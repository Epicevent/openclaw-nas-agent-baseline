#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  openclaw-ops-drift-check.sh [--registry PATH] [--control PATH] [--manifest PATH] [--report PATH]

Compares /srv/openclaw-ops/slots.yaml with live slot state.

Read-only:
  - does not print secrets
  - does not modify slots.yaml
  - calls svcops-control.sh through sudo -n
USAGE
}

registry="/srv/openclaw-ops/slots.yaml"
control="/opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh"
manifest="/opt/openclaw-nas-agent-baseline/.openclaw-baseline-manifest"
report=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --registry)
      registry="${2:?missing registry path}"
      shift 2
      ;;
    --control)
      control="${2:?missing control path}"
      shift 2
      ;;
    --manifest)
      manifest="${2:?missing manifest path}"
      shift 2
      ;;
    --report)
      report="${2:?missing report path}"
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

python3 - "$registry" "$control" "$manifest" "$report" <<'PY'
from __future__ import annotations

import os
import re
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

registry = Path(sys.argv[1])
control = sys.argv[2]
manifest = Path(sys.argv[3])
report = sys.argv[4]


def unquote(value: str) -> str:
    value = value.strip()
    if value.startswith('"') and value.endswith('"'):
        return value[1:-1]
    return value


def parse_registry(path: Path):
    meta: dict[str, str] = {}
    slots: list[dict[str, str]] = []
    section = "meta"
    current: dict[str, str] | None = None

    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.rstrip()
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if stripped == "slots:":
            section = "slots"
            continue
        if section == "meta" and line.startswith("  ") and ":" in stripped:
            key, value = stripped.split(":", 1)
            meta[key] = unquote(value)
            continue
        if section == "slots":
            if line.startswith("  - slot:"):
                if current:
                    slots.append(current)
                current = {"slot": unquote(line.split(":", 1)[1])}
                continue
            if current is not None and line.startswith("    ") and not line.startswith("      ") and ":" in stripped:
                key, value = stripped.split(":", 1)
                current[key] = unquote(value)
                continue
    if current:
        slots.append(current)
    return meta, slots


def run_command(args: list[str], timeout: int = 240):
    try:
        proc = subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
        return proc.returncode, proc.stdout
    except subprocess.TimeoutExpired as exc:
        return 124, (exc.stdout or "") + "\nTIMEOUT\n"


def parse_key_values(text: str) -> dict[str, str]:
    result: dict[str, str] = {}
    for line in text.splitlines():
        if "=" in line and re.match(r"^[A-Za-z0-9_]+=", line):
            key, value = line.split("=", 1)
            result[key] = value
    return result


def parse_key_value_file(path: Path) -> dict[str, str]:
    if not path.exists():
        return {}
    return parse_key_values(path.read_text(encoding="utf-8", errors="replace"))


def extract_mount_sources(text: str):
    customer = []
    container = []
    for line in text.splitlines():
        if line.startswith("INFO customer_nas_mount=") or line.startswith("INFO container_nas_mount="):
            _, rest = line.split(" ", 1)
            match = re.match(r"(?P<key>[^=]+)=(?P<path>\S+)\s+source=(?P<source>\S+)", rest)
            if not match:
                continue
            entry = (match.group("path"), match.group("source"))
            if match.group("key") == "customer_nas_mount":
                customer.append(entry)
            else:
                container.append(entry)
    return customer, container


meta, slots = parse_registry(registry)
expected_image_id = meta.get("image_id", "")
expected_baseline_commit = meta.get("baseline_commit", "")
installed_manifest = parse_key_value_file(manifest)
installed_baseline_commit = installed_manifest.get("source_commit", "")
started = datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")
lines: list[str] = []
failures = 0
warnings = 0

lines.append(f"drift_check_started={started}")
lines.append(f"registry={registry}")
lines.append(f"manifest={manifest}")
lines.append(f"slot_count={len(slots)}")
lines.append(f"registry_baseline_commit={expected_baseline_commit or 'missing'}")
lines.append(f"installed_baseline_commit={installed_baseline_commit or 'missing'}")
if not installed_baseline_commit:
    failures += 1
    lines.append("baseline_manifest=fail missing_or_unreadable")
