#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import re
import stat
import sys
from pathlib import Path


DEFAULT_GEMINI_MODEL = "gemini-2.5-pro"
KNOWN_GEMINI_MODELS = {
    "gemini-2.5-pro",
    "gemini-2.5-flash",
    "gemini-1.5-pro",
    "gemini-1.5-flash",
}


def die(message: str, code: int = 1) -> None:
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(code)


def safe_write_regular(path: Path, text: str, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.parent.is_symlink():
        die(f"config parent must not be a symlink: {path.parent}")
    if path.exists() and path.is_symlink():
        die(f"config file must not be a symlink: {path}")

    flags = os.O_WRONLY | os.O_CREAT
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    fd = os.open(path, flags, mode)
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            die(f"config file must be regular: {path}")
        if st.st_nlink != 1:
            die(f"config file must not be hardlinked: {path}")
        os.ftruncate(fd, 0)
        os.write(fd, text.encode("utf-8"))
    finally:
        os.close(fd)
    os.chmod(path, mode)


def validate_gemini_model(model: str) -> str:
    if model in KNOWN_GEMINI_MODELS:
        return model
    if not re.fullmatch(r"gemini-[A-Za-z0-9][A-Za-z0-9._:-]{0,127}", model):
        die(f"invalid Gemini model: {model}", 2)
    return model


def top_level_key(line: str) -> str:
    if not line or line[0].isspace() or ":" not in line:
        return ""
    return line.split(":", 1)[0].strip()


def strip_model_keys(lines: list[str]) -> list[str]:
    out: list[str] = []
    skip_model_block = False
    for line in lines:
        key = top_level_key(line)
        if skip_model_block:
            if not line.strip():
                continue
            if not key:
                continue
            skip_model_block = False

        if key == "provider":
            continue
        if key == "model":
            skip_model_block = True
            continue
        out.append(line)
    return out


def read_config_lines(path: Path) -> list[str]:
    if not path.exists():
        return []
    if path.is_symlink():
        die(f"config file must not be a symlink: {path}")
    st = path.stat()
    if not stat.S_ISREG(st.st_mode):
        die(f"config file must be regular: {path}")
    if st.st_nlink != 1:
        die(f"config file must not be hardlinked: {path}")
    return path.read_text(encoding="utf-8", errors="replace").splitlines()


def set_gemini_config(path: Path, model: str) -> None:
    model = validate_gemini_model(model)
    lines = strip_model_keys(read_config_lines(path))
    while lines and not lines[-1].strip():
        lines.pop()
    if lines:
        lines.append("")
    lines.extend(
        [
            "provider: gemini",
            f"model: {model}",
        ]
    )
    safe_write_regular(path, "\n".join(lines) + "\n")
    print(f"hermes_config_path={path}")
    print("hermes_provider=gemini")
    print(f"hermes_model={model}")


def parse_scalar(value: str) -> str:
    value = value.strip()
    if (value.startswith("'") and value.endswith("'")) or (
        value.startswith('"') and value.endswith('"')
    ):
        return value[1:-1]
    return value


def config_status(path: Path) -> int:
    print(f"hermes_config_file={path}")
    if not path.exists():
        print("hermes_config_state=missing")
        return 1
    if path.is_symlink():
        print("hermes_config_state=symlink_refused")
        return 1
    st = path.stat()
    if not stat.S_ISREG(st.st_mode):
        print("hermes_config_state=not_regular")
        return 1
    if st.st_nlink != 1:
        print("hermes_config_state=hardlink_refused")
        return 1

    provider = ""
    model = ""
    in_model_block = False
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        key = top_level_key(line)
        if key:
            in_model_block = key == "model" and not line.split(":", 1)[1].strip()
        if key == "provider":
            provider = parse_scalar(line.split(":", 1)[1])
        elif key == "model":
            scalar = line.split(":", 1)[1].strip()
            if scalar:
                model = parse_scalar(scalar)
        elif in_model_block:
            stripped = line.strip()
            if stripped.startswith("provider:"):
                provider = parse_scalar(stripped.split(":", 1)[1])
            elif stripped.startswith("default:"):
                model = parse_scalar(stripped.split(":", 1)[1])

    print("hermes_config_state=present")
    print(f"hermes_provider={provider or 'missing'}")
    print(f"hermes_model={model or 'missing'}")
    return 0 if provider and model else 1


def env_has_gemini_key(path: Path) -> bool:
    if not path.exists() or path.is_symlink():
        return False
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or "=" not in stripped:
            continue
        key, value = stripped.split("=", 1)
        key = key.removeprefix("export ").strip()
        if key in {"GEMINI_API_KEY", "GOOGLE_API_KEY"} and value.strip().strip("'\""):
            return True
    return False


def main() -> int:
    parser = argparse.ArgumentParser(description="Manage Hermes provider config without printing secrets.")
    sub = parser.add_subparsers(dest="command", required=True)

    set_parser = sub.add_parser("set-gemini")
    set_parser.add_argument("--config", required=True)
    set_parser.add_argument("--model", default=os.environ.get("OPENCLAW_HERMES_GEMINI_MODEL", DEFAULT_GEMINI_MODEL))

    status_parser = sub.add_parser("status")
    status_parser.add_argument("--config", required=True)

    has_parser = sub.add_parser("has-gemini-key")
    has_parser.add_argument("--env", required=True)

    args = parser.parse_args()
    if args.command == "set-gemini":
        set_gemini_config(Path(args.config), args.model)
        return 0
    if args.command == "status":
        return config_status(Path(args.config))
    if args.command == "has-gemini-key":
        return 0 if env_has_gemini_key(Path(args.env)) else 1
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
