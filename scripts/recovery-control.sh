#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'USAGE'
Usage:
  recovery-control.sh backup [backup args...]
  recovery-control.sh repair [repair args...]
USAGE
}

command_name="${1:-}"
shift || true

case "$command_name" in
  backup)
    exec bash "$script_dir/internal/recovery-backup-openclaw-state.bash" "$@"
    ;;
  repair)
    exec bash "$script_dir/internal/recovery-repair-openclaw-state.bash" "$@"
    ;;
  -h|--help|help|"")
    usage
    ;;
  *)
    echo "error: unknown recovery-control command: $command_name" >&2
    usage >&2
    exit 2
    ;;
esac
