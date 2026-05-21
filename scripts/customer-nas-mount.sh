#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  openclaw-nas-mount [options]
  customer-nas-mount.sh [options]

Creates the customer's NAS credential file if needed and mounts the registered
share-name folder under ~/nas_docs through the fstab user-mount rule prepared
by the operator.

Options:
  --status              Show mount/credential status only.
  --request-share SHARE Create an operator approval request for a new NAS share.
  --request-mount SHARE Create an operator approval request for a named NAS
                        mount under ~/nas_docs/SHARE_NAME.
  --mount-name NAME     Use an already registered named mount under
                        ~/nas_docs/NAME.
  --remount             Unmount first, then mount again.
  --reset-credential    Re-enter NAS username/password before mounting.
  --mountpoint DIR      Override mountpoint.
  --credentials FILE    Override credentials file.

Run as the customer Linux account, for example oc20. Do not run with sudo.
USAGE
}

mode="mount"
reset_credential=0
mountpoint="${OPENCLAW_NAS_MOUNTPOINT:-}"
credentials="${OPENCLAW_NAS_CREDENTIALS:-}"
mount_name=""
requested_share=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --status)
      mode="status"
      shift
      ;;
    --request-share)
      mode="request_share"
      requested_share="${2:?missing --request-share value}"
      shift 2
      ;;
    --request-mount)
      mode="request_mount"
      requested_share="${2:?missing --request-mount value}"
      shift 2
      ;;
    --mount-name)
      mount_name="${2:?missing --mount-name value}"
      shift 2
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

validate_mount_name() {
  local name="$1"
  if [[ "$name" == "." || "$name" == ".." || ! "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]; then
    echo "error: invalid mount name: $name" >&2
    echo "hint: use letters, numbers, dot, dash, or underscore" >&2
    exit 2
  fi
}

validate_share() {
  local share="$1"
  if [[ ! "$share" =~ ^//[^[:space:]/]+/[^[:space:]]+$ ]]; then
    echo "error: invalid CIFS share path: $share" >&2
    echo "hint: expected form is //NAS_HOST/SHARE_NAME" >&2
    exit 2
  fi
}

mount_name_from_share() {
  local share="$1" rest name
  rest="${share#//}"
  rest="${rest#*/}"
  name="${rest%%/*}"
  validate_mount_name "$name"
  printf '%s' "$name"
}

if [[ "$mode" == "request_mount" || "$mode" == "request_share" ]] && [[ -z "$mount_name" ]]; then
  validate_share "$requested_share"
  mount_name="$(mount_name_from_share "$requested_share")"
fi

if [[ -n "$mount_name" ]]; then
  validate_mount_name "$mount_name"
fi

if [[ -z "$mountpoint" ]]; then
  if [[ -n "$mount_name" ]]; then
    mountpoint="$HOME/nas_docs/$mount_name"
  else
    mountpoint="$HOME/nas_docs"
  fi
fi

if [[ -z "$credentials" ]]; then
  if [[ -n "$mount_name" ]]; then
    credentials="$HOME/.openclaw-nas/credentials/$mount_name.cred"
  else
    credentials="$HOME/.nas-cifs.cred"
  fi
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
  echo "scope=customer_account_only"
  echo "note=OpenClaw container visibility requires operator nas-verify"
  echo "linux_user=$(whoami)"
  echo "home=$HOME"
  echo "mount_name=${mount_name:-primary}"
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
      echo "next_action=shell_ok"
      echo "openclaw_next_action=if OpenClaw cannot see NAS, ask operator to run nas-verify $(whoami)"
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

  if [[ "$mountpoint" == "$HOME/nas_docs" ]]; then
    awk -v root="$mountpoint/" '
      $0 !~ /^[[:space:]]*#/ && $2 ~ "^" root && $3 == "cifs" {
        count += 1
        name = $2
        sub("^" root, "", name)
        sub("/.*$", "", name)
        printf "registered_child_mount_%d=%s\n", count, $2
        printf "registered_child_share_%d=%s\n", count, $1
        printf "child_mount_command_%d=openclaw-nas-mount --mount-name %s --status\n", count, name
      }
      END {
        if (!count) {
          print "registered_child_mounts=none"
        }
      }
    ' /etc/fstab 2>/dev/null || true
  fi
}

configured_share() {
  awk -v mp="$mountpoint" '
    $0 !~ /^[[:space:]]*#/ && $2 == mp && $3 == "cifs" { print $1; exit }
  ' /etc/fstab 2>/dev/null || true
}

write_share_request() {
  local share="$1" request_dir request_file current_share requested_at request_kind
  validate_share "$share"
  request_dir="$HOME/.openclaw-nas"
  request_file="$request_dir/share-request.env"
  if [[ -n "$mount_name" ]]; then
    request_kind="nas_mount"
  else
    request_kind="nas_share"
  fi
  current_share="$(configured_share)"
  requested_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  umask 077
  mkdir -p "$request_dir"
  {
    printf 'REQUEST_KIND=%s\n' "$request_kind"
    printf 'REQUESTED_BY=%s\n' "$(whoami)"
    printf 'REQUESTED_AT=%s\n' "$requested_at"
    printf 'MOUNT_NAME=%s\n' "${mount_name:-primary}"
    printf 'REQUESTED_SHARE=%s\n' "$share"
    printf 'CURRENT_REGISTERED_SHARE=%s\n' "${current_share:-missing}"
    printf 'MOUNTPOINT=%s\n' "$mountpoint"
    printf 'CREDENTIALS_PATH=%s\n' "$credentials"
  } > "$request_file"
  chmod 600 "$request_file"

  echo "== NAS share 변경 요청 =="
  echo "request_file=$request_file"
  echo "mount_name=${mount_name:-primary}"
  echo "mountpoint=$mountpoint"
  echo "requested_share=$share"
  echo "current_registered_share=${current_share:-missing}"
  echo "next_action=ask operator to approve this request"
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

if [[ "$mode" == "request_share" || "$mode" == "request_mount" ]]; then
  write_share_request "$requested_share"
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
