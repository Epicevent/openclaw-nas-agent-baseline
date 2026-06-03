#!/usr/bin/env python3
from __future__ import annotations

import re
import os
from pathlib import Path


ROOT = Path(os.environ.get("HERMES_WORKSPACE_ROOT", "/opt/hermes-workspace"))

PRETTY_ANCHOR = "{ id: 'anthropic', name: 'Anthropic', kind: 'api_key', envKeys: ['ANTHROPIC_API_KEY'], models: [] },"
PRETTY_INSERT = (
    PRETTY_ANCHOR
    + "\n  { id: 'gemini', name: 'Google Gemini', kind: 'api_key', envKeys: ['GOOGLE_API_KEY', 'GEMINI_API_KEY'], models: [] },"
)

PATTERNS = [
    (
        re.compile(
            r"(\{\s*id\s*:\s*(['\"])anthropic\2\s*,\s*name\s*:\s*(['\"])Anthropic\3\s*,\s*kind\s*:\s*(['\"])api_key\4\s*,\s*envKeys\s*:\s*\[\s*(['\"])ANTHROPIC_API_KEY\5\s*\]\s*,\s*models\s*:\s*\[\s*\]\s*\}\s*,)",
            re.MULTILINE,
        ),
        "flexible",
    ),
    (
        re.compile(
            r"(\{id:'anthropic',name:'Anthropic',kind:'api_key',envKeys:\['ANTHROPIC_API_KEY'\],models:\[\]\},)"
        ),
        "single",
    ),
    (
        re.compile(
            r'(\{id:"anthropic",name:"Anthropic",kind:"api_key",envKeys:\["ANTHROPIC_API_KEY"\],models:\[\]\},)'
        ),
        "double",
    ),
]


def candidate_files(root: Path):
    suffixes = {".js", ".cjs", ".mjs", ".ts", ".tsx"}
    roots = [
        root / "server-entry.js",
        root / "dist",
        root / "src",
        root / "electron",
    ]
    seen: set[Path] = set()
    for scan_root in roots:
        if not scan_root.exists():
            continue
        iterator = [scan_root] if scan_root.is_file() else scan_root.rglob("*")
        for path in iterator:
            if path in seen:
                continue
            seen.add(path)
            if not path.is_file() or path.suffix not in suffixes:
                continue
            try:
                if path.stat().st_size > 80 * 1024 * 1024:
                    continue
            except OSError:
                continue
            yield path


def fallback_insert_after_anthropic(text: str) -> tuple[str, int]:
    marker_index = text.find("ANTHROPIC_API_KEY")
    while marker_index >= 0:
        start = text.rfind("{", 0, marker_index)
        end = text.find("}", marker_index)
        if start >= 0 and end >= 0:
            window = text[start : end + 1]
            if "anthropic" in window and "Anthropic" in window and "api_key" in window and "envKeys" in window:
                quote = '"' if '"ANTHROPIC_API_KEY"' in window else "'"
                gemini = (
                    "{"
                    + f"id:{quote}gemini{quote},"
                    + f"name:{quote}Google Gemini{quote},"
                    + f"kind:{quote}api_key{quote},"
                    + f"envKeys:[{quote}GOOGLE_API_KEY{quote},{quote}GEMINI_API_KEY{quote}],"
                    + "models:[]"
                    + "}"
                )
                insert_at = end + 1
                if insert_at < len(text) and text[insert_at] == ",":
                    insert_at += 1
                    return text[:insert_at] + gemini + "," + text[insert_at:], 1
                return text[:insert_at] + "," + gemini + text[insert_at:], 1
        marker_index = text.find("ANTHROPIC_API_KEY", marker_index + 1)
    return text, 0


def patch_file(path: Path) -> int:
    try:
        text = path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        return 0
    if "Google Gemini" in text and ("GEMINI_API_KEY" in text or "GOOGLE_API_KEY" in text):
        return 0
    if "ANTHROPIC_API_KEY" not in text or "OPENROUTER_API_KEY" not in text:
        return 0

    changed = 0
    new_text = text
    if PRETTY_ANCHOR in new_text:
        new_text = new_text.replace(PRETTY_ANCHOR, PRETTY_INSERT, 1)
        changed += 1

    for pattern, style in PATTERNS:
        def replace(match: re.Match[str]) -> str:
            quote = '"' if style == "double" else "'"
            if style == "flexible":
                quote = match.group(2)
            gemini = (
                "{id:"
                + quote
                + "gemini"
                + quote
                + ",name:"
                + quote
                + "Google Gemini"
                + quote
                + ",kind:"
                + quote
                + "api_key"
                + quote
                + ",envKeys:["
                + quote
                + "GOOGLE_API_KEY"
                + quote
                + ","
                + quote
                + "GEMINI_API_KEY"
                + quote
                + "],models:[]},"
            )
            return match.group(1) + gemini

        new_text, count = pattern.subn(replace, new_text, count=1)
        changed += count

    if not changed:
        new_text, count = fallback_insert_after_anthropic(new_text)
        changed += count

    if changed:
        path.write_text(new_text, encoding="utf-8")
    return changed


def main() -> int:
    if not ROOT.exists():
        print(f"error: workspace root not found: {ROOT}")
        return 1
    patched = []
    for path in candidate_files(ROOT):
        count = patch_file(path)
        if count:
            patched.append((path, count))

    for path, count in patched:
        print(f"patched={path} replacements={count}")

    if not patched:
        print("error: no Hermes Workspace provider catalog patched")
        scanned = 0
        likely = []
        for path in candidate_files(ROOT):
            scanned += 1
            try:
                text = path.read_text(encoding="utf-8", errors="replace")
            except OSError:
                continue
            if "ANTHROPIC_API_KEY" in text or "OPENROUTER_API_KEY" in text or "HERMES_PROVIDER_CATALOG" in text:
                likely.append(str(path))
        print(f"scanned_files={scanned}")
        print("candidate_files_with_provider_markers=" + ",".join(likely[:20]))
        return 1
    print("hermes_workspace_gemini_provider_patch=ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
