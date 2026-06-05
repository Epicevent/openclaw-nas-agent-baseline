#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  ops-monitor.sh nas-request-check [--registry PATH] [--policy PATH] [--control PATH] [--start N] [--end N] [--actions-log PATH]
  ops-monitor.sh nas-request-watch [same args]

Approves or rejects customer NAS share requests by account grant policy.
The monitor never reads or stores NAS passwords.
USAGE
}

mode="${1:-check}"
[[ "$mode" == "check" || "$mode" == "watch" ]] || { usage >&2; exit 2; }
shift || true

registry="/srv/openclaw-ops/slots.yaml"
policy="/srv/openclaw-ops/nas-policy.yaml"
control="/opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh"
actions_log="/srv/openclaw-ops/reports/actions.log"
start=1
end=20
interval="${OPENCLAW_NAS_REQUEST_INTERVAL_SECONDS:-30}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --registry)
      registry="${2:?missing registry path}"
      shift 2
      ;;
    --policy)
      policy="${2:?missing policy path}"
      shift 2
      ;;
    --control)
      control="${2:?missing control path}"
      shift 2
      ;;
    --actions-log)
      actions_log="${2:?missing actions log path}"
      shift 2
      ;;
    --start)
      start="${2:?missing start}"
      shift 2
      ;;
    --end)
      end="${2:?missing end}"
      shift 2
      ;;
    --interval)
      interval="${2:?missing interval}"
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

