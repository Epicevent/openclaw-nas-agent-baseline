#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  apply-subdomain-mode.sh --user USER [options]

Converts an existing OpenClaw customer account to subdomain mode:

  - sets gateway.controlUi.basePath="/"
  - sets allowedOrigins to https://USER.BASE_DOMAIN, unless --host is passed
  - writes runtime env values into /home/USER/openclaw/.env
  - writes deploy/apache-subdomain-USER.conf
  - force-recreates the OpenClaw gateway container

Options:
  --user USER          Target account, for example oc3. Required.
  --host HOST          Public host. Default: USER.BASE_DOMAIN.
  --base-domain NAME   Base domain. Default: ji-tech.co.kr.
  --no-apache-conf     Do not write deploy/apache-subdomain-USER.conf.
  --no-recreate        Do not force-recreate the gateway container.

Run as root/admin.
USAGE
}

target_user=""
host=""
base_domain="${OPENCLAW_BASE_DOMAIN:-ji-tech.co.kr}"
write_apache=1
recreate=1

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
    --no-apache-conf)
      write_apache=0
      shift
      ;;
    --no-recreate)
      recreate=0
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

target_home="$(getent passwd "$target_user" | cut -d: -f6)"
if [[ -z "$target_home" ]]; then
  echo "error: user not found: $target_user" >&2
  exit 1
fi

if [[ -z "$host" ]]; then
  host="${target_user}.${base_domain}"
fi

origin="https://${host}"
config_path="$target_home/.openclaw/openclaw.json"
runtime_env_path="$target_home/openclaw/.env"
compose_dir="$target_home/openclaw"
container="openclaw-${target_user}-openclaw-gateway-1"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-safe-compose.sh
source "$script_dir/lib-safe-compose.sh"

if [[ ! "$target_user" =~ ^oc[1-9][0-9]*$ ]]; then
  echo "error: invalid user name: $target_user" >&2
  exit 2
fi

if [[ ! "$host" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$ ]]; then
  echo "error: invalid host: $host" >&2
  exit 2
fi

if [[ ! -d "$compose_dir" ]]; then
  echo "error: missing compose dir: $compose_dir" >&2
  exit 1
fi

openclaw_assert_managed_slot_prewrite "$target_user"
openclaw_assert_safe_openclaw_config_file "$target_user" "$config_path"
openclaw_assert_safe_compose_dir "$target_user" "$compose_dir"

if [[ ! -f "$config_path" ]]; then
  echo "error: missing config: $config_path" >&2
  exit 1
fi

backup_dir="$(mktemp -d "/tmp/openclaw-subdomain-mode-backup.${target_user}.XXXXXX")"
chmod 0700 "$backup_dir"
cp -a "$config_path" "$backup_dir/openclaw.json.bak"
if [[ -f "$runtime_env_path" ]]; then
  cp -a "$runtime_env_path" "$backup_dir/env.bak"
fi

echo "target_user=$target_user"
echo "target_home=$target_home"
echo "host=$host"
echo "origin=$origin"
echo "backup_dir=$backup_dir"

SUBDOMAIN_CONFIG_PATH="$config_path" \
SUBDOMAIN_RUNTIME_ENV_PATH="$runtime_env_path" \
SUBDOMAIN_ORIGIN="$origin" \
python3 - <<'PY'
import json
import os
import stat
from pathlib import Path

config_path = Path(os.environ["SUBDOMAIN_CONFIG_PATH"])
runtime_env_path = Path(os.environ["SUBDOMAIN_RUNTIME_ENV_PATH"])
origin = os.environ["SUBDOMAIN_ORIGIN"].rstrip("/")


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

data = json.loads(config_path.read_text(encoding="utf-8") or "{}")
control = data.setdefault("gateway", {}).setdefault("controlUi", {})
control["basePath"] = "/"
control["dangerouslyDisableDeviceAuth"] = True
control["allowedOrigins"] = [origin]
control.pop("autoApproveWithToken", None)
safe_write_regular(config_path, json.dumps(data, indent=2, ensure_ascii=False) + "\n")

runtime_values = {
    "OPENCLAW_PROXY_MODE": "subdomain",
    "OPENCLAW_CONTROL_UI_BASEPATH": "/",
    "OPENCLAW_CONTROL_UI_DISABLE_DEVICE_AUTH": "1",
    "OPENCLAW_PROXY_PUBLIC_ORIGIN": origin,
    "OPENCLAW_PROXY_ALLOWED_ORIGINS": origin,
}

def quote(value: str) -> str:
    return "'" + value.replace("'", "'\"'\"'") + "'"

lines = []
seen = set()
if runtime_env_path.exists():
    lines = runtime_env_path.read_text(encoding="utf-8", errors="replace").splitlines()

out = []
for line in lines:
    stripped = line.strip()
    key = stripped.split("=", 1)[0] if "=" in stripped else ""
    if key in runtime_values:
        out.append(f"{key}={quote(runtime_values[key])}")
        seen.add(key)
    else:
        out.append(line)

for key in sorted(runtime_values):
    if key not in seen:
        out.append(f"{key}={quote(runtime_values[key])}")

runtime_env_path.parent.mkdir(parents=True, exist_ok=True)
safe_write_regular(runtime_env_path, "\n".join(out) + "\n")
PY

echo "updated_config=$config_path"
echo "updated_runtime_env=$runtime_env_path"

if [[ "$write_apache" -eq 1 ]]; then
  bash "$script_dir/write-apache-proxy-conf.sh" \
    --user "$target_user" \
    --mode subdomain \
    --host "$host" \
    --base-domain "$base_domain" \
    --apply
fi

if [[ "$recreate" -eq 1 ]]; then
  echo "== docker compose force-recreate gateway =="
  openclaw_assert_safe_compose_dir "$target_user" "$compose_dir"
  cd "$compose_dir"
  compose_args=(-f docker-compose.yml)
  [[ -f docker-compose.extra.yml ]] && compose_args+=(-f docker-compose.extra.yml)
  [[ -f docker-compose.host-user.yml ]] && compose_args+=(-f docker-compose.host-user.yml)
  [[ -f docker-compose.shared-ollama.yml ]] && compose_args+=(-f docker-compose.shared-ollama.yml)
  [[ -f docker-compose.sandbox.yml ]] && compose_args+=(-f docker-compose.sandbox.yml)
  docker compose "${compose_args[@]}" up -d --force-recreate openclaw-gateway
  docker ps --filter "name=^/${container}$" --format 'container={{.Names}} status={{.Status}}'
fi

echo "done"
