#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${1:-${ROOT_DIR}/openshift/hermes.env}"

if ! command -v oc >/dev/null 2>&1; then
  echo "OpenShift CLI (oc) is required." >&2
  exit 1
fi

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "Missing env file: ${ENV_FILE}" >&2
  echo "Create it from: ${ROOT_DIR}/openshift/hermes.env.example" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

NAMESPACE="${NAMESPACE:-hermes-agent}"
APP_NAME="${APP_NAME:-hermes-agent}"
HERMES_IMAGE="${HERMES_IMAGE:-}"
IMAGE_PULL_POLICY="${IMAGE_PULL_POLICY:-IfNotPresent}"
REPLICAS="${REPLICAS:-1}"
HERMES_HOME="${HERMES_HOME:-/opt/hermes/.hermes}"
PVC_NAME="${PVC_NAME:-hermes-home}"
PVC_SIZE="${PVC_SIZE:-5Gi}"
STORAGE_CLASS="${STORAGE_CLASS:-}"
HERMES_RUN_MODE="${HERMES_RUN_MODE:-gateway}"
HERMES_DASHBOARD_PORT="${HERMES_DASHBOARD_PORT:-9119}"
HERMES_INFERENCE_PROVIDER="${HERMES_INFERENCE_PROVIDER:-}"
HERMES_INFERENCE_MODEL="${HERMES_INFERENCE_MODEL:-}"
HERMES_INFERENCE_API_MODE="${HERMES_INFERENCE_API_MODE:-}"
AZURE_FOUNDRY_BASE_URL="${AZURE_FOUNDRY_BASE_URL:-}"
AZURE_ANTHROPIC_KEY="${AZURE_ANTHROPIC_KEY:-}"
LLMAAS_TOKEN_URL="${LLMAAS_TOKEN_URL:-https://idp.cloud.vwgroup.com/auth/realms/kums-mfa/protocol/openid-connect/token}"
LLMAAS_CLIENT_ID="${LLMAAS_CLIENT_ID:-}"
LLMAAS_CLIENT_SECRET="${LLMAAS_CLIENT_SECRET:-}"
LLMAAS_VIRTUAL_KEY="${LLMAAS_VIRTUAL_KEY:-}"
HTTP_PROXY="${HTTP_PROXY:-}"
HTTPS_PROXY="${HTTPS_PROXY:-}"
NO_PROXY="${NO_PROXY:-}"
NODE_USE_ENV_PROXY="${NODE_USE_ENV_PROXY:-1}"
IMAGE_PULL_SECRET="${IMAGE_PULL_SECRET:-}"
TELEGRAM_SOURCE_SECRET_NAME="${TELEGRAM_SOURCE_SECRET_NAME:-}"
INHERIT_SECRET_NAME="${INHERIT_SECRET_NAME:-${APP_NAME}-secrets}"
PROXY_SECRET_NAME="${PROXY_SECRET_NAME:-${INHERIT_SECRET_NAME}}"
ALLOW_INTERACTIVE_SECRET_PROMPT="${ALLOW_INTERACTIVE_SECRET_PROMPT:-false}"
GATEWAY_ALLOW_ALL_USERS="${GATEWAY_ALLOW_ALL_USERS:-}"
TELEGRAM_ALLOWED_USERS="${TELEGRAM_ALLOWED_USERS:-}"

if [[ -z "${AZURE_FOUNDRY_API_KEY:-}" ]] && [[ -n "${OPENAI_API_KEY:-}" ]]; then
  AZURE_FOUNDRY_API_KEY="${OPENAI_API_KEY}"
fi

