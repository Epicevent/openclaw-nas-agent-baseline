#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  openclaw-nas-mount [options]
  customer-nas-mount.sh [options]

Creates the customer's NAS credential file if needed and mounts ~/nas_docs
through the fstab user-mount rule prepared by the operator.

Options:
  --status              Show mount/credential status only.
  --remount             Unmount first, then mount again.
  --reset-credential    Re-enter NAS username/password before mounting.
  --mountpoint DIR      Default: ~/nas_docs.
  --credentials FILE    Default: ~/.nas-cifs.cred.

Run as the customer Linux account, for example oc20. Do not run with sudo.
USAGE
}

mode="mount"
reset_credential=0
mountpoint="${OPENCLAW_NAS_MOUNTPOINT:-$HOME/nas_docs}"
credentials="${OPENCLAW_NAS_CREDENTIALS:-$HOME/.nas-cifs.cred}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --status)
      mode="status"
      shift
      ;;
    --remount)
      mode="remount"
      shift
      ;;
    --reset-credential)
      reset_credential=1
      shift
      ;;
    --mountpoint)
      mountpoint="${2:?missing --mountpoint value}"
      shift 2
      ;;
    --credentials)
      credentials="${2:?missing --credentials value}"
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

if [[ "$(id -u)" -eq 0 ]]; then
  echo "error: run as the customer account, not root" >&2
  exit 1
fi

