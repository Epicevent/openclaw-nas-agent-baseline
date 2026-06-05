#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

try:
    import grp
except ImportError:  # Windows local syntax tests.
    grp = None  # type: ignore[assignment]


DEFAULT_OPS_DIR = Path("/srv/openclaw-ops")
DEFAULT_SLOTS = DEFAULT_OPS_DIR / "slots.yaml"
DEFAULT_IMAGES = DEFAULT_OPS_DIR / "images.yaml"
DEFAULT_ACTIONS_LOG = DEFAULT_OPS_DIR / "reports" / "actions.log"
DEFAULT_IMAGE_HISTORY = DEFAULT_OPS_DIR / "reports" / "image-history"
DEFAULT_CONTROL = Path("/opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh")

IMAGE_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
CHANNEL_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
SLOT_RE = re.compile(r"^oc[1-9][0-9]*$")
SECRET_ENV_RE = re.compile(r"(?i)(api[_-]?key|token|password|passwd|credential|secret)")
ALLOWED_STATUSES = {"candidate", "staging", "approved", "failed", "retired"}
ROLLABLE_STATUSES = {"staging", "approved"}


def now_iso() -> str:
    return datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")


def run(args: list[str], timeout: int = 600, check: bool = False) -> tuple[int, str]:
    try:
        proc = subprocess.run(
            args,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=timeout,
        )
        if check and proc.returncode != 0:
            raise RuntimeError(f"command failed rc={proc.returncode}: {' '.join(args)}\n{proc.stdout}")
        return proc.returncode, proc.stdout
    except subprocess.TimeoutExpired as exc:
        return 124, (exc.stdout or "") + "\nTIMEOUT\n"


