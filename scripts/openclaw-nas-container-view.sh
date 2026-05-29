#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  openclaw-nas-container-view.sh tree --user USER [--depth N] [--limit N]
  openclaw-nas-container-view.sh search-smoke --user USER --query QUERY [--limit N]

Shows what the OpenClaw gateway container can see under /home/node/nas_docs.
It never reads NAS credentials, OpenClaw tokens, or provider/API keys.
USAGE
}

mode="${1:-}"
shift || true

target_user=""
query=""
max_depth=3
entry_limit=120

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user)
      target_user="${2:?missing --user value}"
      shift 2
      ;;
    --query)
      query="${2:?missing --query value}"
      shift 2
      ;;
    --depth)
      max_depth="${2:?missing --depth value}"
      shift 2
      ;;
    --limit)
      entry_limit="${2:?missing --limit value}"
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

if [[ "$mode" != "tree" && "$mode" != "search-smoke" ]]; then
  usage >&2
  exit 2
fi

if [[ ! "$target_user" =~ ^oc[1-9][0-9]*$ ]]; then
  echo "error: invalid customer user: $target_user" >&2
  exit 2
fi

if [[ ! "$max_depth" =~ ^[0-9]+$ || "$max_depth" -lt 1 || "$max_depth" -gt 5 ]]; then
  echo "error: invalid depth: $max_depth" >&2
  exit 2
fi

if [[ ! "$entry_limit" =~ ^[0-9]+$ || "$entry_limit" -lt 1 || "$entry_limit" -gt 500 ]]; then
  echo "error: invalid limit: $entry_limit" >&2
  exit 2
fi

if [[ "$mode" == "search-smoke" ]]; then
  if [[ -z "$query" || "${#query}" -gt 160 || "$query" == *$'\n'* || "$query" == *$'\r'* ]]; then
    echo "error: invalid query" >&2
    exit 2
  fi
fi

container="openclaw-${target_user}-openclaw-gateway-1"
root_path="/home/node/nas_docs"
status_key="tree_status"
if [[ "$mode" == "search-smoke" ]]; then
  status_key="search_status"
fi

echo "target_user=$target_user"
echo "container=$container"
echo "container_root=$root_path"

if ! docker inspect "$container" >/dev/null 2>&1; then
  echo "container_status=missing"
  echo "$status_key=container_missing"
  exit 1
fi

container_status="$(docker inspect "$container" --format '{{.State.Status}}' 2>/dev/null || true)"
echo "container_status=${container_status:-unknown}"
if [[ "$container_status" != "running" ]]; then
  echo "$status_key=container_not_running"
  exit 1
fi

if [[ "$mode" == "tree" ]]; then
  docker exec -i \
    -e OPENCLAW_NAS_ROOT="$root_path" \
    -e OPENCLAW_NAS_DEPTH="$max_depth" \
    -e OPENCLAW_NAS_LIMIT="$entry_limit" \
    "$container" python3 - <<'PY'
from __future__ import annotations

import json
import os
import re
import stat
from pathlib import Path, PurePosixPath

root = Path(os.environ["OPENCLAW_NAS_ROOT"])
max_depth = int(os.environ["OPENCLAW_NAS_DEPTH"])
limit = int(os.environ["OPENCLAW_NAS_LIMIT"])

secret_re = re.compile(
    r"(?i)(api[_-]?key|token|password|passwd|credential|secret|sk-[A-Za-z0-9]{8,}|AIza[0-9A-Za-z_-]{12,})"
)

reported = 0
omitted = 0
mounts: dict[str, str] = {}


def decode_mount_path(value: str) -> str:
    return (
        value.replace(r"\040", " ")
        .replace(r"\011", "\t")
        .replace(r"\012", "\n")
        .replace(r"\134", "\\")
    )


def load_mounts() -> dict[str, str]:
    found: dict[str, str] = {}
    try:
        lines = Path("/proc/self/mountinfo").read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return found
    for line in lines:
        if " - " not in line:
            continue
        left, right = line.split(" - ", 1)
        fields = left.split()
        right_fields = right.split()
        if len(fields) < 5 or not right_fields:
            continue
        found[decode_mount_path(fields[4])] = right_fields[0]
    return found


mounts = load_mounts()


def clean_name(name: str) -> str:
    if secret_re.search(name):
        return "[REDACTED_NAME]"
    return name[:160]


def clean_path(path: Path) -> str:
    try:
        rel = path.relative_to(root)
    except ValueError:
        return str(path)
    parts = [clean_name(part) for part in rel.parts]
    if not parts:
        return str(PurePosixPath(str(root)))
    return str(PurePosixPath(str(root), *parts))


def emit(kind: str, depth: int, path: Path, **extra: object) -> None:
    global reported, omitted
    if reported >= limit:
        omitted += 1
        return
    row = {"kind": kind, "depth": depth, "path": clean_path(path)}
    row.update(extra)
    print("TREE " + json.dumps(row, ensure_ascii=False, sort_keys=True))
    reported += 1


