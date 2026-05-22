#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  svcops-control.sh check USER HOST
  svcops-control.sh check-all START END BASE_DOMAIN
  svcops-control.sh nas-status USER
  svcops-control.sh nas-status-all START END
  svcops-control.sh nas-requests START END
  svcops-control.sh nas-approve-share USER
  svcops-control.sh nas-verify USER
  svcops-control.sh nas-verify-all START END
  svcops-control.sh nas-register USER SHARE
  svcops-control.sh nas-register-all START END SHARE
  svcops-control.sh nas-unregister USER
  svcops-control.sh nas-unregister-all START END
  svcops-control.sh gateway-refresh USER
  svcops-control.sh nas-prepare USER SHARE
  svcops-control.sh nas-fstab USER SHARE
  svcops-control.sh subdomain USER HOST
  svcops-control.sh isolation USER

Restricted root wrapper for the svcops operating account.

This wrapper does not print NAS credentials, OpenClaw tokens, or API keys.
Run through sudoers, not directly by customer accounts.
USAGE
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-safe-compose.sh
source "$script_dir/lib-safe-compose.sh"

validate_user() {
  local user="$1"
  if [[ ! "$user" =~ ^oc[1-9][0-9]*$ ]]; then
    echo "error: invalid customer user: $user" >&2
    exit 2
  fi
  if ! id "$user" >/dev/null 2>&1; then
    echo "error: user not found: $user" >&2
    exit 1
  fi
}

validate_host() {
  local host="$1"
  if [[ ! "$host" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$ ]]; then
    echo "error: invalid host: $host" >&2
    exit 2
  fi
}

