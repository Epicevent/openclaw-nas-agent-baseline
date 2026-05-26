#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  manage-shared-ollama.sh status
  manage-shared-ollama.sh up --model MODEL [options]
  manage-shared-ollama.sh usage [--since WINDOW] [--user USER]
  manage-shared-ollama.sh smoke --user USER [--model MODEL]

Runs one shared Ollama container for OpenClaw heartbeat traffic.

Options for up:
  --model MODEL       Model to ensure, for example qwen2.5-coder:7b. Required.
  --image IMAGE       Ollama image. Default: ollama/ollama:0.17.7.
  --bind IP           Host bind address. Default: docker0 IPv4 address.
  --port PORT         Host port. Default: 11434.
  --models-dir DIR    Host model store. Default: /srv/openclaw-ollama/models.
  --no-pull-model     Start service but do not pull/check the model.

Run as root/admin through svcops-control.sh.
USAGE
}

container_name="openclaw-shared-ollama"
state_dir="/srv/openclaw-ollama"
endpoint_file="$state_dir/endpoint.env"
image="ollama/ollama:0.17.7"
model=""
bind_ip=""
port="11434"
models_dir="$state_dir/models"
pull_model=1

die() {
  echo "error: $*" >&2
  exit 1
}

docker0_ip() {
  ip -4 addr show docker0 2>/dev/null | sed -n 's/.*inet \([^/ ]*\).*/\1/p' | head -1
}

validate_model() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._:+/-]{0,127}$ ]] || die "invalid model: $1"
}

validate_image() {
  [[ "$1" =~ ^[A-Za-z0-9./:_-]+$ ]] || die "invalid image: $1"
}

validate_bind() {
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "invalid bind IP: $1"
  [[ "$1" != "0.0.0.0" ]] || die "0.0.0.0 is not allowed for shared Ollama"
}

validate_port() {
  [[ "$1" =~ ^[0-9]+$ && "$1" -ge 1 && "$1" -le 65535 ]] || die "invalid port: $1"
}

validate_since_window() {
  [[ "$1" =~ ^[A-Za-z0-9:TZ+_.-]+$ ]] || die "invalid since window: $1"
}

validate_user() {
  [[ "$1" =~ ^oc[1-9][0-9]*$ ]] || die "invalid user: $1"
}

docker_since_window() {
  local value="$1" n
  if [[ "$value" =~ ^([0-9]+)d$ ]]; then
    n="${BASH_REMATCH[1]}"
    printf '%sh' "$((n * 24))"
  else
    printf '%s' "$value"
  fi
}

read_endpoint_value() {
  local key="$1"
  awk -F= -v k="$key" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$endpoint_file" 2>/dev/null || true
}

