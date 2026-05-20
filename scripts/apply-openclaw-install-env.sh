#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  apply-openclaw-install-env.sh --env-file FILE [--user USER] [--home HOME] [--no-runtime-env] [--import-gateway-token]

Applies install-time OpenClaw settings into a newly created account.
The script does not print secret values.

This is not a restore step. It is the settings materialization step that the
bootstrap should run during a fresh install when an install env file is present.

By default, this script does not copy a gateway token from the env file. Fresh
installs should keep the generated gateway token unless the operator explicitly
passes --import-gateway-token.

It updates:
  - ~/.openclaw/openclaw.json for non-secret settings
  - ~/openclaw/.env for runtime env values, when ~/openclaw exists
  - Control UI device pairing bypass, unless explicitly disabled

Secret values such as GEMINI_API_KEY are not written into openclaw.json. The
Gateway reads them from its runtime environment.

Examples:
  bash scripts/apply-openclaw-install-env.sh --env-file "$HOME/.openclaw-install.env" --home "$HOME"
  sudo bash scripts/apply-openclaw-install-env.sh --env-file /secure/ocN.install.env --user ocN
USAGE
}

target_user=""
target_home=""
env_file=""
write_runtime_env=1
import_gateway_token=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file)
      env_file="${2:?missing env file}"
      shift 2
      ;;
    --user)
      target_user="${2:?missing user}"
      shift 2
      ;;
    --home)
      target_home="${2:?missing home}"
      shift 2
      ;;
    --no-runtime-env)
      write_runtime_env=0
      shift
      ;;
    --import-gateway-token)
      import_gateway_token=1
      shift
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

if [[ -z "$env_file" ]]; then
  echo "error: --env-file is required" >&2
  usage >&2
  exit 2
fi

if [[ ! -f "$env_file" ]]; then
  echo "error: env file not found: $env_file" >&2
  exit 1
fi

if [[ -n "$target_user" && -z "$target_home" ]]; then
  target_home="$(getent passwd "$target_user" | cut -d: -f6)"
fi

if [[ -z "$target_home" ]]; then
  target_home="${HOME:?HOME is not set}"
fi

if [[ -z "$target_user" ]]; then
  if command -v getent >/dev/null 2>&1; then
    target_user="$(getent passwd "$(id -u)" | cut -d: -f1 || true)"
  fi
  target_user="${target_user:-$(id -un)}"
fi

target_uid="$(id -u "$target_user" 2>/dev/null || true)"
target_gid="$(id -g "$target_user" 2>/dev/null || true)"

openclaw_dir="$target_home/.openclaw"
config_path="$openclaw_dir/openclaw.json"
runtime_env_path="$target_home/openclaw/.env"

mkdir -p "$openclaw_dir"

OPENCLAW_IMPORT_ENV_FILE="$env_file" \
OPENCLAW_IMPORT_CONFIG_PATH="$config_path" \
OPENCLAW_IMPORT_RUNTIME_ENV_PATH="$runtime_env_path" \
OPENCLAW_IMPORT_WRITE_RUNTIME_ENV="$write_runtime_env" \
OPENCLAW_IMPORT_GATEWAY_TOKEN="$import_gateway_token" \
OPENCLAW_IMPORT_USER="$target_user" \
python3 - <<'PY'
import json
import os
import re
import secrets
import shlex
from pathlib import Path

env_file = Path(os.environ["OPENCLAW_IMPORT_ENV_FILE"])
config_path = Path(os.environ["OPENCLAW_IMPORT_CONFIG_PATH"])
runtime_env_path = Path(os.environ["OPENCLAW_IMPORT_RUNTIME_ENV_PATH"])
write_runtime_env = os.environ["OPENCLAW_IMPORT_WRITE_RUNTIME_ENV"] == "1"
import_gateway_token = os.environ["OPENCLAW_IMPORT_GATEWAY_TOKEN"] == "1"
target_user = os.environ["OPENCLAW_IMPORT_USER"]

key_re = re.compile(r"^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$")


def parse_value(raw: str) -> str:
    raw = raw.strip()
    if not raw:
        return ""
    if raw[0] in ("'", '"'):
        try:
            parts = shlex.split(raw, posix=True)
            return parts[0] if parts else ""
        except ValueError:
            return raw.strip("'\"")
    return raw


