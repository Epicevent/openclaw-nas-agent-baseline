#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  slot-control.sh install-openclaw --user USER [options]

Creates a customer-mode OpenClaw slot directly from an already-built Docker
image. This is the fast fresh-install path for a prepared ocN slot.

Prerequisites:
  - USER exists.
  - at least one registered CIFS mount exists under /home/USER/nas_docs.
  - OPENCLAW_IMAGE, or --image, points at a ready OpenClaw baseline image.
  - Provider/API keys are optional at install time and can be applied later with
    slot-control.sh runtime-secrets.

Options:
  --user USER           Target customer slot, for example oc20. Required.
  --host HOST           Public subdomain. Default: USER.BASE_DOMAIN.
  --base-domain NAME    Base domain. Default: ji-tech.co.kr.
  --image IMAGE         Docker image. Default: openclaw-nas-agent:baseline.
  --compose-dir DIR     Compose dir. Default: /home/USER/openclaw.
  --runtime-user USER   Runtime account. Default: USER_rt.
  --data-group GROUP    NAS shared group. Default: USER_data.
  --gateway-port PORT   Backend gateway host port. Default: slot policy.
  --bridge-port PORT    Backend bridge host port. Default: gateway port + 1.
  --skip-nas-check      Do not require a CIFS mount under /home/USER/nas_docs.
  --no-apache-conf      Do not write /home/USER/openclaw/deploy/apache-subdomain-USER.conf.
  --force               Replace existing compose files and target containers.
  --check               Run deployment check after starting.

Run as root/admin.
USAGE
}

target_user=""
host=""
base_domain="${OPENCLAW_BASE_DOMAIN:-ji-tech.co.kr}"
image="${OPENCLAW_IMAGE:-openclaw-nas-agent:baseline}"
compose_dir=""
runtime_user=""
data_group=""
gateway_port=""
bridge_port=""
skip_nas_check=0
write_apache=1
force=0
run_check=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user)
      target_user="${2:?missing --user value}"
      shift 2
      ;;
    --host)
      host="${2:?missing --host value}"
      shift 2
      ;;
    --base-domain)
      base_domain="${2:?missing --base-domain value}"
      shift 2
      ;;
    --image)
      image="${2:?missing --image value}"
      shift 2
      ;;
    --compose-dir)
      compose_dir="${2:?missing --compose-dir value}"
      shift 2
      ;;
    --runtime-user)
      runtime_user="${2:?missing --runtime-user value}"
      shift 2
      ;;
    --data-group)
      data_group="${2:?missing --data-group value}"
      shift 2
      ;;
    --gateway-port)
      gateway_port="${2:?missing --gateway-port value}"
      shift 2
      ;;
    --bridge-port)
      bridge_port="${2:?missing --bridge-port value}"
      shift 2
      ;;
    --skip-nas-check)
      skip_nas_check=1
      shift
      ;;
    --no-apache-conf)
      write_apache=0
      shift
      ;;
    --force)
      force=1
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
# shellcheck source=scripts/internal/lib-safe-compose.bash
source "$script_dir/lib-safe-compose.bash"
openclaw_assert_managed_slot_name "$target_user" || exit $?
target_home="$(getent passwd "$target_user" | cut -d: -f6)"
if [[ -z "$target_home" ]]; then
  echo "error: user not found: $target_user" >&2
  exit 1
fi

host="${host:-${target_user}.${base_domain}}"
origin="https://${host}"
compose_dir="${compose_dir:-$target_home/openclaw}"
runtime_user="${runtime_user:-${target_user}_rt}"
data_group="${data_group:-${target_user}_data}"
nas_mount="$target_home/nas_docs"
config_path="$target_home/.openclaw/openclaw.json"
container="openclaw-${target_user}-openclaw-gateway-1"
cli_container="openclaw-${target_user}-openclaw-cli-1"

if [[ "$compose_dir" != "$target_home/openclaw" ]]; then
  echo "error: --compose-dir must be the managed slot path: $target_home/openclaw" >&2
  exit 2
fi

if [[ ! "$host" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$ ]]; then
  echo "error: invalid host: $host" >&2
  exit 2
fi

slot="$(openclaw_slot_number "$target_user" 2>/dev/null || printf '%s' "$target_user")"
gateway_port="${gateway_port:-$(openclaw_slot_default_gateway_port "$target_user")}"
bridge_port="${bridge_port:-$(openclaw_slot_default_bridge_port "$target_user")}"
openclaw_validate_port "$gateway_port" gateway_port || exit $?
openclaw_validate_port "$bridge_port" bridge_port || exit $?