cifs_share_is_valid() {
  local share="$1"
  [[ "$share" =~ ^//[^[:space:]/,]+/[^[:space:]/,]+$ ]]
}

validate_share() {
  local share="$1"
  if ! cifs_share_is_valid "$share"; then
    echo "error: invalid CIFS share path: $share" >&2
    exit 2
  fi
}

validate_mount_name() {
  local name="$1"
  if [[ "$name" == "." || "$name" == ".." || ! "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]; then
    echo "error: invalid mount name: $name" >&2
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

customer_home() {
  getent passwd "$1" | cut -d: -f6
}

nas_mountpoint() {
  local target_home="$1"
  printf '%s/nas_docs' "$target_home"
}

named_nas_mountpoint() {
  local target_home="$1" mount_name="$2"
  printf '%s/nas_docs/%s' "$target_home" "$mount_name"
}

nas_credentials_path() {
  local target_home="$1"
  printf '%s/.nas-cifs.cred' "$target_home"
}

named_nas_credentials_path() {
  local target_home="$1" mount_name="$2"
  printf '%s/.openclaw-nas/credentials/%s.cred' "$target_home" "$mount_name"
}

registered_nas_mountpoints() {
  local root="$1"
  awk -v root="$root" '
    $0 !~ /^[[:space:]]*#/ && $3 == "cifs" && ($2 == root || index($2, root "/") == 1) {
      print $2
    }
  ' /etc/fstab 2>/dev/null
}

container_path_for_nas_mountpoint() {
  local root="$1" mountpoint="$2" suffix
  if [[ "$mountpoint" == "$root" ]]; then
    printf '%s' "/home/node/nas_docs"
  else
    suffix="${mountpoint#$root/}"
    printf '/home/node/nas_docs/%s' "$suffix"
  fi
}

print_nas_status() {
  local target_user="$1" target_home="$2" mountpoint="${3:-}" credentials_path="${4:-}" mount_name="${5:-primary}"
  local entry source target fstype options creds_path current_target current_fstype current_source
  mountpoint="${mountpoint:-$(nas_mountpoint "$target_home")}"
  credentials_path="${credentials_path:-$(nas_credentials_path "$target_home")}"
  echo "target_user=$target_user"
  echo "target_home=$target_home"
  echo "mount_name=$mount_name"
  echo "mountpoint=$mountpoint"

  entry="$(awk -v mp="$mountpoint" '
    $0 !~ /^[[:space:]]*#/ && $2 == mp && $3 == "cifs" { print; exit }
  ' /etc/fstab 2>/dev/null || true)"
  if [[ -n "$entry" ]]; then
    read -r source target fstype options _ <<<"$entry"
    echo "fstab_rule=present"
    echo "fstab_source=$source"
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

  current_target="$(findmnt -T "$mountpoint" -n -o TARGET 2>/dev/null | head -1 || true)"
  current_source="$(findmnt -T "$mountpoint" -n -o SOURCE 2>/dev/null | head -1 || true)"
  current_fstype="$(findmnt -T "$mountpoint" -n -o FSTYPE 2>/dev/null | head -1 || true)"
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
    findmnt -T "$mountpoint" -o TARGET,SOURCE,FSTYPE,OPTIONS || true
  else
    echo "mount=missing"
  fi

  if [[ "$mountpoint" == "$(nas_mountpoint "$target_home")" ]]; then
    awk -v root="$mountpoint/" '
      $0 !~ /^[[:space:]]*#/ && $2 ~ "^" root && $3 == "cifs" {
        count += 1
        printf "registered_child_mount_%d=%s\n", count, $2
        printf "registered_child_share_%d=%s\n", count, $1
      }
      END {
        if (!count) {
          print "registered_child_mounts=none"
        }
      }
    ' /etc/fstab 2>/dev/null || true
  fi
}

print_customer_nas_next_steps() {
  local target_user="$1" mount_name="${2:-}"
  if [[ -n "$mount_name" ]]; then
    cat <<EOF
customer_next_steps:
  after logging in as $target_user:
  openclaw-nas-mount --mount-name $mount_name --status
  openclaw-nas-mount --mount-name $mount_name --reset-credential
EOF
  else
    cat <<EOF
customer_next_steps:
  after logging in as $target_user:
  openclaw-nas-mount --status
  openclaw-nas-mount --reset-credential
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
  mount_name="$(request_value MOUNT_NAME "$request_file")"
  [[ "$mount_name" == "primary" || -z "$mount_name" ]] && mount_name="$(mount_name_from_share "$requested_share")"
  validate_mount_name "$mount_name"
  echo "share_request=present"
  echo "requested_by=${requested_by:-unknown}"
  echo "requested_at=${requested_at:-unknown}"
  echo "mount_name=$mount_name"
  echo "derived_mountpoint=$(named_nas_mountpoint "$target_home" "$mount_name")"
  echo "derived_credentials_file=$(named_nas_credentials_path "$target_home" "$mount_name")"
  if [[ -n "$requested_mountpoint" || -n "$requested_credentials" ]]; then
    echo "request_path_fields=ignored; paths are derived from mount_name"
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
  mount_name="$(request_value MOUNT_NAME "$request_file")"
  [[ "$mount_name" == "primary" || -z "$mount_name" ]] && mount_name="$(mount_name_from_share "$requested_share")"
  validate_mount_name "$mount_name"
  requested_mountpoint="$(named_nas_mountpoint "$target_home" "$mount_name")"
  requested_credentials="$(named_nas_credentials_path "$target_home" "$mount_name")"

  echo "approving_share_request_for=$target_user"
  echo "mount_name=$mount_name"
  echo "mountpoint=$requested_mountpoint"
  echo "credentials_path=$requested_credentials"
  echo "requested_share=$requested_share"
  helper_args=(--user "$target_user" --share "$requested_share" --mount-name "$mount_name")
  bash "$script_dir/write-user-nas-fstab-entry.sh" \
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
  print_customer_nas_next_steps "$target_user" "$mount_name"
}

gateway_container() {
  local target_user="$1"
  printf 'openclaw-%s-openclaw-gateway-1' "$target_user"
}

compose_files() {
  local compose_dir="$1"
  printf '%s\n' -f docker-compose.yml
  [[ -f "$compose_dir/docker-compose.extra.yml" ]] && printf '%s\n' -f docker-compose.extra.yml
  [[ -f "$compose_dir/docker-compose.host-user.yml" ]] && printf '%s\n' -f docker-compose.host-user.yml
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
  local host_source host_fstype host_target container_source container_fstype container_target container_mp nas_mp share_name
  local host_failed=0 container_failed=0
  local -a visible_nas_mountpoints=()
  target_home="$(customer_home "$target_user")"
  mountpoint="$(nas_mountpoint "$target_home")"
  container="$(gateway_container "$target_user")"

  echo "target_user=$target_user"
  echo "== NAS visibility map =="
  echo "+ account: $target_user"
  echo "+ host root:      $mountpoint"
  echo "+ container root: /home/node/nas_docs"
  echo "+ rule:           host_root/SHARE_NAME -> container_root/SHARE_NAME"
  mapfile -t nas_mountpoints < <(registered_nas_mountpoints "$mountpoint")
  if [[ "${#nas_mountpoints[@]}" -eq 0 ]]; then
    echo "+ mounted shares: none"
    echo "FAIL host_nas_mounted_cifs"
    echo "INFO host_nas_registered_mounts=none"
    failed=1
  else
    echo "INFO host_nas_registered_mount_count=${#nas_mountpoints[@]}"
    for nas_mp in "${nas_mountpoints[@]}"; do
      host_source="$(findmnt -T "$nas_mp" -n -o SOURCE 2>/dev/null | head -1 || true)"
      host_target="$(findmnt -T "$nas_mp" -n -o TARGET 2>/dev/null | head -1 || true)"
      host_fstype="$(findmnt -T "$nas_mp" -n -o FSTYPE 2>/dev/null | head -1 || true)"
      if [[ "$host_target" == "$nas_mp" && "$host_fstype" == "cifs" ]]; then
        echo "INFO host_nas_mount=$nas_mp source=$host_source"
        share_name="${nas_mp#$mountpoint/}"
        echo "+ share:          ${share_name:-primary}"
        echo "| source:         $host_source"
        echo "| host path:      $nas_mp"
        echo "| host state:     mounted cifs"
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
  fi

  if ! docker ps --format '{{.Names}}' | grep -qx "$container"; then
    echo "FAIL gateway_container_running"
    return 1
  fi

  if [[ "${#visible_nas_mountpoints[@]}" -eq 0 ]]; then
    container_failed=1
    echo "INFO container_nas_visible_mounts=none"
  else
    for nas_mp in "${visible_nas_mountpoints[@]}"; do
      container_mp="$(container_path_for_nas_mountpoint "$mountpoint" "$nas_mp")"
      container_source="$(docker exec "$container" findmnt -T "$container_mp" -n -o SOURCE 2>/dev/null | head -1 || true)"
      container_target="$(docker exec "$container" findmnt -T "$container_mp" -n -o TARGET 2>/dev/null | head -1 || true)"
      container_fstype="$(docker exec "$container" findmnt -T "$container_mp" -n -o FSTYPE 2>/dev/null | head -1 || true)"
      if [[ "$container_target" == "$container_mp" && "$container_fstype" == "cifs" ]]; then
        echo "INFO container_nas_mount=$container_mp source=$container_source"
        echo "| container path: $container_mp"
        echo "| container state: mounted cifs"
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

  sample_count="$(docker exec "$container" sh -lc 'find /home/node/nas_docs -maxdepth 1 -mindepth 1 2>/dev/null | head -3 | wc -l' 2>/dev/null || true)"
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
    bash "$script_dir/check-customer-deployment.sh" \
      --user "$target_user" \
      --expected-basepath / \
      --expected-origin "https://$host"
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
        if ! bash "$script_dir/check-customer-deployment.sh" \
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

  nas-approve-share)
    [[ $# -eq 1 ]] || { usage >&2; exit 2; }
    target_user="$1"
    validate_user "$target_user"
    approve_share_request "$target_user"
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

  nas-register|nas-prepare)
    [[ $# -eq 2 ]] || { usage >&2; exit 2; }
    target_user="$1"
    share="$2"
    validate_user "$target_user"
    validate_share "$share"
    mount_name="$(mount_name_from_share "$share")"
    bash "$script_dir/write-user-nas-fstab-entry.sh" \
      --user "$target_user" \
      --share "$share"
    target_home="$(customer_home "$target_user")"
    echo
    print_nas_status "$target_user" "$target_home" \
      "$(named_nas_mountpoint "$target_home" "$mount_name")" \
      "$(named_nas_credentials_path "$target_home" "$mount_name")" \
      "$mount_name"
    echo
    print_customer_nas_next_steps "$target_user" "$mount_name"
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
        if ! bash "$script_dir/write-user-nas-fstab-entry.sh" \
          --user "$target_user" \
          --share "$share" | sed -n '/^target_user=/p;/^mount_name=/p;/^mountpoint=/p;/^share=/p;/^fstab_user_mount=/p'; then
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
    [[ $# -eq 1 ]] || { usage >&2; exit 2; }
    target_user="$1"
    validate_user "$target_user"
    bash "$script_dir/remove-user-nas-fstab-entry.sh" \
      --user "$target_user"
    ;;

  nas-unregister-all)
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
        if ! bash "$script_dir/remove-user-nas-fstab-entry.sh" \
          --user "$target_user" | sed -n '/^target_user=/p;/^mountpoint=/p;/^fstab_user_mount=/p;/^note=/p'; then
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

  nas-fstab)
    [[ $# -eq 2 ]] || { usage >&2; exit 2; }
    target_user="$1"
    share="$2"
    validate_user "$target_user"
    validate_share "$share"
    bash "$script_dir/write-user-nas-fstab-entry.sh" \
      --user "$target_user" \
      --share "$share"
    ;;

  subdomain)
    [[ $# -eq 2 ]] || { usage >&2; exit 2; }
    target_user="$1"
    host="$2"
    validate_user "$target_user"
    validate_host "$host"
    bash "$script_dir/apply-subdomain-mode.sh" \
      --user "$target_user" \
      --host "$host"
    ;;

  isolation)
    [[ $# -eq 1 ]] || { usage >&2; exit 2; }
    target_user="$1"
    validate_user "$target_user"
    bash "$script_dir/apply-customer-mode-isolation.sh" \
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
