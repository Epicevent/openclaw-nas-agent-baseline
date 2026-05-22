#!/usr/bin/env bash

openclaw_safe_fail() {
  echo "FAIL $1" >&2
  [[ $# -gt 1 ]] && shift && printf '%s\n' "$@" >&2
  return 1
}

openclaw_assert_root_owned_file() {
  local path="$1" label="${2:-file}"
  [[ -f "$path" ]] || openclaw_safe_fail "${label}_missing=$path" || return 1
  [[ ! -L "$path" ]] || openclaw_safe_fail "${label}_symlink=$path" || return 1
  [[ "$(stat -c '%U:%G' "$path" 2>/dev/null || true)" == "root:root" ]] \
    || openclaw_safe_fail "${label}_not_root_owned=$path" || return 1
  if find "$path" -maxdepth 0 -perm /022 2>/dev/null | grep -q .; then
    openclaw_safe_fail "${label}_writable_by_group_or_other=$path" || return 1
  fi
}

openclaw_assert_safe_compose_dir() {
  local target_user="$1" compose_dir="$2"
  local target_home expected resolved required optional env_file

  target_home="$(getent passwd "$target_user" | cut -d: -f6)"
  [[ -n "$target_home" ]] || openclaw_safe_fail "compose_user_missing=$target_user" || return 1

  expected="$target_home/openclaw"
  [[ "$compose_dir" == "$expected" ]] \
    || openclaw_safe_fail "compose_dir_unexpected=$compose_dir expected=$expected" || return 1
  [[ -d "$compose_dir" ]] || openclaw_safe_fail "compose_dir_missing=$compose_dir" || return 1
  [[ ! -L "$compose_dir" ]] || openclaw_safe_fail "compose_dir_symlink=$compose_dir" || return 1

  resolved="$(readlink -f "$compose_dir" 2>/dev/null || true)"
  [[ "$resolved" == "$expected" ]] \
    || openclaw_safe_fail "compose_dir_resolves_outside=$compose_dir resolved=${resolved:-missing} expected=$expected" || return 1

  [[ "$(stat -c '%U:%G' "$compose_dir" 2>/dev/null || true)" == "root:root" ]] \
    || openclaw_safe_fail "compose_dir_not_root_owned=$compose_dir" || return 1
  if find "$compose_dir" -maxdepth 0 -perm /022 2>/dev/null | grep -q .; then
    openclaw_safe_fail "compose_dir_writable_by_group_or_other=$compose_dir" || return 1
  fi

  for required in docker-compose.yml docker-compose.host-user.yml; do
    openclaw_assert_root_owned_file "$compose_dir/$required" "compose_file" || return 1
  done

  for optional in docker-compose.extra.yml docker-compose.sandbox.yml; do
    if [[ -e "$compose_dir/$optional" ]]; then
      openclaw_assert_root_owned_file "$compose_dir/$optional" "compose_file" || return 1
    fi
  done

  env_file="$compose_dir/.env"
  if [[ -e "$env_file" ]]; then
    openclaw_assert_root_owned_file "$env_file" "compose_env" || return 1
    if find "$env_file" -maxdepth 0 -perm /077 2>/dev/null | grep -q .; then
      openclaw_safe_fail "compose_env_too_permissive=$env_file" || return 1
    fi
  fi
}
