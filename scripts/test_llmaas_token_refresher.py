"""Unit tests for llmaas-token-refresher.py.

Covers:
  - fetch_token: success, HTTP 400, HTTP 500, network error, malformed JSON,
    missing access_token, default expires_in.
  - patch_secret: success shape, anthropic_b64 omitted when None, CalledProcessError.
  - restart_deployment: success shape (annotation), CalledProcessError.
  - refresh_once: full-cycle success, failure on each step, MIRROR_TO_ANTHROPIC=false.
  - _detect_namespace: SA token path, env var fallback, default fallback.
  - main: initial-delay + refresh_every / retry_every sleep pattern; infinite loop.

No real network. No real oc. No sleep durations >1 second.
"""
import importlib.util
import json
import pathlib
import subprocess
import urllib.error
from unittest import mock

import pytest


# Load the script as a module. The filename contains a hyphen which is not a
# valid Python identifier, so we cannot use plain `import`. Loading via
# importlib gives us a real module object whose attributes we can patch and
# whose functions we can call directly.
SCRIPT_PATH = pathlib.Path(__file__).parent / "llmaas-token-refresher.py"
_SPEC = importlib.util.spec_from_file_location(
    "llmaas_token_refresher", SCRIPT_PATH
)
refresher = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(refresher)


# Minimal env for any test that calls functions reading os.environ.
def _base_env():
    return {
        "LLMAAS_TOKEN_URL": "https://example.test/token",
        "LLMAAS_CLIENT_ID": "test-client-id",
        "LLMAAS_CLIENT_SECRET": "test-client-secret",
        "TARGET_SECRET_NAME": "my-secret",
        "TARGET_DEPLOYMENT_NAME": "my-deploy",
        "TARGET_NAMESPACE": "my-ns",
    }


# ---------------------------------------------------------------------------
# fetch_token
# ---------------------------------------------------------------------------


class _FakeResponse:
    """Minimal context-manager-compatible HTTP response for urlopen mocks."""

    def __init__(self, status=200, body=b""):
        self.status = status
        self._body = body

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        return False

    def read(self):
        return self._body


def test_fetch_token_success_returns_token_and_expires_in():
    payload = json.dumps(
        {"access_token": "abc.def.ghi", "expires_in": 1234}
    ).encode("utf-8")
    with mock.patch(
        "urllib.request.urlopen", return_value=_FakeResponse(200, payload)
    ) as m_urlopen:
        token, expires_in = refresher.fetch_token(
            "https://example.test/token", "id", "secret"
        )
    assert token == "abc.def.ghi"
    assert expires_in == 1234
    # Verify the request shape.
    req = m_urlopen.call_args.args[0]
    assert req.get_full_url() == "https://example.test/token"
    assert req.get_method() == "POST"
    body = req.data.decode("utf-8")
    assert "grant_type=client_credentials" in body
    assert "client_id=id" in body
    assert "client_secret=secret" in body


def test_fetch_token_http_400_raises_runtime_error():
    err = urllib.error.HTTPError(
        "https://example.test/token", 400, "Bad Request", {}, None
    )
    with mock.patch("urllib.request.urlopen", side_effect=err):
        with pytest.raises(RuntimeError, match="HTTP 400"):
            refresher.fetch_token(
                "https://example.test/token", "id", "secret"
            )


def test_fetch_token_http_500_raises_runtime_error():
    err = urllib.error.HTTPError(
        "https://example.test/token", 500, "Internal Server Error", {}, None
    )
    with mock.patch("urllib.request.urlopen", side_effect=err):
        with pytest.raises(RuntimeError, match="HTTP 500"):
            refresher.fetch_token(
                "https://example.test/token", "id", "secret"
            )


def test_fetch_token_url_error_propagates_unchanged():
    """Network errors (URLError) must propagate, not be wrapped."""
    err = urllib.error.URLError("dns failure")
    with mock.patch("urllib.request.urlopen", side_effect=err):
        with pytest.raises(urllib.error.URLError) as excinfo:
            refresher.fetch_token(
                "https://example.test/token", "id", "secret"
            )
    assert excinfo.value is err


def test_fetch_token_malformed_json_raises_jsondecode_error():
    with mock.patch(
        "urllib.request.urlopen",
        return_value=_FakeResponse(200, b"this is not json {"),
    ):
        with pytest.raises(json.JSONDecodeError):
            refresher.fetch_token(
                "https://example.test/token", "id", "secret"
            )


def test_fetch_token_missing_access_token_raises_runtime_error():
    payload = json.dumps({"expires_in": 600}).encode("utf-8")
    with mock.patch(
        "urllib.request.urlopen", return_value=_FakeResponse(200, payload)
    ):
        with pytest.raises(RuntimeError, match="missing access_token"):
            refresher.fetch_token(
                "https://example.test/token", "id", "secret"
            )


