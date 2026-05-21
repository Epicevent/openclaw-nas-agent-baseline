#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  remove-user-nas-fstab-entry.sh --user USER [options]

Removes the managed /etc/fstab CIFS user-mount rule for USER. It does not
unmount an existing mount and does not delete the user's NAS credential file.

Options:
  --user USER         Target account, for example oc20. Required.
  --mountpoint DIR    Mountpoint. Default: /home/USER/nas_docs.
  --no-daemon-reload  Do not run systemctl daemon-reload after fstab update.

Run as root/admin.
USAGE
}

target_user=""
mountpoint=""
daemon_reload=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user)
      target_user="${2:?missing --user value}"
      shift 2
      ;;
    --mountpoint)
      mountpoint="${2:?missing --mountpoint value}"
      shift 2
      ;;
    --no-daemon-reload)
      daemon_reload=0
      shift
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

if [[ -z "$target_user" ]]; then
  echo "error: --user is required" >&2
  usage >&2
  exit 2
fi

if [[ ! "$target_user" =~ ^oc[1-9][0-9]*$ ]]; then
  echo "error: invalid user name: $target_user" >&2
  exit 2
fi

if [[ "$(id -u)" -ne 0 ]]; then
  echo "error: run with sudo/root" >&2
  exit 1
fi

target_home="$(getent passwd "$target_user" | cut -d: -f6)"
if [[ -z "$target_home" ]]; then
  echo "error: user not found: $target_user" >&2
  exit 1
fi

mountpoint="${mountpoint:-$target_home/nas_docs}"
if [[ "$mountpoint" != "$target_home/"* && "$mountpoint" != "$target_home" ]]; then
  echo "error: mountpoint must stay under $target_home: $mountpoint" >&2
  exit 1
fi

backup="/etc/fstab.$(date +%Y%m%d%H%M%S).bak"
tmp="$(mktemp)"
cp /etc/fstab "$backup"

begin="# BEGIN managed openclaw user NAS mount $target_user"
end="# END managed openclaw user NAS mount $target_user"

awk -v begin="$begin" -v end="$end" -v mp="$mountpoint" '
  $0 == begin { removed = 1; skip = 1; next }
  $0 == end { skip = 0; next }
  skip { next }
  $0 !~ /^[[:space:]]*#/ && $2 == mp && $3 == "cifs" {
    removed = 1
    print "# disabled by openclaw user NAS unregister: " $0
    next
  }
  { print }
  END {
    if (removed) {
      exit 0
    }
    exit 3
  }
' /etc/fstab > "$tmp" || rc=$?

rc="${rc:-0}"
if [[ "$rc" -eq 3 ]]; then
  rm -f "$tmp"
  echo "target_user=$target_user"
  echo "target_home=$target_home"
  echo "mountpoint=$mountpoint"
  echo "fstab_backup=$backup"
  echo "fstab_user_mount=already_absent"
  exit 0
elif [[ "$rc" -ne 0 ]]; then
  rm -f "$tmp"
  echo "error: failed to rewrite /etc/fstab" >&2
  exit "$rc"
fi

install -o root -g root -m 0644 "$tmp" /etc/fstab
rm -f "$tmp"

if [[ "$daemon_reload" -eq 1 ]] && command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload || true
fi

echo "target_user=$target_user"
echo "target_home=$target_home"
echo "mountpoint=$mountpoint"
echo "fstab_backup=$backup"
echo "fstab_user_mount=removed"
echo "note=existing_mount_is_not_unmounted"