def mount_meta(path: Path) -> dict[str, str]:
    fstype = mounts.get(str(path))
    if fstype:
        return {"mount_state": "mounted", "fstype": fstype}
    return {"mount_state": "visible_not_mounted"}


def classify(entry: Path) -> str:
    try:
        st = entry.lstat()
    except OSError:
        return "unreadable"
    if stat.S_ISLNK(st.st_mode):
        return "symlink"
    if stat.S_ISDIR(st.st_mode):
        return "dir"
    if stat.S_ISREG(st.st_mode):
        return "file"
    return "other"


def list_entries(path: Path) -> tuple[list[Path], str]:
    try:
        return sorted(path.iterdir(), key=lambda item: (classify(item) != "dir", item.name.lower())), "readable"
    except PermissionError:
        return [], "permission_denied"
    except FileNotFoundError:
        return [], "missing"
    except OSError:
        return [], "unreadable"


def walk(path: Path, depth: int) -> None:
    entries, state = list_entries(path)
    dirs = [entry for entry in entries if classify(entry) == "dir"]
    files = [entry for entry in entries if classify(entry) == "file"]
    dir_state = "empty" if state == "readable" and not entries else state
    emit(
        "dir",
        depth,
        path,
        state=dir_state,
        dir_count=len(dirs),
        file_count=len(files),
        entry_count=len(entries),
        **mount_meta(path),
    )
    if state != "readable" or depth >= max_depth:
        return
    for entry in entries:
        kind = classify(entry)
        if kind == "dir":
            walk(entry, depth + 1)
        elif kind == "file":
            try:
                size = entry.lstat().st_size
            except OSError:
                size = None
            emit("file", depth + 1, entry, state="readable", size=size)
        else:
            emit(kind, depth + 1, entry, state=kind)


if not root.exists():
    print("root_state=missing")
    print("tree_status=missing")
    raise SystemExit(1)
if not root.is_dir():
    print("root_state=not_directory")
    print("tree_status=not_directory")
    raise SystemExit(1)

print("root_state=visible")
walk(root, 0)
print(f"tree_entries_reported={reported}")
print(f"tree_entries_omitted={omitted}")
print("tree_status=ok" if omitted == 0 else "tree_status=truncated")
PY
  exit $?
fi

docker exec -i \
  -e OPENCLAW_NAS_ROOT="$root_path" \
  -e OPENCLAW_NAS_QUERY="$query" \
  -e OPENCLAW_NAS_LIMIT="$entry_limit" \
  "$container" python3 - <<'PY'
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
from pathlib import Path, PurePosixPath

root = Path(os.environ["OPENCLAW_NAS_ROOT"])
query = os.environ["OPENCLAW_NAS_QUERY"]
limit = int(os.environ["OPENCLAW_NAS_LIMIT"])

secret_re = re.compile(
    r"(?i)(api[_-]?key|token|password|passwd|credential|secret|sk-[A-Za-z0-9]{8,}|AIza[0-9A-Za-z_-]{12,})"
)


def clean_name(name: str) -> str:
    if secret_re.search(name):
        return "[REDACTED_NAME]"
    return name[:160]


def clean_path(path: str) -> str:
    p = Path(path)
    try:
        rel = p.relative_to(root)
    except ValueError:
        return path
    parts = [clean_name(part) for part in rel.parts]
    if not parts:
        return str(PurePosixPath(str(root)))
    return str(PurePosixPath(str(root), *parts))


tools = {name: ("present" if shutil.which(name) else "missing") for name in ("find", "rg", "pdftotext", "pandoc")}
for name, state in tools.items():
    print(f"tool_{name}={state}")

if not root.exists():
    print("root_state=missing")
    print("search_status=root_missing")
    raise SystemExit(1)
if not root.is_dir():
    print("root_state=not_directory")
    print("search_status=root_not_directory")
    raise SystemExit(1)
print("root_state=visible")
print(f"query_chars={len(query)}")

if tools["find"] != "present" or tools["rg"] != "present":
    print("search_status=tool_missing")
    raise SystemExit(1)

try:
    result = subprocess.run(
        [
            "rg",
            "-l",
            "--fixed-strings",
            "--hidden",
            "--no-messages",
            "--max-filesize",
            "10M",
            "--",
            query,
            str(root),
        ],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=20,
        check=False,
    )
except subprocess.TimeoutExpired:
    print("search_status=timeout")
    raise SystemExit(1)

matches = [line for line in result.stdout.splitlines() if line.strip()]
limited = matches[:limit]
print(f"rg_exit_code={result.returncode}")
print(f"match_count_limited={len(limited)}")
print(f"match_count_truncated={'yes' if len(matches) > len(limited) else 'no'}")
for path in limited:
    print("MATCH " + json.dumps({"path": clean_path(path)}, ensure_ascii=False, sort_keys=True))

if result.returncode == 0:
    print("search_status=match")
elif result.returncode == 1:
    print("search_status=no_match")
else:
    print("search_status=rg_error")
    raise SystemExit(1)
PY
