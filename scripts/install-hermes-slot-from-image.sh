#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  install-hermes-slot-from-image.sh --user USER --image IMAGE [options]

Reconfigures a prepared ocN slot to run a single Hermes container image.
The image must contain Hermes Agent, Hermes Workspace, and the OpenClaw NAS
Agent document baseline packages.

Options:
  --user USER           Target slot, for example oc15. Required.
  --image IMAGE         Integrated Hermes image ref. Required.
  --host HOST           Public subdomain. Default: USER.BASE_DOMAIN.
  --base-domain NAME    Base domain. Default: ji-tech.co.kr.
  --force               Replace existing containers.
  --local-only-dashboard
                        Do not expose Hermes Workspace through Apache.
                        Operators can still use an SSH tunnel to 127.0.0.1.

Run as root/admin.
USAGE
}

target_user=""
image=""
host=""
base_domain="${OPENCLAW_BASE_DOMAIN:-ji-tech.co.kr}"
force=0
local_only_dashboard=0

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
    --local-only-dashboard)
      local_only_dashboard=1
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
workspace_port=$((28789 + (slot - 1) * 100))
container="openclaw-${target_user}-openclaw-gateway-1"
legacy_workspace_container="openclaw-${target_user}-hermes-workspace-1"
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
if [[ -z "$data_gid" ]]; then
  echo "error: could not resolve gid for $data_group" >&2
  exit 1
fi

openclaw_assert_managed_slot_prewrite "$target_user"

if [[ "$force" -eq 1 ]]; then
  docker rm -f "$container" >/dev/null 2>&1 || true
  docker rm -f "$cli_container" >/dev/null 2>&1 || true
fi
docker rm -f "$legacy_workspace_container" >/dev/null 2>&1 || true

mkdir -p "$compose_dir" "$hermes_home" "$hermes_home/home" "$hermes_home/nas_docs" "$hermes_home/workspace"
chown -R "$runtime_user:$data_group" "$hermes_home"
chmod 0750 "$hermes_home" "$hermes_home/home" "$hermes_home/nas_docs" "$hermes_home/workspace"
chown root:root "$compose_dir"
chmod 0755 "$compose_dir"

openclaw_assert_managed_slot_prewrite "$target_user"

api_key="$(openssl rand -hex 32 2>/dev/null || python3 - <<'PY'
import secrets
print(secrets.token_hex(32))
PY
)"

provider_secret_env="$(mktemp)"
trap 'rm -f "$provider_secret_env"' EXIT
provider_secret_count=0
env_backup=""
secret_sources=()
[[ -f "$compose_dir/.env" ]] && secret_sources+=("$compose_dir/.env")
[[ -f "$hermes_home/.env" ]] && secret_sources+=("$hermes_home/.env")
if [[ -f "$compose_dir/.env" ]]; then
  env_backup="$compose_dir/.env.bak.hermes-$(date +%Y%m%d%H%M%S)"
  cp -a "$compose_dir/.env" "$env_backup"
  chown root:root "$env_backup"
  chmod 0600 "$env_backup"
fi
if [[ "${#secret_sources[@]}" -gt 0 ]]; then
  provider_secret_count="$(
    OPENCLAW_EXISTING_ENVS="$(IFS=:; printf '%s' "${secret_sources[*]}")" \
    OPENCLAW_PROVIDER_SECRET_ENV="$provider_secret_env" \
    python3 - <<'PY'
import os
import re
import shlex
from pathlib import Path

existing_envs = [Path(item) for item in os.environ["OPENCLAW_EXISTING_ENVS"].split(":") if item]
out_path = Path(os.environ["OPENCLAW_PROVIDER_SECRET_ENV"])

allowed_keys = {
    "ANTHROPIC_API_KEY",
    "DEEPSEEK_API_KEY",
    "ELEVENLABS_API_KEY",
    "GEMINI_API_KEY",
    "GOOGLE_API_KEY",
    "GROQ_API_KEY",
    "MISTRAL_API_KEY",
    "OPENAI_API_KEY",
    "OPENROUTER_API_KEY",
    "PERPLEXITY_API_KEY",
    "TOGETHER_API_KEY",
    "XAI_API_KEY",
}

key_re = re.compile(r"^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$")


def parse_value(raw: str) -> str:
    raw = raw.strip()
    if not raw:
        return ""
    if raw[0] in ("'", '"'):
        try:
            parts = shlex.split(raw, posix=True)
            return parts[0] if parts else ""
        except ValueError:
            return raw.strip("'\"")
    return raw


def quote_env(value: str) -> str:
    return "'" + value.replace("'", "'\"'\"'") + "'"


values: dict[str, str] = {}
for existing_env in existing_envs:
    for line in existing_env.read_text(encoding="utf-8", errors="replace").splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        m = key_re.match(line)
        if not m:
            continue
        key = m.group(1)
        if key in allowed_keys:
            value = parse_value(m.group(2))
            if value:
                values[key] = value