elif expected_baseline_commit and installed_baseline_commit != expected_baseline_commit:
    failures += 1
    lines.append("baseline_manifest=fail commit_mismatch")
else:
    lines.append("baseline_manifest=pass")
lines.append("")

for slot in slots:
    name = slot.get("slot", "")
    status = slot.get("status", "")
    subdomain = slot.get("subdomain", f"{name}.ji-tech.co.kr")
    nas_share = slot.get("nas_share", meta.get("default_nas_share", ""))
    mount_name = slot.get("mount_name", meta.get("default_mount_name", ""))
    expected_host_path = f"/home/{name}/nas_docs/{mount_name}"
    expected_container_path = f"/home/node/nas_docs/{mount_name}"

    slot_failed = False
    slot_warn = False
    detail: list[str] = []

    check_rc, check_out = run_command(["sudo", "-n", control, "check", name, subdomain])
    fail_lines = [ln for ln in check_out.splitlines() if ln.startswith("FAIL ")]
    if check_rc != 0 or fail_lines:
        slot_failed = True
        detail.append(f"release_gate=fail rc={check_rc} fails={','.join(fail_lines[:8])}")
    else:
        detail.append("release_gate=pass")

    customer_mounts, container_mounts = extract_mount_sources(check_out)
    if (expected_host_path, nas_share) not in customer_mounts:
        slot_failed = True
        actual = ",".join(f"{p}->{s}" for p, s in customer_mounts) or "missing"
        detail.append(f"customer_nas=fail expected={expected_host_path}->{nas_share} actual={actual}")
    else:
        detail.append("customer_nas=pass")

    if (expected_container_path, nas_share) not in container_mounts:
        slot_failed = True
        actual = ",".join(f"{p}->{s}" for p, s in container_mounts) or "missing"
        detail.append(f"container_nas=fail expected={expected_container_path}->{nas_share} actual={actual}")
    else:
        detail.append("container_nas=pass")

    image_rc, image_out = run_command(["sudo", "-n", control, "image-status", name], timeout=60)
    image = parse_key_values(image_out)
    actual_image_id = image.get("container_image_id", "")
    actual_image_ref = image.get("container_image_ref", "")
    if image_rc != 0 or not actual_image_id:
        slot_failed = True
        detail.append(f"image=fail rc={image_rc}")
    elif expected_image_id and actual_image_id != expected_image_id:
        slot_failed = True
        detail.append(f"image=fail expected_id={expected_image_id} actual_id={actual_image_id} actual_ref={actual_image_ref}")
    else:
        detail.append(f"image=pass actual_ref={actual_image_ref}")

    result = "FAIL" if slot_failed else "WARN" if slot_warn else "PASS"
    if slot_failed:
        failures += 1
    elif slot_warn:
        warnings += 1

    lines.append(f"== {name} ==")
    lines.append(f"registry_status={status}")
    lines.append(f"expected_subdomain={subdomain}")
    lines.append(f"expected_nas={expected_host_path}->{nas_share}")
    lines.append(f"expected_container_nas={expected_container_path}->{nas_share}")
    lines.append(f"result={result}")
    for item in detail:
        lines.append(item)
    lines.append("")

finished = datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")
summary = "FAIL" if failures else "WARN" if warnings else "PASS"
lines.append(f"drift_check_finished={finished}")
lines.append(f"summary={summary}")
lines.append(f"failures={failures}")
lines.append(f"warnings={warnings}")

output = "\n".join(lines) + "\n"
if report:
    report_path = Path(report)
    report_path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=str(report_path.parent), delete=False) as tmp:
        tmp.write(output)
        tmp_name = tmp.name
    os.replace(tmp_name, report_path)

print(output, end="")
raise SystemExit(1 if failures else 0)
PY
