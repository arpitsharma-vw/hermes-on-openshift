FROM debian:bookworm-slim

ENV LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    HERMES_HOME=/opt/hermes/.hermes \
    PATH=/usr/local/bin:/usr/bin:/bin

USER root

# Base runtime tools required by the Hermes installer.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    curl \
    findutils \
    git \
    gzip \
    tar \
    && rm -rf /var/lib/apt/lists/*

# Hermes upstream installer handles remaining runtime dependencies.
RUN curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh | bash

# OpenShift-friendly writable home path for random non-root UIDs.
RUN mkdir -p /opt/hermes/.hermes \
    && chgrp -R 0 /opt/hermes \
    && chmod -R g=u /opt/hermes

WORKDIR /opt/hermes

# Default to non-root; OpenShift may override with a random UID.
USER 1001

ENTRYPOINT ["/bin/sh", "-c"]
CMD ["hermes --help"]