if ! docker image inspect "$image" >/dev/null 2>&1; then
  echo "error: image not found: $image" >&2
  echo "hint: register and pull an official public image release before installing the slot" >&2
  exit 1
fi

if [[ "$skip_nas_check" -eq 0 ]]; then
  mapfile -t nas_mountpoints < <(awk -v root="$nas_mount" '
    $0 !~ /^[[:space:]]*#/ && $3 == "cifs" && ($2 == root || index($2, root "/") == 1) {
      print $2
    }
  ' /etc/fstab 2>/dev/null)
  if [[ "${#nas_mountpoints[@]}" -eq 0 ]]; then
    echo "error: no registered NAS CIFS mount under $nas_mount" >&2
    echo "hint: customer requests a source with agent-nas-mount --request-share '//NAS_HOST/SHARE'" >&2
    echo "hint: the default local path is generated as host-<hosthash>/SHARE-<sharehash> to avoid cross-NAS name collisions" >&2
    exit 1
  fi
  nas_check_failed=0
  for nas_mp in "${nas_mountpoints[@]}"; do
    nas_target="$(openclaw_findmnt_exact_field "$nas_mp" TARGET)"
    nas_fstype="$(openclaw_findmnt_exact_field "$nas_mp" FSTYPE)"
    nas_source="$(awk -v mp="$nas_mp" '$0 !~ /^[[:space:]]*#/ && $2 == mp && $3 == "cifs" { print $1; exit }' /etc/fstab 2>/dev/null || true)"
    if [[ "$nas_target" != "$nas_mp" || "$nas_fstype" != "cifs" ]]; then
      echo "error: NAS is not mounted as CIFS at $nas_mp" >&2
      if [[ -n "$nas_source" ]]; then
        echo "hint: customer should run agent-nas-mount --share \"$nas_source\" --reset-credential" >&2
      fi
      nas_check_failed=1
    fi
  done
  [[ "$nas_check_failed" -eq 0 ]] || exit 1
fi

if [[ -f "$compose_dir/docker-compose.yml" && "$force" -ne 1 ]]; then
  echo "error: compose already exists: $compose_dir/docker-compose.yml" >&2
  echo "hint: pass --force only when replacing this slot install" >&2
  exit 1
fi

if docker inspect "$container" >/dev/null 2>&1 && [[ "$force" -ne 1 ]]; then
  echo "error: container already exists: $container" >&2
  echo "hint: pass --force only when replacing this slot install" >&2
  exit 1
fi

echo "target_user=$target_user"
echo "target_home=$target_home"
echo "runtime_user=$runtime_user"
echo "data_group=$data_group"
echo "image=$image"
echo "host=$host"
echo "gateway_port=$gateway_port"
echo "secret_import=skipped"

openclaw_assert_managed_slot_prewrite "$target_user"

if ! getent group "$data_group" >/dev/null; then
  groupadd "$data_group"
fi

if ! id "$runtime_user" >/dev/null 2>&1; then
  useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin "$runtime_user"
fi

usermod -aG "$data_group" "$runtime_user"

target_uid="$(id -u "$target_user")"
target_gid="$(id -g "$target_user")"
runtime_uid="$(id -u "$runtime_user")"
runtime_gid="$(id -g "$runtime_user")"
data_gid="$(getent group "$data_group" | cut -d: -f3)"

if [[ "$force" -eq 1 ]]; then
  docker rm -f "$container" >/dev/null 2>&1 || true
  docker rm -f "$cli_container" >/dev/null 2>&1 || true
fi

mkdir -p "$compose_dir" \
  "$target_home/.openclaw" \
  "$target_home/.openclaw/workspace" \
  "$target_home/.config/openclaw" \
  "$target_home/.openclaw-auth-profile-secrets"

openclaw_assert_managed_slot_prewrite "$target_user"
openclaw_assert_safe_openclaw_config_file "$target_user" "$config_path"

