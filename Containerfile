FROM debian:bookworm-slim

ENV LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    HERMES_HOME=/opt/hermes/.hermes \
    HERMES_INSTALL_DIR=/opt/hermes/hermes-agent \
    PATH=/usr/local/bin:/usr/bin:/bin

USER root

# Base runtime tools required by Hermes runtime and verification commands.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    curl \
    findutils \
    gzip \
    python3 \
    python3-venv \
    python3-pip \
    ripgrep \
    ffmpeg \
    tar \
    && rm -rf /var/lib/apt/lists/*

# Install Hermes lazily at runtime to avoid CI build failures from upstream installer
# or dependency resolution changes. First invocation of `hermes` bootstraps install.
RUN cat <<'EOF' >/usr/local/bin/hermes
#!/usr/bin/env bash
set -euo pipefail

HERMES_HOME="${HERMES_HOME:-/opt/hermes/.hermes}"
HERMES_INSTALL_DIR="${HERMES_INSTALL_DIR:-/opt/hermes/hermes-agent}"
HERMES_BIN="${HERMES_INSTALL_DIR}/venv/bin/hermes"

if [[ ! -x "${HERMES_BIN}" ]]; then
    echo "Bootstrapping Hermes installation into ${HERMES_INSTALL_DIR} ..."
    mkdir -p "${HERMES_HOME}"
    curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh | bash -s -- --skip-setup --dir "${HERMES_INSTALL_DIR}" --hermes-home "${HERMES_HOME}"
fi

exec "${HERMES_BIN}" "$@"
EOF

RUN chmod +x /usr/local/bin/hermes

# OpenShift-friendly writable home path for random non-root UIDs.
RUN mkdir -p /opt/hermes/.hermes \
    && chgrp -R 0 /opt/hermes \
    && chmod -R g=u /opt/hermes

WORKDIR /opt/hermes

# Default to non-root; OpenShift may override with a random UID.
USER 1001

ENTRYPOINT ["/bin/sh", "-c"]
CMD ["hermes --help"]
