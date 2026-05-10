# ─── Stage 1: Build the web frontend (Node ≥ 20 required) ──────────────────
FROM node:20-slim AS frontend-builder

RUN apt-get update \
    && apt-get install -y --no-install-recommends git ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/hermes/src
RUN git clone --depth 1 https://github.com/NousResearch/hermes-agent.git .
RUN cd web && npm install && npm run build

# ─── Stage 2: Install Python package with pre-built frontend ────────────────
FROM python:3.11-slim AS python-builder

RUN apt-get update \
    && apt-get install -y --no-install-recommends git ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=frontend-builder /opt/hermes/src /opt/hermes/src

RUN python3 -m venv /opt/hermes/hermes-agent/venv \
    && /opt/hermes/hermes-agent/venv/bin/pip install --no-cache-dir --upgrade pip setuptools wheel \
    && /opt/hermes/hermes-agent/venv/bin/pip install --no-cache-dir "/opt/hermes/src[web]"

# ─── Stage 3: Lean runtime image ────────────────────────────────────────────
FROM python:3.11-slim

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    HERMES_HOME=/opt/hermes/.hermes \
    HERMES_INSTALL_DIR=/opt/hermes/hermes-agent \
    PATH=/opt/hermes/hermes-agent/venv/bin:/usr/local/bin:/usr/bin:/bin

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    curl \
    findutils \
    gzip \
    ripgrep \
    ffmpeg \
    tar \
    && rm -rf /var/lib/apt/lists/*

# Copy venv (Python package + hermes binary) from builder
COPY --from=python-builder /opt/hermes/hermes-agent/venv /opt/hermes/hermes-agent/venv

# Copy hermes source so the dashboard can find web/dist static assets
COPY --from=frontend-builder /opt/hermes/src /opt/hermes/src

# OpenShift-friendly writable home path for random non-root UIDs.
RUN mkdir -p /opt/hermes/.hermes \
    && chgrp -R 0 /opt/hermes \
    && chmod -R g=u /opt/hermes

WORKDIR /opt/hermes

# Default to non-root; OpenShift may override with a random UID.
USER 1001

ENTRYPOINT ["/bin/sh", "-c"]
CMD ["hermes --help"]
