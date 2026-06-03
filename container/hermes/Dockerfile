# Build a single-container Hermes runtime image for OpenClaw NAS Agent slots.
#
# Usage:
#   docker build \
#     --build-arg BASE_IMAGE=nousresearch/hermes-agent:latest \
#     --build-arg HERMES_WORKSPACE_IMAGE=ghcr.io/outsourc-e/hermes-workspace:latest \
#     -t ghcr.io/epicevent/openclaw-nas-agent:hermes-workspace-YYYYMMDD-rN \
#     -f container/hermes/Dockerfile .
#
# The final image contains:
#   - Hermes Agent gateway/runtime from BASE_IMAGE
#   - Hermes Workspace web UI from HERMES_WORKSPACE_IMAGE
#   - OpenClaw NAS Agent document-reading baseline packages
ARG HERMES_WORKSPACE_IMAGE=ghcr.io/outsourc-e/hermes-workspace:latest
ARG BASE_IMAGE=nousresearch/hermes-agent:latest

FROM ${HERMES_WORKSPACE_IMAGE} AS hermes_workspace

FROM ${BASE_IMAGE}

USER root

COPY --from=hermes_workspace /usr/local/bin/node /usr/local/bin/node
COPY --from=hermes_workspace /usr/local/bin/npm /usr/local/bin/npm
COPY --from=hermes_workspace /usr/local/bin/npx /usr/local/bin/npx
COPY --from=hermes_workspace /usr/local/lib/node_modules /usr/local/lib/node_modules
COPY --from=hermes_workspace /app /opt/hermes-workspace
COPY container/hermes/patch-hermes-workspace-gemini.py /tmp/patch-hermes-workspace-gemini.py

COPY container/install-container-baseline.sh /tmp/install-container-baseline.sh
RUN chmod +x /tmp/install-container-baseline.sh \
  && /tmp/install-container-baseline.sh \
  && rm -f /tmp/install-container-baseline.sh \
  && apt-get update \
  && apt-get install -y --no-install-recommends tini procps gosu python3 \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/* \
  && python3 /tmp/patch-hermes-workspace-gemini.py \
  && rm -f /tmp/patch-hermes-workspace-gemini.py

COPY container/hermes/openclaw-hermes-entrypoint.sh /usr/local/bin/openclaw-hermes-entrypoint
RUN chmod 0755 /usr/local/bin/openclaw-hermes-entrypoint \
  && mkdir -p /etc/services.d/hermes-workspace \
  && cp /usr/local/bin/openclaw-hermes-entrypoint /etc/services.d/hermes-workspace/run \
  && chmod -R a+rX /opt/hermes-workspace

ENV LANG=ko_KR.UTF-8 \
    LANGUAGE=ko_KR:ko \
    LC_ALL=ko_KR.UTF-8 \
    NODE_ENV=production \
    HERMES_HOME=/opt/data \
    HERMES_DATA_DIR=/opt/data \
    HERMES_WORKSPACE_DIR=/workspace \
    HERMES_API_URL=http://127.0.0.1:8642 \
    HERMES_DASHBOARD_URL=http://127.0.0.1:9119 \
    HOST=0.0.0.0 \
    PORT=3000

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=5 \
  CMD curl -fsS http://127.0.0.1:3000/ >/dev/null || exit 1

ENTRYPOINT ["/init", "/opt/hermes/docker/main-wrapper.sh"]
CMD ["gateway", "run"]

LABEL org.opencontainers.image.title="OpenClaw Hermes Workspace NAS Agent"
LABEL org.opencontainers.image.description="Single-container Hermes Agent + Hermes Workspace image with OpenClaw NAS document baseline"
