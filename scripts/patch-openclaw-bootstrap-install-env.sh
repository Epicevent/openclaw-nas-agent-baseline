#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  patch-openclaw-bootstrap-install-env.sh [--target FILE] [--check] [--dry-run]

Patches the shared openclaw-bootstrap script so fresh installs can consume:

  OPENCLAW_INSTALL_ENV_FILE=/home/oc1/.openclaw-install.env

The bootstrap remains the single install/start entrypoint. This patch only adds
the hook that calls scripts/apply-openclaw-install-env.sh during bootstrap.

Default target:
  /opt/openclaw-bootstrap/openclaw-bootstrap.sh

Examples:
  sudo bash scripts/patch-openclaw-bootstrap-install-env.sh
  bash scripts/patch-openclaw-bootstrap-install-env.sh --check
USAGE
}

target="/opt/openclaw-bootstrap/openclaw-bootstrap.sh"
mode="patch"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)
      target="${2:?missing target}"
      shift 2
      ;;
    --check)
      mode="check"
      shift
      ;;
    --dry-run)
      mode="dry-run"
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

if [[ ! -f "$target" ]]; then
  echo "error: bootstrap target not found: $target" >&2
  exit 1
fi

if [[ "$mode" == "patch" && "$(id -u)" -ne 0 && "$target" == /opt/* ]]; then
  echo "error: patching $target requires root; run with sudo" >&2
  exit 1
fi

OPENCLAW_BOOTSTRAP_TARGET="$target" \
OPENCLAW_BOOTSTRAP_PATCH_MODE="$mode" \
python3 - <<'PY'
import os
import shutil
import sys
from datetime import datetime
from pathlib import Path

target = Path(os.environ["OPENCLAW_BOOTSTRAP_TARGET"])
mode = os.environ["OPENCLAW_BOOTSTRAP_PATCH_MODE"]
marker = "OPENCLAW_BOOTSTRAP_INSTALL_ENV_PATCH v1"

text = target.read_text(encoding="utf-8")

if mode == "check":
    print("bootstrap_install_env=ok" if marker in text else "bootstrap_install_env=missing")
    sys.exit(0 if marker in text else 1)

if marker in text:
    print(f"already patched: {target}")
    sys.exit(0)

new = text


def replace_once(old: str, replacement: str) -> None:
    global new
    if old not in new:
        raise SystemExit(f"error: expected bootstrap anchor not found:\n{old}")
    new = new.replace(old, replacement, 1)


replace_once(
    "OPENCLAW_SETUP_PATCH_MARKER='OPENCLAW_BOOTSTRAP_HOST_UID_PATCH v1'\n",
    "OPENCLAW_SETUP_PATCH_MARKER='OPENCLAW_BOOTSTRAP_HOST_UID_PATCH v1'\n"
    f"OPENCLAW_INSTALL_ENV_PATCH_MARKER='{marker}'\n",
)

replace_once(
    "    OPENCLAW_PROXY_ALLOWED_ORIGINS\n"
    "    OPENCLAW_NAS_HOST_PATH\n",
    "    OPENCLAW_PROXY_ALLOWED_ORIGINS\n"
    "    OPENCLAW_IMAGE\n"
    "    OPENCLAW_INSTALL_ENV_FILE\n"
    "    OPENCLAW_NAS_HOST_PATH\n",
)

replace_once(
    '  openclaw_env_upsert COMPOSE_PROJECT_NAME "$COMPOSE_PROJECT_NAME"\n',
    '  openclaw_env_upsert COMPOSE_PROJECT_NAME "$COMPOSE_PROJECT_NAME"\n'
    '  openclaw_env_upsert OPENCLAW_IMAGE "${OPENCLAW_IMAGE:-}"\n'
    '  openclaw_env_upsert OPENCLAW_INSTALL_ENV_FILE "${OPENCLAW_INSTALL_ENV_FILE:-}"\n',
)

install_functions = r'''
# OPENCLAW_INSTALL_ENV_FILE is install input, not a later restore step.
# Bootstrap stays the only operator-facing install/start command.
resolve_openclaw_baseline_dir() {
  local d
  for d in "${OPENCLAW_BASELINE_DIR:-}" \
           "/opt/openclaw-nas-agent-baseline" \
           "$HOME/openclaw-nas-agent-baseline-fresh" \
           "$HOME/openclaw-nas-agent-baseline"; do
    [[ -n "$d" ]] || continue
    if [[ -f "$d/scripts/apply-openclaw-install-env.sh" ]]; then
      printf '%s' "$d"
      return 0
    fi
  done
  return 1
}

apply_openclaw_install_settings() {
  [[ -n "${OPENCLAW_INSTALL_ENV_FILE:-}" ]] || return 0

  local env_file baseline_dir helper
  env_file="$OPENCLAW_INSTALL_ENV_FILE"
  [[ -f "$env_file" ]] || die "OPENCLAW_INSTALL_ENV_FILE 를 찾을 수 없습니다: $env_file"

  baseline_dir="$(resolve_openclaw_baseline_dir)" || die "openclaw-nas-agent-baseline repo를 찾을 수 없습니다. OPENCLAW_BASELINE_DIR 를 지정하세요."
  helper="$baseline_dir/scripts/apply-openclaw-install-env.sh"

  info "Install settings 적용 중: $env_file"
  bash "$helper" --home "$HOME" --env-file "$env_file"

  if docker_ok; then
    info "Install settings 반영을 위해 게이트웨이를 재생성합니다..."
    openclaw_write_extra_compose_from_env
    docker_compose up -d --force-recreate openclaw-gateway
  fi
}

'''

replace_once("\nmain() {\n", "\n" + install_functions + "main() {\n")

replace_once(
    "  if ! docker_ok; then\n",
    "  apply_openclaw_install_settings\n\n"
    "  if ! docker_ok; then\n",
)

if mode == "dry-run":
    print(f"would patch: {target}")
    sys.exit(0)

backup = target.with_name(target.name + "." + datetime.now().strftime("%Y%m%d%H%M%S") + ".bak")
shutil.copy2(target, backup)
target.write_text(new, encoding="utf-8")
target.chmod(0o750)
print(f"patched: {target}")
print(f"backup: {backup}")
PY
