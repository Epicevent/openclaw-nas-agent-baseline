# Install Package

This project can be shipped as a simple `tar.gz` package.

The package installs the baseline repo on the host, usually under:

```text
/opt/openclaw-nas-agent-baseline
```

That path gives `openclaw-bootstrap` a stable place to find:

- `container/Dockerfile`
- `scripts/build-container-baseline.sh`
- `scripts/apply-openclaw-install-env.sh`
- check scripts and docs

## Build

From the repository root:

```bash
bash scripts/build-install-package.sh
```

The output is written to `dist/`, for example:

```text
dist/openclaw-nas-agent-baseline-20260519-9b1d4ff.tar.gz
```

## Install On Host

On the target host:

```bash
tar -xzf openclaw-nas-agent-baseline-*.tar.gz
cd openclaw-nas-agent-baseline-*
sudo bash install.sh
```

## What The Package Contains

- baseline container build files
- install-settings materializer
- customer-mode bootstrap patch helper
- verification scripts
- docs and examples

## What The Package Does Not Contain

- NAS credentials
- OpenClaw gateway tokens
- API keys
- SSH keys
- user memory databases
- NAS documents

Secrets and per-account settings stay outside Git, for example:

```text
/home/ocN/.openclaw-install.env
/home/ocN/.openclaw
/home/ocN/nas_docs
```

## Fresh Install Relationship

The operator-facing install command remains bootstrap:

```bash
sudo env \
  OPENCLAW_CUSTOMER_MODE=1 \
  OPENCLAW_TARGET_USER=ocN \
  OPENCLAW_IMAGE=openclaw-nas-agent:baseline \
  OPENCLAW_INSTALL_ENV_FILE=/home/ocN/.openclaw-install.env \
  OPENCLAW_BASELINE_DIR=/opt/openclaw-nas-agent-baseline \
  openclaw-bootstrap < /dev/null
```

The package is successful when bootstrap can use this repo's image and install
settings helper during that one install flow, without adding the customer
account to the Docker group.
