# OpenClaw NAS Agent Baseline

This repository is the runtime baseline package for per-account OpenClaw
containers.

It is not the host bootstrap. The shared `openclaw-bootstrap` script remains
the single install/start entrypoint for each Linux account.

## Contract

For a prepared target account, an empty-state install should be:

```bash
OPENCLAW_IMAGE=openclaw-nas-agent:baseline \
OPENCLAW_INSTALL_ENV_FILE="$HOME/.openclaw-install.env" \
openclaw-bootstrap
```

The account is considered installed only when:

- the gateway container is healthy
- the container uses `openclaw-nas-agent:baseline`
- `/home/node/nas_docs` is visible inside the container
- the document-reading tools from this repo are present
- required install settings such as Gemini are already applied

Gemini settings are install input, not a later restore step.

## Role Split

| Layer | Job |
| --- | --- |
| host operation | Linux users, Docker access, CIFS/NAS mounts, reverse proxy, shared bootstrap placement. |
| `openclaw-bootstrap` | Create/start one OpenClaw instance for the current Linux account from empty state. |
| this repository | Build the baseline image and provide install-settings/check helpers. |
| per-account private env | Store secrets such as `GEMINI_API_KEY`; never commit them. |

## Build The Baseline Image

```bash
BASE_IMAGE=ghcr.io/openclaw/openclaw:latest \
IMAGE_TAG=openclaw-nas-agent:baseline \
bash scripts/build-container-baseline.sh
```

## Install Settings

Per-account install settings live outside Git:

```bash
$HOME/.openclaw-install.env
```

Example keys:

```bash
GEMINI_API_KEY=...
OPENCLAW_DEFAULT_MODEL=...
OPENCLAW_CONTROL_UI_BASEPATH=/$(id -un)
OPENCLAW_PROXY_PUBLIC_ORIGIN=https://ji-tech.co.kr
OPENCLAW_PROXY_ALLOWED_ORIGINS=https://ji-tech.co.kr,https://www.ji-tech.co.kr
```

The helper that materializes those settings is:

```bash
bash scripts/apply-openclaw-install-env.sh \
  --home "$HOME" \
  --env-file "$HOME/.openclaw-install.env"
```

This helper is intended to be called by `openclaw-bootstrap` during install.
Operators should not have to run a separate recovery sequence after install.

If the shared bootstrap does not yet support `OPENCLAW_INSTALL_ENV_FILE`, patch
that bootstrap once from an admin checkout or temporary clone:

```bash
PATCH_REPO=/opt/openclaw-nas-agent-baseline
if [ ! -f "$PATCH_REPO/scripts/patch-openclaw-bootstrap-install-env.sh" ]; then
  PATCH_REPO="$(mktemp -d)/openclaw-nas-agent-baseline"
  git clone https://github.com/Epicevent/openclaw-nas-agent-baseline.git "$PATCH_REPO"
fi

sudo bash "$PATCH_REPO/scripts/patch-openclaw-bootstrap-install-env.sh"
sudo bash "$PATCH_REPO/scripts/patch-openclaw-bootstrap-install-env.sh" --check
```

## Documents

- [Bootstrap compatibility](docs/BOOTSTRAP_COMPATIBILITY.md)
- [Per-account fresh install runbook](docs/PER_ACCOUNT_FRESH_INSTALL_RUNBOOK.md)
- [Empty-state fresh install test](docs/FRESH_INSTALL_TEST.md)
- [Install settings](docs/INSTALL_SETTINGS.md)
- [Container baseline](docs/CONTAINER_BASELINE.md)
- [Install package](docs/INSTALL_PACKAGE.md)
- [Remount guide](docs/REMOUNT_GUIDE.md)
