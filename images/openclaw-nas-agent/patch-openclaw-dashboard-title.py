#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
from pathlib import Path


TEXT_SUFFIXES = {
    ".html",
    ".htm",
    ".js",
    ".mjs",
    ".cjs",
    ".css",
    ".json",
    ".svg",
    ".txt",
}

SKIP_DIRS = {
    ".git",
    ".cache",
    "__pycache__",
    "node_modules",
    "vendor",
}


def is_candidate(path: Path, max_bytes: int) -> bool:
    try:
        if not path.is_file() or path.is_symlink():
            return False
        if path.suffix.lower() not in TEXT_SUFFIXES:
            return False
        if path.stat().st_size > max_bytes:
            return False
    except OSError:
        return False
    return True


def iter_files(root: Path, max_bytes: int):
    if not root.exists():
        return
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [item for item in dirnames if item not in SKIP_DIRS]
        current = Path(dirpath)
        for name in filenames:
            path = current / name
            if is_candidate(path, max_bytes):
                yield path


def patch_file(path: Path, replacements: list[tuple[str, str]]) -> bool:
    try:
        data = path.read_bytes()
    except OSError:
        return False
    if b"\x00" in data:
        return False
    text = data.decode("utf-8", errors="ignore")
    original = text
    for source, target in replacements:
        if source:
            text = text.replace(source, target)
    if text == original:
        return False
    path.write_text(text, encoding="utf-8")
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description="Patch visible OpenClaw dashboard title text in a built image.")
    parser.add_argument("roots", nargs="+", help="Directories to scan inside the image")
    parser.add_argument("--source", default="OpenClaw", help="Primary source text")
    parser.add_argument("--extra-source", action="append", default=[], help="Additional exact source text")
    parser.add_argument("--target", required=True, help="Replacement display text")
    parser.add_argument("--max-file-bytes", type=int, default=8 * 1024 * 1024)
    parser.add_argument("--allow-missing", action="store_true")
    args = parser.parse_args()

    sources = [args.source, *args.extra_source]
    replacements = [(source, args.target) for source in dict.fromkeys(sources) if source]
    patched: list[Path] = []
    scanned = 0

    for root_name in args.roots:
        root = Path(root_name)
        for path in iter_files(root, args.max_file_bytes):
            scanned += 1
            if patch_file(path, replacements):
                patched.append(path)

    print(f"openclaw_dashboard_title_patch_scanned={scanned}")
    print(f"openclaw_dashboard_title_patch_count={len(patched)}")
    for path in patched[:50]:
        print(f"openclaw_dashboard_title_patch_file={path}")
    if len(patched) > 50:
        print(f"openclaw_dashboard_title_patch_file_omitted={len(patched) - 50}")

    if not patched and not args.allow_missing:
        print("error: no OpenClaw dashboard title text was patched", flush=True)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