# Fetch llmgateway OAuth2 access token when llmaas credentials are present.
# The token is stored in AZURE_FOUNDRY_API_KEY and pushed to the Kubernetes Secret.
# Re-run this deploy script to refresh (tokens expire in ~30 min).
if [[ -z "${AZURE_FOUNDRY_API_KEY:-}" ]] && [[ -n "${LLMAAS_CLIENT_ID:-}" ]] && [[ -n "${LLMAAS_CLIENT_SECRET:-}" ]]; then
  echo "Fetching llmgateway OAuth2 access token..."
  _llmaas_token_json=$(curl -sf -X POST "${LLMAAS_TOKEN_URL}" \
    --data-urlencode "client_id=${LLMAAS_CLIENT_ID}" \
    --data-urlencode "client_secret=${LLMAAS_CLIENT_SECRET}" \
    --data-urlencode "grant_type=client_credentials")
  AZURE_FOUNDRY_API_KEY=$(printf '%s' "${_llmaas_token_json}" | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")
  unset _llmaas_token_json
  echo "OAuth2 token obtained (expires ~30 min). Re-run deploy to refresh."
fi

if [[ -z "${AZURE_ANTHROPIC_KEY:-}" ]] && [[ -n "${AZURE_FOUNDRY_API_KEY:-}" ]]; then
  AZURE_ANTHROPIC_KEY="${AZURE_FOUNDRY_API_KEY}"
fi

RUNTIME_HTTP_PROXY="${HTTP_PROXY}"
RUNTIME_HTTPS_PROXY="${HTTPS_PROXY}"
RUNTIME_NO_PROXY="${NO_PROXY}"

# Keep proxy values out of oc CLI environment.
unset HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy

if [[ -z "${HERMES_IMAGE}" ]]; then
  echo "HERMES_IMAGE is required in ${ENV_FILE}" >&2
  exit 1
fi

echo "Ensuring namespace ${NAMESPACE} exists..."
oc get namespace "${NAMESPACE}" >/dev/null 2>&1 || oc create namespace "${NAMESPACE}"
oc project "${NAMESPACE}" >/dev/null

echo "Applying ServiceAccount..."
cat <<EOF | oc apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${APP_NAME}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: ${APP_NAME}
EOF

echo "Applying Role + RoleBindings for token-refresher sidecar..."
cat <<EOF | oc apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: hermes-token-refresher
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: ${APP_NAME}
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    resourceNames: ["hermes-agent-secrets", "hermes-dashboard-secrets"]
    verbs: ["get", "patch"]
  - apiGroups: ["apps"]
    resources: ["deployments"]
    resourceNames: ["hermes-agent", "hermes-dashboard"]
    verbs: ["patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: hermes-agent-refresher
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: ${APP_NAME}
subjects:
  - kind: ServiceAccount
    name: hermes-agent
    namespace: ${NAMESPACE}
roleRef:
  kind: Role
  name: hermes-token-refresher
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: hermes-dashboard-refresher
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: ${APP_NAME}
subjects:
  - kind: ServiceAccount
    name: hermes-dashboard
    namespace: ${NAMESPACE}
roleRef:
  kind: Role
  name: hermes-token-refresher
  apiGroup: rbac.authorization.k8s.io
EOF

echo "Applying PVC..."
if [[ -n "${STORAGE_CLASS}" ]]; then
  cat <<EOF | oc apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${PVC_NAME}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: ${APP_NAME}
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: ${PVC_SIZE}
  storageClassName: ${STORAGE_CLASS}
EOF
else
  cat <<EOF | oc apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${PVC_NAME}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: ${APP_NAME}
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: ${PVC_SIZE}
EOF
fi

echo "Applying ConfigMap..."
cat <<EOF | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${APP_NAME}-config
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: ${APP_NAME}
data:
  HERMES_HOME: "${HERMES_HOME}"
  HOME: "/opt/hermes"
  XDG_STATE_HOME: "${HERMES_HOME}/xdg-state"
  HERMES_RUN_MODE: "${HERMES_RUN_MODE}"
  HERMES_INFERENCE_PROVIDER: "${HERMES_INFERENCE_PROVIDER}"
  HERMES_INFERENCE_MODEL: "${HERMES_INFERENCE_MODEL}"
  HERMES_INFERENCE_API_MODE: "${HERMES_INFERENCE_API_MODE}"
  AZURE_FOUNDRY_BASE_URL: "${AZURE_FOUNDRY_BASE_URL}"
  LLMAAS_TOKEN_URL: "${LLMAAS_TOKEN_URL}"
  GATEWAY_ALLOW_ALL_USERS: "${GATEWAY_ALLOW_ALL_USERS}"
  TELEGRAM_ALLOWED_USERS: "${TELEGRAM_ALLOWED_USERS}"
  NODE_USE_ENV_PROXY: "${NODE_USE_ENV_PROXY}"
EOF

echo "Applying Secret..."

if [[ -z "${OPENAI_API_KEY:-}" ]]; then
  existing_openai_key_b64="$(oc get secret "${INHERIT_SECRET_NAME}" -n "${NAMESPACE}" -o jsonpath='{.data.OPENAI_API_KEY}' 2>/dev/null || true)"
  if [[ -n "${existing_openai_key_b64}" ]]; then
    OPENAI_API_KEY="$(printf '%s' "${existing_openai_key_b64}" | base64 --decode)"
  fi
fi

if [[ -z "${AZURE_FOUNDRY_API_KEY:-}" ]]; then
  existing_azure_key_b64="$(oc get secret "${INHERIT_SECRET_NAME}" -n "${NAMESPACE}" -o jsonpath='{.data.AZURE_FOUNDRY_API_KEY}' 2>/dev/null || true)"
  if [[ -n "${existing_azure_key_b64}" ]]; then
    AZURE_FOUNDRY_API_KEY="$(printf '%s' "${existing_azure_key_b64}" | base64 --decode)"
  elif [[ -n "${OPENAI_API_KEY:-}" ]]; then
    AZURE_FOUNDRY_API_KEY="${OPENAI_API_KEY}"
  fi
fi

if [[ -z "${LLMAAS_CLIENT_ID:-}" ]]; then
  existing_llmaas_client_id_b64="$(oc get secret "${INHERIT_SECRET_NAME}" -n "${NAMESPACE}" -o jsonpath='{.data.LLMAAS_CLIENT_ID}' 2>/dev/null || true)"
  if [[ -n "${existing_llmaas_client_id_b64}" ]]; then
    LLMAAS_CLIENT_ID="$(printf '%s' "${existing_llmaas_client_id_b64}" | base64 --decode)"
  fi
fi

if [[ -z "${LLMAAS_CLIENT_SECRET:-}" ]]; then
  existing_llmaas_client_secret_b64="$(oc get secret "${INHERIT_SECRET_NAME}" -n "${NAMESPACE}" -o jsonpath='{.data.LLMAAS_CLIENT_SECRET}' 2>/dev/null || true)"
  if [[ -n "${existing_llmaas_client_secret_b64}" ]]; then
    LLMAAS_CLIENT_SECRET="$(printf '%s' "${existing_llmaas_client_secret_b64}" | base64 --decode)"
  fi
fi

if [[ -z "${LLMAAS_VIRTUAL_KEY:-}" ]]; then
  existing_llmaas_virtual_key_b64="$(oc get secret "${INHERIT_SECRET_NAME}" -n "${NAMESPACE}" -o jsonpath='{.data.LLMAAS_VIRTUAL_KEY}' 2>/dev/null || true)"
  if [[ -n "${existing_llmaas_virtual_key_b64}" ]]; then
    LLMAAS_VIRTUAL_KEY="$(printf '%s' "${existing_llmaas_virtual_key_b64}" | base64 --decode)"
  fi
fi

if [[ -z "${OPENAI_API_KEY:-}" ]] && [[ "${ALLOW_INTERACTIVE_SECRET_PROMPT}" == "true" ]] && [[ -t 0 ]]; then
  read -r -s -p "OPENAI_API_KEY not set in env file. Enter a new key (leave blank to skip): " OPENAI_API_KEY
  echo
fi

secret_args=()
[[ -n "${OPENAI_API_KEY:-}" ]] && secret_args+=(--from-literal=OPENAI_API_KEY="${OPENAI_API_KEY}")
[[ -n "${OPENROUTER_API_KEY:-}" ]] && secret_args+=(--from-literal=OPENROUTER_API_KEY="${OPENROUTER_API_KEY}")
[[ -n "${ANTHROPIC_API_KEY:-}" ]] && secret_args+=(--from-literal=ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY}")
[[ -n "${AZURE_ANTHROPIC_KEY:-}" ]] && secret_args+=(--from-literal=AZURE_ANTHROPIC_KEY="${AZURE_ANTHROPIC_KEY}")
[[ -n "${AZURE_FOUNDRY_API_KEY:-}" ]] && secret_args+=(--from-literal=AZURE_FOUNDRY_API_KEY="${AZURE_FOUNDRY_API_KEY}")
[[ -n "${LLMAAS_CLIENT_ID:-}" ]] && secret_args+=(--from-literal=LLMAAS_CLIENT_ID="${LLMAAS_CLIENT_ID}")
[[ -n "${LLMAAS_CLIENT_SECRET:-}" ]] && secret_args+=(--from-literal=LLMAAS_CLIENT_SECRET="${LLMAAS_CLIENT_SECRET}")
[[ -n "${LLMAAS_VIRTUAL_KEY:-}" ]] && secret_args+=(--from-literal=LLMAAS_VIRTUAL_KEY="${LLMAAS_VIRTUAL_KEY}")
[[ -n "${GH_TOKEN:-}" ]] && secret_args+=(--from-literal=GH_TOKEN="${GH_TOKEN}")
[[ -n "${TELEGRAM_BOT_TOKEN:-}" ]] && secret_args+=(--from-literal=TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN}")
[[ -n "${SLACK_BOT_TOKEN:-}" ]] && secret_args+=(--from-literal=SLACK_BOT_TOKEN="${SLACK_BOT_TOKEN}")
[[ -n "${DISCORD_BOT_TOKEN:-}" ]] && secret_args+=(--from-literal=DISCORD_BOT_TOKEN="${DISCORD_BOT_TOKEN}")
[[ -n "${RUNTIME_HTTP_PROXY:-}" ]] && secret_args+=(--from-literal=HTTP_PROXY="${RUNTIME_HTTP_PROXY}")
[[ -n "${RUNTIME_HTTPS_PROXY:-}" ]] && secret_args+=(--from-literal=HTTPS_PROXY="${RUNTIME_HTTPS_PROXY}")
[[ -n "${RUNTIME_NO_PROXY:-}" ]] && secret_args+=(--from-literal=NO_PROXY="${RUNTIME_NO_PROXY}")

if (( ${#secret_args[@]} == 0 )); then
  echo "No secret values detected in ${ENV_FILE}; creating placeholder secret."
  oc create secret generic "${APP_NAME}-secrets" \
    --from-literal=PLACEHOLDER=replace-me \
    --namespace "${NAMESPACE}" \
    --dry-run=client -o yaml | oc apply -f -
else
  oc create secret generic "${APP_NAME}-secrets" \
    "${secret_args[@]}" \
    --namespace "${NAMESPACE}" \
    --dry-run=client -o yaml | oc apply -f -
fi

if [[ -z "${TELEGRAM_BOT_TOKEN:-}" ]]; then
  if [[ -n "${TELEGRAM_SOURCE_SECRET_NAME}" ]]; then
    source_telegram_token_b64="$(oc get secret "${TELEGRAM_SOURCE_SECRET_NAME}" -n "${NAMESPACE}" -o jsonpath='{.data.TELEGRAM_BOT_TOKEN}' 2>/dev/null || true)"
    if [[ -n "${source_telegram_token_b64}" ]]; then
      oc patch secret "${APP_NAME}-secrets" -n "${NAMESPACE}" --type=merge \
        -p '{"data":{"TELEGRAM_BOT_TOKEN":"'"${source_telegram_token_b64}"'"}}' >/dev/null
      echo "TELEGRAM_BOT_TOKEN copied from secret ${TELEGRAM_SOURCE_SECRET_NAME} into ${APP_NAME}-secrets."
    else
      echo "TELEGRAM_BOT_TOKEN not provided and no key found in secret ${TELEGRAM_SOURCE_SECRET_NAME}."
    fi
  else
    echo "TELEGRAM_BOT_TOKEN not provided and TELEGRAM_SOURCE_SECRET_NAME is not set."
  fi
fi

for inherited_secret_key in OPENAI_API_KEY OPENROUTER_API_KEY ANTHROPIC_API_KEY AZURE_FOUNDRY_API_KEY LLMAAS_CLIENT_SECRET LLMAAS_VIRTUAL_KEY GH_TOKEN SLACK_BOT_TOKEN DISCORD_BOT_TOKEN; do
  inherited_secret_b64="$(oc get secret "${INHERIT_SECRET_NAME}" -n "${NAMESPACE}" -o jsonpath='{.data.'"${inherited_secret_key}"'}' 2>/dev/null || true)"
  if [[ -n "${inherited_secret_b64}" ]]; then
    oc patch secret "${APP_NAME}-secrets" -n "${NAMESPACE}" --type=merge \
      -p '{"data":{"'"${inherited_secret_key}"'":"'"${inherited_secret_b64}"'"}}' >/dev/null
  fi
done

http_proxy_secret_b64="$(oc get secret "${PROXY_SECRET_NAME}" -n "${NAMESPACE}" -o jsonpath='{.data.HTTP_PROXY}' 2>/dev/null || true)"
[[ -z "${http_proxy_secret_b64}" ]] && http_proxy_secret_b64="$(oc get secret "${PROXY_SECRET_NAME}" -n "${NAMESPACE}" -o jsonpath='{.data.http_proxy}' 2>/dev/null || true)"
https_proxy_secret_b64="$(oc get secret "${PROXY_SECRET_NAME}" -n "${NAMESPACE}" -o jsonpath='{.data.HTTPS_PROXY}' 2>/dev/null || true)"
[[ -z "${https_proxy_secret_b64}" ]] && https_proxy_secret_b64="$(oc get secret "${PROXY_SECRET_NAME}" -n "${NAMESPACE}" -o jsonpath='{.data.https_proxy}' 2>/dev/null || true)"
no_proxy_secret_b64="$(oc get secret "${PROXY_SECRET_NAME}" -n "${NAMESPACE}" -o jsonpath='{.data.NO_PROXY}' 2>/dev/null || true)"
[[ -z "${no_proxy_secret_b64}" ]] && no_proxy_secret_b64="$(oc get secret "${PROXY_SECRET_NAME}" -n "${NAMESPACE}" -o jsonpath='{.data.no_proxy}' 2>/dev/null || true)"

# Ensure vwgroup.com is in NO_PROXY so the token-refresher sidecar can reach
# idp.cloud.vwgroup.com without going through the corporate proxy. Idempotent.
existing_no_proxy_value="$(printf '%s' "${no_proxy_secret_b64:-}" | base64 --decode 2>/dev/null || true)"
if [[ -n "${existing_no_proxy_value}" ]] && ! [[ "${existing_no_proxy_value}" =~ (^|,)vwgroup\.com($|,) ]]; then
  existing_no_proxy_value="${existing_no_proxy_value%,},vwgroup.com"
  no_proxy_secret_b64="$(printf '%s' "${existing_no_proxy_value}" | base64 | tr -d '\n')"
fi

if [[ -z "${http_proxy_secret_b64}" || -z "${https_proxy_secret_b64}" ]]; then
  proxy_user_b64="$(oc get secret "${PROXY_SECRET_NAME}" -n "${NAMESPACE}" -o jsonpath='{.data.proxy-user}' 2>/dev/null || true)"
  proxy_password_b64="$(oc get secret "${PROXY_SECRET_NAME}" -n "${NAMESPACE}" -o jsonpath='{.data.proxy-password}' 2>/dev/null || true)"

  if [[ -z "${http_proxy_secret_b64}" ]]; then
    http_proxy_host_b64="$(oc get secret "${PROXY_SECRET_NAME}" -n "${NAMESPACE}" -o jsonpath='{.data.http-proxy-url}' 2>/dev/null || true)"
    http_proxy_port_b64="$(oc get secret "${PROXY_SECRET_NAME}" -n "${NAMESPACE}" -o jsonpath='{.data.http-proxy-port}' 2>/dev/null || true)"
    if [[ -n "${http_proxy_host_b64}" ]]; then
      http_proxy_host="$(printf '%s' "${http_proxy_host_b64}" | base64 --decode)"
      if [[ "${http_proxy_host}" != http://* && "${http_proxy_host}" != https://* ]]; then
        http_proxy_host="http://${http_proxy_host}"
      fi

      if [[ "${http_proxy_host}" == *"@"* ]]; then
        http_proxy_value="${http_proxy_host}"
      elif [[ -n "${proxy_user_b64}" && -n "${proxy_password_b64}" ]]; then
        proxy_user="$(printf '%s' "${proxy_user_b64}" | base64 --decode)"
        proxy_password="$(printf '%s' "${proxy_password_b64}" | base64 --decode)"
        http_proxy_host_no_scheme="${http_proxy_host#http://}"
        http_proxy_host_no_scheme="${http_proxy_host_no_scheme#https://}"
        http_proxy_value="http://${proxy_user}:${proxy_password}@${http_proxy_host_no_scheme}"
      else
        http_proxy_value="${http_proxy_host}"
      fi

      if [[ -n "${http_proxy_port_b64}" ]] && [[ ! "${http_proxy_value}" =~ :[0-9]+$ ]]; then
        http_proxy_port="$(printf '%s' "${http_proxy_port_b64}" | base64 --decode)"
        http_proxy_value="${http_proxy_value}:${http_proxy_port}"
      fi
      http_proxy_secret_b64="$(printf '%s' "${http_proxy_value}" | base64 | tr -d '\n')"
    fi
  fi

  if [[ -z "${https_proxy_secret_b64}" ]]; then
    https_proxy_host_b64="$(oc get secret "${PROXY_SECRET_NAME}" -n "${NAMESPACE}" -o jsonpath='{.data.https-proxy-url}' 2>/dev/null || true)"
    https_proxy_port_b64="$(oc get secret "${PROXY_SECRET_NAME}" -n "${NAMESPACE}" -o jsonpath='{.data.https-proxy-port}' 2>/dev/null || true)"
    if [[ -n "${https_proxy_host_b64}" ]]; then
      https_proxy_host="$(printf '%s' "${https_proxy_host_b64}" | base64 --decode)"
      if [[ "${https_proxy_host}" != http://* && "${https_proxy_host}" != https://* ]]; then
        https_proxy_host="https://${https_proxy_host}"
      fi

      if [[ "${https_proxy_host}" == *"@"* ]]; then
        https_proxy_value="${https_proxy_host}"
      elif [[ -n "${proxy_user_b64}" && -n "${proxy_password_b64}" ]]; then
        proxy_user="$(printf '%s' "${proxy_user_b64}" | base64 --decode)"
        proxy_password="$(printf '%s' "${proxy_password_b64}" | base64 --decode)"
        https_proxy_host_no_scheme="${https_proxy_host#http://}"
        https_proxy_host_no_scheme="${https_proxy_host_no_scheme#https://}"
        https_proxy_value="https://${proxy_user}:${proxy_password}@${https_proxy_host_no_scheme}"
      else
        https_proxy_value="${https_proxy_host}"
      fi

      if [[ -n "${https_proxy_port_b64}" ]] && [[ ! "${https_proxy_value}" =~ :[0-9]+$ ]]; then
        https_proxy_port="$(printf '%s' "${https_proxy_port_b64}" | base64 --decode)"
        https_proxy_value="${https_proxy_value}:${https_proxy_port}"
      fi
      https_proxy_secret_b64="$(printf '%s' "${https_proxy_value}" | base64 | tr -d '\n')"
    fi
  fi
fi

if [[ -n "${http_proxy_secret_b64}" ]]; then
  oc patch secret "${APP_NAME}-secrets" -n "${NAMESPACE}" --type=merge \
    -p '{"data":{"HTTP_PROXY":"'"${http_proxy_secret_b64}"'"}}' >/dev/null
fi
if [[ -n "${https_proxy_secret_b64}" ]]; then
  oc patch secret "${APP_NAME}-secrets" -n "${NAMESPACE}" --type=merge \
    -p '{"data":{"HTTPS_PROXY":"'"${https_proxy_secret_b64}"'"}}' >/dev/null
fi
if [[ -n "${no_proxy_secret_b64}" ]]; then
  oc patch secret "${APP_NAME}-secrets" -n "${NAMESPACE}" --type=merge \
    -p '{"data":{"NO_PROXY":"'"${no_proxy_secret_b64}"'"}}' >/dev/null
fi

echo "Applying Deployment..."
if [[ -n "${IMAGE_PULL_SECRET}" ]]; then
cat <<EOF | oc apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${APP_NAME}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: ${APP_NAME}
spec:
  replicas: ${REPLICAS}
  selector:
    matchLabels:
      app.kubernetes.io/name: ${APP_NAME}
  template:
    metadata:
      labels:
        app.kubernetes.io/name: ${APP_NAME}
    spec:
      imagePullSecrets:
        - name: ${IMAGE_PULL_SECRET}
      serviceAccountName: ${APP_NAME}
      containers:
        - name: hermes
          image: ${HERMES_IMAGE}
          imagePullPolicy: ${IMAGE_PULL_POLICY}
          ports:
            - name: dashboard
              containerPort: ${HERMES_DASHBOARD_PORT}
              protocol: TCP
          envFrom:
            - configMapRef:
                name: ${APP_NAME}-config
            - secretRef:
                name: ${APP_NAME}-secrets
          command: ["/bin/sh", "-c"]
          args:
            - |
              set -eu
              mkdir -p "${HERMES_HOME}"
              if [ ! -f "${HERMES_HOME}/config.yaml" ] && { [ -n "${HERMES_INFERENCE_PROVIDER}" ] || [ -n "${HERMES_INFERENCE_MODEL}" ] || [ -n "${AZURE_FOUNDRY_BASE_URL}" ]; }; then
                printf 'model:\n' > "${HERMES_HOME}/config.yaml"
                printf '  provider: %s\n' "${HERMES_INFERENCE_PROVIDER:-auto}" >> "${HERMES_HOME}/config.yaml"
                printf '  default: %s\n' "${HERMES_INFERENCE_MODEL}" >> "${HERMES_HOME}/config.yaml"
                if [ -n "${AZURE_FOUNDRY_BASE_URL}" ]; then
                  printf '  base_url: %s\n' "${AZURE_FOUNDRY_BASE_URL}" >> "${HERMES_HOME}/config.yaml"
                fi
                if [ -n "${HERMES_INFERENCE_API_MODE}" ]; then
                  printf '  api_mode: %s\n' "${HERMES_INFERENCE_API_MODE}" >> "${HERMES_HOME}/config.yaml"
                elif [ "${HERMES_INFERENCE_PROVIDER}" = "azure-foundry" ]; then
                  printf '  api_mode: %s\n' 'chat_completions' >> "${HERMES_HOME}/config.yaml"
                fi
                if [ -n "${LLMAAS_VIRTUAL_KEY:-}" ]; then
                  printf '  default_headers:\n' >> "${HERMES_HOME}/config.yaml"
                  printf '    X-LLM-API-CLIENT-ID: "Bearer %s"\n' "${LLMAAS_VIRTUAL_KEY}" >> "${HERMES_HOME}/config.yaml"
                fi
                printf 'auxiliary:\n' >> "${HERMES_HOME}/config.yaml"
                printf '  compression:\n' >> "${HERMES_HOME}/config.yaml"
                if [ -n "${HERMES_INFERENCE_PROVIDER}" ]; then
                  printf '    provider: %s\n' "${HERMES_INFERENCE_PROVIDER}" >> "${HERMES_HOME}/config.yaml"
                fi
                if [ -n "${HERMES_INFERENCE_MODEL}" ]; then
                  printf '    model: %s\n' "${HERMES_INFERENCE_MODEL}" >> "${HERMES_HOME}/config.yaml"
                fi
                if [ -n "${AZURE_FOUNDRY_BASE_URL}" ]; then
                  printf '    base_url: %s\n' "${AZURE_FOUNDRY_BASE_URL}" >> "${HERMES_HOME}/config.yaml"
                fi
                if [ -n "${HERMES_INFERENCE_API_MODE}" ]; then
                  printf '    api_mode: %s\n' "${HERMES_INFERENCE_API_MODE}" >> "${HERMES_HOME}/config.yaml"
                elif [ "${HERMES_INFERENCE_PROVIDER}" = "azure-foundry" ]; then
                  printf '    api_mode: %s\n' 'chat_completions' >> "${HERMES_HOME}/config.yaml"
                fi
                if [ -n "${LLMAAS_VIRTUAL_KEY:-}" ]; then
                  printf '    default_headers:\n' >> "${HERMES_HOME}/config.yaml"
                  printf '      X-LLM-API-CLIENT-ID: "Bearer %s"\n' "${LLMAAS_VIRTUAL_KEY}" >> "${HERMES_HOME}/config.yaml"
                fi
              fi
              case "${HERMES_RUN_MODE}" in
                gateway)
                  /opt/hermes/hermes-agent/venv/bin/python -c "import telegram" >/dev/null 2>&1 \
                    || /opt/hermes/hermes-agent/venv/bin/pip install --no-cache-dir python-telegram-bot
                  exec hermes gateway
                  ;;
                chat)
                  exec hermes
                  ;;
                dashboard)
                  exec hermes dashboard --host 0.0.0.0 --port "${HERMES_DASHBOARD_PORT}" --no-open --insecure
                  ;;
                idle)
                  exec tail -f /dev/null
                  ;;
                *)
                  echo "Unsupported HERMES_RUN_MODE=${HERMES_RUN_MODE}" >&2
                  exit 1
                  ;;
              esac
          securityContext:
            allowPrivilegeEscalation: false
            runAsNonRoot: true
            capabilities:
              drop: ["ALL"]
            seccompProfile:
              type: RuntimeDefault
        - name: token-refresher
          image: ${HERMES_IMAGE}
          imagePullPolicy: ${IMAGE_PULL_POLICY}
          env:
            - name: TARGET_NAMESPACE
              value: "${NAMESPACE}"
            - name: TARGET_SECRET_NAME
              value: "${APP_NAME}-secrets"
            - name: TARGET_DEPLOYMENT_NAME
              value: "${APP_NAME}"
            - name: REFRESH_INTERVAL_SECONDS
              value: "${REFRESH_INTERVAL_SECONDS:-1500}"
            - name: RETRY_INTERVAL_SECONDS
              value: "${RETRY_INTERVAL_SECONDS:-60}"
            - name: INITIAL_DELAY_SECONDS
              value: "${INITIAL_DELAY_SECONDS:-5}"
            - name: MIRROR_TO_ANTHROPIC
              value: "${MIRROR_TO_ANTHROPIC:-true}"
          envFrom:
            - secretRef:
                name: ${APP_NAME}-secrets
          command: ["/bin/sh", "-c"]
          args:
            - exec python3 -u /usr/local/bin/llmaas-token-refresher.py
          securityContext:
            allowPrivilegeEscalation: false
            runAsNonRoot: true
            capabilities:
              drop: ["ALL"]
            seccompProfile:
              type: RuntimeDefault
          resources:
            requests:
              cpu: 10m
              memory: 32Mi
            limits:
              cpu: 50m
              memory: 64Mi
          volumeMounts:
            - name: hermes-home
              mountPath: ${HERMES_HOME}
      volumes:
        - name: hermes-home
          persistentVolumeClaim:
            claimName: ${PVC_NAME}
EOF
else
cat <<EOF | oc apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${APP_NAME}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: ${APP_NAME}
spec:
  replicas: ${REPLICAS}
  selector:
    matchLabels:
      app.kubernetes.io/name: ${APP_NAME}
  template:
    metadata:
      labels:
        app.kubernetes.io/name: ${APP_NAME}
    spec:
      serviceAccountName: ${APP_NAME}
      containers:
        - name: hermes
          image: ${HERMES_IMAGE}
          imagePullPolicy: ${IMAGE_PULL_POLICY}
          ports:
            - name: dashboard
              containerPort: ${HERMES_DASHBOARD_PORT}
              protocol: TCP
          envFrom:
            - configMapRef:
                name: ${APP_NAME}-config
            - secretRef:
                name: ${APP_NAME}-secrets
          command: ["/bin/sh", "-c"]
          args:
            - |
              set -eu
              mkdir -p "${HERMES_HOME}"
              if [ ! -f "${HERMES_HOME}/config.yaml" ] && { [ -n "${HERMES_INFERENCE_PROVIDER}" ] || [ -n "${HERMES_INFERENCE_MODEL}" ] || [ -n "${AZURE_FOUNDRY_BASE_URL}" ]; }; then
                printf 'model:\n' > "${HERMES_HOME}/config.yaml"
                printf '  provider: %s\n' "${HERMES_INFERENCE_PROVIDER:-auto}" >> "${HERMES_HOME}/config.yaml"
                printf '  default: %s\n' "${HERMES_INFERENCE_MODEL}" >> "${HERMES_HOME}/config.yaml"
                if [ -n "${AZURE_FOUNDRY_BASE_URL}" ]; then
                  printf '  base_url: %s\n' "${AZURE_FOUNDRY_BASE_URL}" >> "${HERMES_HOME}/config.yaml"
                fi
                if [ -n "${HERMES_INFERENCE_API_MODE}" ]; then
                  printf '  api_mode: %s\n' "${HERMES_INFERENCE_API_MODE}" >> "${HERMES_HOME}/config.yaml"
                elif [ "${HERMES_INFERENCE_PROVIDER}" = "azure-foundry" ]; then
                  printf '  api_mode: %s\n' 'chat_completions' >> "${HERMES_HOME}/config.yaml"
                fi
                if [ -n "${LLMAAS_VIRTUAL_KEY:-}" ]; then
                  printf '  default_headers:\n' >> "${HERMES_HOME}/config.yaml"
                  printf '    X-LLM-API-CLIENT-ID: "Bearer %s"\n' "${LLMAAS_VIRTUAL_KEY}" >> "${HERMES_HOME}/config.yaml"
                fi
                printf 'auxiliary:\n' >> "${HERMES_HOME}/config.yaml"
                printf '  compression:\n' >> "${HERMES_HOME}/config.yaml"
                if [ -n "${HERMES_INFERENCE_PROVIDER}" ]; then
                  printf '    provider: %s\n' "${HERMES_INFERENCE_PROVIDER}" >> "${HERMES_HOME}/config.yaml"
                fi
                if [ -n "${HERMES_INFERENCE_MODEL}" ]; then
                  printf '    model: %s\n' "${HERMES_INFERENCE_MODEL}" >> "${HERMES_HOME}/config.yaml"
                fi
                if [ -n "${AZURE_FOUNDRY_BASE_URL}" ]; then
                  printf '    base_url: %s\n' "${AZURE_FOUNDRY_BASE_URL}" >> "${HERMES_HOME}/config.yaml"
                fi
                if [ -n "${HERMES_INFERENCE_API_MODE}" ]; then
                  printf '    api_mode: %s\n' "${HERMES_INFERENCE_API_MODE}" >> "${HERMES_HOME}/config.yaml"
                elif [ "${HERMES_INFERENCE_PROVIDER}" = "azure-foundry" ]; then
                  printf '    api_mode: %s\n' 'chat_completions' >> "${HERMES_HOME}/config.yaml"
                fi
                if [ -n "${LLMAAS_VIRTUAL_KEY:-}" ]; then
                  printf '    default_headers:\n' >> "${HERMES_HOME}/config.yaml"
                  printf '      X-LLM-API-CLIENT-ID: "Bearer %s"\n' "${LLMAAS_VIRTUAL_KEY}" >> "${HERMES_HOME}/config.yaml"
                fi
              fi
              case "${HERMES_RUN_MODE}" in
                gateway)
                  /opt/hermes/hermes-agent/venv/bin/python -c "import telegram" >/dev/null 2>&1 \
                    || /opt/hermes/hermes-agent/venv/bin/pip install --no-cache-dir python-telegram-bot
                  exec hermes gateway
                  ;;
                chat)
                  exec hermes
                  ;;
                dashboard)
                  exec hermes dashboard --host 0.0.0.0 --port "${HERMES_DASHBOARD_PORT}" --no-open --insecure
                  ;;
                idle)
                  exec tail -f /dev/null
                  ;;
                *)
                  echo "Unsupported HERMES_RUN_MODE=${HERMES_RUN_MODE}" >&2
                  exit 1
                  ;;
              esac
          securityContext:
            allowPrivilegeEscalation: false
            runAsNonRoot: true
            capabilities:
              drop: ["ALL"]
            seccompProfile:
              type: RuntimeDefault
        - name: token-refresher
          image: ${HERMES_IMAGE}
          imagePullPolicy: ${IMAGE_PULL_POLICY}
          env:
            - name: TARGET_NAMESPACE
              value: "${NAMESPACE}"
            - name: TARGET_SECRET_NAME
              value: "${APP_NAME}-secrets"
            - name: TARGET_DEPLOYMENT_NAME
              value: "${APP_NAME}"
            - name: REFRESH_INTERVAL_SECONDS
              value: "${REFRESH_INTERVAL_SECONDS:-1500}"
            - name: RETRY_INTERVAL_SECONDS
              value: "${RETRY_INTERVAL_SECONDS:-60}"
            - name: INITIAL_DELAY_SECONDS
              value: "${INITIAL_DELAY_SECONDS:-5}"
            - name: MIRROR_TO_ANTHROPIC
              value: "${MIRROR_TO_ANTHROPIC:-true}"
          envFrom:
            - secretRef:
                name: ${APP_NAME}-secrets
          command: ["/bin/sh", "-c"]
          args:
            - exec python3 -u /usr/local/bin/llmaas-token-refresher.py
          securityContext:
            allowPrivilegeEscalation: false
            runAsNonRoot: true
            capabilities:
              drop: ["ALL"]
            seccompProfile:
              type: RuntimeDefault
          resources:
            requests:
              cpu: 10m
              memory: 32Mi
            limits:
              cpu: 50m
              memory: 64Mi
          volumeMounts:
            - name: hermes-home
              mountPath: ${HERMES_HOME}
      volumes:
        - name: hermes-home
          persistentVolumeClaim:
            claimName: ${PVC_NAME}
