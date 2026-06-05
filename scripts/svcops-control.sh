#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  svcops-control.sh check USER HOST
  svcops-control.sh check-all START END BASE_DOMAIN
  svcops-control.sh nas-status USER
  svcops-control.sh nas-status-all START END
  svcops-control.sh nas-request USER
  svcops-control.sh nas-requests START END
  svcops-control.sh nas-approve-share USER
  svcops-control.sh nas-reject-share USER REASON
  svcops-control.sh nas-verify USER
  svcops-control.sh nas-verify-all START END
  svcops-control.sh nas-tree USER
  svcops-control.sh nas-search-smoke USER QUERY
  svcops-control.sh nas-runtime-root-fix USER
  svcops-control.sh nas-runtime-root-fix-all START END
  svcops-control.sh nas-register USER SHARE
  svcops-control.sh nas-register-all START END SHARE
  svcops-control.sh nas-unregister USER SHARE [--unmount] [--delete-credential] [--delete-empty-dir]
  svcops-control.sh nas-unregister USER --all [--unmount] [--delete-credential] [--delete-empty-dir]
  svcops-control.sh nas-unregister-all START END SHARE [--unmount] [--delete-credential] [--delete-empty-dir]
  svcops-control.sh nas-unregister-all START END --all [--unmount] [--delete-credential] [--delete-empty-dir]
  svcops-control.sh image-status USER
  svcops-control.sh image-status-all START END
  svcops-control.sh container-logs USER [LINES]
  svcops-control.sh runtime-secret-status USER
  svcops-control.sh handoff-credential USER
  svcops-control.sh hermes-model USER MODEL
  svcops-control.sh hermes-model-all START END MODEL
  svcops-control.sh hermes-guidance USER
  svcops-control.sh hermes-guidance-all START END
  svcops-control.sh image-list
  svcops-control.sh image-release-add REF [NAME]
  svcops-control.sh image-release-verify IMAGE
  svcops-control.sh image-release-promote IMAGE CHANNEL
  svcops-control.sh image-rollout CHANNEL
  svcops-control.sh image-rollout-range START END IMAGE
  svcops-control.sh image-rollout-slot USER IMAGE
  svcops-control.sh image-rollback USER
  svcops-control.sh hermes-install USER IMAGE
  svcops-control.sh dev-slot-install USER openclaw|hermes [IMAGE]
  svcops-control.sh dev-slot-status USER
  svcops-control.sh source-mode-enable USER
  svcops-control.sh source-mode-disable USER
  svcops-control.sh source-mode-status USER
  svcops-control.sh usage USER [SINCE]
  svcops-control.sh usage-all START END [SINCE]
  svcops-control.sh shared-ollama-status
  svcops-control.sh shared-ollama-up MODEL [IMAGE]
  svcops-control.sh shared-ollama-usage [SINCE] [USER]
  svcops-control.sh shared-ollama-smoke USER [MODEL]
  svcops-control.sh ollama-provider USER MODEL [BASE_URL]
  svcops-control.sh ollama-default USER MODEL [BASE_URL]
  svcops-control.sh heartbeat-status USER
  svcops-control.sh heartbeat-status-all START END
  svcops-control.sh heartbeat-disable USER
  svcops-control.sh heartbeat-disable-all START END
  svcops-control.sh heartbeat-ollama USER MODEL [BASE_URL]
  svcops-control.sh heartbeat-ollama-all START END MODEL [BASE_URL]
  svcops-control.sh gateway-refresh USER
  svcops-control.sh nas-prepare USER SHARE
  svcops-control.sh nas-fstab USER SHARE
  svcops-control.sh subdomain USER HOST
  svcops-control.sh isolation USER

Restricted root wrapper for the svcops operating account.

This wrapper does not print NAS credentials or provider/API keys. Handoff
credentials are printed only by the explicit handoff-credential command.
Run through sudoers, not directly by customer accounts.
USAGE
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/internal/lib-safe-compose.bash
source "$script_dir/internal/lib-safe-compose.bash"

container_findmnt_exact_field() {
  local container="$1" path="$2" field="$3"
  docker exec "$container" findmnt -n -M "$path" -o "$field" 2>/dev/null | head -1 || true
}

container_findmnt_exact_line() {
  local container="$1" path="$2"
  docker exec "$container" findmnt -n -M "$path" -o TARGET,SOURCE,FSTYPE,OPTIONS 2>/dev/null | head -1 || true
}

validate_user() {
  local user="$1"
  if ! openclaw_is_managed_slot "$user"; then
    echo "error: invalid managed slot: $user" >&2
    exit 2
  fi
  if ! id "$user" >/dev/null 2>&1; then
    echo "error: user not found: $user" >&2
    exit 1
  fi
}

validate_customer_slot() {
  local user="$1"
  if ! openclaw_is_customer_slot "$user"; then
    echo "error: command requires customer slot ocN, got: $user" >&2
    exit 2
  fi
  validate_user "$user"
}

validate_dev_slot() {
  local user="$1"
  if ! openclaw_is_dev_slot "$user"; then
    echo "error: command requires dev slot dev-oc or dev-hermess, got: $user" >&2
    exit 2
  fi
  validate_user "$user"
}

validate_host() {
  local host="$1"
  if [[ ! "$host" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$ ]]; then
    echo "error: invalid host: $host" >&2
    exit 2
  fi
}

cifs_share_is_valid() {
  openclaw_nas_share_is_valid "$1"
}

validate_share() {
  openclaw_nas_validate_share "$1" || exit $?
}

validate_mount_name() {
  openclaw_nas_validate_mount_name "$1" || exit $?
}

validate_reject_reason() {
  local reason="$1"
  if [[ ! "$reason" =~ ^[A-Za-z0-9_.:-]{1,80}$ ]]; then
    echo "error: invalid reject reason: $reason" >&2
    exit 2
  fi
}

validate_gemini_model() {
  local model="$1"
  if [[ ! "$model" =~ ^gemini-[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$ ]]; then
    echo "error: invalid Gemini model: $model" >&2
    exit 2
  fi
}

mount_name_from_share() {
  openclaw_nas_mount_name_from_share "$1"
}

customer_home() {
  getent passwd "$1" | cut -d: -f6
}

nas_mountpoint() {
  local target_home="$1"
  printf '%s/nas_docs' "$target_home"
}

named_nas_mountpoint() {
  local target_home="$1" mount_name="$2"
  openclaw_nas_mountpoint "$target_home" "$mount_name"
}

nas_credentials_path() {
  local target_home="$1"
  printf '%s/.nas-cifs.cred' "$target_home"
}

named_nas_credentials_path() {
  local target_home="$1" mount_name="$2"
  openclaw_nas_credentials_path "$target_home" "$mount_name"
}

registered_nas_mountpoints() {
  local root="$1"
  awk -v root="$root" '
    $0 !~ /^[[:space:]]*#/ && $3 == "cifs" && ($2 == root || index($2, root "/") == 1) {
      print $2
    }
  ' /etc/fstab 2>/dev/null
}

container_nas_root_for_runtime() {
  local runtime_family="$1"
  if [[ "$runtime_family" == "hermes" ]]; then
    printf '%s' "/workspace/nas_docs"
  else
    printf '%s' "/home/node/nas_docs"
  fi
}

container_path_for_nas_mountpoint() {
  local container_root="$1" root="$2" mountpoint="$3" suffix
  if [[ "$mountpoint" == "$root" ]]; then
    printf '%s' "$container_root"
  else
    suffix="${mountpoint#$root/}"
    printf '%s/%s' "$container_root" "$suffix"
  fi
}

container_runtime_sh_for_family() {
  local container="$1" runtime_family="$2" snippet="$3"
  shift 3
  if [[ "$runtime_family" == "hermes" ]]; then
    docker exec "$container" sh -lc '
      user_cmd="$1"
      shift
      if command -v s6-setuidgid >/dev/null 2>&1 && id hermes >/dev/null 2>&1; then
        exec s6-setuidgid hermes sh -c "$user_cmd" sh "$@"
      elif command -v gosu >/dev/null 2>&1 && id hermes >/dev/null 2>&1; then
        exec gosu hermes sh -c "$user_cmd" sh "$@"
      fi
      exec sh -c "$user_cmd" sh "$@"
    ' sh "$snippet" "$@"
  else
    docker exec "$container" sh -c "$snippet" sh "$@"
  fi
}

mount_options_include_ro() {
  [[ ",${1:-}," == *,ro,* ]]
}

