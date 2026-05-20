#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  install.sh [--prefix DIR] [--repair-user USER] [--repair-users LIST] [--force-defaults] [--check]

Installs this OpenClaw NAS agent baseline bundle into a host path.

Default:
  /opt/openclaw-nas-agent-baseline

Examples:
  sudo bash install.sh
  sudo bash install.sh --check

This installer does not store NAS credentials, OpenClaw tokens, or API keys.
USAGE
}

prefix="/opt/openclaw-nas-agent-baseline"
repair_users=()
force_defaults=0
run_check=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix)
      prefix="${2:?missing prefix}"
      shift 2
      ;;
    --repair-user)
      repair_users+=("${2:?missing user}")
      shift 2
      ;;
    --repair-users)
      IFS=',' read -r -a parsed_users <<<"${2:?missing users}"
      repair_users+=("${parsed_users[@]}")
      shift 2
      ;;
    --force-defaults)
      force_defaults=1
      shift
      ;;
    --check)
      run_check=1
      shift
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

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "$prefix" in
  /opt/*)
    if [[ "$(id -u)" -ne 0 ]]; then
      echo "error: installing under /opt requires root. Re-run with sudo or use --prefix." >&2
      exit 1
    fi
    ;;
esac

mkdir -p "$prefix"

tmp_exclude="$(mktemp)"
cleanup() {
  rm -f "$tmp_exclude"
}
trap cleanup EXIT

cat > "$tmp_exclude" <<'EOF'
./.git
./dist
./*.tar.gz
./*.zip
EOF

tar -C "$script_dir" --exclude-from="$tmp_exclude" -cf - . | tar -C "$prefix" -xf -

chmod +x "$prefix/install.sh" "$prefix"/scripts/*.sh "$prefix"/container/*.sh 2>/dev/null || true

if [[ "$(id -u)" -eq 0 ]]; then
  chown -R root:root "$prefix"
fi

echo "installed: $prefix"

for user in "${repair_users[@]}"; do
  [[ -n "$user" ]] || continue
  args=(--user "$user")
  if [[ "$force_defaults" -eq 1 ]]; then
    args+=(--force-defaults)
  fi
  echo "repairing OpenClaw state for: $user"
  bash "$prefix/scripts/repair-openclaw-state.sh" "${args[@]}"
done

if [[ "$run_check" -eq 1 ]]; then
  echo "running baseline check:"
  bash "$prefix/scripts/check-baseline.sh" || true
fi

cat <<EOF

Next useful commands:
  cd $prefix
  sudo bash scripts/patch-openclaw-bootstrap-install-env.sh
  sudo bash scripts/patch-openclaw-bootstrap-install-env.sh --check
  sudo bash scripts/check-customer-mode-isolation.sh --user oc1
  sudo bash scripts/check-customer-deployment.sh --user oc1 --expected-basepath / --expected-origin https://oc1.ji-tech.co.kr
  less README.md
EOF
