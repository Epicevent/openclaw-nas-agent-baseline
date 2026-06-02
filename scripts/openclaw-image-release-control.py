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
    aliases = ",".join(sorted({ref, runtime_ref, release_name}))
    return {
        "name": release_name,
        "family": release_name.split("-", 1)[0],
        "version": release_name.split("-", 1)[1] if "-" in release_name else release_name,
        "registry_ref": ref,
        "runtime_ref": runtime_ref,
        "digest": digest,
        "image_id": image_id,
        "status": "candidate",
        "role": "custom" if "dashboard" in release_name else "baseline",
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
need clawhub
if locale charmap 2>/dev/null | grep -qi UTF-8; then echo PASS locale_utf8; else echo FAIL locale_utf8; failed=1; fi
if locale -a 2>/dev/null | grep -Eiq '^ko_KR(\.utf8|\.UTF-8)?$'; then echo PASS ko_locale; else echo FAIL ko_locale; failed=1; fi
if command -v fc-list >/dev/null 2>&1 && [ "$(fc-list :lang=ko 2>/dev/null | wc -l)" -gt 0 ]; then echo PASS korean_fonts; else echo FAIL korean_fonts; failed=1; fi
python3 - <<'PY'
import docx, openpyxl, pandas
PY
echo PASS python_document_modules
exit "$failed"
'''
    rc, out = run(["docker", "run", "--rm", "--entrypoint", "sh", ref, "-lc", script], timeout=600)
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


def slot_numbers_for_channel(channel: str, slots: list[dict[str, str]]) -> list[str]:
    explicit = [slot["slot"] for slot in slots if slot.get("image_channel") == channel]
    if explicit:
        return explicit
    names = {slot.get("slot", "") for slot in slots}
    if channel == "staging":
        return ["oc1"] if "oc1" in names else []
    if channel == "oc15-20-test":
        return [f"oc{i}" for i in range(15, 21) if f"oc{i}" in names]
    return []


def update_slot_assignment(slots_path: Path, slot_name: str, image: dict[str, str], channel: str) -> None:
    if not slots_path.exists():
        return
    text = slots_path.read_text(encoding="utf-8")
    lines = text.splitlines(keepends=True)
    _, slots = parse_slots(slots_path)
    current = next((item for item in slots if item.get("slot") == slot_name), {})
    previous_name = current.get("image_name") or current.get("image_tag", "")
    previous_ref = current.get("image_tag", "")

    out: list[str] = []
    in_target = False
    inserted = False
    seen = {"image_channel": False, "image_name": False, "image_tag": False, "previous_image_name": False, "previous_image_ref": False, "image_updated_at": False}
    for line in lines:
        stripped = line.strip()
        if line.startswith("  - slot:"):
            if in_target and not inserted:
                out.extend(slot_image_lines(image, channel, previous_name, previous_ref))
                inserted = True
            in_target = unquote(line.split(":", 1)[1]) == slot_name
            inserted = False
            seen = {key: False for key in seen}
            out.append(line)
            continue
        if in_target and line.startswith("  - slot:"):
            in_target = False
        if in_target and line.startswith("    ") and not line.startswith("      ") and ":" in stripped:
            key = stripped.split(":", 1)[0]
            if key in seen:
                seen[key] = True
                if key == "image_channel":
                    out.append(f"    image_channel: {q(channel)}\n")
                elif key == "image_name":
                    out.append(f"    image_name: {q(image['name'])}\n")
                elif key == "image_tag":
                    out.append(f"    image_tag: {q(image.get('runtime_ref') or image.get('registry_ref') or image['name'])}\n")
                elif key == "previous_image_name":
                    out.append(f"    previous_image_name: {q(previous_name)}\n")
                elif key == "previous_image_ref":
                    out.append(f"    previous_image_ref: {q(previous_ref)}\n")
                elif key == "image_updated_at":
                    out.append(f"    image_updated_at: {q(now_iso())}\n")
                continue
        if in_target and not inserted and line.startswith("    last_gate:"):
            out.extend(slot_image_lines(image, channel, previous_name, previous_ref, seen))
            inserted = True
        out.append(line)
    if in_target and not inserted:
        out.extend(slot_image_lines(image, channel, previous_name, previous_ref, seen))
    atomic_write(slots_path, "".join(out), default_mode=0o640)


def slot_image_lines(
    image: dict[str, str],
    channel: str,
    previous_name: str,
    previous_ref: str,
    seen: dict[str, bool] | None = None,
) -> list[str]:
    seen = seen or {}
    rows = {
        "image_channel": channel,
        "image_name": image["name"],
        "image_tag": image.get("runtime_ref") or image.get("registry_ref") or image["name"],
        "previous_image_name": previous_name,
        "previous_image_ref": previous_ref,
        "image_updated_at": now_iso(),
    }
    return [f"    {key}: {q(value)}\n" for key, value in rows.items() if not seen.get(key)]


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


def refresh_gateway(control: Path, target_user: str) -> tuple[int, str]:
    return run([str(control), "gateway-refresh", target_user], timeout=300)


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
        print(f"image={image.get('name')} status={image.get('status')} ref={image.get('registry_ref')} runtime_ref={image.get('runtime_ref')} image_id={image.get('image_id')}")
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
    print("status=candidate")
    return 0


def cmd_verify(args: argparse.Namespace) -> int:
    state = parse_images(args.images)
    image = find_image(state, args.image)
    if not image:
        raise SystemExit(f"error: image not found in release cache: {args.image}")
    docker_pull(image.get("registry_ref") or image.get("runtime_ref") or image["name"])
    latest = image_release_from_ref(image.get("registry_ref") or image.get("runtime_ref") or image["name"], image["name"])
    image.update({key: value for key, value in latest.items() if key in {"runtime_ref", "digest", "image_id", "updated_at", "aliases"}})
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
    update_env_image(target_user, image_ref)
    update_slot_assignment(args.slots, target_user, image, channel)
    rc, out = refresh_gateway(args.control, target_user)
    output = (
        f"target_user={target_user}\n"
        f"image_name={image['name']}\n"
        f"image_channel={channel}\n"
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


def cmd_rollback(args: argparse.Namespace) -> int:
    _, slots = parse_slots(args.slots)
    slot = next((item for item in slots if item.get("slot") == args.user), None)
    if not slot:
        raise SystemExit(f"error: slot not found: {args.user}")
    previous = slot.get("previous_image_name") or slot.get("previous_image_ref")
    if not previous:
        raise SystemExit(f"error: no previous image recorded for {args.user}")
    state = parse_images(args.images)
    image = find_image(state, previous)
    if not image:
        raise SystemExit(f"error: previous image is not in image cache: {previous}")
    rc, output = apply_image_to_slot(args, args.user, image, slot.get("image_channel") or "rollback")
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
