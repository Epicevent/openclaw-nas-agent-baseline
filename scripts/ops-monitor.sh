#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'USAGE'
Usage:
  ops-monitor.sh health-check [args...]
  ops-monitor.sh health-watch [args...]
  ops-monitor.sh nas-request-check [args...]
  ops-monitor.sh nas-request-watch [args...]
  ops-monitor.sh usage [usage args...]
USAGE
}

command_name="${1:-}"
shift || true

case "$command_name" in
  health-check)
    exec bash "$script_dir/internal/openclaw-ops-health-check.bash" "$@"
    ;;
  health-watch)
    exec bash "$script_dir/internal/openclaw-ops-health-watch.bash" "$@"
    ;;
  drift-check)
    exec bash "$script_dir/internal/openclaw-ops-health-check.bash" "$@"
    ;;
  drift-watch)
    exec bash "$script_dir/internal/openclaw-ops-health-watch.bash" "$@"
    ;;
  nas-request-check)
    exec bash "$script_dir/internal/openclaw-nas-request-monitor.bash" check "$@"
    ;;
  nas-request-watch)
    exec bash "$script_dir/internal/openclaw-nas-request-monitor.bash" watch "$@"
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
