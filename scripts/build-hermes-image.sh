#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${1:-${ROOT_DIR}/openshift/hermes.env}"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "Missing env file: ${ENV_FILE}" >&2
  echo "Create it from: ${ROOT_DIR}/openshift/hermes.env.example" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

HERMES_IMAGE="${HERMES_IMAGE:-}"
if [[ -z "${HERMES_IMAGE}" ]]; then
  echo "HERMES_IMAGE must be set in ${ENV_FILE}" >&2
  exit 1
fi

if command -v podman >/dev/null 2>&1; then
  BUILDER="podman"
elif command -v docker >/dev/null 2>&1; then
  BUILDER="docker"
else
  echo "Neither podman nor docker is available." >&2
  exit 1
fi

echo "Using ${BUILDER} to build image ${HERMES_IMAGE}"
"${BUILDER}" build -f "${ROOT_DIR}/Containerfile" -t "${HERMES_IMAGE}" "${ROOT_DIR}"

echo "Running quick image smoke test..."
"${BUILDER}" run --rm --entrypoint /bin/sh "${HERMES_IMAGE}" -c "command -v hermes >/dev/null && test -x /usr/local/bin/hermes"

if [[ "${NO_PUSH:-0}" == "1" ]]; then
  echo "NO_PUSH=1 set; skipping push."
  exit 0
fi

echo "Pushing ${HERMES_IMAGE}"
"${BUILDER}" push "${HERMES_IMAGE}"

echo "Image build and push complete: ${HERMES_IMAGE}"
