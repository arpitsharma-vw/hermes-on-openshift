# Dual Deployment

This setup runs two Hermes deployments in the same namespace:

- `hermes-agent` in `gateway` mode for Telegram
- `hermes-dashboard` in `dashboard` mode for the web UI

Both can share the same Hermes state volume so the dashboard sees the same session history as the gateway.

## Files

- `hermes.env`: gateway deployment
- `hermes-dashboard.env`: dashboard deployment
- `hermes.env.example`: base gateway template
- `hermes-dashboard.env.example`: dashboard template

## Important Settings

- Set `HERMES_INFERENCE_PROVIDER`, `HERMES_INFERENCE_MODEL`, and `AZURE_FOUNDRY_BASE_URL` in both env files.
- Leave provider secrets blank in the env files when the cluster secret already exists.
- Use `INHERIT_SECRET_NAME=hermes-agent-secrets` for the dashboard deployment so it reuses provider credentials.
- Use `PVC_NAME=hermes-home` in the dashboard deployment to share the same Hermes state and history.

## Token Refresh Sidecar

When the cluster is configured for the LLMAAS gateway (`azure-foundry` provider against `https://llmapi.ai.vwgroup.com`), both `hermes-agent` and `hermes-dashboard` Deployments get a `token-refresher` sidecar container. Each pod refreshes its own access token independently — the agent sidecar patches `hermes-agent-secrets` and restarts `hermes-agent`, the dashboard sidecar patches `hermes-dashboard-secrets` and restarts `hermes-dashboard`. Timing skew between the two pods is acceptable because the JWT TTL (~30 minutes) far exceeds any realistic skew between two pods in the same namespace, and both sidecars patch both secrets (via `MIRROR_TO_ANTHROPIC=true`) so either sidecar can recover the other.

The sidecar logs are separate from the main container; inspect them with:

```bash
oc logs deploy/hermes-agent -c token-refresher -n "$NAMESPACE"
oc logs deploy/hermes-dashboard -c token-refresher -n "$NAMESPACE"
```

Tunables (`REFRESH_INTERVAL_SECONDS`, `RETRY_INTERVAL_SECONDS`, `INITIAL_DELAY_SECONDS`, `MIRROR_TO_ANTHROPIC`) and the credential `LLMAAS_CLIENT_ID` are documented in [README.md](README.md#token-refresh-sidecar-llmaas).

## Demo Secrets (No Credentials In Files)

Create and manage Hermes secrets in this repo/workflow only.

Recommended approach:

- Keep these blank in env files: `OPENAI_API_KEY`, `AZURE_FOUNDRY_API_KEY`, `GH_TOKEN`, `TELEGRAM_BOT_TOKEN`
- Create/update `hermes-agent-secrets` directly in OpenShift for Hermes
- Keep OpenClaw secret creation and rotation in the OpenClaw repo/workflow

By default, Hermes deploy is independent and does not pull credentials from other app secrets.

Manual create/update for Hermes secret (prompted, no file storage):

```bash
export NAMESPACE=dl-playground-arpit
read -r -s -p "TELEGRAM_BOT_TOKEN: " TELEGRAM_BOT_TOKEN; echo
read -r -s -p "AZURE_FOUNDRY_API_KEY: " AZURE_FOUNDRY_API_KEY; echo
read -r -s -p "GH_TOKEN (optional): " GH_TOKEN; echo

oc -n "$NAMESPACE" create secret generic hermes-agent-secrets \
	--from-literal=TELEGRAM_BOT_TOKEN="$TELEGRAM_BOT_TOKEN" \
	--from-literal=AZURE_FOUNDRY_API_KEY="$AZURE_FOUNDRY_API_KEY" \
	--from-literal=OPENAI_API_KEY="$AZURE_FOUNDRY_API_KEY" \
	${GH_TOKEN:+--from-literal=GH_TOKEN="$GH_TOKEN"} \
	--dry-run=client -o yaml | oc apply -f -

unset TELEGRAM_BOT_TOKEN AZURE_FOUNDRY_API_KEY GH_TOKEN
```

Manual create/update for dashboard-only secret (independent rotation):

```bash
export NAMESPACE=dl-playground-arpit
read -r -s -p "DASHBOARD_AZURE_FOUNDRY_API_KEY: " DASHBOARD_AZURE_FOUNDRY_API_KEY; echo
read -r -s -p "DASHBOARD_GH_TOKEN (optional): " DASHBOARD_GH_TOKEN; echo

oc -n "$NAMESPACE" create secret generic hermes-dashboard-secrets \
	--from-literal=AZURE_FOUNDRY_API_KEY="$DASHBOARD_AZURE_FOUNDRY_API_KEY" \
	--from-literal=OPENAI_API_KEY="$DASHBOARD_AZURE_FOUNDRY_API_KEY" \
	${DASHBOARD_GH_TOKEN:+--from-literal=GH_TOKEN="$DASHBOARD_GH_TOKEN"} \
	--dry-run=client -o yaml | oc apply -f -

unset DASHBOARD_AZURE_FOUNDRY_API_KEY DASHBOARD_GH_TOKEN
```

To make dashboard use its own secret instead of inheriting gateway credentials:

```bash
sed -i '' 's/^INHERIT_SECRET_NAME=.*/INHERIT_SECRET_NAME=hermes-dashboard-secrets/' openshift/hermes-dashboard.env
./scripts/ocp-deploy-hermes.sh openshift/hermes-dashboard.env
```

## Deploy

```bash
./scripts/ocp-deploy-hermes.sh openshift/hermes.env
./scripts/ocp-deploy-hermes.sh openshift/hermes-dashboard.env
```

## Verify

```bash
oc -n "$NAMESPACE" get deploy,pods,svc,route | grep hermes
```

## Operations

Restart only gateway:

```bash
oc -n "$NAMESPACE" rollout restart deploy/hermes-agent
oc -n "$NAMESPACE" rollout status deploy/hermes-agent --timeout=180s
```

Restart only dashboard:

```bash
oc -n "$NAMESPACE" rollout restart deploy/hermes-dashboard
oc -n "$NAMESPACE" rollout status deploy/hermes-dashboard --timeout=180s
```

Check shared state/config health:

```bash
# Both pods should be Running
oc -n "$NAMESPACE" get pods -l app.kubernetes.io/name=hermes-agent
oc -n "$NAMESPACE" get pods -l app.kubernetes.io/name=hermes-dashboard

# Dashboard route should return 200
route=$(oc -n "$NAMESPACE" get route hermes-dashboard -o jsonpath='{.spec.host}')
curl -k -I "https://$route"

# Both deployments should mount the same PVC name (hermes-home)
oc -n "$NAMESPACE" get deploy hermes-agent -o jsonpath='{.spec.template.spec.volumes[0].persistentVolumeClaim.claimName}' && echo
oc -n "$NAMESPACE" get deploy hermes-dashboard -o jsonpath='{.spec.template.spec.volumes[0].persistentVolumeClaim.claimName}' && echo

# Shared Hermes config and sessions visible from dashboard pod
oc -n "$NAMESPACE" exec deploy/hermes-dashboard -- /bin/sh -c 'sed -n "1,80p" "$HERMES_HOME/config.yaml"; echo ---; ls "$HERMES_HOME/sessions" | wc -l'
```

## Notes

- Gateway mode removes only its own Service and Route.
- Dashboard mode creates its own Service and Route.
- The deploy script now writes a minimal `config.yaml` into `HERMES_HOME` from the runtime env so gateway and auxiliary tasks use the configured model/provider consistently.