cat > "$compose_dir/.env" <<EOF
OPENCLAW_INSTANCE='$target_user'
COMPOSE_PROJECT_NAME='openclaw-$target_user'
OPENCLAW_IMAGE='$image'
OPENCLAW_GATEWAY_PORT='$gateway_port'
OPENCLAW_BRIDGE_PORT='$bridge_port'
OPENCLAW_PORT_BASE='28789'
OPENCLAW_PORT_STRIDE='100'
OPENCLAW_PORT_SLOT='$slot'
OPENCLAW_PROXY_MODE='subdomain'
OPENCLAW_CONTROL_UI_BASEPATH='/'
OPENCLAW_CONTROL_UI_DISABLE_DEVICE_AUTH='1'
OPENCLAW_PROXY_PUBLIC_ORIGIN='$origin'
OPENCLAW_PROXY_ALLOWED_ORIGINS='$origin'
OPENCLAW_GATEWAY_BIND='lan'
OPENCLAW_CONFIG_DIR='/home/node/.openclaw'
OPENCLAW_CONFIG_PATH='/home/node/.openclaw/openclaw.json'
OPENCLAW_STATE_DIR='/home/node/.openclaw'
OPENCLAW_WORKSPACE_DIR='/home/node/.openclaw/workspace'
OPENCLAW_NAS_HOST_PATH='$nas_mount'
OPENCLAW_NAS_CONTAINER_PATH='/home/node/nas_docs'
OPENCLAW_NAS_SYMLINK='$nas_mount'
OPENCLAW_EXTRA_MOUNTS='$nas_mount:/home/node/nas_docs:ro'
OPENCLAW_HOST_UID='$runtime_uid'
OPENCLAW_HOST_GID='$runtime_gid'
LANG='ko_KR.UTF-8'
LANGUAGE='ko_KR:ko'
LC_ALL='ko_KR.UTF-8'
EOF

cat > "$compose_dir/docker-compose.yml" <<EOF
services:
  openclaw-gateway:
    image: \${OPENCLAW_IMAGE:-$image}
    restart: unless-stopped
    init: true
    entrypoint: ["openclaw"]
    command: ["gateway", "run"]
    env_file:
      - .env
    environment:
      HOME: /home/node
      OPENCLAW_HOME: /home/node/.openclaw
      OPENCLAW_CONFIG_DIR: /home/node/.openclaw
      OPENCLAW_CONFIG_PATH: /home/node/.openclaw/openclaw.json
      OPENCLAW_STATE_DIR: /home/node/.openclaw
      OPENCLAW_WORKSPACE_DIR: /home/node/.openclaw/workspace
      OPENCLAW_GATEWAY_PORT: "18789"
      OPENCLAW_BRIDGE_PORT: "18790"
      OPENCLAW_NAS_CONTAINER_PATH: /home/node/nas_docs
      LANG: ko_KR.UTF-8
      LANGUAGE: ko_KR:ko
      LC_ALL: ko_KR.UTF-8
    ports:
      - "\${OPENCLAW_GATEWAY_PORT:-$gateway_port}:18789"
      - "\${OPENCLAW_BRIDGE_PORT:-$bridge_port}:18790"
    volumes:
      - $target_home/.openclaw:/home/node/.openclaw
      - $target_home/.config/openclaw:/home/node/.config/openclaw
      - $target_home/.openclaw-auth-profile-secrets:/home/node/.openclaw-auth-profile-secrets
      - $nas_mount:/home/node/nas_docs:ro
    working_dir: /home/node/.openclaw/workspace

  openclaw-cli:
    image: \${OPENCLAW_IMAGE:-$image}
    init: true
    entrypoint: ["openclaw"]
    env_file:
      - .env
    environment:
      HOME: /home/node
      OPENCLAW_HOME: /home/node/.openclaw
      OPENCLAW_CONFIG_DIR: /home/node/.openclaw
      OPENCLAW_CONFIG_PATH: /home/node/.openclaw/openclaw.json
      OPENCLAW_STATE_DIR: /home/node/.openclaw
      OPENCLAW_WORKSPACE_DIR: /home/node/.openclaw/workspace
      OPENCLAW_GATEWAY_PORT: "18789"
      LANG: ko_KR.UTF-8
      LANGUAGE: ko_KR:ko
      LC_ALL: ko_KR.UTF-8
    network_mode: "service:openclaw-gateway"
    volumes:
      - $target_home/.openclaw:/home/node/.openclaw
      - $target_home/.config/openclaw:/home/node/.config/openclaw
      - $target_home/.openclaw-auth-profile-secrets:/home/node/.openclaw-auth-profile-secrets
      - $nas_mount:/home/node/nas_docs:ro
    working_dir: /home/node/.openclaw/workspace
EOF

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

chown -R root:root "$compose_dir"
find "$compose_dir" -type d -exec chmod 0755 {} +
find "$compose_dir" -type f -exec chmod 0644 {} +
chmod 0600 "$compose_dir/.env"
chown root:root "$compose_dir/.env" "$compose_dir/docker-compose.host-user.yml"

if ! command -v python3 >/dev/null 2>&1; then
  echo "error: python3 is required to initialize production OpenClaw config" >&2
  exit 1
