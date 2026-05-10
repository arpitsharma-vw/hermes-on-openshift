FROM registry.access.redhat.com/ubi9/ubi-minimal:9.5

ENV LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    HERMES_HOME=/opt/hermes/.hermes \
    PATH=/usr/local/bin:/usr/bin:/bin

USER root

# Base runtime tools required by the Hermes installer and common runtime tasks.
RUN microdnf install -y \
    bash \
    ca-certificates \
    coreutils \
    curl \
    findutils \
    git \
    grep \
    gzip \
    procps-ng \
    shadow-utils \
    tar \
    which \
    && microdnf clean all

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
