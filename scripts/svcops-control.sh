#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  svcops-control.sh check USER HOST
  svcops-control.sh check-all START END BASE_DOMAIN
  svcops-control.sh nas-status USER
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
  local target_user="$1" target_home="$2" mountpoint entry source target fstype options creds_path current_target current_fstype
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
  current_fstype="$(findmnt -T "$mountpoint" -n -o FSTYPE 2>/dev/null | head -1 || true)"
  if [[ "$current_target" == "$mountpoint" ]]; then
    echo "mount=present"
    echo "mount_fstype=$current_fstype"
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

  nas-prepare)
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
