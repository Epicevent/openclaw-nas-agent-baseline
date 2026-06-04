#!/usr/bin/env bash
set -euo pipefail

interval_seconds="${OPENCLAW_OPS_DRIFT_INTERVAL_SECONDS:-900}"
registry="${OPENCLAW_OPS_REGISTRY:-/srv/openclaw-ops/slots.yaml}"
images="${OPENCLAW_OPS_IMAGES:-/srv/openclaw-ops/images.yaml}"
report_dir="${OPENCLAW_OPS_REPORT_DIR:-/srv/openclaw-ops/reports}"
checker="${OPENCLAW_OPS_DRIFT_CHECKER:-/opt/openclaw-nas-agent-baseline/scripts/internal/openclaw-ops-drift-check.bash}"

mkdir -p "$report_dir"

while true; do
  ts="$(date -Iseconds)"
  latest="$report_dir/drift-latest.txt"
  history="$report_dir/drift-${ts//[:+]/_}.txt"
  echo "drift_watch_tick=$ts"
  if "$checker" --registry "$registry" --images "$images" --report "$latest"; then
    result="PASS"
  else
    result="FAIL"
  fi
  cp "$latest" "$history" 2>/dev/null || true
  echo "drift_watch_result=$result"
  sleep "$interval_seconds"
done
