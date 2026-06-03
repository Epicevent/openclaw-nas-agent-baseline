#!/usr/bin/env python3
from __future__ import annotations

import re
import os
from pathlib import Path


ROOT = Path(os.environ.get("HERMES_WORKSPACE_ROOT", "/opt/hermes-workspace"))
CACHE_BUST_ID = os.environ.get("OPENCLAW_HERMES_CLIENT_PATCH_ID", "gemini-ui-r9")

PRETTY_ANCHOR = "{ id: 'anthropic', name: 'Anthropic', kind: 'api_key', envKeys: ['ANTHROPIC_API_KEY'], models: [] },"
PRETTY_INSERT = (
    PRETTY_ANCHOR
    + "\n  { id: 'gemini', name: 'Google Gemini', kind: 'api_key', envKeys: ['GOOGLE_API_KEY', 'GEMINI_API_KEY'], models: [] },"
)
SETTINGS_DIALOG_SOURCE_ANCHOR = """  {
    id: 'anthropic',
    name: 'Anthropic',
    logo: '/providers/anthropic.png',
    models: ['claude-sonnet-4-6', 'claude-opus-4-6', 'claude-haiku-3-5'],
    authType: 'api_key',
    envKey: 'ANTHROPIC_API_KEY',
  },"""
SETTINGS_DIALOG_SOURCE_INSERT = SETTINGS_DIALOG_SOURCE_ANCHOR + """
  {
    id: 'gemini',
    name: 'Google Gemini',
    logo: '',
    models: ['gemini-2.5-pro', 'gemini-2.5-flash', 'gemini-1.5-pro', 'gemini-1.5-flash'],
    authType: 'api_key',
    envKey: 'GOOGLE_API_KEY',
  },"""
SETTINGS_DIALOG_GEMINI_CARD_MIN = (
    "{id:'gemini',name:'Google Gemini',logo:'',"
    "models:['gemini-2.5-pro','gemini-2.5-flash','gemini-1.5-pro','gemini-1.5-flash'],"
    "authType:'api_key',envKey:'GOOGLE_API_KEY'},"
)
SETTINGS_DIALOG_GEMINI_CARD_MIN_DOUBLE = SETTINGS_DIALOG_GEMINI_CARD_MIN.replace("'", '"')
SETTINGS_PROVIDER_OPTION = "{ label: 'Google Gemini', value: 'gemini' },"
SETTINGS_PROVIDER_OPTION_MIN = "{label:'Google Gemini',value:'gemini'},"
SETTINGS_PROVIDER_OPTION_MIN_DOUBLE = SETTINGS_PROVIDER_OPTION_MIN.replace("'", '"')

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

SETTINGS_DIALOG_CARD_PATTERNS = [
    (
        re.compile(
            r"(\{\s*id\s*:\s*(['\"])anthropic\2\s*,\s*name\s*:\s*(['\"])Anthropic\3\s*,\s*logo\s*:\s*(['\"])/providers/anthropic\.png\4\s*,\s*models\s*:\s*\[[^\]]+\]\s*,\s*authType\s*:\s*(['\"])api_key\5\s*,\s*envKey\s*:\s*(['\"])ANTHROPIC_API_KEY\6\s*\}\s*,)",
            re.MULTILINE,
        ),
        "flexible",
    ),
    (
        re.compile(
            r"(\{id:'anthropic',name:'Anthropic',logo:'/providers/anthropic\.png',models:\[[^\]]+\],authType:'api_key',envKey:'ANTHROPIC_API_KEY'\},)"
        ),
        "single",
    ),
    (
        re.compile(
            r'(\{id:"anthropic",name:"Anthropic",logo:"/providers/anthropic\.png",models:\[[^\]]+\],authType:"api_key",envKey:"ANTHROPIC_API_KEY"\},)'
        ),
        "double",
    ),
]

SETTINGS_PROVIDER_OPTION_PATTERNS = [
    (
        re.compile(
            r"(\{\s*label\s*:\s*(['\"])Anthropic\2\s*,\s*value\s*:\s*(['\"])anthropic\3\s*\}\s*,)",
            re.MULTILINE,
        ),
        "flexible",
    ),
    (re.compile(r"(\{label:'Anthropic',value:'anthropic'\},)"), "single"),
    (re.compile(r'(\{label:"Anthropic",value:"anthropic"\},)'), "double"),
]


