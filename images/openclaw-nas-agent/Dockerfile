# Build an OpenClaw runtime image from a maintained OpenClaw source ref and
# add the shared NAS document tool baseline.
#
# OpenClaw/Hermes product customizations are source changes, not post-build
# string rewrites. The workflow passes a source repository and commit; this
# Dockerfile builds the Control UI from that source and copies the built assets
# into the frozen runtime base image.

ARG OPENCLAW_SOURCE_REPO=https://github.com/openclaw/openclaw.git
ARG OPENCLAW_SOURCE_REF=
ARG BASE_IMAGE=ubuntu:24.04
ARG RUNTIME_USER=node

FROM node:22-bookworm AS openclaw-control-ui-builder
ARG OPENCLAW_SOURCE_REPO
ARG OPENCLAW_SOURCE_REF

RUN apt-get update \
  && apt-get install -y --no-install-recommends git ca-certificates \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /src
RUN test -n "$OPENCLAW_SOURCE_REF" \
  && git clone "$OPENCLAW_SOURCE_REPO" openclaw \
  && cd openclaw \
  && git checkout --detach "$OPENCLAW_SOURCE_REF" \
  && corepack enable \
  && node scripts/ui.js build \
  && test -f dist/control-ui/index.html \
  && test -d dist/control-ui/assets

FROM ${BASE_IMAGE}
ARG BASE_IMAGE
ARG RUNTIME_USER
ARG OPENCLAW_SOURCE_REPO
ARG OPENCLAW_SOURCE_REF

USER root

COPY --from=openclaw-control-ui-builder /src/openclaw/dist/control-ui /app/dist/control-ui
COPY images/shared/install-document-baseline.sh /tmp/install-document-baseline.sh
COPY images/shared/openclaw-hwp-text.py /usr/local/bin/openclaw-hwp-text
COPY images/shared/openclaw-document-tools /usr/local/bin/openclaw-document-tools
RUN chmod +x /tmp/install-document-baseline.sh \
  && /tmp/install-document-baseline.sh \
  && rm -f /tmp/install-document-baseline.sh \
  && chmod 0755 /usr/local/bin/openclaw-hwp-text /usr/local/bin/openclaw-document-tools \
  && ln -sf /usr/local/bin/openclaw-hwp-text /usr/local/bin/read-hwp \
  && ln -sf /usr/local/bin/openclaw-hwp-text /usr/local/bin/hwp-read \
  && ln -sf /usr/local/bin/openclaw-hwp-text /usr/local/bin/hwp2txt \
  && printf 'family=openclaw\nsource_repo=%s\nsource_ref=%s\nbase_image=%s\n' \
    "$OPENCLAW_SOURCE_REPO" "$OPENCLAW_SOURCE_REF" "$BASE_IMAGE" \
    > /usr/local/share/openclaw-nas-agent-source.manifest

ENV LANG=ko_KR.UTF-8 \
    LANGUAGE=ko_KR:ko \
    LC_ALL=ko_KR.UTF-8

USER ${RUNTIME_USER}

LABEL org.opencontainers.image.title="JiTech OpenClaw-family runtime"
LABEL org.opencontainers.image.description="OpenClaw runtime image built from a managed source ref with NAS document tools"
LABEL org.opencontainers.image.family="openclaw"
LABEL org.opencontainers.image.openclaw.source="${OPENCLAW_SOURCE_REPO}"
LABEL org.opencontainers.image.openclaw.revision="${OPENCLAW_SOURCE_REF}"
LABEL org.opencontainers.image.base.name="${BASE_IMAGE}"
