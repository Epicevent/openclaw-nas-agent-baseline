#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  approve-openclaw-device.sh DEVICE_ID
  approve-openclaw-device.sh --list

Approves or lists OpenClaw Control UI devices for the current Linux account.

Run this as the target account, for example:

  sudo su - oc1
  bash /opt/openclaw-nas-agent-baseline/scripts/approve-openclaw-device.sh 62a39efd-d9d4-4eb4-8bdb-b9bbf61e1668
USAGE
}

mode="approve"
device_id=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --list)
      mode="list"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      if [[ -n "$device_id" ]]; then
        echo "error: too many arguments" >&2
        usage >&2
        exit 2
      fi
      device_id="$1"
      shift
      ;;
  esac
done

if [[ "$mode" == "approve" && -z "$device_id" ]]; then
  echo "error: DEVICE_ID is required" >&2
  usage >&2
  exit 2
fi

openclaw_dir="${OPENCLAW_DIR:-$HOME/openclaw}"
if [[ ! -d "$openclaw_dir" ]]; then
  echo "error: OpenClaw directory not found: $openclaw_dir" >&2
  exit 1
fi

compose_args=(-f docker-compose.yml)
[[ -f "$openclaw_dir/docker-compose.extra.yml" ]] && compose_args+=(-f docker-compose.extra.yml)
[[ -f "$openclaw_dir/docker-compose.host-user.yml" ]] && compose_args+=(-f docker-compose.host-user.yml)
[[ -f "$openclaw_dir/docker-compose.sandbox.yml" ]] && compose_args+=(-f docker-compose.sandbox.yml)

project="openclaw-$(id -un | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')"
if [[ -f "$openclaw_dir/.env" ]]; then
  existing_project="$(awk -F= '$1=="COMPOSE_PROJECT_NAME"{print $2}' "$openclaw_dir/.env" | tail -1)"
  existing_project="${existing_project//$'\r'/}"
  existing_project="${existing_project//\"/}"
  existing_project="${existing_project//\'/}"
  existing_project="$(printf '%s' "$existing_project" | tr -d '[:space:]')"
  [[ -n "$existing_project" ]] && project="$existing_project"
fi

cd "$openclaw_dir"
export COMPOSE_PROJECT_NAME="$project"

# The CLI service shares the gateway container's network namespace. Inside that
# namespace the gateway listens on the container port 18789, not the host-mapped
# per-account port such as 28789/28889.
run_cli() {
  docker compose "${compose_args[@]}" run --rm \
    -e OPENCLAW_GATEWAY_PORT="${OPENCLAW_GATEWAY_CONTAINER_PORT:-18789}" \
    openclaw-cli "$@"
}

if [[ "$mode" == "list" ]]; then
  run_cli devices list
else
  run_cli devices approve "$device_id"
fi
