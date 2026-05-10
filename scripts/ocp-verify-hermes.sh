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

# Do not route oc CLI traffic through deployment proxy settings.
unset HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy

NAMESPACE="${NAMESPACE:-hermes-agent}"
APP_NAME="${APP_NAME:-hermes-agent}"

oc project "${NAMESPACE}" >/dev/null

echo "Checking deployment rollout..."
oc rollout status deployment/"${APP_NAME}" --timeout=180s

echo "Checking pod status..."
oc get pods -l app.kubernetes.io/name="${APP_NAME}" -o wide

POD_NAME="$(oc get pods -l app.kubernetes.io/name="${APP_NAME}" -o jsonpath='{.items[0].metadata.name}')"
if [[ -z "${POD_NAME}" ]]; then
  echo "No pod found for app ${APP_NAME}" >&2
  exit 1
fi

echo "Showing recent logs..."
oc logs "${POD_NAME}" --tail=100 || true

echo "Running hermes doctor inside pod..."
oc exec "${POD_NAME}" -- hermes doctor || true

echo "Verification completed for ${APP_NAME} in ${NAMESPACE}."
