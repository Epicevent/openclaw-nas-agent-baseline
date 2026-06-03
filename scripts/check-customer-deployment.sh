#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  check-customer-deployment.sh --user USER --expected-origin ORIGIN [--expected-basepath PATH] [--skip-provider-key-check] [--skip-public-url-check] [--expect-unknown-origin-rejected ORIGIN]

Checks the full hosted customer deployment without printing secret values.

This is the completion check for customer subdomain deployments. It runs the
customer-mode isolation check first, then verifies the Apache VirtualHost layer
and the public URL.

Expected pass state:
  - customer-mode isolation passes
  - container document baseline tools and Korean runtime support pass
  - Apache vhost is registered by apache2ctl -S
  - Apache registered vhost config file exists
  - Apache registered vhost config points at the expected gateway port
  - public URL returns an OpenClaw page, not the default site
  - optionally, an unknown origin does not return an OpenClaw page

Run as root/admin.
USAGE
}

target_user=""
expected_origin=""
expected_basepath="/"
skip_public_url_check=0
expect_unknown_origin_rejected=""
skip_provider_key_check=0

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
    --skip-provider-key-check)
      skip_provider_key_check=1
      shift
      ;;
    --skip-public-url-check)
      skip_public_url_check=1
      shift
      ;;
    --expect-unknown-origin-rejected)
      expect_unknown_origin_rejected="${2:?missing origin}"
      shift 2
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
runtime_env_path="$target_home/openclaw/.env"
runtime_family="openclaw"
failed=0

if [[ -f "$runtime_env_path" ]]; then
  runtime_family="$(
    awk -F= '$1 == "OPENCLAW_RUNTIME_FAMILY" {
      value=$2
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      gsub(/^'\''|'\''$/, "", value)
      gsub(/^"|"$/, "", value)
      print value
      exit
    }' "$runtime_env_path" 2>/dev/null || true
  )"
  runtime_family="${runtime_family:-openclaw}"
fi

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

apache_vhost_config_path() {
  local host="$1"

  apache2ctl -S 2>&1 | awk -v host="$host" '
    index($0, "namevhost " host " ") || index($0, "default server " host " ") {
      if (match($0, /\([^()]+:[0-9]+\)/)) {
        path = substr($0, RSTART + 1, RLENGTH - 2)
        sub(/:[0-9]+$/, "", path)
        print path
        exit
      }
    }
  '
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
  local container_port="18789"

  if [[ "$runtime_family" == "hermes" ]]; then
    container_port="3000"
    if [[ -f "$runtime_env_path" ]]; then
      actual_port="$(
        awk -F= '$1 == "OPENCLAW_BRIDGE_PORT" {
          value=$2
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
          gsub(/^'\''|'\''$/, "", value)
          gsub(/^"|"$/, "", value)
          print value
          exit
        }' "$runtime_env_path" 2>/dev/null || true
      )"
      if [[ "$actual_port" =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$actual_port"
        return 0
      fi
    fi
  fi

  actual_port="$(docker port "$container" "${container_port}/tcp" 2>/dev/null | sed -n 's/.*:\([0-9][0-9]*\)$/\1/p' | head -1 || true)"
  if [[ -n "$actual_port" ]]; then
    printf '%s\n' "$actual_port"
    return 0
  fi

  if [[ "$target_user" =~ ^oc([0-9]+)$ ]]; then
    local base_port
    base_port=$((28789 + (${BASH_REMATCH[1]} - 1) * 100))
    printf '%s\n' "$base_port"
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

  if [[ "$curl_rc" -eq 0 ]] && [[ "$http_code" =~ ^(2|3) ]] && grep -Eqi 'OpenClaw|Hermes' "$body_file"; then
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

echo "== production legacy boundary =="
legacy_import_pattern='apply-openclaw-install-env[.]sh'
legacy_env_pattern='[.]openclaw-install[.]'"env"
legacy_refs="$(
  grep -R -n --include='*.sh' -E "${legacy_import_pattern}|${legacy_env_pattern}" "$script_dir" 2>/dev/null \
    | grep -v '/legacy/' \
    || true
)"
if [[ -n "$legacy_refs" ]]; then
  fail "production_legacy_boundary_ok"
  printf '%s\n' "$legacy_refs" | sed 's/^/INFO legacy_ref=/'
else
  pass "production_legacy_boundary_ok"
fi

echo "== production recovery boundary =="
recovery_repair_pattern='repair-openclaw-state[.]'"sh"
recovery_backup_pattern='backup-openclaw-state[.]'"sh"
recovery_refs="$(
  grep -R -n --include='*.sh' -E "${recovery_repair_pattern}|${recovery_backup_pattern}" "$script_dir" 2>/dev/null \
    | grep -v '/recovery/' \
    || true
)"
if [[ -n "$recovery_refs" ]]; then
  fail "production_recovery_boundary_ok"
  printf '%s\n' "$recovery_refs" | sed 's/^/INFO recovery_ref=/'
