#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import stat
from pathlib import Path
from typing import Any


def read_config(path: Path) -> dict[str, Any]:
    if not path.exists():
        raise RuntimeError("missing")
    if path.is_symlink():
        raise RuntimeError("symlink_refused")
    st = path.stat()
    if not stat.S_ISREG(st.st_mode):
        raise RuntimeError("not_regular")
    if st.st_nlink != 1:
        raise RuntimeError("hardlink_refused")
    return json.loads(path.read_text(encoding="utf-8") or "{}")


def primary_model(data: dict[str, Any]) -> str:
    agents = data.get("agents")
    if not isinstance(agents, dict):
        return ""
    defaults = agents.get("defaults")
    if not isinstance(defaults, dict):
        return ""
    model = defaults.get("model")
    if isinstance(model, str):
        return model.strip()
    if isinstance(model, dict):
        for key in ("primary", "default", "model", "id", "name"):
            value = model.get(key)
            if isinstance(value, str) and value.strip():
                return value.strip()
    return ""


def heartbeat_every(data: dict[str, Any]) -> str:
    agents = data.get("agents")
    if not isinstance(agents, dict):
        return ""
    defaults = agents.get("defaults")
    if not isinstance(defaults, dict):
        return ""
    heartbeat = defaults.get("heartbeat")
    if not isinstance(heartbeat, dict):
        return ""
    value = heartbeat.get("every")
    return str(value).strip() if value is not None else ""


def command_status(config: Path) -> int:
    print(f"openclaw_config_file={config}")
    try:
        data = read_config(config)
    except RuntimeError as exc:
        print(f"openclaw_config_state={exc}")
        return 1
    print("openclaw_config_state=present")
    print(f"openclaw_model_primary={primary_model(data) or 'implicit_default'}")
    print(f"openclaw_heartbeat_every={heartbeat_every(data) or 'implicit_default'}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Print non-secret OpenClaw runtime config status.")
    sub = parser.add_subparsers(dest="command", required=True)

    status = sub.add_parser("status")
    status.add_argument("--config", required=True)

    args = parser.parse_args()
    if args.command == "status":
        return command_status(Path(args.config))
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
