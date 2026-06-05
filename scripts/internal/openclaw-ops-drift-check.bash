#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  ops-monitor.sh drift-check [--registry PATH] [--images PATH] [--control PATH] [--manifest PATH] [--report PATH]

Compares /srv/openclaw-ops/slots.yaml with live slot state.

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


def resolve_expected_image(slot, meta, catalog):
    if catalog.get("images"):
        for key_name in ("image_name", "image_channel", "image_tag"):
            value = slot.get(key_name, "")
            image = find_catalog_image(catalog, value)
            if image:
                return {
                    "source": key_name,
                    "name": image.get("name", ""),
                    "ref": image.get("runtime_ref") or image.get("registry_ref", ""),
                    "digest": image.get("digest", ""),
                    "image_id": image.get("image_id", ""),
                    "status": image.get("status", ""),
                    "family": image.get("family", ""),
                    "source_repo": image.get("source_repo", ""),
                    "source_ref": image.get("source_ref", ""),
                    "base_image": image.get("base_image", ""),
                    "workspace_image": image.get("workspace_image", ""),
                    "unresolved": "",
                }
            if value and key_name in {"image_name", "image_channel"}:
                return {
                    "source": key_name,
                    "name": value,
                    "ref": "",
                    "digest": "",
                    "image_id": "",
                    "status": "",
                    "family": "",
                    "source_repo": "",
                    "source_ref": "",
                    "base_image": "",
                    "workspace_image": "",
                    "unresolved": value,
                }
    return {
        "source": "meta",
        "name": meta.get("image_tag", ""),
        "ref": meta.get("image_tag", ""),
        "digest": "",
        "image_id": meta.get("image_id", ""),
        "status": "",
        "family": "",
        "source_repo": "",
        "source_ref": "",
        "base_image": "",
        "workspace_image": "",
        "unresolved": "",
    }


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
image_catalog = parse_image_catalog(images_path)
expected_baseline_commit = meta.get("baseline_commit", "")
installed_manifest = parse_key_value_file(manifest)
installed_baseline_commit = installed_manifest.get("source_commit", "")
started = datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")
lines: list[str] = []
failures = 0
warnings = 0

lines.append(f"drift_check_started={started}")
lines.append(f"registry={registry}")
lines.append(f"image_registry={images_path}")
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
    expected_image = resolve_expected_image(slot, meta, image_catalog)

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
    root_match = re.search(r"^INFO container_nas_root=(?P<root>\S+)", check_out, re.MULTILINE)
    expected_container_root = root_match.group("root") if root_match else "/home/node/nas_docs"
    expected_container_path = f"{expected_container_root}/{mount_name}"
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
    expected_image_id = expected_image.get("image_id", "")
    expected_digest = expected_image.get("digest", "")
    if image_rc != 0 or not actual_image_id:
        slot_failed = True
        detail.append(f"image=fail rc={image_rc}")
    elif expected_image.get("unresolved"):
        slot_failed = True
        detail.append(f"image=fail unresolved_expected={expected_image.get('unresolved')} source={expected_image.get('source')}")
    elif expected_image_id and actual_image_id != expected_image_id:
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
    lines.append(f"expected_image_source={expected_image.get('source', '')}")
    lines.append(f"expected_image_name={expected_image.get('name', '') or 'missing'}")
    if expected_image.get("family"):
        lines.append(f"expected_image_family={expected_image.get('family')}")
    if expected_image.get("source_repo"):
        lines.append(f"expected_image_source_repo={expected_image.get('source_repo')}")
    if expected_image.get("source_ref"):
        lines.append(f"expected_image_source_ref={expected_image.get('source_ref')}")
    if expected_image.get("base_image"):
        lines.append(f"expected_image_base={expected_image.get('base_image')}")
    if expected_image.get("workspace_image"):
        lines.append(f"expected_image_workspace={expected_image.get('workspace_image')}")
    lines.append(f"expected_image_ref={expected_image.get('ref', '') or 'missing'}")
    lines.append(f"expected_image_id={expected_image.get('image_id', '') or 'missing'}")
    if expected_image.get("digest"):
        lines.append(f"expected_image_digest={expected_image.get('digest')}")
    if expected_image.get("status"):
        lines.append(f"expected_image_status={expected_image.get('status')}")
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
