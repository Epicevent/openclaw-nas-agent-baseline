# Bootstrap Compatibility

This repository must not replace `openclaw-bootstrap.sh`.

The two layers have different jobs.

## Role split

| Layer | Owner | Job |
| --- | --- | --- |
| `openclaw-bootstrap.sh` | host/account bootstrap | Create or start one OpenClaw Docker instance per Linux user. |
| this repository | runtime baseline package | Build a compatible OpenClaw image with document-reading tools and provide repair/check scripts. |
| `/home/ocN/.openclaw` | per-user state | Keep OpenClaw config, auth state, workspace, and account-specific settings. |
| `/home/ocN/nas_docs` | host NAS mount | Keep the per-user NAS mount outside the container. |

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

This repository should not duplicate that logic.

## What this repository owns

This repository owns:

- `container/Dockerfile`
- `container/install-container-baseline.sh`
- `scripts/build-container-baseline.sh`
- `scripts/check-baseline.sh`
- `scripts/backup-openclaw-state.sh`
- `scripts/repair-openclaw-state.sh`
- `install.sh`
- the tar.gz install package workflow

It does not own NAS credentials, OpenClaw tokens, or per-user login state.

## Compatibility point

Compatibility is the image name.

The bootstrap already supports:

```bash
OPENCLAW_IMAGE=<image> openclaw-bootstrap
```

So the compatible path is:

```bash
cd /opt/openclaw-nas-agent-baseline

BASE_IMAGE=ghcr.io/openclaw/openclaw:latest \
IMAGE_TAG=openclaw-nas-agent:baseline \
bash scripts/build-container-baseline.sh

OPENCLAW_IMAGE=openclaw-nas-agent:baseline \
openclaw-bootstrap
```

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

Therefore either:

- pass `OPENCLAW_IMAGE=openclaw-nas-agent:baseline` every time the bootstrap is
  used to recreate/start with the baseline image, or
- patch the bootstrap separately to persist `OPENCLAW_IMAGE`.

That patch belongs to the bootstrap layer, not this runtime baseline repo.
