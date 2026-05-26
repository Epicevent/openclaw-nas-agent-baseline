#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  openclaw-heartbeat-control.sh status --user USER
  openclaw-heartbeat-control.sh status --range START END
  openclaw-heartbeat-control.sh disable --user USER
  openclaw-heartbeat-control.sh disable --range START END

Finds or disables OpenClaw workspace HEARTBEAT.md files.

This script prints file metadata only. It does not print heartbeat contents,
NAS credentials, gateway tokens, or provider/API keys.
USAGE
}

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
  if [[ "$count" -gt 0 ]]; then
    echo "heartbeat_enabled=yes"
  else
    echo "heartbeat_enabled=no"
  fi
}

disable_heartbeat_for_user() {
  local user="$1" file stamp count=0 disabled
  validate_user_name "$user"
  echo "target_user=$user"
  if ! id "$user" >/dev/null 2>&1; then
    echo "user_status=missing"
    return 1
  fi
  echo "user_status=present"
  stamp="$(date +%Y%m%d%H%M%S)"
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    count=$((count + 1))
    if [[ "$file" != */HEARTBEAT.md ]]; then
      echo "heartbeat_skip_$count=unexpected_path"
      echo "heartbeat_file_$count=$file"
      continue
    fi
    disabled="${file}.disabled.${stamp}"
    mv -- "$file" "$disabled"
    echo "heartbeat_disabled_$count=$disabled"
  done < <(heartbeat_files_for_user "$user")
  echo "heartbeat_disabled_count=$count"
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
