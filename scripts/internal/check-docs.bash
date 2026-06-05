#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
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
  PUBLIC_REGISTRY_IMAGES.md \
  REMOUNT_GUIDE.md; do
  if grep_md "$removed" | grep -q .; then
    fail "removed_doc_reference_$removed"
  else
    pass "removed_doc_reference_$removed"
  fi
done

host_install_refs="$(grep_md 'git clone .*openclaw-nas-agent-baseline|git clone "\$REPO_URL"|install-svcops-account\.sh --set-password --nopasswd-sudo' || true)"
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

if grep_md '<public repo commit>|BASELINE_COMMIT="<|paste_40_hex|TODO|FIXME' | grep -q .; then
  grep_md '<public repo commit>|BASELINE_COMMIT="<|paste_40_hex|TODO|FIXME'
  fail "operator_placeholder_in_docs"
else
  pass "operator_placeholder_absent"
fi

if grep_md 'openclaw-bootstrap|\.openclaw-install\.env' | grep -v 'docs/SLOT_TURNOVER.md:' | grep -q .; then
  grep_md 'openclaw-bootstrap|\.openclaw-install\.env' | grep -v 'docs/SLOT_TURNOVER.md:' || true
  fail "legacy_bootstrap_reference_outside_turnover_cleanup"
else
  pass "legacy_bootstrap_reference_limited"
fi

if grep_md 'build-container-baseline\.sh|build-hermes-integrated-image\.sh|install-system-baseline\.sh' | grep -q .; then
  grep_md 'build-container-baseline\.sh|build-hermes-integrated-image\.sh|install-system-baseline\.sh'
  fail "removed_local_image_build_reference"
else
  pass "removed_local_image_build_reference_absent"
fi

if grep -RInE 'dashboard-20260602-r1|openclaw-overlays' \
  "$repo_root/README.md" "$repo_root/docs" "$repo_root/images" "$repo_root/.github" "$repo_root/admin-cli" \
  --include='*.md' --include='*.yml' --include='*.yaml' --include='openclaw-ops-console' 2>/dev/null | grep -q .; then
  grep -RInE 'dashboard-20260602-r1|openclaw-overlays' \
    "$repo_root/README.md" "$repo_root/docs" "$repo_root/images" "$repo_root/.github" "$repo_root/admin-cli" \
    --include='*.md' --include='*.yml' --include='*.yaml' --include='openclaw-ops-console' 2>/dev/null || true
  fail "stale_dashboard_image_reference_absent"
else
  pass "stale_dashboard_image_reference_absent"
fi

if grep -RInE 'patch-openclaw-dashboard-title|OPENCLAW_DASHBOARD_' \
  "$repo_root/images" "$repo_root/.github" "$repo_root/docs" \
  --include='*.py' --include='*.yml' --include='*.yaml' --include='*.md' 2>/dev/null | grep -q .; then
  grep -RInE 'patch-openclaw-dashboard-title|OPENCLAW_DASHBOARD_' \
    "$repo_root/images" "$repo_root/.github" "$repo_root/docs" \
    --include='*.py' --include='*.yml' --include='*.yaml' --include='*.md' 2>/dev/null || true
  fail "openclaw_dist_patch_path_absent"
else
  pass "openclaw_dist_patch_path_absent"
fi

if [[ -d "$repo_root/container" ]]; then
  fail "legacy_container_directory_present"
else
  pass "legacy_container_directory_absent"
fi

container_refs="$(grep -RIn 'container/' "$repo_root/README.md" "$repo_root/docs" "$repo_root/.github" --include='*.md' --include='*.yml' --include='*.yaml' 2>/dev/null || true)"
if printf '%s\n' "$container_refs" | grep -q .; then
  printf '%s\n' "$container_refs"
  fail "legacy_container_reference_present"
else
  pass "legacy_container_reference_absent"
fi

exit "$failed"