else
  pass "production_recovery_boundary_ok"
fi

echo "== customer isolation =="
isolation_args=(
  --user "$target_user"
  --expected-basepath "$expected_basepath"
  --expected-origin "$expected_origin"
)
if [[ "$skip_provider_key_check" -eq 1 ]]; then
  isolation_args+=(--skip-provider-key-check)
fi
if [[ "$runtime_family" == "hermes" ]]; then
  isolation_args+=(--skip-provider-key-check)
fi
if bash "$script_dir/check-customer-mode-isolation.sh" \
  "${isolation_args[@]}"; then
  pass "customer_isolation_ok"
else
  fail "customer_isolation_ok"
fi

echo "== container document baseline =="
if docker inspect "$container" >/dev/null 2>&1; then
  pass "container_exists_for_document_baseline"

  check "container_locale_utf8" \
    docker exec "$container" sh -lc 'locale charmap 2>/dev/null | grep -qi UTF-8'

  check "container_ko_locale_available" \
    docker exec "$container" sh -lc 'locale -a 2>/dev/null | grep -Eiq "^ko_KR(\\.utf8|\\.UTF-8)?$"'

  check "container_korean_fonts_available" \
    docker exec "$container" sh -lc 'command -v fc-list >/dev/null 2>&1 && [ "$(fc-list :lang=ko 2>/dev/null | wc -l)" -gt 0 ]'

  required_container_commands=(
    file
    rg
    jq
    yq
    7z
    7zz
    libreoffice
    soffice
    pandoc
    pdftotext
    pdfinfo
    tesseract
    ocrmypdf
    xlsx2csv
    in2csv
    ssconvert
    antiword
    catdoc
    python3
    node
    npm
    clawhub
    hwp5txt
    hwp5proc
    openclaw-hwp-text
    openclaw-document-tools
  )

  for command_name in "${required_container_commands[@]}"; do
    check "container_cmd_${command_name}_ok" \
      docker exec "$container" sh -lc "command -v '$command_name' >/dev/null 2>&1"
  done

  check "container_tesseract_kor_available" \
    docker exec "$container" sh -lc 'tesseract --list-langs 2>/dev/null | grep -qx kor'

  check "container_python_document_modules_ok" \
    docker exec "$container" python3 -c 'import docx, pandas, openpyxl, pptx, lxml, bs4, pypdf, pdfplumber, fitz'

  check "container_korean_file_smoke_ok" \
    docker exec "$container" python3 -c 'from pathlib import Path; p=Path("/tmp/openclaw-korean-smoke"); p.mkdir(exist_ok=True); f=p/"\ud55c\uae00.txt"; f.write_text("\ud55c\uae00 \ud14c\uc2a4\ud2b8\n", encoding="utf-8"); assert f.read_text(encoding="utf-8").strip() == "\ud55c\uae00 \ud14c\uc2a4\ud2b8"; f.unlink(); p.rmdir()'

  if [[ "$runtime_family" == "hermes" ]]; then
    check "hermes_workspace_guidance_ok" \
      docker exec "$container" sh -lc 'for f in /workspace/AGENTS.md /workspace/CLAUDE.md; do test -f "$f" && grep -q openclaw-hwp-text "$f" && grep -q /workspace/nas_docs "$f"; done'

    check "hermes_nas_canonical_alias_ok" \
      docker exec "$container" sh -lc 'test -d /workspace/nas_docs && test -L /opt/data/nas_docs && test "$(readlink /opt/data/nas_docs)" = /workspace/nas_docs'
  fi
