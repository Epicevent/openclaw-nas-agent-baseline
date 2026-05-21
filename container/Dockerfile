# Build an OpenClaw runtime image that already contains document-reading tools.
#
# Usage:
#   docker build \
#     --build-arg BASE_IMAGE=<current-openclaw-runtime-image> \
#     -t openclaw-nas-agent:baseline \
#     -f container/Dockerfile .
#
# The default BASE_IMAGE is only a placeholder for local package testing.
# In production, pass the exact image currently used by the OpenClaw container.
ARG BASE_IMAGE=ubuntu:24.04
FROM ${BASE_IMAGE}

USER root

COPY container/install-container-baseline.sh /tmp/install-container-baseline.sh
RUN chmod +x /tmp/install-container-baseline.sh \
  && /tmp/install-container-baseline.sh \
  && rm -f /tmp/install-container-baseline.sh

ENV LANG=ko_KR.UTF-8 \
    LANGUAGE=ko_KR:ko \
    LC_ALL=ko_KR.UTF-8

USER node

LABEL org.opencontainers.image.title="OpenClaw NAS Agent Baseline"
LABEL org.opencontainers.image.description="Document-reading baseline packages for OpenClaw containers with per-user NAS mounts"
