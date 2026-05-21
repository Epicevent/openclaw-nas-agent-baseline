#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  svcops-control.sh check USER HOST
  svcops-control.sh check-all START END BASE_DOMAIN
  svcops-control.sh nas-status USER
  svcops-control.sh nas-status-all START END
  svcops-control.sh nas-verify USER
  svcops-control.sh nas-verify-all START END
  svcops-control.sh nas-register USER SHARE
  svcops-control.sh nas-register-all START END SHARE
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

validate_share() {
  local share="$1"
  if [[ ! "$share" =~ ^//[^[:space:]/]+/[^[:space:]]+$ ]]; then
    echo "error: invalid CIFS share path: $share" >&2
    exit 2
  fi
}

customer_home() {
  getent passwd "$1" | cut -d: -f6
}

nas_mountpoint() {
  local target_home="$1"
  printf '%s/nas_docs' "$target_home"
}

print_nas_status() {
  local target_user="$1" target_home="$2" mountpoint entry source target fstype options creds_path current_target current_fstype current_source
  mountpoint="$(nas_mountpoint "$target_home")"
  echo "target_user=$target_user"
  echo "target_home=$target_home"
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

  if [[ -s "$target_home/.nas-cifs.cred" ]]; then
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
}

print_customer_nas_next_steps() {
  local target_user="$1"
  cat <<EOF
customer_next_steps:
  after logging in as $target_user:
  openclaw-nas-mount --status
  openclaw-nas-mount --reset-credential
EOF
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

  echo "action=gateway_refresh"
  (
    cd "$compose_dir"
    mapfile -t args < <(compose_files "$compose_dir")
    docker compose "${args[@]}" up -d --force-recreate openclaw-gateway
  )
  docker ps --filter "name=^/${container}$" --format 'container={{.Names}} status={{.Status}}'
}

verify_nas_visibility() {
  local target_user="$1" target_home mountpoint container host_source host_fstype container_source container_fstype sample_count failed=0
  target_home="$(customer_home "$target_user")"
  mountpoint="$(nas_mountpoint "$target_home")"
  container="$(gateway_container "$target_user")"

  echo "target_user=$target_user"
  host_source="$(findmnt -T "$mountpoint" -n -o SOURCE 2>/dev/null | head -1 || true)"
  host_fstype="$(findmnt -T "$mountpoint" -n -o FSTYPE 2>/dev/null | head -1 || true)"
  if [[ "$host_fstype" == "cifs" ]]; then
    echo "PASS host_nas_mounted_cifs"
    echo "INFO host_nas_source=$host_source"
  else
    echo "FAIL host_nas_mounted_cifs"
    echo "INFO host_nas_fstype=${host_fstype:-missing} source=${host_source:-missing}"
    failed=1
  fi

  if ! docker ps --format '{{.Names}}' | grep -qx "$container"; then
    echo "FAIL gateway_container_running"
    return 1
  fi

  container_source="$(docker exec "$container" findmnt -T /home/node/nas_docs -n -o SOURCE 2>/dev/null | head -1 || true)"
  container_fstype="$(docker exec "$container" findmnt -T /home/node/nas_docs -n -o FSTYPE 2>/dev/null | head -1 || true)"
  if [[ "$container_fstype" == "cifs" ]]; then
    echo "PASS container_nas_mounted_cifs"
    echo "INFO container_nas_source=$container_source"
  else
    echo "FAIL container_nas_mounted_cifs"
    echo "INFO container_nas_fstype=${container_fstype:-missing} source=${container_source:-missing}"
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
    bash "$script_dir/write-user-nas-fstab-entry.sh" \
      --user "$target_user" \
      --share "$share"
    target_home="$(customer_home "$target_user")"
    echo
    print_nas_status "$target_user" "$target_home"
    echo
    print_customer_nas_next_steps "$target_user"
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
          --share "$share" | sed -n '/^target_user=/p;/^mountpoint=/p;/^share=/p;/^fstab_user_mount=/p'; then
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
