#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/internal/lib-safe-compose.bash
source "$script_dir/lib-safe-compose.bash"

usage() {
  cat <<'USAGE'
Usage:
  svcops-control.sh nas-register USER //NAS_HOST/SHARE

Writes an /etc/fstab entry that lets USER mount only their own NAS mountpoint
without sudo. The NAS credential file remains owned by USER and is not created
or read by this script.

Options:
  --user USER              Target account, for example oc20. Required.
  --share SHARE            CIFS share path, for example //nas.example.com/share.
                            Required unless OPENCLAW_USER_NAS_SHARE is set.
  --no-daemon-reload       Do not run systemctl daemon-reload after fstab update.

Run as root/admin.
USAGE
}

target_user=""
share="${OPENCLAW_USER_NAS_SHARE:-}"
mount_name=""
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
    --mount-name)
      echo "error: --mount-name is not supported" >&2
      echo "hint: mountpoint and credential path are derived from --share //HOST/SHARE" >&2
      exit 2
      ;;
    --mountpoint|--credentials-path)
      echo "error: $1 is not supported" >&2
      echo "hint: mountpoint and credential path are derived from --share //HOST/SHARE" >&2
      exit 2
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

openclaw_assert_managed_slot_name "$target_user" || exit $?

openclaw_nas_validate_share "$share" || exit $?

if [[ -n "$mount_name" ]]; then
  openclaw_nas_validate_mount_name "$mount_name" || exit $?
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

if [[ -z "$mount_name" ]]; then
  mount_name="$(openclaw_nas_mount_name_from_share "$share")"
fi

mountpoint="$(openclaw_nas_mountpoint "$target_home" "$mount_name")"
credentials_path="$(openclaw_nas_credentials_path "$target_home" "$mount_name")"

assert_no_symlink_chain() {
  local path="$1" current="" part
  local -a parts
  [[ "$path" == /* ]] || return 0
  IFS='/' read -r -a parts <<<"$path"
  for part in "${parts[@]}"; do
    [[ -n "$part" ]] || continue
    current="$current/$part"
    if [[ -L "$current" ]]; then
      echo "error: refusing symlink in managed NAS path: $current" >&2
      exit 1
    fi
  done
}

fix_managed_mount_dirs() {
  local root="$1" leaf="$2" current rel part
  local -a parts
  chown "$target_user:$data_group" "$root" 2>/dev/null || true
  chmod 0550 "$root" 2>/dev/null || true
  rel="${leaf#$root/}"
  current="$root"
  IFS='/' read -r -a parts <<<"$rel"
  for part in "${parts[@]}"; do
    [[ -n "$part" ]] || continue
    current="$current/$part"
    if [[ "$(openclaw_findmnt_exact_field "$current" TARGET)" == "$current" ]]; then
      continue
    fi
    chown "$target_user:$data_group" "$current" 2>/dev/null || true
    chmod 0550 "$current" 2>/dev/null || true
  done
}

for path in "$target_home" "$target_home/nas_docs" "$target_home/.openclaw-nas" "$target_home/.openclaw-nas/credentials" "$mountpoint" "$credentials_path"; do
  if [[ -L "$path" ]]; then
    echo "error: refusing symlink in managed NAS path: $path" >&2
    exit 1
  fi
done
assert_no_symlink_chain "$mountpoint"
assert_no_symlink_chain "$credentials_path"

case "$mountpoint" in
  "$target_home/nas_docs/"*) ;;
  *)
    echo "error: internal mountpoint escaped managed root: $mountpoint" >&2
    exit 1
    ;;
esac

case "$credentials_path" in
  "$target_home/.openclaw-nas/credentials/"*.cred) ;;
  *)
    echo "error: internal credential path escaped managed root: $credentials_path" >&2
    exit 1
    ;;
esac

if [[ "$mountpoint" == *"/../"* || "$mountpoint" == */.. || "$credentials_path" == *"/../"* || "$credentials_path" == */.. ]]; then
  echo "error: refusing parent traversal in managed NAS path" >&2
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

credentials_dir="$(dirname "$credentials_path")"
credentials_root="$(dirname "$credentials_dir")"
mkdir -p "$mountpoint" "$credentials_dir"
for path in "$target_home" "$target_home/nas_docs" "$target_home/.openclaw-nas" "$target_home/.openclaw-nas/credentials" "$mountpoint" "$credentials_path"; do
  if [[ -L "$path" ]]; then
    echo "error: refusing symlink in managed NAS path after mkdir: $path" >&2
    exit 1
  fi
done
assert_no_symlink_chain "$mountpoint"
assert_no_symlink_chain "$credentials_path"
fix_managed_mount_dirs "$target_home/nas_docs" "$mountpoint"
current_mount_target="$(openclaw_findmnt_exact_field "$mountpoint" TARGET)"
if [[ "$current_mount_target" == "$mountpoint" ]]; then
  echo "warn: mountpoint is already mounted; skipping ownership fix: $mountpoint" >&2
  echo "warn: unmount it before changing mountpoint ownership" >&2
else
  chown "$target_user:$data_group" "$mountpoint" 2>/dev/null || chown "$target_user:$target_user" "$mountpoint"
  if [[ "$credentials_path" == "$target_home/.openclaw-nas/credentials/"* ]]; then
    chown "$target_user:$target_user" "$credentials_root" "$credentials_dir" 2>/dev/null || true
    chmod 0700 "$credentials_root" "$credentials_dir" 2>/dev/null || true
  else
    chown "$target_user:$target_user" "$credentials_dir" 2>/dev/null || true
  fi
  chmod 0550 "$mountpoint"
fi

backup="/etc/fstab.$(date +%Y%m%d%H%M%S).bak"
tmp="$(mktemp)"
cp /etc/fstab "$backup"

existing_mount_source="$(
  awk -v mp="$mountpoint" '
    $0 !~ /^[[:space:]]*#/ && $2 == mp && $3 == "cifs" { print $1; exit }
  ' /etc/fstab 2>/dev/null || true
)"
if [[ -n "$existing_mount_source" && "$existing_mount_source" != "$share" ]]; then
  echo "error: mountpoint already belongs to a different NAS share" >&2
  echo "existing_share=$existing_mount_source" >&2
  echo "requested_share=$share" >&2
  echo "mountpoint=$mountpoint" >&2
  exit 1
fi

if [[ -n "$mount_name" ]]; then
  begin="# BEGIN managed openclaw user NAS mount $target_user $mount_name"
  end="# END managed openclaw user NAS mount $target_user $mount_name"
else
  begin="# BEGIN managed openclaw user NAS mount $target_user"
  end="# END managed openclaw user NAS mount $target_user"
fi

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
echo "derived_mount_name=${mount_name:-primary}"
echo "mountpoint=$mountpoint"
echo "credentials_path=$credentials_path"
echo "nas_share=$share"
echo "mount_cifs=$mount_cifs"
echo "fstab_backup=$backup"
echo "fstab_user_mount=ok"
echo
echo "Next, run as $target_user:"
echo "  agent-nas-mount --share \"$share\" --reset-credential"