EOF
fi

if [[ "${HERMES_RUN_MODE}" == "dashboard" ]]; then
echo "Applying Service..."
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Service
metadata:
  name: ${APP_NAME}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: ${APP_NAME}
spec:
  selector:
    app.kubernetes.io/name: ${APP_NAME}
  ports:
    - name: http
      port: ${HERMES_DASHBOARD_PORT}
      targetPort: dashboard
      protocol: TCP
EOF

echo "Applying Route..."
cat <<EOF | oc apply -f -
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: ${APP_NAME}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: ${APP_NAME}
spec:
  to:
    kind: Service
    name: ${APP_NAME}
  port:
    targetPort: http
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
EOF
else
  echo "Gateway mode detected; removing dashboard Service/Route if present..."
  oc delete route "${APP_NAME}" -n "${NAMESPACE}" --ignore-not-found=true >/dev/null
  oc delete service "${APP_NAME}" -n "${NAMESPACE}" --ignore-not-found=true >/dev/null
fi

echo "Clearing stale config.yaml so hermes regenerates it with updated settings..."
oc exec deployment/"${APP_NAME}" -n "${NAMESPACE}" -- rm -f "${HERMES_HOME}/config.yaml" 2>/dev/null || true

echo "Triggering fresh rollout to pick up new config..."
oc rollout restart deployment/"${APP_NAME}" -n "${NAMESPACE}" >/dev/null

echo "Waiting for rollout..."
oc rollout status deployment/"${APP_NAME}" --timeout=180s

ROUTE_URL=""
if [[ "${HERMES_RUN_MODE}" == "dashboard" ]]; then
  ROUTE_URL="$(oc get route "${APP_NAME}" -n "${NAMESPACE}" -o jsonpath='https://{.spec.host}' 2>/dev/null || true)"
fi

echo "Deployment completed in namespace ${NAMESPACE}."
if [[ -n "${ROUTE_URL}" ]]; then
  echo "Route URL: ${ROUTE_URL}"
fi
echo "Next: run scripts/ocp-verify-hermes.sh ${ENV_FILE}"