print_nas_status() {
  local target_user="$1" target_home="$2" mountpoint="${3:-}" credentials_path="${4:-}" mount_name="${5:-primary}"
  local entry source target fstype options creds_path current_target current_fstype current_source
  mountpoint="${mountpoint:-$(nas_mountpoint "$target_home")}"
  credentials_path="${credentials_path:-$(nas_credentials_path "$target_home")}"
  echo "target_user=$target_user"
  echo "target_home=$target_home"
  echo "derived_mount_name=$mount_name"
  echo "mountpoint=$mountpoint"

  entry="$(awk -v mp="$mountpoint" '
    $0 !~ /^[[:space:]]*#/ && $2 == mp && $3 == "cifs" { print; exit }
  ' /etc/fstab 2>/dev/null || true)"
  if [[ -n "$entry" ]]; then
    read -r source target fstype options _ <<<"$entry"
    echo "fstab_rule=present"
    echo "fstab_source=$source"
    echo "nas_share=$source"
    creds_path="$(printf '%s' "$options" | tr ',' '\n' | awk -F= '$1 == "credentials" { print $2; exit }')"
    [[ -n "$creds_path" ]] && echo "fstab_credentials=$creds_path"
  else
    echo "fstab_rule=missing"
  fi

  if [[ -s "$credentials_path" ]]; then
    echo "credential_file=present"
  else
    echo "credential_file=missing"
  fi

  current_target="$(openclaw_findmnt_exact_field "$mountpoint" TARGET)"
  current_source="$(openclaw_findmnt_exact_field "$mountpoint" SOURCE)"
  current_fstype="$(openclaw_findmnt_exact_field "$mountpoint" FSTYPE)"
  if [[ "$current_target" == "$mountpoint" ]]; then
    echo "mount=present"
    echo "mount_source=$current_source"
    echo "mount_fstype=$current_fstype"
    if [[ -n "${source:-}" && "$current_source" == "$source" ]]; then
      echo "mount_matches_fstab=yes"
    elif [[ -n "${source:-}" ]]; then
      echo "mount_matches_fstab=no"
      echo "remount_required=yes"
    fi
    openclaw_findmnt_exact_line "$mountpoint" | sed 's/^/mount_exact=/'
  else
    echo "mount=missing"
    openclaw_print_parent_mount_hint "$mountpoint"
  fi

  if [[ "$mountpoint" == "$(nas_mountpoint "$target_home")" ]]; then
    while IFS=$'\t' read -r idx child_mount child_share; do
      [[ -n "$idx" ]] || continue
      echo "registered_child_mount_$idx=$child_mount"
      echo "registered_child_share_$idx=$child_share"
      child_target="$(openclaw_findmnt_exact_field "$child_mount" TARGET)"
      child_source="$(openclaw_findmnt_exact_field "$child_mount" SOURCE)"
      child_fstype="$(openclaw_findmnt_exact_field "$child_mount" FSTYPE)"
      if [[ "$child_target" == "$child_mount" && "$child_fstype" == "cifs" ]]; then
        echo "registered_child_state_$idx=mounted_cifs"
        echo "registered_child_mounted_source_$idx=$child_source"
      elif [[ "$child_target" == "$child_mount" ]]; then
        echo "registered_child_state_$idx=mounted_non_cifs"
        echo "registered_child_mounted_source_$idx=$child_source"
        echo "registered_child_mounted_fstype_$idx=$child_fstype"
      else
        echo "registered_child_state_$idx=not_mounted"
      fi
    done < <(awk -v root="$mountpoint/" '
      $0 !~ /^[[:space:]]*#/ && $2 ~ "^" root && $3 == "cifs" {
        count += 1
        printf "%d\t%s\t%s\n", count, $2, $1
      }
      END {
        if (!count) {
          print "\t\t"
        }
      }
    ' /etc/fstab 2>/dev/null || true)
    if ! awk -v root="$mountpoint/" '$0 !~ /^[[:space:]]*#/ && $2 ~ "^" root && $3 == "cifs" { found=1 } END { exit found ? 0 : 1 }' /etc/fstab 2>/dev/null; then
      echo "registered_child_mounts=none"
    fi
  fi
}

print_customer_nas_next_steps() {
  local target_user="$1" share="${2:-}"
  if [[ -n "$share" ]]; then
    cat <<EOF
customer_next_steps:
  after logging in as $target_user:
  agent-nas-mount --share $share --status
  agent-nas-mount --share $share --reset-credential
EOF
  else
    cat <<EOF
customer_next_steps:
  after logging in as $target_user:
  agent-nas-mount --status
  agent-nas-mount --reset-credential
EOF
  fi
}

share_request_file() {
  local target_home="$1"
  printf '%s/.openclaw-nas/share-request.env' "$target_home"
}

request_value() {
  local key="$1" file="$2"
  awk -F= -v k="$key" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$file" 2>/dev/null || true
}

assert_share_request_path_safe() {
  local target_user="$1" target_home="$2" request_file="$3" resolved
  [[ ! -L "$target_home" ]] || { echo "share_request=invalid_home_symlink"; return 1; }
  if [[ -e "$target_home/.openclaw-nas" && -L "$target_home/.openclaw-nas" ]]; then
    echo "share_request=invalid_control_dir_symlink"
    return 1
  fi
  [[ ! -L "$request_file" ]] || { echo "share_request=invalid_symlink"; return 1; }
  resolved="$(readlink -f "$request_file" 2>/dev/null || true)"
  [[ "$resolved" == "$target_home/.openclaw-nas/share-request.env" ]] || {
    echo "share_request=invalid_resolved_path"
    echo "request_resolved=${resolved:-missing}"
    return 1
  }
  [[ "$(stat -c '%U' "$request_file" 2>/dev/null || true)" == "$target_user" ]] || {
    echo "share_request=invalid_owner"
    echo "request_owner=$(stat -c '%U' "$request_file" 2>/dev/null || echo unknown)"
    return 1
  }
  if find "$request_file" -maxdepth 0 -perm /077 2>/dev/null | grep -q .; then
    echo "share_request=invalid_permissions"
    echo "request_mode=$(stat -c '%a' "$request_file" 2>/dev/null || echo unknown)"
    return 1
  fi
}

print_share_request() {
  local target_user="$1" target_home="$2" request_file requested_share requested_at requested_by current_share owner requested_mountpoint requested_credentials mount_name
  request_file="$(share_request_file "$target_home")"
  echo "target_user=$target_user"
  if [[ ! -f "$request_file" ]]; then
    echo "share_request=missing"
    echo "next_action=none"
    return 0
  fi
  if ! assert_share_request_path_safe "$target_user" "$target_home" "$request_file"; then
    echo "next_action=reject; inspect account state with root"
    return 1
  fi
  requested_share="$(request_value REQUESTED_SHARE "$request_file")"
  requested_at="$(request_value REQUESTED_AT "$request_file")"
  requested_by="$(request_value REQUESTED_BY "$request_file")"
  current_share="$(request_value CURRENT_REGISTERED_SHARE "$request_file")"
  requested_mountpoint="$(request_value MOUNTPOINT "$request_file")"
  requested_credentials="$(request_value CREDENTIALS_PATH "$request_file")"
  if cifs_share_is_valid "$requested_share"; then
    mount_name="$(mount_name_from_share "$requested_share")"
  else
    mount_name="invalid"
  fi
  echo "share_request=present"
  echo "requested_by=${requested_by:-unknown}"
  echo "requested_at=${requested_at:-unknown}"
  echo "derived_mount_name=$mount_name"
  echo "derived_mountpoint=$(named_nas_mountpoint "$target_home" "$mount_name")"
  echo "derived_credentials_file=$(named_nas_credentials_path "$target_home" "$mount_name")"
  if [[ -n "$requested_mountpoint" || -n "$requested_credentials" ]]; then
    if [[ -n "$requested_mountpoint" && "$requested_mountpoint" != "$(named_nas_mountpoint "$target_home" "$mount_name")" ]]; then
      echo "request_path_override=yes"
    elif [[ -n "$requested_credentials" && "$requested_credentials" != "$(named_nas_credentials_path "$target_home" "$mount_name")" ]]; then
      echo "request_path_override=yes"
    else
      echo "request_path_override=no"
    fi
    echo "request_path_fields=ignored; paths are derived from requested_share"
  fi
  echo "current_registered_share=${current_share:-unknown}"
  echo "requested_share=${requested_share:-missing}"
  if cifs_share_is_valid "$requested_share"; then
    echo "next_action=approve_or_decline_request"
    echo "approve_command=sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh nas-approve-share $target_user"
  else
    echo "next_action=reject; invalid requested_share"
    return 1
  fi
}

approve_share_request() {
  local target_user="$1" target_home target_group request_file requested_share requested_mountpoint requested_credentials mount_name approved_dir approved_file stamp helper_args
  target_home="$(customer_home "$target_user")"
  target_group="$(id -gn "$target_user")"
  request_file="$(share_request_file "$target_home")"
  [[ -f "$request_file" ]] || { echo "FAIL share_request_missing"; return 1; }
  if ! assert_share_request_path_safe "$target_user" "$target_home" "$request_file" >/dev/null; then
    echo "FAIL share_request_path_safety"
    return 1
  fi
  requested_share="$(request_value REQUESTED_SHARE "$request_file")"
  validate_share "$requested_share"
  mount_name="$(mount_name_from_share "$requested_share")"
  validate_mount_name "$mount_name"
  requested_mountpoint="$(named_nas_mountpoint "$target_home" "$mount_name")"
  requested_credentials="$(named_nas_credentials_path "$target_home" "$mount_name")"

  echo "approving_share_request_for=$target_user"
  echo "derived_mount_name=$mount_name"
  echo "mountpoint=$requested_mountpoint"
  echo "credentials_path=$requested_credentials"
  echo "requested_share=$requested_share"
  helper_args=(--user "$target_user" --share "$requested_share")
  bash "$script_dir/internal/write-user-nas-fstab-entry.bash" \
    "${helper_args[@]}"

  stamp="$(date +%Y%m%d%H%M%S)"
  approved_dir="$target_home/.openclaw-nas/approved"
  approved_file="$approved_dir/share-request.$stamp.env"
  mkdir -p "$approved_dir"
  {
    printf 'REQUEST_KIND=nas_mount\n'
    printf 'REQUESTED_BY=%s\n' "$(request_value REQUESTED_BY "$request_file")"
    printf 'REQUESTED_AT=%s\n' "$(request_value REQUESTED_AT "$request_file")"
    printf 'MOUNT_NAME=%s\n' "$mount_name"
    printf 'REQUESTED_SHARE=%s\n' "$requested_share"
    printf 'MOUNTPOINT=%s\n' "$requested_mountpoint"
    printf 'CREDENTIALS_PATH=%s\n' "$requested_credentials"
    printf 'APPROVED_AT=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'APPROVED_BY=svcops\n'
  } > "$approved_file"
  chown "$target_user:$target_group" "$target_home/.openclaw-nas" "$approved_dir" "$approved_file"
  chmod 0700 "$target_home/.openclaw-nas" "$approved_dir"
  chmod 0600 "$approved_file"
  rm -f "$request_file"

  echo
  print_nas_status "$target_user" "$target_home" "$requested_mountpoint" "$requested_credentials" "${mount_name:-primary}"
  echo
  print_customer_nas_next_steps "$target_user" "$requested_share"
}

