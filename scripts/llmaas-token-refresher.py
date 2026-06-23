#!/usr/bin/env python3
"""LLMAAS OAuth2 token refresher sidecar.

Periodically fetches a fresh access token from the LLMAAS OAuth2
client_credentials endpoint, base64-encodes it, patches a target
Kubernetes/OpenShift Secret, and triggers a rolling restart of the target
Deployment. Designed to run as a sidecar container in the same pod as the
agent/dashboard that consumes the token.

Stdlib only (no pip dependencies). Reads tunables from environment variables;
see main() for the env var contract.
"""
import base64
import json
import os
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request


# Required env vars (must be set, otherwise sidecar exits and is restarted).
REQUIRED_ENV_VARS = (
    "LLMAAS_TOKEN_URL",
    "LLMAAS_CLIENT_ID",
    "LLMAAS_CLIENT_SECRET",
    "TARGET_SECRET_NAME",
    "TARGET_DEPLOYMENT_NAME",
)

# Defaults applied if the corresponding env var is unset.
DEFAULT_REFRESH_INTERVAL_SECONDS = 1500  # 25 min — token TTL is ~30 min.
DEFAULT_RETRY_INTERVAL_SECONDS = 60
DEFAULT_INITIAL_DELAY_SECONDS = 5

# Network / subprocess timeouts (seconds).
HTTP_TIMEOUT_SECONDS = 15
OC_TIMEOUT_SECONDS = 30

# Kubernetes well-known path to the pod's namespace (Downward API alternative).
SA_NAMESPACE_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/namespace"


def log(level, msg):
    """Print one RFC3339-UTC log line to stdout, flushed immediately.

    Never call this with a token, secret, or credential value. Only metadata
    (lengths, status codes, error classes) is safe to log.
    """
    print(
        f"{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())} {level} {msg}",
        flush=True,
    )


def fetch_token(token_url, client_id, client_secret):
    """POST OAuth2 client_credentials to token_url.

    Returns (access_token, expires_in_seconds). Raises on failure:
      - RuntimeError: HTTP 4xx/5xx, unexpected status, or response missing
        'access_token'.
      - urllib.error.URLError: network-level failure (timeout, DNS, refused).
      - json.JSONDecodeError: response body is not valid JSON.
    """
    data = urllib.parse.urlencode({
        "grant_type": "client_credentials",
        "client_id": client_id,
        "client_secret": client_secret,
    }).encode("utf-8")
    req = urllib.request.Request(token_url, data=data, method="POST")
    req.add_header("Content-Type", "application/x-www-form-urlencoded")
    req.add_header("Accept", "application/json")
    try:
        resp = urllib.request.urlopen(req, timeout=HTTP_TIMEOUT_SECONDS)
    except urllib.error.HTTPError as e:
        # 4xx/5xx: convert to RuntimeError so callers can treat uniformly.
        # The body of the error response may contain details but is not safe
        # to log in full (could echo back client_id etc.).
        raise RuntimeError(f"token endpoint returned HTTP {e.code}") from e
    # Other URLError subclasses (timeout, DNS, refused) propagate as-is.
    with resp:
        status = resp.status
        raw = resp.read()
    if status != 200:
        raise RuntimeError(f"token endpoint returned HTTP {status}")
    body = json.loads(raw)
    if "access_token" not in body:
        raise RuntimeError(
            f"token response missing access_token: {sorted(body.keys())}"
        )
    return body["access_token"], int(body.get("expires_in", 1800))


def b64(s):
    """Base64-encode a UTF-8 string for use as a k8s Secret data field."""
    return base64.b64encode(s.encode("utf-8")).decode("ascii")


def patch_secret(secret_name, namespace, foundry_b64, anthropic_b64=None):
    """Patch AZURE_FOUNDRY_API_KEY (and optionally AZURE_ANTHROPIC_KEY) on a Secret.

    Uses 'oc patch secret --type=merge' with a JSON merge patch payload.
    Raises subprocess.CalledProcessError if the oc command fails.
    """
    patch = {"data": {"AZURE_FOUNDRY_API_KEY": foundry_b64}}
    if anthropic_b64 is not None:
        patch["data"]["AZURE_ANTHROPIC_KEY"] = anthropic_b64
    patch_json = json.dumps(patch)
    subprocess.run(
        [
            "oc", "-n", namespace, "patch", "secret", secret_name,
            "--type=merge", "-p", patch_json,
        ],
        check=True, capture_output=True, timeout=OC_TIMEOUT_SECONDS,
    )


