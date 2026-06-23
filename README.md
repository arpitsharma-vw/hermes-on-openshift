# Hermes on OpenShift

This repository deploys Hermes Agent on OpenShift for a team demo setup with:

- Telegram gateway mode
- Dashboard mode
- Shared Hermes state between gateway and dashboard
- Secrets managed in OpenShift secret objects (not in repo files)

## Current Deployment Pattern

The recommended pattern is dual deployment in the same namespace:

- hermes-agent: gateway mode (Telegram)
- hermes-dashboard: dashboard mode (web UI)

Both deployments can mount the same PVC (hermes-home) so dashboard and gateway see the same sessions and config.

For full details, see [openshift/DUAL_DEPLOYMENT.md](openshift/DUAL_DEPLOYMENT.md).

## Security Model

- No credential values should be stored in files in this repo.
- Keep credential fields blank in env files under openshift.
- Create and rotate secrets directly in OpenShift.
- Hermes and OpenClaw should be managed independently in their own repos/workflows.
- `LLMAAS_CLIENT_ID` and `LLMAAS_CLIENT_SECRET` are populated from the env file into `${APP_NAME}-secrets` at deploy time. `LLMAAS_CLIENT_ID` used to live as a blank value in the ConfigMap; it has been moved to the Secret so the `token-refresher` sidecar can read it. `LLMAAS_TOKEN_URL` stays in the ConfigMap (a URL is not sensitive).

By default, this deploy flow does not pull credentials from other app secrets.

## Key Scripts

- [scripts/build-hermes-image.sh](scripts/build-hermes-image.sh): build/push Hermes image
- [scripts/ocp-create-ghcr-pull-secret.sh](scripts/ocp-create-ghcr-pull-secret.sh): create GHCR pull secret
- [scripts/ocp-registry-login.sh](scripts/ocp-registry-login.sh): OpenShift registry login helper
- [scripts/ocp-deploy-hermes.sh](scripts/ocp-deploy-hermes.sh): deploy/update Hermes on OpenShift
- [scripts/ocp-verify-hermes.sh](scripts/ocp-verify-hermes.sh): rollout and runtime verification

## Core Config Files

- [openshift/hermes.env.example](openshift/hermes.env.example): gateway template
- [openshift/hermes-dashboard.env.example](openshift/hermes-dashboard.env.example): dashboard template
- [openshift/hermes.env](openshift/hermes.env): gateway runtime config
- [openshift/hermes-dashboard.env](openshift/hermes-dashboard.env): dashboard runtime config

## LLMAAS OAuth2 Token Refresh (Sidecar)

OAuth2 access tokens issued by the LLMAAS gateway (used by the `azure-foundry` provider against `https://llmapi.ai.vwgroup.com`) have a JWT lifetime of roughly 30 minutes. Without rotation, every ~30 minutes the agent would need a full re-deploy to refresh the access token. A small `token-refresher` sidecar container running in every Hermes pod automates this rotation so no manual re-deploy is ever needed.

### What the sidecar does

Every `REFRESH_INTERVAL_SECONDS` (default `1500` seconds = 25 minutes, leaving a 5-minute buffer below the 30-minute JWT TTL), the sidecar:

1. POSTs to `LLMAAS_TOKEN_URL` with OAuth2 `grant_type=client_credentials`.
2. Base64-encodes the returned `access_token` and patches the pod's Secret (`${APP_NAME}-secrets`) with the new `AZURE_FOUNDRY_API_KEY`. If `MIRROR_TO_ANTHROPIC=true`, the same value is also written to `AZURE_ANTHROPIC_KEY`.
3. Patches the deployment annotation `kubectl.kubernetes.io/restartedAt` with the current RFC3339 timestamp, which triggers a rolling restart so the main container picks up the rotated secret values via `envFrom`.
4. Logs the outcome with timestamp, status code, and `expires_in` (token values themselves are never logged).

The loop is single-threaded and never exits. On HTTP failure, RBAC failure, or any other transient error the sidecar logs and retries after `RETRY_INTERVAL_SECONDS` (uniform interval — used for all failure types). A crash in the sidecar restarts cleanly (no crash loop in normal operation); missing or empty credentials cause logged retries, never a fatal exit that takes down the main container.

### Image and pod layout

