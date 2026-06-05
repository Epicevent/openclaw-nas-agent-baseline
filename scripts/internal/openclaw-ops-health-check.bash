#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  ops-monitor.sh health-check [--registry PATH] [--images PATH] [--control PATH] [--manifest PATH] [--report PATH]

Reads the lane registry and live server state.

Read-only:
  - does not print secrets
  - does not modify slots.yaml
  - calls svcops-control.sh through sudo -n
USAGE
}

registry="/srv/openclaw-ops/slots.yaml"
images="/srv/openclaw-ops/images.yaml"
control="/opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh"
manifest="/opt/openclaw-nas-agent-baseline/.openclaw-baseline-manifest"
report=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --registry)
      registry="${2:?missing registry path}"
      shift 2
      ;;
    --images)
      images="${2:?missing images path}"
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

python3 - "$registry" "$images" "$control" "$manifest" "$report" <<'PY'
from __future__ import annotations

import os
import re
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

registry = Path(sys.argv[1])
images_path = Path(sys.argv[2])
control = sys.argv[3]
manifest = Path(sys.argv[4])
report = sys.argv[5]


def unquote(value: str) -> str:
    value = value.strip()
    if value.startswith('"') and value.endswith('"'):
        return value[1:-1].replace('\\"', '"').replace("\\\\", "\\")
    if value.startswith("'") and value.endswith("'"):
        return value[1:-1]
    return value


def parse_registry(path: Path):
    meta: dict[str, str] = {}
    slots: list[dict[str, str]] = []
    if not path.exists():
        return meta, slots
    section = "meta"
    current: dict[str, str] | None = None
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.rstrip().lstrip("\ufeff")
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        indent = len(line) - len(line.lstrip(" "))
        if stripped == "meta:":
            section = "meta"
            current = None
            continue
        if stripped == "slots:":
            section = "slots"
            current = None
            continue
        if section == "meta" and indent == 2 and ":" in stripped:
            key, value = stripped.split(":", 1)
            meta[key] = unquote(value)
            continue
        if section != "slots":
            continue
        if indent == 2 and stripped.startswith("- slot:"):
            if current:
                slots.append(current)
            current = {"slot": unquote(stripped.split(":", 1)[1])}
            continue
        if current is not None and indent == 4 and ":" in stripped:
            key, value = stripped.split(":", 1)
            current[key] = unquote(value)
    if current:
        slots.append(current)
    return meta, sorted(slots, key=lambda item: slot_order(item.get("slot", "")))


def parse_image_catalog(path: Path):
    state = {"channels": {}, "images": []}
    if not path.exists():
        return state
    section = ""
    current = None
    alias_mode = False
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.rstrip().lstrip("\ufeff")
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        indent = len(line) - len(line.lstrip(" "))
        if stripped == "channels:":
            section = "channels"
            current = None
            alias_mode = False
            continue
        if stripped == "images:":
            section = "images"
            current = None
            alias_mode = False
            continue
        if section == "channels" and indent == 2 and ":" in stripped:
            key, value = stripped.split(":", 1)
            state["channels"][key] = unquote(value)
            continue
        if section == "images" and indent == 2 and stripped.startswith("- name:"):
            if current:
                state["images"].append(current)
            current = {"name": unquote(stripped.split(":", 1)[1]), "aliases": ""}
            alias_mode = False
            continue
        if section == "images" and current is not None:
            if indent == 4 and stripped == "aliases:":
                alias_mode = True
                continue
            if alias_mode and indent == 6 and stripped.startswith("- "):
                aliases = [item for item in current.get("aliases", "").split(",") if item]
                aliases.append(unquote(stripped[2:]))
                current["aliases"] = ",".join(aliases)
                continue
            alias_mode = False
            if indent == 4 and ":" in stripped:
                key, value = stripped.split(":", 1)
                current[key] = unquote(value)
                continue
    if current:
        state["images"].append(current)
    return state


def slot_order(slot: str) -> int:
    match = re.search(r"(\d+)$", slot or "")
    if match:
        return int(match.group(1))
    if slot == "dev-oc":
        return 10_001
    if slot == "dev-hermess":
        return 10_002
    return 10_999


def infer_lane(slot: dict[str, str]) -> str:
    name = slot.get("slot", "")
    lane = slot.get("lane", "")
    if lane:
        return lane
    if name == "dev-oc":
        return "dev-openclaw"
    if name == "dev-hermess":
        return "dev-hermes"
    legacy_channel = slot.get("image_channel", "")
    if legacy_channel in {"openclaw", "hermes", "hold"}:
        return legacy_channel
    legacy_name = slot.get("image_name", "") or slot.get("image_tag", "")
    if legacy_name.startswith("hermes-"):
        return "hermes"
    match = re.match(r"^oc([0-9]+)$", name)
    if match and int(match.group(1)) >= 15:
        return "hermes"
    return "openclaw"


def image_aliases(image):
    aliases = {image.get("name", ""), image.get("registry_ref", ""), image.get("runtime_ref", "")}
    aliases.update(item for item in image.get("aliases", "").split(",") if item)
    return {item for item in aliases if item}


