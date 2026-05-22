#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
failed=0

fail() {
  printf 'FAIL %s\n' "$*"
  failed=1
}

pass() {
  printf 'PASS %s\n' "$*"
}

grep_md() {
  local pattern="$1"
  grep -RInE "$pattern" "$repo_root/README.md" "$repo_root/docs" --include='*.md' 2>/dev/null || true
}

for removed in \
  BOOTSTRAP_COMPAT.md \
  CONTAINER_BASELINE.md \
  IMAGE_FAST_INSTALL.md \
  OPERATION_MODEL.md \
  REMOUNT_GUIDE.md; do
  if grep_md "$removed" | grep -q .; then
    fail "removed_doc_reference_$removed"
  else
    pass "removed_doc_reference_$removed"
  fi
done

host_install_refs="$(grep_md 'git clone https://github\.com/Epicevent/openclaw-nas-agent-baseline\.git|install-svcops-account\.sh --set-password --nopasswd-sudo' || true)"
if printf '%s\n' "$host_install_refs" | grep -v 'docs/ROOT_ADMIN_TASKS.md:' | grep -q .; then
  printf '%s\n' "$host_install_refs" | grep -v 'docs/ROOT_ADMIN_TASKS.md:' || true
  fail "host_install_snippet_outside_root_admin_tasks"
else
  pass "host_install_snippet_single_source"
fi

if grep_md 'git rev-parse HEAD' | grep -q .; then
  grep_md 'git rev-parse HEAD'
  fail "git_rev_parse_head_in_docs"
else
  pass "git_rev_parse_head_absent"
fi

if grep_md 'openclaw-bootstrap|\.openclaw-install\.env' | grep -v 'docs/SLOT_TURNOVER.md:' | grep -q .; then
  grep_md 'openclaw-bootstrap|\.openclaw-install\.env' | grep -v 'docs/SLOT_TURNOVER.md:' || true
  fail "legacy_bootstrap_reference_outside_turnover_cleanup"
else
  pass "legacy_bootstrap_reference_limited"
fi

exit "$failed"
