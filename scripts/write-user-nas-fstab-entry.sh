#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  write-user-nas-fstab-entry.sh --user USER [options]

Writes an /etc/fstab entry that lets USER mount only their own NAS mountpoint
without sudo. The NAS credential file remains owned by USER and is not created
or read by this script.

Options:
  --user USER              Target account, for example oc20. Required.
  --share SHARE            CIFS share path, for example //nas.example.com/share.
                            Required unless OPENCLAW_USER_NAS_SHARE is set.
  --mountpoint DIR         Mountpoint. Default: /home/USER/nas_docs.
  --credentials-path FILE  Credential file. Default: /home/USER/.nas-cifs.cred.
  --no-daemon-reload       Do not run systemctl daemon-reload after fstab update.

Run as root/admin.
USAGE
}

target_user=""
share="${OPENCLAW_USER_NAS_SHARE:-}"
mountpoint=""
credentials_path=""
daemon_reload=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user)
      target_user="${2:?missing --user value}"
      shift 2
      ;;
    --share)
      share="${2:?missing --share value}"
      shift 2
      ;;
    --mountpoint)
      mountpoint="${2:?missing --mountpoint value}"
      shift 2
      ;;
    --credentials-path)
      credentials_path="${2:?missing --credentials-path value}"
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

if [[ -z "$share" ]]; then
  echo "error: --share is required unless OPENCLAW_USER_NAS_SHARE is set" >&2
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

target_uid="$(id -u "$target_user")"
data_group="${target_user}_data"
if ! getent group "$data_group" >/dev/null; then
  groupadd "$data_group"
fi
target_gid="$(getent group "$data_group" | cut -d: -f3)"

mountpoint="${mountpoint:-$target_home/nas_docs}"
credentials_path="${credentials_path:-$target_home/.nas-cifs.cred}"

if [[ "$mountpoint" != "$target_home/"* && "$mountpoint" != "$target_home" ]]; then
  echo "error: mountpoint must stay under $target_home: $mountpoint" >&2
  exit 1
fi

if [[ "$credentials_path" != "$target_home/"* ]]; then
  echo "error: credentials-path must stay under $target_home: $credentials_path" >&2
  exit 1
fi

mount_cifs=""
for candidate in /usr/sbin/mount.cifs /sbin/mount.cifs; do
  if [[ -x "$candidate" ]]; then
    mount_cifs="$candidate"
    break
  fi
done

if [[ -z "$mount_cifs" ]]; then
  echo "error: mount.cifs not found" >&2
  exit 1
fi

if [[ ! -u "$mount_cifs" ]]; then
  echo "error: $mount_cifs is not setuid root; non-sudo CIFS user mount will not work" >&2
  exit 1
fi

mkdir -p "$mountpoint"
current_mount_target="$(findmnt -T "$mountpoint" -n -o TARGET 2>/dev/null | head -1 || true)"
if [[ "$current_mount_target" == "$mountpoint" ]]; then
  echo "warn: mountpoint is already mounted; skipping ownership fix: $mountpoint" >&2
  echo "warn: unmount it before changing mountpoint ownership" >&2
else
  chown "$target_user:$data_group" "$mountpoint" 2>/dev/null || chown "$target_user:$target_user" "$mountpoint"
  chmod 0550 "$mountpoint"
fi

backup="/etc/fstab.$(date +%Y%m%d%H%M%S).bak"
tmp="$(mktemp)"
cp /etc/fstab "$backup"

begin="# BEGIN managed openclaw user NAS mount $target_user"
end="# END managed openclaw user NAS mount $target_user"

awk -v begin="$begin" -v end="$end" -v mp="$mountpoint" '
  $0 == begin { skip = 1; next }
  $0 == end { skip = 0; next }
  skip { next }
  $0 !~ /^[[:space:]]*#/ && $2 == mp {
    print "# disabled by openclaw user NAS mount helper: " $0
    next
  }
  { print }
' /etc/fstab > "$tmp"

{
  printf '%s\n' "$begin"
  printf '%s %s cifs noauto,user,credentials=%s,uid=%s,gid=%s,forceuid,forcegid,ro,file_mode=0440,dir_mode=0550,iocharset=utf8,vers=3.1.1,nounix,noserverino,nosharesock,_netdev,nofail 0 0\n' \
    "$share" "$mountpoint" "$credentials_path" "$target_uid" "$target_gid"
  printf '%s\n' "$end"
} >> "$tmp"

install -o root -g root -m 0644 "$tmp" /etc/fstab
rm -f "$tmp"

if [[ "$daemon_reload" -eq 1 ]] && command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload || true
fi

echo "target_user=$target_user"
echo "target_home=$target_home"
echo "mountpoint=$mountpoint"
echo "credentials_path=$credentials_path"
echo "share=$share"
echo "mount_cifs=$mount_cifs"
echo "fstab_backup=$backup"
echo "fstab_user_mount=ok"
echo
echo "Next, run as $target_user and create $credentials_path, then:"
echo "  mount \"$mountpoint\""
