#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  check-customer-mode-isolation.sh --user USER

Checks customer-mode isolation without printing secret values.

Expected pass state:
  - USER is not in the docker group
  - USER can read /home/USER/nas_docs
  - USER cannot read /home/USER/openclaw/.env
  - USER cannot read /home/USER/.openclaw/openclaw.json
  - USER cannot see GEMINI_API_KEY through /proc
  - Control UI device pairing is disabled for this hosted customer flow
  - gateway container has GEMINI_API_KEY and can read NAS

Run as root/admin.
USAGE
}

target_user=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user)
      target_user="${2:?missing user}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$target_user" ]]; then
  echo "error: --user is required" >&2
  usage >&2
  exit 2
fi

if [[ "$(id -u)" -ne 0 ]]; then
  echo "error: run with sudo/root" >&2
  exit 1
fi

target_home="$(getent passwd "$target_user" | cut -d: -f6)"
if [[ -z "$target_home" ]]; then
  echo "error: user not found: $target_user" >&2
  exit 1
fi

container="openclaw-${target_user}-openclaw-gateway-1"
runtime_env_path="$target_home/openclaw/.env"
config_path="$target_home/.openclaw/openclaw.json"
failed=0

pass() {
  printf 'PASS %s\n' "$1"
}

fail() {
  printf 'FAIL %s\n' "$1"
  failed=1
}

check() {
  local name="$1"
  shift
  if "$@"; then
    pass "$name"
  else
    fail "$name"
  fi
}

if id -nG "$target_user" | tr ' ' '\n' | grep -qx docker; then
  fail "customer_not_in_docker_group"
else
  pass "customer_not_in_docker_group"
fi

check "customer_nas_read_ok" sudo -u "$target_user" test -r "$target_home/nas_docs"

if [[ -f "$runtime_env_path" ]]; then
  pass "runtime_env_exists"
else
  fail "runtime_env_exists"
  echo "INFO missing_runtime_env=$runtime_env_path"
fi

if [[ -f "$config_path" ]]; then
  pass "config_exists"
else
  fail "config_exists"
  echo "INFO missing_config=$config_path"
fi

check "customer_runtime_env_blocked" sudo -u "$target_user" test ! -r "$runtime_env_path"
check "customer_config_blocked" sudo -u "$target_user" test ! -r "$config_path"

if [[ -f "$config_path" ]]; then
  if grep -q '"apiKey"' "$config_path"; then
    fail "config_has_no_literal_api_key"
  else
    pass "config_has_no_literal_api_key"
  fi
else
  fail "config_has_no_literal_api_key"
fi

if [[ -f "$config_path" ]] && sudo python3 - "$config_path" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
enabled = data.get("gateway", {}).get("controlUi", {}).get("dangerouslyDisableDeviceAuth") is True
raise SystemExit(0 if enabled else 1)
PY
then
  pass "control_ui_device_auth_disabled"
else
  fail "control_ui_device_auth_disabled"
fi

if sudo -u "$target_user" docker ps >/tmp/openclaw-customer-check-docker.out 2>/tmp/openclaw-customer-check-docker.err; then
  fail "customer_docker_blocked"
else
  pass "customer_docker_blocked"
fi

gateway_pids="$(pgrep -f 'node dist/index.js gateway' || true)"
proc_seen=no
for pid in $gateway_pids; do
  if sudo -u "$target_user" sh -c 'tr "\000" "\n" < "$1" | grep -q "^GEMINI_API_KEY="' sh "/proc/$pid/environ" >/dev/null 2>&1; then
    proc_seen=yes
  fi
done

if [[ "$proc_seen" == "no" ]]; then
  pass "customer_proc_env_gemini_blocked"
else
  fail "customer_proc_env_gemini_blocked"
fi

if docker inspect "$container" >/dev/null 2>&1; then
  docker inspect "$container" --format 'INFO container_user={{.Config.User}} status={{.State.Status}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}'
  if docker exec "$container" sh -lc 'test -n "$GEMINI_API_KEY"'; then
    pass "container_env_gemini_present"
  else
    fail "container_env_gemini_present"
  fi

  if docker exec "$container" sh -lc 'test -r /home/node/nas_docs'; then
    pass "container_nas_read_ok"
  else
    fail "container_nas_read_ok"
  fi

  sample="$(docker exec "$container" sh -lc 'find /home/node/nas_docs -maxdepth 1 -mindepth 1 2>/dev/null | head -3 | wc -l' || echo 0)"
  echo "INFO container_nas_sample=$sample"
else
  fail "container_exists"
fi

exit "$failed"
