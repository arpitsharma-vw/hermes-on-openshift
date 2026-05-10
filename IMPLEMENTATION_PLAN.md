# Hermes on OpenShift Implementation Plan

Last updated: 2026-05-09

This plan follows the official Hermes installation guidance and gates OpenShift work behind a proven local baseline.

## Source of Truth

- Installation: https://hermes-agent.nousresearch.com/docs/getting-started/installation
- Key upstream constraints:
  - Git is the only prerequisite for installer-based setup.
  - Installer handles missing uv, Python 3.11, Node.js 22, ripgrep, and ffmpeg.
  - Recommended flow is: install -> shell reload -> `hermes` / `hermes doctor` -> provider/model setup -> optional gateway.

## Success Definition

The effort is complete when all are true:

- Hermes CLI works on macOS with a real provider and model.
- One gateway channel works end-to-end.
- Hermes runs in OpenShift with persistent state and secret injection.
- Restart of pod does not lose required state (config, sessions, channel state as applicable).
- Repo contains reproducible deployment and operations instructions.

## Phase 0: Environment Readiness (Local)

Goal: validate machine prerequisites before installer run.

Tasks:

1. Confirm Git is present:
	- `git --version`
2. Confirm shell profile target (zsh expected on macOS):
	- `echo $SHELL`
3. Capture local proxy variables if applicable:
	- `env | rg 'HTTP_PROXY|HTTPS_PROXY|NO_PROXY'`

Acceptance criteria:

- `git --version` succeeds.
- shell profile location is known (`~/.zshrc` or equivalent).

## Phase 1: Local Hermes Install + CLI Baseline

Goal: prove Hermes works locally before gateway or OpenShift work.

Tasks:

1. Install via official one-liner:
	- `curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh | bash`
2. Reload shell:
	- `source ~/.zshrc`
3. Validate binary and environment:
	- `which hermes`
	- `hermes doctor`
4. Configure provider and model:
	- `hermes model`
	- Pick a model with >=64k context window.
5. Run first successful chat:
	- `hermes` or `hermes --tui`
6. Validate session resume:
	- `hermes --continue`

Acceptance criteria:

- `hermes doctor` has no blocking errors.
- Hermes returns a valid response for a normal prompt.
- Session resume works after terminal restart.

Evidence to capture:

- install timestamp
- `hermes doctor` output summary
- chosen provider + model name

## Phase 2: Gateway Baseline (Local)

Goal: prove messaging path before containerization.

Tasks:

1. Run gateway setup:
	- `hermes gateway setup`
2. Connect first channel (Telegram preferred for first pass).
3. Validate auth/pairing flow.
4. Send test message and confirm Hermes response.
5. Document required env vars, secrets, and local state paths.

Acceptance criteria:

- At least one channel works end-to-end.
- Pairing/allowlist behavior is understood.
- Restart behavior is documented.

## Phase 3: Container Feasibility

Goal: identify the minimum viable runtime contract for OpenShift.

Tasks:

1. Build a container image with Hermes available at runtime.
2. Explicitly set and test `HERMES_HOME` in container.
3. Map writable paths that must persist.
4. Verify CLI and gateway behavior with mounted storage.
5. Validate proxy behavior for both Python and Node execution paths.
6. Test non-root execution and filesystem permissions.

Acceptance criteria:

- Runtime dependencies are documented.
- Persistent paths are confirmed by test.
- Container can start and complete a CLI chat.

## Phase 4: OpenShift Proof of Concept

Goal: run Hermes as a non-production workload in cluster.

Tasks:

1. Create namespace-scoped deployment resources:
	- Deployment
	- ServiceAccount
	- Secret(s)
	- ConfigMap(s)
	- PVC for Hermes state
2. Inject provider and gateway secrets from Secret objects only.
3. Mount persistent storage to `HERMES_HOME`.
4. Configure proxy env vars (`HTTP_PROXY`, `HTTPS_PROXY`, `NO_PROXY`) if cluster requires them.
5. Validate egress to provider endpoints.
6. Run functional tests:
	- CLI request from pod
	- gateway message round-trip
7. Restart pod and verify state persistence.

Acceptance criteria:

- Pod starts and stays healthy.
- One provider and one channel operate successfully.
- Restart does not lose required Hermes state.

## Phase 5: Hardening + Operationalization

Goal: make deployment repeatable and supportable.

Tasks:

1. Add hardened Containerfile and deterministic entrypoint.
2. Add scripted OpenShift deployment workflow.
3. Document token rotation and secret update process.
4. Document backup/restore for persistent Hermes data.
5. Document failure runbooks (provider outage, gateway auth expiry, PVC issues).

Acceptance criteria:

- Fresh environment deployment is reproducible.
- Security and operational procedures are documented.
- Recovery path is validated at least once.

## Risks and Mitigations

- Risk: Provider/model misconfiguration blocks baseline.
  - Mitigation: require `hermes doctor` and `hermes model` completion before proceeding.
- Risk: OpenShift egress/proxy blocks provider or messaging APIs.
  - Mitigation: add early network checks in Phase 4 before feature validation.
- Risk: State loss on restart due to incomplete persistence mapping.
  - Mitigation: explicitly test restart with PVC-mounted `HERMES_HOME`.

## Decision Gates

- Gate A (after Phase 1): local CLI baseline must pass before gateway work.
- Gate B (after Phase 2): one messaging channel must pass before container work.
- Gate C (after Phase 3): persistence and non-root runtime must pass before OpenShift.
- Gate D (after Phase 4): POC reliability must pass before hardening.

## Immediate Execution Order

1. Run [scripts/bootstrap-local-macos.sh](scripts/bootstrap-local-macos.sh).
2. Complete Phase 1 verification commands.
3. Complete Phase 2 gateway validation.
4. Start container feasibility notes and OpenShift manifests.

## Open Questions

- Which provider/model should be baseline for this repo?
- Is target usage CLI only, gateway only, or both?
- Should first OpenShift deploy use isolated namespace or shared namespace?
