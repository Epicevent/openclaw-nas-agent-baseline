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
            r"(\{id:'anthropic',name:'Anthropic',kind:'api_key',envKeys:\['ANTHROPIC_API_KEY'\],models:\[\]\},)"
        ),
        r"\1{id:'gemini',name:'Google Gemini',kind:'api_key',envKeys:['GOOGLE_API_KEY','GEMINI_API_KEY'],models:[]},",
    ),
    (
        re.compile(
            r'(\{id:"anthropic",name:"Anthropic",kind:"api_key",envKeys:\["ANTHROPIC_API_KEY"\],models:\[\]\},)'
        ),
        r'\1{id:"gemini",name:"Google Gemini",kind:"api_key",envKeys:["GOOGLE_API_KEY","GEMINI_API_KEY"],models:[]},',
    ),
]


def candidate_files(root: Path):
    suffixes = {".js", ".cjs", ".mjs", ".ts", ".tsx"}
    for path in root.rglob("*"):
        if not path.is_file() or path.suffix not in suffixes:
            continue
        try:
            if path.stat().st_size > 80 * 1024 * 1024:
                continue
        except OSError:
            continue
        yield path


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

    for pattern, replacement in PATTERNS:
        new_text, count = pattern.subn(replacement, new_text, count=1)
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
        return 1
    print("hermes_workspace_gemini_provider_patch=ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
