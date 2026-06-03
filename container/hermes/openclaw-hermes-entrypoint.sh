#!/command/with-contenv sh
set -eu

HERMES_HOME="${HERMES_HOME:-/opt/data}"
HERMES_DATA_DIR="${HERMES_DATA_DIR:-$HERMES_HOME}"
HERMES_WORKSPACE_DIR="${HERMES_WORKSPACE_DIR:-/workspace}"
HERMES_API_URL="${HERMES_API_URL:-http://127.0.0.1:8642}"
HERMES_DASHBOARD_URL="${HERMES_DASHBOARD_URL:-http://127.0.0.1:9119}"
HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-3000}"
HOME="${HOME:-$HERMES_HOME/home}"

export HERMES_HOME
export HERMES_DATA_DIR
export HERMES_WORKSPACE_DIR
export HERMES_API_URL
export HERMES_DASHBOARD_URL
export HOST
export PORT
export HOME
export COOKIE_SECURE="${COOKIE_SECURE:-1}"
export TRUST_PROXY="${TRUST_PROXY:-1}"
export NODE_ENV="${NODE_ENV:-production}"

if [ "${OPENCLAW_PATCH_HERMES_GEMINI_PROVIDER:-1}" != "0" ]; then
  if command -v python3 >/dev/null 2>&1 && [ -x /usr/local/bin/patch-hermes-workspace-gemini ]; then
    python3 /usr/local/bin/patch-hermes-workspace-gemini || echo "WARN hermes_workspace_gemini_provider_patch=failed"
  else
    echo "WARN hermes_workspace_gemini_provider_patch=unavailable"
  fi
fi

mkdir -p "$HERMES_HOME" "$HOME" "$HERMES_WORKSPACE_DIR"

OPENCLAW_NAS_CONTAINER_PATH="${OPENCLAW_NAS_CONTAINER_PATH:-/workspace/nas_docs}"
HERMES_WORKSPACE_NAS_PATH="$HERMES_WORKSPACE_DIR/nas_docs"
if [ "$OPENCLAW_NAS_CONTAINER_PATH" != "$HERMES_WORKSPACE_NAS_PATH" ] && [ -d "$OPENCLAW_NAS_CONTAINER_PATH" ]; then
  if [ -L "$HERMES_WORKSPACE_NAS_PATH" ]; then
    ln -sfn "$OPENCLAW_NAS_CONTAINER_PATH" "$HERMES_WORKSPACE_NAS_PATH"
  elif [ -e "$HERMES_WORKSPACE_NAS_PATH" ]; then
    if [ -d "$HERMES_WORKSPACE_NAS_PATH" ] && rmdir "$HERMES_WORKSPACE_NAS_PATH" 2>/dev/null; then
      ln -s "$OPENCLAW_NAS_CONTAINER_PATH" "$HERMES_WORKSPACE_NAS_PATH"
    else
      echo "WARN hermes_workspace_nas_path_exists=$HERMES_WORKSPACE_NAS_PATH"
    fi
  else
    ln -s "$OPENCLAW_NAS_CONTAINER_PATH" "$HERMES_WORKSPACE_NAS_PATH"
  fi
fi

for _ in $(seq 1 90); do
  if curl -fsS http://127.0.0.1:8642/health >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

for _ in $(seq 1 90); do
  if curl -fsS "$HERMES_DASHBOARD_URL" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

cd /opt/hermes-workspace
exec s6-setuidgid hermes node "--max-old-space-size=${NODE_MAX_OLD_SPACE_SIZE:-2048}" server-entry.js
