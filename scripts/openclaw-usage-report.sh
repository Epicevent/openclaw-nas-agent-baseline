#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  openclaw-usage-report.sh --user USER [--since WINDOW]
  openclaw-usage-report.sh --range START END [--since WINDOW]

Read-only usage summary for OpenClaw customer slots.

WINDOW defaults to 24h and is passed to docker logs --since. Supported examples:
  30m, 24h, 7d, 2026-05-26T00:00:00+09:00

The report prints counters and timestamps only. It does not print log contents,
NAS credentials, gateway tokens, or provider/API keys.
USAGE
}

target_user=""
range_start=""
range_end=""
since_window="24h"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user)
      target_user="${2:?missing user}"
      shift 2
      ;;
    --range)
      range_start="${2:?missing start}"
      range_end="${3:?missing end}"
      shift 3
      ;;
    --since)
      since_window="${2:?missing since window}"
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

validate_user_name() {
  local user="$1"
  [[ "$user" =~ ^oc[1-9][0-9]*$ ]] || {
    echo "error: invalid customer user: $user" >&2
    exit 2
  }
}

validate_since_window() {
  local value="$1"
  [[ "$value" =~ ^[A-Za-z0-9:TZ+_.-]+$ ]] || {
    echo "error: invalid since window: $value" >&2
    exit 2
  }
}

since_seconds_for_container_scan() {
  local value="$1" n unit
  if [[ "$value" =~ ^([0-9]+)(m|h|d)$ ]]; then
    n="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[2]}"
    case "$unit" in
      m) printf '%s' "$((n * 60))" ;;
      h) printf '%s' "$((n * 3600))" ;;
      d) printf '%s' "$((n * 86400))" ;;
    esac
  else
    printf '86400'
  fi
}

docker_since_window() {
  local value="$1" n
  if [[ "$value" =~ ^([0-9]+)d$ ]]; then
    n="${BASH_REMATCH[1]}"
    printf '%sh' "$((n * 24))"
  else
    printf '%s' "$value"
  fi
}

container_name_for_user() {
  printf 'openclaw-%s-openclaw-gateway-1' "$1"
}

count_matching_lines() {
  local pattern="$1" file="$2"
  grep -Eic "$pattern" "$file" 2>/dev/null || true
}

container_activity_python() {
  cat <<'PY'
import datetime
import os
import sys
import time

since_seconds = int(sys.argv[1])
now = time.time()
cutoff = now - since_seconds

groups = [
    ("app_log", ["/tmp/openclaw"], (".log",)),
    ("state", ["/home/node/.openclaw", "/home/node/.config/openclaw"], None),
    ("workspace", ["/home/node/.openclaw/workspace"], None),
]

def iso(ts):
    return datetime.datetime.fromtimestamp(ts, datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")

overall_latest = 0.0
for name, roots, suffixes in groups:
    recent_count = 0
    recent_bytes = 0
    total_count = 0
    latest = 0.0
    for root in roots:
        if not os.path.exists(root):
            continue
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = [d for d in dirnames if d not in {".git", "node_modules"}]
            for filename in filenames:
                if suffixes and not filename.endswith(suffixes):
                    continue
                path = os.path.join(dirpath, filename)
                try:
                    st = os.stat(path)
                except OSError:
                    continue
                total_count += 1
                if st.st_mtime > latest:
                    latest = st.st_mtime
                if st.st_mtime >= cutoff:
                    recent_count += 1
                    recent_bytes += st.st_size
    if latest > overall_latest:
        overall_latest = latest
    print(f"container_{name}_files_total={total_count}")
    print(f"container_{name}_files_recent={recent_count}")
    print(f"container_{name}_bytes_recent={recent_bytes}")
    print(f"container_{name}_latest_at={iso(latest) if latest else 'none'}")

print(f"container_file_latest_at={iso(overall_latest) if overall_latest else 'none'}")
PY
}

print_usage_for_user() {
  local user="$1" since="$2" since_seconds docker_since container tmp logs_rc status health started image_id log_lines error_lines warn_lines last_log_at file_latest
  validate_user_name "$user"
  echo "target_user=$user"
  echo "usage_window=$since"

  if ! id "$user" >/dev/null 2>&1; then
    echo "user_status=missing"
    return 1
  fi
  echo "user_status=present"

  container="$(container_name_for_user "$user")"
  echo "container=$container"
  if ! docker inspect "$container" >/dev/null 2>&1; then
    echo "container_status=missing"
    return 1
  fi

  status="$(docker inspect "$container" --format '{{.State.Status}}' 2>/dev/null || echo unknown)"
  health="$(docker inspect "$container" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' 2>/dev/null || echo unknown)"
  started="$(docker inspect "$container" --format '{{.State.StartedAt}}' 2>/dev/null || echo unknown)"
  image_id="$(docker inspect "$container" --format '{{.Image}}' 2>/dev/null || echo unknown)"
  echo "container_status=$status"
  echo "container_health=$health"
  echo "container_started_at=$started"
  echo "container_image_id=$image_id"

  tmp="$(mktemp)"
  logs_rc=0
  docker_since="$(docker_since_window "$since")"
  echo "docker_since_window=$docker_since"
  docker logs --timestamps --since "$docker_since" "$container" >"$tmp" 2>&1 || logs_rc=$?
  log_lines="$(wc -l <"$tmp" | tr -d ' ')"
  error_lines="$(count_matching_lines 'error|exception|fatal|panic|traceback|failed|fail' "$tmp")"
  warn_lines="$(count_matching_lines 'warn|warning' "$tmp")"
  last_log_at="$(awk '/^[0-9]{4}-[0-9]{2}-[0-9]{2}T/ { print $1 }' "$tmp" | tail -1)"
  echo "docker_logs_rc=$logs_rc"
  echo "docker_log_lines_since=$log_lines"
  echo "docker_log_error_lines_since=$error_lines"
  echo "docker_log_warn_lines_since=$warn_lines"
  echo "docker_log_last_at=${last_log_at:-none}"
  rm -f "$tmp"

  since_seconds="$(since_seconds_for_container_scan "$since")"
  docker exec -i "$container" python3 - "$since_seconds" <<PY 2>/dev/null || echo "container_file_activity=unavailable"
$(container_activity_python)
PY
}

validate_since_window "$since_window"

if [[ -n "$target_user" && -n "$range_start" ]]; then
  echo "error: use either --user or --range, not both" >&2
  exit 2
fi

if [[ -n "$target_user" ]]; then
  print_usage_for_user "$target_user" "$since_window"
  exit $?
fi

if [[ -n "$range_start" || -n "$range_end" ]]; then
  [[ "$range_start" =~ ^[0-9]+$ && "$range_end" =~ ^[0-9]+$ && "$range_start" -le "$range_end" ]] || {
    echo "error: invalid range" >&2
    exit 2
  }
  failed=0
  for i in $(seq "$range_start" "$range_end"); do
    echo "== oc$i =="
    print_usage_for_user "oc$i" "$since_window" || failed=1
  done
  exit "$failed"
fi

usage >&2
exit 2