def candidate_files(root: Path):
    suffixes = {".js", ".cjs", ".mjs", ".ts", ".tsx"}
    roots = [
        root / "server-entry.js",
        root / "dist",
        root / "build",
        root / ".output",
        root / "public",
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
            if "node_modules" in path.parts or ".git" in path.parts:
                continue
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


def insert_after_object_with_marker(
    text: str,
    marker: str,
    required_fragments: tuple[str, ...],
    insert_builder,
) -> tuple[str, int]:
    marker_index = text.find(marker)
    while marker_index >= 0:
        start = text.rfind("{", 0, marker_index)
        end = text.find("}", marker_index)
        if start >= 0 and end >= 0:
            window = text[start : end + 1]
            if all(fragment in window for fragment in required_fragments):
                quote = '"' if f'"{marker}"' in window else "'"
                insert_at = end + 1
                suffix = ""
                if insert_at < len(text) and text[insert_at] == ",":
                    insert_at += 1
                else:
                    suffix = ","
                return (
                    text[:insert_at] + insert_builder(quote) + suffix + text[insert_at:],
                    1,
                )
        marker_index = text.find(marker, marker_index + 1)
    return text, 0


def patch_server_provider_catalog(text: str) -> tuple[str, int]:
    if "Google Gemini" in text and ("GEMINI_API_KEY" in text or "GOOGLE_API_KEY" in text):
        return text, 0
    if "ANTHROPIC_API_KEY" not in text or "OPENROUTER_API_KEY" not in text:
        return text, 0

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

    return new_text, changed


def patch_settings_dialog_cards(text: str) -> tuple[str, int]:
    if "Google Gemini" in text and "GOOGLE_API_KEY" in text:
        return text, 0
    if "ANTHROPIC_API_KEY" not in text or "XIAOMI_API_KEY" not in text:
        return text, 0

    changed = 0
    new_text = text
    if SETTINGS_DIALOG_SOURCE_ANCHOR in new_text:
        new_text = new_text.replace(SETTINGS_DIALOG_SOURCE_ANCHOR, SETTINGS_DIALOG_SOURCE_INSERT, 1)
        changed += 1

    if not changed:
        for pattern, style in SETTINGS_DIALOG_CARD_PATTERNS:
            def replace(match: re.Match[str]) -> str:
                if style == "double":
                    return match.group(1) + SETTINGS_DIALOG_GEMINI_CARD_MIN_DOUBLE
                if style == "single":
                    return match.group(1) + SETTINGS_DIALOG_GEMINI_CARD_MIN
                quote = match.group(2)
                return (
                    match.group(1)
                    + "{id:"
                    + quote
                    + "gemini"
                    + quote
                    + ",name:"
                    + quote
                    + "Google Gemini"
                    + quote
                    + ",logo:"
                    + quote
                    + quote
                    + ",models:["
                    + quote
                    + "gemini-2.5-pro"
                    + quote
                    + ","
                    + quote
                    + "gemini-2.5-flash"
                    + quote
                    + ","
                    + quote
                    + "gemini-1.5-pro"
                    + quote
                    + ","
                    + quote
                    + "gemini-1.5-flash"
                    + quote
                    + "],authType:"
                    + quote
                    + "api_key"
                    + quote
                    + ",envKey:"
                    + quote
                    + "GOOGLE_API_KEY"
                    + quote
                    + "},"
                )

            new_text, count = pattern.subn(replace, new_text, count=1)
            changed += count
            if count:
                break

    if not changed:
        def build_gemini_card(quote: str) -> str:
            return (
                "{id:"
                + quote
                + "gemini"
                + quote
                + ",name:"
                + quote
                + "Google Gemini"
                + quote
                + ",logo:"
                + quote
                + quote
                + ",models:["
                + quote
                + "gemini-2.5-pro"
                + quote
                + ","
                + quote
                + "gemini-2.5-flash"
                + quote
                + ","
                + quote
                + "gemini-1.5-pro"
                + quote
                + ","
                + quote
                + "gemini-1.5-flash"
                + quote
                + "],authType:"
                + quote
                + "api_key"
                + quote
                + ",envKey:"
                + quote
                + "GOOGLE_API_KEY"
                + quote
                + "},"
            )

        new_text, count = insert_after_object_with_marker(
            new_text,
            "ANTHROPIC_API_KEY",
            ("anthropic", "Anthropic", "api_key", "envKey"),
            build_gemini_card,
        )
        changed += count

    return new_text, changed


def patch_settings_provider_options(text: str) -> tuple[str, int]:
    if "Google Gemini" in text and "MODEL_PROVIDER_OPTIONS" in text:
        return text, 0
    if "MODEL_PROVIDER_OPTIONS" not in text or "ModelProviderOption" not in text:
        return text, 0

    changed = 0
    new_text = text
    new_text, count = re.subn(
        r"(type\s+ModelProviderOption\s*=\s*[^;\n]*'anthropic')",
        r"\1 | 'gemini'",
        new_text,
        count=1,
    )
    changed += count
    for pattern, style in SETTINGS_PROVIDER_OPTION_PATTERNS:
        def replace(match: re.Match[str]) -> str:
            if style == "double":
                return match.group(1) + SETTINGS_PROVIDER_OPTION_MIN_DOUBLE
            if style == "single":
                return match.group(1) + SETTINGS_PROVIDER_OPTION_MIN
            return match.group(1) + "\n  " + SETTINGS_PROVIDER_OPTION

        new_text, count = pattern.subn(replace, new_text, count=1)
        changed += count
        if count:
            break
    return new_text, changed


def patch_file(path: Path) -> int:
    try:
        text = path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        return 0
    new_text = text
    changed = 0
    for patcher in (
        patch_server_provider_catalog,
        patch_settings_dialog_cards,
        patch_settings_provider_options,
    ):
        new_text, count = patcher(new_text)
        changed += count

    if changed:
        path.write_text(new_text, encoding="utf-8")
    return changed


def patch_client_cache_bust(root: Path) -> list[tuple[Path, int]]:
    patched: list[tuple[Path, int]] = []
    html_files = []
    root_index = root / "index.html"
    if root_index.exists():
        html_files.append(root_index)
    html_roots = [
        root / "dist",
        root / "build",
        root / ".output",
        root / "public",
    ]
    for html_root in html_roots:
        if not html_root.exists():
            continue
        for path in html_root.rglob("index.html"):
            html_files.append(path)

    seen: set[Path] = set()
    for path in html_files:
        if path in seen:
            continue
        seen.add(path)
        if "node_modules" in path.parts or ".git" in path.parts:
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            continue
        if CACHE_BUST_ID in text:
            continue
        new_text, count = re.subn(
            r"((?:src|href)=['\"]/assets/[^'\"\?]+?\.(?:js|css))(['\"])",
            rf"\1?{CACHE_BUST_ID}\2",
            text,
        )
        if count:
            path.write_text(new_text, encoding="utf-8")
            patched.append((path, count))
    return patched


def gemini_patch_already_present(root: Path) -> bool:
    provider_present = False
    cache_bust_present = False

    for path in candidate_files(root):
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        if "Google Gemini" in text and "GOOGLE_API_KEY" in text:
            provider_present = True
            break

    html_files = [root / "index.html"]
    for html_root in (root / "dist", root / "build", root / ".output", root / "public"):
        if html_root.exists():
            html_files.extend(html_root.rglob("index.html"))

    for path in html_files:
        if "node_modules" in path.parts or ".git" in path.parts:
            continue
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        if CACHE_BUST_ID in text:
            cache_bust_present = True
            break

    return provider_present and cache_bust_present


def main() -> int:
    if not ROOT.exists():
        print(f"error: workspace root not found: {ROOT}")
        return 1
    patched = []
    for path in candidate_files(ROOT):
        count = patch_file(path)
        if count:
            patched.append((path, count))
    patched.extend(patch_client_cache_bust(ROOT))

    for path, count in patched:
        print(f"patched={path} replacements={count}")

    if not patched and gemini_patch_already_present(ROOT):
        print("hermes_workspace_gemini_provider_patch=already_present")
        return 0

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