reject_share_request() {
  local target_user="$1" reason="$2" target_home target_group request_file requested_share requested_at requested_by mount_name rejected_dir rejected_file stamp
  target_home="$(customer_home "$target_user")"
  target_group="$(id -gn "$target_user")"
  request_file="$(share_request_file "$target_home")"
  [[ -f "$request_file" ]] || { echo "FAIL share_request_missing"; return 1; }
  if ! assert_share_request_path_safe "$target_user" "$target_home" "$request_file" >/dev/null; then
    echo "FAIL share_request_path_safety"
    return 1
  fi

  requested_share="$(request_value REQUESTED_SHARE "$request_file")"
  requested_at="$(request_value REQUESTED_AT "$request_file")"
  requested_by="$(request_value REQUESTED_BY "$request_file")"
  if cifs_share_is_valid "$requested_share"; then
    mount_name="$(mount_name_from_share "$requested_share")"
  else
    mount_name="invalid"
  fi

  echo "rejecting_share_request_for=$target_user"
  echo "derived_mount_name=$mount_name"
  echo "requested_share=${requested_share:-missing}"
  echo "reject_reason=$reason"

  stamp="$(date +%Y%m%d%H%M%S)"
  rejected_dir="$target_home/.openclaw-nas/rejected"
  rejected_file="$rejected_dir/share-request.$stamp.env"
  mkdir -p "$rejected_dir"
  {
    printf 'REQUEST_KIND=nas_mount\n'
    printf 'REQUESTED_BY=%s\n' "${requested_by:-unknown}"
    printf 'REQUESTED_AT=%s\n' "${requested_at:-unknown}"
    printf 'MOUNT_NAME=%s\n' "$mount_name"
    printf 'REQUESTED_SHARE=%s\n' "${requested_share:-missing}"
    printf 'REJECTED_AT=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'REJECTED_BY=svcops\n'
    printf 'REJECT_REASON=%s\n' "$reason"
  } > "$rejected_file"
  chown "$target_user:$target_group" "$target_home/.openclaw-nas" "$rejected_dir" "$rejected_file"
  chmod 0700 "$target_home/.openclaw-nas" "$rejected_dir"
  chmod 0600 "$rejected_file"
  rm -f "$request_file"
  echo "share_request=rejected"
}

fix_nas_runtime_root() {
  local target_user="$1" target_home data_group nas_root compose_dir runtime_family container_root override_file
  validate_user "$target_user"
  target_home="$(customer_home "$target_user")"
  data_group="${target_user}_data"
  nas_root="$target_home/nas_docs"
  compose_dir="$target_home/openclaw"
  runtime_family="$(slot_runtime_family "$target_user")"
  container_root="$(container_nas_root_for_runtime "$runtime_family")"
  override_file="$compose_dir/docker-compose.nas.yml"

  openclaw_assert_managed_slot_prewrite "$target_user" || return 1
  [[ -d "$nas_root" ]] || { echo "FAIL nas_root_missing=$nas_root"; return 1; }
  [[ ! -L "$nas_root" ]] || { echo "FAIL nas_root_symlink=$nas_root"; return 1; }
  [[ -d "$compose_dir" ]] || { echo "FAIL compose_dir_missing=$compose_dir"; return 1; }
  getent group "$data_group" >/dev/null || { echo "FAIL data_group_missing=$data_group"; return 1; }
  openclaw_assert_safe_compose_dir "$target_user" "$compose_dir" || return 1

  chown "$target_user:$data_group" "$nas_root"
  chmod 0550 "$nas_root"
  if [[ "$runtime_family" == "hermes" ]]; then
    cat > "$override_file" <<EOF
services:
  openclaw-gateway:
    volumes:
      - type: bind
        source: $nas_root
        target: $container_root
        read_only: true
        bind:
          propagation: rslave
EOF
  else
    cat > "$override_file" <<EOF
services:
  openclaw-gateway:
    volumes:
      - type: bind
        source: $nas_root
        target: $container_root
        read_only: true
        bind:
          propagation: rslave
  openclaw-cli:
    volumes:
      - type: bind
        source: $nas_root
        target: $container_root
        read_only: true
        bind:
          propagation: rslave
EOF
  fi
  chown root:root "$override_file"
  chmod 0644 "$override_file"
  echo "target_user=$target_user"
  echo "runtime_family=$runtime_family"
  echo "nas_root=$nas_root"
  echo "nas_root_owner=$target_user:$data_group"
  echo "nas_root_mode=0550"
  echo "container_nas_root=$container_root"
  echo "compose_nas_override=$override_file"
  echo "bind_propagation=rslave"
  refresh_gateway "$target_user"
  echo "== NAS visibility after runtime root fix =="
  verify_nas_visibility "$target_user"
}

gateway_container() {
  local target_user="$1"
  printf 'openclaw-%s-openclaw-gateway-1' "$target_user"
}

redact_sensitive_output() {
  sed -E \
    -e 's/([A-Za-z0-9_]*(API[_-]?KEY|TOKEN|PASSWORD|PASSWD|CREDENTIAL|SECRET)[A-Za-z0-9_]*[=:" ]+)[^[:space:]",}]+/\1[REDACTED]/Ig' \
    -e 's/(Bearer )[A-Za-z0-9._~+\/=-]+/\1[REDACTED]/Ig' \
    -e 's/(sk-[A-Za-z0-9_-]{8})[A-Za-z0-9_-]+/\1[REDACTED]/g'
}

runtime_secret_status() {
  local target_user="$1" target_home runtime_family env_path key found_any config_path
  local -a env_paths provider_keys

  target_home="$(customer_home "$target_user")"
  runtime_family="openclaw"
  if [[ -f "$target_home/openclaw/.env" ]]; then
    runtime_family="$(awk -F= '$1 == "OPENCLAW_RUNTIME_FAMILY" { gsub(/'\''|"/, "", $2); print $2; exit }' "$target_home/openclaw/.env" 2>/dev/null || true)"
    runtime_family="${runtime_family:-openclaw}"
  fi

  provider_keys=(
    ANTHROPIC_API_KEY
    DEEPSEEK_API_KEY
    ELEVENLABS_API_KEY
    GEMINI_API_KEY
    GOOGLE_API_KEY
    GROQ_API_KEY
    MISTRAL_API_KEY
    OPENAI_API_KEY
    OPENROUTER_API_KEY
    PERPLEXITY_API_KEY
    TOGETHER_API_KEY
    XAI_API_KEY
  )

  if [[ "$runtime_family" == "hermes" ]]; then
    env_paths=(
      "$target_home/.hermes/.env"
      "$target_home/.hermes/home/.hermes/.env"
    )
  else
    env_paths=("$target_home/openclaw/.env")
  fi

  echo "target_user=$target_user"
  echo "runtime_family=$runtime_family"
  for env_path in "${env_paths[@]}"; do
    echo "env_file=$env_path"
    if [[ ! -f "$env_path" ]]; then
      echo "env_file_state=missing"
      continue
    fi
    if [[ -L "$env_path" ]]; then
      echo "env_file_state=symlink_refused"
      continue
    fi
    echo "env_file_state=present"
    found_any=0
    for key in "${provider_keys[@]}"; do
      if awk -F= -v k="$key" '$1 == k && length($2) > 0 { found=1 } END { exit found ? 0 : 1 }' "$env_path"; then
        echo "$key=present"
        found_any=1
      fi
    done
    [[ "$found_any" -eq 1 ]] || echo "provider_keys=missing"
  done
  if [[ "$runtime_family" == "hermes" ]]; then
    config_path="$target_home/.hermes/config.yaml"
    python3 "$script_dir/hermes-runtime-config.py" status --config "$config_path" || true
  else
    config_path="$target_home/.openclaw/openclaw.json"
    if openclaw_assert_safe_openclaw_config_file "$target_user" "$config_path" >/dev/null 2>&1; then
      echo "openclaw_config_safety=pass"
    else
      echo "openclaw_config_safety=fail"
    fi
    python3 "$script_dir/openclaw-runtime-config.py" status --config "$config_path" || true
  fi
}

set_hermes_model() {
  local target_user="$1" model="$2" target_home runtime_family runtime_user data_group hermes_config_path
  validate_user "$target_user"
  validate_gemini_model "$model"
  runtime_family="$(slot_runtime_family "$target_user")"
  if [[ "$runtime_family" != "hermes" ]]; then
    echo "target_user=$target_user"
    echo "runtime_family=$runtime_family"
    echo "model_update=skipped_not_hermes"
    return 1
  fi
  target_home="$(customer_home "$target_user")"
  runtime_user="${target_user}_rt"
  data_group="${target_user}_data"
  hermes_config_path="$target_home/.hermes/config.yaml"
  OPENCLAW_HERMES_GEMINI_MODEL="$model" \
    python3 "$script_dir/hermes-runtime-config.py" set-gemini --config "$hermes_config_path"
  chown "$runtime_user:$data_group" "$hermes_config_path"
  chmod 0600 "$hermes_config_path"
  echo "model_update=ok"
  refresh_gateway "$target_user"
}

slot_runtime_family() {
  local target_user="$1" target_home runtime_family
  target_home="$(customer_home "$target_user")"
  runtime_family="openclaw"
  if [[ -f "$target_home/openclaw/.env" ]]; then
    runtime_family="$(awk -F= '$1 == "OPENCLAW_RUNTIME_FAMILY" { gsub(/'\''|"/, "", $2); print $2; exit }' "$target_home/openclaw/.env" 2>/dev/null || true)"
    runtime_family="${runtime_family:-openclaw}"
  fi
  printf '%s' "$runtime_family"
}

slot_public_url() {
  local target_user="$1" target_home origin
  target_home="$(customer_home "$target_user")"
  if [[ -f "$target_home/openclaw/.env" ]]; then
    origin="$(awk -F= '$1 == "OPENCLAW_PROXY_PUBLIC_ORIGIN" { sub(/^[^=]*=/, ""); gsub(/'\''|"/, "", $0); print $0; exit }' "$target_home/openclaw/.env" 2>/dev/null || true)"
  fi
  origin="${origin:-https://${target_user}.ji-tech.co.kr}"
  printf '%s/' "${origin%/}"
}

