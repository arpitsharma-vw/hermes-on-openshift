# ─── Stage 1: Build the web frontend (Node ≥ 20 required) ──────────────────
FROM node:20-slim AS frontend-builder

ARG HERMES_REF=v2026.6.19

RUN apt-get update \
    && apt-get install -y --no-install-recommends git ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/hermes/src
RUN git clone --branch "${HERMES_REF}" --depth 1 https://github.com/NousResearch/hermes-agent.git .
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

ARG KUBECTL_VERSION=v1.32.5
ARG TRIVY_VERSION=0.70.0

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
    && ARCH="$(dpkg --print-architecture)" \
    && case "${ARCH}" in \
      amd64) KUBECTL_ARCH="amd64" ;; \
      arm64) KUBECTL_ARCH="arm64" ;; \
      *) echo "Unsupported architecture for kubectl: ${ARCH}" && exit 1 ;; \
    esac \
    && curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${KUBECTL_ARCH}/kubectl" -o /usr/local/bin/kubectl \
    && chmod +x /usr/local/bin/kubectl \
    && case "${ARCH}" in \
      amd64) TRIVY_ARCH="64bit" ;; \
      arm64) TRIVY_ARCH="ARM64" ;; \
      *) echo "Unsupported architecture for trivy: ${ARCH}" && exit 1 ;; \
    esac \
    && curl -fsSL "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_Linux-${TRIVY_ARCH}.tar.gz" -o /tmp/trivy.tar.gz \
    && tar -xzf /tmp/trivy.tar.gz -C /tmp trivy \
    && mv /tmp/trivy /usr/local/bin/trivy \
    && chmod +x /usr/local/bin/trivy \
    && rm -f /tmp/trivy.tar.gz \
    && rm -rf /var/lib/apt/lists/*

# Copy venv (Python package + hermes binary) from builder
COPY --from=python-builder /opt/hermes/hermes-agent/venv /opt/hermes/hermes-agent/venv

# Copy LLMAAS OAuth2 token-refresher sidecar script.
COPY scripts/llmaas-token-refresher.py /usr/local/bin/llmaas-token-refresher.py
RUN chmod +x /usr/local/bin/llmaas-token-refresher.py

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
