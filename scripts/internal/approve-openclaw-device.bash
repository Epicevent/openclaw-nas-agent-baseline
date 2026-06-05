#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  slot-control.sh approve-device [--user USER] DEVICE_ID
  slot-control.sh approve-device [--user USER] --list

Approves or lists OpenClaw Control UI devices for an OpenClaw account.

Run as the target account in lab mode, or as admin/root with --user in customer
mode.

Examples:

  sudo /opt/openclaw-nas-agent-baseline/scripts/slot-control.sh approve-device --user oc1 --list
  sudo /opt/openclaw-nas-agent-baseline/scripts/slot-control.sh approve-device --user oc1 62a39efd-d9d4-4eb4-8bdb-b9bbf61e1668

  sudo su - oc1
  /opt/openclaw-nas-agent-baseline/scripts/slot-control.sh approve-device 62a39efd-d9d4-4eb4-8bdb-b9bbf61e1668
USAGE
}

mode="approve"
device_id=""
target_user=""
user_arg=0
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/internal/lib-safe-compose.bash
source "$script_dir/lib-safe-compose.bash"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user)
      target_user="${2:?missing user}"
      user_arg=1
      shift 2
      ;;
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

if [[ -n "$target_user" ]]; then
  target_home="$(getent passwd "$target_user" | cut -d: -f6)"
  if [[ -z "$target_home" ]]; then
    echo "error: user not found: $target_user" >&2
    exit 1
  fi
else
  target_user="$(id -un)"
  target_home="$HOME"
fi

openclaw_dir="${OPENCLAW_DIR:-$target_home/openclaw}"
if [[ ! -d "$openclaw_dir" ]]; then
  echo "error: OpenClaw directory not found: $openclaw_dir" >&2
  exit 1
fi

if [[ "$user_arg" -eq 1 ]]; then
  openclaw_assert_managed_slot_name "$target_user" || exit $?
  openclaw_assert_safe_compose_dir "$target_user" "$openclaw_dir"
fi

compose_args=(-f docker-compose.yml)
[[ -f "$openclaw_dir/docker-compose.source.yml" ]] && compose_args+=(-f docker-compose.source.yml)
[[ -f "$openclaw_dir/docker-compose.extra.yml" ]] && compose_args+=(-f docker-compose.extra.yml)
[[ -f "$openclaw_dir/docker-compose.host-user.yml" ]] && compose_args+=(-f docker-compose.host-user.yml)
[[ -f "$openclaw_dir/docker-compose.shared-ollama.yml" ]] && compose_args+=(-f docker-compose.shared-ollama.yml)
[[ -f "$openclaw_dir/docker-compose.sandbox.yml" ]] && compose_args+=(-f docker-compose.sandbox.yml)

project="openclaw-$(printf '%s' "$target_user" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')"
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
