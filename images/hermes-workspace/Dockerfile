# Wrap an already-built Hermes-family runtime image with shared NAS document
# tools and slot entrypoint glue. Product source is built outside this
# operations repository.

ARG BASE_IMAGE=ubuntu:24.04

FROM ${BASE_IMAGE}
ARG BASE_IMAGE

USER root

COPY images/shared/openclaw-hwp-text.py /usr/local/bin/openclaw-hwp-text
COPY images/shared/openclaw-document-tools /usr/local/bin/openclaw-document-tools
COPY images/shared/install-document-baseline.sh /tmp/install-document-baseline.sh
RUN test -f /opt/hermes/docker/main-wrapper.sh \
  && test -f /opt/hermes-workspace/server-entry.js \
  && chmod +x /tmp/install-document-baseline.sh \
  && /tmp/install-document-baseline.sh \
  && rm -f /tmp/install-document-baseline.sh \
  && apt-get update \
  && apt-get install -y --no-install-recommends tini procps gosu passwd python3 \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/* \
  && chmod 0755 /usr/local/bin/openclaw-hwp-text /usr/local/bin/openclaw-document-tools \
  && ln -sf /usr/local/bin/openclaw-hwp-text /usr/local/bin/read-hwp \
  && ln -sf /usr/local/bin/openclaw-hwp-text /usr/local/bin/hwp-read \
  && ln -sf /usr/local/bin/openclaw-hwp-text /usr/local/bin/hwp2txt \
  && printf 'family=hermes\nbase_image=%s\n' "$BASE_IMAGE" \
    > /usr/local/share/agent-runtime-wrapper.manifest

COPY images/hermes-workspace/openclaw-hermes-entrypoint.sh /usr/local/bin/openclaw-hermes-entrypoint
COPY images/hermes-workspace/openclaw-nas-group-init.sh /etc/cont-init.d/10-openclaw-nas-group
RUN chmod 0755 /usr/local/bin/openclaw-hermes-entrypoint \
  && chmod 0755 /etc/cont-init.d/10-openclaw-nas-group \
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
  CMD node -e "fetch('http://127.0.0.1:3000/').then(r=>process.exit(r.status < 500 ? 0 : 1)).catch(()=>process.exit(1))"

ENTRYPOINT ["/init", "/opt/hermes/docker/main-wrapper.sh"]
CMD ["gateway", "run"]

LABEL org.opencontainers.image.title="JiTech Hermes-family runtime wrapper"
LABEL org.opencontainers.image.description="Hermes-family runtime image wrapped with shared NAS document tools"
LABEL org.opencontainers.image.family="hermes"
LABEL org.opencontainers.image.base.name="${BASE_IMAGE}"
