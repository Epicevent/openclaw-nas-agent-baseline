#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  apply-ollama-heartbeat-config.sh --user USER [options]

Configures OpenClaw heartbeat runs to use a local Ollama OpenAI-compatible
provider. Provider/API keys are not written to openclaw.json.

Options:
  --user USER             Target customer slot, for example oc20. Required.
  --model MODEL           Ollama model. Default: gemma2:2b.
  --provider-id ID        OpenClaw provider id. Default: local-ollama.
  --base-url URL          OpenAI-compatible base URL. Default: http://host.docker.internal:11434/v1.
  --every DURATION        Heartbeat interval. Default: 30m.
  --main-model MODEL      Optional primary model, for example google/gemini-1.5-pro.
  --no-restart            Update files only; do not recreate gateway.

Run as root/admin.
USAGE
}

target_user=""
ollama_model="gemma2:2b"
provider_id="local-ollama"
base_url="http://host.docker.internal:11434/v1"
heartbeat_every="30m"
main_model=""
restart_gateway=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user)
      target_user="${2:?missing --user value}"
      shift 2
      ;;
    --model)
      ollama_model="${2:?missing --model value}"
      shift 2
      ;;
    --provider-id)
      provider_id="${2:?missing --provider-id value}"
      shift 2
      ;;
    --base-url)
      base_url="${2:?missing --base-url value}"
      shift 2
      ;;
    --every)
      heartbeat_every="${2:?missing --every value}"
      shift 2
      ;;
    --main-model)
      main_model="${2:?missing --main-model value}"
      shift 2
      ;;
    --no-restart)
      restart_gateway=0
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

if [[ ! "$target_user" =~ ^oc[1-9][0-9]*$ ]]; then
  echo "error: invalid user name: $target_user" >&2
  exit 2
fi

if [[ ! "$provider_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]; then
  echo "error: invalid provider id: $provider_id" >&2
  exit 2
fi

if [[ ! "$ollama_model" =~ ^[A-Za-z0-9][A-Za-z0-9._:+/-]{0,127}$ ]]; then
  echo "error: invalid model name: $ollama_model" >&2
  exit 2
fi

if [[ ! "$heartbeat_every" =~ ^([0-9]+)(ms|s|m|h)$ ]]; then
  echo "error: invalid heartbeat interval: $heartbeat_every" >&2
  exit 2
fi

if [[ -n "$main_model" && ! "$main_model" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._:+/-]{0,127}$ ]]; then
  echo "error: invalid main model ref: $main_model" >&2
  exit 2
fi

case "$base_url" in
  http://*|https://*) ;;
  *)
    echo "error: base URL must start with http:// or https://: $base_url" >&2
    exit 2
    ;;
esac

base_host_port="$(
  OPENCLAW_OLLAMA_BASE_URL="$base_url" python3 - <<'PY'
import os
from urllib.parse import urlparse

url = urlparse(os.environ["OPENCLAW_OLLAMA_BASE_URL"])
host = url.hostname or ""
port = url.port or (443 if url.scheme == "https" else 80)
print(f"{host}:{port}")
PY
)"
base_host="${base_host_port%:*}"
base_port="${base_host_port##*:}"
docker_bridge_ip="$(ip -4 addr show docker0 2>/dev/null | sed -n 's/.*inet \([^/ ]*\).*/\1/p' | head -1 || true)"

if [[ "$base_host" == "host.docker.internal" ]] && command -v ss >/dev/null 2>&1; then
  if ! ss -ltn | awk -v p=":$base_port" '
    $4 ~ p "$" && ($4 ~ /^0\.0\.0\.0:/ || $4 ~ /^\[::\]:/ || $4 ~ /^172\.17\.0\.1:/) { found = 1 }
    END { exit found ? 0 : 1 }
  '; then
    echo "error: Ollama is not reachable from Docker containers at $base_url" >&2
    echo "hint: current Linux Docker containers cannot reach a service bound only to 127.0.0.1." >&2
    echo "hint: bind Ollama to the Docker bridge address, then retry." >&2
    exit 1
  fi
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-safe-compose.sh
source "$script_dir/lib-safe-compose.sh"

target_home="$(getent passwd "$target_user" | cut -d: -f6)"
if [[ -z "$target_home" ]]; then
  echo "error: user not found: $target_user" >&2
  exit 1
fi

runtime_user="${target_user}_rt"
if ! id "$runtime_user" >/dev/null 2>&1; then
  echo "error: runtime user not found: $runtime_user" >&2
  exit 1