run_once() {
  python3 - "$registry" "$policy" "$control" "$actions_log" "$start" "$end" <<'PY'
from __future__ import annotations

import fnmatch
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

registry = Path(sys.argv[1])
policy_path = Path(sys.argv[2])
control = sys.argv[3]
actions_log = Path(sys.argv[4])
start = int(sys.argv[5])
end = int(sys.argv[6])


def now_iso() -> str:
    return datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")


def unquote(value: str) -> str:
    value = value.strip()
    if value.startswith('"') and value.endswith('"'):
        return value[1:-1].replace('\\"', '"').replace("\\\\", "\\")
    if value.startswith("'") and value.endswith("'"):
        return value[1:-1]
    return value


def parse_slots(path: Path) -> dict[str, str]:
    lanes: dict[str, str] = {}
    if not path.exists():
        return lanes
    current = ""
    section = ""
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.rstrip().lstrip("\ufeff")
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        indent = len(line) - len(line.lstrip(" "))
        if stripped == "slots:":
            section = "slots"
            continue
        if section != "slots":
            continue
        if indent == 2 and stripped.startswith("- slot:"):
            current = unquote(stripped.split(":", 1)[1])
            lanes.setdefault(current, infer_lane(current, ""))
            continue
        if current and indent == 4 and ":" in stripped:
            key, value = stripped.split(":", 1)
            if key == "lane":
                lanes[current] = unquote(value)
            elif key == "image_channel" and current not in lanes:
                lanes[current] = unquote(value)
    return lanes


def infer_lane(user: str, value: str = "") -> str:
    if value in {"openclaw", "hermes", "hold", "dev-openclaw", "dev-hermes"}:
        return value
    if user == "dev-oc":
        return "dev-openclaw"
    if user == "dev-hermess":
        return "dev-hermes"
    match = re.match(r"^oc([0-9]+)$", user)
    if match and int(match.group(1)) >= 15:
        return "hermes"
    return "openclaw"


def parse_policy(path: Path) -> dict:
    state = {"defaults": {"auto_approve": "false"}, "accounts": {}}
    if not path.exists():
        return state
    section = ""
    account = ""
    grants_mode = False
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.rstrip().lstrip("\ufeff")
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        indent = len(line) - len(line.lstrip(" "))
        if stripped == "defaults:":
            section = "defaults"
            account = ""
            grants_mode = False
            continue
        if stripped == "accounts:":
            section = "accounts"
            account = ""
            grants_mode = False
            continue
        if section == "defaults" and indent == 2 and ":" in stripped:
            key, value = stripped.split(":", 1)
            state["defaults"][key] = unquote(value)
            continue
        if section == "accounts" and indent == 2 and stripped.endswith(":"):
            account = stripped[:-1]
            state["accounts"].setdefault(account, {"grants": []})
            grants_mode = False
            continue
        if section == "accounts" and account and indent == 4:
            if stripped == "grants:":
                grants_mode = True
                continue
            if ":" in stripped and not stripped.startswith("- "):
                key, value = stripped.split(":", 1)
                state["accounts"][account][key] = unquote(value)
                grants_mode = False
                continue
        if section == "accounts" and account and grants_mode and indent == 6 and stripped.startswith("- allow:"):
            state["accounts"][account]["grants"].append(unquote(stripped.split(":", 1)[1]))
            continue
    return state


def bool_value(value: str) -> bool:
    return str(value).strip().lower() in {"1", "true", "yes", "on"}


def command_prefix() -> list[str]:
    if os.environ.get("OPENCLAW_OPS_MONITOR_NO_SUDO") == "1":
        return [control]
    if os.geteuid() == 0:
        return [control]
    return ["sudo", "-n", control]


def run_control(args: list[str], timeout: int = 180) -> tuple[int, str, float]:
    started = time.monotonic()
    try:
        proc = subprocess.run(command_prefix() + args, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
        duration = time.monotonic() - started
        return proc.returncode, proc.stdout, duration
    except subprocess.TimeoutExpired as exc:
        duration = time.monotonic() - started
        return 124, (exc.stdout or "") + "\nTIMEOUT\n", duration


def parse_request_blocks(text: str):
    blocks: dict[str, dict[str, str]] = {}
    current = ""
    for line in text.splitlines():
        match = re.match(r"^==\s+((?:oc[0-9]+)|dev-oc|dev-hermess)\s+==$", line.strip())
        if match:
            current = match.group(1)
            blocks[current] = {}
            continue
        if current and "=" in line and re.match(r"^[A-Za-z0-9_]+=", line):
            key, value = line.split("=", 1)
            blocks[current][key] = value
    return blocks


def parse_status_count(text: str) -> int:
    count = 0
    for line in text.splitlines():
        if re.match(r"^registered_child_mount_[0-9]+=", line):
            count += 1
    return count


def valid_share(share: str) -> bool:
    return bool(re.match(r"^//[^/\s,]+/[^/\s,]+$", share or ""))


def grant_valid(pattern: str) -> bool:
    if pattern == "*":
        return True
    return bool(re.match(r"^//[^/\s,]+/[^/\s,]*\*?[^/\s,]*$", pattern or ""))


def grant_matches(pattern: str, share: str) -> bool:
    if pattern == "*":
        return True
    if not grant_valid(pattern):
        return False
    return fnmatch.fnmatchcase(share, pattern)


def safe_reason(reason: str) -> str:
    reason = re.sub(r"[^A-Za-z0-9_.:-]+", "_", reason.strip())[:80]
    return reason or "policy_denied"


def log_action(action: str, user: str, params: dict, exit_code: int, duration: float, output: str) -> None:
    event = {
        "timestamp": now_iso(),
        "actor": os.environ.get("SUDO_USER") or os.environ.get("USER") or "unknown",
        "action": action,
        "slot": user,
        "params": params,
        "exit_code": exit_code,
        "duration_seconds": round(duration, 3),
        "summary": "\n".join(output.splitlines()[:12])[:2048],
    }
    actions_log.parent.mkdir(parents=True, exist_ok=True)
    with actions_log.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(event, ensure_ascii=False) + "\n")
    try:
        os.chmod(actions_log, 0o600)
    except PermissionError:
        pass


def evaluate(user: str, request: dict[str, str], lane: str, policy: dict) -> tuple[bool, str, dict]:
    share = request.get("requested_share", "")
    account = (policy.get("accounts") or {}).get(user)
    if lane.startswith("dev-"):
        return False, "dev_slot_denied", {}
    if lane == "hold":
        return False, "hold_lane_denied", {}
    if request.get("request_path_override") == "yes":
        return False, "path_override_denied", {}
    if request.get("mount_name") == "invalid":
        return False, "unsafe_mount_name", {}
    if not account:
        return False, "policy_missing", {}
    if not bool_value(account.get("auto_approve", policy.get("defaults", {}).get("auto_approve", "false"))):
        return False, "auto_approve_false", {}
    if not valid_share(share):
        return False, "invalid_share", {}
    grants = [grant for grant in account.get("grants", []) if grant]
    if not grants:
        return False, "grants_missing", {}
    if not any(grant_matches(grant, share) for grant in grants):
        return False, "grant_mismatch", {"grants": grants}
    max_mounts = str(account.get("max_mounts", "1"))
    if max_mounts != "unlimited":
        if not re.match(r"^[0-9]+$", max_mounts):
            return False, "invalid_max_mounts", {}
        rc, status_out, _ = run_control(["nas-status", user], timeout=60)
        if rc != 0:
            return False, "nas_status_failed", {}
        if parse_status_count(status_out) >= int(max_mounts):
            return False, "max_mounts_exceeded", {"max_mounts": max_mounts}
    return True, "grant_matched", {"grants": grants, "max_mounts": max_mounts}


def main() -> int:
    lanes = parse_slots(registry)
    policy = parse_policy(policy_path)
    users = [f"oc{i}" for i in range(start, end + 1)]
    for user in sorted(lanes):
        if user.startswith("dev-") and user not in users:
            users.append(user)
    requests: dict[str, dict[str, str]] = {}
    request_failures = 0
    for user in users:
        rc, out, _ = run_control(["nas-request", user], timeout=60)
        if rc != 0:
            if "user not found" not in out and "invalid managed slot" not in out:
                print(out, end="" if out.endswith("\n") else "\n")
                request_failures += 1
            continue
        requests.update(parse_request_blocks(out))
    handled = 0
    failed = request_failures
    for user, block in requests.items():
        if block.get("share_request") != "present":
            continue
        share = block.get("requested_share", "")
        lane = lanes.get(user) or infer_lane(user)
        ok, reason, detail = evaluate(user, block, lane, policy)
        if ok:
            print(f"== {user} ==")
            print(f"request=approve share={share} lane={lane} reason={reason}")
            approve_rc, approve_out, duration = run_control(["nas-approve-share", user], timeout=240)
            print(approve_out, end="" if approve_out.endswith("\n") else "\n")
            log_action("nas-auto-approve", user, {"requested_share": share, "lane": lane, **detail}, approve_rc, duration, approve_out)
            handled += 1
            if approve_rc != 0:
                failed += 1
        else:
            print(f"== {user} ==")
            print(f"request=reject share={share or 'missing'} lane={lane} reason={reason}")
            reject_rc, reject_out, duration = run_control(["nas-reject-share", user, safe_reason(reason)], timeout=120)
            print(reject_out, end="" if reject_out.endswith("\n") else "\n")
            log_action("nas-auto-reject", user, {"requested_share": share, "lane": lane, "reason": reason, **detail}, reject_rc, duration, reject_out)
            handled += 1
            if reject_rc != 0:
                failed += 1
    print(f"nas_request_check_finished={now_iso()}")
    print(f"handled={handled}")
    print(f"failures={failed}")
    return 1 if failed else 0


raise SystemExit(main())
PY
}

if [[ "$mode" == "check" ]]; then
  run_once
else
  while true; do
    echo "nas_request_watch_tick=$(date -Iseconds)"
    if run_once; then
      echo "nas_request_watch_result=PASS"
    else
      echo "nas_request_watch_result=FAIL"
    fi
    sleep "$interval"
  done
fi