def test_fetch_token_default_expires_in_when_missing():
    payload = json.dumps({"access_token": "x"}).encode("utf-8")
    with mock.patch(
        "urllib.request.urlopen", return_value=_FakeResponse(200, payload)
    ):
        token, expires_in = refresher.fetch_token(
            "https://example.test/token", "id", "secret"
        )
    assert token == "x"
    assert expires_in == 1800


# ---------------------------------------------------------------------------
# patch_secret
# ---------------------------------------------------------------------------


def test_patch_secret_invokes_oc_with_merge_type_and_no_anthropic_by_default():
    with mock.patch.object(refresher.subprocess, "run") as m_run:
        refresher.patch_secret("my-secret", "my-ns", "Zm91bmRyeQ==")
    m_run.assert_called_once()
    args = m_run.call_args.args[0]
    assert args == [
        "oc", "-n", "my-ns", "patch", "secret", "my-secret",
        "--type=merge", "-p", mock.ANY,
    ]
    patch_payload = json.loads(args[-1])
    assert patch_payload == {"data": {"AZURE_FOUNDRY_API_KEY": "Zm91bmRyeQ=="}}
    assert "AZURE_ANTHROPIC_KEY" not in patch_payload["data"]
    # Ensure check=True so CalledProcessError is raised on failure.
    assert m_run.call_args.kwargs.get("check") is True


def test_patch_secret_includes_anthropic_when_anthropic_b64_provided():
    with mock.patch.object(refresher.subprocess, "run") as m_run:
        refresher.patch_secret(
            "my-secret", "my-ns", "Zm91bmRyeQ==", "YW50aHJvcGlj"
        )
    args = m_run.call_args.args[0]
    patch_payload = json.loads(args[-1])
    assert patch_payload == {
        "data": {
            "AZURE_FOUNDRY_API_KEY": "Zm91bmRyeQ==",
            "AZURE_ANTHROPIC_KEY": "YW50aHJvcGlj",
        }
    }


def test_patch_secret_propagates_called_process_error():
    err = subprocess.CalledProcessError(1, ["oc"], stderr=b"forbidden")
    with mock.patch.object(refresher.subprocess, "run", side_effect=err):
        with pytest.raises(subprocess.CalledProcessError):
            refresher.patch_secret("my-secret", "my-ns", "Zm91bmRyeQ==")


# ---------------------------------------------------------------------------
# restart_deployment
# ---------------------------------------------------------------------------


def test_restart_deployment_invokes_oc_patch_with_rfc3339_annotation():
    with mock.patch.object(refresher.subprocess, "run") as m_run:
        refresher.restart_deployment("my-deploy", "my-ns")
    m_run.assert_called_once()
    args = m_run.call_args.args[0]
    assert args[:5] == ["oc", "-n", "my-ns", "patch", "deployment"]
    assert args[5] == "my-deploy"
    assert args[6] == "-p"
    payload = json.loads(args[7])
    annotation = payload["metadata"]["annotations"][
        "kubectl.kubernetes.io/restartedAt"
    ]
    # RFC3339 UTC, second precision: 20 chars including the trailing Z.
    assert annotation.endswith("Z")
    assert len(annotation) == 20
    # Verify check=True.
    assert m_run.call_args.kwargs.get("check") is True


def test_restart_deployment_propagates_called_process_error():
    err = subprocess.CalledProcessError(1, ["oc"], stderr=b"forbidden")
    with mock.patch.object(refresher.subprocess, "run", side_effect=err):
        with pytest.raises(subprocess.CalledProcessError):
            refresher.restart_deployment("my-deploy", "my-ns")


# ---------------------------------------------------------------------------
# refresh_once
# ---------------------------------------------------------------------------


def test_refresh_once_success_calls_in_order_and_returns_true():
    env = _base_env()
    call_log = []

    def fake_fetch_token(*args, **kwargs):
        call_log.append("fetch_token")
        return ("t0k3n", 600)

    def fake_patch_secret(*args, **kwargs):
        call_log.append("patch_secret")

    def fake_restart_deployment(*args, **kwargs):
        call_log.append("restart_deployment")

    with mock.patch.object(
        refresher, "fetch_token", side_effect=fake_fetch_token
    ), mock.patch.object(
        refresher, "patch_secret", side_effect=fake_patch_secret
    ), mock.patch.object(
        refresher, "restart_deployment", side_effect=fake_restart_deployment
    ):
        ok = refresher.refresh_once(env)

    assert ok is True
    assert call_log == ["fetch_token", "patch_secret", "restart_deployment"]


