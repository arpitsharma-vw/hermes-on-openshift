FROM debian:bookworm-slim

ENV LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    HERMES_HOME=/opt/hermes/.hermes \
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

# Install Hermes in an isolated virtualenv to avoid installer-side shell assumptions.
RUN python3 -m venv /opt/hermes/venv \
    && /opt/hermes/venv/bin/pip install --no-cache-dir --upgrade pip setuptools wheel \
    && /opt/hermes/venv/bin/pip install --no-cache-dir "hermes-agent>=0.13.0" \
    && ln -sf /opt/hermes/venv/bin/hermes /usr/local/bin/hermes

# OpenShift-friendly writable home path for random non-root UIDs.
RUN mkdir -p /opt/hermes/.hermes \
    && chgrp -R 0 /opt/hermes \
    && chmod -R g=u /opt/hermes

WORKDIR /opt/hermes

# Default to non-root; OpenShift may override with a random UID.
USER 1001

ENTRYPOINT ["/bin/sh", "-c"]
CMD ["hermes --help"]
