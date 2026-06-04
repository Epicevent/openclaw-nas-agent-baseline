#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  apply-ollama-provider-config.sh --user USER --model MODEL [options]

Registers the shared Ollama OpenAI-compatible provider in a customer slot.
This makes the local model available to OpenClaw without changing heartbeat.

Options:
  --user USER          Target customer slot, for example oc1. Required.
  --model MODEL        Ollama model, for example qwen2.5-coder:7b. Required.
  --provider-id ID     OpenClaw provider id. Default: local-ollama.
  --base-url URL       OpenAI-compatible base URL. Default: shared Ollama container URL.
  --set-default        Make this local model the default primary model.
  --no-restart         Update files only; do not recreate gateway.

Run as root/admin.
USAGE
}

target_user=""
ollama_model=""
provider_id="local-ollama"
base_url=""
set_default=0
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
    --set-default)
      set_default=1
      shift
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

if [[ -z "$target_user" || -z "$ollama_model" ]]; then
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

case "$base_url" in
  "")
    ;;
  http://*|https://*) ;;
  *)
    echo "error: base URL must start with http:// or https://: $base_url" >&2
    exit 2
    ;;
esac

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/internal/lib-safe-compose.bash
source "$script_dir/lib-safe-compose.bash"
# shellcheck source=scripts/internal/lib-ollama.bash
source "$script_dir/lib-ollama.bash"

base_url="${base_url:-$(openclaw_ollama_container_base_url)}"
host_probe_base_url="$(openclaw_ollama_host_probe_base_url "$base_url")"
case "$base_url" in
  http://*|https://*) ;;
  *)
    echo "error: base URL must start with http:// or https://: $base_url" >&2
    exit 2
    ;;
esac
case "$host_probe_base_url" in
  http://*|https://*) ;;
  *)
    echo "error: host probe URL must start with http:// or https://: $host_probe_base_url" >&2
    exit 2
    ;;
esac

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
model_ref="$provider_id/$ollama_model"

echo "target_user=$target_user"
echo "target_home=$target_home"
echo "provider_id=$provider_id"
echo "ollama_model=$ollama_model"
echo "model_ref=$model_ref"
echo "base_url=$base_url"
echo "host_probe_base_url=$host_probe_base_url"
echo "set_default=$([[ "$set_default" -eq 1 ]] && echo yes || echo no)"
echo "config_api_key=not_written"

openclaw_assert_managed_slot_prewrite "$target_user"
openclaw_assert_safe_compose_dir "$target_user" "$compose_dir"
openclaw_assert_safe_openclaw_config_file "$target_user" "$config_path"
case "$base_url" in
  http://$(openclaw_ollama_network_alias):*|http://$(openclaw_ollama_network_alias)/*)
    openclaw_assert_shared_ollama_network
    openclaw_write_shared_ollama_compose_override "$target_user" "$compose_dir"
    ;;
esac
openclaw_assert_safe_compose_dir "$target_user" "$compose_dir"

if command -v python3 >/dev/null 2>&1; then
  if OPENCLAW_OLLAMA_MODEL="$ollama_model" \
    OPENCLAW_OLLAMA_BASE_URL="$host_probe_base_url" \
    python3 - <<'PY'
import json
import os
from urllib.parse import urlparse
import urllib.request

model = os.environ["OPENCLAW_OLLAMA_MODEL"]
base = os.environ["OPENCLAW_OLLAMA_BASE_URL"].rstrip("/")
url = urlparse(base)
root = f"{url.scheme}://{url.netloc}"

try:
    with urllib.request.urlopen(root + "/api/tags", timeout=5) as response:
        data = json.load(response)
except Exception as exc:
    print("shared_ollama_probe_error=" + exc.__class__.__name__)
    raise SystemExit(1)

names = {item.get("name") or item.get("model") for item in data.get("models", [])}
raise SystemExit(0 if model in names else 2)
PY
  then
    echo "shared_ollama_model_present=yes"
  else
    rc=$?
    if [[ "$rc" -eq 2 ]]; then
      echo "error: shared Ollama model missing: $ollama_model" >&2
    else
      echo "error: shared Ollama unreachable for host probe URL: $host_probe_base_url" >&2
    fi
    exit 1
  fi
fi

OPENCLAW_CONFIG_PATH="$config_path" \
OPENCLAW_OLLAMA_PROVIDER_ID="$provider_id" \
OPENCLAW_OLLAMA_BASE_URL="$base_url" \
OPENCLAW_OLLAMA_MODEL="$ollama_model" \
OPENCLAW_SET_DEFAULT="$set_default" \
python3 - <<'PY'
import json
import os
import stat
from pathlib import Path

path = Path(os.environ["OPENCLAW_CONFIG_PATH"])
provider_id = os.environ["OPENCLAW_OLLAMA_PROVIDER_ID"]
base_url = os.environ["OPENCLAW_OLLAMA_BASE_URL"].rstrip("/")
model = os.environ["OPENCLAW_OLLAMA_MODEL"]
set_default = os.environ["OPENCLAW_SET_DEFAULT"] == "1"
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
catalog = defaults.setdefault("models", {})
catalog.setdefault(model_ref, {"alias": f"Ollama {model}"})

if set_default:
    current = defaults.get("model")
    if isinstance(current, dict):
        current["primary"] = model_ref
        defaults["model"] = current
    else:
        defaults["model"] = {"primary": model_ref}

safe_write_regular(path, json.dumps(data, indent=2, ensure_ascii=False) + "\n")
print(f"updated_config={path}")
print(f"registered_model={model_ref}")
print(f"default_model={'set' if set_default else 'preserved'}")
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
    compose_args=(-f docker-compose.yml)
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

  docker exec -i -e OPENCLAW_OLLAMA_BASE_URL="$base_url" -e OPENCLAW_OLLAMA_MODEL="$ollama_model" "$container" python3 - <<'PY'
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
else
  echo "restart=skipped"
fi

echo "done"
