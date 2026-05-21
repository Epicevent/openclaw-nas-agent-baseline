#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  check-customer-mode-isolation.sh --user USER [--expected-basepath PATH] [--expected-origin ORIGIN]

Checks customer-mode isolation without printing secret values.

Expected pass state:
  - USER is not in the docker group
  - /home/USER/nas_docs is readable and contains registered CIFS share mounts
  - USER cannot read /home/USER/openclaw/.env
  - USER cannot read /home/USER/.openclaw/openclaw.json
  - USER cannot see GEMINI_API_KEY through /proc
  - Control UI device pairing is disabled for this hosted customer flow
  - gateway container has GEMINI_API_KEY and sees the NAS as a CIFS mount

Run as root/admin.
USAGE
}

target_user=""
expected_basepath=""
expected_origin=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user)
      target_user="${2:?missing user}"
      shift 2
      ;;
    --expected-basepath)
      expected_basepath="${2:?missing basepath}"
      shift 2
      ;;
    --expected-origin)
      expected_origin="${2:?missing origin}"
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
nas_mountpoint="$target_home/nas_docs"
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

registered_nas_mountpoints() {
  local root="$1"
  awk -v root="$root" '
    $0 !~ /^[[:space:]]*#/ && $3 == "cifs" && ($2 == root || index($2, root "/") == 1) {
      print $2
    }
  ' /etc/fstab 2>/dev/null
}

container_path_for_nas_mountpoint() {
  local root="$1" mountpoint="$2" suffix
  if [[ "$mountpoint" == "$root" ]]; then
    printf '%s' "/home/node/nas_docs"
  else
    suffix="${mountpoint#$root/}"
    printf '/home/node/nas_docs/%s' "$suffix"
  fi
}

if id -nG "$target_user" | tr ' ' '\n' | grep -qx docker; then
  fail "customer_not_in_docker_group"
else
  pass "customer_not_in_docker_group"
fi

check "customer_nas_read_ok" sudo -u "$target_user" test -r "$nas_mountpoint"

visible_nas_mountpoints=()
mapfile -t nas_mountpoints < <(registered_nas_mountpoints "$nas_mountpoint")
if [[ "${#nas_mountpoints[@]}" -eq 0 ]]; then
  fail "customer_nas_mounted_cifs"
  echo "INFO customer_nas_registered_mounts=none"
else
  customer_nas_failed=0
  visible_nas_mountpoints=()
  echo "INFO customer_nas_registered_mount_count=${#nas_mountpoints[@]}"
  for nas_mp in "${nas_mountpoints[@]}"; do
    nas_target="$(findmnt -T "$nas_mp" -n -o TARGET 2>/dev/null | head -1 || true)"
    nas_source="$(findmnt -T "$nas_mp" -n -o SOURCE 2>/dev/null | head -1 || true)"
    nas_fstype="$(findmnt -T "$nas_mp" -n -o FSTYPE 2>/dev/null | head -1 || true)"
    if [[ "$nas_target" == "$nas_mp" && "$nas_fstype" == "cifs" ]]; then
      echo "INFO customer_nas_mount=$nas_mp source=$nas_source"
      visible_nas_mountpoints+=("$nas_mp")
      if sudo -u "$target_user" test -r "$nas_mp"; then
        :
      else
        customer_nas_failed=1
        echo "INFO customer_nas_mount_unreadable=$nas_mp"
      fi
    elif [[ "$nas_mp" == "$nas_mountpoint" && "${#nas_mountpoints[@]}" -gt 1 ]]; then
      :
    else
      customer_nas_failed=1
      echo "INFO customer_nas_mount_bad=$nas_mp target=${nas_target:-missing} fstype=${nas_fstype:-missing} source=${nas_source:-missing}"
    fi
  done
  if [[ "${#visible_nas_mountpoints[@]}" -gt 0 && "$customer_nas_failed" -eq 0 ]]; then
    pass "customer_nas_mounted_cifs"
  else
    fail "customer_nas_mounted_cifs"
  fi
fi

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

if [[ -n "$expected_basepath" ]]; then
  if [[ -f "$config_path" ]] && sudo python3 - "$config_path" "$expected_basepath" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
expected = sys.argv[2]
actual = data.get("gateway", {}).get("controlUi", {}).get("basePath")
if actual != expected:
    print(f"INFO control_ui_basepath actual={actual!r} expected={expected!r}")
    raise SystemExit(1)
PY
  then
    pass "control_ui_basepath_ok"
  else
    fail "control_ui_basepath_ok"
  fi
fi

if [[ -n "$expected_origin" ]]; then
  if [[ -f "$config_path" ]] && sudo python3 - "$config_path" "$expected_origin" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
expected = sys.argv[2].rstrip("/")
origins = data.get("gateway", {}).get("controlUi", {}).get("allowedOrigins") or []
origins = [str(origin).rstrip("/") for origin in origins]
if expected not in origins:
    print(f"INFO control_ui_allowed_origins actual={origins!r} expected={expected!r}")
    raise SystemExit(1)
PY
  then
    pass "control_ui_allowed_origin_ok"
  else
    fail "control_ui_allowed_origin_ok"
  fi
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

  if [[ "${#visible_nas_mountpoints[@]}" -eq 0 ]]; then
    fail "container_nas_mounted_cifs"
    echo "INFO container_nas_visible_mounts=none"
  else
    container_nas_failed=0
    for nas_mp in "${visible_nas_mountpoints[@]}"; do
      container_mp="$(container_path_for_nas_mountpoint "$nas_mountpoint" "$nas_mp")"
      if docker exec "$container" sh -lc 'test -r "$1"' sh "$container_mp"; then
        :
      else
        container_nas_failed=1
        echo "INFO container_nas_mount_unreadable=$container_mp"
      fi
      container_nas_source="$(docker exec "$container" findmnt -T "$container_mp" -n -o SOURCE 2>/dev/null | head -1 || true)"
      container_nas_target="$(docker exec "$container" findmnt -T "$container_mp" -n -o TARGET 2>/dev/null | head -1 || true)"
      container_nas_fstype="$(docker exec "$container" findmnt -T "$container_mp" -n -o FSTYPE 2>/dev/null | head -1 || true)"
      if [[ "$container_nas_target" == "$container_mp" && "$container_nas_fstype" == "cifs" ]]; then
        echo "INFO container_nas_mount=$container_mp source=$container_nas_source"
      else
        container_nas_failed=1
        echo "INFO container_nas_mount_bad=$container_mp target=${container_nas_target:-missing} fstype=${container_nas_fstype:-missing} source=${container_nas_source:-missing}"
      fi
    done
    if [[ "$container_nas_failed" -eq 0 ]]; then
      pass "container_nas_mounted_cifs"
    else
      fail "container_nas_mounted_cifs"
    fi
  fi

  sample="$(docker exec "$container" sh -lc 'find /home/node/nas_docs -maxdepth 1 -mindepth 1 2>/dev/null | head -3 | wc -l' || echo 0)"
  echo "INFO container_nas_sample=$sample"
else
  fail "container_exists"
fi

exit "$failed"