def parse_env(path: Path) -> dict[str, str]:
    out: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.lstrip("\ufeff")
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        m = key_re.match(line)
        if not m:
            continue
        key, raw = m.group(1), m.group(2)
        out[key] = parse_value(raw)
    return out


def split_origins(*values: str) -> list[str]:
    origins: list[str] = []
    for value in values:
        for raw in (value or "").split(","):
            origin = raw.strip().rstrip("/")
            if origin and origin not in origins:
                origins.append(origin)
    return origins


def bool_from_env(value, default: bool = False) -> bool:
    if value is None or value == "":
        return default
    return value.strip().lower() in {"1", "true", "yes", "on"}


def normalize_base_path(value: str, default: str) -> str:
    raw = (value or "").strip()
    if not raw:
        return default
    if raw == "/":
        return "/"
    if not raw.startswith("/"):
        raw = f"/{raw}"
    return raw.rstrip("/") or "/"


def quote_env(value: str) -> str:
    return "'" + value.replace("'", "'\"'\"'") + "'"


def upsert_env_file(path: Path, values: dict[str, str]) -> None:
    existing_lines: list[str] = []
    seen: set[str] = set()
    if path.exists():
        existing_lines = path.read_text(encoding="utf-8", errors="replace").splitlines()

    new_lines: list[str] = []
    for line in existing_lines:
        m = key_re.match(line)
        if not m:
            new_lines.append(line)
            continue
        key = m.group(1)
        if key in values:
            new_lines.append(f"{key}={quote_env(values[key])}")
            seen.add(key)
        else:
            new_lines.append(line)

    for key in sorted(values):
        if key not in seen:
            new_lines.append(f"{key}={quote_env(values[key])}")

    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(new_lines) + "\n", encoding="utf-8")
    path.chmod(0o600)


env = parse_env(env_file)

if config_path.exists():
    data = json.loads(config_path.read_text(encoding="utf-8") or "{}")
else:
    data = {}

gateway = data.setdefault("gateway", {})
gateway.setdefault("mode", "local")
gateway.setdefault("port", 18789)
if env.get("OPENCLAW_GATEWAY_BIND"):
    gateway["bind"] = env["OPENCLAW_GATEWAY_BIND"]
else:
    gateway.setdefault("bind", "lan")

auth = gateway.setdefault("auth", {})
auth.setdefault("mode", "token")
if import_gateway_token and env.get("OPENCLAW_GATEWAY_TOKEN"):
    auth["token"] = env["OPENCLAW_GATEWAY_TOKEN"]
elif not auth.get("token"):
    auth["token"] = secrets.token_urlsafe(32)

control = gateway.setdefault("controlUi", {})
control.pop("autoApproveWithToken", None)
control["dangerouslyDisableDeviceAuth"] = bool_from_env(
    env.get("OPENCLAW_CONTROL_UI_DISABLE_DEVICE_AUTH"),
    default=True,
)
if env.get("OPENCLAW_CONTROL_UI_BASEPATH"):
    control["basePath"] = normalize_base_path(
        env["OPENCLAW_CONTROL_UI_BASEPATH"],
        default=f"/{target_user}",
    )

origins = split_origins(env.get("OPENCLAW_PROXY_PUBLIC_ORIGIN", ""), env.get("OPENCLAW_PROXY_ALLOWED_ORIGINS", ""))
if origins:
    control["allowedOrigins"] = origins

if env.get("GEMINI_API_KEY"):
    plugins = data.setdefault("plugins", {}).setdefault("entries", {})
    google = plugins.setdefault("google", {})
    google["enabled"] = True
    web_search_config = google.setdefault("config", {}).setdefault("webSearch", {})
    # Keep API keys out of host-readable OpenClaw config. Gemini web search
    # falls back to GEMINI_API_KEY from the Gateway environment.
    web_search_config.pop("apiKey", None)
    web_search = data.setdefault("tools", {}).setdefault("web", {}).setdefault("search", {})
    web_search["provider"] = "gemini"
    web_search["enabled"] = True

if env.get("OPENCLAW_DEFAULT_MODEL"):
    model = env["OPENCLAW_DEFAULT_MODEL"]
    defaults = data.setdefault("agents", {}).setdefault("defaults", {})
    defaults.setdefault("model", {})["primary"] = model
    defaults.setdefault("models", {}).setdefault(model, {})

