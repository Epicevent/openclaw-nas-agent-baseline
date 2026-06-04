#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import re
from pathlib import Path


TEXT_SUFFIXES = {
    ".html",
    ".htm",
    ".js",
    ".mjs",
    ".cjs",
    ".css",
    ".svg",
    ".txt",
}
JS_SUFFIXES = {
    ".js",
    ".mjs",
    ".cjs",
}

SKIP_DIRS = {
    ".git",
    ".cache",
    "__pycache__",
    "node_modules",
    "vendor",
}


def is_candidate(
    path: Path,
    max_bytes: int,
    include_path_re: re.Pattern[str] | None,
    exclude_path_re: re.Pattern[str] | None,
) -> bool:
    try:
        if not path.is_file() or path.is_symlink():
            return False
        normalized = path.as_posix()
        if include_path_re is not None and not include_path_re.search(normalized):
            return False
        if exclude_path_re is not None and exclude_path_re.search(normalized):
            return False
        if path.suffix.lower() not in TEXT_SUFFIXES:
            return False
        if path.stat().st_size > max_bytes:
            return False
    except OSError:
        return False
    return True


def iter_files(
    root: Path,
    max_bytes: int,
    include_path_re: re.Pattern[str] | None,
    exclude_path_re: re.Pattern[str] | None,
):
    if not root.exists():
        return
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [item for item in dirnames if item not in SKIP_DIRS]
        current = Path(dirpath)
        for name in filenames:
            path = current / name
            if is_candidate(path, max_bytes, include_path_re, exclude_path_re):
                yield path


def patch_js_string_literals(text: str, replacements: list[tuple[str, str]]) -> tuple[str, int]:
    out: list[str] = []
    changed = 0
    i = 0
    length = len(text)
    while i < length:
        char = text[i]
        if char not in {"'", '"', "`"}:
            out.append(char)
            i += 1
            continue

        quote = char
        start = i
        i += 1
        escaped = False
        while i < length:
            current = text[i]
            if escaped:
                escaped = False
                i += 1
                continue
            if current == "\\":
                escaped = True
                i += 1
                continue
            if current == quote:
                i += 1
                break
            i += 1

        literal = text[start:i]
        if len(literal) < 2 or literal[-1] != quote:
            out.append(literal)
            continue
        body = literal[1:-1]
        new_body = body
        for source, target in replacements:
            if source:
                changed += new_body.count(source)
                new_body = new_body.replace(source, target)
        out.append(f"{quote}{new_body}{quote}")
    return "".join(out), changed


def patch_text(text: str, replacements: list[tuple[str, str]]) -> tuple[str, int]:
    new_text = text
    changed = 0
    for source, target in replacements:
        if source:
            changed += new_text.count(source)
            new_text = new_text.replace(source, target)
    return new_text, changed


def patch_file(path: Path, replacements: list[tuple[str, str]]) -> int:
    try:
        data = path.read_bytes()
    except OSError:
        return 0
    if b"\x00" in data:
        return 0
    text = data.decode("utf-8", errors="ignore")
    original = text
    if path.suffix.lower() in JS_SUFFIXES:
        text, replacement_count = patch_js_string_literals(text, replacements)
    else:
        text, replacement_count = patch_text(text, replacements)
    if text == original:
        return 0
    path.write_text(text, encoding="utf-8")
    return replacement_count


def main() -> int:
    parser = argparse.ArgumentParser(description="Patch visible OpenClaw dashboard title text in a built image.")
    parser.add_argument("roots", nargs="+", help="Directories to scan inside the image")
    parser.add_argument("--source", default="OpenClaw", help="Primary source text")
    parser.add_argument("--extra-source", action="append", default=[], help="Additional exact source text")
    parser.add_argument("--target", required=True, help="Replacement display text")
    parser.add_argument("--max-file-bytes", type=int, default=8 * 1024 * 1024)
    parser.add_argument("--include-path-regex", default="", help="Only patch files whose normalized path matches this regex")
    parser.add_argument("--exclude-path-regex", default="", help="Skip files whose normalized path matches this regex")
    parser.add_argument("--max-patched-files", type=int, default=80)
    parser.add_argument("--max-replacements", type=int, default=200)
    parser.add_argument("--allow-missing", action="store_true")
    args = parser.parse_args()

    sources = [args.source, *args.extra_source]
    replacements = [(source, args.target) for source in dict.fromkeys(sources) if source]
    patched: list[Path] = []
    scanned = 0
    replacement_total = 0
    include_path_re = re.compile(args.include_path_regex) if args.include_path_regex else None
    exclude_path_re = re.compile(args.exclude_path_regex) if args.exclude_path_regex else None

    for root_name in args.roots:
        root = Path(root_name)
        for path in iter_files(root, args.max_file_bytes, include_path_re, exclude_path_re):
            scanned += 1
            replacement_count = patch_file(path, replacements)
            if replacement_count:
                replacement_total += replacement_count
                patched.append(path)

    print(f"openclaw_dashboard_title_patch_scanned={scanned}")
    print(f"openclaw_dashboard_title_patch_count={len(patched)}")
    print(f"openclaw_dashboard_title_patch_replacements={replacement_total}")
    for path in patched[:50]:
        print(f"openclaw_dashboard_title_patch_file={path}")
    if len(patched) > 50:
        print(f"openclaw_dashboard_title_patch_file_omitted={len(patched) - 50}")

    if not patched and not args.allow_missing:
        print("error: no OpenClaw dashboard title text was patched", flush=True)
        return 1
    if len(patched) > args.max_patched_files:
        print(f"error: too many patched files: {len(patched)} > {args.max_patched_files}", flush=True)
        return 1
    if replacement_total > args.max_replacements:
        print(f"error: too many replacements: {replacement_total} > {args.max_replacements}", flush=True)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
