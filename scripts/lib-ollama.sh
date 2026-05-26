#!/usr/bin/env bash

openclaw_ollama_container_name() {
  printf '%s' "${OPENCLAW_SHARED_OLLAMA_CONTAINER:-openclaw-shared-ollama}"
}

openclaw_ollama_network_default() {
  printf '%s' "${OPENCLAW_SHARED_OLLAMA_NETWORK_DEFAULT:-openclaw-shared-ollama-net}"
}

openclaw_ollama_alias_default() {
  printf '%s' "${OPENCLAW_SHARED_OLLAMA_ALIAS_DEFAULT:-openclaw-shared-ollama}"
}

openclaw_ollama_state_dir() {
  printf '%s' "${OPENCLAW_SHARED_OLLAMA_STATE_DIR:-/srv/openclaw-ollama}"
}

openclaw_ollama_endpoint_file() {
  printf '%s' "$(openclaw_ollama_state_dir)/endpoint.env"
}

openclaw_ollama_endpoint_value() {
  local key="$1" file
  file="$(openclaw_ollama_endpoint_file)"
  awk -F= -v k="$key" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$file" 2>/dev/null || true
}

openclaw_ollama_network_name() {
  local value
  value="$(openclaw_ollama_endpoint_value OPENCLAW_SHARED_OLLAMA_NETWORK)"
  printf '%s' "${value:-$(openclaw_ollama_network_default)}"
}

openclaw_ollama_network_alias() {
  local value
  value="$(openclaw_ollama_endpoint_value OPENCLAW_SHARED_OLLAMA_NETWORK_ALIAS)"
  printf '%s' "${value:-$(openclaw_ollama_alias_default)}"
}

openclaw_ollama_container_base_url() {
  local value
  value="$(openclaw_ollama_endpoint_value OPENCLAW_SHARED_OLLAMA_BASE_URL)"
  printf '%s' "${value:-http://$(openclaw_ollama_network_alias):11434/v1}"
}

openclaw_ollama_host_probe_base_url() {
  local configured="${1:-}" value bind port alias
  value="$(openclaw_ollama_endpoint_value OPENCLAW_SHARED_OLLAMA_HOST_BASE_URL)"
  if [[ -n "$value" ]]; then
    printf '%s' "$value"
    return 0
  fi

  alias="$(openclaw_ollama_network_alias)"
  case "$configured" in
    http://$alias:*|http://$alias/*)
      bind="$(openclaw_ollama_endpoint_value OPENCLAW_SHARED_OLLAMA_BIND_IP)"
      port="$(openclaw_ollama_endpoint_value OPENCLAW_SHARED_OLLAMA_PORT)"
      printf 'http://%s:%s/v1' "${bind:-172.17.0.1}" "${port:-11434}"
      ;;
    *)
      printf '%s' "$configured"
      ;;
  esac
}

openclaw_assert_shared_ollama_network() {
  local network
  network="$(openclaw_ollama_network_name)"
  docker network inspect "$network" >/dev/null 2>&1 || {
    echo "error: shared Ollama Docker network missing: $network" >&2
    return 1
  }
}

openclaw_write_shared_ollama_compose_override() {
  local target_user="$1" compose_dir="$2"
  local network tmp out

  [[ "$target_user" =~ ^oc[1-9][0-9]*$ ]] || {
    echo "error: invalid user: $target_user" >&2
    return 1
  }
  [[ -d "$compose_dir" ]] || {
    echo "error: compose dir missing: $compose_dir" >&2
    return 1
  }

  network="$(openclaw_ollama_network_name)"
  [[ "$network" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$ ]] || {
    echo "error: invalid shared Ollama network name: $network" >&2
    return 1
  }

  out="$compose_dir/docker-compose.shared-ollama.yml"
  tmp="$(mktemp)"
  cat > "$tmp" <<EOF
services:
  openclaw-gateway:
    networks:
      default: {}
      openclaw-shared-ollama: {}

networks:
  openclaw-shared-ollama:
    external: true
    name: "$network"
EOF

  if [[ "$(id -u)" -eq 0 ]]; then
    install -o root -g root -m 0644 "$tmp" "$out"
  else
    install -m 0644 "$tmp" "$out"
  fi
  rm -f "$tmp"
  echo "shared_ollama_compose_override=$out"
  echo "shared_ollama_network=$network"
}
