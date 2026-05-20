#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  check-customer-deployment.sh --user USER --expected-origin ORIGIN [--expected-basepath PATH] [--skip-public-url-check]

Checks the full hosted customer deployment without printing secret values.

This is the completion check for customer subdomain deployments. It runs the
customer-mode isolation check first, then verifies the Apache VirtualHost layer
and the public URL.

Expected pass state:
  - customer-mode isolation passes
  - account deploy conf exists under /home/USER/openclaw/deploy
  - Apache site is installed under /etc/apache2/sites-available
  - Apache site is enabled under /etc/apache2/sites-enabled
  - Apache vhost is registered by apache2ctl -S
  - Apache site points at the expected gateway port
  - public URL returns an OpenClaw page, not the default site

Run as root/admin.
USAGE
}

target_user=""
expected_origin=""
expected_basepath="/"
skip_public_url_check=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user)
      target_user="${2:?missing user}"
      shift 2
      ;;
    --expected-origin)
      expected_origin="${2:?missing origin}"
      shift 2
      ;;
    --expected-basepath)
      expected_basepath="${2:?missing basepath}"
      shift 2
      ;;
    --skip-public-url-check)
      skip_public_url_check=1
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

if [[ -z "$target_user" || -z "$expected_origin" ]]; then
  echo "error: --user and --expected-origin are required" >&2
  usage >&2
  exit 2
fi

if [[ "$(id -u)" -ne 0 ]]; then
  echo "error: run with sudo/root" >&2
  exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
target_home="$(getent passwd "$target_user" | cut -d: -f6)"
if [[ -z "$target_home" ]]; then
  echo "error: user not found: $target_user" >&2
  exit 1
fi

container="openclaw-${target_user}-openclaw-gateway-1"
deploy_subdomain_config_path="$target_home/openclaw/deploy/apache-subdomain-${target_user}.conf"
failed=0

pass() {
  printf 'PASS %s\n' "$1"
}

fail() {
  printf 'FAIL %s\n' "$1"
  failed=1
}

check() {
  local name="$1"
  shift
  if "$@"; then
    pass "$name"
  else
    fail "$name"
  fi
}

origin_host() {
  python3 - "$1" <<'PY'
import sys
from urllib.parse import urlparse

raw = sys.argv[1]
parsed = urlparse(raw if "://" in raw else f"https://{raw}")
if not parsed.hostname:
    raise SystemExit(1)
print(parsed.hostname)
PY
}

public_url_for() {
  python3 - "$1" "$2" <<'PY'
import sys

origin = sys.argv[1].rstrip("/")
basepath = sys.argv[2] or "/"
if not basepath.startswith("/"):
    basepath = "/" + basepath
if not basepath.endswith("/"):
    basepath += "/"
print(origin + basepath)
PY
}

expected_gateway_port() {
  local actual_port

  actual_port="$(docker port "$container" 18789/tcp 2>/dev/null | sed -n 's/.*:\([0-9][0-9]*\)$/\1/p' | head -1 || true)"
  if [[ -n "$actual_port" ]]; then
    printf '%s\n' "$actual_port"
    return 0
  fi

  if [[ "$target_user" =~ ^oc([0-9]+)$ ]]; then
    printf '%s\n' "$((28789 + (${BASH_REMATCH[1]} - 1) * 100))"
    return 0
  fi

  return 1
}

check_public_openclaw_page() {
  local public_url="$1"
  local body_file
  local meta_file
  local curl_rc=0
  local http_code=""
  local effective_url=""
  local title=""

  if ! command -v curl >/dev/null 2>&1; then
    echo "INFO missing_command=curl"
    return 1
  fi

  body_file="$(mktemp)"
  meta_file="$(mktemp)"

  curl -k -L -sS --max-time 10 \
    -o "$body_file" \
    -w 'http_code=%{http_code}\nurl_effective=%{url_effective}\n' \
    "$public_url" >"$meta_file" || curl_rc=$?

  http_code="$(sed -n 's/^http_code=//p' "$meta_file" | tail -1)"
  effective_url="$(sed -n 's/^url_effective=//p' "$meta_file" | tail -1)"

  if [[ "$curl_rc" -eq 0 ]] && [[ "$http_code" =~ ^(2|3) ]] && grep -qi 'OpenClaw' "$body_file"; then
    rm -f "$body_file" "$meta_file"
    return 0
  fi

  title="$(tr '\n' ' ' <"$body_file" | sed -n 's/.*<title[^>]*>\([^<]*\)<.*/\1/p' | head -1)"
  echo "INFO public_url=$public_url"
  echo "INFO public_http_code=${http_code:-unknown}"
  echo "INFO public_effective_url=${effective_url:-unknown}"
  if [[ -n "$title" ]]; then
    echo "INFO public_page_title=$title"
  fi

  rm -f "$body_file" "$meta_file"
  return 1
}

echo "== customer isolation =="
if bash "$script_dir/check-customer-mode-isolation.sh" \
  --user "$target_user" \
  --expected-basepath "$expected_basepath" \
  --expected-origin "$expected_origin"; then
  pass "customer_isolation_ok"
else
  fail "customer_isolation_ok"
fi

echo "== apache subdomain =="
if [[ "$expected_basepath" != "/" ]]; then
  fail "apache_subdomain_basepath_ok"
  echo "INFO expected_basepath_for_subdomain=/"
else
  pass "apache_subdomain_basepath_ok"
fi

expected_host="$(origin_host "$expected_origin" || true)"
if [[ -z "$expected_host" ]]; then
  fail "apache_expected_host_parse_ok"
else
  pass "apache_expected_host_parse_ok"
  apache_available_path="/etc/apache2/sites-available/${expected_host}.conf"
  apache_enabled_path="/etc/apache2/sites-enabled/${expected_host}.conf"

  check "apache_deploy_conf_exists" test -f "$deploy_subdomain_config_path"
  check "apache_site_available_ok" test -f "$apache_available_path"
  check "apache_site_enabled_ok" test -e "$apache_enabled_path"

  if command -v apache2ctl >/dev/null 2>&1; then
    check "apache_syntax_ok" apache2ctl -t

    if apache2ctl -S 2>&1 | grep -Fq "$expected_host"; then
      pass "apache_vhost_registered_ok"
    else
      fail "apache_vhost_registered_ok"
      echo "INFO missing_apache_vhost=$expected_host"
    fi
  else
    fail "apache_syntax_ok"
    fail "apache_vhost_registered_ok"
    echo "INFO missing_command=apache2ctl"
  fi

  expected_port="$(expected_gateway_port || true)"
  if [[ -n "$expected_port" && -f "$apache_available_path" ]]; then
    if grep -Fq "127.0.0.1:${expected_port}" "$apache_available_path"; then
      pass "apache_backend_port_ok"
    else
      fail "apache_backend_port_ok"
      echo "INFO expected_backend=127.0.0.1:${expected_port}"
      echo "INFO apache_site=$apache_available_path"
    fi
  else
    fail "apache_backend_port_ok"
    echo "INFO expected_backend_port=${expected_port:-unknown}"
    echo "INFO apache_site=$apache_available_path"
  fi

  if [[ "$skip_public_url_check" -eq 1 ]]; then
    echo "INFO public_url_openclaw_page_ok=skipped"
  else
    public_url="$(public_url_for "$expected_origin" "$expected_basepath")"
    if check_public_openclaw_page "$public_url"; then
      pass "public_url_openclaw_page_ok"
    else
      fail "public_url_openclaw_page_ok"
    fi
  fi
fi

exit "$failed"
