#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  build-install-package.sh [--version VERSION] [--out-dir DIR]

Builds a simple tar.gz installation package for this repository.

Examples:
  bash scripts/build-install-package.sh
  bash scripts/build-install-package.sh --version 2026.05.19
USAGE
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
out_dir="$repo_root/dist"
version=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      version="${2:?missing version}"
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

if [[ -z "$version" ]]; then
  if git -C "$repo_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    short_sha="$(git -C "$repo_root" rev-parse --short HEAD)"
    version="$(date +%Y%m%d)-$short_sha"
  else
    version="$(date +%Y%m%d%H%M%S)"
  fi
fi

package_name="openclaw-nas-agent-baseline-$version"
package_path="$out_dir/$package_name.tar.gz"
stage_dir="$(mktemp -d)"

cleanup() {
  rm -rf "$stage_dir"
}
trap cleanup EXIT

mkdir -p "$out_dir" "$stage_dir/$package_name"

tar -C "$repo_root" \
  --exclude='./.git' \
  --exclude='./dist' \
  --exclude='./*.tar.gz' \
  --exclude='./*.zip' \
  -cf - . | tar -C "$stage_dir/$package_name" -xf -

if [[ -n "${SOURCE_DATE_EPOCH:-}" ]]; then
  find "$stage_dir/$package_name" -exec touch -d "@$SOURCE_DATE_EPOCH" {} +
fi

tar -C "$stage_dir" -czf "$package_path" "$package_name"

echo "$package_path"
