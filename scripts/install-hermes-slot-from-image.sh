#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  install-hermes-slot-from-image.sh --user USER --image IMAGE [options]

Reconfigures a prepared ocN slot to run a Hermes Agent container image.
The image should be a public registry image derived from nousresearch/hermes-agent
with the OpenClaw NAS Agent document baseline packages installed.

Options:
  --user USER           Target slot, for example oc15. Required.
  --image IMAGE         Hermes NAS Agent image ref. Required.
  --host HOST           Public subdomain. Default: USER.BASE_DOMAIN.
  --base-domain NAME    Base domain. Default: ji-tech.co.kr.
  --force               Replace existing gateway container and compose files.
  --insecure-dashboard  Publish the Hermes dashboard without a login gate.
                        Temporary lab use only. Do not use for customer slots.

Run as root/admin.
USAGE
}

target_user=""
image=""
host=""
base_domain="${OPENCLAW_BASE_DOMAIN:-ji-tech.co.kr}"
force=0
insecure_dashboard=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user)
      target_user="${2:?missing --user value}"
      shift 2
      ;;
    --image)
      image="${2:?missing --image value}"
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
    --force)
      force=1
      shift
      ;;
    --insecure-dashboard)
      insecure_dashboard=1
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

if [[ -z "$target_user" || -z "$image" ]]; then
  echo "error: --user and --image are required" >&2
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
# shellcheck source=scripts/lib-safe-compose.sh
source "$script_dir/lib-safe-compose.sh"

target_home="$(getent passwd "$target_user" | cut -d: -f6)"
if [[ -z "$target_home" || "$target_home" != "/home/$target_user" ]]; then
  echo "error: unexpected or missing home for $target_user: ${target_home:-missing}" >&2
  exit 1
fi

host="${host:-${target_user}.${base_domain}}"
origin="https://${host}"
runtime_user="${target_user}_rt"
data_group="${target_user}_data"
compose_dir="$target_home/openclaw"
hermes_home="$target_home/.hermes"
nas_mount="$target_home/nas_docs"
slot="${target_user#oc}"
gateway_port=$((28789 + (slot - 1) * 100))
dashboard_port=$((gateway_port + 1))
container="openclaw-${target_user}-openclaw-gateway-1"
cli_container="openclaw-${target_user}-openclaw-cli-1"

if [[ ! "$host" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$ ]]; then
  echo "error: invalid host: $host" >&2
  exit 2
fi

if ! docker image inspect "$image" >/dev/null 2>&1; then
  echo "error: image not found: $image" >&2
  exit 1
fi

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

openclaw_assert_managed_slot_prewrite "$target_user"

if [[ "$force" -eq 1 ]]; then
  docker rm -f "$container" >/dev/null 2>&1 || true
  docker rm -f "$cli_container" >/dev/null 2>&1 || true
fi

mkdir -p "$compose_dir" "$hermes_home" "$hermes_home/home" "$hermes_home/nas_docs"
chown -R "$runtime_user:$data_group" "$hermes_home"
chmod 0750 "$hermes_home" "$hermes_home/home" "$hermes_home/nas_docs"
chown root:root "$compose_dir"
chmod 0755 "$compose_dir"

openclaw_assert_managed_slot_prewrite "$target_user"

api_key="$(openssl rand -hex 32 2>/dev/null || python3 - <<'PY'
import secrets
print(secrets.token_hex(32))
PY
)"

cat > "$compose_dir/.env" <<EOF
OPENCLAW_RUNTIME_FAMILY='hermes'
OPENCLAW_INSTANCE='$target_user'
COMPOSE_PROJECT_NAME='openclaw-$target_user'
OPENCLAW_IMAGE='$image'
OPENCLAW_GATEWAY_PORT='$gateway_port'
OPENCLAW_BRIDGE_PORT='$dashboard_port'
OPENCLAW_PROXY_MODE='subdomain'
OPENCLAW_CONTROL_UI_BASEPATH='/'
OPENCLAW_PROXY_PUBLIC_ORIGIN='$origin'
OPENCLAW_PROXY_ALLOWED_ORIGINS='$origin'
OPENCLAW_NAS_HOST_PATH='$nas_mount'
OPENCLAW_NAS_CONTAINER_PATH='/home/node/nas_docs'
OPENCLAW_EXTRA_MOUNTS='$nas_mount:/home/node/nas_docs:ro'
HERMES_HOME='/opt/data'
HERMES_DATA_DIR='/opt/data'
HERMES_DASHBOARD='1'
HERMES_DASHBOARD_HOST='0.0.0.0'
HERMES_DASHBOARD_PORT='9119'
HERMES_DASHBOARD_INSECURE='1'
API_SERVER_ENABLED='true'
API_SERVER_HOST='0.0.0.0'
API_SERVER_KEY='$api_key'
PUID='$runtime_uid'
PGID='$runtime_gid'
HERMES_UID='$runtime_uid'
HERMES_GID='$runtime_gid'
LANG='ko_KR.UTF-8'
LANGUAGE='ko_KR:ko'
LC_ALL='ko_KR.UTF-8'
EOF