else
  fail "container_exists_for_document_baseline"
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

  if [[ -f "$deploy_subdomain_config_path" ]]; then
    pass "apache_account_deploy_conf_exists"
  else
    echo "INFO account_deploy_conf_missing=$deploy_subdomain_config_path"
  fi

  apache_vhost_path=""
  if command -v apache2ctl >/dev/null 2>&1; then
    check "apache_syntax_ok" apache2ctl -t

    apache_vhost_path="$(apache_vhost_config_path "$expected_host" || true)"
    if [[ -n "$apache_vhost_path" ]]; then
      pass "apache_vhost_registered_ok"
      echo "INFO apache_vhost_config=$apache_vhost_path"
    else
      fail "apache_vhost_registered_ok"
      echo "INFO missing_apache_vhost=$expected_host"
    fi
  else
    fail "apache_syntax_ok"
    fail "apache_vhost_registered_ok"
    echo "INFO missing_command=apache2ctl"
  fi

  if [[ -n "$apache_vhost_path" && -f "$apache_vhost_path" ]]; then
    pass "apache_vhost_config_exists"
  else
    fail "apache_vhost_config_exists"
    echo "INFO apache_vhost_config=${apache_vhost_path:-unknown}"
  fi

  hermes_local_only_apache=0
  if [[ "$runtime_family" == "hermes" && -n "$apache_vhost_path" && -f "$apache_vhost_path" ]] \
    && grep -Eq "Hermes (Workspace )?local-only" "$apache_vhost_path"; then
    hermes_local_only_apache=1
  fi

  expected_port="$(expected_gateway_port || true)"
  if [[ -n "$expected_port" && -n "$apache_vhost_path" && -f "$apache_vhost_path" ]]; then
    if [[ "$hermes_local_only_apache" -eq 1 ]]; then
      pass "apache_backend_port_ok"
      echo "INFO hermes_workspace_exposure=local_only"
    elif grep -Fq "127.0.0.1:${expected_port}" "$apache_vhost_path"; then
      pass "apache_backend_port_ok"
    else
      fail "apache_backend_port_ok"
      echo "INFO expected_backend=127.0.0.1:${expected_port}"
      echo "INFO apache_vhost_config=$apache_vhost_path"
    fi
  else
    fail "apache_backend_port_ok"
    echo "INFO expected_backend_port=${expected_port:-unknown}"
    echo "INFO apache_vhost_config=${apache_vhost_path:-unknown}"
  fi

  if [[ "$skip_public_url_check" -eq 1 ]]; then
    echo "INFO public_url_openclaw_page_ok=skipped"
  else
    public_url="$(public_url_for "$expected_origin" "$expected_basepath")"
    if [[ "$hermes_local_only_apache" -eq 1 ]]; then
      public_http_code="$(curl -k -sS --max-time 10 -o /dev/null -w '%{http_code}' "$public_url" 2>/dev/null || true)"
      if [[ "$public_http_code" == "403" ]]; then
        pass "public_url_openclaw_page_ok"
        echo "INFO hermes_public_workspace_disabled=403"
      else
        fail "public_url_openclaw_page_ok"
        echo "INFO expected_public_http_code=403"
        echo "INFO public_http_code=${public_http_code:-unknown}"
      fi
    elif check_public_openclaw_page "$public_url"; then
      pass "public_url_openclaw_page_ok"
    else
      fail "public_url_openclaw_page_ok"
    fi
  fi

  if [[ -n "$expect_unknown_origin_rejected" ]]; then
    unknown_url="$(public_url_for "$expect_unknown_origin_rejected" "/")"
    if check_public_openclaw_page "$unknown_url"; then
      fail "unknown_origin_rejected_ok"
      echo "INFO unknown_origin_returned_openclaw=$unknown_url"
    else
      pass "unknown_origin_rejected_ok"
    fi
  fi
fi

exit "$failed"