def find_catalog_image(catalog, key):
    if not key:
        return None
    for image in catalog.get("images", []):
        if key in image_aliases(image):
            return image
    channel_target = catalog.get("channels", {}).get(key)
    if channel_target:
        return find_catalog_image(catalog, channel_target)
    return None


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
            entry = f"{match.group('path')}->{match.group('source')}"
            if match.group("key") == "customer_nas_mount":
                customer.append(entry)
            else:
                container.append(entry)
    return customer, container


def path_exists_if_readable(path: Path) -> bool | None:
    try:
        return path.exists()
    except PermissionError:
        return None


def expected_image_for_lane(catalog, lane: str):
    if lane.startswith("dev-") or lane == "hold":
        return None
    return find_catalog_image(catalog, lane)


meta, slots = parse_registry(registry)
image_catalog = parse_image_catalog(images_path)
installed_manifest = parse_key_value_file(manifest)
installed_baseline_commit = installed_manifest.get("source_commit", "")
started = datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")
lines: list[str] = []
failures = 0
warnings = 0

lines.append(f"health_check_started={started}")
lines.append(f"registry={registry}")
lines.append(f"image_registry={images_path}")
lines.append(f"manifest={manifest}")
lines.append(f"slot_count={len(slots)}")
lines.append(f"installed_baseline_commit={installed_baseline_commit or 'missing'}")
if not installed_baseline_commit:
    failures += 1
    lines.append("baseline_manifest=fail missing_or_unreadable")
else:
    lines.append("baseline_manifest=pass")
lines.append("")

for slot in slots:
    name = slot.get("slot", "")
    lane = infer_lane(slot)
    slot_type = "dev" if lane.startswith("dev-") else "customer"
    subdomain = slot.get("subdomain", f"{name}.ji-tech.co.kr")
    expected_image = expected_image_for_lane(image_catalog, lane)
    source_override = Path(f"/home/{name}/openclaw/docker-compose.source.yml")

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

    source_override_exists = path_exists_if_readable(source_override)
    if slot_type == "customer" and source_override_exists is True:
        slot_failed = True
        detail.append(f"source_mode=fail forbidden_customer_source_override={source_override}")
    elif slot_type == "dev":
        if source_override_exists is None:
            detail.append("source_mode=unknown permission_denied")
        else:
            detail.append(f"source_mode={'enabled' if source_override_exists else 'disabled'}")

    customer_mounts, container_mounts = extract_mount_sources(check_out)
    detail.append(f"customer_nas_live={','.join(customer_mounts) or 'missing'}")
    detail.append(f"container_nas_live={','.join(container_mounts) or 'missing'}")

    image_rc, image_out = run_command(["sudo", "-n", control, "image-status", name], timeout=60)
    image = parse_key_values(image_out)
    actual_image_id = image.get("container_image_id", "")
    actual_image_ref = image.get("container_image_ref", "")
    if image_rc != 0 or not actual_image_id:
        slot_failed = True
        detail.append(f"image=fail rc={image_rc}")
    elif expected_image:
        expected_image_id = expected_image.get("image_id", "")
        expected_digest = expected_image.get("digest", "")
        if expected_image_id and actual_image_id != expected_image_id:
            if expected_digest and expected_digest in actual_image_ref:
                detail.append(f"image=pass expected_digest={expected_digest} actual_ref={actual_image_ref}")
            else:
                slot_failed = True
                detail.append(f"image=fail expected_id={expected_image_id} actual_id={actual_image_id} actual_ref={actual_image_ref}")
        elif expected_digest and actual_image_ref and "@" in actual_image_ref and expected_digest not in actual_image_ref:
            slot_failed = True
            detail.append(f"image=fail expected_digest={expected_digest} actual_ref={actual_image_ref} actual_id={actual_image_id}")
        else:
            detail.append(f"image=pass actual_ref={actual_image_ref}")
    else:
        if lane in {"openclaw", "hermes"}:
            slot_warn = True
            detail.append(f"image=warn no_channel_for_lane={lane} actual_ref={actual_image_ref}")
        else:
            detail.append(f"image=info lane={lane} actual_ref={actual_image_ref}")

    result = "FAIL" if slot_failed else "WARN" if slot_warn else "PASS"
    if slot_failed:
        failures += 1
    elif slot_warn:
        warnings += 1

    lines.append(f"== {name} ==")
    lines.append(f"slot_lane={lane}")
    lines.append(f"slot_type={slot_type}")
    lines.append(f"host={subdomain}")
    if expected_image:
        lines.append(f"expected_image_name={expected_image.get('name', '')}")
        lines.append(f"expected_image_ref={expected_image.get('runtime_ref') or expected_image.get('registry_ref', '')}")
        lines.append(f"expected_image_id={expected_image.get('image_id', '')}")
        if expected_image.get("digest"):
            lines.append(f"expected_image_digest={expected_image.get('digest')}")
    else:
        lines.append("expected_image_name=none")
    lines.append(f"result={result}")
    for item in detail:
        lines.append(item)
    lines.append("")

finished = datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")
summary = "FAIL" if failures else "WARN" if warnings else "PASS"
lines.append(f"health_check_finished={finished}")
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
