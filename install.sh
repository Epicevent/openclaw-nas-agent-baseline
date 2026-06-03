#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  install.sh [--prefix DIR] [--ops-registry PATH] [--no-ops-registry-sync] [--repair-user USER] [--repair-users LIST] [--force-defaults] [--check]

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
ops_registry="${OPENCLAW_OPS_REGISTRY:-/srv/openclaw-ops/slots.yaml}"
sync_ops_registry=1
repair_users=()
force_defaults=0
run_check=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix)
      prefix="${2:?missing prefix}"
      shift 2
      ;;
    --ops-registry)
      ops_registry="${2:?missing ops registry path}"
      shift 2
      ;;
    --no-ops-registry-sync)
      sync_ops_registry=0
      shift
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

sync_ops_registry_baseline() {
  local registry="$1"
  if [[ "$sync_ops_registry" -ne 1 ]]; then
    echo "ops_registry_sync=skipped disabled"
    return 0
  fi
  if [[ -z "$registry" || ! -f "$registry" ]]; then
    echo "ops_registry_sync=skipped missing"
    return 0
  fi
  if [[ "$source_commit" == "unknown" ]]; then
    echo "ops_registry_sync=skipped unknown_source_commit"
    return 0
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    echo "ops_registry_sync=skipped python3_missing"
    return 0
  fi

  python3 - "$registry" "$source_commit" <<'PY'
from __future__ import annotations

import os
import re
import stat
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

path = Path(sys.argv[1])
commit = sys.argv[2]
updated_at = datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")

text = path.read_text(encoding="utf-8")
lines = text.splitlines(keepends=True)
out: list[str] = []
in_meta = False
seen_meta = False
seen_baseline = False
seen_updated_at = False
changed = False

def q(value: str) -> str:
    return '"' + value.replace('"', '\\"') + '"'

def current_value(line: str) -> str:
    return line.split(":", 1)[1].strip().strip('"').strip("'")

for line in lines:
    stripped = line.strip()
    if stripped == "meta:":
        in_meta = True
        seen_meta = True
        out.append(line)
        continue
    if stripped == "slots:" and in_meta:
        if not seen_baseline:
            out.append(f"  baseline_commit: {q(commit)}\n")
            changed = True
        if not seen_updated_at:
            out.append(f"  updated_at: {q(updated_at)}\n")
            changed = True
        in_meta = False
        out.append(line)
        continue
    if in_meta and re.match(r"^\s{2}baseline_commit:", line):
        seen_baseline = True
        if current_value(line) != commit:
            out.append(f"  baseline_commit: {q(commit)}\n")
            changed = True
        else:
            out.append(line)
        continue
    if in_meta and re.match(r"^\s{2}updated_at:", line):
        seen_updated_at = True
        if current_value(line) != updated_at:
            out.append(f"  updated_at: {q(updated_at)}\n")
            changed = True
        else:
            out.append(line)
        continue
    out.append(line)

if not seen_meta:
    raise SystemExit("ops registry has no meta section")

if not text.endswith("\n"):
    out.append("\n")

if not changed:
    print(f"ops_registry_sync=unchanged path={path} baseline_commit={commit}")
    raise SystemExit(0)

st = path.stat()
fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent))
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.writelines(out)
    os.chmod(tmp_name, stat.S_IMODE(st.st_mode))
    try:
        os.chown(tmp_name, st.st_uid, st.st_gid)
    except PermissionError:
        pass
    os.replace(tmp_name, path)
finally:
    try:
        os.unlink(tmp_name)
    except FileNotFoundError:
        pass

print(f"ops_registry_sync=updated path={path} baseline_commit={commit}")
PY
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
find "$prefix/scripts" -type f -name '*.sh' -exec chmod +x {} + 2>/dev/null || true
find "$prefix/scripts" -type f -name '*.py' -exec chmod +x {} + 2>/dev/null || true
find "$prefix/admin-cli/bin" -type f -exec chmod +x {} + 2>/dev/null || true

if [[ "$(id -u)" -eq 0 ]]; then
  chown -R root:root "$prefix"
  if [[ -x "$prefix/scripts/customer-nas-mount.sh" ]]; then
    mkdir -p /usr/local/bin
    ln -sfn "$prefix/scripts/customer-nas-mount.sh" /usr/local/bin/openclaw-nas-mount
  fi
fi

write_baseline_manifest
sync_ops_registry_baseline "$ops_registry"

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
