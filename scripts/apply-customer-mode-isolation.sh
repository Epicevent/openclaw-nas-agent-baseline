#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  apply-customer-mode-isolation.sh --user USER [options]

Converts an already bootstrapped OpenClaw account into customer mode:

  - USER keeps read access to /home/USER/nas_docs
  - USER is removed from the docker group
  - USER cannot read ~/openclaw/.env or ~/.openclaw/openclaw.json
  - the OpenClaw gateway runs as a separate runtime account
  - the runtime account reads NAS through a per-account data group

Options:
  --user USER             Customer Linux account, for example oc1.
  --runtime-user USER     Runtime account. Default: <user>_rt.
  --data-group GROUP      NAS shared group. Default: <user>_data.
  --share UNC             CIFS share path. Required unless --no-remount is used.
  --credentials FILE      CIFS credentials file. Required unless --no-remount is used.
  --mountpoint DIR        NAS mountpoint. Default: /home/<user>/nas_docs.
  --compose-dir DIR       OpenClaw compose dir. Default: /home/<user>/openclaw.
  --no-remount            Do not unmount/remount NAS; only adjust users/files/compose.
  --no-restart            Do not restart the gateway.
  --check                 Run verification after applying.

Run as root.
USAGE
}

target_user=""
runtime_user=""
data_group=""
share=""
credentials=""
mountpoint=""
compose_dir=""
remount=1
restart_gateway=1
run_check=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user)
      target_user="${2:?missing user}"
      shift 2
      ;;
    --runtime-user)
      runtime_user="${2:?missing runtime user}"
      shift 2
      ;;
    --data-group)
      data_group="${2:?missing data group}"
      shift 2
      ;;
    --share)
      share="${2:?missing share}"
      shift 2
      ;;
    --credentials)
      credentials="${2:?missing credentials file}"
      shift 2
      ;;
    --mountpoint)
      mountpoint="${2:?missing mountpoint}"
      shift 2
      ;;
    --compose-dir)
      compose_dir="${2:?missing compose dir}"
      shift 2
      ;;
    --no-remount)
      remount=0
      shift
      ;;
    --no-restart)
      restart_gateway=0
      shift
      ;;
    --check)
      run_check=1
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

if [[ "$(id -u)" -ne 0 ]]; then
  echo "error: run with sudo/root" >&2
  exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-safe-compose.sh
source "$script_dir/lib-safe-compose.sh"

if [[ ! "$target_user" =~ ^oc[1-9][0-9]*$ ]]; then
  echo "error: invalid user name: $target_user" >&2
  exit 2
fi

target_home="$(getent passwd "$target_user" | cut -d: -f6)"
if [[ -z "$target_home" ]]; then
  echo "error: user not found: $target_user" >&2
  exit 1
fi

runtime_user="${runtime_user:-${target_user}_rt}"
data_group="${data_group:-${target_user}_data}"
mountpoint="${mountpoint:-$target_home/nas_docs}"
compose_dir="${compose_dir:-$target_home/openclaw}"
container="openclaw-${target_user}-openclaw-gateway-1"
cli_container="openclaw-${target_user}-openclaw-cli-1"

if [[ "$compose_dir" != "$target_home/openclaw" ]]; then
  echo "error: --compose-dir must be the managed slot path: $target_home/openclaw" >&2
  exit 2
fi

case "$mountpoint" in
  "$target_home/nas_docs"|"$target_home/nas_docs/"*) ;;
  *)
    echo "error: --mountpoint must stay under $target_home/nas_docs" >&2
    exit 2
    ;;
esac

if [[ "$mountpoint" == *"/../"* || "$mountpoint" == */.. || -L "$mountpoint" ]]; then
  echo "error: unsafe NAS mountpoint: $mountpoint" >&2
  exit 2
fi

if [[ "$remount" -eq 1 ]]; then
  if [[ -z "$share" ]]; then
    echo "error: --share is required unless --no-remount is used" >&2
    exit 2
  fi
  if [[ -z "$credentials" ]]; then
    echo "error: --credentials is required unless --no-remount is used" >&2
    exit 2
  fi
fi

compose_args() {
  printf '%s\n' -f docker-compose.yml
  [[ -f "$compose_dir/docker-compose.extra.yml" ]] && printf '%s\n' -f docker-compose.extra.yml
  [[ -f "$compose_dir/docker-compose.host-user.yml" ]] && printf '%s\n' -f docker-compose.host-user.yml
  [[ -f "$compose_dir/docker-compose.sandbox.yml" ]] && printf '%s\n' -f docker-compose.sandbox.yml
}

echo "== preflight =="
openclaw_assert_managed_slot_prewrite "$target_user"
id "$target_user"
test -d "$target_home"
test -d "$compose_dir"
test -f "$compose_dir/docker-compose.yml"
test -f "$compose_dir/.env"
test -f "$target_home/.openclaw/openclaw.json"
if [[ "$remount" -eq 1 ]]; then
  test -f "$credentials"