def q(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def unquote(value: str) -> str:
    value = value.strip()
    if value.startswith('"') and value.endswith('"'):
        return value[1:-1].replace('\\"', '"').replace("\\\\", "\\")
    if value.startswith("'") and value.endswith("'"):
        return value[1:-1]
    return value


def validate_image_name(name: str) -> str:
    if not IMAGE_NAME_RE.match(name):
        raise SystemExit(f"error: invalid image name: {name}")
    return name


def validate_channel(name: str) -> str:
    if not CHANNEL_RE.match(name):
        raise SystemExit(f"error: invalid image channel: {name}")
    return name


def validate_slot(name: str) -> str:
    if not SLOT_RE.match(name):
        raise SystemExit(f"error: invalid slot: {name}")
    return name


def validate_slot_number(value: str) -> int:
    if not re.match(r"^[0-9]+$", value or ""):
        raise SystemExit(f"error: invalid slot number: {value}")
    number = int(value)
    if number < 1 or number > 999:
        raise SystemExit(f"error: slot number out of range: {value}")
    return number


def validate_ref(ref: str) -> str:
    if not ref or any(ch.isspace() for ch in ref) or ref.startswith("-"):
        raise SystemExit(f"error: invalid image ref: {ref}")
    if "/" not in ref:
        raise SystemExit("error: registry image ref is required, for example ghcr.io/epicevent/openclaw-nas-agent:tag")
    return ref


def image_name_from_ref(ref: str) -> str:
    tail = ref.split("/", 1)[-1].split("/")[-1]
    if "@" in tail:
        base = tail.split("@", 1)[0]
        suffix = tail.split("@", 1)[1].replace(":", "-")[:24]
        name = f"{base}-{suffix}"
    elif ":" in tail:
        name = tail.rsplit(":", 1)[1]
    else:
        name = tail
    name = re.sub(r"[^A-Za-z0-9._-]+", "-", name).strip("-")
    return validate_image_name(name or "image")


def split_ref_repository(ref: str) -> str:
    if "@" in ref:
        return ref.split("@", 1)[0]
    if ":" in ref.rsplit("/", 1)[-1]:
        return ref.rsplit(":", 1)[0]
    return ref


def parse_images(path: Path) -> dict[str, Any]:
    state: dict[str, Any] = {"meta": {}, "channels": {}, "images": []}
    if not path.exists():
        state["meta"] = {"schema_version": "1", "source_of_truth": "true", "registry": "public"}
        return state
    section = ""
    current: dict[str, str] | None = None
    alias_mode = False
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.rstrip().lstrip("\ufeff")
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        indent = len(line) - len(line.lstrip(" "))
        if stripped == "meta:":
            section = "meta"
            current = None
            alias_mode = False
            continue
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
        if section == "meta" and indent == 2 and ":" in stripped:
            key, value = stripped.split(":", 1)
            state["meta"][key] = unquote(value)
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
                current["aliases"] = current.get("aliases", "")
                continue
            if alias_mode and indent == 6 and stripped.startswith("- "):
                alias = unquote(stripped[2:])
                aliases = [item for item in current.get("aliases", "").split(",") if item]
                aliases.append(alias)
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


def write_images(path: Path, state: dict[str, Any]) -> None:
    meta = state.get("meta") or {}
    channels = state.get("channels") or {}
    images = state.get("images") or []
    lines: list[str] = []
    lines.append("# OpenClaw public image release cache.\n")
    lines.append("# Image contents are public; secrets and customer state stay outside images.\n")
    lines.append("meta:\n")
    for key in ("schema_version", "source_of_truth", "registry", "updated_at"):
        value = str(meta.get(key, ""))
        if value:
            lines.append(f"  {key}: {q(value)}\n")
    lines.append("\nchannels:\n")
    if channels:
        for key in sorted(channels):
            lines.append(f"  {key}: {q(str(channels[key]))}\n")
    else:
        lines.append("  default: \"\"\n")
    lines.append("\nimages:\n")
    for image in sorted(images, key=lambda item: item.get("name", "")):
        lines.append(f"  - name: {q(str(image.get('name', '')))}\n")
        for key in (
            "family",
            "version",
            "source_repo",
            "source_ref",
            "agent_source_repo",
            "agent_source_ref",
            "workspace_source_repo",
            "workspace_source_ref",
            "base_image",
            "workspace_image",
            "registry_ref",
            "runtime_ref",
            "digest",
            "image_id",
            "status",
            "role",
            "created_at",
            "updated_at",
            "verified_at",
            "last_error",
        ):
            value = str(image.get(key, ""))
            if value:
                lines.append(f"    {key}: {q(value)}\n")
        aliases = [item for item in str(image.get("aliases", "")).split(",") if item]
        if aliases:
            lines.append("    aliases:\n")
            for alias in aliases:
                lines.append(f"      - {q(alias)}\n")
    atomic_write(path, "".join(lines), default_mode=0o640)


def atomic_write(path: Path, text: str, default_mode: int = 0o640) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        st = path.stat()
        mode = stat.S_IMODE(st.st_mode)
        uid = st.st_uid
        gid = st.st_gid
    else:
        mode = default_mode
        uid = 0 if os.geteuid() == 0 else os.geteuid()
        try:
            gid = grp.getgrnam("svcops").gr_gid if grp is not None else os.getegid()
        except Exception:
            gid = os.getegid()
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
        os.chmod(tmp_name, mode)
        if hasattr(os, "chown"):
            try:
                os.chown(tmp_name, uid, gid)
            except PermissionError:
                pass
        os.replace(tmp_name, path)
    finally:
        try:
            os.unlink(tmp_name)
        except FileNotFoundError:
            pass


def image_aliases(image: dict[str, str]) -> set[str]:
    aliases = {image.get("name", ""), image.get("registry_ref", ""), image.get("runtime_ref", "")}
    aliases.update(item for item in image.get("aliases", "").split(",") if item)
    return {item for item in aliases if item}


def find_image(state: dict[str, Any], key: str) -> dict[str, str] | None:
    for image in state.get("images", []):
        if key in image_aliases(image):
            return image
    channel_target = (state.get("channels") or {}).get(key)
    if channel_target:
        return find_image(state, str(channel_target))
    return None


def upsert_image(state: dict[str, Any], image: dict[str, str]) -> None:
    name = image["name"]
    state["images"] = [item for item in state.get("images", []) if item.get("name") != name]
    state["images"].append(image)
    state.setdefault("meta", {})["updated_at"] = now_iso()


def docker_pull(ref: str) -> None:
    print(f"pull_ref={ref}")
    rc, out = run(["docker", "pull", ref], timeout=1800)
    print(out, end="")
    if rc != 0:
        raise SystemExit(rc)


def docker_inspect_image(ref: str) -> dict[str, Any]:
    rc, out = run(["docker", "image", "inspect", ref], timeout=120)
    if rc != 0:
        raise SystemExit(f"error: docker image inspect failed for {ref}\n{out}")
    data = json.loads(out)
    if not data:
        raise SystemExit(f"error: image inspect returned no data: {ref}")
    return data[0]


def image_release_from_ref(ref: str, name: str | None = None) -> dict[str, str]:
    ref = validate_ref(ref)
    docker_pull(ref)
    info = docker_inspect_image(ref)
    image_id = str(info.get("Id", ""))
    repo_digests = [str(item) for item in info.get("RepoDigests", [])]
    repo = split_ref_repository(ref)
    runtime_ref = ""
    for candidate in repo_digests:
        if candidate.startswith(repo + "@"):
            runtime_ref = candidate
            break
    if not runtime_ref and repo_digests:
        runtime_ref = repo_digests[0]
    if not runtime_ref:
        runtime_ref = ref
    digest = runtime_ref.split("@", 1)[1] if "@" in runtime_ref else ""
    release_name = validate_image_name(name or image_name_from_ref(ref))
    created_at = str(info.get("Created", "")) or now_iso()
    os_name = str(info.get("Os", ""))
    arch = str(info.get("Architecture", ""))
    labels = {str(key): str(value) for key, value in ((info.get("Config") or {}).get("Labels") or {}).items()}
    openclaw_source_repo = labels.get("org.opencontainers.image.openclaw.source", "")
    openclaw_source_ref = labels.get("org.opencontainers.image.openclaw.revision", "")
    agent_source_repo = (
        labels.get("org.opencontainers.image.hermes.agent.source", "")
        or labels.get("org.opencontainers.image.hermes.source", "")
    )
    agent_source_ref = (
        labels.get("org.opencontainers.image.hermes.agent.revision", "")
        or labels.get("org.opencontainers.image.hermes.revision", "")
    )
    workspace_source_repo = labels.get("org.opencontainers.image.hermes.workspace.source", "")
    workspace_source_ref = labels.get("org.opencontainers.image.hermes.workspace.revision", "")
    base_image = labels.get("org.opencontainers.image.base.name", "")
    workspace_image = labels.get("org.opencontainers.image.workspace.name", "")
    family = labels.get("org.opencontainers.image.family", "")
    if not family:
        family = "hermes" if release_name.startswith("hermes-") else "openclaw"
    if family == "hermes":
        source_repo = workspace_source_repo or agent_source_repo
        source_ref = workspace_source_ref or agent_source_ref
    else:
        source_repo = openclaw_source_repo
        source_ref = openclaw_source_ref
    aliases = ",".join(sorted({ref, runtime_ref, release_name}))
    return {
        "name": release_name,
        "family": family,
        "version": release_name.split("-", 1)[1] if "-" in release_name else release_name,
        "source_repo": source_repo,
        "source_ref": source_ref,
        "agent_source_repo": agent_source_repo,
        "agent_source_ref": agent_source_ref,
        "workspace_source_repo": workspace_source_repo,
        "workspace_source_ref": workspace_source_ref,
        "base_image": base_image,
        "workspace_image": workspace_image,
        "registry_ref": ref,
        "runtime_ref": runtime_ref,
        "digest": digest,
        "image_id": image_id,
        "status": "candidate",
        "role": "hermes" if family == "hermes" else "openclaw",
        "created_at": created_at,
        "updated_at": now_iso(),
        "aliases": aliases,
        "os": os_name,
        "arch": arch,
    }


def secret_env_findings(image: dict[str, str]) -> list[str]:
    ref = image.get("runtime_ref") or image.get("registry_ref") or image.get("name", "")
    info = docker_inspect_image(ref)
    findings: list[str] = []
    for env_item in (info.get("Config") or {}).get("Env") or []:
        key, _, value = str(env_item).partition("=")
        if SECRET_ENV_RE.search(key) and value and value not in {"", "changeme", "example", "placeholder"}:
            findings.append(key)
    return findings


def verify_container_baseline(image: dict[str, str]) -> tuple[bool, str]:
    ref = image.get("runtime_ref") or image.get("registry_ref") or image.get("name", "")
    family = image.get("family", "")
    script = r'''
set -eu
failed=0
need() {
  if command -v "$1" >/dev/null 2>&1; then
    echo "PASS cmd_$1"
  else
    echo "FAIL cmd_$1"
    failed=1
  fi
}
need_one() {
  label="$1"; shift
  for cmd in "$@"; do
    if command -v "$cmd" >/dev/null 2>&1; then
      echo "PASS cmd_$label=$cmd"
      return 0
    fi
  done
  echo "FAIL cmd_$label"
  failed=1
}
need python3
need node
need npm
need file
need rg
need jq
need yq
need_one 7z 7z 7zz
need_one libreoffice libreoffice soffice
need pandoc
need pdftotext
need pdfinfo
need tesseract
need ocrmypdf
need xlsx2csv
need in2csv
need ssconvert
need antiword
need catdoc
need hwp5txt
need hwp5proc
need openclaw-hwp-text
need openclaw-document-tools
need clawhub
if locale charmap 2>/dev/null | grep -qi UTF-8; then echo PASS locale_utf8; else echo FAIL locale_utf8; failed=1; fi
if locale -a 2>/dev/null | grep -Eiq '^ko_KR(\.utf8|\.UTF-8)?$'; then echo PASS ko_locale; else echo FAIL ko_locale; failed=1; fi
if command -v fc-list >/dev/null 2>&1 && [ "$(fc-list :lang=ko 2>/dev/null | wc -l)" -gt 0 ]; then echo PASS korean_fonts; else echo FAIL korean_fonts; failed=1; fi
python3 - <<'PY'
import docx, openpyxl, pandas
PY
echo PASS python_document_modules
if [ "${OPENCLAW_EXPECT_HERMES_WORKSPACE:-0}" = "1" ]; then
  if [ -f /opt/hermes-workspace/server-entry.js ]; then echo PASS hermes_workspace_app; else echo FAIL hermes_workspace_app; failed=1; fi
  if [ -x /usr/local/bin/openclaw-hermes-entrypoint ]; then echo PASS hermes_integrated_entrypoint; else echo FAIL hermes_integrated_entrypoint; failed=1; fi
fi
exit "$failed"
'''
    args = ["docker", "run", "--rm", "--entrypoint", "sh"]
    if family == "hermes":
        args.extend(["-e", "OPENCLAW_EXPECT_HERMES_WORKSPACE=1"])
    args.extend([ref, "-lc", script])
    rc, out = run(args, timeout=600)
    return rc == 0, out


def parse_slots(path: Path) -> tuple[dict[str, str], list[dict[str, str]]]:
    meta: dict[str, str] = {}
    slots: list[dict[str, str]] = []
    if not path.exists():
        return meta, slots
    section = ""
    current: dict[str, str] | None = None
    nested = ""
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.rstrip().lstrip("\ufeff")
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        indent = len(line) - len(line.lstrip(" "))
        if stripped == "meta:":
            section = "meta"
            current = None
            nested = ""
            continue
        if stripped == "slots:":
            section = "slots"
            current = None
            nested = ""
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
            nested = ""
            continue
        if current is None:
            continue
        if indent == 4 and stripped.endswith(":"):
            nested = stripped[:-1]
            continue
        if indent == 4 and ":" in stripped:
            key, value = stripped.split(":", 1)
            current[key] = unquote(value)
            nested = ""
            continue
        if indent == 6 and nested and ":" in stripped:
            key, value = stripped.split(":", 1)
            current[f"{nested}.{key}"] = unquote(value)
    if current:
        slots.append(current)
    return meta, slots


def slot_number_from_name(name: str) -> int | None:
    match = re.match(r"^oc([0-9]+)$", name or "")
    return int(match.group(1)) if match else None


def slot_lane(slot: dict[str, str]) -> str:
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
    number = slot_number_from_name(name)
    if number is not None and number >= 15:
        return "hermes"
    return "openclaw"


def slot_record(slots: list[dict[str, str]], name: str) -> dict[str, str]:
    return next((slot for slot in slots if slot.get("slot") == name), {"slot": name})


def slot_is_customer_rollout_target(slot: dict[str, str]) -> bool:
    name = slot.get("slot", "")
    lane = slot_lane(slot)
    return bool(SLOT_RE.match(name)) and lane != "hold" and not lane.startswith("dev-")


def slot_numbers_for_channel(channel: str, slots: list[dict[str, str]]) -> list[str]:
    explicit = [
        slot["slot"]
        for slot in slots
        if slot_lane(slot) == channel and slot_is_customer_rollout_target(slot)
    ]
    if explicit:
        return explicit
    names = {slot.get("slot", "") for slot in slots}
    if channel == "staging":
        slot = slot_record(slots, "oc1")
        return ["oc1"] if "oc1" in names and slot_is_customer_rollout_target(slot) else []
    if channel == "oc15-20-test":
        return [
            f"oc{i}"
            for i in range(15, 21)
            if f"oc{i}" in names and slot_is_customer_rollout_target(slot_record(slots, f"oc{i}"))
        ]
    return []


def slot_numbers_for_range(start: str, end: str, slots: list[dict[str, str]]) -> list[str]:
    start_number = validate_slot_number(start)
    end_number = validate_slot_number(end)
    if start_number > end_number:
        raise SystemExit("error: START must be less than or equal to END")
    if end_number - start_number + 1 > 100:
        raise SystemExit("error: rollout range is too large")
    names = {slot.get("slot", "") for slot in slots}
    return [
        f"oc{i}"
        for i in range(start_number, end_number + 1)
        if f"oc{i}" in names and slot_is_customer_rollout_target(slot_record(slots, f"oc{i}"))
    ]


def update_env_image(target_user: str, image_ref: str) -> None:
    env_path = Path(f"/home/{target_user}/openclaw/.env")
    if not env_path.exists():
        raise SystemExit(f"error: env file missing: {env_path}")
    lines = env_path.read_text(encoding="utf-8", errors="replace").splitlines(keepends=True)
    out: list[str] = []
    changed = False
    for line in lines:
        if line.startswith("OPENCLAW_IMAGE="):
            out.append(f"OPENCLAW_IMAGE='{image_ref}'\n")
            changed = True
        else:
            out.append(line)
    if not changed:
        out.append(f"OPENCLAW_IMAGE='{image_ref}'\n")
    atomic_write(env_path, "".join(out), default_mode=0o600)


def current_env_image_ref(target_user: str) -> str:
    env_path = Path(f"/home/{target_user}/openclaw/.env")
    if not env_path.exists():
        return ""
    for line in env_path.read_text(encoding="utf-8", errors="replace").splitlines():
        if line.startswith("OPENCLAW_IMAGE="):
            return unquote(line.split("=", 1)[1])
    return ""


def sanitize_history_name(value: str) -> str:
    value = re.sub(r"[^A-Za-z0-9._-]+", "-", value).strip("-")
    return value[:127] or "previous-image"


def write_image_history(
    history_dir: Path,
    target_user: str,
    previous_ref: str,
    previous_family: str,
    image: dict[str, str],
    image_ref: str,
    channel: str,
) -> None:
    path = history_dir / f"{target_user}.env"
    text = (
        f"PREVIOUS_IMAGE_REF={q(previous_ref)}\n"
        f"PREVIOUS_RUNTIME_FAMILY={q(previous_family)}\n"
        f"CURRENT_IMAGE_NAME={q(image.get('name', ''))}\n"
        f"CURRENT_IMAGE_REF={q(image_ref)}\n"
        f"CURRENT_RUNTIME_FAMILY={q(image.get('family', '') or 'openclaw')}\n"
        f"CHANNEL={q(channel)}\n"
        f"UPDATED_AT={q(now_iso())}\n"
    )
    atomic_write(path, text, default_mode=0o640)


def read_image_history(history_dir: Path, target_user: str) -> dict[str, str]:
    path = history_dir / f"{target_user}.env"
    if not path.exists():
        return {}
    result: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        result[key] = unquote(value)
    return result


def refresh_gateway(control: Path, target_user: str) -> tuple[int, str]:
    return run([str(control), "gateway-refresh", target_user], timeout=300)


def slot_host(slots_path: Path, target_user: str) -> str:
    _, slots = parse_slots(slots_path)
    slot = next((item for item in slots if item.get("slot") == target_user), None)
    return (slot or {}).get("subdomain") or f"{target_user}.ji-tech.co.kr"


def current_runtime_family(target_user: str) -> str:
    env_path = Path(f"/home/{target_user}/openclaw/.env")
    if not env_path.exists():
        return ""
    for line in env_path.read_text(encoding="utf-8", errors="replace").splitlines():
        if line.startswith("OPENCLAW_RUNTIME_FAMILY="):
            return unquote(line.split("=", 1)[1])
    return "openclaw"


def install_openclaw_slot(control: Path, slots_path: Path, target_user: str, image_ref: str) -> tuple[int, str]:
    script_dir = control.parent
    return run(
        [
            str(script_dir / "internal" / "install-customer-slot-from-image.bash"),
            "--user",
            target_user,
            "--host",
            slot_host(slots_path, target_user),
            "--image",
            image_ref,
            "--force",
            "--check",
        ],
        timeout=1200,
    )


def install_hermes_slot(control: Path, slots_path: Path, target_user: str, image_ref: str) -> tuple[int, str]:
    script_dir = control.parent
    return run(
        [
            str(script_dir / "internal" / "install-hermes-slot-from-image.bash"),
            "--user",
            target_user,
            "--host",
            slot_host(slots_path, target_user),
            "--image",
            image_ref,
            "--force",
        ],
        timeout=900,
    )


def append_action(path: Path, action: str, payload: dict[str, Any], exit_code: int, output: str) -> None:
    event = {
        "timestamp": now_iso(),
        "actor": os.environ.get("SUDO_USER") or os.environ.get("USER") or "unknown",
        "action": action,
        "params": payload,
        "exit_code": exit_code,
        "summary": "\n".join(output.splitlines()[:10])[:2048],
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(event, ensure_ascii=False) + "\n")
    try:
        os.chmod(path, 0o600)
    except PermissionError:
        pass


def cmd_list(args: argparse.Namespace) -> int:
    state = parse_images(args.images)
    print(f"images_file={args.images}")
    for channel, image_name in sorted((state.get("channels") or {}).items()):
        print(f"channel={channel} image={image_name}")
    for image in sorted(state.get("images", []), key=lambda item: item.get("name", "")):
        print(
            f"image={image.get('name')} family={image.get('family')} status={image.get('status')} "
            f"source_ref={image.get('source_ref', '')} base_image={image.get('base_image', '')} "
            f"agent_source_ref={image.get('agent_source_ref', '')} "
            f"workspace_source_ref={image.get('workspace_source_ref', '')} "
            f"ref={image.get('registry_ref')} runtime_ref={image.get('runtime_ref')} image_id={image.get('image_id')}"
        )
    return 0


def cmd_add(args: argparse.Namespace) -> int:
    state = parse_images(args.images)
    image = image_release_from_ref(args.ref, args.name)
    upsert_image(state, image)
    write_images(args.images, state)
    print(f"image_release_added={image['name']}")
    print(f"registry_ref={image['registry_ref']}")
    print(f"runtime_ref={image['runtime_ref']}")
    print(f"digest={image.get('digest', '')}")
    print(f"image_id={image['image_id']}")
    if image.get("source_repo"):
        print(f"source_repo={image['source_repo']}")
    if image.get("source_ref"):
        print(f"source_ref={image['source_ref']}")
    if image.get("agent_source_repo"):
        print(f"agent_source_repo={image['agent_source_repo']}")
    if image.get("agent_source_ref"):
        print(f"agent_source_ref={image['agent_source_ref']}")
    if image.get("workspace_source_repo"):
        print(f"workspace_source_repo={image['workspace_source_repo']}")
    if image.get("workspace_source_ref"):
        print(f"workspace_source_ref={image['workspace_source_ref']}")
    if image.get("base_image"):
        print(f"base_image={image['base_image']}")
    if image.get("workspace_image"):
        print(f"workspace_image={image['workspace_image']}")
    print("status=candidate")
    return 0


def cmd_verify(args: argparse.Namespace) -> int:
    state = parse_images(args.images)
    image = find_image(state, args.image)
    if not image:
        raise SystemExit(f"error: image not found in release cache: {args.image}")
    docker_pull(image.get("registry_ref") or image.get("runtime_ref") or image["name"])
    latest = image_release_from_ref(image.get("registry_ref") or image.get("runtime_ref") or image["name"], image["name"])
    image.update(
        {
            key: value
            for key, value in latest.items()
            if key
            in {
                "family",
                "runtime_ref",
                "digest",
                "image_id",
                "updated_at",
                "aliases",
                "source_repo",
                "source_ref",
                "agent_source_repo",
                "agent_source_ref",
                "workspace_source_repo",
                "workspace_source_ref",
                "base_image",
                "workspace_image",
            }
        }
    )
    findings = secret_env_findings(image)
    if findings:
        image["status"] = "failed"
        image["last_error"] = "secret_env=" + ",".join(findings)
        write_images(args.images, state)
        print(f"image_release_verified={image['name']}")
        print(f"status=failed")
        print(f"secret_env_findings={','.join(findings)}")
        return 1
    ok, output = verify_container_baseline(image)
    print(output, end="")
    image["verified_at"] = now_iso()
    if ok:
        if image.get("status") in {"candidate", "failed", ""}:
            image["status"] = "staging"
        image.pop("last_error", None)
        result = 0
    else:
        image["status"] = "failed"
        image["last_error"] = "container_baseline_failed"
        result = 1
    upsert_image(state, image)
    write_images(args.images, state)
    print(f"image_release_verified={image['name']}")
    print(f"status={image['status']}")
    return result


def cmd_promote(args: argparse.Namespace) -> int:
    state = parse_images(args.images)
    image = find_image(state, args.image)
    if not image:
        raise SystemExit(f"error: image not found: {args.image}")
    status = image.get("status", "")
    if status not in ROLLABLE_STATUSES:
        raise SystemExit(f"error: image status does not allow promotion: {status}")
    channel = validate_channel(args.channel)
    state.setdefault("channels", {})[channel] = image["name"]
    if channel not in {"staging", "oc15-20-test"}:
        image["status"] = "approved"
    image["updated_at"] = now_iso()
    upsert_image(state, image)
    write_images(args.images, state)
    print(f"image_release_promoted={image['name']}")
    print(f"channel={channel}")
    print(f"status={image['status']}")
    return 0


def apply_image_to_slot(args: argparse.Namespace, slot: str, image: dict[str, str], channel: str) -> tuple[int, str]:
    target_user = validate_slot(slot)
    image_ref = image.get("runtime_ref") or image.get("registry_ref") or image["name"]
    docker_pull(image_ref)
    family = image.get("family", "")
    previous_ref = current_env_image_ref(target_user)
    previous_family = current_runtime_family(target_user)
    if family == "hermes":
        rc, out = install_hermes_slot(args.control, args.slots, target_user, image_ref)
    elif previous_family == "hermes":
        rc, out = install_openclaw_slot(args.control, args.slots, target_user, image_ref)
    else:
        update_env_image(target_user, image_ref)
        rc, out = refresh_gateway(args.control, target_user)
    if rc == 0:
        write_image_history(args.image_history_dir, target_user, previous_ref, previous_family, image, image_ref, channel)
    output = (
        f"target_user={target_user}\n"
        f"image_name={image['name']}\n"
        f"image_family={family or 'openclaw'}\n"
        f"image_channel={channel}\n"
        f"source_repo={image.get('source_repo', '')}\n"
        f"source_ref={image.get('source_ref', '')}\n"
        f"agent_source_repo={image.get('agent_source_repo', '')}\n"
        f"agent_source_ref={image.get('agent_source_ref', '')}\n"
        f"workspace_source_repo={image.get('workspace_source_repo', '')}\n"
        f"workspace_source_ref={image.get('workspace_source_ref', '')}\n"
        f"base_image={image.get('base_image', '')}\n"
        f"runtime_ref={image_ref}\n"
        f"{out}"
    )
    append_action(args.actions_log, "image-apply", {"slot": target_user, "image": image["name"], "channel": channel}, rc, output)
    return rc, output


def cmd_rollout_slot(args: argparse.Namespace) -> int:
    state = parse_images(args.images)
    image = find_image(state, args.image)
    if not image:
        raise SystemExit(f"error: image not found: {args.image}")
    if image.get("status") not in ROLLABLE_STATUSES:
        raise SystemExit(f"error: image status does not allow rollout: {image.get('status')}")
    _, slots = parse_slots(args.slots)
    slot = slot_record(slots, args.user)
    if not slot_is_customer_rollout_target(slot):
        raise SystemExit(f"error: image rollout is allowed only for customer image slots: {args.user}")
    channel = args.channel or "manual"
    rc, output = apply_image_to_slot(args, args.user, image, channel)
    print(output, end="" if output.endswith("\n") else "\n")
    return rc


def cmd_rollout(args: argparse.Namespace) -> int:
    state = parse_images(args.images)
    channel = validate_channel(args.channel)
    image_name = (state.get("channels") or {}).get(channel)
    if not image_name:
        raise SystemExit(f"error: no image promoted for channel: {channel}")
    image = find_image(state, image_name)
    if not image:
        raise SystemExit(f"error: promoted image is missing: {image_name}")
    if image.get("status") not in ROLLABLE_STATUSES:
        raise SystemExit(f"error: image status does not allow rollout: {image.get('status')}")
    _, slots = parse_slots(args.slots)
    targets = slot_numbers_for_channel(channel, slots)
    if not targets:
        raise SystemExit(f"error: no slots selected for channel: {channel}")
    failed = 0
    for slot in targets:
        print(f"== {slot} ==")
        rc, output = apply_image_to_slot(args, slot, image, channel)
        print(output, end="" if output.endswith("\n") else "\n")
        if rc != 0:
            failed = 1
    return failed


def cmd_rollout_range(args: argparse.Namespace) -> int:
    state = parse_images(args.images)
    image = find_image(state, args.image)
    if not image:
        raise SystemExit(f"error: image not found: {args.image}")
    if image.get("status") not in ROLLABLE_STATUSES:
        raise SystemExit(f"error: image status does not allow rollout: {image.get('status')}")
    _, slots = parse_slots(args.slots)
    targets = slot_numbers_for_range(args.start, args.end, slots)
    if not targets:
        raise SystemExit(f"error: no slots selected for range: {args.start}-{args.end}")
    channel = validate_channel(args.channel or f"range-{args.start}-{args.end}")
    print(f"target_range=oc{args.start}..oc{args.end}")
    print(f"target_count={len(targets)}")
    print(f"image_name={image['name']}")
    print(f"image_channel={channel}")
    failed = 0
    for slot in targets:
        print(f"== {slot} ==")
        rc, output = apply_image_to_slot(args, slot, image, channel)
        print(output, end="" if output.endswith("\n") else "\n")
        if rc != 0:
            failed = 1
    return failed


def cmd_rollback(args: argparse.Namespace) -> int:
    _, slots = parse_slots(args.slots)
    slot = next((item for item in slots if item.get("slot") == args.user), None)
    if not slot:
        raise SystemExit(f"error: slot not found: {args.user}")
    if not slot_is_customer_rollout_target(slot):
        raise SystemExit(f"error: image rollback is allowed only for customer image slots: {args.user}")
    history = read_image_history(args.image_history_dir, args.user)
    previous = history.get("PREVIOUS_IMAGE_REF") or slot.get("previous_image_name") or slot.get("previous_image_ref")
    if not previous:
        raise SystemExit(f"error: no previous image recorded for {args.user}")
    state = parse_images(args.images)
    image = find_image(state, previous)
    if not image:
        image = {
            "name": sanitize_history_name(previous.rsplit("/", 1)[-1]),
            "runtime_ref": previous,
            "registry_ref": previous,
            "family": history.get("PREVIOUS_RUNTIME_FAMILY", ""),
        }
    rc, output = apply_image_to_slot(args, args.user, image, "rollback")
    print(output, end="" if output.endswith("\n") else "\n")
    return rc


def cmd_status_all(args: argparse.Namespace) -> int:
    start = int(args.start)
    end = int(args.end)
    failed = 0
    for number in range(start, end + 1):
        slot = f"oc{number}"
        print(f"== {slot} ==")
        rc, out = run([str(args.control), "image-status", slot], timeout=60)
        print(out, end="" if out.endswith("\n") else "\n")
        if rc != 0:
            failed = 1
    return failed


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="OpenClaw public registry image release control")
    parser.add_argument("--slots", type=Path, default=DEFAULT_SLOTS)
    parser.add_argument("--images", type=Path, default=DEFAULT_IMAGES)
    parser.add_argument("--actions-log", type=Path, default=DEFAULT_ACTIONS_LOG)
    parser.add_argument("--image-history-dir", type=Path, default=DEFAULT_IMAGE_HISTORY)
    parser.add_argument("--control", type=Path, default=DEFAULT_CONTROL)
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("list").set_defaults(func=cmd_list)

    add = sub.add_parser("add")
    add.add_argument("ref")
    add.add_argument("--name")
    add.set_defaults(func=cmd_add)

    verify = sub.add_parser("verify")
    verify.add_argument("image")
    verify.set_defaults(func=cmd_verify)

    promote = sub.add_parser("promote")
    promote.add_argument("image")
    promote.add_argument("channel")
    promote.set_defaults(func=cmd_promote)

    rollout = sub.add_parser("rollout")
    rollout.add_argument("channel")
    rollout.set_defaults(func=cmd_rollout)

    rollout_range = sub.add_parser("rollout-range")
    rollout_range.add_argument("start")
    rollout_range.add_argument("end")
    rollout_range.add_argument("image")
    rollout_range.add_argument("--channel", default="")
    rollout_range.set_defaults(func=cmd_rollout_range)

    rollout_slot = sub.add_parser("rollout-slot")
    rollout_slot.add_argument("user")
    rollout_slot.add_argument("image")
    rollout_slot.add_argument("--channel", default="manual")
    rollout_slot.set_defaults(func=cmd_rollout_slot)

    rollback = sub.add_parser("rollback")
    rollback.add_argument("user")
    rollback.set_defaults(func=cmd_rollback)

    status_all = sub.add_parser("status-all")
    status_all.add_argument("start")
    status_all.add_argument("end")
    status_all.set_defaults(func=cmd_status_all)

    return parser


def main(argv: list[str]) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    started = time.monotonic()
    try:
        rc = int(args.func(args))
        return rc
    finally:
        elapsed = int((time.monotonic() - started) * 1000)
        print(f"duration_ms={elapsed}")


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