out_path.write_text(
    "".join(f"{key}={quote_env(values[key])}\n" for key in sorted(values)),
    encoding="utf-8",
)
print(len(values))
PY
  )"
fi
chmod 0600 "$provider_secret_env"

handoff_dir="${OPENCLAW_HANDOFF_DIR:-/srv/openclaw-ops/handoff}"
workspace_secret_file="$handoff_dir/hermes-workspace-${target_user}.env"
legacy_workspace_secret_file="/srv/openclaw-ops/reports/hermes-workspace-${target_user}.password"
workspace_password=""
for candidate_secret_file in "$workspace_secret_file" "$legacy_workspace_secret_file"; do
  if [[ -f "$candidate_secret_file" && ! -L "$candidate_secret_file" ]]; then
    workspace_password="$(awk -F= '$1 == "password" { sub(/^[^=]*=/, ""); print; exit }' "$candidate_secret_file" 2>/dev/null || true)"
    [[ -n "$workspace_password" ]] && break
  fi
done
if [[ -z "$workspace_password" ]]; then
  workspace_password="$(openssl rand -hex 24 2>/dev/null || python3 - <<'PY'
import secrets
print(secrets.token_hex(24))
PY
)"
fi
mkdir -p "$handoff_dir"
chown root:svcops "$handoff_dir" 2>/dev/null || chown root:root "$handoff_dir"
chmod 0750 "$handoff_dir"
{
  printf 'url=https://%s/\n' "$host"
  printf 'password=%s\n' "$workspace_password"
} > "$workspace_secret_file"
chown root:svcops "$workspace_secret_file" 2>/dev/null || chown root:root "$workspace_secret_file"
chmod 0640 "$workspace_secret_file"
if [[ -f "$legacy_workspace_secret_file" && "$legacy_workspace_secret_file" != "$workspace_secret_file" ]]; then
  rm -f "$legacy_workspace_secret_file"
fi

cat > "$compose_dir/.env" <<EOF
OPENCLAW_RUNTIME_FAMILY='hermes'
OPENCLAW_INSTANCE='$target_user'
COMPOSE_PROJECT_NAME='openclaw-$target_user'
OPENCLAW_IMAGE='$image'
OPENCLAW_GATEWAY_PORT='$workspace_port'
OPENCLAW_BRIDGE_PORT='$workspace_port'
OPENCLAW_PROXY_MODE='subdomain'
OPENCLAW_CONTROL_UI_BASEPATH='/'
OPENCLAW_PROXY_PUBLIC_ORIGIN='$origin'
OPENCLAW_PROXY_ALLOWED_ORIGINS='$origin'
OPENCLAW_NAS_HOST_PATH='$nas_mount'
OPENCLAW_NAS_CONTAINER_PATH='/workspace/nas_docs'
OPENCLAW_NAS_DATA_GID='$data_gid'
OPENCLAW_EXTRA_MOUNTS='$nas_mount:/workspace/nas_docs:ro'
HERMES_HOME='/opt/data'
HERMES_DATA_DIR='/opt/data'
HERMES_WORKSPACE_DIR='/workspace'
HERMES_API_URL='http://127.0.0.1:8642'
HERMES_DASHBOARD_URL='http://127.0.0.1:9119'
HERMES_DASHBOARD='1'
HERMES_DASHBOARD_HOST='127.0.0.1'
HERMES_DASHBOARD_PORT='9119'
HERMES_DASHBOARD_INSECURE='1'
API_SERVER_ENABLED='true'
API_SERVER_HOST='127.0.0.1'
API_SERVER_KEY='$api_key'
HERMES_API_TOKEN='$api_key'
HERMES_PASSWORD='$workspace_password'
COOKIE_SECURE='1'
TRUST_PROXY='1'
HOST='0.0.0.0'
PORT='3000'
PUID='$runtime_uid'
PGID='$runtime_gid'
HERMES_UID='$runtime_uid'
HERMES_GID='$runtime_gid'
HOME='/opt/data/home'
LANG='ko_KR.UTF-8'
LANGUAGE='ko_KR:ko'
LC_ALL='ko_KR.UTF-8'
EOF

