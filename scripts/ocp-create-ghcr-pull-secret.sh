#!/usr/bin/env bash
set -euo pipefail

if ! command -v oc >/dev/null 2>&1; then
  echo "OpenShift CLI (oc) is required." >&2
  exit 1
fi

NAMESPACE="${1:-${NAMESPACE:-}}"
SECRET_NAME="${2:-${IMAGE_PULL_SECRET:-ghcr-pull-secret}}"
GHCR_USERNAME="${GHCR_USERNAME:-}"
GHCR_TOKEN="${GHCR_TOKEN:-}"

if [[ -z "${NAMESPACE}" ]]; then
  echo "Usage: $0 <namespace> [secret-name]" >&2
  echo "Or export NAMESPACE before running." >&2
  exit 1
fi

if [[ -z "${GHCR_USERNAME}" || -z "${GHCR_TOKEN}" ]]; then
  echo "Set GHCR_USERNAME and GHCR_TOKEN environment variables first." >&2
  echo "GHCR_TOKEN should be a token with read:packages scope." >&2
  exit 1
fi

oc project "${NAMESPACE}" >/dev/null

oc create secret docker-registry "${SECRET_NAME}" \
  --docker-server=ghcr.io \
  --docker-username="${GHCR_USERNAME}" \
  --docker-password="${GHCR_TOKEN}" \
  --namespace "${NAMESPACE}" \
  --dry-run=client -o yaml | oc apply -f -

echo "Created/updated image pull secret ${SECRET_NAME} in namespace ${NAMESPACE}."