wait_for_ollama() {
  local base="http://$bind_ip:$port"
  local i
  for i in $(seq 1 60); do
    if curl -fsS "$base/api/tags" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

print_status() {
  local endpoint_model endpoint_url endpoint_image status image_ref listener
  endpoint_url="$(read_endpoint_value OPENCLAW_SHARED_OLLAMA_BASE_URL)"
  endpoint_model="$(read_endpoint_value OPENCLAW_SHARED_OLLAMA_MODEL)"
  endpoint_image="$(read_endpoint_value OPENCLAW_SHARED_OLLAMA_IMAGE)"
  status="$(docker inspect "$container_name" --format '{{.State.Status}}' 2>/dev/null || true)"
  image_ref="$(docker inspect "$container_name" --format '{{.Config.Image}}' 2>/dev/null || true)"
  listener="$(ss -ltn 2>/dev/null | awk -v p=":$port" '$4 ~ p "$" { print $4 }' | tr '\n' ' ')"

  echo "container=$container_name"
  echo "container_status=${status:-missing}"
  echo "container_image=${image_ref:-missing}"
  echo "models_dir=$models_dir"
  echo "endpoint_file=$endpoint_file"
  echo "endpoint_url=${endpoint_url:-missing}"
  echo "endpoint_model=${endpoint_model:-missing}"
  echo "endpoint_image=${endpoint_image:-missing}"
  echo "listeners=${listener:-none}"
  if [[ "$status" == "running" ]]; then
    docker exec "$container_name" ollama list || true
  fi
}

print_usage() {
  local since="$1" target_user="$2" docker_since status tmp_logs tmp_map container ip user
  validate_since_window "$since"
  [[ -z "$target_user" ]] || validate_user "$target_user"

  status="$(docker inspect "$container_name" --format '{{.State.Status}}' 2>/dev/null || true)"
  echo "container=$container_name"
  echo "container_status=${status:-missing}"
  echo "usage_window=$since"
  if [[ "$status" != "running" ]]; then
    return 1
  fi

  tmp_logs="$(mktemp)"
  tmp_map="$(mktemp)"
  trap 'rm -f "$tmp_logs" "$tmp_map"' RETURN

  docker_since="$(docker_since_window "$since")"
  echo "docker_since_window=$docker_since"
  docker logs --timestamps --since "$docker_since" "$container_name" >"$tmp_logs" 2>&1 || true

  while IFS= read -r container; do
    [[ "$container" =~ ^openclaw-(oc[0-9]+)-openclaw-gateway-1$ ]] || continue
    user="${BASH_REMATCH[1]}"
    if [[ -n "$target_user" && "$user" != "$target_user" ]]; then
      continue
    fi
    ip="$(docker inspect "$container" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{"\n"}}{{end}}' 2>/dev/null | sed '/^$/d' | head -1 || true)"
    [[ -n "$ip" ]] || continue
    printf '%s %s %s\n' "$ip" "$user" "$container" >>"$tmp_map"
  done < <(docker ps --format '{{.Names}}')

  python3 - "$tmp_logs" "$tmp_map" "$target_user" <<'PY'
import collections
import re
import sys

log_path, map_path, target_user = sys.argv[1:4]

ip_to_slot = {}
slots = {}
with open(map_path, "r", encoding="utf-8", errors="replace") as handle:
    for line in handle:
        parts = line.rstrip("\n").split(" ", 2)
        if len(parts) != 3:
            continue
        ip, slot, container = parts
        ip_to_slot[ip] = slot
        slots[slot] = {
            "gateway_ip": ip,
            "gateway_container": container,
            "request_lines": 0,
            "generation_request_lines": 0,
            "model_list_request_lines": 0,
            "other_request_lines": 0,
            "latest_request_at": "none",
            "latest_generation_at": "none",
        }

request_re = re.compile(r"\|\s*(\d+\.\d+\.\d+\.\d+)\s*\|\s*([A-Z]+)\s+\"([^\"]+)\"")
timestamp_re = re.compile(r"^(\d{4}-\d{2}-\d{2}T\S+)")
generation_paths = (
    "/v1/chat/completions",
    "/v1/completions",
    "/v1/responses",
    "/api/chat",
    "/api/generate",
    "/api/embed",
    "/api/embeddings",
    "/v1/embeddings",
)
model_list_paths = (
    "/v1/models",
    "/api/tags",
    "/api/ps",
)

totals = collections.Counter()
unmapped = collections.Counter()

with open(log_path, "r", encoding="utf-8", errors="replace") as handle:
    for line in handle:
        m = request_re.search(line)
        if not m:
            continue
        ip, method, raw_path = m.groups()
        path = raw_path.split("?", 1)[0]
        ts_match = timestamp_re.match(line)
        ts = ts_match.group(1) if ts_match else "unknown"
        is_generation = method == "POST" and path in generation_paths
        is_model_list = path in model_list_paths

        totals["request_lines"] += 1
        if is_generation:
            totals["generation_request_lines"] += 1
        elif is_model_list:
            totals["model_list_request_lines"] += 1
        else:
            totals["other_request_lines"] += 1

        slot = ip_to_slot.get(ip)
        if not slot:
            unmapped["request_lines"] += 1
            if is_generation:
                unmapped["generation_request_lines"] += 1
            elif is_model_list:
                unmapped["model_list_request_lines"] += 1
            else:
                unmapped["other_request_lines"] += 1
            continue

        row = slots[slot]
        row["request_lines"] += 1
        row["latest_request_at"] = ts
        if is_generation:
            row["generation_request_lines"] += 1
            row["latest_generation_at"] = ts
        elif is_model_list:
            row["model_list_request_lines"] += 1
        else:
            row["other_request_lines"] += 1

print(f"mapped_gateway_count={len(slots)}")
print(f"request_lines_total={totals['request_lines']}")
print(f"generation_request_lines_total={totals['generation_request_lines']}")
print(f"model_list_request_lines_total={totals['model_list_request_lines']}")
print(f"other_request_lines_total={totals['other_request_lines']}")
print(f"unmapped_request_lines={unmapped['request_lines']}")
print(f"unmapped_generation_request_lines={unmapped['generation_request_lines']}")

for slot in sorted(slots, key=lambda s: int(s[2:])):
    row = slots[slot]
    print(f"== {slot} ==")
    print(f"gateway_container={row['gateway_container']}")
    print(f"gateway_ip={row['gateway_ip']}")
    print(f"request_lines={row['request_lines']}")
    print(f"generation_request_lines={row['generation_request_lines']}")
    print(f"model_list_request_lines={row['model_list_request_lines']}")
    print(f"other_request_lines={row['other_request_lines']}")
    print(f"latest_request_at={row['latest_request_at']}")
    print(f"latest_generation_at={row['latest_generation_at']}")
PY
}

run_smoke() {
  local user="$1" model_override="$2" endpoint_url endpoint_model model container status
  validate_user "$user"
  if [[ -n "$model_override" ]]; then
    validate_model "$model_override"
  fi

  endpoint_url="$(read_endpoint_value OPENCLAW_SHARED_OLLAMA_BASE_URL)"
  endpoint_model="$(read_endpoint_value OPENCLAW_SHARED_OLLAMA_MODEL)"
  model="${model_override:-$endpoint_model}"
  [[ -n "$endpoint_url" ]] || die "missing shared Ollama endpoint file value"
  [[ -n "$model" ]] || die "missing shared Ollama model"

  container="openclaw-${user}-openclaw-gateway-1"
  status="$(docker inspect "$container" --format '{{.State.Status}}' 2>/dev/null || true)"
  echo "target_user=$user"
  echo "gateway_container=$container"
  echo "gateway_status=${status:-missing}"
  echo "base_url=$endpoint_url"
  echo "model=$model"
  [[ "$status" == "running" ]] || die "gateway container is not running"

  docker exec \
    -e OPENCLAW_OLLAMA_BASE_URL="$endpoint_url" \
    -e OPENCLAW_OLLAMA_MODEL="$model" \
    "$container" python3 - <<'PY'
import json
import os
import urllib.request

base = os.environ["OPENCLAW_OLLAMA_BASE_URL"].rstrip("/")
model = os.environ["OPENCLAW_OLLAMA_MODEL"]
payload = {
    "model": model,
    "messages": [
        {"role": "user", "content": "Reply with exactly OK."},
    ],
    "stream": False,
    "temperature": 0,
    "max_tokens": 4,
}
request = urllib.request.Request(
    base + "/chat/completions",
    data=json.dumps(payload).encode("utf-8"),
    headers={
        "Content-Type": "application/json",
        "Authorization": "Bearer ollama",
    },
    method="POST",
)
try:
    with urllib.request.urlopen(request, timeout=60) as response:
        status = response.status
        data = json.load(response)
except Exception as exc:
    print("generation_smoke=fail")
    print("generation_error=" + exc.__class__.__name__)
    raise SystemExit(1)

content = ""
choices = data.get("choices")
if isinstance(choices, list) and choices:
    first = choices[0]
    if isinstance(first, dict):
        message = first.get("message")
        if isinstance(message, dict):
            content = str(message.get("content") or "")
        if not content:
            content = str(first.get("text") or "")

print("generation_smoke=pass")
print(f"http_status={status}")
print("response_nonempty=" + ("yes" if content.strip() else "no"))
print(f"response_chars={len(content)}")
raise SystemExit(0 if status == 200 and content.strip() else 1)
PY
}

cmd="${1:-}"
shift || true

case "$cmd" in
  -h|--help|help)
    usage
    exit 0
    ;;
  status)
    [[ "$(id -u)" -eq 0 ]] || die "run with sudo/root"
    mkdir -p "$state_dir"
    print_status
    ;;
  usage)
    since_window="2h"
    target_user=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --since)
          since_window="${2:?missing --since value}"
          shift 2
          ;;
        --user)
          target_user="${2:?missing --user value}"
          shift 2
          ;;
        *)
          die "unknown argument: $1"
          ;;
      esac
    done
    [[ "$(id -u)" -eq 0 ]] || die "run with sudo/root"
    print_usage "$since_window" "$target_user"
    ;;
  smoke)
    smoke_user=""
    smoke_model=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --user)
          smoke_user="${2:?missing --user value}"
          shift 2
          ;;
        --model)
          smoke_model="${2:?missing --model value}"
          shift 2
          ;;
        *)
          die "unknown argument: $1"
          ;;
      esac
    done
    [[ "$(id -u)" -eq 0 ]] || die "run with sudo/root"
    [[ -n "$smoke_user" ]] || die "--user is required"
    run_smoke "$smoke_user" "$smoke_model"
    ;;
  up)
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --model)
          model="${2:?missing --model value}"
          shift 2
          ;;
        --image)
          image="${2:?missing --image value}"
          shift 2
          ;;
        --bind)
          bind_ip="${2:?missing --bind value}"
          shift 2
          ;;
        --port)
          port="${2:?missing --port value}"
          shift 2
          ;;
        --models-dir)
          models_dir="${2:?missing --models-dir value}"
          shift 2
          ;;
        --no-pull-model)
          pull_model=0
          shift
          ;;
        *)
          die "unknown argument: $1"
          ;;
      esac
    done

    [[ "$(id -u)" -eq 0 ]] || die "run with sudo/root"
    [[ -n "$model" ]] || die "--model is required"
    validate_model "$model"
    validate_image "$image"
    validate_port "$port"
    bind_ip="${bind_ip:-$(docker0_ip)}"
    [[ -n "$bind_ip" ]] || die "could not resolve docker0 IPv4 address"
    validate_bind "$bind_ip"

    mkdir -p "$models_dir" "$state_dir"
    chown root:root "$state_dir" "$models_dir"
    chmod 0755 "$state_dir" "$models_dir"

    echo "container=$container_name"
    echo "image=$image"
    echo "model=$model"
    echo "bind=$bind_ip:$port"
    echo "models_dir=$models_dir"

    docker pull "$image"
    docker rm -f "$container_name" >/dev/null 2>&1 || true
    docker run -d \
      --name "$container_name" \
      --restart unless-stopped \
      -e OLLAMA_HOST=0.0.0.0:11434 \
      -p "$bind_ip:$port:11434" \
      -v "$models_dir:/root/.ollama" \
      "$image" >/dev/null

    wait_for_ollama || die "shared Ollama did not become reachable at http://$bind_ip:$port"

    if [[ "$pull_model" -eq 1 ]]; then
      docker exec "$container_name" ollama pull "$model"
    fi

    {
      printf 'OPENCLAW_SHARED_OLLAMA_BASE_URL=http://%s:%s/v1\n' "$bind_ip" "$port"
      printf 'OPENCLAW_SHARED_OLLAMA_MODEL=%s\n' "$model"
      printf 'OPENCLAW_SHARED_OLLAMA_IMAGE=%s\n' "$image"
      printf 'OPENCLAW_SHARED_OLLAMA_MODELS_DIR=%s\n' "$models_dir"
    } > "$endpoint_file"
    chown root:root "$endpoint_file"
    chmod 0644 "$endpoint_file"

    print_status
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