assert_handoff_file_safe() {
  local file="$1" owner mode
  [[ -f "$file" ]] || { echo "handoff_secret=missing"; return 1; }
  [[ ! -L "$file" ]] || { echo "handoff_secret=symlink_refused"; return 1; }
  owner="$(stat -c '%U:%G' "$file" 2>/dev/null || true)"
  mode="$(stat -c '%a' "$file" 2>/dev/null || true)"
  if [[ "$owner" != "root:svcops" && "$owner" != "root:root" ]]; then
    echo "handoff_secret=invalid_owner"
    echo "handoff_secret_owner=${owner:-unknown}"
    return 1
  fi
  if find "$file" -maxdepth 0 -perm /027 2>/dev/null | grep -q .; then
    echo "handoff_secret=invalid_permissions"
    echo "handoff_secret_mode=${mode:-unknown}"
    return 1
  fi
}

print_handoff_credential() {
  local target_user="$1" target_home runtime_family url token config_path password secret_file legacy_secret_file
  target_home="$(customer_home "$target_user")"
  runtime_family="$(slot_runtime_family "$target_user")"
  url="$(slot_public_url "$target_user")"

  echo "target_user=$target_user"
  echo "runtime_family=$runtime_family"
  echo "url=$url"

  if [[ "$runtime_family" == "hermes" ]]; then
    secret_file="/srv/openclaw-ops/handoff/hermes-workspace-${target_user}.env"
    legacy_secret_file="/srv/openclaw-ops/reports/hermes-workspace-${target_user}.password"
    if [[ ! -f "$secret_file" && -f "$legacy_secret_file" ]]; then
      assert_handoff_file_safe "$legacy_secret_file" || return 1
      mkdir -p /srv/openclaw-ops/handoff
      chown root:svcops /srv/openclaw-ops/handoff 2>/dev/null || chown root:root /srv/openclaw-ops/handoff
      chmod 0750 /srv/openclaw-ops/handoff
      cp "$legacy_secret_file" "$secret_file"
      chown root:svcops "$secret_file" 2>/dev/null || chown root:root "$secret_file"
      chmod 0640 "$secret_file"
      rm -f "$legacy_secret_file"
      echo "handoff_secret_migrated_from=$legacy_secret_file"
      echo "handoff_secret_location=handoff"
    else
      echo "handoff_secret_location=handoff"
    fi
    if ! assert_handoff_file_safe "$secret_file"; then
      return 1
    fi
    password="$(awk -F= '$1 == "password" { sub(/^[^=]*=/, ""); print; exit }' "$secret_file" 2>/dev/null || true)"
    [[ -n "$password" ]] || { echo "handoff_password=missing"; return 1; }
    echo "handoff_kind=hermes_workspace_password"
    echo "handoff_secret_file=$secret_file"
    echo "password=$password"
    return 0
  fi

  config_path="$target_home/.openclaw/openclaw.json"
  openclaw_assert_safe_openclaw_config_file "$target_user" "$config_path" || return 1
  token="$(OPENCLAW_CONFIG_PATH="$config_path" python3 - <<'PY'
import json
import os
from pathlib import Path

path = Path(os.environ["OPENCLAW_CONFIG_PATH"])
cfg = json.loads(path.read_text(encoding="utf-8"))
print(cfg.get("gateway", {}).get("auth", {}).get("token", ""))
PY
)"
  [[ -n "$token" ]] || { echo "handoff_token=missing"; return 1; }
  echo "handoff_kind=openclaw_gateway_token"
  echo "handoff_secret_file=$config_path"
  echo "token=$token"
}

shared_ollama_base_url() {
  awk -F= '$1 == "OPENCLAW_SHARED_OLLAMA_BASE_URL" { sub(/^[^=]*=/, ""); print; exit }' \
    /srv/openclaw-ollama/endpoint.env 2>/dev/null || true
}

compose_files() {
  local compose_dir="$1"
  local runtime_family=""
  if [[ -f "$compose_dir/.env" ]]; then
    runtime_family="$(awk -F= '$1 == "OPENCLAW_RUNTIME_FAMILY" { gsub(/'\''|"/, "", $2); print $2; exit }' "$compose_dir/.env" 2>/dev/null || true)"
  fi
  printf '%s\n' -f docker-compose.yml
  [[ -f "$compose_dir/docker-compose.nas.yml" ]] && printf '%s\n' -f docker-compose.nas.yml
  [[ -f "$compose_dir/docker-compose.source.yml" ]] && printf '%s\n' -f docker-compose.source.yml
  if [[ "$runtime_family" == "hermes" ]]; then
    return 0
  fi
  [[ -f "$compose_dir/docker-compose.extra.yml" ]] && printf '%s\n' -f docker-compose.extra.yml
  [[ -f "$compose_dir/docker-compose.host-user.yml" ]] && printf '%s\n' -f docker-compose.host-user.yml
  [[ -f "$compose_dir/docker-compose.shared-ollama.yml" ]] && printf '%s\n' -f docker-compose.shared-ollama.yml
  [[ -f "$compose_dir/docker-compose.sandbox.yml" ]] && printf '%s\n' -f docker-compose.sandbox.yml
}

refresh_gateway() {
  local target_user="$1" target_home compose_dir container
  target_home="$(customer_home "$target_user")"
  compose_dir="$target_home/openclaw"
  container="$(gateway_container "$target_user")"
  [[ -d "$compose_dir" ]] || { echo "FAIL compose_dir_missing=$compose_dir"; return 1; }
  openclaw_assert_safe_compose_dir "$target_user" "$compose_dir" || return 1

  echo "action=gateway_refresh"
  (
    cd "$compose_dir"
    mapfile -t args < <(compose_files "$compose_dir")
    docker compose "${args[@]}" up -d --force-recreate openclaw-gateway
  )
  docker ps --filter "name=^/${container}$" --format 'container={{.Names}} status={{.Status}}'
}

verify_nas_visibility() {
  local target_user="$1" target_home mountpoint container sample_count failed=0
  local host_source host_fstype host_target host_options container_source container_fstype container_target container_options container_mp nas_mp share_name
  local host_failed=0 host_readonly_failed=0 container_failed=0 container_readonly_failed=0
  local runtime_family container_root
  local -a visible_nas_mountpoints=()
  target_home="$(customer_home "$target_user")"
  mountpoint="$(nas_mountpoint "$target_home")"
  container="$(gateway_container "$target_user")"
  runtime_family="$(slot_runtime_family "$target_user")"
  container_root="$(container_nas_root_for_runtime "$runtime_family")"

  echo "target_user=$target_user"
  echo "runtime_family=$runtime_family"
  echo "== NAS visibility map =="
  echo "+ account: $target_user"
  echo "+ host root:      $mountpoint"
  echo "+ container root: $container_root"
  echo "+ rule:           host_root/host-<hosthash>/SHARE-<sharehash> -> container_root/host-<hosthash>/SHARE-<sharehash>"
  mapfile -t nas_mountpoints < <(registered_nas_mountpoints "$mountpoint")
  if [[ "${#nas_mountpoints[@]}" -eq 0 ]]; then
    echo "+ mounted shares: none"
    echo "FAIL host_nas_mounted_cifs"
    echo "INFO host_nas_registered_mounts=none"
    failed=1
  else
    echo "INFO host_nas_registered_mount_count=${#nas_mountpoints[@]}"
    for nas_mp in "${nas_mountpoints[@]}"; do
      host_source="$(openclaw_findmnt_exact_field "$nas_mp" SOURCE)"
      host_target="$(openclaw_findmnt_exact_field "$nas_mp" TARGET)"
      host_fstype="$(openclaw_findmnt_exact_field "$nas_mp" FSTYPE)"
      host_options="$(openclaw_findmnt_exact_field "$nas_mp" OPTIONS)"
      if [[ "$host_target" == "$nas_mp" && "$host_fstype" == "cifs" ]]; then
        echo "INFO host_nas_mount=$nas_mp source=$host_source"
        share_name="${nas_mp#$mountpoint/}"
        echo "+ share:          ${share_name:-primary}"
        echo "| source:         $host_source"
        echo "| host path:      $nas_mp"
        echo "| host state:     mounted cifs"
        if mount_options_include_ro "$host_options"; then
          echo "| host readonly:  yes"
        else
          echo "INFO host_nas_not_readonly=$nas_mp options=${host_options:-missing}"
          echo "| host readonly:  no"
          host_readonly_failed=1
        fi
        visible_nas_mountpoints+=("$nas_mp")
      elif [[ "$nas_mp" == "$mountpoint" && "${#nas_mountpoints[@]}" -gt 1 ]]; then
        :
      else
        echo "INFO host_nas_mount_bad=$nas_mp target=${host_target:-missing} fstype=${host_fstype:-missing} source=${host_source:-missing}"
        echo "+ share problem:  $nas_mp"
        echo "| host state:     not mounted as cifs"
        host_failed=1
      fi
    done
    if [[ "${#visible_nas_mountpoints[@]}" -gt 0 && "$host_failed" -eq 0 ]]; then
      echo "PASS host_nas_mounted_cifs"
    else
      echo "FAIL host_nas_mounted_cifs"
      failed=1
    fi
    if [[ "${#visible_nas_mountpoints[@]}" -gt 0 && "$host_readonly_failed" -eq 0 ]]; then
      echo "PASS host_nas_readonly"
    else
      echo "FAIL host_nas_readonly"
      failed=1
    fi
  fi

  if ! docker ps --format '{{.Names}}' | grep -qx "$container"; then
    echo "FAIL gateway_container_running"
    return 1
  fi

  if [[ "${#visible_nas_mountpoints[@]}" -eq 0 ]]; then
    container_failed=1
    echo "INFO container_nas_visible_mounts=none"
  else
    container_root_options="$(container_findmnt_exact_field "$container" "$container_root" OPTIONS)"
    if mount_options_include_ro "$container_root_options"; then
      echo "PASS container_nas_root_readonly"
    else
      echo "FAIL container_nas_root_readonly"
      echo "INFO container_nas_root_options=${container_root_options:-missing}"
      container_failed=1
    fi
    for nas_mp in "${visible_nas_mountpoints[@]}"; do
      container_mp="$(container_path_for_nas_mountpoint "$container_root" "$mountpoint" "$nas_mp")"
      container_source="$(container_findmnt_exact_field "$container" "$container_mp" SOURCE)"
      container_target="$(container_findmnt_exact_field "$container" "$container_mp" TARGET)"
      container_fstype="$(container_findmnt_exact_field "$container" "$container_mp" FSTYPE)"
      container_options="$(container_findmnt_exact_field "$container" "$container_mp" OPTIONS)"
      if [[ "$container_target" == "$container_mp" && "$container_fstype" == "cifs" ]] \
        && container_runtime_sh_for_family "$container" "$runtime_family" 'test -r "$1"' "$container_mp"; then
        echo "INFO container_nas_mount=$container_mp source=$container_source"
        echo "| container path: $container_mp"
        echo "| container state: mounted cifs"
        if mount_options_include_ro "$container_options"; then
          echo "| container readonly: yes"
        else
          echo "INFO container_nas_not_readonly=$container_mp options=${container_options:-missing}"
          echo "| container readonly: no"
          container_readonly_failed=1
        fi
      else
        echo "INFO container_nas_mount_bad=$container_mp target=${container_target:-missing} fstype=${container_fstype:-missing} source=${container_source:-missing}"
        echo "| container path: $container_mp"
        echo "| container state: not mounted as cifs"
        container_failed=1
      fi
    done
  fi
  if [[ "$container_failed" -eq 0 ]]; then
    echo "PASS container_nas_mounted_cifs"
  else
    echo "FAIL container_nas_mounted_cifs"
    failed=1
  fi
  if [[ "${#visible_nas_mountpoints[@]}" -gt 0 && "$container_readonly_failed" -eq 0 ]]; then
    echo "PASS container_nas_mounts_readonly"
  else
    echo "FAIL container_nas_mounts_readonly"
    failed=1
  fi

  sample_count="$(container_runtime_sh_for_family "$container" "$runtime_family" 'find "$1" -maxdepth 1 -mindepth 1 2>/dev/null | head -3 | wc -l' "$container_root" 2>/dev/null || true)"
  echo "INFO container_nas_sample=${sample_count:-0}"
  return "$failed"
}

