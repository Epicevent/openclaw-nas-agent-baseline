#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  apply-runtime-secrets.sh --user USER --env-file FILE [options]

Applies provider/API secrets after a customer slot already exists. This is the
production secret injection and rotation path. Fresh install does not depend on
this file and this script never calls legacy install-env importers.

Options:
  --user USER           Target customer slot, for example oc20. Required.
  --env-file FILE       Root-owned env file with runtime secrets. Required.
  --host HOST           Public subdomain. Default: USER.BASE_DOMAIN.
  --base-domain NAME    Base domain. Default: ji-tech.co.kr.
  --runtime-user USER   Runtime account. Default: USER_rt.
  --no-restart          Update files only; do not recreate the gateway.
  --check               Run deployment check after restart/update.

The env file must be a regular root:root file and must not be readable or
writable by group/other. Only allowlisted provider/API key names are accepted.
Secret values are never printed.
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

OPENCLAW_SECRET_ENV_FILE="$env_file" \
OPENCLAW_SECRET_RUNTIME_ENV_PATH="$compose_dir/.env" \
OPENCLAW_SECRET_CONFIG_PATH="$target_home/.openclaw/openclaw.json" \
python3 - <<'PY'
import json
import os
import re
import shlex
import sys
from pathlib import Path

env_file = Path(os.environ["OPENCLAW_SECRET_ENV_FILE"])
runtime_env_path = Path(os.environ["OPENCLAW_SECRET_RUNTIME_ENV_PATH"])
config_path = Path(os.environ["OPENCLAW_SECRET_CONFIG_PATH"])

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


def parse_env(path: Path) -> dict[str, str]:
    out: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.lstrip("\ufeff")
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        m = key_re.match(line)
        if not m:
            print(f"error: unsupported env syntax in {path}", file=sys.stderr)
            raise SystemExit(2)
        key, raw = m.group(1), m.group(2)
        out[key] = parse_value(raw)
    return out


def quote_env(value: str) -> str:
    return "'" + value.replace("'", "'\"'\"'") + "'"


def upsert_env_file(path: Path, values: dict[str, str]) -> None:
    existing_lines: list[str] = []
    seen: set[str] = set()
    if path.exists():
        existing_lines = path.read_text(encoding="utf-8", errors="replace").splitlines()

    new_lines: list[str] = []
    for line in existing_lines:
        m = key_re.match(line)
        if not m:
            new_lines.append(line)
            continue
        key = m.group(1)
        if key in values:
            new_lines.append(f"{key}={quote_env(values[key])}")
            seen.add(key)
        else:
            new_lines.append(line)

    for key in sorted(values):
        if key not in seen:
            new_lines.append(f"{key}={quote_env(values[key])}")

    path.write_text("\n".join(new_lines) + "\n", encoding="utf-8")
    path.chmod(0o600)


def strip_literal_api_keys(value) -> int:
    removed = 0
    if isinstance(value, dict):
        for key in list(value):
            if key == "apiKey":
                del value[key]
                removed += 1
            else:
                removed += strip_literal_api_keys(value[key])
    elif isinstance(value, list):
        for item in value:
            removed += strip_literal_api_keys(item)
    return removed


parsed = parse_env(env_file)
unknown = sorted(set(parsed) - allowed_keys)
if unknown:
    print("error: unsupported runtime secret key(s): " + ", ".join(unknown), file=sys.stderr)
    print(
        "hint: this path accepts provider/API secret keys only; use root runtime/config scripts for policy changes.",
        file=sys.stderr,
    )
    raise SystemExit(2)

values = {key: value for key, value in parsed.items() if value}
if not values:
    print("error: no supported runtime secret keys found", file=sys.stderr)
    raise SystemExit(2)

upsert_env_file(runtime_env_path, values)

removed_api_keys = 0
if config_path.exists():
    data = json.loads(config_path.read_text(encoding="utf-8") or "{}")
    removed_api_keys = strip_literal_api_keys(data)
    if removed_api_keys:
        config_path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        config_path.chmod(0o600)

summary = {
    "updated_runtime_env": str(runtime_env_path),
    "secret_keys_imported": sorted(values),
    "literal_api_keys_removed_from_config": removed_api_keys,
}
print(json.dumps(summary, indent=2, ensure_ascii=False))
PY

chown root:root "$compose_dir/.env"
chmod 0600 "$compose_dir/.env"
if [[ -f "$target_home/.openclaw/openclaw.json" ]]; then
  chown "$runtime_user:$runtime_user" "$target_home/.openclaw/openclaw.json"
  chmod 0600 "$target_home/.openclaw/openclaw.json"
fi
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
