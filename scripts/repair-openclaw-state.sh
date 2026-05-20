#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  repair-openclaw-state.sh [--user USER] [--home HOME] [--snapshot FILE] [--force-defaults] [--no-backup]

Repairs a user's OpenClaw state enough to get the agent usable again.

Default behavior:
  - backs up the current ~/.openclaw repairable state
  - restores a snapshot if --snapshot is provided
  - otherwise seeds repo defaults into ~/.openclaw/workspace and creates a minimal gateway config
  - recreates workspace NAS symlinks to ~/nas_docs
  - fixes ownership for the target user

Examples:
  sudo bash scripts/repair-openclaw-state.sh --user oc1
  sudo bash scripts/repair-openclaw-state.sh --user oc1 --snapshot /home/oc1/.openclaw-recovery/snapshots/openclaw-state-oc1-20260519120000.tar.gz
USAGE
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

target_user=""
target_home=""
snapshot=""
force_defaults=0
make_backup=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user)
      target_user="${2:?missing user}"
      shift 2
      ;;
    --home)
      target_home="${2:?missing home}"
      shift 2
      ;;
    --snapshot)
      snapshot="${2:?missing snapshot file}"
      shift 2
      ;;
    --force-defaults)
      force_defaults=1
      shift
      ;;
    --no-backup)
      make_backup=0
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

if [[ -n "$target_user" && -z "$target_home" ]]; then
  target_home="$(getent passwd "$target_user" | cut -d: -f6)"
fi

if [[ -z "$target_home" ]]; then
  target_home="${HOME:?HOME is not set}"
fi

if [[ -z "$target_user" ]]; then
  if command -v getent >/dev/null 2>&1; then
    target_user="$(getent passwd "$(id -u)" | cut -d: -f1 || true)"
  fi
  target_user="${target_user:-$(id -un)}"
fi

target_uid="$(id -u "$target_user" 2>/dev/null || true)"
target_gid="$(id -g "$target_user" 2>/dev/null || true)"

openclaw_dir="$target_home/.openclaw"
workspace_dir="$openclaw_dir/workspace"
recovery_dir="$target_home/.openclaw-recovery"
config_path="$openclaw_dir/openclaw.json"

mkdir -p "$openclaw_dir" "$workspace_dir" "$recovery_dir"

if [[ "$make_backup" -eq 1 && -d "$openclaw_dir" ]]; then
  echo "backup: $("$script_dir/backup-openclaw-state.sh" --user "$target_user" --home "$target_home")"
fi

if [[ -n "$snapshot" ]]; then
  if [[ ! -f "$snapshot" ]]; then
    echo "error: snapshot not found: $snapshot" >&2
    exit 1
  fi

  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT
  tar -xzf "$snapshot" -C "$tmp_dir"

  if [[ ! -d "$tmp_dir/openclaw-state/.openclaw" ]]; then
    echo "error: invalid snapshot: missing openclaw-state/.openclaw" >&2
    exit 1
  fi

  cp -a "$tmp_dir/openclaw-state/.openclaw/." "$openclaw_dir/"
  echo "restored snapshot: $snapshot"
else
  defaults_dir="$repo_root/openclaw/defaults/workspace"
  mkdir -p "$workspace_dir/skills"

  install_default() {
    local name="$1"
    local src="$defaults_dir/$name"
    local dst="$workspace_dir/$name"

    if [[ ! -f "$src" ]]; then
      return 0
    fi

    if [[ "$force_defaults" -eq 1 || ! -e "$dst" ]]; then
      cp -a "$src" "$dst"
      echo "seeded: $dst"
    fi
  }

  install_default "AGENTS.md"
  install_default "TOOLS.md"
  install_default "RECOVERY.md"

  if command -v python3 >/dev/null 2>&1; then
    OPENCLAW_REPAIR_CONFIG_PATH="$config_path" \
    OPENCLAW_REPAIR_USER="$target_user" \
    OPENCLAW_REPAIR_WORKSPACE="/home/node/.openclaw/workspace" \
    OPENCLAW_REPAIR_BASEPATH="${OPENCLAW_CONTROL_UI_BASEPATH:-/$target_user}" \
    OPENCLAW_REPAIR_ALLOWED_ORIGINS="${OPENCLAW_PROXY_ALLOWED_ORIGINS:-${OPENCLAW_PROXY_PUBLIC_ORIGIN:-}}" \
    python3 - <<'PY'
import json
import os
import secrets
from pathlib import Path

path = Path(os.environ["OPENCLAW_REPAIR_CONFIG_PATH"])
user = os.environ["OPENCLAW_REPAIR_USER"]
workspace = os.environ["OPENCLAW_REPAIR_WORKSPACE"]
base_path = os.environ["OPENCLAW_REPAIR_BASEPATH"] or f"/{user}"
origins_raw = os.environ.get("OPENCLAW_REPAIR_ALLOWED_ORIGINS", "")

if not base_path.startswith("/"):
    base_path = f"/{base_path}"
base_path = base_path.rstrip("/") or f"/{user}"

if path.exists():
    data = json.loads(path.read_text() or "{}")
else:
    data = {}

gateway = data.setdefault("gateway", {})
gateway.setdefault("mode", "local")
gateway.setdefault("port", 18789)
gateway.setdefault("bind", "lan")

auth = gateway.setdefault("auth", {})
auth.setdefault("mode", "token")
if not auth.get("token"):
    auth["token"] = secrets.token_urlsafe(32)

control = gateway.setdefault("controlUi", {})
control.setdefault("basePath", base_path)
control.setdefault("autoApproveWithToken", True)

origins = []
for raw in origins_raw.split(","):
    origin = raw.strip().rstrip("/")
    if origin and origin not in origins:
        origins.append(origin)
if origins:
    control["allowedOrigins"] = origins

control.setdefault("allowInsecureAuth", True)

agents = data.setdefault("agents", {})
defaults = agents.setdefault("defaults", {})
defaults.setdefault("workspace", workspace)

path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
path.chmod(0o600)
PY
    echo "seeded: $config_path"
  else
    echo "warning: python3 not found; skipped minimal OpenClaw gateway config seed" >&2
  fi
fi

nas_mount="$target_home/nas_docs"
rm -f "$workspace_dir/nas_docs" "$workspace_dir/nas"
ln -s "$nas_mount" "$workspace_dir/nas_docs"
ln -s "$nas_mount" "$workspace_dir/nas"

cat > "$recovery_dir/last-repair.txt" <<EOF
time=$(date -Is)
user=$target_user
home=$target_home
snapshot=${snapshot:-}
repo=$repo_root
EOF

if [[ -n "$target_uid" && -n "$target_gid" && "$(id -u)" -eq 0 ]]; then
  chown -R "$target_uid:$target_gid" "$openclaw_dir" "$recovery_dir"
fi

echo "openclaw_dir=$openclaw_dir"
echo "workspace_dir=$workspace_dir"
echo "nas_symlink=$workspace_dir/nas_docs -> $nas_mount"
echo "repair complete"
