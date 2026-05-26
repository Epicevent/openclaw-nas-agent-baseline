#!/usr/bin/env bash

openclaw_safe_fail() {
  echo "FAIL $1" >&2
  [[ $# -gt 1 ]] && shift && printf '%s\n' "$@" >&2
  return 1
}

openclaw_target_home() {
  getent passwd "$1" | cut -d: -f6
}

openclaw_assert_managed_slot_prewrite() {
  local target_user="$1"
  local target_home expected_home path resolved owner group runtime_user

  [[ "$target_user" =~ ^oc[1-9][0-9]*$ ]] \
    || openclaw_safe_fail "managed_slot_invalid_user=$target_user" || return 1

  target_home="$(openclaw_target_home "$target_user")"
  [[ -n "$target_home" ]] || openclaw_safe_fail "managed_slot_user_missing=$target_user" || return 1

  expected_home="/home/$target_user"
  [[ "$target_home" == "$expected_home" ]] \
    || openclaw_safe_fail "managed_slot_home_unexpected=$target_home expected=$expected_home" || return 1

  [[ -d "$target_home" ]] || openclaw_safe_fail "managed_slot_home_missing=$target_home" || return 1
  [[ ! -L "$target_home" ]] || openclaw_safe_fail "managed_slot_home_symlink=$target_home" || return 1
  resolved="$(readlink -f "$target_home" 2>/dev/null || true)"
  [[ "$resolved" == "$target_home" ]] \
    || openclaw_safe_fail "managed_slot_home_resolves_outside=$target_home resolved=${resolved:-missing}" || return 1
  owner="$(stat -c '%U' "$target_home" 2>/dev/null || true)"
  [[ "$owner" == "$target_user" ]] \
    || openclaw_safe_fail "managed_slot_home_owner_unexpected=$target_home owner=${owner:-missing} expected=$target_user" || return 1
  if find "$target_home" -maxdepth 0 -perm /022 2>/dev/null | grep -q .; then
    openclaw_safe_fail "managed_slot_home_writable_by_group_or_other=$target_home" || return 1
  fi

  runtime_user="${target_user}_rt"

  for path in \
    "$target_home/openclaw" \
    "$target_home/.openclaw" \
    "$target_home/.openclaw/workspace" \
    "$target_home/.config" \
    "$target_home/.config/openclaw" \
    "$target_home/.openclaw-auth-profile-secrets" \
    "$target_home/.openclaw-recovery" \
    "$target_home/.openclaw-nas" \
    "$target_home/.openclaw-nas/credentials" \
    "$target_home/nas_docs"; do
    if [[ -L "$path" ]]; then
      openclaw_safe_fail "managed_slot_path_symlink=$path" || return 1
    fi
    if [[ -e "$path" ]]; then
      resolved="$(readlink -f "$path" 2>/dev/null || true)"
      case "$resolved" in
        "$target_home"|"$target_home"/*) ;;
        *)
          openclaw_safe_fail "managed_slot_path_resolves_outside=$path resolved=${resolved:-missing}" || return 1
          ;;
      esac

      if find "$path" -maxdepth 0 -perm /022 2>/dev/null | grep -q .; then
        openclaw_safe_fail "managed_slot_path_writable_by_group_or_other=$path" || return 1
      fi

      owner="$(stat -c '%U' "$path" 2>/dev/null || true)"
      group="$(stat -c '%G' "$path" 2>/dev/null || true)"
      case "$path" in
        "$target_home/openclaw")
          [[ "$owner:$group" == "root:root" ]] \
            || openclaw_safe_fail "managed_slot_compose_owner_unexpected=$path owner=${owner:-missing}:${group:-missing} expected=root:root" || return 1
          ;;
        *)
          case "$owner" in
            root|"$target_user"|"$runtime_user") ;;
            *)
              openclaw_safe_fail "managed_slot_path_owner_unexpected=$path owner=${owner:-missing} expected=root_or_${target_user}_or_${runtime_user}" || return 1
              return 1
              ;;
          esac
          ;;
      esac
    fi
  done
}

openclaw_assert_managed_subpath() {
  local target_user="$1" path="$2" root="$3" label="${4:-managed_path}"
  local target_home resolved root_resolved

  target_home="$(openclaw_target_home "$target_user")"
  [[ -n "$target_home" ]] || openclaw_safe_fail "${label}_user_missing=$target_user" || return 1
  [[ "$root" == "$target_home"* ]] || openclaw_safe_fail "${label}_root_unexpected=$root" || return 1
  [[ ! -L "$path" ]] || openclaw_safe_fail "${label}_symlink=$path" || return 1

  root_resolved="$(readlink -f "$root" 2>/dev/null || true)"
  [[ -n "$root_resolved" ]] || openclaw_safe_fail "${label}_root_missing=$root" || return 1
  resolved="$(readlink -m "$path" 2>/dev/null || true)"
  case "$resolved" in
    "$root_resolved"|"$root_resolved"/*) ;;
    *) openclaw_safe_fail "${label}_resolves_outside=$path resolved=${resolved:-missing} root=$root_resolved" || return 1 ;;
  esac
}

openclaw_assert_root_owned_file() {
  local path="$1" label="${2:-file}"
  [[ -f "$path" ]] || openclaw_safe_fail "${label}_missing=$path" || return 1
  [[ ! -L "$path" ]] || openclaw_safe_fail "${label}_symlink=$path" || return 1
  [[ "$(stat -c '%h' "$path" 2>/dev/null || true)" == "1" ]] \
    || openclaw_safe_fail "${label}_hardlink=$path" || return 1
  [[ "$(stat -c '%U:%G' "$path" 2>/dev/null || true)" == "root:root" ]] \
    || openclaw_safe_fail "${label}_not_root_owned=$path" || return 1
  if find "$path" -maxdepth 0 -perm /022 2>/dev/null | grep -q .; then
    openclaw_safe_fail "${label}_writable_by_group_or_other=$path" || return 1
  fi
}

openclaw_assert_safe_openclaw_config_file() {
  local target_user="$1" config_path="${2:-}" label="${3:-openclaw_config}"
  local target_home runtime_user expected config_dir resolved owner group nlink

  target_home="$(openclaw_target_home "$target_user")"
  [[ -n "$target_home" ]] || openclaw_safe_fail "${label}_user_missing=$target_user" || return 1

  runtime_user="${target_user}_rt"
  expected="$target_home/.openclaw/openclaw.json"
  config_path="${config_path:-$expected}"
  config_dir="$target_home/.openclaw"

  [[ "$config_path" == "$expected" ]] \
    || openclaw_safe_fail "${label}_path_unexpected=$config_path expected=$expected" || return 1
  [[ -d "$config_dir" ]] || openclaw_safe_fail "${label}_dir_missing=$config_dir" || return 1
  [[ ! -L "$config_dir" ]] || openclaw_safe_fail "${label}_dir_symlink=$config_dir" || return 1
  resolved="$(readlink -f "$config_dir" 2>/dev/null || true)"
  [[ "$resolved" == "$config_dir" ]] \
    || openclaw_safe_fail "${label}_dir_resolves_outside=$config_dir resolved=${resolved:-missing}" || return 1
  owner="$(stat -c '%U' "$config_dir" 2>/dev/null || true)"
  group="$(stat -c '%G' "$config_dir" 2>/dev/null || true)"
  case "$owner" in
    root|"$runtime_user") ;;
    *)
      openclaw_safe_fail "${label}_dir_owner_unexpected=$config_dir owner=${owner:-missing}:${group:-missing} expected=root_or_${runtime_user}" || return 1
      ;;
  esac
  if find "$config_dir" -maxdepth 0 -perm /022 2>/dev/null | grep -q .; then
    openclaw_safe_fail "${label}_dir_writable_by_group_or_other=$config_dir" || return 1
  fi

  [[ ! -L "$config_path" ]] || openclaw_safe_fail "${label}_symlink=$config_path" || return 1
  if [[ -e "$config_path" ]]; then
    [[ -f "$config_path" ]] || openclaw_safe_fail "${label}_not_regular=$config_path" || return 1
    resolved="$(readlink -f "$config_path" 2>/dev/null || true)"
    [[ "$resolved" == "$expected" ]] \
      || openclaw_safe_fail "${label}_resolves_outside=$config_path resolved=${resolved:-missing} expected=$expected" || return 1
    nlink="$(stat -c '%h' "$config_path" 2>/dev/null || true)"
    [[ "$nlink" == "1" ]] || openclaw_safe_fail "${label}_hardlink=$config_path links=${nlink:-missing}" || return 1
    owner="$(stat -c '%U' "$config_path" 2>/dev/null || true)"
    group="$(stat -c '%G' "$config_path" 2>/dev/null || true)"
    case "$owner" in
      root|"$runtime_user") ;;
      *)
        openclaw_safe_fail "${label}_owner_unexpected=$config_path owner=${owner:-missing}:${group:-missing} expected=root_or_${runtime_user}" || return 1
        ;;
    esac
    if find "$config_path" -maxdepth 0 -perm /077 2>/dev/null | grep -q .; then
      openclaw_safe_fail "${label}_too_permissive=$config_path" || return 1
    fi
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

  for optional in docker-compose.extra.yml docker-compose.shared-ollama.yml docker-compose.sandbox.yml; do
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
