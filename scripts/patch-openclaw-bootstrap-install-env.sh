#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  patch-openclaw-bootstrap-install-env.sh [--target FILE] [--check] [--dry-run]

Patches the shared openclaw-bootstrap script so fresh installs can consume:

  OPENCLAW_INSTALL_ENV_FILE=$HOME/.openclaw-install.env
  OPENCLAW_CUSTOMER_MODE=1 OPENCLAW_TARGET_USER=ocN

The bootstrap remains the single install/start entrypoint. This patch adds the
install-env hook and an admin-driven customer-mode path that does not require
putting the customer account in the docker group.

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
import re
import shutil
import sys
from datetime import datetime
from pathlib import Path

target = Path(os.environ["OPENCLAW_BOOTSTRAP_TARGET"])
mode = os.environ["OPENCLAW_BOOTSTRAP_PATCH_MODE"]

marker = "OPENCLAW_BOOTSTRAP_INSTALL_ENV_PATCH v1"
main_call_marker = "OPENCLAW_BOOTSTRAP_INSTALL_ENV_MAIN_CALL v1"
host_user_marker = "OPENCLAW_BOOTSTRAP_HOST_USER_RECREATE_PATCH v1"
customer_mode_marker = "OPENCLAW_BOOTSTRAP_CUSTOMER_MODE_PATCH v1"
customer_finalize_marker = "OPENCLAW_BOOTSTRAP_CUSTOMER_MODE_FINALIZE_CALL v1"
customer_mode_probe = "openclaw_customer_mode_truthy()"

text = target.read_text(encoding="utf-8")

if mode == "check":
    ok = (
        marker in text
        and main_call_marker in text
        and host_user_marker in text
        and customer_mode_probe in text
        and customer_finalize_marker in text
    )
    if ok:
        print("bootstrap_install_env=ok")
        print("bootstrap_customer_mode=ok")
    else:
        print("bootstrap_install_env=missing")
    if marker in text and main_call_marker not in text:
        print("bootstrap_install_env_main_call=missing")
    if marker in text and host_user_marker not in text:
        print("bootstrap_host_user_recreate=missing")
    if customer_mode_probe not in text:
        print("bootstrap_customer_mode=missing")
    if customer_mode_probe in text and customer_finalize_marker not in text:
        print("bootstrap_customer_mode_finalize=missing")
    sys.exit(0 if ok else 1)

if (
    marker in text
    and main_call_marker in text
    and host_user_marker in text
    and customer_mode_probe in text
    and customer_finalize_marker in text
):
    print(f"already patched: {target}")
    sys.exit(0)

new = text


def replace_once(old: str, replacement: str) -> None:
    global new
    if old not in new:
        raise SystemExit(f"error: expected bootstrap anchor not found:\n{old}")
    new = new.replace(old, replacement, 1)


def maybe_replace_once(old: str, replacement: str) -> bool:
    global new
    if old not in new:
        return False
    new = new.replace(old, replacement, 1)
    return True


if marker not in new:
    replace_once(
        "OPENCLAW_SETUP_PATCH_MARKER='OPENCLAW_BOOTSTRAP_HOST_UID_PATCH v1'\n",
        "OPENCLAW_SETUP_PATCH_MARKER='OPENCLAW_BOOTSTRAP_HOST_UID_PATCH v1'\n"
        f"OPENCLAW_INSTALL_ENV_PATCH_MARKER='{marker}'\n",
    )

if customer_mode_marker not in new and "OPENCLAW_CUSTOMER_MODE_PATCH_MARKER=" not in new:
    replace_once(
        f"OPENCLAW_INSTALL_ENV_PATCH_MARKER='{marker}'\n",
        f"OPENCLAW_INSTALL_ENV_PATCH_MARKER='{marker}'\n"
        f"OPENCLAW_CUSTOMER_MODE_PATCH_MARKER='{customer_mode_marker}'\n",
    )