fi

target_uid="$(id -u "$target_user")"

echo "== create runtime identity =="
if ! getent group "$data_group" >/dev/null; then
  groupadd "$data_group"
fi

if ! id "$runtime_user" >/dev/null 2>&1; then
  useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin "$runtime_user"
fi

usermod -aG "$data_group" "$runtime_user"

runtime_uid="$(id -u "$runtime_user")"
runtime_gid="$(id -g "$runtime_user")"
data_gid="$(getent group "$data_group" | cut -d: -f3)"

echo "target_uid=$target_uid"
echo "runtime_uid=$runtime_uid runtime_gid=$runtime_gid data_gid=$data_gid"

echo "== stop current containers =="
docker rm -f "$container" >/dev/null 2>&1 || true
docker rm -f "$cli_container" >/dev/null 2>&1 || true

if [[ "$remount" -eq 1 ]]; then
  echo "== remount NAS for owner $target_user + group $data_group =="
  current_mount_target="$(findmnt -T "$mountpoint" -n -o TARGET 2>/dev/null | head -1 || true)"
  if [[ "$current_mount_target" == "$mountpoint" ]]; then
    umount "$mountpoint"
  fi
  mkdir -p "$mountpoint"
  chown "$target_user:$data_group" "$mountpoint"
  chmod 0550 "$mountpoint"
  mount -t cifs "$share" "$mountpoint" \
    -o "credentials=$credentials,uid=$target_uid,gid=$data_gid,forceuid,forcegid,ro,file_mode=0440,dir_mode=0550,iocharset=utf8,vers=3.1.1,nounix,noserverino,nosharesock"
else
  echo "== remount skipped =="
fi

echo "== protect state and runtime env from $target_user =="
if [[ -d "$target_home/.openclaw" ]]; then
  chown -R "$runtime_user:$runtime_user" "$target_home/.openclaw"
  find "$target_home/.openclaw" -type d -exec chmod 0700 {} +
  find "$target_home/.openclaw" -type f -exec chmod 0600 {} +
fi

if [[ -d "$target_home/.openclaw-auth-profile-secrets" ]]; then
  chown -R "$runtime_user:$runtime_user" "$target_home/.openclaw-auth-profile-secrets"
  find "$target_home/.openclaw-auth-profile-secrets" -type d -exec chmod 0700 {} +
  find "$target_home/.openclaw-auth-profile-secrets" -type f -exec chmod 0600 {} +
fi

if [[ -f "$target_home/.openclaw-install.env" ]]; then
  chown root:root "$target_home/.openclaw-install.env"
  chmod 0600 "$target_home/.openclaw-install.env"
fi

chown -R root:root "$compose_dir"
find "$compose_dir" -type d -exec chmod 0755 {} +
find "$compose_dir" -type f -exec chmod 0644 {} +
chmod 0600 "$compose_dir/.env"

chown "$target_user:$target_user" "$target_home"
chmod 0750 "$target_home"

echo "== write runtime compose override =="
timestamp="$(date +%Y%m%d%H%M%S)"
if [[ -f "$compose_dir/docker-compose.host-user.yml" ]]; then
  cp -a "$compose_dir/docker-compose.host-user.yml" "$compose_dir/docker-compose.host-user.yml.bak.$timestamp"
fi

cat > "$compose_dir/docker-compose.host-user.yml" <<EOF
services:
  openclaw-gateway:
    user: "$runtime_uid:$runtime_gid"
    group_add:
      - "$data_gid"
  openclaw-cli:
    user: "$runtime_uid:$runtime_gid"
    group_add:
      - "$data_gid"
EOF

chown root:root "$compose_dir/docker-compose.host-user.yml"
chmod 0644 "$compose_dir/docker-compose.host-user.yml"

echo "== remove customer docker group =="
gpasswd -d "$target_user" docker >/dev/null 2>&1 || true

if [[ "$restart_gateway" -eq 1 ]]; then
  echo "== start gateway as runtime user =="
  openclaw_assert_safe_compose_dir "$target_user" "$compose_dir"
  cd "$compose_dir"
  mapfile -t args < <(compose_args)
  docker compose "${args[@]}" up -d --force-recreate openclaw-gateway

  for i in $(seq 1 30); do
    status="$(docker inspect "$container" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' 2>/dev/null || echo missing)"
    echo "health_attempt_$i=$status"
    [[ "$status" == "healthy" ]] && break
    sleep 2
  done
else
  echo "== restart skipped =="
fi

if [[ "$run_check" -eq 1 ]]; then
  bash "$script_dir/check-customer-mode-isolation.sh" --user "$target_user"
fi

echo "done"
