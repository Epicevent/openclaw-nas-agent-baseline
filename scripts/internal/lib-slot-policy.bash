#!/usr/bin/env bash

openclaw_is_customer_slot() {
  [[ "${1:-}" =~ ^oc[1-9][0-9]*$ ]]
}

openclaw_is_dev_slot() {
  case "${1:-}" in
    dev-oc|dev-hermess) return 0 ;;
    *) return 1 ;;
  esac
}

openclaw_is_managed_slot() {
  openclaw_is_customer_slot "${1:-}" || openclaw_is_dev_slot "${1:-}"
}

openclaw_slot_kind() {
  local slot="${1:-}"
  if openclaw_is_customer_slot "$slot"; then
    printf '%s\n' customer
  elif openclaw_is_dev_slot "$slot"; then
    printf '%s\n' dev
  else
    return 1
  fi
}

openclaw_assert_customer_slot_name() {
  local slot="${1:-}"
  openclaw_is_customer_slot "$slot" || {
    echo "error: expected customer slot ocN, got: $slot" >&2
    return 2
  }
}

openclaw_assert_dev_slot_name() {
  local slot="${1:-}"
  openclaw_is_dev_slot "$slot" || {
    echo "error: expected dev slot dev-oc or dev-hermess, got: $slot" >&2
    return 2
  }
}

openclaw_assert_managed_slot_name() {
  local slot="${1:-}"
  openclaw_is_managed_slot "$slot" || {
    echo "error: expected managed slot ocN, dev-oc, or dev-hermess; got: $slot" >&2
    return 2
  }
}

openclaw_slot_default_family() {
  case "${1:-}" in
    dev-hermess) printf '%s\n' hermes ;;
    *) printf '%s\n' openclaw ;;
  esac
}

openclaw_slot_number() {
  local slot="${1:-}"
  if [[ "$slot" =~ ^oc([1-9][0-9]*)$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

openclaw_slot_default_gateway_port() {
  local slot="${1:-}" number
  if number="$(openclaw_slot_number "$slot" 2>/dev/null)"; then
    printf '%s\n' $((28789 + (number - 1) * 100))
    return 0
  fi
  case "$slot" in
    dev-oc) printf '%s\n' 30789 ;;
    dev-hermess) printf '%s\n' 30889 ;;
    *) return 1 ;;
  esac
}

openclaw_slot_default_bridge_port() {
  local slot="${1:-}" gateway_port
  gateway_port="$(openclaw_slot_default_gateway_port "$slot")" || return 1
  printf '%s\n' $((gateway_port + 1))
}

openclaw_validate_port() {
  local port="${1:-}" label="${2:-port}"
  if [[ ! "$port" =~ ^[0-9]+$ || "$port" -lt 1 || "$port" -gt 65535 ]]; then
    echo "error: invalid $label: $port" >&2
    return 2
  fi
}

openclaw_dev_source_path() {
  case "${1:-}" in
    dev-oc) printf '%s\n' /home/openclawdev/src/openclaw-jitech ;;
    dev-hermess) printf '%s\n' /home/openclawdev/src/hermes-workspace-jitech ;;
    *) return 1 ;;
  esac
}

openclaw_dev_source_artifact_path() {
  case "${1:-}" in
    dev-oc) printf '%s\n' /home/openclawdev/src/openclaw-jitech/dist/control-ui ;;
    dev-hermess) printf '%s\n' /home/openclawdev/src/hermes-workspace-jitech ;;
    *) return 1 ;;
  esac
}

openclaw_dev_source_container_path() {
  case "${1:-}" in
    dev-oc) printf '%s\n' /app/dist/control-ui ;;
    dev-hermess) printf '%s\n' /opt/hermes-workspace ;;
    *) return 1 ;;
  esac
}
