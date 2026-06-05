#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  svcops-control.sh nas-unregister USER [MOUNT_NAME] [--unmount] [--delete-credential] [--delete-empty-dir]

Removes managed /etc/fstab CIFS user-mount rules for USER.

Options:
  --user USER             Target account, for example oc20. Required.
  --mount-name NAME       Remove only /home/USER/nas_docs/NAME.
                          NAME may contain a managed host-hash/share path.
  --mountpoint DIR        Remove only this mountpoint. Default: all under
                          /home/USER/nas_docs.
  --unmount               Unmount matching active CIFS mounts.
  --delete-credential     Delete matching NAS credential files.
  --delete-empty-dir      Remove matching empty mount directories after unmount.
  --no-daemon-reload      Do not run systemctl daemon-reload after fstab update.

Run as root/admin.
USAGE
}

target_user=""
mount_name=""
mountpoint=""
daemon_reload=1
do_unmount=0
delete_credential=0
delete_empty_dir=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user)
      target_user="${2:?missing --user value}"
      shift 2
      ;;
    --mount-name)
      mount_name="${2:?missing --mount-name value}"
      shift 2
      ;;
    --mountpoint)
      mountpoint="${2:?missing --mountpoint value}"
      shift 2
      ;;
    --unmount)
      do_unmount=1
      shift
      ;;
    --delete-credential)
      delete_credential=1
      shift
      ;;
    --delete-empty-dir)
      delete_empty_dir=1
      shift
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

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/internal/lib-safe-compose.bash
source "$script_dir/lib-safe-compose.bash"
openclaw_assert_managed_slot_name "$target_user" || exit $?

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

nas_root="$target_home/nas_docs"
credential_root="$target_home/.openclaw-nas/credentials"
remove_all=0
if [[ -z "$mountpoint" ]]; then
  if [[ -n "$mount_name" ]]; then
    mountpoint="$(openclaw_nas_mountpoint "$target_home" "$mount_name")"
  else
    mountpoint="$nas_root"
    remove_all=1
  fi
fi

