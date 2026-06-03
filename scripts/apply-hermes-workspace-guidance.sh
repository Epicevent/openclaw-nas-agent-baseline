#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  apply-hermes-workspace-guidance.sh --user USER [--check]

Installs managed Hermes workspace guidance so the agent knows the canonical NAS
root and HWP/HWPX helper commands.

Run as root/admin.
USAGE
}

target_user=""
check_only=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user)
      target_user="${2:?missing --user value}"
      shift 2
      ;;
    --check)
      check_only=1
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

if [[ ! "$target_user" =~ ^oc[1-9][0-9]*$ ]]; then
  echo "error: invalid user: $target_user" >&2
  exit 2
fi

if [[ "$(id -u)" -ne 0 ]]; then
  echo "error: run with sudo/root" >&2
  exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
target_home="$(getent passwd "$target_user" | cut -d: -f6)"
if [[ -z "$target_home" || "$target_home" != "/home/$target_user" ]]; then
  echo "error: unexpected home for $target_user: ${target_home:-missing}" >&2
  exit 1
fi

runtime_env="$target_home/openclaw/.env"
runtime_family="openclaw"
if [[ -f "$runtime_env" ]]; then
  runtime_family="$(
    awk -F= '$1 == "OPENCLAW_RUNTIME_FAMILY" { gsub(/'\''|"/, "", $2); print $2; exit }' "$runtime_env" 2>/dev/null || true
  )"
  runtime_family="${runtime_family:-openclaw}"
fi
if [[ "$runtime_family" != "hermes" ]]; then
  echo "target_user=$target_user"
  echo "runtime_family=$runtime_family"
  echo "guidance=skipped_not_hermes"
  exit 0
fi

runtime_user="${target_user}_rt"
data_group="${target_user}_data"
hermes_home="$target_home/.hermes"
workspace="$hermes_home/workspace"
agents_file="$workspace/AGENTS.md"
source_file="$script_dir/hermes-workspace-defaults/AGENTS.md"

if [[ ! -f "$source_file" ]]; then
  echo "error: missing source guidance: $source_file" >&2
  exit 1
fi

for path in "$target_home" "$hermes_home"; do
  if [[ -L "$path" ]]; then
    echo "error: symlink refused: $path" >&2
    exit 1
  fi
done
if [[ -e "$workspace" && -L "$workspace" ]]; then
  echo "error: symlink refused: $workspace" >&2
  exit 1
fi
if [[ -e "$agents_file" && -L "$agents_file" ]]; then
  echo "error: symlink refused: $agents_file" >&2
  exit 1
fi

resolved_workspace="$(realpath -m "$workspace")"
resolved_agents="$(realpath -m "$agents_file")"
case "$resolved_workspace" in
  "$target_home/.hermes/workspace") ;;
  *)
    echo "error: workspace escaped managed path: $resolved_workspace" >&2
    exit 1
    ;;
esac
case "$resolved_agents" in
  "$target_home/.hermes/workspace/AGENTS.md") ;;
  *)
    echo "error: AGENTS.md escaped managed path: $resolved_agents" >&2
    exit 1
    ;;
esac

echo "target_user=$target_user"
echo "runtime_family=$runtime_family"
echo "workspace=$workspace"
echo "agents_file=$agents_file"

if [[ "$check_only" -eq 1 ]]; then
  if [[ -f "$agents_file" ]] && grep -q 'BEGIN OPENCLAW HERMES GUIDANCE' "$agents_file" \
    && grep -q 'openclaw-hwp-text' "$agents_file" \
    && grep -q '/workspace/nas_docs' "$agents_file"; then
    echo "guidance=present"
    exit 0
  fi
  echo "guidance=missing"
  exit 1
fi

mkdir -p "$workspace"

python3 - "$agents_file" "$source_file" <<'PY'
from __future__ import annotations

import sys
from pathlib import Path

target = Path(sys.argv[1])
source = Path(sys.argv[2])
begin = "<!-- BEGIN OPENCLAW HERMES GUIDANCE -->"
end = "<!-- END OPENCLAW HERMES GUIDANCE -->"
block = f"{begin}\n{source.read_text(encoding='utf-8').rstrip()}\n{end}\n"

if target.exists():
    text = target.read_text(encoding="utf-8", errors="replace")
else:
    text = ""

if begin in text and end in text:
    before, rest = text.split(begin, 1)
    _old, after = rest.split(end, 1)
    text = before.rstrip() + "\n\n" + block + after.lstrip()
else:
    text = text.rstrip() + ("\n\n" if text.strip() else "") + block

target.write_text(text, encoding="utf-8")
PY

if id "$runtime_user" >/dev/null 2>&1 && getent group "$data_group" >/dev/null; then
  chown "$runtime_user:$data_group" "$workspace" "$agents_file"
else
  chown root:root "$workspace" "$agents_file"
fi
chmod 0750 "$workspace"
chmod 0644 "$agents_file"

echo "guidance=updated"
