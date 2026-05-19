#!/usr/bin/env bash
set -euo pipefail

USER_PREFIX="${USER_PREFIX:-oc}"
USER_START="${USER_START:-1}"
USER_END="${USER_END:-20}"
NAS_REL="${NAS_REL:-nas_docs}"

printf '%-6s %-8s %-8s %-10s %-10s %-10s %s\n' "USER" "EXISTS" "HOME" "NAS_DIR" "MOUNTED" "OPENCLAW" "SHELL"

for i in $(seq "$USER_START" "$USER_END"); do
  user="${USER_PREFIX}${i}"
  if entry="$(getent passwd "$user")"; then
    IFS=: read -r _ _ _ _ _ home shell <<<"$entry"
    [[ -d "$home" ]] && home_ok=yes || home_ok=no
    [[ -d "$home/$NAS_REL" ]] && nas_ok=yes || nas_ok=no
    mountpoint -q "$home/$NAS_REL" && mounted=yes || mounted=no
    if runuser -u "$user" -- sh -lc 'command -v openclaw >/dev/null 2>&1'; then
      openclaw_ok=yes
    else
      openclaw_ok=no
    fi
    printf '%-6s %-8s %-8s %-10s %-10s %-10s %s\n' "$user" yes "$home_ok" "$nas_ok" "$mounted" "$openclaw_ok" "$shell"
  else
    printf '%-6s %-8s %-8s %-10s %-10s %-10s %s\n' "$user" no "-" "-" "-" "-" "-"
  fi
done
