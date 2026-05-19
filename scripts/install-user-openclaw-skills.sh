#!/usr/bin/env bash
set -euo pipefail

USER_PREFIX="${USER_PREFIX:-oc}"
USER_START="${USER_START:-1}"
USER_END="${USER_END:-20}"

SKILLS=(
  hwp-reader
  hwp-extract-pipeline
  pdf
  document-parser
  spreadsheet
  summarize
  clawhub
  session-logs
  skill-creator
)

run_for_user() {
  local user="$1"
  if ! getent passwd "$user" >/dev/null; then
    echo "skip missing user: $user"
    return 0
  fi

  echo "== $user =="
  runuser -u "$user" -- sh -lc 'openclaw --version >/dev/null'

  for skill in "${SKILLS[@]}"; do
    echo "install skill for $user: $skill"
    runuser -u "$user" -- sh -lc "openclaw skills install '$skill' || true"
  done

  runuser -u "$user" -- sh -lc 'openclaw skills check || true'
}

if [[ "$(id -u)" -eq 0 ]]; then
  for i in $(seq "$USER_START" "$USER_END"); do
    run_for_user "${USER_PREFIX}${i}"
  done
else
  for skill in "${SKILLS[@]}"; do
    echo "install skill: $skill"
    openclaw skills install "$skill" || true
  done
  openclaw skills check || true
fi
