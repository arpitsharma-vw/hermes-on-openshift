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
HTTP_PROXY="${HTTP_PROXY:-}"
HTTPS_PROXY="${HTTPS_PROXY:-}"
NO_PROXY="${NO_PROXY:-}"
NODE_USE_ENV_PROXY="${NODE_USE_ENV_PROXY:-1}"
IMAGE_PULL_SECRET="${IMAGE_PULL_SECRET:-}"

RUNTIME_HTTP_PROXY="${HTTP_PROXY}"
RUNTIME_HTTPS_PROXY="${HTTPS_PROXY}"
RUNTIME_NO_PROXY="${NO_PROXY}"

# Keep proxy values for ConfigMap data, but do not let oc CLI use them.
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
  HTTP_PROXY: "${RUNTIME_HTTP_PROXY}"
  HTTPS_PROXY: "${RUNTIME_HTTPS_PROXY}"
  NO_PROXY: "${RUNTIME_NO_PROXY}"
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
              case "${HERMES_RUN_MODE}" in
                gateway)
                  exec hermes gateway
                  ;;
                chat)
                  exec hermes
                  ;;
                dashboard)
                  # Bootstrap installs hermes-agent[web] (fastapi+uvicorn) on first start.
                  hermes --help >/dev/null 2>&1 || true
                  exec hermes dashboard --host 0.0.0.0 --port "${HERMES_DASHBOARD_PORT}" --no-open
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
              case "${HERMES_RUN_MODE}" in
                gateway)
                  exec hermes gateway
                  ;;
                chat)
                  exec hermes
                  ;;
                dashboard)
                  # Bootstrap installs hermes-agent[web] (fastapi+uvicorn) on first start.
                  hermes --help >/dev/null 2>&1 || true
                  exec hermes dashboard --host 0.0.0.0 --port "${HERMES_DASHBOARD_PORT}" --no-open
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
          volumeMounts:
            - name: hermes-home
              mountPath: ${HERMES_HOME}
      volumes:
        - name: hermes-home
          persistentVolumeClaim:
            claimName: ${PVC_NAME}
EOF
fi

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

echo "Waiting for rollout..."
oc rollout status deployment/"${APP_NAME}" --timeout=180s

ROUTE_URL="$(oc get route "${APP_NAME}" -n "${NAMESPACE}" -o jsonpath='https://{.spec.host}' 2>/dev/null || true)"

echo "Deployment completed in namespace ${NAMESPACE}."
if [[ -n "${ROUTE_URL}" ]]; then
  echo "Route URL: ${ROUTE_URL}"
fi
echo "Next: run scripts/ocp-verify-hermes.sh ${ENV_FILE}"
