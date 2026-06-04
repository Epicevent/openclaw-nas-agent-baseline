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
ARG OPENCLAW_DASHBOARD_TITLE=""
ARG OPENCLAW_DASHBOARD_SOURCE_TEXT=OpenClaw
ARG OPENCLAW_DASHBOARD_INCLUDE_REGEX='^/app/dist/.*[.]js$|^/app/dist/index[.]html$|^/app/(public|assets|static)/.*[.](html|svg|css|js)$'
ARG OPENCLAW_DASHBOARD_EXCLUDE_REGEX='/node_modules/'
ARG OPENCLAW_DASHBOARD_MAX_PATCHED_FILES=120
ARG OPENCLAW_DASHBOARD_MAX_REPLACEMENTS=500

USER root

COPY images/shared/install-document-baseline.sh /tmp/install-document-baseline.sh
COPY images/shared/openclaw-hwp-text.py /usr/local/bin/openclaw-hwp-text
COPY images/shared/openclaw-document-tools /usr/local/bin/openclaw-document-tools
COPY images/openclaw-nas-agent/patch-openclaw-dashboard-title.py /usr/local/bin/patch-openclaw-dashboard-title
RUN chmod +x /tmp/install-document-baseline.sh \
  && /tmp/install-document-baseline.sh \
  && rm -f /tmp/install-document-baseline.sh \
  && chmod 0755 /usr/local/bin/openclaw-hwp-text /usr/local/bin/openclaw-document-tools /usr/local/bin/patch-openclaw-dashboard-title \
  && ln -sf /usr/local/bin/openclaw-hwp-text /usr/local/bin/read-hwp \
  && ln -sf /usr/local/bin/openclaw-hwp-text /usr/local/bin/hwp-read \
  && ln -sf /usr/local/bin/openclaw-hwp-text /usr/local/bin/hwp2txt

RUN if [ -n "$OPENCLAW_DASHBOARD_TITLE" ]; then \
      patch-openclaw-dashboard-title \
        --source "$OPENCLAW_DASHBOARD_SOURCE_TEXT" \
        --extra-source Openclaw \
        --target "$OPENCLAW_DASHBOARD_TITLE" \
        --include-path-regex "$OPENCLAW_DASHBOARD_INCLUDE_REGEX" \
        --exclude-path-regex "$OPENCLAW_DASHBOARD_EXCLUDE_REGEX" \
        --max-patched-files "$OPENCLAW_DASHBOARD_MAX_PATCHED_FILES" \
        --max-replacements "$OPENCLAW_DASHBOARD_MAX_REPLACEMENTS" \
        /app /workspace /home/node /usr/local/share /opt; \
    else \
      echo "openclaw_dashboard_title_patch=skipped"; \
    fi

ENV LANG=ko_KR.UTF-8 \
    LANGUAGE=ko_KR:ko \
    LC_ALL=ko_KR.UTF-8

USER ${RUNTIME_USER}

LABEL org.opencontainers.image.title="OpenClaw NAS Agent Baseline"
LABEL org.opencontainers.image.description="Document-reading baseline packages for OpenClaw containers with per-user NAS mounts"
