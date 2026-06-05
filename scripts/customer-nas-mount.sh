#!/usr/bin/env bash
set -euo pipefail

script_path="${BASH_SOURCE[0]}"
while [[ -L "$script_path" ]]; do
  script_dir="$(cd -P "$(dirname "$script_path")" && pwd)"
  link_target="$(readlink "$script_path")"
  if [[ "$link_target" == /* ]]; then
    script_path="$link_target"
  else
    script_path="$script_dir/$link_target"
  fi
done
script_dir="$(cd -P "$(dirname "$script_path")" && pwd)"
# shellcheck source=scripts/internal/lib-safe-compose.bash
source "$script_dir/internal/lib-safe-compose.bash"

usage() {
  cat <<'USAGE'
Usage:
  agent-nas-mount [options]
  customer-nas-mount.sh [options]

Creates the customer's NAS credential file if needed and mounts the registered
share-name folder under ~/nas_docs through the fstab user-mount rule prepared
by the operator.

Options:
  --status              Show mount/credential status only.
  --share SHARE         Target a registered NAS share, for example
                        //nas.example.local/OC1.
  --request-share SHARE Create a policy-based approval request for a NAS share.
  --wait [SECONDS]      After a request, wait for automatic approval and mount.
                        Default wait time is 90 seconds. Use 0 to wait forever.
  --unmount             Unmount the selected registered NAS share.
  --remount             Unmount first, then mount again.
  --reset-credential    Re-enter NAS username/password before mounting.

Run as the customer Linux account, for example oc20. Do not run with sudo.
USAGE
}

mode="mount"
reset_credential=0
wait_after_request=0
wait_seconds="${OPENCLAW_NAS_WAIT_SECONDS:-90}"
watch_state_file="${OPENCLAW_NAS_WATCH_STATE_FILE:-/var/lib/openclaw-nas-agent/nas-request-watch.state}"
mountpoint=""
credentials=""
mount_name=""
source_share=""
requested_share=""
request_wait_started_epoch=0

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
    --share)
      source_share="${2:?missing --share value}"
      shift 2
      ;;
    --request-mount)
      echo "error: --request-mount is no longer supported" >&2
      echo "hint: use --request-share //HOST/SHARE" >&2
      exit 2
      ;;
    --mount-name)
      echo "error: --mount-name is not a customer-facing selector" >&2
      echo "hint: use --share //HOST/SHARE" >&2
      exit 2
      ;;
    --remount)
      mode="remount"
      shift
      ;;
    --unmount)
      mode="unmount"
      shift
      ;;
    --wait)
      wait_after_request=1
      if [[ "${2:-}" =~ ^[0-9]+$ ]]; then
        wait_seconds="$2"
        shift 2
      else
        shift
      fi
      ;;
    --reset-credential)
      reset_credential=1
      shift
      ;;
    --mountpoint|--credentials)
      echo "error: $1 is not supported in customer mode" >&2
      echo "hint: use --share //HOST/SHARE; paths are derived from the NAS source." >&2
      exit 2
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

if [[ ! "$wait_seconds" =~ ^[0-9]+$ ]]; then
  echo "error: wait seconds must be a non-negative integer: $wait_seconds" >&2
  exit 2
fi

if [[ -n "${OPENCLAW_NAS_MOUNTPOINT:-}" || -n "${OPENCLAW_NAS_CREDENTIALS:-}" ]]; then
  echo "error: OPENCLAW_NAS_MOUNTPOINT/OPENCLAW_NAS_CREDENTIALS overrides are not supported" >&2
  echo "hint: use --share //HOST/SHARE; paths are generated from the registered NAS source." >&2
  exit 2
fi

validate_mount_name() {
  openclaw_nas_validate_mount_name "$1" || exit $?
}

validate_share() {
  openclaw_nas_validate_share "$1" || exit $?
}

mount_name_from_share() {
  openclaw_nas_mount_name_from_share "$1"
}

if [[ -n "$source_share" ]]; then
  validate_share "$source_share"
  mount_name="$(mount_name_from_share "$source_share")"
fi

if [[ "$mode" == "request_share" ]]; then
  validate_share "$requested_share"
  mount_name="$(mount_name_from_share "$requested_share")"
fi

if [[ -n "$mount_name" ]]; then
  validate_mount_name "$mount_name"
fi

if [[ -z "$mountpoint" ]]; then
  if [[ -n "$mount_name" ]]; then
    mountpoint="$(openclaw_nas_mountpoint "$HOME" "$mount_name")"
  else
    mountpoint="$HOME/nas_docs"
  fi
fi

if [[ -z "$credentials" ]]; then
  if [[ -n "$mount_name" ]]; then
    credentials="$(openclaw_nas_credentials_path "$HOME" "$mount_name")"
  else
    credentials="$HOME/.nas-cifs.cred"
  fi
fi

configured_fstab_entry() {
  awk -v mp="$mountpoint" '
    $0 !~ /^[[:space:]]*#/ && $2 == mp && $3 == "cifs" { print; exit }
  ' /etc/fstab 2>/dev/null || true
}

decision_file_for_share() {
  local decision="$1" share="$2" since_epoch="$3" dir file file_share mtime
  dir="$HOME/.openclaw-nas/$decision"
  [[ -d "$dir" ]] || return 1
  while IFS= read -r -d '' file; do
    mtime="$(stat -c %Y "$file" 2>/dev/null || echo 0)"
    if [[ "$mtime" =~ ^[0-9]+$ ]] && (( mtime < since_epoch )); then
      continue
    fi
    file_share="$(awk -F= '$1 == "REQUESTED_SHARE" { print $2; exit }' "$file" 2>/dev/null || true)"
    if [[ "$file_share" == "$share" ]]; then
      printf '%s' "$file"
      return 0
    fi
  done < <(find "$dir" -maxdepth 1 -type f -name 'share-request.*.env' -print0 2>/dev/null || true)
  return 1
}

print_auto_approval_watcher_state() {
  local ts status handled failures now_epoch ts_epoch age stale_after
  stale_after="${OPENCLAW_NAS_WATCH_STALE_SECONDS:-90}"
  if [[ ! -r "$watch_state_file" ]]; then
    echo "watcher_state=unknown reason=state_file_missing_or_unreadable"
    return 0
  fi
  ts="$(awk -F= '$1 == "timestamp" { print $2; exit }' "$watch_state_file" 2>/dev/null || true)"
  status="$(awk -F= '$1 == "status" { print $2; exit }' "$watch_state_file" 2>/dev/null || true)"
  handled="$(awk -F= '$1 == "handled" { print $2; exit }' "$watch_state_file" 2>/dev/null || true)"
  failures="$(awk -F= '$1 == "failures" { print $2; exit }' "$watch_state_file" 2>/dev/null || true)"
  if [[ -z "$ts" ]]; then
    echo "watcher_state=unknown reason=state_timestamp_missing"
    return 0
  fi
  now_epoch="$(date +%s)"
  ts_epoch="$(date -d "$ts" +%s 2>/dev/null || true)"
  if [[ -z "$ts_epoch" ]]; then
    echo "watcher_state=unknown reason=state_timestamp_unparseable last_status=${status:-unknown}"
    return 0
  fi
  age=$((now_epoch - ts_epoch))
  if (( age < 0 )); then
    age=0
  fi
  if (( age > stale_after )); then
    echo "watcher_state=stale age_seconds=$age last_status=${status:-unknown} handled=${handled:-unknown} failures=${failures:-unknown}"
  else
    echo "watcher_state=alive age_seconds=$age last_status=${status:-unknown} handled=${handled:-unknown} failures=${failures:-unknown}"
  fi
}

wait_for_registered_share() {
  local share="$1" started deadline elapsed current rejected_file approved_file
  started="$SECONDS"
  if [[ "$wait_seconds" -eq 0 ]]; then
    deadline=0
    echo "wait_timeout_seconds=unlimited"
  else
    deadline=$((SECONDS + wait_seconds))
    echo "wait_timeout_seconds=$wait_seconds"
  fi
  echo "wait_target_share=$share"
  while [[ "$deadline" -eq 0 || "$SECONDS" -le "$deadline" ]]; do
    elapsed=$((SECONDS - started))
    current="$(configured_share)"
    print_auto_approval_watcher_state
    rejected_file="$(decision_file_for_share rejected "$share" "$request_wait_started_epoch" || true)"
    if [[ -n "$rejected_file" ]]; then
      echo "wait_state=rejected elapsed_seconds=$elapsed decision_file=$rejected_file"
      return 2
    fi
    approved_file="$(decision_file_for_share approved "$share" "$request_wait_started_epoch" || true)"
    if [[ -n "$approved_file" ]]; then
      echo "approval_record=present decision_file=$approved_file"
    fi
    if [[ "$current" == "$share" ]]; then
      echo "wait_state=registered elapsed_seconds=$elapsed"
      return 0
    fi
    echo "wait_state=pending elapsed_seconds=$elapsed registered_share=${current:-missing}"
    sleep 2
  done
  elapsed=$((SECONDS - started))
  echo "wait_state=timeout elapsed_seconds=$elapsed"
  return 1
}

configured_share() {
  local entry
  entry="$(configured_fstab_entry)"
  [[ -n "$entry" ]] || return 0
  awk '{ print $1; exit }' <<<"$entry"
}

credential_nas_username() {
  awk -F= '$1 == "username" { print $2; exit }' "$credentials" 2>/dev/null || true
}

print_registered_child_mounts() {
  local root="$1" lines n mp share name state source
  lines="$(awk -v root="$root/" '
    $0 !~ /^[[:space:]]*#/ && $2 ~ "^" root && $3 == "cifs" {
      count += 1
    name = $2
    sub("^" root, "", name)
    printf "%d\t%s\t%s\t%s\n", count, $2, $1, name
    }
  ' /etc/fstab 2>/dev/null || true)"
  if [[ -z "$lines" ]]; then
    echo "registered_child_mounts=none"
    return 0
  fi
  while IFS=$'\t' read -r n mp share name; do
    [[ -n "$n" ]] || continue
    echo "registered_child_mount_$n=$mp"
    echo "registered_child_share_$n=$share"
    state="not_mounted"
    source=""
    if [[ "$(openclaw_findmnt_exact_field "$mp" TARGET)" == "$mp" ]]; then
      if [[ "$(openclaw_findmnt_exact_field "$mp" FSTYPE)" == "cifs" ]]; then
        state="mounted_cifs"
        source="$(openclaw_findmnt_exact_field "$mp" SOURCE)"
      else
        state="mounted_non_cifs"
        source="$(openclaw_findmnt_exact_field "$mp" SOURCE)"
      fi
    fi
    echo "registered_child_state_$n=$state"
    [[ -n "$source" ]] && echo "registered_child_mounted_source_$n=$source"
    echo "child_mount_command_$n=agent-nas-mount --share $share --status"
  done <<<"$lines"
}

status() {
  local current_target current_source current_fstype fstab_entry fstab_source fstab_target fstab_type fstab_options fstab_credentials nas_user next_action
  echo "== NAS status =="
  echo "scope=customer_account_only"
  echo "note=container visibility requires operator nas-verify"
  echo "linux_user=$(whoami)"
  echo "home=$HOME"
  echo "derived_mount_name=${mount_name:-primary}"
  echo "mountpoint=$mountpoint"

  fstab_entry="$(configured_fstab_entry)"
  if [[ -n "$fstab_entry" ]]; then
    read -r fstab_source fstab_target fstab_type fstab_options _ <<<"$fstab_entry"
    echo "fstab_rule=present"
    echo "registered_share=$fstab_source"
    echo "registered_nas_share=$fstab_source"
    fstab_credentials="$(printf '%s' "$fstab_options" | tr ',' '\n' | awk -F= '$1 == "credentials" { print $2; exit }')"
    [[ -n "$fstab_credentials" ]] && echo "registered_credentials_file=$fstab_credentials"
  else
    echo "fstab_rule=missing"
    echo "registered_share=missing"
  fi

  if [[ -s "$credentials" ]]; then
    echo "credential_file=present"
    nas_user="$(credential_nas_username)"
    [[ -n "$nas_user" ]] && echo "credential_nas_username=$nas_user"
  else
    echo "credential_file=missing"
  fi

  current_target="$(openclaw_findmnt_exact_field "$mountpoint" TARGET)"
  current_source="$(openclaw_findmnt_exact_field "$mountpoint" SOURCE)"
  current_fstype="$(openclaw_findmnt_exact_field "$mountpoint" FSTYPE)"
  if [[ "$current_target" == "$mountpoint" ]]; then
    echo "mount_state=mounted"
    echo "mounted_source=$current_source"
    echo "mounted_fstype=$current_fstype"
    if [[ -n "${fstab_source:-}" && "$current_source" != "$fstab_source" ]]; then
      echo "mount_matches_registered_share=no"
      echo "next_action=agent-nas-mount --share $fstab_source --remount"
    else
      echo "mount_matches_registered_share=yes"
      echo "next_action=shell_ok"
      echo "container_next_action=if the agent cannot see NAS, ask operator to run nas-verify $(whoami)"
    fi
  else
    echo "mount_state=not_mounted"
    openclaw_print_parent_mount_hint "$mountpoint"
    if [[ -z "$fstab_entry" ]]; then
      next_action="ask operator to register the NAS share"
    elif [[ ! -s "$credentials" ]]; then
      next_action="agent-nas-mount --share $fstab_source --reset-credential"
    else
      next_action="agent-nas-mount --share $fstab_source --remount"
    fi
    echo "next_action=$next_action"
  fi

  if [[ "$mountpoint" == "$HOME/nas_docs" ]]; then
    print_registered_child_mounts "$mountpoint"
  fi
}

write_share_request() {
  local share="$1" request_dir request_file current_share requested_at next_action request_mount_name request_mountpoint request_credentials
  validate_share "$share"
  request_mount_name="$(mount_name_from_share "$share")"
  request_mountpoint="$(openclaw_nas_mountpoint "$HOME" "$request_mount_name")"
  request_credentials="$(openclaw_nas_credentials_path "$HOME" "$request_mount_name")"
  request_dir="$HOME/.openclaw-nas"
  request_file="$request_dir/share-request.env"
  current_share="$(configured_share)"
  requested_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  if [[ "$current_share" == "$share" ]]; then
    rm -f "$request_file" 2>/dev/null || true
    echo "== NAS share request =="
    echo "request_file=$request_file"
    echo "request_state=already_registered"
    echo "nas_share=$share"
    echo "mountpoint=$request_mountpoint"
    echo "requested_share=$share"
    echo "current_registered_share=$current_share"
    if [[ -s "$request_credentials" ]]; then
      next_action="agent-nas-mount --share $share --remount"
    else
      next_action="agent-nas-mount --share $share --reset-credential"
    fi
    echo "next_action=$next_action"
    return 0
  fi

  umask 077
  mkdir -p "$request_dir"
  {
    printf 'REQUEST_KIND=nas_share\n'
    printf 'REQUESTED_BY=%s\n' "$(whoami)"
    printf 'REQUESTED_AT=%s\n' "$requested_at"
    printf 'MOUNT_NAME=%s\n' "$request_mount_name"
    printf 'REQUESTED_SHARE=%s\n' "$share"
    printf 'CURRENT_REGISTERED_SHARE=%s\n' "${current_share:-missing}"
    printf 'MOUNTPOINT=%s\n' "$request_mountpoint"
    printf 'CREDENTIALS_PATH=%s\n' "$request_credentials"
  } > "$request_file"
  chmod 600 "$request_file"

  echo "== NAS share request =="
  echo "request_file=$request_file"
  echo "nas_share=$share"
  echo "mountpoint=$request_mountpoint"
  echo "requested_share=$share"
  echo "current_registered_share=${current_share:-missing}"
  if [[ "$current_share" == "$share" ]]; then
    if [[ -s "$request_credentials" ]]; then
      next_action="agent-nas-mount --share $share --remount"
    else
      next_action="agent-nas-mount --share $share --reset-credential"
    fi
  else
    next_action="wait for automatic NAS approval daemon"
  fi
  echo "next_action=$next_action"
}

require_registered_share() {
  local share nas_user
  share="$(configured_share)"
  if [[ -z "$share" ]]; then
    echo "error: no registered NAS share for $mountpoint" >&2
    echo "hint: ask the operator to register this account's NAS share first." >&2
    status >&2
    exit 1
  fi
  echo "== NAS target =="
  echo "linux_user=$(whoami)"
  echo "registered_share=$share"
  echo "registered_nas_share=$share"
  echo "mountpoint=$mountpoint"
  if [[ -s "$credentials" ]]; then
    nas_user="$(credential_nas_username)"
    [[ -n "$nas_user" ]] && echo "credential_nas_username=$nas_user"
  else
    echo "credential_file=missing"
  fi
}

write_credentials() {
  local old_stty
  umask 077
  mkdir -p "$(dirname "$credentials")"

  printf "NAS username (not Linux username): "
  read -r nas_user

  printf "NAS password: "
  old_stty="$(stty -g)"
  trap 'stty "$old_stty" 2>/dev/null || true' INT TERM EXIT
  stty -echo
  read -r nas_pass
  stty "$old_stty"
  trap - INT TERM EXIT
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

if [[ "$mode" == "request_share" ]]; then
  if [[ "$reset_credential" -eq 1 || ! -s "$credentials" ]]; then
    write_credentials
  fi
  request_wait_started_epoch="$(date +%s)"
  write_share_request "$requested_share"
  if [[ "$wait_after_request" -eq 1 ]]; then
    echo "action=wait_for_auto_approval"
    if wait_for_registered_share "$requested_share"; then
      wait_rc=0
    else
      wait_rc=$?
    fi
    if [[ "$wait_rc" -ne 0 ]]; then
      if [[ "$wait_rc" -eq 2 ]]; then
        echo "approval=rejected" >&2
      else
        echo "approval=timeout" >&2
      fi
      status >&2
      exit 1
    fi
    echo "approval=registered"
    source_share="$requested_share"
    mode="mount"
  else
    exit 0
  fi
fi

if [[ "$mode" == "unmount" ]]; then
  if [[ -z "$source_share" ]]; then
    echo "error: --share //HOST/SHARE is required for unmount" >&2
    status >&2
    exit 2
  fi
  require_registered_share
  current_target="$(openclaw_findmnt_exact_field "$mountpoint" TARGET)"
  if [[ "$current_target" == "$mountpoint" ]]; then
    echo "action=unmount_registered_share"
    umount "$mountpoint"
    status
  else
    echo "mount=already_not_mounted"
    status
  fi
  exit 0
fi

if [[ -z "$source_share" ]]; then
  echo "error: --share //HOST/SHARE is required for mount/remount/credential operations" >&2
  status >&2
  exit 2
fi

mkdir -p "$mountpoint" 2>/dev/null || true
require_registered_share

if [[ "$mode" == "remount" ]]; then
  current_target="$(openclaw_findmnt_exact_field "$mountpoint" TARGET)"
  if [[ "$current_target" == "$mountpoint" ]]; then
    echo "action=unmount_existing"
    umount "$mountpoint"
  fi
fi

if [[ "$reset_credential" -eq 1 || ! -s "$credentials" ]]; then
  write_credentials
fi

current_target="$(openclaw_findmnt_exact_field "$mountpoint" TARGET)"
if [[ "$current_target" == "$mountpoint" ]]; then
  fstype="$(openclaw_findmnt_exact_field "$mountpoint" FSTYPE)"
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

current_target="$(openclaw_findmnt_exact_field "$mountpoint" TARGET)"
fstype="$(openclaw_findmnt_exact_field "$mountpoint" FSTYPE)"
if [[ "$current_target" != "$mountpoint" || "$fstype" != "cifs" ]]; then
  echo "error: mount finished but $mountpoint is not CIFS" >&2
  status >&2
  exit 1
fi

echo "mount=cifs_ok"
status
echo "sample_count=$(find "$mountpoint" -maxdepth 1 -mindepth 1 2>/dev/null | head -3 | wc -l)"