customer_mode_bootstrap = rf'''
# {customer_mode_marker}
openclaw_customer_mode_truthy() {{
  case "${{1:-}}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}}

# Customer mode is an admin-driven bootstrap path. The human customer account
# never needs docker group membership; root runs Docker while the container and
# OpenClaw state are prepared for a separate runtime identity.
if openclaw_customer_mode_truthy "${{OPENCLAW_CUSTOMER_MODE:-0}}"; then
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "error: OPENCLAW_CUSTOMER_MODE=1 requires sudo/root" >&2
    exit 1
  fi

  OPENCLAW_TARGET_USER="${{OPENCLAW_TARGET_USER:-${{OPENCLAW_INSTANCE:-}}}}"
  if [[ -z "$OPENCLAW_TARGET_USER" ]]; then
    echo "error: OPENCLAW_TARGET_USER is required in customer mode" >&2
    exit 1
  fi

  if ! id "$OPENCLAW_TARGET_USER" >/dev/null 2>&1; then
    useradd -m -s /bin/bash "$OPENCLAW_TARGET_USER"
  fi

  OPENCLAW_TARGET_HOME="$(getent passwd "$OPENCLAW_TARGET_USER" | cut -d: -f6)"
  if [[ -z "$OPENCLAW_TARGET_HOME" ]]; then
    echo "error: could not resolve home for $OPENCLAW_TARGET_USER" >&2
    exit 1
  fi

  OPENCLAW_RUNTIME_USER="${{OPENCLAW_RUNTIME_USER:-${{OPENCLAW_TARGET_USER}}_rt}}"
  OPENCLAW_DATA_GROUP="${{OPENCLAW_DATA_GROUP:-${{OPENCLAW_TARGET_USER}}_data}}"

  if ! getent group "$OPENCLAW_DATA_GROUP" >/dev/null; then
    groupadd "$OPENCLAW_DATA_GROUP"
  fi

  if ! id "$OPENCLAW_RUNTIME_USER" >/dev/null 2>&1; then
    useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin "$OPENCLAW_RUNTIME_USER"
  fi

  usermod -aG "$OPENCLAW_DATA_GROUP" "$OPENCLAW_RUNTIME_USER"

  OPENCLAW_TARGET_UID="$(id -u "$OPENCLAW_TARGET_USER")"
  OPENCLAW_RUNTIME_UID="$(id -u "$OPENCLAW_RUNTIME_USER")"
  OPENCLAW_RUNTIME_GID="$(id -g "$OPENCLAW_RUNTIME_USER")"
  OPENCLAW_DATA_GID="$(getent group "$OPENCLAW_DATA_GROUP" | cut -d: -f3)"

  export HOME="$OPENCLAW_TARGET_HOME"
  export USER="$OPENCLAW_TARGET_USER"
  export LOGNAME="$OPENCLAW_TARGET_USER"
  export OPENCLAW_INSTANCE="${{OPENCLAW_INSTANCE:-$OPENCLAW_TARGET_USER}}"
  export OPENCLAW_HOST_UID="$OPENCLAW_RUNTIME_UID"
  export OPENCLAW_HOST_GID="$OPENCLAW_RUNTIME_GID"
  export OPENCLAW_TARGET_USER OPENCLAW_TARGET_HOME
  export OPENCLAW_RUNTIME_USER OPENCLAW_RUNTIME_UID OPENCLAW_RUNTIME_GID
  export OPENCLAW_DATA_GROUP OPENCLAW_DATA_GID

  OPENCLAW_CUSTOMER_MOUNTPOINT="${{OPENCLAW_CUSTOMER_MOUNTPOINT:-$OPENCLAW_TARGET_HOME/nas_docs}}"
  export OPENCLAW_CUSTOMER_MOUNTPOINT
  export OPENCLAW_NAS_HOST_PATH="${{OPENCLAW_NAS_HOST_PATH:-$OPENCLAW_CUSTOMER_MOUNTPOINT}}"
  export OPENCLAW_NAS_SYMLINK="${{OPENCLAW_NAS_SYMLINK:-$OPENCLAW_CUSTOMER_MOUNTPOINT}}"
  export OPENCLAW_INSTALL_ENV_FILE="${{OPENCLAW_INSTALL_ENV_FILE:-$OPENCLAW_TARGET_HOME/.openclaw-install.env}}"

  if ! openclaw_customer_mode_truthy "${{OPENCLAW_CUSTOMER_SKIP_NAS_REMOUNT:-0}}" \
    && ! openclaw_customer_mode_truthy "${{OPENCLAW_BOOTSTRAP_SKIP_NAS:-0}}"; then
    OPENCLAW_CUSTOMER_SHARE="${{OPENCLAW_CUSTOMER_SHARE:-//192.168.0.222/hanpass}}"
    OPENCLAW_CUSTOMER_CREDENTIALS="${{OPENCLAW_CUSTOMER_CREDENTIALS:-/etc/samba/hanpass.cred}}"
    if [[ ! -f "$OPENCLAW_CUSTOMER_CREDENTIALS" ]]; then
      echo "error: CIFS credentials not found: $OPENCLAW_CUSTOMER_CREDENTIALS" >&2
      exit 1
    fi

    mkdir -p "$OPENCLAW_CUSTOMER_MOUNTPOINT"
    if findmnt -T "$OPENCLAW_CUSTOMER_MOUNTPOINT" >/dev/null 2>&1; then
      umount "$OPENCLAW_CUSTOMER_MOUNTPOINT"
    fi
    chown "$OPENCLAW_TARGET_USER:$OPENCLAW_DATA_GROUP" "$OPENCLAW_CUSTOMER_MOUNTPOINT"
    chmod 0550 "$OPENCLAW_CUSTOMER_MOUNTPOINT"
    mount -t cifs "$OPENCLAW_CUSTOMER_SHARE" "$OPENCLAW_CUSTOMER_MOUNTPOINT" \
      -o "credentials=$OPENCLAW_CUSTOMER_CREDENTIALS,uid=$OPENCLAW_TARGET_UID,gid=$OPENCLAW_DATA_GID,forceuid,forcegid,ro,file_mode=0440,dir_mode=0550,iocharset=utf8,vers=3.1.1,nounix,noserverino,nosharesock"
  fi
fi

'''