fi

compose_dir="$target_home/openclaw"
config_path="$target_home/.openclaw/openclaw.json"
container="openclaw-${target_user}-openclaw-gateway-1"

echo "target_user=$target_user"
echo "target_home=$target_home"
echo "provider_id=$provider_id"
echo "ollama_model=$ollama_model"
echo "base_url=$base_url"
echo "heartbeat_every=$heartbeat_every"
[[ -n "$main_model" ]] && echo "main_model=$main_model" || echo "main_model=preserve"
echo "config_api_key=not_written"

openclaw_assert_managed_slot_prewrite "$target_user"
openclaw_assert_safe_compose_dir "$target_user" "$compose_dir"
openclaw_assert_safe_openclaw_config_file "$target_user" "$config_path"

host_ollama_ok=unknown
if command -v python3 >/dev/null 2>&1; then
  if OPENCLAW_OLLAMA_MODEL="$ollama_model" \
    OPENCLAW_OLLAMA_BASE_SCHEME="${base_url%%://*}" \
    OPENCLAW_OLLAMA_BASE_HOST="$base_host" \
    OPENCLAW_OLLAMA_BASE_PORT="$base_port" \
    OPENCLAW_DOCKER_BRIDGE_IP="$docker_bridge_ip" \
    python3 - <<'PY'
import json
import os
import urllib.request

model = os.environ["OPENCLAW_OLLAMA_MODEL"]
scheme = os.environ["OPENCLAW_OLLAMA_BASE_SCHEME"] or "http"
host = os.environ["OPENCLAW_OLLAMA_BASE_HOST"]
port = os.environ["OPENCLAW_OLLAMA_BASE_PORT"]
bridge = os.environ.get("OPENCLAW_DOCKER_BRIDGE_IP", "")

hosts = []
if host in {"host.docker.internal", "localhost", "127.0.0.1"}:
    hosts.extend(["127.0.0.1", "localhost"])
    if bridge:
        hosts.append(bridge)
else:
    hosts.append(host)

data = None
last_error = None
for candidate in dict.fromkeys(hosts):
    try:
        with urllib.request.urlopen(f"{scheme}://{candidate}:{port}/api/tags", timeout=5) as response:
            data = json.load(response)
        break
    except Exception as exc:
        last_error = exc

if data is None:
    print("host_ollama_probe_error=" + (last_error.__class__.__name__ if last_error else "unknown"))
    raise SystemExit(1)

names = {item.get("name") or item.get("model") for item in data.get("models", [])}
raise SystemExit(0 if model in names else 2)
PY
  then
    host_ollama_ok=yes
  else
    rc=$?
    if [[ "$rc" -eq 2 ]]; then
      echo "error: host Ollama model missing: $ollama_model" >&2
    else
      echo "error: host Ollama unreachable for base URL: $base_url" >&2
    fi
    exit 1
  fi
fi
echo "host_ollama_model_present=$host_ollama_ok"

cat > "$compose_dir/docker-compose.ollama.yml" <<'EOF'
services:
  openclaw-gateway:
    extra_hosts:
      - "host.docker.internal:host-gateway"
  openclaw-cli:
    extra_hosts:
      - "host.docker.internal:host-gateway"
EOF
chown root:root "$compose_dir/docker-compose.ollama.yml"
chmod 0644 "$compose_dir/docker-compose.ollama.yml"

OPENCLAW_CONFIG_PATH="$config_path" \
OPENCLAW_OLLAMA_PROVIDER_ID="$provider_id" \
OPENCLAW_OLLAMA_BASE_URL="$base_url" \
OPENCLAW_OLLAMA_MODEL="$ollama_model" \
OPENCLAW_HEARTBEAT_EVERY="$heartbeat_every" \
OPENCLAW_MAIN_MODEL="$main_model" \
python3 - <<'PY'
import json
import os
import stat
from pathlib import Path

path = Path(os.environ["OPENCLAW_CONFIG_PATH"])
provider_id = os.environ["OPENCLAW_OLLAMA_PROVIDER_ID"]
base_url = os.environ["OPENCLAW_OLLAMA_BASE_URL"].rstrip("/")
model = os.environ["OPENCLAW_OLLAMA_MODEL"]
heartbeat_every = os.environ["OPENCLAW_HEARTBEAT_EVERY"]
main_model = os.environ.get("OPENCLAW_MAIN_MODEL", "").strip()
model_ref = f"{provider_id}/{model}"


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


