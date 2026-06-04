#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  openclaw-heartbeat-control.sh status --user USER
  openclaw-heartbeat-control.sh status --range START END
  openclaw-heartbeat-control.sh disable --user USER
  openclaw-heartbeat-control.sh disable --range START END

Shows optional OpenClaw workspace HEARTBEAT.md files and disables the
OpenClaw heartbeat cadence.

This script prints file metadata only. It does not print heartbeat contents,
NAS credentials, gateway tokens, or provider/API keys.
USAGE
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/lib-safe-compose.bash"

command_name="${1:-}"
shift || true

target_user=""
range_start=""
range_end=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user)
      target_user="${2:?missing user}"
      shift 2
      ;;
    --range)
      range_start="${2:?missing start}"
      range_end="${3:?missing end}"
      shift 3
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

validate_user_name() {
  local user="$1"
  [[ "$user" =~ ^oc[1-9][0-9]*$ ]] || {
    echo "error: invalid customer user: $user" >&2
    exit 2
  }
}

customer_home() {
  getent passwd "$1" | cut -d: -f6
}

heartbeat_files_for_user() {
  local user="$1" home workspace
  home="$(customer_home "$user")"
  workspace="$home/.openclaw/workspace"
  [[ -d "$workspace" ]] || return 0
  find "$workspace" -xdev -maxdepth 5 \( -type f -o -type l \) -name 'HEARTBEAT.md' -print 2>/dev/null | sort
}

print_heartbeat_config_status_for_user() {
  local user="$1" home config_path safety_output
  home="$(customer_home "$user")"
  config_path="$home/.openclaw/openclaw.json"

  if [[ ! -e "$config_path" ]]; then
    echo "heartbeat_config=missing"
    echo "heartbeat_config_every=30m"
    echo "heartbeat_config_enabled=yes"
    echo "heartbeat_config_note=missing_config_uses_openclaw_default"
    return 0
  fi

  if safety_output="$(openclaw_assert_safe_openclaw_config_file "$user" "$config_path" 2>&1)"; then
    echo "heartbeat_config_safe=yes"
  else
    echo "heartbeat_config_safe=no"
    echo "heartbeat_config_safety_detail=$safety_output"
    return 1
  fi

  OPENCLAW_CONFIG_PATH="$config_path" python3 - <<'PY'
import json
import os
from pathlib import Path

path = Path(os.environ["OPENCLAW_CONFIG_PATH"])
try:
    data = json.loads(path.read_text(encoding="utf-8"))
except Exception as exc:
    print("heartbeat_config_parse=fail")
    print(f"heartbeat_config_parse_error={exc.__class__.__name__}")
    raise SystemExit(1)

heartbeat = (
    data.get("agents", {})
    .get("defaults", {})
    .get("heartbeat")
)
agents = data.get("agents", {})
defaults = agents.get("defaults", {})
default_heartbeat = defaults.get("heartbeat")
default_every = "30m"
if isinstance(default_heartbeat, dict) and default_heartbeat.get("every"):
    default_every = str(default_heartbeat.get("every"))
agent_entries = agents.get("list")
if not isinstance(agent_entries, list):
    agent_entries = []
agent_heartbeats = []
for index, entry in enumerate(agent_entries):
    if not isinstance(entry, dict):
        continue
    hb = entry.get("heartbeat")
    if isinstance(hb, dict):
        agent_id = entry.get("id") or str(index)
        every = str(hb.get("every") or default_every)
        agent_heartbeats.append((agent_id, every))

if isinstance(heartbeat, dict):
    print("heartbeat_config=present")
    print(f"heartbeat_config_every={default_every}")
    print(f"heartbeat_config_model={heartbeat.get('model', '')}")
else:
    print("heartbeat_config=absent")
    print("heartbeat_config_every=30m")
print(f"heartbeat_agent_overrides_count={len(agent_heartbeats)}")
for offset, (agent_id, every) in enumerate(agent_heartbeats, 1):
    print(f"heartbeat_agent_{offset}_id={agent_id}")
    print(f"heartbeat_agent_{offset}_every={every}")
if agent_heartbeats:
    enabled = any(every != "0m" for _, every in agent_heartbeats)
else:
    enabled = default_every != "0m"
print(f"heartbeat_config_enabled={'yes' if enabled else 'no'}")
PY
}

