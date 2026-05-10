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
- If your cluster uses outbound proxies, set HTTP_PROXY/HTTPS_PROXY/NO_PROXY and NODE_USE_ENV_PROXY in env files.