def strip_api_key(value) -> int:
    removed = 0
    if isinstance(value, dict):
        for key in list(value):
            if key == "apiKey":
                del value[key]
                removed += 1
            else:
                removed += strip_api_key(value[key])
    elif isinstance(value, list):
        for item in value:
            removed += strip_api_key(item)
    return removed


data = json.loads(path.read_text(encoding="utf-8") or "{}")
removed = strip_api_key(data)

models = data.setdefault("models", {})
models.setdefault("mode", "merge")
providers = models.setdefault("providers", {})
providers[provider_id] = {
    "baseUrl": base_url,
    "api": "openai-completions",
    "timeoutSeconds": 120,
    "models": [
        {
            "id": model,
            "name": f"Ollama {model}",
            "reasoning": False,
            "input": ["text"],
            "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0},
            "contextWindow": 8192,
            "contextTokens": 4096,
            "maxTokens": 2048,
            "compat": {
                "supportsDeveloperRole": False,
                "requiresStringContent": True,
                "strictMessageKeys": True,
            },
        }
    ],
}

agents = data.setdefault("agents", {})
defaults = agents.setdefault("defaults", {})
if main_model:
    current = defaults.get("model")
    if isinstance(current, dict):
        current["primary"] = main_model
        defaults["model"] = current
    else:
        defaults["model"] = {"primary": main_model}
catalog = defaults.setdefault("models", {})
catalog.setdefault(model_ref, {"alias": f"Ollama {model}"})
if main_model:
    catalog.setdefault(main_model, {})
defaults["heartbeat"] = {
    "every": heartbeat_every,
    "model": model_ref,
    "includeReasoning": False,
    "includeSystemPromptSection": True,
    "lightContext": True,
    "isolatedSession": True,
    "skipWhenBusy": True,
}
agent_entries = agents.get("list")
agent_overrides_updated = 0
if isinstance(agent_entries, list):
    for entry in agent_entries:
        if not isinstance(entry, dict):
            continue
        heartbeat = entry.get("heartbeat")
        if isinstance(heartbeat, dict):
            heartbeat["every"] = heartbeat_every
            heartbeat["model"] = model_ref
            heartbeat.setdefault("includeReasoning", False)
            heartbeat.setdefault("includeSystemPromptSection", True)
            heartbeat.setdefault("lightContext", True)
            heartbeat.setdefault("isolatedSession", True)
            heartbeat.setdefault("skipWhenBusy", True)
            agent_overrides_updated += 1

safe_write_regular(path, json.dumps(data, indent=2, ensure_ascii=False) + "\n")
print(f"updated_config={path}")
print(f"heartbeat_model={model_ref}")
print(f"heartbeat_agent_overrides_updated={agent_overrides_updated}")
print(f"literal_api_keys_removed={removed}")
PY

chown "$runtime_user:$runtime_user" "$config_path"
chmod 0600 "$config_path"
openclaw_assert_safe_openclaw_config_file "$target_user" "$config_path"
openclaw_assert_safe_compose_dir "$target_user" "$compose_dir"

if [[ "$restart_gateway" -eq 1 ]]; then
  echo "== docker compose force-recreate gateway =="
  (
    cd "$compose_dir"
    export COMPOSE_PROJECT_NAME="openclaw-$target_user"
    docker compose \
      -f docker-compose.yml \
      -f docker-compose.ollama.yml \
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

  if command -v python3 >/dev/null 2>&1; then
    if docker exec -e OPENCLAW_OLLAMA_BASE_URL="$base_url" -e OPENCLAW_OLLAMA_MODEL="$ollama_model" "$container" python3 - <<'PY'
import json
import os
import urllib.request

base = os.environ["OPENCLAW_OLLAMA_BASE_URL"].rstrip("/")
model = os.environ["OPENCLAW_OLLAMA_MODEL"]
try:
    with urllib.request.urlopen(base + "/models", timeout=8) as response:
        data = json.load(response)
except Exception as exc:
    print("container_ollama_reachable=no")
    print("container_ollama_error=" + exc.__class__.__name__)
    raise SystemExit(1)

ids = {item.get("id") for item in data.get("data", []) if isinstance(item, dict)}
print("container_ollama_reachable=yes")
print("container_ollama_model_present=" + ("yes" if model in ids else "no"))
raise SystemExit(0 if model in ids else 1)
PY
    then
      :
    else
      echo "error: container Ollama check failed for $base_url model=$ollama_model" >&2
      exit 1
    fi
  fi
else
  echo "restart=skipped"
fi

echo "done"