def test_refresh_once_returns_false_when_fetch_token_raises():
    env = _base_env()
    with mock.patch.object(
        refresher,
        "fetch_token",
        side_effect=RuntimeError("token endpoint returned HTTP 503"),
    ):
        ok = refresher.refresh_once(env)
    assert ok is False


def test_refresh_once_returns_false_when_patch_secret_raises():
    env = _base_env()
    with mock.patch.object(
        refresher, "fetch_token", return_value=("t0k3n", 600)
    ), mock.patch.object(
        refresher,
        "patch_secret",
        side_effect=subprocess.CalledProcessError(1, ["oc"], stderr=b"err"),
    ), mock.patch.object(
        refresher, "restart_deployment"
    ) as m_restart:
        ok = refresher.refresh_once(env)
    assert ok is False
    # restart must not be called if patch failed.
    m_restart.assert_not_called()


def test_refresh_once_returns_false_when_restart_deployment_raises():
    env = _base_env()
    with mock.patch.object(
        refresher, "fetch_token", return_value=("t0k3n", 600)
    ), mock.patch.object(
        refresher, "patch_secret"
    ), mock.patch.object(
        refresher,
        "restart_deployment",
        side_effect=subprocess.CalledProcessError(1, ["oc"], stderr=b"err"),
    ):
        ok = refresher.refresh_once(env)
    assert ok is False


def test_refresh_once_mirror_false_omits_anthropic_b64():
    env = _base_env()
    env["MIRROR_TO_ANTHROPIC"] = "false"
    with mock.patch.object(
        refresher, "fetch_token", return_value=("t0k3n", 600)
    ), mock.patch.object(
        refresher, "patch_secret"
    ) as m_patch, mock.patch.object(
        refresher, "restart_deployment"
    ):
        refresher.refresh_once(env)
    # patch_secret called positionally with anthropic_b64=None.
    args, kwargs = m_patch.call_args
    assert args[3] is None


def test_refresh_once_mirror_true_passes_anthropic_b64():
    env = _base_env()
    env["MIRROR_TO_ANTHROPIC"] = "true"
    with mock.patch.object(
        refresher, "fetch_token", return_value=("t0k3n", 600)
    ), mock.patch.object(
        refresher, "patch_secret"
    ) as m_patch, mock.patch.object(
        refresher, "restart_deployment"
    ):
        refresher.refresh_once(env)
    args, kwargs = m_patch.call_args
    assert args[3] is not None
    assert args[3]  # non-empty base64 string


# ---------------------------------------------------------------------------
# _detect_namespace
# ---------------------------------------------------------------------------


def test_detect_namespace_reads_sa_token_path(monkeypatch):
    monkeypatch.setattr(
        refresher.os.path,
        "exists",
        lambda p: p == refresher.SA_NAMESPACE_PATH,
    )
    monkeypatch.setattr(
        "builtins.open", mock.mock_open(read_data="from-sa-file\n")
    )
    assert refresher._detect_namespace() == "from-sa-file"


def test_detect_namespace_falls_back_to_target_namespace_env(monkeypatch):
    monkeypatch.setattr(refresher.os.path, "exists", lambda p: False)
    monkeypatch.setenv("TARGET_NAMESPACE", "from-env")
    assert refresher._detect_namespace() == "from-env"


def test_detect_namespace_falls_back_to_default(monkeypatch):
    monkeypatch.setattr(refresher.os.path, "exists", lambda p: False)
    monkeypatch.delenv("TARGET_NAMESPACE", raising=False)
    assert refresher._detect_namespace() == "default"


# ---------------------------------------------------------------------------
# main loop
# ---------------------------------------------------------------------------


def _set_minimum_env(monkeypatch):
    """Set just the required env vars; leave optional ones unset to exercise defaults."""
    monkeypatch.setenv("LLMAAS_TOKEN_URL", "https://example.test/token")
    monkeypatch.setenv("LLMAAS_CLIENT_ID", "test-client-id")
    monkeypatch.setenv("LLMAAS_CLIENT_SECRET", "test-client-secret")
    monkeypatch.setenv("TARGET_SECRET_NAME", "my-secret")
    monkeypatch.setenv("TARGET_DEPLOYMENT_NAME", "my-deploy")
    monkeypatch.delenv("REFRESH_INTERVAL_SECONDS", raising=False)
    monkeypatch.delenv("RETRY_INTERVAL_SECONDS", raising=False)
    monkeypatch.delenv("INITIAL_DELAY_SECONDS", raising=False)
    monkeypatch.delenv("MIRROR_TO_ANTHROPIC", raising=False)
    monkeypatch.delenv("TARGET_NAMESPACE", raising=False)


