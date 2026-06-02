#!/usr/bin/env bash
set -euo pipefail

HERMES_HOME="${HERMES_HOME:-/opt/data}"
HERMES_DATA_DIR="${HERMES_DATA_DIR:-$HERMES_HOME}"
HERMES_WORKSPACE_DIR="${HERMES_WORKSPACE_DIR:-/workspace}"
HERMES_API_URL="${HERMES_API_URL:-http://127.0.0.1:8642}"
HERMES_DASHBOARD_URL="${HERMES_DASHBOARD_URL:-http://127.0.0.1:9119}"
HERMES_API_TOKEN="${HERMES_API_TOKEN:-${API_SERVER_KEY:-}}"
HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-3000}"
HOME="${HOME:-$HERMES_HOME/home}"

export HERMES_HOME
export HERMES_DATA_DIR
export HERMES_WORKSPACE_DIR
export HERMES_API_URL
export HERMES_DASHBOARD_URL
export HERMES_API_TOKEN
export HOST
export PORT
export HOME
export HERMES_DASHBOARD="${HERMES_DASHBOARD:-1}"
export HERMES_DASHBOARD_HOST="${HERMES_DASHBOARD_HOST:-127.0.0.1}"
export HERMES_DASHBOARD_PORT="${HERMES_DASHBOARD_PORT:-9119}"
export HERMES_DASHBOARD_INSECURE="${HERMES_DASHBOARD_INSECURE:-1}"
export API_SERVER_ENABLED="${API_SERVER_ENABLED:-true}"
export API_SERVER_HOST="${API_SERVER_HOST:-127.0.0.1}"
export COOKIE_SECURE="${COOKIE_SECURE:-1}"
export TRUST_PROXY="${TRUST_PROXY:-1}"
export NODE_ENV="${NODE_ENV:-production}"

mkdir -p "$HERMES_HOME" "$HOME" "$HERMES_WORKSPACE_DIR"

run_as=()
if [[ "$(id -u)" -eq 0 && -n "${HERMES_UID:-${PUID:-}}" && -n "${HERMES_GID:-${PGID:-}}" ]] \
  && command -v gosu >/dev/null 2>&1; then
  run_as=(gosu "${HERMES_UID:-${PUID}}:${HERMES_GID:-${PGID}}")
fi

gateway_pid=""
workspace_pid=""

shutdown() {
  local rc=$?
  if [[ -n "$workspace_pid" ]]; then
    kill "$workspace_pid" >/dev/null 2>&1 || true
  fi
  if [[ -n "$gateway_pid" ]]; then
    kill "$gateway_pid" >/dev/null 2>&1 || true
  fi
  wait >/dev/null 2>&1 || true
  exit "$rc"
}
trap shutdown INT TERM EXIT

"${run_as[@]}" hermes gateway run &
gateway_pid="$!"

for _ in $(seq 1 90); do
  if curl -fsS http://127.0.0.1:8642/health >/dev/null 2>&1; then
    break
  fi
  if ! kill -0 "$gateway_pid" >/dev/null 2>&1; then
    wait "$gateway_pid"
  fi
  sleep 1
done

cd /opt/hermes-workspace
"${run_as[@]}" node "--max-old-space-size=${NODE_MAX_OLD_SPACE_SIZE:-2048}" server-entry.js &
workspace_pid="$!"

wait -n "$gateway_pid" "$workspace_pid"