cat > "$hermes_home/.env" <<EOF
API_SERVER_ENABLED='true'
API_SERVER_HOST='127.0.0.1'
API_SERVER_KEY='$api_key'
HERMES_API_TOKEN='$api_key'
CLAUDE_API_TOKEN='$api_key'
CLAUDE_DASHBOARD_TOKEN='$api_key'
HERMES_PASSWORD='$workspace_password'
HERMES_HOME='/opt/data'
HERMES_DATA_DIR='/opt/data'
HERMES_WORKSPACE_DIR='/workspace'
HERMES_API_URL='http://127.0.0.1:8642'
HERMES_DASHBOARD_URL='http://127.0.0.1:9119'
HERMES_DASHBOARD='1'
HERMES_DASHBOARD_HOST='127.0.0.1'
HERMES_DASHBOARD_PORT='9119'
HERMES_DASHBOARD_INSECURE='1'
COOKIE_SECURE='1'
TRUST_PROXY='1'
EOF
cat "$provider_secret_env" >> "$hermes_home/.env"
chown "$runtime_user:$data_group" "$hermes_home/.env"
chmod 0600 "$hermes_home/.env"
if python3 "$script_dir/hermes-runtime-config.py" has-gemini-key --env "$hermes_home/.env"; then
  python3 "$script_dir/hermes-runtime-config.py" set-gemini --config "$hermes_home/config.yaml"
  chown "$runtime_user:$data_group" "$hermes_home/config.yaml"
  chmod 0600 "$hermes_home/config.yaml"
else
  echo "hermes_config_update=skipped_no_gemini_key"
fi

cat > "$compose_dir/docker-compose.yml" <<EOF
services:
  openclaw-gateway:
    image: \${OPENCLAW_IMAGE:-$image}
    restart: unless-stopped
    env_file:
      - .env
    environment:
      HERMES_HOME: /opt/data
      HERMES_DATA_DIR: /opt/data
      HERMES_WORKSPACE_DIR: /workspace
      HERMES_API_URL: http://127.0.0.1:8642
      HERMES_DASHBOARD_URL: http://127.0.0.1:9119
      HERMES_DASHBOARD: "1"
      HERMES_DASHBOARD_HOST: 127.0.0.1
      HERMES_DASHBOARD_PORT: "9119"
      HERMES_DASHBOARD_INSECURE: "1"
      API_SERVER_ENABLED: "true"
      API_SERVER_HOST: 127.0.0.1
      HERMES_API_TOKEN: \${API_SERVER_KEY}
      OPENCLAW_NAS_CONTAINER_PATH: /workspace/nas_docs
      OPENCLAW_NAS_DATA_GID: "$data_gid"
      HOME: /opt/data/home
      HOST: 0.0.0.0
      PORT: "3000"
      COOKIE_SECURE: "1"
      TRUST_PROXY: "1"
      LANG: ko_KR.UTF-8
      LANGUAGE: ko_KR:ko
      LC_ALL: ko_KR.UTF-8
    ports:
      - "127.0.0.1:\${OPENCLAW_BRIDGE_PORT:-$workspace_port}:3000"
    group_add:
      - "$data_gid"
    volumes:
      - $hermes_home:/opt/data
      - $hermes_home/workspace:/workspace
      - $nas_mount:/workspace/nas_docs:ro
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
echo "workspace_port=$workspace_port"
if [[ -n "$env_backup" ]]; then
  echo "env_backup=$env_backup"
fi
echo "provider_secret_keys_preserved=$provider_secret_count"
echo "handoff_secret_file=$workspace_secret_file"
if [[ "$local_only_dashboard" -eq 1 ]]; then
  echo "workspace_exposure=local_only"
else
  echo "workspace_exposure=public_password"
fi

(
  cd "$compose_dir"
  docker compose -f docker-compose.yml up -d --force-recreate openclaw-gateway
)

docker ps --filter "name=^/${container}$" --format 'container={{.Names}} status={{.Status}}'

apache_output="/etc/apache2/openclaw/apache-subdomain-${target_user}.conf"
if [[ "$local_only_dashboard" -eq 1 && -d /etc/apache2/openclaw && -x "$(command -v apache2ctl || true)" ]]; then
  tmp_apache="$(mktemp)"
  cat > "$tmp_apache" <<EOF
# Hermes Workspace local-only - ${target_user}
# Public access is intentionally disabled. Use an SSH tunnel to 127.0.0.1:${workspace_port}.
<VirtualHost *:443>
    ServerName ${host}

    SSLEngine on
    SSLCertificateFile      /etc/letsencrypt/live/${base_domain}/fullchain.pem
    SSLCertificateKeyFile   /etc/letsencrypt/live/${base_domain}/privkey.pem

    <Location />
        Require all denied
    </Location>

    ErrorDocument 403 "Hermes Workspace is local-only. Use SSH tunnel to 127.0.0.1:${workspace_port}."
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
elif [[ -d /etc/apache2/openclaw && -x "$(command -v apache2ctl || true)" ]]; then
  bash "$script_dir/write-apache-proxy-conf.sh" \
    --user "$target_user" \
    --mode subdomain \
    --host "$host" \
    --base-domain "$base_domain" \
    --port "$workspace_port" \
    --output "$apache_output" \
    --apply \
    --reload
else
  bash "$script_dir/write-apache-proxy-conf.sh" \
    --user "$target_user" \
    --mode subdomain \
    --host "$host" \
    --base-domain "$base_domain" \
    --port "$workspace_port" \
    --apply
fi
