#!/usr/bin/env bash
set -euo pipefail

prefix="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
failed=0

pass() {
  printf 'PASS %s\n' "$*"
}

fail() {
  printf 'FAIL %s\n' "$*"
  failed=1
}

need_file() {
  local path="$1"
  if [[ -f "$prefix/$path" ]]; then
    pass "file_$path"
  else
    fail "file_$path"
  fi
}

need_executable() {
  local path="$1"
  if [[ -x "$prefix/$path" ]]; then
    pass "executable_$path"
  else
    fail "executable_$path"
  fi
}

need_dir() {
  local path="$1"
  if [[ -d "$prefix/$path" ]]; then
    pass "dir_$path"
  else
    fail "dir_$path"
  fi
}

need_file "README.md"
need_file "install.sh"
need_file ".openclaw-baseline-manifest"

need_executable "scripts/svcops-control.sh"
need_executable "scripts/slot-control.sh"
need_executable "scripts/ops-monitor.sh"
need_executable "scripts/customer-nas-mount.sh"
need_executable "scripts/install-svcops-account.sh"
need_executable "admin-cli/bin/openclaw-ops-console"

need_dir "images"
need_dir "docs"

if [[ -d "$prefix/openclaw" ]]; then
  fail "product_source_dir_absent"
else
  pass "product_source_dir_absent"
fi

if [[ -d "$prefix/container" ]]; then
  fail "legacy_container_dir_absent"
else
  pass "legacy_container_dir_absent"
fi

if [[ "$(id -u)" -eq 0 || "$prefix" == /opt/* ]]; then
  if [[ -x /usr/local/bin/agent-nas-mount ]]; then
    pass "customer_nas_helper_alias_present"
  else
    fail "customer_nas_helper_alias_present"
  fi

  if [[ -L /usr/local/bin/openclaw-nas-mount ]]; then
    target="$(readlink /usr/local/bin/openclaw-nas-mount 2>/dev/null || true)"
    if [[ "$target" == "$prefix/scripts/customer-nas-mount.sh" ]]; then
      fail "legacy_customer_nas_helper_alias_absent"
    else
      pass "legacy_customer_nas_helper_alias_absent"
    fi
  else
    pass "legacy_customer_nas_helper_alias_absent"
  fi
else
  pass "customer_nas_helper_alias_skipped"
fi

if grep -RIn -- '--repair-user\|--repair-users\|repairing OpenClaw state' "$prefix/install.sh" "$prefix/README.md" "$prefix/docs" 2>/dev/null | grep -q .; then
  grep -RIn -- '--repair-user\|--repair-users\|repairing OpenClaw state' "$prefix/install.sh" "$prefix/README.md" "$prefix/docs" 2>/dev/null || true
  fail "host_install_product_repair_absent"
else
  pass "host_install_product_repair_absent"
fi

exit "$failed"