if env.get("OPENCLAW_SANDBOX"):
    data.setdefault("agents", {}).setdefault("defaults", {}).setdefault("sandbox", {})["mode"] = env["OPENCLAW_SANDBOX"]

config_path.parent.mkdir(parents=True, exist_ok=True)
config_path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
config_path.chmod(0o600)

runtime_keys = {
    "COMPOSE_PROJECT_NAME",
    "DOCKER_GID",
    "GEMINI_API_KEY",
    "OPENCLAW_ALLOW_INSECURE_PRIVATE_WS",
    "OPENCLAW_BRIDGE_PORT",
    "OPENCLAW_CONFIG_DIR",
    "OPENCLAW_CONTROL_UI_BASEPATH",
    "OPENCLAW_CONTROL_UI_DISABLE_DEVICE_AUTH",
    "OPENCLAW_DEFAULT_MODEL",
    "OPENCLAW_DISABLE_BONJOUR",
    "OPENCLAW_DOCKER_APT_PACKAGES",
    "OPENCLAW_DOCKER_SOCKET",
    "OPENCLAW_EXTENSIONS",
    "OPENCLAW_EXTRA_MOUNTS",
    "OPENCLAW_GATEWAY_BIND",
    "OPENCLAW_GATEWAY_PORT",
    "OPENCLAW_HOME_VOLUME",
    "OPENCLAW_HOST_GID",
    "OPENCLAW_HOST_UID",
    "OPENCLAW_INSTALL_DOCKER_CLI",
    "OPENCLAW_INSTANCE",
    "OPENCLAW_NAS_CONTAINER_PATH",
    "OPENCLAW_NAS_HOST_PATH",
    "OPENCLAW_NAS_SYMLINK",
    "OPENCLAW_OTEL_PRELOADED",
    "OPENCLAW_PORT_BASE",
    "OPENCLAW_PORT_SLOT",
    "OPENCLAW_PORT_STRIDE",
    "OPENCLAW_PROXY_ALLOWED_ORIGINS",
    "OPENCLAW_PROXY_PUBLIC_ORIGIN",
    "OPENCLAW_SANDBOX",
    "OPENCLAW_SKIP_ONBOARDING",
    "OPENCLAW_TZ",
    "OPENCLAW_WORKSPACE_DIR",
    "OTEL_EXPORTER_OTLP_ENDPOINT",
    "OTEL_EXPORTER_OTLP_LOGS_ENDPOINT",
    "OTEL_EXPORTER_OTLP_METRICS_ENDPOINT",
    "OTEL_EXPORTER_OTLP_PROTOCOL",
    "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT",
    "OTEL_SEMCONV_STABILITY_OPT_IN",
    "OTEL_SERVICE_NAME",
}

if import_gateway_token:
    runtime_keys.add("OPENCLAW_GATEWAY_TOKEN")

runtime_values = {key: env[key] for key in runtime_keys if key in env}
if write_runtime_env and runtime_env_path.parent.exists() and runtime_values:
    upsert_env_file(runtime_env_path, runtime_values)
    runtime_env_written = True
else:
    runtime_env_written = False

summary = {
    "updated_config": str(config_path),
    "updated_runtime_env": str(runtime_env_path) if runtime_env_written else None,
    "gateway_token_imported": bool(import_gateway_token and env.get("OPENCLAW_GATEWAY_TOKEN")),
    "gateway_token_policy": "imported_from_env" if import_gateway_token else "preserved_or_generated_fresh",
    "gemini_api_key_runtime_env_requested": bool(env.get("GEMINI_API_KEY")),
    "gemini_api_key_written_to_config": False,
    "default_model_imported": bool(env.get("OPENCLAW_DEFAULT_MODEL")),
    "allowed_origins_imported": bool(origins),
    "control_ui_device_auth_disabled": bool(control.get("dangerouslyDisableDeviceAuth")),
    "runtime_env_keys_imported": sorted(runtime_values) if runtime_env_written else [],
}
print(json.dumps(summary, indent=2, ensure_ascii=False))
PY

if [[ -n "$target_uid" && -n "$target_gid" && "$(id -u)" -eq 0 ]]; then
  chown "$target_uid:$target_gid" "$config_path"
  if [[ -f "$runtime_env_path" ]]; then
    chown "$target_uid:$target_gid" "$runtime_env_path"
  fi
fi