The sidecar is shipped in the same container image as Hermes. The `Containerfile` `COPY`s `scripts/llmaas-token-refresher.py` to `/usr/local/bin/llmaas-token-refresher.py`, so the existing `HERMES_IMAGE` already contains the script once the image is rebuilt. The sidecar container runs as a non-root user with `allowPrivilegeEscalation: false`, dropped capabilities, and `RuntimeDefault` seccomp profile, in the same pod as the main `hermes` container and sharing the existing ServiceAccount.

### RBAC

The deploy script applies a single `Role` named `hermes-token-refresher` in the target namespace, bound to both the `hermes-agent` and `hermes-dashboard` ServiceAccounts via two `RoleBindings` (`hermes-agent-refresher`, `hermes-dashboard-refresher`). The Role grants:

- `get`/`patch` on `secrets/hermes-agent-secrets` and `secrets/hermes-dashboard-secrets`
- `patch` on `deployments/hermes-agent` and `deployments/hermes-dashboard`

Each sidecar can patch either deployment's secret. This is intentional so the sidecar can recover the other deployment if it falls behind, and avoids a second Role that would only differ in `resourceNames`.

### Tunables

The following env vars are read by the sidecar. They are set in the env file (e.g. `openshift/hermes.env`), propagated to the Secret by the deploy script, and surfaced on the sidecar container as env vars. Defaults are baked into the script, so they do not need to be set explicitly for the sidecar to work.

| Variable | Default | Description |
|---|---|---|
| `REFRESH_INTERVAL_SECONDS` | `1500` | Seconds between refresh cycles. Lower than the JWT TTL (~1800s); 25 minutes leaves a 5-minute buffer. |
| `RETRY_INTERVAL_SECONDS` | `60` | Sleep between failed refresh attempts (uniform interval — used for all failure types: network, HTTP error, RBAC denial). |
| `INITIAL_DELAY_SECONDS` | `5` | Sleep before the first refresh attempt, to let the main container start. |
| `MIRROR_TO_ANTHROPIC` | `true` | Also patch `AZURE_ANTHROPIC_KEY` with the same value as `AZURE_FOUNDRY_API_KEY`. Required by the dashboard; harmless for the agent. |

### Where credentials live

`LLMAAS_CLIENT_ID` and `LLMAAS_CLIENT_SECRET` are stored in `${APP_NAME}-secrets` (the same Secret that already held `LLMAAS_CLIENT_SECRET`). Neither is in the ConfigMap, neither is in the repo. `LLMAAS_TOKEN_URL` remains in the ConfigMap (a URL is not sensitive) and the sidecar reads it via `envFrom: configMapRef`. The fetched access token is written back to the same Secret at every refresh cycle.

To populate `LLMAAS_CLIENT_ID` from an existing cluster Secret, set `INHERIT_SECRET_NAME` in the env file (the existing inheritance mechanism picks it up). To populate it directly, paste the value into the env file before running the deploy script.

### Rollback

If the sidecar misbehaves in production, you can effectively pause it without redeploying:

```bash
oc set env deployment/hermes-agent -c token-refresher REFRESH_INTERVAL_SECONDS=999999
```

Substitute `hermes-dashboard` for the dashboard deployment. The sidecar continues to run but only refreshes every ~11.6 days, far beyond any token TTL. To remove the sidecar permanently, delete the `token-refresher` container block from the Deployment spec and re-apply.

## Quick Start

1. Copy and edit env files (without putting credentials into them):

```bash
cp openshift/hermes.env.example openshift/hermes.env
cp openshift/hermes-dashboard.env.example openshift/hermes-dashboard.env
```

2. Create/update OpenShift secrets manually from terminal prompts (see [openshift/DUAL_DEPLOYMENT.md](openshift/DUAL_DEPLOYMENT.md)).

3. Deploy gateway and dashboard:

```bash
./scripts/ocp-deploy-hermes.sh openshift/hermes.env
./scripts/ocp-deploy-hermes.sh openshift/hermes-dashboard.env
```

4. Verify:

```bash
./scripts/ocp-verify-hermes.sh openshift/hermes.env
./scripts/ocp-verify-hermes.sh openshift/hermes-dashboard.env
```

## Notes

- Gateway mode removes only its own service/route.
- Dashboard mode creates its own service/route.
- First pod start may install some runtime dependencies in-container.
- If your cluster uses outbound proxies, set `PROXY_SECRET_NAME` (recommended) or set `HTTP_PROXY`/`HTTPS_PROXY`/`NO_PROXY` directly, plus `NODE_USE_ENV_PROXY`.