case "$mountpoint" in
  "$HOME"|"$HOME"/*) ;;
  *)
    echo "error: mountpoint must stay under HOME: $mountpoint" >&2
    exit 2
    ;;
esac

case "$credentials" in
  "$HOME"|"$HOME"/*) ;;
  *)
    echo "error: credentials file must stay under HOME: $credentials" >&2
    exit 2
    ;;
esac

status() {
  local current_target current_source current_fstype fstab_entry fstab_source fstab_target fstab_type fstab_options fstab_credentials nas_user next_action
  echo "== NAS 연결 상태 =="
  echo "linux_user=$(whoami)"
  echo "home=$HOME"
  echo "mountpoint=$mountpoint"
  fstab_entry="$(awk -v mp="$mountpoint" '
    $0 !~ /^[[:space:]]*#/ && $2 == mp && $3 == "cifs" { print; exit }
  ' /etc/fstab 2>/dev/null || true)"
  if [[ -n "$fstab_entry" ]]; then
    read -r fstab_source fstab_target fstab_type fstab_options _ <<<"$fstab_entry"
    echo "fstab_rule=present"
    echo "registered_share=$fstab_source"
    fstab_credentials="$(printf '%s' "$fstab_options" | tr ',' '\n' | awk -F= '$1 == "credentials" { print $2; exit }')"
    if [[ -n "$fstab_credentials" ]]; then
      echo "registered_credentials_file=$fstab_credentials"
    fi
  else
    echo "fstab_rule=missing"
    echo "registered_share=missing"
  fi
  if [[ -s "$credentials" ]]; then
    echo "credential_file=present"
    nas_user="$(awk -F= '$1 == "username" { print $2; exit }' "$credentials" 2>/dev/null || true)"
    if [[ -n "$nas_user" ]]; then
      echo "credential_username=$nas_user"
    fi
  else
    echo "credential_file=missing"
  fi
  current_target="$(findmnt -T "$mountpoint" -n -o TARGET 2>/dev/null | head -1 || true)"
  current_source="$(findmnt -T "$mountpoint" -n -o SOURCE 2>/dev/null | head -1 || true)"
  current_fstype="$(findmnt -T "$mountpoint" -n -o FSTYPE 2>/dev/null | head -1 || true)"
  if [[ "$current_target" == "$mountpoint" ]]; then
    echo "mount_state=mounted"
    echo "mounted_source=$current_source"
    echo "mounted_fstype=$current_fstype"
    if [[ -n "${fstab_source:-}" && "$current_source" != "$fstab_source" ]]; then
      echo "mount_matches_registered_share=no"
      echo "next_action=openclaw-nas-mount --remount"
    else
      echo "mount_matches_registered_share=yes"
      echo "next_action=none"
    fi
  else
    echo "mount_state=not_mounted"
    if [[ -z "$fstab_entry" ]]; then
      next_action="ask operator to register the NAS share"
    elif [[ ! -s "$credentials" ]]; then
      next_action="openclaw-nas-mount --reset-credential"
    else
      next_action="openclaw-nas-mount --remount"
    fi
    echo "next_action=$next_action"
  fi
}

configured_share() {
  awk -v mp="$mountpoint" '
    $0 !~ /^[[:space:]]*#/ && $2 == mp && $3 == "cifs" { print $1; exit }
  ' /etc/fstab 2>/dev/null || true
}

require_registered_share() {
  local share
  share="$(configured_share)"
  if [[ -z "$share" ]]; then
    echo "error: no registered NAS share for $mountpoint" >&2
    echo "hint: ask the operator to register this account's NAS share first." >&2
    status >&2
    exit 1
  fi
  echo "== NAS 연결 대상 =="
  echo "registered_share=$share"
  echo "mountpoint=$mountpoint"
  if [[ -s "$credentials" ]]; then
    local nas_user
    nas_user="$(awk -F= '$1 == "username" { print $2; exit }' "$credentials" 2>/dev/null || true)"
    [[ -n "$nas_user" ]] && echo "credential_username=$nas_user"
  else
    echo "credential_file=missing"
  fi
}

write_credentials() {
  umask 077
  mkdir -p "$(dirname "$credentials")"

  printf "NAS username: "
  read -r nas_user

  printf "NAS password: "
  stty -echo
  read -r nas_pass
  stty echo
  printf "\n"

  {
    printf "username=%s\n" "$nas_user"
    printf "password=%s\n" "$nas_pass"
  } > "$credentials"

  chmod 600 "$credentials"
  unset nas_user nas_pass
  echo "credential_file=written"
}

if [[ "$mode" == "status" ]]; then
  status
  exit 0
fi

mkdir -p "$mountpoint" 2>/dev/null || true
require_registered_share

if [[ "$mode" == "remount" ]]; then
  current_target="$(findmnt -T "$mountpoint" -n -o TARGET 2>/dev/null | head -1 || true)"
  if [[ "$current_target" == "$mountpoint" ]]; then
    echo "action=unmount_existing"
    umount "$mountpoint"
  fi
fi

if [[ "$reset_credential" -eq 1 || ! -s "$credentials" ]]; then
  write_credentials
fi

current_target="$(findmnt -T "$mountpoint" -n -o TARGET 2>/dev/null | head -1 || true)"
if [[ "$current_target" == "$mountpoint" ]]; then
  fstype="$(findmnt -T "$mountpoint" -n -o FSTYPE | head -1)"
  if [[ "$fstype" == "cifs" ]]; then
    echo "mount=already_cifs"
    status
    exit 0
  fi
fi

echo "action=mount_registered_share"
if mount "$mountpoint"; then
  :
else
  rc=$?
  echo "mount=failed" >&2
  status >&2
  echo "hint=If fstab_rule is present but mount fails with error(13), check the NAS username/password or NAS share permission." >&2
  exit "$rc"
fi

current_target="$(findmnt -T "$mountpoint" -n -o TARGET 2>/dev/null | head -1 || true)"
fstype="$(findmnt -T "$mountpoint" -n -o FSTYPE 2>/dev/null | head -1 || true)"
if [[ "$current_target" != "$mountpoint" || "$fstype" != "cifs" ]]; then
  echo "error: mount finished but $mountpoint is not CIFS" >&2
  status >&2
  exit 1
fi

echo "mount=cifs_ok"
status
echo "sample_count=$(find "$mountpoint" -maxdepth 1 -mindepth 1 2>/dev/null | head -3 | wc -l)"