def restart_deployment(deployment_name, namespace):
    """Trigger a rolling restart by writing the kubectl restartedAt annotation.

    Kubernetes treats a change to this annotation as a rolling-restart trigger.
    Raises subprocess.CalledProcessError if the oc command fails.
    """
    annotation = json.dumps({
        "metadata": {
            "annotations": {
                "kubectl.kubernetes.io/restartedAt": time.strftime(
                    "%Y-%m-%dT%H:%M:%SZ", time.gmtime()
                ),
            },
        },
    })
    subprocess.run(
        [
            "oc", "-n", namespace, "patch", "deployment",
            deployment_name, "-p", annotation,
        ],
        check=True, capture_output=True, timeout=OC_TIMEOUT_SECONDS,
    )


def _detect_namespace():
    """Best-effort: read namespace from SA token path, then env, then 'default'."""
    try:
        if os.path.exists(SA_NAMESPACE_PATH):
            with open(SA_NAMESPACE_PATH, "r", encoding="utf-8") as f:
                value = f.read().strip()
            if value:
                return value
    except OSError:
        # Permission denied, I/O error, etc. — fall through to fallbacks.
        pass
    return os.environ.get("TARGET_NAMESPACE") or "default"


def refresh_once(env):
    """One full refresh cycle: fetch -> patch secret -> restart deployment.

    Returns True on success, False on any retryable failure. Never raises.
    """
    token_url = env["LLMAAS_TOKEN_URL"]
    client_id = env["LLMAAS_CLIENT_ID"]
    client_secret = env["LLMAAS_CLIENT_SECRET"]
    secret_name = env["TARGET_SECRET_NAME"]
    deployment_name = env["TARGET_DEPLOYMENT_NAME"]
    namespace = env.get("TARGET_NAMESPACE") or _detect_namespace()
    mirror_anthropic = env.get("MIRROR_TO_ANTHROPIC", "true").lower() == "true"

    try:
        token, expires_in = fetch_token(token_url, client_id, client_secret)
    except (
        urllib.error.URLError,
        urllib.error.HTTPError,
        RuntimeError,
        json.JSONDecodeError,
        OSError,
    ) as e:
        log("ERROR", f"token fetch failed: {type(e).__name__}: {e}")
        return False

    log("INFO", f"token fetched (expires_in={expires_in}s, length={len(token)})")
    foundry_b64 = b64(token)
    anthropic_b64 = b64(token) if mirror_anthropic else None

    try:
        patch_secret(secret_name, namespace, foundry_b64, anthropic_b64)
    except subprocess.CalledProcessError as e:
        stderr = (e.stderr or b"").decode(errors="replace")[:300]
        log("ERROR", f"secret patch failed (rc={e.returncode}): {stderr}")
        return False
    log("INFO", f"patched secret {namespace}/{secret_name}")

    try:
        restart_deployment(deployment_name, namespace)
    except subprocess.CalledProcessError as e:
        stderr = (e.stderr or b"").decode(errors="replace")[:300]
        log("ERROR", f"deployment restart failed (rc={e.returncode}): {stderr}")
        return False
    log("INFO", f"triggered rolling restart of {namespace}/{deployment_name}")
    return True


def main():
    """Run forever: every REFRESH_INTERVAL_SECONDS, refresh token + restart."""
    # Collect every env var this script cares about (required + optional).
    # Optional ones default via setdefault below. This dict is then passed
    # into refresh_once() so all values come from one consistent source.
    all_keys = REQUIRED_ENV_VARS + (
        "REFRESH_INTERVAL_SECONDS",
        "RETRY_INTERVAL_SECONDS",
        "INITIAL_DELAY_SECONDS",
        "MIRROR_TO_ANTHROPIC",
        "TARGET_NAMESPACE",
    )
    env = {k: os.environ[k] for k in all_keys if k in os.environ}
    env.setdefault("REFRESH_INTERVAL_SECONDS", str(DEFAULT_REFRESH_INTERVAL_SECONDS))
    env.setdefault("RETRY_INTERVAL_SECONDS", str(DEFAULT_RETRY_INTERVAL_SECONDS))
    env.setdefault("INITIAL_DELAY_SECONDS", str(DEFAULT_INITIAL_DELAY_SECONDS))

    refresh_every = int(env["REFRESH_INTERVAL_SECONDS"])
    retry_every = int(env["RETRY_INTERVAL_SECONDS"])
    initial_delay = int(env["INITIAL_DELAY_SECONDS"])

    log(
        "INFO",
        "refresher starting: "
        f"target={env.get('TARGET_DEPLOYMENT_NAME', '<unset>')}, "
        f"secret={env.get('TARGET_SECRET_NAME', '<unset>')}, "
        f"refresh={refresh_every}s, "
        f"retry={retry_every}s, "
        f"initial_delay={initial_delay}s",
    )
    time.sleep(initial_delay)

    while True:
        ok = refresh_once(env)
        time.sleep(refresh_every if ok else retry_every)


if __name__ == "__main__":
    main()
