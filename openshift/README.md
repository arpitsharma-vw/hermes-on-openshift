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