if customer_mode_probe not in new:
    if "OPENCLAW_CUSTOMER_MODE_PATCH_MARKER=" in new:
        marker_line_re = re.compile(r"OPENCLAW_CUSTOMER_MODE_PATCH_MARKER='[^']+'\n")
        new = marker_line_re.sub(lambda m: m.group(0) + customer_mode_bootstrap, new, count=1)
    else:
        replace_once("set -euo pipefail\n", "set -euo pipefail\n" + customer_mode_bootstrap)

if "    OPENCLAW_IMAGE\n" not in new:
    maybe_replace_once(
        "    OPENCLAW_PROXY_ALLOWED_ORIGINS\n",
        "    OPENCLAW_PROXY_ALLOWED_ORIGINS\n"
        "    OPENCLAW_IMAGE\n",
    )

if "    OPENCLAW_INSTALL_ENV_FILE\n" not in new:
    maybe_replace_once(
        "    OPENCLAW_NAS_HOST_PATH\n",
        "    OPENCLAW_INSTALL_ENV_FILE\n"
        "    OPENCLAW_NAS_HOST_PATH\n",
    )

if 'openclaw_env_upsert OPENCLAW_IMAGE "${OPENCLAW_IMAGE:-}"' not in new:
    replace_once(
        '  openclaw_env_upsert COMPOSE_PROJECT_NAME "$COMPOSE_PROJECT_NAME"\n',
        '  openclaw_env_upsert COMPOSE_PROJECT_NAME "$COMPOSE_PROJECT_NAME"\n'
        '  openclaw_env_upsert OPENCLAW_IMAGE "${OPENCLAW_IMAGE:-}"\n',
    )

if 'openclaw_env_upsert OPENCLAW_INSTALL_ENV_FILE "${OPENCLAW_INSTALL_ENV_FILE:-}"' not in new:
    replace_once(
        '  openclaw_env_upsert OPENCLAW_IMAGE "${OPENCLAW_IMAGE:-}"\n',
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
  [[ -f "$env_file" ]] || die "OPENCLAW_INSTALL_ENV_FILE not found: $env_file"

  baseline_dir="$(resolve_openclaw_baseline_dir)" || die "openclaw-nas-agent-baseline repo not found. Set OPENCLAW_BASELINE_DIR."
  helper="$baseline_dir/scripts/apply-openclaw-install-env.sh"

  info "Applying install settings: $env_file"
  local helper_args=(--home "$HOME" --env-file "$env_file")
  [[ -n "${OPENCLAW_TARGET_USER:-}" ]] && helper_args+=(--user "$OPENCLAW_TARGET_USER")
  bash "$helper" "${helper_args[@]}"

  if docker_ok; then
    info "Recreating gateway after install settings..."
    # OPENCLAW_BOOTSTRAP_HOST_USER_RECREATE_PATCH v1
    ensure_openclaw_host_user_compose
    openclaw_write_extra_compose_from_env
    docker_compose up -d --force-recreate openclaw-gateway
  fi
}

