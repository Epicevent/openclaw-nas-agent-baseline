#!/usr/bin/env bash

openclaw_nas_share_is_valid() {
  [[ "${1:-}" =~ ^//[^[:space:]/,]+/[^[:space:]/,]+$ ]]
}

openclaw_nas_validate_share() {
  local share="${1:-}"
  if ! openclaw_nas_share_is_valid "$share"; then
    echo "error: invalid CIFS share path: $share" >&2
    echo "hint: expected form is //NAS_HOST/SHARE" >&2
    return 2
  fi
}

openclaw_nas_mount_name_is_valid() {
  local name="${1:-}"
  [[ "$name" != "." && "$name" != ".." && "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}(/[A-Za-z0-9][A-Za-z0-9._-]{0,63}){0,3}$ ]]
}

openclaw_nas_validate_mount_name() {
  local name="${1:-}"
  if ! openclaw_nas_mount_name_is_valid "$name"; then
    echo "error: invalid mount name: $name" >&2
    echo "hint: use 1-4 path components with letters, numbers, dot, dash, or underscore" >&2
    return 2
  fi
}

openclaw_nas_host_label() {
  local host="${1:-}" digest
  digest="$(printf '%s' "$host" | sha256sum | awk '{ print substr($1, 1, 12) }')"
  printf 'host-%s' "$digest"
}

openclaw_nas_safe_share_label() {
  local share_name="${1:-}"
  share_name="${share_name//[^A-Za-z0-9._-]/_}"
  printf '%s' "$share_name"
}

openclaw_nas_mount_name_from_share() {
  local share="${1:-}" rest host share_name mount_name
  openclaw_nas_validate_share "$share" || return $?
  rest="${share#//}"
  host="${rest%%/*}"
  share_name="${rest#*/}"
  share_name="${share_name%%/*}"
  mount_name="$(openclaw_nas_host_label "$host")/$(openclaw_nas_safe_share_label "$share_name")"
  openclaw_nas_validate_mount_name "$mount_name" || return $?
  printf '%s' "$mount_name"
}

openclaw_nas_mountpoint() {
  local target_home="$1" mount_name="$2"
  printf '%s/nas_docs/%s' "$target_home" "$mount_name"
}

openclaw_nas_credentials_path() {
  local target_home="$1" mount_name="$2"
  printf '%s/.openclaw-nas/credentials/%s.cred' "$target_home" "$mount_name"
}
