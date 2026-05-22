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
source_commit="${OPENCLAW_BASELINE_COMMIT:-}"
source_dirty="unknown"
source_remote=""

if [[ -z "$source_commit" ]] && command -v git >/dev/null 2>&1 && git -C "$script_dir" rev-parse --verify HEAD >/dev/null 2>&1; then
  source_commit="$(git -C "$script_dir" rev-parse HEAD)"
  source_remote="$(git -C "$script_dir" config --get remote.origin.url 2>/dev/null || true)"
  if [[ -n "$(git -C "$script_dir" status --porcelain --untracked-files=no 2>/dev/null || true)" ]]; then
    source_dirty="dirty"
  else
    source_dirty="clean"
  fi
fi

source_commit="${source_commit:-unknown}"
source_remote="${source_remote:-unknown}"

write_baseline_manifest() {
  local manifest="$prefix/.openclaw-baseline-manifest"
  local tmp installed_at installed_by
  installed_at="$(date -Iseconds)"
  installed_by="$(id -un 2>/dev/null || echo unknown)"
  tmp="$(mktemp)"
  cat > "$tmp" <<EOF
schema_version=1
source_commit=$source_commit
source_dirty=$source_dirty
source_remote=$source_remote
installed_at=$installed_at
installed_by=$installed_by
install_prefix=$prefix
EOF
  if [[ "$(id -u)" -eq 0 ]]; then
    install -o root -g root -m 0644 "$tmp" "$manifest"
  else
    install -m 0644 "$tmp" "$manifest"
  fi
  rm -f "$tmp"
}

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

chmod +x "$prefix/install.sh" "$prefix"/container/*.sh 2>/dev/null || true
find "$prefix/scripts" -type f -name '*.sh' -exec chmod +x {} + 2>/dev/null || true

if [[ "$(id -u)" -eq 0 ]]; then
  chown -R root:root "$prefix"
  if [[ -x "$prefix/scripts/customer-nas-mount.sh" ]]; then
    mkdir -p /usr/local/bin
    ln -sfn "$prefix/scripts/customer-nas-mount.sh" /usr/local/bin/openclaw-nas-mount
  fi
fi

write_baseline_manifest

echo "installed: $prefix"
echo "baseline_manifest=$prefix/.openclaw-baseline-manifest"
echo "baseline_commit=$source_commit"

for user in "${repair_users[@]}"; do
  [[ -n "$user" ]] || continue
  args=(--user "$user")
  if [[ "$force_defaults" -eq 1 ]]; then
    args+=(--force-defaults)
  fi
  echo "repairing OpenClaw state for: $user"
  bash "$prefix/scripts/recovery/repair-openclaw-state.sh" "${args[@]}"
done

if [[ "$run_check" -eq 1 ]]; then
  echo "running baseline check:"
  bash "$prefix/scripts/check-docs.sh"
  bash "$prefix/scripts/check-baseline.sh" || true
fi

cat <<EOF

Next useful commands:
  cd $prefix
  sudo bash scripts/install-svcops-account.sh --set-password --nopasswd-sudo
  openclaw-nas-mount --help
  sudo bash scripts/install-customer-slot-from-image.sh --user oc1 --host oc1.ji-tech.co.kr --image openclaw-nas-agent:baseline
  sudo bash scripts/check-customer-mode-isolation.sh --user oc1
  sudo bash scripts/check-customer-deployment.sh --user oc1 --expected-basepath / --expected-origin https://oc1.ji-tech.co.kr
  less README.md
EOF
