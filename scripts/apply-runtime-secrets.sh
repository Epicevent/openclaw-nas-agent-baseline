#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  apply-runtime-secrets.sh --user USER --env-file FILE [options]

Applies provider/runtime secrets after a customer slot already exists. This is
the production secret injection and rotation path. Fresh install does not
depend on this file.

Options:
  --user USER           Target customer slot, for example oc20. Required.
  --env-file FILE       Root-owned env file with runtime secrets. Required.
  --host HOST           Public subdomain. Default: USER.BASE_DOMAIN.
  --base-domain NAME    Base domain. Default: ji-tech.co.kr.
  --runtime-user USER   Runtime account. Default: USER_rt.
  --no-restart          Update files only; do not recreate the gateway.
  --check               Run deployment check after restart/update.

The env file must be a regular root:root file and must not be readable or
writable by group/other. Secret values are never printed.
USAGE
}

target_user=""
env_file=""
host=""
base_domain="${OPENCLAW_BASE_DOMAIN:-ji-tech.co.kr}"
runtime_user=""
restart_gateway=1
run_check=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user)
      target_user="${2:?missing --user value}"
      shift 2
      ;;
    --env-file)
      env_file="${2:?missing --env-file value}"
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
    --runtime-user)
      runtime_user="${2:?missing --runtime-user value}"
      shift 2
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

if [[ -z "$target_user" || -z "$env_file" ]]; then
  echo "error: --user and --env-file are required" >&2
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
if [[ -z "$target_home" ]]; then
  echo "error: user not found: $target_user" >&2
  exit 1
fi

runtime_user="${runtime_user:-${target_user}_rt}"
if ! id "$runtime_user" >/dev/null 2>&1; then
  echo "error: runtime user not found: $runtime_user" >&2
  exit 1
fi

host="${host:-${target_user}.${base_domain}}"
origin="https://${host}"
compose_dir="$target_home/openclaw"
container="openclaw-${target_user}-openclaw-gateway-1"

if [[ ! "$host" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$ ]]; then
  echo "error: invalid host: $host" >&2
  exit 2
fi

if [[ ! -f "$env_file" ]]; then
  echo "error: env file not found: $env_file" >&2
  exit 1
fi
if [[ -L "$env_file" ]]; then
  echo "error: env file must not be a symlink: $env_file" >&2
  exit 1
fi
if [[ "$(stat -c '%U:%G' "$env_file" 2>/dev/null || true)" != "root:root" ]]; then
  echo "error: env file must be root:root: $env_file" >&2
  exit 1
fi
if find "$env_file" -maxdepth 0 -perm /077 2>/dev/null | grep -q .; then
  echo "error: env file must be mode 0600 or stricter: $env_file" >&2
  exit 1
fi

echo "target_user=$target_user"
echo "target_home=$target_home"
echo "runtime_user=$runtime_user"
echo "host=$host"
echo "env_file=$env_file"

openclaw_assert_managed_slot_prewrite "$target_user"
openclaw_assert_safe_compose_dir "$target_user" "$compose_dir"

bash "$script_dir/apply-openclaw-install-env.sh" \
  --env-file "$env_file" \
  --user "$target_user" \
  --runtime-user "$runtime_user"

chown root:root "$compose_dir/.env"
chmod 0600 "$compose_dir/.env"
openclaw_assert_safe_compose_dir "$target_user" "$compose_dir"

if [[ "$restart_gateway" -eq 1 ]]; then
  echo "== docker compose force-recreate gateway =="
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
else
  echo "restart=skipped"
fi

if [[ "$run_check" -eq 1 ]]; then
  bash "$script_dir/check-customer-deployment.sh" \
    --user "$target_user" \
    --expected-basepath / \
    --expected-origin "$origin"
fi

echo "done"
