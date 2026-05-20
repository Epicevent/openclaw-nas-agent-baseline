# Bootstrap Compatibility

This repository must not replace `openclaw-bootstrap.sh`.

The two layers have different jobs.

## Role split

| Layer | Owner | Job |
| --- | --- | --- |
| `openclaw-bootstrap.sh` | host/account bootstrap | Create or start one OpenClaw Docker instance per Linux user from empty state. |
| this repository | runtime baseline package | Build a compatible OpenClaw image with document-reading tools and provide install-settings/check helpers. |
| `/home/ocN/.openclaw` | per-user state | Keep OpenClaw config, auth state, workspace, and account-specific settings. |
| `/home/ocN/nas_docs` | host NAS mount | Keep the per-user NAS mount outside the container. |
| `/home/ocN/.openclaw-install.env` | private install input | Provide required account settings such as `GEMINI_API_KEY`. |

## Standard bootstrap placement

The shared bootstrap script should live outside any one user's home directory:

```text
/opt/openclaw-bootstrap/openclaw-bootstrap.sh
/usr/local/bin/openclaw-bootstrap -> /opt/openclaw-bootstrap/openclaw-bootstrap.sh
```

That placement keeps the bootstrap account-neutral. The script still acts on the
account that executes it because it derives defaults from `$HOME` and `$USER`.

For example:

```text
oc1 runs openclaw-bootstrap  -> /home/oc1/openclaw, /home/oc1/.openclaw
oc20 runs openclaw-bootstrap -> /home/oc20/openclaw, /home/oc20/.openclaw
```

## What the bootstrap owns

The existing bootstrap owns:

- Docker and Docker Compose availability
- `OPENCLAW_INSTANCE`
- `COMPOSE_PROJECT_NAME`
- account ports
- control UI base path
- host UID/GID mapping
- bind mounts for `.openclaw`
- bind mounts for `nas_docs`
- gateway start/recreate
- applying install settings during the install, when an install env file is
  provided

This repository should not duplicate that logic.

## What this repository owns

This repository owns:

- `container/Dockerfile`
- `container/install-container-baseline.sh`
- `scripts/build-container-baseline.sh`
- `scripts/check-baseline.sh`
- `scripts/apply-openclaw-install-env.sh`
- `install.sh`
- the tar.gz install package workflow

It does not own NAS credentials, OpenClaw gateway tokens, or per-user login
state. It does provide the code that writes required install settings, such as
Gemini, into a newly created OpenClaw config when bootstrap calls it.

## Compatibility point

Compatibility has two points:

1. the image name
2. the install settings helper

The bootstrap already supports:

```bash
OPENCLAW_IMAGE=<image> openclaw-bootstrap
```

So the image-compatible path is:

```bash
cd /opt/openclaw-nas-agent-baseline

BASE_IMAGE=ghcr.io/openclaw/openclaw:latest \
IMAGE_TAG=openclaw-nas-agent:baseline \
bash scripts/build-container-baseline.sh

OPENCLAW_IMAGE=openclaw-nas-agent:baseline \
openclaw-bootstrap
```

For accounts that require Gemini, bootstrap must also consume the private
install env file and call the repo helper during the same install:

```bash
OPENCLAW_IMAGE=openclaw-nas-agent:baseline \
OPENCLAW_INSTALL_ENV_FILE="$HOME/.openclaw-install.env" \
openclaw-bootstrap
```

That is still one bootstrap install. It is not a post-install restore.

For another account:

```bash
sudo su - oc20

OPENCLAW_IMAGE=openclaw-nas-agent:baseline \
openclaw-bootstrap
```

## Required image contract

The baseline image must be built from the same OpenClaw image family that the
bootstrap expects.

Do keep:

- OpenClaw entrypoints and commands
- `/usr/local/bin/openclaw`
- the expected container home path, currently `/home/node`
- the ability to run with `user: "<host_uid>:<host_gid>"`
- the same exposed gateway behavior

Do not bake into the image:

- NAS credentials
- API keys
- OpenClaw auth tokens
- `/home/ocN/.openclaw`
- NAS documents

Do provide API keys through the private install env file. They are runtime
settings, not image content and not `openclaw.json` content.

## What changing the image does

Changing `OPENCLAW_IMAGE` swaps the tool/runtime layer.

It should not change:

- `/home/ocN/.openclaw`
- `/home/ocN/nas_docs`
- account UID/GID
- ports
- OpenClaw account state

Those are provided by the bootstrap and host bind mounts.

## Important note

The observed `openclaw-bootstrap.sh` accepts `OPENCLAW_IMAGE` from the shell
environment. It does not appear to persist that value into `.env` by itself.
It also does not currently pass `GEMINI_API_KEY` from the install env contract
into the Gateway runtime as part of first install.

Therefore either:

- pass `OPENCLAW_IMAGE=openclaw-nas-agent:baseline` every time the bootstrap is
  used to recreate/start with the baseline image, or
- patch the bootstrap separately to persist `OPENCLAW_IMAGE`.
- patch the bootstrap to call `scripts/apply-openclaw-install-env.sh` when
  `OPENCLAW_INSTALL_ENV_FILE` is set. The helper writes non-secret config and
  runtime env only; it must not store the API key in `openclaw.json`.

Those patches belong to the bootstrap layer, not to a second fresh-install
wrapper.

This repository includes the compatibility patch helper:

```bash
PATCH_REPO=/opt/openclaw-nas-agent-baseline
if [ ! -f "$PATCH_REPO/scripts/patch-openclaw-bootstrap-install-env.sh" ]; then
  PATCH_REPO="$(mktemp -d)/openclaw-nas-agent-baseline"
  git clone https://github.com/Epicevent/openclaw-nas-agent-baseline.git "$PATCH_REPO"
fi

sudo bash "$PATCH_REPO/scripts/patch-openclaw-bootstrap-install-env.sh"
```

After that, the expected check is:

```bash
sudo bash "$PATCH_REPO/scripts/patch-openclaw-bootstrap-install-env.sh" --check
```

Expected:

```text
bootstrap_install_env=ok
```
