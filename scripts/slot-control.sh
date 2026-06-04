#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'USAGE'
Usage:
  slot-control.sh install-openclaw [install args...]
  slot-control.sh install-hermes [install args...]
  slot-control.sh runtime-secrets [secret args...]
  slot-control.sh subdomain [subdomain args...]
  slot-control.sh isolation [isolation args...]
  slot-control.sh approve-device [device args...]
  slot-control.sh hermes-guidance [guidance args...]
USAGE
}

command_name="${1:-}"
shift || true

case "$command_name" in
  install-openclaw)
    exec bash "$script_dir/internal/install-customer-slot-from-image.bash" "$@"
    ;;
  install-hermes)
    exec bash "$script_dir/internal/install-hermes-slot-from-image.bash" "$@"
    ;;
  runtime-secrets)
    exec bash "$script_dir/internal/apply-runtime-secrets.bash" "$@"
    ;;
  subdomain)
    exec bash "$script_dir/internal/apply-subdomain-mode.bash" "$@"
    ;;
  isolation)
    exec bash "$script_dir/internal/apply-customer-mode-isolation.bash" "$@"
    ;;
  approve-device)
    exec bash "$script_dir/internal/approve-openclaw-device.bash" "$@"
    ;;
  hermes-guidance)
    exec bash "$script_dir/internal/apply-hermes-workspace-guidance.bash" "$@"
    ;;
  -h|--help|help|"")
    usage
    ;;
  *)
    echo "error: unknown slot-control command: $command_name" >&2
    usage >&2
    exit 2
    ;;
esac
