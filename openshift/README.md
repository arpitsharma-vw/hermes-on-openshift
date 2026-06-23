# OpenShift Deployment Guide

This folder contains the deployment inputs for Hermes on OpenShift.

## Files

- `hermes.env.example`: copy this to `hermes.env` and fill values.

## Build the Image First

This repo includes a `Containerfile`, so you can build Hermes yourself.

For private GitHub repo flow, prefer GitHub Actions to push to GHCR using
`.github/workflows/build-ghcr-image.yml`.

```bash
cp openshift/hermes.env.example openshift/hermes.env
vi openshift/hermes.env
./scripts/ocp-registry-login.sh
./scripts/build-hermes-image.sh openshift/hermes.env
```

Set `HERMES_IMAGE` in `hermes.env` to the image location you can pull from OpenShift.

If your GHCR package is private, create pull secret before deploy:

```bash
export GHCR_USERNAME=<your-github-username>
export GHCR_TOKEN=<token-with-read-packages>
./scripts/ocp-create-ghcr-pull-secret.sh <your-namespace> ghcr-pull-secret
```

Then set `IMAGE_PULL_SECRET=ghcr-pull-secret` in `hermes.env`.

## Required Inputs

Set these in `hermes.env` before deployment:

- `HERMES_IMAGE`: container image with `hermes` binary available
- `NAMESPACE`: target project/namespace
- one provider API key (for example `OPENAI_API_KEY`)

Optional but commonly needed:

- `PROXY_SECRET_NAME` (Secret with `HTTP_PROXY`, `HTTPS_PROXY`, `NO_PROXY` keys)
- `HTTP_PROXY`, `HTTPS_PROXY`, `NO_PROXY` (fallback when not using secret)
- `STORAGE_CLASS` for PVC provisioning behavior
- `HERMES_RUN_MODE` (`gateway`, `chat`, or `idle`)

If your proxy secret is `my-proxy-whitelist`, the deploy script also supports its key shape:
`http-proxy-url`, `http-proxy-port`, `https-proxy-url`, `https-proxy-port`,
`proxy-user`, `proxy-password` (it composes `HTTP_PROXY`/`HTTPS_PROXY` from these).

## Token Refresh Sidecar (LLMAAS)

When the deployment uses the internal LLMAAS gateway (`azure-foundry` provider against `https://llmapi.ai.vwgroup.com`), the deploy script adds a `token-refresher` sidecar container to the Deployment. The sidecar periodically fetches a fresh OAuth2 access token and patches the agent's Secret, then triggers a rolling restart by patching the `kubectl.kubernetes.io/restartedAt` annotation.

`LLMAAS_TOKEN_URL` remains in the ConfigMap (a URL is not sensitive); the sidecar reads it via `envFrom: configMapRef`. `LLMAAS_CLIENT_ID` and `LLMAAS_CLIENT_SECRET` live in `${APP_NAME}-secrets`. The fetched access token is patched back into the same Secret as `AZURE_FOUNDRY_API_KEY` at every refresh cycle (and into `AZURE_ANTHROPIC_KEY` if `MIRROR_TO_ANTHROPIC=true`). The deploy script also applies a `Role` `hermes-token-refresher` plus two `RoleBindings` (`hermes-agent-refresher`, `hermes-dashboard-refresher`) granting the sidecar permission to patch those Secrets and Deployments.

### Tunables

Set these in `hermes.env` (or `hermes-dashboard.env`) before running `scripts/ocp-deploy-hermes.sh`. The deploy script propagates them into the Secret and onto the sidecar container. All have working defaults baked into the script.

| Variable | Default | Description |
|---|---|---|
| `REFRESH_INTERVAL_SECONDS` | `1500` | Seconds between refresh cycles. Lower than the JWT TTL (~1800s) so there is a buffer. |
| `RETRY_INTERVAL_SECONDS` | `60` | Seconds between retry attempts on failure (uniform interval for all failure types: network, HTTP error, RBAC denial). |
| `INITIAL_DELAY_SECONDS` | `5` | Seconds to wait before the first refresh attempt, to let the main container start. |
| `MIRROR_TO_ANTHROPIC` | `true` | Also patch `AZURE_ANTHROPIC_KEY` with the same token (keeps the dashboard's anthropic key in sync with the gateway's foundry key). |
| `LLMAAS_CLIENT_ID` | (none) | OAuth2 client id. Must be populated in the env file (or inherited via `INHERIT_SECRET_NAME`) for refresh to work. The deploy script reads it from the env file and writes it into `${APP_NAME}-secrets`. |

If `LLMAAS_CLIENT_ID` is unset, the sidecar logs an error and retries forever; it never crashes the main container. To effectively pause the sidecar without redeploying, set `REFRESH_INTERVAL_SECONDS` to a very large value on the existing sidecar (see `oc set env deployment/<name> -c token-refresher REFRESH_INTERVAL_SECONDS=999999`).

## Deploy

```bash
cp openshift/hermes.env.example openshift/hermes.env
vi openshift/hermes.env
./scripts/ocp-deploy-hermes.sh openshift/hermes.env
```

## Verify

```bash
./scripts/ocp-verify-hermes.sh openshift/hermes.env
```

## What the Deploy Script Creates

- ServiceAccount
- PersistentVolumeClaim for `HERMES_HOME`
- ConfigMap for non-secret runtime vars
- Secret for provider and gateway tokens
- Deployment

## Troubleshooting

1. If rollout fails, check pod events:

```bash
oc get events -n "$NAMESPACE" --sort-by=.lastTimestamp | tail -n 50
```

2. If image pull fails, verify `HERMES_IMAGE` and image pull permissions.
3. If API calls fail, verify outbound proxy values and provider key values.
4. If state is lost after restart, verify PVC is bound and mounted.
