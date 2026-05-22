#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  backup-openclaw-state.sh [--user USER] [--home HOME] [--out-dir DIR]

Creates a local recovery snapshot for the repairable parts of ~/.openclaw.
It intentionally skips volatile databases, logs, device identity, and NAS data.

Examples:
  bash scripts/recovery/backup-openclaw-state.sh
  sudo bash scripts/recovery/backup-openclaw-state.sh --user oc1
USAGE
}

target_user=""
target_home=""
out_dir=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user)
      target_user="${2:?missing user}"
      shift 2
      ;;
    --home)
      target_home="${2:?missing home}"
      shift 2
      ;;
    --out-dir)
      out_dir="${2:?missing output dir}"
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

if [[ -n "$target_user" && -z "$target_home" ]]; then
  target_home="$(getent passwd "$target_user" | cut -d: -f6)"
fi

if [[ -z "$target_home" ]]; then
  target_home="${HOME:?HOME is not set}"
fi

if [[ -z "$target_user" ]]; then
  if command -v getent >/dev/null 2>&1; then
    target_user="$(getent passwd "$(id -u)" | cut -d: -f1 || true)"
  fi
  target_user="${target_user:-$(id -un)}"
fi

openclaw_dir="$target_home/.openclaw"
if [[ ! -d "$openclaw_dir" ]]; then
  echo "error: not found: $openclaw_dir" >&2
  exit 1
fi

timestamp="$(date +%Y%m%d%H%M%S)"
out_dir="${out_dir:-$target_home/.openclaw-recovery/snapshots}"
archive="$out_dir/openclaw-state-$target_user-$timestamp.tar.gz"
tmp_dir="$(mktemp -d)"
stage="$tmp_dir/openclaw-state/.openclaw"

cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

mkdir -p "$stage" "$out_dir"

copy_rel() {
  local rel="$1"
  local src="$openclaw_dir/$rel"
  local dst="$stage/$rel"

  if [[ -e "$src" || -L "$src" ]]; then
    mkdir -p "$(dirname "$dst")"
    cp -a "$src" "$dst"
  fi
}

copy_rel "openclaw.json"
copy_rel "exec-approvals.json"
copy_rel "agents"
copy_rel "plugin-skills"
copy_rel "completions"
copy_rel "canvas"
copy_rel "workspace/AGENTS.md"
copy_rel "workspace/TOOLS.md"
copy_rel "workspace/USER.md"
copy_rel "workspace/IDENTITY.md"
copy_rel "workspace/HEARTBEAT.md"
copy_rel "workspace/SOUL.md"
copy_rel "workspace/.clawhub"
copy_rel "workspace/.openclaw"
copy_rel "workspace/skills"
copy_rel "workspace/nas"
copy_rel "workspace/nas_docs"

tar -C "$tmp_dir" -czf "$archive" openclaw-state

if [[ "$(id -u)" -eq 0 ]] && id "$target_user" >/dev/null 2>&1; then
  chown "$target_user:$target_user" "$archive"
fi

echo "$archive"
