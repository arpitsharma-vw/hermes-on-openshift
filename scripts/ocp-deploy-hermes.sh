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
HTTP_PROXY="${HTTP_PROXY:-}"
HTTPS_PROXY="${HTTPS_PROXY:-}"
NO_PROXY="${NO_PROXY:-}"
NODE_USE_ENV_PROXY="${NODE_USE_ENV_PROXY:-1}"
IMAGE_PULL_SECRET="${IMAGE_PULL_SECRET:-}"

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
  HERMES_RUN_MODE: "${HERMES_RUN_MODE}"
  NODE_USE_ENV_PROXY: "${NODE_USE_ENV_PROXY}"
  HTTP_PROXY: "${HTTP_PROXY}"
  HTTPS_PROXY: "${HTTPS_PROXY}"
  NO_PROXY: "${NO_PROXY}"
EOF

echo "Applying Secret..."
secret_args=()
[[ -n "${OPENAI_API_KEY:-}" ]] && secret_args+=(--from-literal=OPENAI_API_KEY="${OPENAI_API_KEY}")
[[ -n "${OPENROUTER_API_KEY:-}" ]] && secret_args+=(--from-literal=OPENROUTER_API_KEY="${OPENROUTER_API_KEY}")
[[ -n "${ANTHROPIC_API_KEY:-}" ]] && secret_args+=(--from-literal=ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY}")
[[ -n "${GH_TOKEN:-}" ]] && secret_args+=(--from-literal=GH_TOKEN="${GH_TOKEN}")
[[ -n "${TELEGRAM_BOT_TOKEN:-}" ]] && secret_args+=(--from-literal=TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN}")
[[ -n "${SLACK_BOT_TOKEN:-}" ]] && secret_args+=(--from-literal=SLACK_BOT_TOKEN="${SLACK_BOT_TOKEN}")
[[ -n "${DISCORD_BOT_TOKEN:-}" ]] && secret_args+=(--from-literal=DISCORD_BOT_TOKEN="${DISCORD_BOT_TOKEN}")

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

echo "Applying Deployment..."
IMAGE_PULL_SECRETS_YAML=""
if [[ -n "${IMAGE_PULL_SECRET}" ]]; then
  IMAGE_PULL_SECRETS_YAML="\n      imagePullSecrets:\n        - name: ${IMAGE_PULL_SECRET}"
fi

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
    spec:${IMAGE_PULL_SECRETS_YAML}
      serviceAccountName: ${APP_NAME}
      securityContext:
        fsGroup: 1001
      containers:
        - name: hermes
          image: ${HERMES_IMAGE}
          imagePullPolicy: ${IMAGE_PULL_POLICY}
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
              case "${HERMES_RUN_MODE}" in
                gateway)
                  exec hermes gateway
                  ;;
                chat)
                  exec hermes
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
          volumeMounts:
            - name: hermes-home
              mountPath: ${HERMES_HOME}
      volumes:
        - name: hermes-home
          persistentVolumeClaim:
            claimName: ${PVC_NAME}
EOF

echo "Waiting for rollout..."
oc rollout status deployment/"${APP_NAME}" --timeout=180s

echo "Deployment completed in namespace ${NAMESPACE}."
echo "Next: run scripts/ocp-verify-hermes.sh ${ENV_FILE}"