verify_nas_and_refresh_if_needed() {
  local target_user="$1" output
  output="$(verify_nas_visibility "$target_user")"
  printf '%s\n' "$output"
  if printf '%s\n' "$output" | grep -qx 'PASS host_nas_mounted_cifs' \
    && printf '%s\n' "$output" | grep -qx 'FAIL container_nas_mounted_cifs'; then
    echo "decision=host_mount_ok_container_stale"
    refresh_gateway "$target_user"
    echo "== after gateway refresh =="
    verify_nas_visibility "$target_user"
    return $?
  fi
  if printf '%s\n' "$output" | grep -q '^FAIL '; then
    return 1
  fi
}

ensure_dev_slot_accounts() {
  local target_user="$1" runtime_user data_group target_home
  openclaw_assert_dev_slot_name "$target_user" || return $?
  runtime_user="${target_user}_rt"
  data_group="${target_user}_data"

  if ! id "$target_user" >/dev/null 2>&1; then
    useradd -m -s /bin/bash "$target_user"
  fi
  target_home="$(customer_home "$target_user")"
  [[ "$target_home" == "/home/$target_user" ]] || {
    echo "error: unexpected home for $target_user: ${target_home:-missing}" >&2
    return 1
  }

  if ! getent group "$data_group" >/dev/null; then
    groupadd "$data_group"
  fi
  if ! id "$runtime_user" >/dev/null 2>&1; then
    useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin "$runtime_user"
  fi
  usermod -aG "$data_group" "$runtime_user"
  mkdir -p "$target_home/nas_docs"
  gpasswd -d "$target_user" docker >/dev/null 2>&1 || true
  gpasswd -d "$target_user" sudo >/dev/null 2>&1 || true
  chown "$target_user:$data_group" "$target_home/nas_docs"
  chmod 0550 "$target_home/nas_docs"
  chown "$target_user:$target_user" "$target_home"
  chmod 0750 "$target_home"

  echo "target_user=$target_user"
  echo "slot_kind=dev"
  echo "target_home=$target_home"
  echo "runtime_user=$runtime_user"
  echo "data_group=$data_group"
  echo "sudo_group=absent"
  echo "docker_group=absent"
}

dev_slot_install() {
  local target_user="$1" family="$2" image="${3:-}" host gateway_port bridge_port expected_family
  openclaw_assert_dev_slot_name "$target_user" || return $?
  ensure_dev_slot_accounts "$target_user"
  case "$family" in
    openclaw|hermes) ;;
    *) echo "error: family must be openclaw or hermes" >&2; return 2 ;;
  esac
  expected_family="$(openclaw_slot_default_family "$target_user")"
  if [[ "$family" != "$expected_family" ]]; then
    echo "error: $target_user is reserved for family=$expected_family, got=$family" >&2
    return 2
  fi
  host="$target_user.ji-tech.co.kr"
  gateway_port="$(openclaw_slot_default_gateway_port "$target_user")"
  bridge_port="$(openclaw_slot_default_bridge_port "$target_user")"
  if [[ "$family" == "hermes" ]]; then
    image="${image:-${OPENCLAW_DEV_HERMES_IMAGE:-}}"
    [[ -n "$image" ]] || { echo "error: Hermes dev image is required as arg3 or OPENCLAW_DEV_HERMES_IMAGE" >&2; return 2; }
    bash "$script_dir/internal/install-hermes-slot-from-image.bash" \
      --user "$target_user" \
      --host "$host" \
      --image "$image" \
      --gateway-port "$gateway_port" \
      --force
  else
    image="${image:-${OPENCLAW_DEV_OPENCLAW_IMAGE:-openclaw-nas-agent:baseline}}"
    bash "$script_dir/internal/install-customer-slot-from-image.bash" \
      --user "$target_user" \
      --host "$host" \
      --image "$image" \
      --gateway-port "$gateway_port" \
      --bridge-port "$bridge_port" \
      --force \
      --check
  fi
}

source_mode_status() {
  local target_user="$1" target_home compose_dir source_path artifact_path container_path override_path runtime_family
  validate_dev_slot "$target_user"
  target_home="$(customer_home "$target_user")"
  compose_dir="$target_home/openclaw"
  override_path="$compose_dir/docker-compose.source.yml"
  runtime_family="$(slot_runtime_family "$target_user")"
  source_path="$(openclaw_dev_source_path "$target_user")"
  artifact_path="$(openclaw_dev_source_artifact_path "$target_user")"
  container_path="$(openclaw_dev_source_container_path "$target_user")"
  echo "target_user=$target_user"
  echo "slot_kind=dev"
  echo "runtime_family=$runtime_family"
  echo "source_path=$source_path"
  echo "source_path_state=$([[ -d "$source_path" ]] && echo present || echo missing)"
  echo "artifact_path=$artifact_path"
  echo "artifact_path_state=$([[ -e "$artifact_path" ]] && echo present || echo missing)"
  if [[ "$target_user" == "dev-hermess" ]]; then
    echo "workspace_package_json=$([[ -f "$artifact_path/package.json" ]] && echo present || echo missing)"
    echo "workspace_server_entry=$([[ -f "$artifact_path/server-entry.js" ]] && echo present || echo missing)"
    echo "workspace_node_modules=$([[ -d "$artifact_path/node_modules" ]] && echo present || echo missing)"
    echo "workspace_dist=$([[ -f "$artifact_path/dist/server/server.js" ]] && echo present || echo missing)"
  fi
  echo "container_path=$container_path"
  echo "source_override=$override_path"
  echo "source_mode=$([[ -f "$override_path" ]] && echo enabled || echo disabled)"
}

source_mode_enable() {
  local target_user="$1" target_home compose_dir source_path artifact_path container_path override_path runtime_family
  validate_dev_slot "$target_user"
  target_home="$(customer_home "$target_user")"
  compose_dir="$target_home/openclaw"
  source_path="$(openclaw_dev_source_path "$target_user")"
  artifact_path="$(openclaw_dev_source_artifact_path "$target_user")"
  container_path="$(openclaw_dev_source_container_path "$target_user")"
  override_path="$compose_dir/docker-compose.source.yml"
  runtime_family="$(slot_runtime_family "$target_user")"

  [[ -d "$compose_dir" ]] || { echo "FAIL compose_dir_missing=$compose_dir"; return 1; }
  [[ -d "$source_path" ]] || { echo "FAIL source_path_missing=$source_path"; return 1; }
  [[ -e "$artifact_path" ]] || { echo "FAIL source_artifact_missing=$artifact_path"; return 1; }
  if [[ "$target_user" == "dev-hermess" ]]; then
    [[ -f "$artifact_path/package.json" ]] || { echo "FAIL hermes_workspace_package_json_missing=$artifact_path/package.json"; return 1; }
    [[ -f "$artifact_path/server-entry.js" ]] || { echo "FAIL hermes_workspace_server_entry_missing=$artifact_path/server-entry.js"; return 1; }
    [[ -d "$artifact_path/node_modules" ]] || { echo "FAIL hermes_workspace_node_modules_missing=$artifact_path/node_modules"; return 1; }
    [[ -f "$artifact_path/dist/server/server.js" ]] || { echo "FAIL hermes_workspace_dist_missing=$artifact_path/dist/server/server.js"; return 1; }
  fi
  openclaw_assert_safe_compose_dir "$target_user" "$compose_dir" || return 1

  if [[ "$target_user" == "dev-oc" ]]; then
    cat > "$override_path" <<EOF
services:
  openclaw-gateway:
    volumes:
      - $artifact_path:$container_path:ro
  openclaw-cli:
    volumes:
      - $artifact_path:$container_path:ro
EOF
  else
    cat > "$override_path" <<EOF
services:
  openclaw-gateway:
    volumes:
      - $source_path:$container_path:rw
EOF
  fi
  chown root:root "$override_path"
  chmod 0644 "$override_path"
  echo "source_mode=enabled"
  echo "target_user=$target_user"
  echo "runtime_family=$runtime_family"
  echo "source_path=$source_path"
  echo "artifact_path=$artifact_path"
  echo "container_path=$container_path"
  refresh_gateway "$target_user"
}