print_heartbeat_status_for_user() {
  local user="$1" file count=0
  validate_user_name "$user"
  echo "target_user=$user"
  if ! id "$user" >/dev/null 2>&1; then
    echo "user_status=missing"
    return 1
  fi
  echo "user_status=present"
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    count=$((count + 1))
    echo "heartbeat_file_$count=$file"
    stat -c "heartbeat_file_${count}_type=%F" "$file" 2>/dev/null || true
    stat -c "heartbeat_file_${count}_owner=%U:%G" "$file" 2>/dev/null || true
    stat -c "heartbeat_file_${count}_mode=%a" "$file" 2>/dev/null || true
    stat -c "heartbeat_file_${count}_size=%s" "$file" 2>/dev/null || true
    stat -c "heartbeat_file_${count}_mtime=%y" "$file" 2>/dev/null || true
  done < <(heartbeat_files_for_user "$user")
  echo "heartbeat_files_count=$count"
  echo "heartbeat_files_note=optional_checklist_not_the_scheduler"
  print_heartbeat_config_status_for_user "$user"
}

disable_heartbeat_for_user() {
  local user="$1" file count=0 home config_path runtime_user config_changed=0
  validate_user_name "$user"
  echo "target_user=$user"
  if ! id "$user" >/dev/null 2>&1; then
    echo "user_status=missing"
    return 1
  fi
  echo "user_status=present"
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    count=$((count + 1))
  done < <(heartbeat_files_for_user "$user")
  echo "heartbeat_files_count=$count"
  echo "heartbeat_files_action=left_untouched_optional_checklist"

  home="$(customer_home "$user")"
  config_path="$home/.openclaw/openclaw.json"
  runtime_user="${user}_rt"
  openclaw_assert_managed_slot_prewrite "$user"
  openclaw_assert_safe_openclaw_config_file "$user" "$config_path"
  if OPENCLAW_CONFIG_PATH="$config_path" python3 - <<'PY'
import json
import os
from pathlib import Path

path = Path(os.environ["OPENCLAW_CONFIG_PATH"])

def safe_write_regular(target: Path, text: str) -> None:
    flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    fd = os.open(target, flags, 0o600)
    try:
        st = os.fstat(fd)
        if not os.path.isfile(target):
            raise RuntimeError("not a regular file")
        if st.st_nlink != 1:
            raise RuntimeError("hardlink count is not 1")
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            fd = -1
            handle.write(text)
    finally:
        if fd != -1:
            os.close(fd)

if path.exists():
    data = json.loads(path.read_text(encoding="utf-8"))
else:
    data = {}
agents = data.setdefault("agents", {})
defaults = agents.setdefault("defaults", {})
heartbeat = defaults.setdefault("heartbeat", {})
if not isinstance(heartbeat, dict):
    heartbeat = {}
    defaults["heartbeat"] = heartbeat
heartbeat["every"] = "0m"

agent_entries = agents.get("list")
agent_overrides_disabled = 0
if isinstance(agent_entries, list):
    for entry in agent_entries:
        if not isinstance(entry, dict):
            continue
        hb = entry.get("heartbeat")
        if isinstance(hb, dict):
            hb["every"] = "0m"
            agent_overrides_disabled += 1

safe_write_regular(path, json.dumps(data, indent=2, ensure_ascii=False) + "\n")
print("heartbeat_config_disabled=yes")
print("heartbeat_config_every=0m")
print(f"heartbeat_agent_overrides_disabled={agent_overrides_disabled}")
PY
  then
    config_changed=1
  else
    return 1
  fi
  chown "$runtime_user:$runtime_user" "$config_path"
  chmod 0600 "$config_path"
  openclaw_assert_safe_openclaw_config_file "$user" "$config_path"
  [[ "$config_changed" -eq 1 ]] || true
}

run_for_selection() {
  local action="$1" failed=0 i user
  if [[ -n "$target_user" && -n "$range_start" ]]; then
    echo "error: use either --user or --range, not both" >&2
    exit 2
  fi
  if [[ -n "$target_user" ]]; then
    "$action" "$target_user"
    return $?
  fi
  if [[ -n "$range_start" || -n "$range_end" ]]; then
    [[ "$range_start" =~ ^[0-9]+$ && "$range_end" =~ ^[0-9]+$ && "$range_start" -le "$range_end" ]] || {
      echo "error: invalid range" >&2
      exit 2
    }
    for i in $(seq "$range_start" "$range_end"); do
      user="oc$i"
      echo "== $user =="
      "$action" "$user" || failed=1
    done
    return "$failed"
  fi
  usage >&2
  exit 2
}

case "$command_name" in
  status)
    run_for_selection print_heartbeat_status_for_user
    ;;
  disable)
    run_for_selection disable_heartbeat_for_user
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    echo "error: unknown command: ${command_name:-}" >&2
    usage >&2
    exit 2
    ;;
esac
