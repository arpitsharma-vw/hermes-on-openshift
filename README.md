# Hermes on OpenShift

This repo is a parallel working area for evaluating Hermes Agent in a way that matches the workflow used for OpenClaw, without mixing assumptions between the two projects.

## Scope

Current goal:
- install Hermes cleanly on macOS
- validate a working CLI session first
- validate gateway setup second
- capture OpenShift-specific requirements before building a hardened deployment

Non-goals for the first pass:
- production-ready OpenShift manifests
- security hardening parity with the OpenClaw repo
- persistent bot deployment before local Hermes behavior is verified

## Why Separate This Repo

Hermes has different runtime assumptions than OpenClaw:
- official install path is a shell installer, not a prebuilt container
- config is split between `~/.hermes/config.yaml` and `~/.hermes/.env`
- provider setup is interactive via `hermes model` or `hermes setup`
- the gateway is a separate long-running Hermes process
- Hermes docs explicitly recommend: get a normal CLI chat working first, then add gateway/messaging

## What We Learned From Hermes Docs

- Install on macOS with:

```bash
curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh | bash
```

- After install:

```bash
source ~/.zshrc
hermes doctor
hermes model
hermes --tui
```

- Hermes stores:
  - secrets in `~/.hermes/.env`
  - non-secret config in `~/.hermes/config.yaml`

- Hermes requires a model with at least a 64k context window.
- Messaging setup should come only after the base CLI works.
- Gateway setup entrypoint is:

```bash
hermes gateway setup
```

## Recommended First Run Order

1. Install Hermes locally on your Mac.
2. Run `hermes doctor` and fix anything it reports.
3. Configure a provider with `hermes model`.
4. Run one clean chat in `hermes` or `hermes --tui`.
5. Resume the session with `hermes --continue`.
6. Only then enable messaging with `hermes gateway setup`.
7. Only after that start container/OpenShift work.

## Proxy Note

Your environment already uses outbound proxies in OpenShift. Hermes is Node- and Python-based, so proxy behavior should be validated early.

Start with these checks when moving beyond local CLI:

```bash
env | rg 'HTTP_PROXY|HTTPS_PROXY|NO_PROXY'
hermes doctor
```

If Hermes or a Node-based sidecar needs explicit proxy support in a containerized environment, test `NODE_USE_ENV_PROXY=1` early rather than treating it as a late-stage fix.

## Repo Layout

- `IMPLEMENTATION_PLAN.md` — phased plan and acceptance criteria
- `Containerfile` — self-managed Hermes runtime image build
- `.github/workflows/build-ghcr-image.yml` — GitHub Actions build/push to GHCR
- `scripts/bootstrap-local-macos.sh` — local install helper for macOS
- `scripts/build-hermes-image.sh` — build/push Hermes image from this repo
- `scripts/ocp-create-ghcr-pull-secret.sh` — create pull secret for private GHCR images
- `scripts/ocp-registry-login.sh` — login helper for OpenShift internal registry
- `scripts/ocp-deploy-hermes.sh` — OpenShift deploy automation
- `scripts/ocp-verify-hermes.sh` — OpenShift smoke checks
- `openshift/hermes.env.example` — deployment variable template (copy to `openshift/hermes.env`)
- `vars/hermes.yml.example` — starter config for future container/OpenShift work

## Private GitHub Repo Build (Recommended)

If you want this in your private GitHub repo, build in GitHub Actions and publish to GHCR.

1. Push this repo to your private GitHub repository.
2. GitHub Action [build-ghcr-image.yml](.github/workflows/build-ghcr-image.yml) builds and pushes:
  - `ghcr.io/<your-github-username>/<your-repo-name>:main`
  - `ghcr.io/<your-github-username>/<your-repo-name>:latest`
  - `ghcr.io/<your-github-username>/<your-repo-name>:sha-<commit>`

Note: the image now bootstraps Hermes on first container startup (lazy install),
which makes CI image build more reliable. First pod start requires outbound
internet access to fetch Hermes installer and Python dependencies.
3. In OpenShift, create a GHCR pull secret:

```bash
export GHCR_USERNAME=<your-github-username>
export GHCR_TOKEN=<token-with-read-packages>
./scripts/ocp-create-ghcr-pull-secret.sh <your-namespace> ghcr-pull-secret
```

4. In `openshift/hermes.env`, set:

```bash
HERMES_IMAGE=ghcr.io/<your-github-username>/<your-repo-name>:main
IMAGE_PULL_SECRET=ghcr-pull-secret
```

## Build Your Own Hermes Image (Local Builder Alternative)

Because there is no pre-provided image in this workflow, build one from this repo first.

1. Prepare env file:

```bash
cp openshift/hermes.env.example openshift/hermes.env
```

2. Set `HERMES_IMAGE` in `openshift/hermes.env`, for example:

```bash
HERMES_IMAGE=image-registry.openshift-image-registry.svc:5000/your-namespace/hermes-agent:latest
```

3. If using OpenShift internal registry, login first:

```bash
./scripts/ocp-registry-login.sh
```

4. Build and push image:

```bash
./scripts/build-hermes-image.sh openshift/hermes.env
```

5. Optional local-only build without push:

```bash
NO_PUSH=1 ./scripts/build-hermes-image.sh openshift/hermes.env
```

## OpenShift Handoff (Run After You Login)

Once you authenticate to OpenShift, this repo is ready for deployment.

1. Prepare deployment variables:

```bash
cp openshift/hermes.env.example openshift/hermes.env
```

2. Edit `openshift/hermes.env` and set at least:
  - `HERMES_IMAGE` (required)
  - one provider key (for example `OPENAI_API_KEY`)
  - proxy vars if your cluster requires outbound proxy

3. Deploy:

```bash
./scripts/ocp-deploy-hermes.sh openshift/hermes.env
```

4. Verify rollout and runtime health:

```bash
./scripts/ocp-verify-hermes.sh openshift/hermes.env
```

5. If you want to start in debug mode first, set:

```bash
HERMES_RUN_MODE=idle
```

Then redeploy and `oc exec` into the pod to run Hermes commands interactively.

## Immediate Next Step (Local Baseline)

Run:

```bash
./scripts/bootstrap-local-macos.sh
```

Then continue with the commands in `IMPLEMENTATION_PLAN.md`.
