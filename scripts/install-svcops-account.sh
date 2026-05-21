#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  install-svcops-account.sh [options]

Creates the restricted svcops operating account and sudoers policy.

Options:
  --account USER       Operating account name. Default: svcops.
  --group GROUP        Operating group name. Default: same as account.
  --prefix DIR         Installed repo path. Default: /opt/openclaw-nas-agent-baseline.
  --set-password       Run passwd for the operating account after creation.
  --nopasswd-sudo      Allow the wrapper without a sudo password.

Run as root/admin after install.sh has installed this repo under /opt.
USAGE
}

account="svcops"
group=""
prefix="/opt/openclaw-nas-agent-baseline"
set_password=0
nopasswd_sudo=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --account)
      account="${2:?missing account}"
      shift 2
      ;;
    --group)
      group="${2:?missing group}"
      shift 2
      ;;
    --prefix)
      prefix="${2:?missing prefix}"
      shift 2
      ;;
    --set-password)
      set_password=1
      shift
      ;;
    --nopasswd-sudo)
      nopasswd_sudo=1
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

group="${group:-$account}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "error: run with sudo/root" >&2
  exit 1
fi

if [[ ! "$account" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
  echo "error: invalid account name: $account" >&2
  exit 2
fi

if [[ ! "$group" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
  echo "error: invalid group name: $group" >&2
  exit 2
fi

case "$prefix" in
  /opt/*) ;;
  *)
    echo "error: prefix must be under /opt: $prefix" >&2
    exit 2
    ;;
esac

control_script="$prefix/scripts/svcops-control.sh"
sudoers_file="/etc/sudoers.d/90-${account}"

if [[ ! -x "$control_script" ]]; then
  echo "error: missing executable control script: $control_script" >&2
  echo "hint: run sudo bash install.sh first from the repo checkout" >&2
  exit 1
fi

if ! getent group "$group" >/dev/null; then
  groupadd "$group"
fi

if ! id "$account" >/dev/null 2>&1; then
  useradd -m -s /bin/bash -g "$group" "$account"
else
  usermod -g "$group" "$account"
fi

usermod -aG "$group" "$account"

for forbidden_group in docker sudo root; do
  if getent group "$forbidden_group" >/dev/null && id -nG "$account" | tr ' ' '\n' | grep -qx "$forbidden_group"; then
    gpasswd -d "$account" "$forbidden_group" >/dev/null || true
  fi
done

chown -R root:root "$prefix"
chmod -R go-w "$prefix"
chmod 0755 "$prefix" "$prefix/scripts"
chmod 0755 "$control_script"

sudo_tag=""
if [[ "$nopasswd_sudo" -eq 1 ]]; then
  sudo_tag="NOPASSWD: "
fi

tmp="$(mktemp)"
cat > "$tmp" <<EOF
# Managed by openclaw-nas-agent-baseline.
# Restricted operating account policy for $account.
Defaults:%$group secure_path="/usr/sbin:/usr/bin:/sbin:/bin"
Defaults:%$group env_reset,!setenv,use_pty,log_input,log_output

%$group ALL=(root) ${sudo_tag}$control_script *
EOF

if ! visudo -cf "$tmp" >/dev/null; then
  echo "error: generated sudoers policy failed validation" >&2
  cat "$tmp" >&2
  rm -f "$tmp"
  exit 1
fi

install -o root -g root -m 0440 "$tmp" "$sudoers_file"
rm -f "$tmp"

if [[ "$set_password" -eq 1 ]]; then
  passwd "$account"
fi

echo "account=$account"
echo "group=$group"
echo "control_script=$control_script"
echo "sudoers_file=$sudoers_file"
echo "docker_group=removed"
echo "sudo_group=removed"
echo "root_group=removed"
echo "svcops_account=ok"
echo
echo "Examples:"
echo "  sudo $control_script nas-status oc1"
echo "  sudo $control_script check oc1 oc1.ji-tech.co.kr"
