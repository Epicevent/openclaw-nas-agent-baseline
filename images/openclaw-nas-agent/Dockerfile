# Build an OpenClaw runtime image that already contains document-reading tools.
#
# Usage:
#   docker build \
#     --build-arg BASE_IMAGE=<current-openclaw-runtime-image> \
#     --build-arg RUNTIME_USER=node \
#     -t openclaw-nas-agent:baseline \
#     -f images/openclaw-nas-agent/Dockerfile .
#
# The default BASE_IMAGE is only a placeholder for local package testing.
# In production, pass the exact image currently used by the OpenClaw container.
ARG BASE_IMAGE=ubuntu:24.04
FROM ${BASE_IMAGE}
ARG RUNTIME_USER=node

USER root

COPY images/shared/install-document-baseline.sh /tmp/install-document-baseline.sh
COPY images/shared/openclaw-hwp-text.py /usr/local/bin/openclaw-hwp-text
COPY images/shared/openclaw-document-tools /usr/local/bin/openclaw-document-tools
RUN chmod +x /tmp/install-document-baseline.sh \
  && /tmp/install-document-baseline.sh \
  && rm -f /tmp/install-document-baseline.sh \
  && chmod 0755 /usr/local/bin/openclaw-hwp-text /usr/local/bin/openclaw-document-tools \
  && ln -sf /usr/local/bin/openclaw-hwp-text /usr/local/bin/read-hwp \
  && ln -sf /usr/local/bin/openclaw-hwp-text /usr/local/bin/hwp-read \
  && ln -sf /usr/local/bin/openclaw-hwp-text /usr/local/bin/hwp2txt

ENV LANG=ko_KR.UTF-8 \
    LANGUAGE=ko_KR:ko \
    LC_ALL=ko_KR.UTF-8

USER ${RUNTIME_USER}

LABEL org.opencontainers.image.title="OpenClaw NAS Agent Baseline"
LABEL org.opencontainers.image.description="Document-reading baseline packages for OpenClaw containers with per-user NAS mounts"
