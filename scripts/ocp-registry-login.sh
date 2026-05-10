#!/usr/bin/env bash
set -euo pipefail

if ! command -v oc >/dev/null 2>&1; then
  echo "OpenShift CLI (oc) is required." >&2
  exit 1
fi

if command -v podman >/dev/null 2>&1; then
  CLIENT="podman"
elif command -v docker >/dev/null 2>&1; then
  CLIENT="docker"
else
  echo "Neither podman nor docker is available." >&2
  exit 1
fi

TOKEN="$(oc whoami -t)"
if [[ -z "${TOKEN}" ]]; then
  echo "Unable to get OpenShift token. Ensure you are logged in with oc login." >&2
  exit 1
fi

REGISTRY_HOST="image-registry.openshift-image-registry.svc:5000"
if oc get route default-route -n openshift-image-registry >/dev/null 2>&1; then
  REGISTRY_HOST="$(oc get route default-route -n openshift-image-registry -o jsonpath='{.spec.host}')"
fi

echo "Logging in to ${REGISTRY_HOST} with ${CLIENT}"
echo "${TOKEN}" | "${CLIENT}" login -u "$(oc whoami)" --password-stdin "${REGISTRY_HOST}"

echo "Registry login succeeded."
echo "Use image names like: ${REGISTRY_HOST}/<namespace>/hermes-agent:latest"