apply_openclaw_customer_mode_finalize() {
  [[ -n "${OPENCLAW_CUSTOMER_MODE:-}" ]] || return 0
  case "${OPENCLAW_CUSTOMER_MODE:-}" in
    1|true|TRUE|yes|YES|on|ON) ;;
    *) return 0 ;;
  esac

  [[ "$(id -u)" -eq 0 ]] || die "OPENCLAW_CUSTOMER_MODE finalize requires sudo/root"

  local target_user target_home runtime_user runtime_uid runtime_gid data_group data_gid compose_dir
  target_user="${OPENCLAW_TARGET_USER:?OPENCLAW_TARGET_USER is required}"
  target_home="${OPENCLAW_TARGET_HOME:-$HOME}"
  runtime_user="${OPENCLAW_RUNTIME_USER:-${target_user}_rt}"
  data_group="${OPENCLAW_DATA_GROUP:-${target_user}_data}"
  runtime_uid="$(id -u "$runtime_user")"
  runtime_gid="$(id -g "$runtime_user")"
  data_gid="$(getent group "$data_group" | cut -d: -f3)"
  compose_dir="${OPENCLAW_DIR:-$target_home/openclaw}"

  info "Finalizing customer mode for $target_user"

  if [[ -d "$target_home/.openclaw" ]]; then
    chown -R "$runtime_user:$runtime_user" "$target_home/.openclaw"
    find "$target_home/.openclaw" -type d -exec chmod 0700 {} +
    find "$target_home/.openclaw" -type f -exec chmod 0600 {} +
  fi

  if [[ -d "$target_home/.openclaw-auth-profile-secrets" ]]; then
    chown -R "$runtime_user:$runtime_user" "$target_home/.openclaw-auth-profile-secrets"
    find "$target_home/.openclaw-auth-profile-secrets" -type d -exec chmod 0700 {} +
    find "$target_home/.openclaw-auth-profile-secrets" -type f -exec chmod 0600 {} +
  fi

  if [[ -f "$target_home/.openclaw-install.env" ]]; then
    chown root:root "$target_home/.openclaw-install.env"
    chmod 0600 "$target_home/.openclaw-install.env"
  fi

  if [[ -d "$compose_dir" ]]; then
    chown -R root:root "$compose_dir"
    find "$compose_dir" -type d -exec chmod 0755 {} +
    find "$compose_dir" -type f -exec chmod 0644 {} +
    [[ -f "$compose_dir/.env" ]] && chmod 0600 "$compose_dir/.env"

    cat > "$compose_dir/docker-compose.host-user.yml" <<EOF
services:
  openclaw-gateway:
    user: "$runtime_uid:$runtime_gid"
    group_add:
      - "$data_gid"
  openclaw-cli:
    user: "$runtime_uid:$runtime_gid"
    group_add:
      - "$data_gid"
EOF
    chown root:root "$compose_dir/docker-compose.host-user.yml"
    chmod 0644 "$compose_dir/docker-compose.host-user.yml"
  fi

  chown "$target_user:$target_user" "$target_home"
  chmod 0750 "$target_home"
  gpasswd -d "$target_user" docker >/dev/null 2>&1 || true

  if docker_ok && [[ -d "$compose_dir" ]]; then
    info "Recreating gateway in customer mode..."
    cd "$compose_dir"
    docker_compose up -d --force-recreate openclaw-gateway
  fi
}

'''

install_block_re = re.compile(
    r"\n# OPENCLAW_INSTALL_ENV_FILE is install input, not a later restore step\.\n"
    r"# Bootstrap stays the only operator-facing install/start command\.\n"
    r".*?\nmain\(\) \{",
    re.S,
)

if install_block_re.search(new):
    new = install_block_re.sub("\n" + install_functions + "main() {", new, count=1)
elif "resolve_openclaw_baseline_dir()" not in new:
    replace_once("\nmain() {\n", "\n" + install_functions + "main() {\n")

# Previous versions of this helper inserted the call inside
# configure_openclaw_control_ui_proxy(). That runs at the wrong layer. The env
# file must be materialized after setup creates ~/.openclaw and after ownership
# is fixed.
new = new.replace(
    '  [[ -z "${OPENCLAW_CONTROL_UI_BASEPATH:-}" ]] && return 0\n'
    '  apply_openclaw_install_settings\n\n'
    '  if ! docker_ok; then\n',
    '  [[ -z "${OPENCLAW_CONTROL_UI_BASEPATH:-}" ]] && return 0\n'
    '\n'
    '  if ! docker_ok; then\n',
)

if main_call_marker not in new:
    replace_once(
        "  fix_openclaw_bindmount_ownership_after_setup\n\n"
        "  configure_openclaw_control_ui_proxy\n",
        "  fix_openclaw_bindmount_ownership_after_setup\n\n"
        f"  # {main_call_marker}\n"
        "  apply_openclaw_install_settings\n\n"
        "  configure_openclaw_control_ui_proxy\n",
    )

if customer_finalize_marker not in new:
    replace_once(
        "  configure_openclaw_control_ui_proxy\n",
        "  configure_openclaw_control_ui_proxy\n\n"
        f"  # {customer_finalize_marker}\n"
        "  apply_openclaw_customer_mode_finalize\n",
    )

if mode == "dry-run":
    print(f"would patch: {target}")
    sys.exit(0)

if new == text:
    print(f"already patched: {target}")
    sys.exit(0)

backup = target.with_name(target.name + "." + datetime.now().strftime("%Y%m%d%H%M%S") + ".bak")
shutil.copy2(target, backup)
target.write_text(new, encoding="utf-8")
target.chmod(0o750)
print(f"patched: {target}")
print(f"backup: {backup}")
PY