fi

OPENCLAW_PRODUCTION_CONFIG_PATH="$config_path" \
OPENCLAW_PRODUCTION_WORKSPACE="/home/node/.openclaw/workspace" \
OPENCLAW_PRODUCTION_ORIGIN="$origin" \
python3 - <<'PY'
import json
import os
import secrets
import stat
from pathlib import Path

path = Path(os.environ["OPENCLAW_PRODUCTION_CONFIG_PATH"])
workspace = os.environ["OPENCLAW_PRODUCTION_WORKSPACE"]
origin = os.environ["OPENCLAW_PRODUCTION_ORIGIN"].rstrip("/")


def safe_write_regular(path: Path, text: str) -> None:
    flags = os.O_WRONLY | os.O_CREAT
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    fd = os.open(path, flags, 0o600)
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            raise RuntimeError(f"not a regular file: {path}")
        if st.st_nlink != 1:
            raise RuntimeError(f"hardlinked file refused: {path}")
        os.ftruncate(fd, 0)
        os.write(fd, text.encode("utf-8"))
    finally:
        os.close(fd)
    os.chmod(path, 0o600)

data = {
    "gateway": {
        "mode": "local",
        "port": 18789,
        "bind": "lan",
        "auth": {
            "mode": "token",
            "token": secrets.token_urlsafe(32),
        },
        "controlUi": {
            "basePath": "/",
            "dangerouslyDisableDeviceAuth": True,
            "allowedOrigins": [origin],
            "allowInsecureAuth": True,
        },
    },
    "agents": {
        "defaults": {
            "workspace": workspace,
            "heartbeat": {
                "every": "0m",
            },
        },
    },
}

path.parent.mkdir(parents=True, exist_ok=True)
safe_write_regular(path, json.dumps(data, indent=2, ensure_ascii=False) + "\n")
PY

echo "state_init=production_minimal"
echo "workspace_seed=skipped"
echo "recovery=skipped"

echo "INFO runtime_secret_injection=not_part_of_fresh_install"

subdomain_args=(--user "$target_user" --host "$host" --no-recreate)
if [[ "$write_apache" -eq 0 ]]; then
  subdomain_args+=(--no-apache-conf)
fi
bash "$script_dir/apply-subdomain-mode.bash" "${subdomain_args[@]}"

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

chown -R root:root "$compose_dir"
find "$compose_dir" -type d -exec chmod 0755 {} +
find "$compose_dir" -type f -exec chmod 0644 {} +
chmod 0600 "$compose_dir/.env"
chown root:root "$compose_dir/.env" "$compose_dir/docker-compose.host-user.yml"

chown "$target_user:$target_user" "$target_home"
chmod 0750 "$target_home"
gpasswd -d "$target_user" docker >/dev/null 2>&1 || true

echo "== docker compose up =="
openclaw_assert_safe_compose_dir "$target_user" "$compose_dir"
(
  cd "$compose_dir"
  export COMPOSE_PROJECT_NAME="openclaw-$target_user"
  compose_args=(-f docker-compose.yml)
  [[ -f docker-compose.source.yml ]] && compose_args+=(-f docker-compose.source.yml)
  [[ -f docker-compose.extra.yml ]] && compose_args+=(-f docker-compose.extra.yml)
  [[ -f docker-compose.host-user.yml ]] && compose_args+=(-f docker-compose.host-user.yml)
  [[ -f docker-compose.shared-ollama.yml ]] && compose_args+=(-f docker-compose.shared-ollama.yml)
  [[ -f docker-compose.sandbox.yml ]] && compose_args+=(-f docker-compose.sandbox.yml)
  docker compose "${compose_args[@]}" up -d --force-recreate openclaw-gateway
)

for i in $(seq 1 30); do
  inspect="$(docker inspect "$container" --format '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' 2>/dev/null || echo "missing missing")"
  status="${inspect%% *}"
  health="${inspect#* }"
  echo "health_attempt_$i status=$status health=$health"
  if [[ "$status" == "running" && ( "$health" == "healthy" || "$health" == "none" ) ]]; then
    break
  fi
  sleep 2
done

docker ps --filter "name=^/${container}$" --format 'container={{.Names}} image={{.Image}} ports={{.Ports}} status={{.Status}}'

if [[ "$run_check" -eq 1 ]]; then
  check_args=(
    --user "$target_user"
    --expected-basepath /
    --expected-origin "$origin"
  )
  check_args+=(--skip-provider-key-check)
  bash "$script_dir/check-customer-deployment.bash" \
    "${check_args[@]}"
fi

echo "done"