source_mode_disable() {
  local target_user="$1" target_home compose_dir override_path
  validate_dev_slot "$target_user"
  target_home="$(customer_home "$target_user")"
  compose_dir="$target_home/openclaw"
  override_path="$compose_dir/docker-compose.source.yml"
  [[ -e "$override_path" ]] && rm -f "$override_path"
  echo "source_mode=disabled"
  echo "target_user=$target_user"
  refresh_gateway "$target_user"
}

command_name="${1:-}"
shift || true

if [[ "$command_name" == "-h" || "$command_name" == "--help" || "$command_name" == "help" ]]; then
  usage
  exit 0
fi

if [[ "$(id -u)" -ne 0 ]]; then
  echo "error: run through sudo/root" >&2
  exit 1
fi

case "$command_name" in
  check)
    [[ $# -eq 2 ]] || { usage >&2; exit 2; }
    target_user="$1"
    host="$2"
    validate_user "$target_user"
    validate_host "$host"
    check_args=()
    if openclaw_is_dev_slot "$target_user"; then
      check_args+=(--skip-provider-key-check)
    fi
    bash "$script_dir/internal/check-customer-deployment.bash" \
      --user "$target_user" \
      --expected-basepath / \
      --expected-origin "https://$host" \
      "${check_args[@]}"
    ;;

  check-all)
    [[ $# -eq 3 ]] || { usage >&2; exit 2; }
    start="$1"
    end="$2"
    base_domain="$3"
    [[ "$start" =~ ^[0-9]+$ && "$end" =~ ^[0-9]+$ && "$start" -le "$end" ]] || {
      echo "error: invalid START/END" >&2
      exit 2
    }
    validate_host "x.$base_domain"
    failed=0
    for i in $(seq "$start" "$end"); do
      target_user="oc$i"
      host="$target_user.$base_domain"
      echo "== $target_user =="
      if id "$target_user" >/dev/null 2>&1; then
        if ! bash "$script_dir/internal/check-customer-deployment.bash" \
          --user "$target_user" \
          --expected-basepath / \
          --expected-origin "https://$host"; then
          failed=1
        fi
      else
        echo "FAIL user_missing"
        failed=1
      fi
    done
    exit "$failed"
    ;;

  nas-status)
    [[ $# -eq 1 ]] || { usage >&2; exit 2; }
    target_user="$1"
    validate_user "$target_user"
    target_home="$(customer_home "$target_user")"
    print_nas_status "$target_user" "$target_home"
    ;;

  nas-status-all)
    [[ $# -eq 2 ]] || { usage >&2; exit 2; }
    start="$1"
    end="$2"
    [[ "$start" =~ ^[0-9]+$ && "$end" =~ ^[0-9]+$ && "$start" -le "$end" ]] || {
      echo "error: invalid START/END" >&2
      exit 2
    }
    for i in $(seq "$start" "$end"); do
      target_user="oc$i"
      echo "== $target_user =="
      if id "$target_user" >/dev/null 2>&1; then
        target_home="$(customer_home "$target_user")"
        print_nas_status "$target_user" "$target_home"
      else
        echo "user=missing"
      fi
    done
    ;;

  nas-requests)
    [[ $# -eq 2 ]] || { usage >&2; exit 2; }
    start="$1"
    end="$2"
    [[ "$start" =~ ^[0-9]+$ && "$end" =~ ^[0-9]+$ && "$start" -le "$end" ]] || {
      echo "error: invalid START/END" >&2
      exit 2
    }
    failed=0
    for i in $(seq "$start" "$end"); do
      target_user="oc$i"
      echo "== $target_user =="
      if id "$target_user" >/dev/null 2>&1; then
        target_home="$(customer_home "$target_user")"
        print_share_request "$target_user" "$target_home" || failed=1
      else
        echo "user=missing"
      fi
    done
    exit "$failed"
    ;;

  nas-request)
    [[ $# -eq 1 ]] || { usage >&2; exit 2; }
    target_user="$1"
    validate_user "$target_user"
    target_home="$(customer_home "$target_user")"
    echo "== $target_user =="
    print_share_request "$target_user" "$target_home"
    ;;

  nas-approve-share)
    [[ $# -eq 1 ]] || { usage >&2; exit 2; }
    target_user="$1"
    validate_user "$target_user"
    approve_share_request "$target_user"
    ;;

  nas-reject-share)
    [[ $# -eq 2 ]] || { usage >&2; exit 2; }
    target_user="$1"
    reason="$2"
    validate_user "$target_user"
    validate_reject_reason "$reason"
    reject_share_request "$target_user" "$reason"
    ;;

  nas-verify)
    [[ $# -eq 1 ]] || { usage >&2; exit 2; }
    target_user="$1"
    validate_user "$target_user"
    verify_nas_and_refresh_if_needed "$target_user"
    ;;

  nas-verify-all)
    [[ $# -eq 2 ]] || { usage >&2; exit 2; }
    start="$1"
    end="$2"
    [[ "$start" =~ ^[0-9]+$ && "$end" =~ ^[0-9]+$ && "$start" -le "$end" ]] || {
      echo "error: invalid START/END" >&2
      exit 2
    }
    failed=0
    for i in $(seq "$start" "$end"); do
      target_user="oc$i"
      echo "== $target_user =="
      if id "$target_user" >/dev/null 2>&1; then
        verify_nas_and_refresh_if_needed "$target_user" || failed=1
      else
        echo "FAIL user_missing"
        failed=1
      fi
    done
    exit "$failed"
    ;;

  nas-tree)
    [[ $# -eq 1 ]] || { usage >&2; exit 2; }
    target_user="$1"
    validate_user "$target_user"
    bash "$script_dir/internal/openclaw-nas-container-view.bash" tree --user "$target_user"
    ;;

  nas-search-smoke)
    [[ $# -eq 2 ]] || { usage >&2; exit 2; }
    target_user="$1"
    query="$2"
    validate_user "$target_user"
    bash "$script_dir/internal/openclaw-nas-container-view.bash" search-smoke --user "$target_user" --query "$query"
    ;;

  nas-runtime-root-fix)
    [[ $# -eq 1 ]] || { usage >&2; exit 2; }
    target_user="$1"
    fix_nas_runtime_root "$target_user"
    ;;

  nas-runtime-root-fix-all)
    [[ $# -eq 2 ]] || { usage >&2; exit 2; }
    start="$1"
    end="$2"
    [[ "$start" =~ ^[0-9]+$ && "$end" =~ ^[0-9]+$ && "$start" -le "$end" ]] || {
      echo "error: invalid START/END" >&2
      exit 2
    }
    failed=0
    for i in $(seq "$start" "$end"); do
      target_user="oc$i"
      echo "== $target_user =="
      if id "$target_user" >/dev/null 2>&1; then
        fix_nas_runtime_root "$target_user" || failed=1
      else
        echo "FAIL user_missing"
        failed=1
      fi
    done
    exit "$failed"
    ;;

  nas-register|nas-prepare)
    [[ $# -eq 2 ]] || { usage >&2; exit 2; }
    target_user="$1"
    share="$2"
    validate_user "$target_user"
    validate_share "$share"
    mount_name="$(mount_name_from_share "$share")"
    helper_args=(--user "$target_user" --share "$share")
    bash "$script_dir/internal/write-user-nas-fstab-entry.bash" "${helper_args[@]}"
    target_home="$(customer_home "$target_user")"
    echo
    print_nas_status "$target_user" "$target_home" \
      "$(named_nas_mountpoint "$target_home" "$mount_name")" \
      "$(named_nas_credentials_path "$target_home" "$mount_name")" \
      "$mount_name"
    echo
    print_customer_nas_next_steps "$target_user" "$share"
    ;;

  nas-register-all)
    [[ $# -eq 3 ]] || { usage >&2; exit 2; }
    start="$1"
    end="$2"
    share="$3"
    [[ "$start" =~ ^[0-9]+$ && "$end" =~ ^[0-9]+$ && "$start" -le "$end" ]] || {
      echo "error: invalid START/END" >&2
      exit 2
    }
    validate_share "$share"
    failed=0
    for i in $(seq "$start" "$end"); do
      target_user="oc$i"
      echo "== $target_user =="
      if id "$target_user" >/dev/null 2>&1; then
        helper_args=(--user "$target_user" --share "$share")
        if ! bash "$script_dir/internal/write-user-nas-fstab-entry.bash" \
          "${helper_args[@]}" | sed -n '/^target_user=/p;/^derived_mount_name=/p;/^mountpoint=/p;/^nas_share=/p;/^fstab_user_mount=/p'; then
          failed=1
        fi
      else
        echo "FAIL user_missing"
        failed=1
      fi
    done
    exit "$failed"
    ;;

  nas-unregister)
    [[ $# -ge 2 ]] || { usage >&2; exit 2; }
    target_user="$1"
    shift
    validate_user "$target_user"
    helper_args=(--user "$target_user")
    selector="$1"
    shift
    if [[ "$selector" == "--all" ]]; then
      helper_args+=(--all)
    else
      validate_share "$selector"
      helper_args+=(--share "$selector")
    fi
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --unmount|--delete-credential|--delete-empty-dir|--no-daemon-reload)
          helper_args+=("$1")
          shift
          ;;
        --*)
          echo "error: unknown nas-unregister option: $1" >&2
          exit 2
          ;;
        *)
          echo "error: unexpected nas-unregister argument: $1" >&2
          echo "hint: use nas-unregister USER //HOST/SHARE or nas-unregister USER --all" >&2
          exit 2
          ;;
      esac
    done
    bash "$script_dir/internal/remove-user-nas-fstab-entry.bash" "${helper_args[@]}"
    ;;

  nas-unregister-all)
    [[ $# -ge 3 ]] || { usage >&2; exit 2; }
    start="$1"
    end="$2"
    selector="$3"
    shift 3
    [[ "$start" =~ ^[0-9]+$ && "$end" =~ ^[0-9]+$ && "$start" -le "$end" ]] || {
      echo "error: invalid START/END" >&2
      exit 2
    }
    unregister_extra=()
    if [[ "$selector" == "--all" ]]; then
      unregister_extra+=(--all)
    else
      validate_share "$selector"
      unregister_extra+=(--share "$selector")
    fi
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --unmount|--delete-credential|--delete-empty-dir|--no-daemon-reload)
          unregister_extra+=("$1")
          shift
          ;;
        --*)
          echo "error: unknown nas-unregister-all option: $1" >&2
          exit 2
          ;;
        *)
          echo "error: unexpected nas-unregister-all argument: $1" >&2
          echo "hint: use nas-unregister-all START END //HOST/SHARE or --all" >&2
          exit 2
          ;;
      esac
    done
    failed=0
    for i in $(seq "$start" "$end"); do
      target_user="oc$i"
      echo "== $target_user =="
      if id "$target_user" >/dev/null 2>&1; then
        if ! bash "$script_dir/internal/remove-user-nas-fstab-entry.bash" \
          --user "$target_user" "${unregister_extra[@]}" | sed -n '/^target_user=/p;/^derived_mount_name=/p;/^mountpoint=/p;/^nas_share=/p;/^fstab_user_mount=/p;/^active_mount=/p;/^unmount=/p;/^credential_file=/p;/^empty_dir=/p;/^note=/p'; then
          failed=1
        fi
      else
        echo "FAIL user_missing"
        failed=1
      fi
    done
    exit "$failed"
    ;;

  gateway-refresh)
    [[ $# -eq 1 ]] || { usage >&2; exit 2; }
    target_user="$1"
    validate_user "$target_user"
    refresh_gateway "$target_user"
    ;;

  image-status)
    [[ $# -eq 1 ]] || { usage >&2; exit 2; }
    target_user="$1"
    validate_user "$target_user"
    container="openclaw-${target_user}-openclaw-gateway-1"
    runtime_family=""
    target_home="$(customer_home "$target_user")"
    if [[ -f "$target_home/openclaw/.env" ]]; then
      runtime_family="$(awk -F= '$1 == "OPENCLAW_RUNTIME_FAMILY" { gsub(/'\''|"/, "", $2); print $2; exit }' "$target_home/openclaw/.env" 2>/dev/null || true)"
    fi
    if ! docker inspect "$container" >/dev/null 2>&1; then
      echo "target_user=$target_user"
      echo "container=$container"
      echo "container_status=missing"
      exit 1
    fi
    echo "target_user=$target_user"
    echo "runtime_family=${runtime_family:-openclaw}"
    echo "container=$container"
    image_ref="$(docker inspect "$container" --format '{{.Config.Image}}')"
    docker inspect "$container" \
      --format 'container_status={{.State.Status}}
container_health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}
container_image_ref={{.Config.Image}}
container_image_id={{.Image}}'
    if docker image inspect "$image_ref" >/dev/null 2>&1; then
      docker image inspect "$image_ref" --format 'container_image_repo_digests={{join .RepoDigests ","}}' || true
      docker image inspect "$image_ref" --format 'container_image_family={{with .Config.Labels}}{{index . "org.opencontainers.image.family"}}{{end}}
container_image_openclaw_source={{with .Config.Labels}}{{index . "org.opencontainers.image.openclaw.source"}}{{end}}
container_image_openclaw_ref={{with .Config.Labels}}{{index . "org.opencontainers.image.openclaw.revision"}}{{end}}
container_image_hermes_source={{with .Config.Labels}}{{index . "org.opencontainers.image.hermes.source"}}{{end}}
container_image_hermes_ref={{with .Config.Labels}}{{index . "org.opencontainers.image.hermes.revision"}}{{end}}
container_image_hermes_agent_source={{with .Config.Labels}}{{index . "org.opencontainers.image.hermes.agent.source"}}{{end}}
container_image_hermes_agent_ref={{with .Config.Labels}}{{index . "org.opencontainers.image.hermes.agent.revision"}}{{end}}
container_image_hermes_workspace_source={{with .Config.Labels}}{{index . "org.opencontainers.image.hermes.workspace.source"}}{{end}}
container_image_hermes_workspace_ref={{with .Config.Labels}}{{index . "org.opencontainers.image.hermes.workspace.revision"}}{{end}}
container_image_base={{with .Config.Labels}}{{index . "org.opencontainers.image.base.name"}}{{end}}
container_image_workspace={{with .Config.Labels}}{{index . "org.opencontainers.image.workspace.name"}}{{end}}' || true
    fi
    ;;

  container-logs)
    [[ $# -ge 1 && $# -le 2 ]] || { usage >&2; exit 2; }
    target_user="$1"
    lines="${2:-120}"
    validate_user "$target_user"
    if [[ ! "$lines" =~ ^[0-9]+$ || "$lines" -lt 1 || "$lines" -gt 300 ]]; then
      echo "error: LINES must be an integer from 1 to 300" >&2
      exit 2
    fi
    container="$(gateway_container "$target_user")"
    if ! docker inspect "$container" >/dev/null 2>&1; then
      echo "target_user=$target_user"
      echo "container=$container"
      echo "container_status=missing"
      exit 1
    fi
    echo "target_user=$target_user"
    echo "container=$container"
    echo "log_tail=$lines"
    docker logs --tail "$lines" "$container" 2>&1 | redact_sensitive_output
    ;;

  runtime-secret-status)
    [[ $# -eq 1 ]] || { usage >&2; exit 2; }
    target_user="$1"
    validate_user "$target_user"
    runtime_secret_status "$target_user"
    ;;

  handoff-credential)
    [[ $# -eq 1 ]] || { usage >&2; exit 2; }
    target_user="$1"
    validate_user "$target_user"
    print_handoff_credential "$target_user"
    ;;

  hermes-model)
    [[ $# -eq 2 ]] || { usage >&2; exit 2; }
    target_user="$1"
    model="$2"
    set_hermes_model "$target_user" "$model"
    ;;

  hermes-model-all)
    [[ $# -eq 3 ]] || { usage >&2; exit 2; }
    start="$1"
    end="$2"
    model="$3"
    [[ "$start" =~ ^[0-9]+$ && "$end" =~ ^[0-9]+$ && "$start" -le "$end" ]] || {
      echo "error: invalid START/END" >&2
      exit 2
    }
    validate_gemini_model "$model"
    failed=0
    for i in $(seq "$start" "$end"); do
      target_user="oc$i"
      echo "== $target_user =="
      if id "$target_user" >/dev/null 2>&1; then
        set_hermes_model "$target_user" "$model" || failed=1
      else
        echo "FAIL user_missing"
        failed=1
      fi
    done
    exit "$failed"
    ;;

  hermes-guidance)
    [[ $# -eq 1 ]] || { usage >&2; exit 2; }
    target_user="$1"
    validate_user "$target_user"
    bash "$script_dir/internal/apply-hermes-workspace-guidance.bash" --user "$target_user"
    ;;

  hermes-guidance-all)
    [[ $# -eq 2 ]] || { usage >&2; exit 2; }
    start="$1"
    end="$2"
    [[ "$start" =~ ^[0-9]+$ && "$end" =~ ^[0-9]+$ && "$start" -le "$end" ]] || {
      echo "error: invalid START/END" >&2
      exit 2
    }
    failed=0
    for i in $(seq "$start" "$end"); do
      target_user="oc$i"
      echo "== $target_user =="
      if id "$target_user" >/dev/null 2>&1; then
        bash "$script_dir/internal/apply-hermes-workspace-guidance.bash" --user "$target_user" || failed=1
      else
        echo "FAIL user_missing"
        failed=1
      fi
    done
    exit "$failed"
    ;;

  image-status-all)
    [[ $# -eq 2 ]] || { usage >&2; exit 2; }
    start="$1"
    end="$2"
    [[ "$start" =~ ^[0-9]+$ && "$end" =~ ^[0-9]+$ && "$start" -le "$end" ]] || {
      echo "error: invalid START/END" >&2
      exit 2
    }
    python3 "$script_dir/openclaw-image-release-control.py" status-all "$start" "$end"
    ;;

  image-list)
    [[ $# -eq 0 ]] || { usage >&2; exit 2; }
    python3 "$script_dir/openclaw-image-release-control.py" list
    ;;

  image-release-add)
    [[ $# -ge 1 && $# -le 2 ]] || { usage >&2; exit 2; }
    if [[ $# -eq 2 ]]; then
      python3 "$script_dir/openclaw-image-release-control.py" add "$1" --name "$2"
    else
      python3 "$script_dir/openclaw-image-release-control.py" add "$1"
    fi
    ;;

  image-release-verify)
    [[ $# -eq 1 ]] || { usage >&2; exit 2; }
    python3 "$script_dir/openclaw-image-release-control.py" verify "$1"
    ;;

  image-release-promote)
    [[ $# -eq 2 ]] || { usage >&2; exit 2; }
    python3 "$script_dir/openclaw-image-release-control.py" promote "$1" "$2"
    ;;

  image-rollout)
    [[ $# -eq 1 ]] || { usage >&2; exit 2; }
    python3 "$script_dir/openclaw-image-release-control.py" rollout "$1"
    ;;

  image-rollout-range)
    [[ $# -eq 3 ]] || { usage >&2; exit 2; }
    start="$1"
    end="$2"
    [[ "$start" =~ ^[0-9]+$ && "$end" =~ ^[0-9]+$ && "$start" -le "$end" ]] || {
      echo "error: invalid START/END" >&2
      exit 2
    }
    python3 "$script_dir/openclaw-image-release-control.py" rollout-range "$start" "$end" "$3"
    ;;

  image-rollout-slot)
    [[ $# -eq 2 ]] || { usage >&2; exit 2; }
    target_user="$1"
    validate_customer_slot "$target_user"
    python3 "$script_dir/openclaw-image-release-control.py" rollout-slot "$target_user" "$2"
    ;;

  image-rollback)
    [[ $# -eq 1 ]] || { usage >&2; exit 2; }
    target_user="$1"
    validate_customer_slot "$target_user"
    python3 "$script_dir/openclaw-image-release-control.py" rollback "$target_user"
    ;;

  hermes-install)
    [[ $# -eq 2 ]] || { usage >&2; exit 2; }
    target_user="$1"
    validate_customer_slot "$target_user"
    bash "$script_dir/internal/install-hermes-slot-from-image.bash" \
      --user "$target_user" \
      --image "$2" \
      --force
    ;;

  dev-slot-install)
    [[ $# -ge 2 && $# -le 3 ]] || { usage >&2; exit 2; }
    dev_slot_install "$1" "$2" "${3:-}"
    ;;

  dev-slot-status)
    [[ $# -eq 1 ]] || { usage >&2; exit 2; }
    target_user="$1"
    validate_dev_slot "$target_user"
    echo "target_user=$target_user"
    echo "slot_kind=dev"
    echo "default_family=$(openclaw_slot_default_family "$target_user")"
    echo "target_home=$(customer_home "$target_user")"
    echo "gateway_port=$(openclaw_slot_default_gateway_port "$target_user")"
    echo "bridge_port=$(openclaw_slot_default_bridge_port "$target_user")"
    id "$target_user"
    source_mode_status "$target_user"
    ;;

  source-mode-enable)
    [[ $# -eq 1 ]] || { usage >&2; exit 2; }
    source_mode_enable "$1"
    ;;

  source-mode-disable)
    [[ $# -eq 1 ]] || { usage >&2; exit 2; }
    source_mode_disable "$1"
    ;;

  source-mode-status)
    [[ $# -eq 1 ]] || { usage >&2; exit 2; }
    source_mode_status "$1"
    ;;

  usage)
    [[ $# -ge 1 && $# -le 2 ]] || { usage >&2; exit 2; }
    target_user="$1"
    since_window="${2:-24h}"
    validate_user "$target_user"
    bash "$script_dir/internal/openclaw-usage-report.bash" \
      --user "$target_user" \
      --since "$since_window"
    ;;

  usage-all)
    [[ $# -ge 2 && $# -le 3 ]] || { usage >&2; exit 2; }
    start="$1"
    end="$2"
    since_window="${3:-24h}"
    [[ "$start" =~ ^[0-9]+$ && "$end" =~ ^[0-9]+$ && "$start" -le "$end" ]] || {
      echo "error: invalid START/END" >&2
      exit 2
    }
    bash "$script_dir/internal/openclaw-usage-report.bash" \
      --range "$start" "$end" \
      --since "$since_window"
    ;;

  shared-ollama-status)
    [[ $# -eq 0 ]] || { usage >&2; exit 2; }
    bash "$script_dir/internal/manage-shared-ollama.bash" status
    ;;

  shared-ollama-up)
    [[ $# -ge 1 && $# -le 2 ]] || { usage >&2; exit 2; }
    model="$1"
    image="${2:-ollama/ollama:0.17.7}"
    bash "$script_dir/internal/manage-shared-ollama.bash" up \
      --model "$model" \
      --image "$image"
    ;;

  shared-ollama-usage)
    [[ $# -le 2 ]] || { usage >&2; exit 2; }
    since_window="${1:-2h}"
    target_user="${2:-}"
    if [[ -n "$target_user" ]]; then
      validate_user "$target_user"
      bash "$script_dir/internal/manage-shared-ollama.bash" usage --since "$since_window" --user "$target_user"
    else
      bash "$script_dir/internal/manage-shared-ollama.bash" usage --since "$since_window"
    fi
    ;;

  shared-ollama-smoke)
    [[ $# -ge 1 && $# -le 2 ]] || { usage >&2; exit 2; }
    target_user="$1"
    model="${2:-}"
    validate_user "$target_user"
    if [[ -n "$model" ]]; then
      bash "$script_dir/internal/manage-shared-ollama.bash" smoke --user "$target_user" --model "$model"
    else
      bash "$script_dir/internal/manage-shared-ollama.bash" smoke --user "$target_user"
    fi
    ;;

  ollama-provider)
    [[ $# -ge 2 && $# -le 3 ]] || { usage >&2; exit 2; }
    target_user="$1"
    model="$2"
    base_url="${3:-$(shared_ollama_base_url)}"
    base_url="${base_url:-http://172.17.0.1:11434/v1}"
    validate_user "$target_user"
    bash "$script_dir/internal/apply-ollama-provider-config.bash" \
      --user "$target_user" \
      --model "$model" \
      --base-url "$base_url"
    ;;

  ollama-default)
    [[ $# -ge 2 && $# -le 3 ]] || { usage >&2; exit 2; }
    target_user="$1"
    model="$2"
    base_url="${3:-$(shared_ollama_base_url)}"
    base_url="${base_url:-http://172.17.0.1:11434/v1}"
    validate_user "$target_user"
    bash "$script_dir/internal/apply-ollama-provider-config.bash" \
      --user "$target_user" \
      --model "$model" \
      --base-url "$base_url" \
      --set-default
    ;;

  heartbeat-status)
    [[ $# -eq 1 ]] || { usage >&2; exit 2; }
    target_user="$1"
    validate_user "$target_user"
    bash "$script_dir/internal/openclaw-heartbeat-control.bash" status --user "$target_user"
    ;;

  heartbeat-status-all)
    [[ $# -eq 2 ]] || { usage >&2; exit 2; }
    start="$1"
    end="$2"
    [[ "$start" =~ ^[0-9]+$ && "$end" =~ ^[0-9]+$ && "$start" -le "$end" ]] || {
      echo "error: invalid START/END" >&2
      exit 2
    }
    bash "$script_dir/internal/openclaw-heartbeat-control.bash" status --range "$start" "$end"
    ;;

  heartbeat-disable)
    [[ $# -eq 1 ]] || { usage >&2; exit 2; }
    target_user="$1"
    validate_user "$target_user"
    bash "$script_dir/internal/openclaw-heartbeat-control.bash" disable --user "$target_user"
    refresh_gateway "$target_user"
    ;;

  heartbeat-disable-all)
    [[ $# -eq 2 ]] || { usage >&2; exit 2; }
    start="$1"
    end="$2"
    [[ "$start" =~ ^[0-9]+$ && "$end" =~ ^[0-9]+$ && "$start" -le "$end" ]] || {
      echo "error: invalid START/END" >&2
      exit 2
    }
    failed=0
    for i in $(seq "$start" "$end"); do
      target_user="oc$i"
      echo "== $target_user =="
      if id "$target_user" >/dev/null 2>&1; then
        bash "$script_dir/internal/openclaw-heartbeat-control.bash" disable --user "$target_user" || failed=1
        refresh_gateway "$target_user" || failed=1
      else
        echo "FAIL user_missing"
        failed=1
      fi
    done
    exit "$failed"
    ;;

  heartbeat-ollama)
    [[ $# -ge 2 && $# -le 3 ]] || { usage >&2; exit 2; }
    target_user="$1"
    model="$2"
    base_url="${3:-$(shared_ollama_base_url)}"
    base_url="${base_url:-http://172.17.0.1:11434/v1}"
    validate_user "$target_user"
    bash "$script_dir/internal/apply-ollama-heartbeat-config.bash" \
      --user "$target_user" \
      --model "$model" \
      --base-url "$base_url" \
      --every 30m
    ;;

  heartbeat-ollama-all)
    [[ $# -ge 3 && $# -le 4 ]] || { usage >&2; exit 2; }
    start="$1"
    end="$2"
    model="$3"
    base_url="${4:-$(shared_ollama_base_url)}"
    base_url="${base_url:-http://172.17.0.1:11434/v1}"
    [[ "$start" =~ ^[0-9]+$ && "$end" =~ ^[0-9]+$ && "$start" -le "$end" ]] || {
      echo "error: invalid START/END" >&2
      exit 2
    }
    failed=0
    for i in $(seq "$start" "$end"); do
      target_user="oc$i"
      echo "== $target_user =="
      if id "$target_user" >/dev/null 2>&1; then
        bash "$script_dir/internal/apply-ollama-heartbeat-config.bash" \
          --user "$target_user" \
          --model "$model" \
          --base-url "$base_url" \
          --every 30m || failed=1
      else
        echo "FAIL user_missing"
        failed=1
      fi
    done
    exit "$failed"
    ;;

  nas-fstab)
    [[ $# -eq 2 ]] || { usage >&2; exit 2; }
    target_user="$1"
    share="$2"
    validate_user "$target_user"
    validate_share "$share"
    bash "$script_dir/internal/write-user-nas-fstab-entry.bash" \
      --user "$target_user" \
      --share "$share"
    ;;

  subdomain)
    [[ $# -eq 2 ]] || { usage >&2; exit 2; }
    target_user="$1"
    host="$2"
    validate_user "$target_user"
    validate_host "$host"
    bash "$script_dir/internal/apply-subdomain-mode.bash" \
      --user "$target_user" \
      --host "$host"
    ;;

  isolation)
    [[ $# -eq 1 ]] || { usage >&2; exit 2; }
    target_user="$1"
    validate_user "$target_user"
    bash "$script_dir/internal/apply-customer-mode-isolation.bash" \
      --user "$target_user" \
      --no-remount \
      --check
    ;;

  *)
    echo "error: unknown command: ${command_name:-}" >&2
    usage >&2
    exit 2
    ;;
esac
