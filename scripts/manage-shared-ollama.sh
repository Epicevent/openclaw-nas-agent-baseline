#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  manage-shared-ollama.sh status
  manage-shared-ollama.sh up --model MODEL [options]

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