def test_main_sleeps_initial_delay_then_refresh_every_on_success(monkeypatch):
    _set_minimum_env(monkeypatch)

    sleep_calls = []
    iteration_count = [0]

    def fake_sleep(seconds):
        sleep_calls.append(seconds)
        # Stop after initial delay + 2 success iterations.
        if len(sleep_calls) >= 3:
            raise StopIteration("break out of infinite loop")

    def fake_refresh_once(env):
        iteration_count[0] += 1
        return True

    monkeypatch.setattr(refresher.time, "sleep", fake_sleep)
    monkeypatch.setattr(refresher, "refresh_once", fake_refresh_once)

    with pytest.raises(StopIteration):
        refresher.main()

    assert iteration_count[0] == 2  # ran twice before the third sleep raised
    # First sleep is initial_delay (5s default), then refresh_every (1500s default).
    assert sleep_calls == [5, 1500, 1500]


def test_main_sleeps_retry_every_on_failure(monkeypatch):
    _set_minimum_env(monkeypatch)

    sleep_calls = []

    def fake_sleep(seconds):
        sleep_calls.append(seconds)
        if len(sleep_calls) >= 3:
            raise StopIteration("break")

    def fake_refresh_once(env):
        return False  # always fail

    monkeypatch.setattr(refresher.time, "sleep", fake_sleep)
    monkeypatch.setattr(refresher, "refresh_once", fake_refresh_once)

    with pytest.raises(StopIteration):
        refresher.main()

    # initial_delay (5), then retry_every (60) twice.
    assert sleep_calls == [5, 60, 60]


def test_main_loop_alternates_refresh_and_retry_sleep(monkeypatch):
    """Mixed success/failure: refresh_once returns True, False, True."""
    _set_minimum_env(monkeypatch)

    sleep_calls = []
    results = iter([True, False, True])

    def fake_sleep(seconds):
        sleep_calls.append(seconds)
        if len(sleep_calls) >= 4:
            raise StopIteration("break")

    def fake_refresh_once(env):
        return next(results)

    monkeypatch.setattr(refresher.time, "sleep", fake_sleep)
    monkeypatch.setattr(refresher, "refresh_once", fake_refresh_once)

    with pytest.raises(StopIteration):
        refresher.main()

    # initial_delay (5), refresh (1500), retry (60), refresh (1500).
    assert sleep_calls == [5, 1500, 60, 1500]


def test_main_loop_runs_indefinitely_until_interrupted(monkeypatch):
    """Verify the while-loop never exits on its own."""
    _set_minimum_env(monkeypatch)

    iterations = [0]
    max_iterations = 50

    def fake_refresh_once(env):
        iterations[0] += 1
        if iterations[0] >= max_iterations:
            raise KeyboardInterrupt("loop bound")
        return True

    monkeypatch.setattr(refresher.time, "sleep", lambda s: None)
    monkeypatch.setattr(refresher, "refresh_once", fake_refresh_once)

    with pytest.raises(KeyboardInterrupt):
        refresher.main()

    assert iterations[0] == max_iterations


def test_main_honours_custom_intervals_from_env(monkeypatch):
    """Custom REFRESH_INTERVAL_SECONDS / RETRY_INTERVAL_SECONDS propagate to sleep."""
    monkeypatch.setenv("LLMAAS_TOKEN_URL", "https://example.test/token")
    monkeypatch.setenv("LLMAAS_CLIENT_ID", "test-client-id")
    monkeypatch.setenv("LLMAAS_CLIENT_SECRET", "test-client-secret")
    monkeypatch.setenv("TARGET_SECRET_NAME", "my-secret")
    monkeypatch.setenv("TARGET_DEPLOYMENT_NAME", "my-deploy")
    monkeypatch.setenv("REFRESH_INTERVAL_SECONDS", "42")
    monkeypatch.setenv("RETRY_INTERVAL_SECONDS", "7")
    monkeypatch.setenv("INITIAL_DELAY_SECONDS", "3")
    monkeypatch.delenv("MIRROR_TO_ANTHROPIC", raising=False)
    monkeypatch.delenv("TARGET_NAMESPACE", raising=False)

    sleep_calls = []
    results = iter([True, False])

    def fake_sleep(seconds):
        sleep_calls.append(seconds)
        if len(sleep_calls) >= 3:
            raise StopIteration("break")

    monkeypatch.setattr(refresher.time, "sleep", fake_sleep)
    monkeypatch.setattr(
        refresher, "refresh_once", lambda env: next(results)
    )

    with pytest.raises(StopIteration):
        refresher.main()

    # initial_delay=3, then refresh=42 on success, then retry=7 on failure.
    assert sleep_calls == [3, 42, 7]
