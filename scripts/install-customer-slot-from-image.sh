#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  install-customer-slot-from-image.sh --user USER [options]

Creates a customer-mode OpenClaw slot directly from an already-built Docker
image. This is the fast fresh-install path for a prepared ocN slot.

Prerequisites:
  - USER exists.
  - /home/USER/.openclaw-install.env exists.
  - at least one registered /home/USER/nas_docs/SHARE_NAME CIFS mount exists.
  - OPENCLAW_IMAGE, or --image, points at a ready OpenClaw baseline image.

Options:
  --user USER           Target customer slot, for example oc20. Required.
  --host HOST           Public subdomain. Default: USER.BASE_DOMAIN.
  --base-domain NAME    Base domain. Default: ji-tech.co.kr.
  --image IMAGE         Docker image. Default: openclaw-nas-agent:baseline.
  --env-file FILE       Install env file. Default: /home/USER/.openclaw-install.env.
  --compose-dir DIR     Compose dir. Default: /home/USER/openclaw.
  --runtime-user USER   Runtime account. Default: USER_rt.
  --data-group GROUP    NAS shared group. Default: USER_data.
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
env_file=""
compose_dir=""
runtime_user=""
data_group=""
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
    --env-file)
      env_file="${2:?missing --env-file value}"
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

if [[ ! "$target_user" =~ ^oc[1-9][0-9]*$ ]]; then
  echo "error: invalid user name: $target_user" >&2
  exit 2
fi

if [[ "$(id -u)" -ne 0 ]]; then
  echo "error: run with sudo/root" >&2
  exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
target_home="$(getent passwd "$target_user" | cut -d: -f6)"
if [[ -z "$target_home" ]]; then
  echo "error: user not found: $target_user" >&2
  exit 1
fi

host="${host:-${target_user}.${base_domain}}"
origin="https://${host}"
env_file="${env_file:-$target_home/.openclaw-install.env}"
compose_dir="${compose_dir:-$target_home/openclaw}"
runtime_user="${runtime_user:-${target_user}_rt}"
data_group="${data_group:-${target_user}_data}"
nas_mount="$target_home/nas_docs"
container="openclaw-${target_user}-openclaw-gateway-1"
cli_container="openclaw-${target_user}-openclaw-cli-1"

slot="${target_user#oc}"
gateway_port=$((28789 + (slot - 1) * 100))
bridge_port=$((gateway_port + 1))

if [[ ! -f "$env_file" ]]; then
  echo "error: install env not found: $env_file" >&2
  exit 1
fi

if ! docker image inspect "$image" >/dev/null 2>&1; then
  echo "error: image not found: $image" >&2
  echo "hint: build it first with scripts/build-container-baseline.sh" >&2
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
    echo "hint: svcops should register a share, then the customer runs openclaw-nas-mount --mount-name SHARE_NAME --reset-credential" >&2
    exit 1
  fi
  nas_check_failed=0
  for nas_mp in "${nas_mountpoints[@]}"; do
    nas_target="$(findmnt -T "$nas_mp" -n -o TARGET 2>/dev/null | head -1 || true)"
    nas_fstype="$(findmnt -T "$nas_mp" -n -o FSTYPE 2>/dev/null | head -1 || true)"
    if [[ "$nas_target" != "$nas_mp" || "$nas_fstype" != "cifs" ]]; then
      echo "error: NAS is not mounted as CIFS at $nas_mp" >&2
      echo "hint: customer should run openclaw-nas-mount --mount-name \"${nas_mp##*/}\" --reset-credential" >&2
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

OPENCLAW_CONTROL_UI_BASEPATH="/" \
OPENCLAW_PROXY_PUBLIC_ORIGIN="$origin" \
OPENCLAW_PROXY_ALLOWED_ORIGINS="$origin" \
bash "$script_dir/repair-openclaw-state.sh" \
  --user "$target_user" \
  --force-defaults \
  --no-backup

bash "$script_dir/apply-openclaw-install-env.sh" \
  --env-file "$env_file" \
  --user "$target_user"

subdomain_args=(--user "$target_user" --host "$host" --no-recreate)
if [[ "$write_apache" -eq 0 ]]; then
  subdomain_args+=(--no-apache-conf)
fi
bash "$script_dir/apply-subdomain-mode.sh" "${subdomain_args[@]}"

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

if [[ -f "$target_home/.openclaw-install.env" ]]; then
  chown root:root "$target_home/.openclaw-install.env"
  chmod 0600 "$target_home/.openclaw-install.env"
fi

chown "$target_user:$target_user" "$target_home"
chmod 0750 "$target_home"
gpasswd -d "$target_user" docker >/dev/null 2>&1 || true

echo "== docker compose up =="
(
  cd "$compose_dir"
  export COMPOSE_PROJECT_NAME="openclaw-$target_user"
  docker compose \
    -f docker-compose.yml \
    -f docker-compose.host-user.yml \
    up -d --force-recreate openclaw-gateway
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
  bash "$script_dir/check-customer-deployment.sh" \
    --user "$target_user" \
    --expected-basepath / \
    --expected-origin "$origin"
fi

echo "done"
