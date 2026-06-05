# Wrap an already-built OpenClaw-family runtime image with shared NAS document
# tools. Product source is built outside this operations repository.

ARG BASE_IMAGE=ubuntu:24.04
ARG RUNTIME_USER=node

FROM ${BASE_IMAGE}
ARG BASE_IMAGE
ARG RUNTIME_USER

USER root

COPY images/shared/install-document-baseline.sh /tmp/install-document-baseline.sh
COPY images/shared/openclaw-hwp-text.py /usr/local/bin/openclaw-hwp-text
COPY images/shared/openclaw-document-tools /usr/local/bin/openclaw-document-tools
RUN test -f /app/dist/control-ui/index.html \
  && chmod +x /tmp/install-document-baseline.sh \
  && /tmp/install-document-baseline.sh \
  && rm -f /tmp/install-document-baseline.sh \
  && chmod 0755 /usr/local/bin/openclaw-hwp-text /usr/local/bin/openclaw-document-tools \
  && ln -sf /usr/local/bin/openclaw-hwp-text /usr/local/bin/read-hwp \
  && ln -sf /usr/local/bin/openclaw-hwp-text /usr/local/bin/hwp-read \
  && ln -sf /usr/local/bin/openclaw-hwp-text /usr/local/bin/hwp2txt \
  && printf 'family=openclaw\nbase_image=%s\n' "$BASE_IMAGE" \
    > /usr/local/share/agent-runtime-wrapper.manifest

ENV LANG=ko_KR.UTF-8 \
    LANGUAGE=ko_KR:ko \
    LC_ALL=ko_KR.UTF-8

USER ${RUNTIME_USER}

LABEL org.opencontainers.image.title="JiTech OpenClaw-family runtime wrapper"
LABEL org.opencontainers.image.description="OpenClaw-family runtime image wrapped with NAS document tools"
LABEL org.opencontainers.image.family="openclaw"
LABEL org.opencontainers.image.base.name="${BASE_IMAGE}"
