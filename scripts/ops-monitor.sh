#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'USAGE'
Usage:
  ops-monitor.sh drift-check [args...]
  ops-monitor.sh drift-watch [args...]
  ops-monitor.sh usage [usage args...]
USAGE
}

command_name="${1:-}"
shift || true

case "$command_name" in
  drift-check)
    exec bash "$script_dir/internal/openclaw-ops-drift-check.bash" "$@"
    ;;
  drift-watch)
    exec bash "$script_dir/internal/openclaw-ops-drift-watch.bash" "$@"
    ;;
  usage)
    exec bash "$script_dir/internal/openclaw-usage-report.bash" "$@"
    ;;
  -h|--help|help|"")
    usage
    ;;
  *)
    echo "error: unknown ops-monitor command: $command_name" >&2
    usage >&2
    exit 2
    ;;
esac
