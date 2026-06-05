#!/usr/bin/env bash
set -euo pipefail

interval="${OPENCLAW_OPS_HEALTH_INTERVAL_SECONDS:-300}"
report_dir="${OPENCLAW_OPS_REPORT_DIR:-/srv/openclaw-ops/reports}"
checker="${OPENCLAW_OPS_HEALTH_CHECKER:-/opt/openclaw-nas-agent-baseline/scripts/internal/openclaw-ops-health-check.bash}"

mkdir -p "$report_dir"

while true; do
  ts="$(date -Iseconds)"
  latest="$report_dir/health-latest.txt"
  history="$report_dir/health-${ts//[:+]/_}.txt"
  echo "health_watch_tick=$ts"
  if bash "$checker" --report "$latest"; then
    result=PASS
  else
    result=FAIL
  fi
  cp "$latest" "$history" 2>/dev/null || true
  echo "health_watch_result=$result"
  sleep "$interval"
done