cat > "$compose_dir/docker-compose.yml" <<EOF
services:
  openclaw-gateway:
    image: \${OPENCLAW_IMAGE:-$image}
    restart: unless-stopped
    env_file:
      - .env
    command: ["gateway", "run"]
    environment:
      HERMES_HOME: /opt/data
      HERMES_DATA_DIR: /opt/data
      HERMES_DASHBOARD: "1"
      HERMES_DASHBOARD_HOST: 0.0.0.0
      HERMES_DASHBOARD_PORT: "9119"
      HERMES_DASHBOARD_INSECURE: "1"
      API_SERVER_ENABLED: "true"
      API_SERVER_HOST: 0.0.0.0
      HOME: /opt/data/home
      LANG: ko_KR.UTF-8
      LANGUAGE: ko_KR:ko
      LC_ALL: ko_KR.UTF-8
    ports:
      - "127.0.0.1:\${OPENCLAW_GATEWAY_PORT:-$gateway_port}:8642"
      - "127.0.0.1:\${OPENCLAW_BRIDGE_PORT:-$dashboard_port}:9119"
    volumes:
      - $hermes_home:/opt/data
      - $nas_mount:/opt/data/nas_docs:ro
      - $nas_mount:/home/node/nas_docs:ro
    working_dir: /opt/data/home
EOF

rm -f "$compose_dir/docker-compose.host-user.yml"

chown root:root "$compose_dir/.env" "$compose_dir/docker-compose.yml"
chmod 0600 "$compose_dir/.env"
chmod 0644 "$compose_dir/docker-compose.yml"

openclaw_assert_safe_compose_dir "$target_user" "$compose_dir"

echo "target_user=$target_user"
echo "runtime_family=hermes"
echo "target_home=$target_home"
echo "hermes_home=$hermes_home"
echo "image=$image"
echo "host=$host"
echo "gateway_port=$gateway_port"
echo "dashboard_port=$dashboard_port"
if [[ "$insecure_dashboard" -eq 1 ]]; then
  echo "dashboard_exposure=public_insecure"
else
  echo "dashboard_exposure=local_only"
fi

(
  cd "$compose_dir"
  docker compose -f docker-compose.yml up -d --force-recreate openclaw-gateway
)

docker ps --filter "name=^/${container}$" --format 'container={{.Names}} status={{.Status}}'

apache_output="/etc/apache2/openclaw/apache-subdomain-${target_user}.conf"
if [[ "$insecure_dashboard" -eq 1 && -d /etc/apache2/openclaw && -x "$(command -v apache2ctl || true)" ]]; then
  bash "$script_dir/write-apache-proxy-conf.sh" \
    --user "$target_user" \
    --mode subdomain \
    --host "$host" \
    --base-domain "$base_domain" \
    --port "$dashboard_port" \
    --output "$apache_output" \
    --apply \
    --reload
elif [[ -d /etc/apache2/openclaw && -x "$(command -v apache2ctl || true)" ]]; then
  tmp_apache="$(mktemp)"
  cat > "$tmp_apache" <<EOF
# Hermes local-only dashboard - ${target_user}
# Public access is intentionally disabled. Use an SSH tunnel to 127.0.0.1:${dashboard_port}.
<VirtualHost *:443>
    ServerName ${host}

    SSLEngine on
    SSLCertificateFile      /etc/letsencrypt/live/${base_domain}/fullchain.pem
    SSLCertificateKeyFile   /etc/letsencrypt/live/${base_domain}/privkey.pem

    <Location />
        Require all denied
    </Location>

    ErrorDocument 403 "Hermes dashboard is local-only. Use SSH tunnel to 127.0.0.1:${dashboard_port}."
</VirtualHost>
EOF
  if [[ -f "$apache_output" ]]; then
    backup="${apache_output}.$(date +%Y%m%d%H%M%S).bak"
    cp -a "$apache_output" "$backup"
    echo "backup=$backup"
  fi
  cat "$tmp_apache" > "$apache_output"
  rm -f "$tmp_apache"
  chown root:root "$apache_output"
  chmod 0644 "$apache_output"
  echo "written=$apache_output"
  apache2ctl -t
  if command -v systemctl >/dev/null 2>&1; then
    systemctl reload apache2
  else
    service apache2 reload
  fi
else
  bash "$script_dir/write-apache-proxy-conf.sh" \
    --user "$target_user" \
    --mode subdomain \
    --host "$host" \
    --base-domain "$base_domain" \
    --port "$dashboard_port" \
    --apply
fi
