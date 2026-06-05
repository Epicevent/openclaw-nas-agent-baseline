#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  install.sh [--prefix DIR] [--check]

Installs the slot operations package into a host path.

Default:
  /opt/openclaw-nas-agent-baseline

Examples:
  sudo bash install.sh
  sudo bash install.sh --check

This installer does not install product source, modify customer slots, build
runtime images, or repair product state. Customer slots are updated by image
rollout commands after a registry image has been verified.

This installer does not store NAS credentials, provider/API keys, gateway
tokens, or customer data.
USAGE
}

prefix="/opt/openclaw-nas-agent-baseline"
run_check=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix)
      prefix="${2:?missing prefix}"
      shift 2
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

real_path() {
  local path="$1"
  if command -v realpath >/dev/null 2>&1; then
    realpath "$path"
  else
    (cd "$path" && pwd -P)
  fi
}

prune_installed_package() {
  local src_real prefix_real path
  src_real="$(real_path "$script_dir")"
  prefix_real="$(real_path "$prefix")"

  if [[ "$src_real" == "$prefix_real" ]]; then
    echo "install_prune=skipped_in_place"
    return 0
  fi

  # The list includes current package paths and legacy payload paths that
  # earlier installers may have copied into the operations prefix.
  for path in \
    README.md \
    LICENSE \
    .gitattributes \
    .gitignore \
    install.sh \
    admin-cli \
    compose \
    container \
    docs \
    examples \
    images \
    openclaw \
    scripts; do
    rm -rf -- "$prefix/$path"
  done
  echo "install_prune=managed_package_paths"
}

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

prefix_abs="$(realpath -m "$prefix")"
case "$prefix_abs" in
  /|/opt|/home|/usr|/var|/tmp)
    echo "error: refusing to install into unsafe prefix: $prefix_abs" >&2
    exit 1
    ;;
esac

mkdir -p "$prefix"
prune_installed_package

tmp_exclude="$(mktemp)"
cleanup() {
  rm -f "$tmp_exclude"
}
trap cleanup EXIT

cat > "$tmp_exclude" <<'EOF'
./.git
./dist
./temp
./*.tar.gz
./*.zip
EOF

tar -C "$script_dir" --exclude-from="$tmp_exclude" -cf - . | tar -C "$prefix" -xf -

chmod +x "$prefix/install.sh" 2>/dev/null || true
find "$prefix/images" -type f -name '*.sh' -exec chmod +x {} + 2>/dev/null || true
find "$prefix/images" -type f -name '*.py' -exec chmod +x {} + 2>/dev/null || true
for wrapper in \
  customer-nas-mount.sh \
  install-svcops-account.sh \
  ops-monitor.sh \
  recovery-control.sh \
  slot-control.sh \
  svcops-control.sh; do
  chmod +x "$prefix/scripts/$wrapper" 2>/dev/null || true
done
find "$prefix/scripts" -type f -name '*.py' -exec chmod +x {} + 2>/dev/null || true
find "$prefix/admin-cli/bin" -type f -exec chmod +x {} + 2>/dev/null || true

if [[ "$(id -u)" -eq 0 ]]; then
  chown -R root:root "$prefix"
  if [[ -x "$prefix/scripts/customer-nas-mount.sh" ]]; then
    mkdir -p /usr/local/bin
    ln -sfn "$prefix/scripts/customer-nas-mount.sh" /usr/local/bin/agent-nas-mount
    if [[ -L /usr/local/bin/openclaw-nas-mount ]]; then
      legacy_target="$(readlink /usr/local/bin/openclaw-nas-mount 2>/dev/null || true)"
      if [[ "$legacy_target" == "$prefix/scripts/customer-nas-mount.sh" ]]; then
        rm -f /usr/local/bin/openclaw-nas-mount
      fi
    fi
  fi
fi

write_baseline_manifest

echo "installed: $prefix"
echo "baseline_manifest=$prefix/.openclaw-baseline-manifest"
echo "installed_source_commit=$source_commit"

if [[ "$run_check" -eq 1 ]]; then
  echo "running operations package check:"
  bash "$prefix/scripts/internal/check-docs.bash"
  bash "$prefix/scripts/internal/check-baseline.bash"
fi

cat <<EOF

Next useful commands:
  cd $prefix
  sudo bash scripts/install-svcops-account.sh --set-password --nopasswd-sudo
  agent-nas-mount --help
  sudo scripts/ops-monitor.sh health-check --report /srv/openclaw-ops/reports/health-latest.txt
  less README.md
EOF