case "$mountpoint" in
  "$target_home"|"$target_home"/*) ;;
  *)
    echo "error: mountpoint must stay under $target_home: $mountpoint" >&2
    exit 1
    ;;
esac

if [[ "$mountpoint" == *"/.."* || "$mountpoint" == *"/."*"/"* ]]; then
  echo "error: mountpoint must not contain dot path components: $mountpoint" >&2
  exit 1
fi

source_share="$(
  awk -v mp="$mountpoint" -v root="$mountpoint/" -v remove_all="$remove_all" '
    $0 !~ /^[[:space:]]*#/ && $3 == "cifs" {
      if ((!remove_all && $2 == mp) || (remove_all && ($2 == mp || index($2, root) == 1))) {
        print $1
        exit
      }
    }
  ' /etc/fstab 2>/dev/null || true
)"

backup="/etc/fstab.$(date +%Y%m%d%H%M%S).bak"
tmp="$(mktemp)"
cp /etc/fstab "$backup"

if [[ "$remove_all" -eq 1 ]]; then
  begin="# BEGIN managed openclaw user NAS mount $target_user"
  end="# END managed openclaw user NAS mount $target_user"
elif [[ -n "$mount_name" ]]; then
  begin="# BEGIN managed openclaw user NAS mount $target_user $mount_name"
  end="# END managed openclaw user NAS mount $target_user $mount_name"
else
  begin="# BEGIN managed openclaw user NAS mount $target_user"
  end="# END managed openclaw user NAS mount $target_user"
fi

rc=0
awk -v begin="$begin" -v end="$end" -v mp="$mountpoint" -v remove_all="$remove_all" '
  remove_all && ($0 == begin || index($0, begin " ") == 1) {
    removed = 1
    skip = 1
    next
  }
  !remove_all && $0 == begin { removed = 1; skip = 1; next }
  skip && ($0 == end || index($0, end " ") == 1) { skip = 0; next }
  skip { next }
  $0 !~ /^[[:space:]]*#/ && $3 == "cifs" && ((remove_all && ($2 == mp || index($2, mp "/") == 1)) || (!remove_all && $2 == mp)) {
    removed = 1
    print "# disabled by openclaw user NAS unregister: " $0
    next
  }
  { print }
  END { exit removed ? 0 : 3 }
' /etc/fstab > "$tmp" || rc=$?

if [[ "$rc" -eq 3 ]]; then
  rm -f "$tmp"
  fstab_state="already_absent"
elif [[ "$rc" -ne 0 ]]; then
  rm -f "$tmp"
  echo "error: failed to rewrite /etc/fstab" >&2
  exit "$rc"
else
  install -o root -g root -m 0644 "$tmp" /etc/fstab
  rm -f "$tmp"
  fstab_state="removed"
fi

if [[ "$daemon_reload" -eq 1 ]] && command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload || true
fi

exact_mount_state() {
  local path="$1" target fstype
  target="$(findmnt -n -M "$path" -o TARGET 2>/dev/null | head -1 || true)"
  fstype="$(findmnt -n -M "$path" -o FSTYPE 2>/dev/null | head -1 || true)"
  if [[ "$target" == "$path" && "$fstype" == "cifs" ]]; then
    printf 'mounted_cifs'
  elif [[ "$target" == "$path" ]]; then
    printf 'mounted_non_cifs'
  else
    printf 'not_mounted'
  fi
}

unmount_result="skipped"
if [[ "$do_unmount" -eq 1 ]]; then
  unmount_result="not_mounted"
  mapfile -t unmount_targets < <(
    if [[ "$remove_all" -eq 1 ]]; then
      findmnt -R "$mountpoint" -n -t cifs -o TARGET 2>/dev/null | sort -r || true
    else
      if [[ "$(exact_mount_state "$mountpoint")" == "mounted_cifs" ]]; then
        printf '%s\n' "$mountpoint"
      fi
    fi
  )
  if [[ "${#unmount_targets[@]}" -gt 0 ]]; then
    unmount_result="ok"
    for active_target in "${unmount_targets[@]}"; do
      case "$active_target" in
        "$nas_root"|"$nas_root"/*) ;;
        *)
          echo "error: refusing to unmount outside $nas_root: $active_target" >&2
          exit 1
          ;;
      esac
      if ! umount "$active_target"; then
        unmount_result="failed"
      fi
    done
    [[ "$unmount_result" != "failed" ]] || exit 1
  fi
fi

credential_result="skipped"
if [[ "$delete_credential" -eq 1 ]]; then
  credential_result="missing"
  if [[ "$remove_all" -eq 1 ]]; then
    if [[ -d "$credential_root" && ! -L "$credential_root" ]]; then
      credential_count=0
      while IFS= read -r -d '' cred_file; do
        case "$cred_file" in
          "$credential_root"/*) ;;
          *) echo "error: refusing credential path: $cred_file" >&2; exit 1 ;;
        esac
        rel_cred="${cred_file#$credential_root/}"
        if [[ "$rel_cred" == *"/.."* || "$rel_cred" == *"/."*"/"* ]]; then
          echo "error: refusing credential path with dot components: $cred_file" >&2
          exit 1
        fi
        [[ ! -L "$cred_file" ]] || { echo "error: refusing symlink credential: $cred_file" >&2; exit 1; }
        rm -f "$cred_file"
        credential_count=$((credential_count + 1))
      done < <(find "$credential_root" -type f -name '*.cred' -print0 2>/dev/null || true)
      while IFS= read -r -d '' empty_cred_dir; do
        case "$empty_cred_dir" in
          "$credential_root") ;;
          "$credential_root"/*) rmdir "$empty_cred_dir" 2>/dev/null || true ;;
        esac
      done < <(find "$credential_root" -mindepth 1 -depth -type d -empty -print0 2>/dev/null || true)
      credential_result="removed_count_$credential_count"
    fi
  else
    if [[ -z "$mount_name" ]]; then
      credential_result="requires_mount_name"
    else
      credential_path="$(openclaw_nas_credentials_path "$target_home" "$mount_name")"
      if [[ -e "$credential_path" || -L "$credential_path" ]]; then
        [[ ! -L "$credential_path" ]] || { echo "error: refusing symlink credential: $credential_path" >&2; exit 1; }
        rm -f "$credential_path"
        cred_parent="$(dirname "$credential_path")"
        while [[ "$cred_parent" == "$credential_root/"* && "$cred_parent" != "$credential_root" ]]; do
          rmdir "$cred_parent" 2>/dev/null || break
          cred_parent="$(dirname "$cred_parent")"
        done
        credential_result="removed"
      fi
    fi
  fi
fi

empty_dir_result="skipped"
if [[ "$delete_empty_dir" -eq 1 ]]; then
  empty_dir_result="missing"
  if [[ "$remove_all" -eq 1 ]]; then
    empty_count=0
    if [[ -d "$nas_root" && ! -L "$nas_root" ]]; then
      while IFS= read -r -d '' child_dir; do
        case "$child_dir" in
          "$nas_root"/*) ;;
          *) echo "error: refusing mount directory path: $child_dir" >&2; exit 1 ;;
        esac
        if [[ "$(exact_mount_state "$child_dir")" != "not_mounted" ]]; then
          continue
        fi
        if rmdir "$child_dir" 2>/dev/null; then
          empty_count=$((empty_count + 1))
        fi
      done < <(find "$nas_root" -xdev -mindepth 1 -depth -type d -empty -print0 2>/dev/null || true)
      empty_dir_result="removed_count_$empty_count"
    fi
  else
    if [[ -d "$mountpoint" && ! -L "$mountpoint" ]]; then
      if [[ "$(exact_mount_state "$mountpoint")" == "not_mounted" ]] && rmdir "$mountpoint" 2>/dev/null; then
        mount_parent="$(dirname "$mountpoint")"
        while [[ "$mount_parent" == "$nas_root/"* && "$mount_parent" != "$nas_root" ]]; do
          rmdir "$mount_parent" 2>/dev/null || break
          mount_parent="$(dirname "$mount_parent")"
        done
        empty_dir_result="removed"
      else
        empty_dir_result="kept_non_empty_or_mounted"
      fi
    fi
  fi
fi

echo "target_user=$target_user"
echo "target_home=$target_home"
echo "mount_name=${mount_name:-all}"
echo "mountpoint=$mountpoint"
[[ -n "$source_share" ]] && echo "source_share=$source_share"
echo "fstab_backup=$backup"
echo "fstab_user_mount=$fstab_state"
echo "active_mount=$(exact_mount_state "$mountpoint")"
echo "unmount=$unmount_result"
echo "credential_file=$credential_result"
echo "empty_dir=$empty_dir_result"
