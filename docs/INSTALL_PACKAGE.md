# Install Package

This project can be shipped as a simple `tar.gz` install package.

It is intentionally not a `.deb` package yet. The first goal is simpler:

- download or copy one archive
- extract it
- run `install.sh`
- get the same operator scripts, container baseline, and OpenClaw repair tools

## Build

From the repository root:

```bash
bash scripts/build-install-package.sh
```

The output is written to `dist/`, for example:

```text
dist/openclaw-nas-agent-baseline-20260519-9b1d4ff.tar.gz
```

## Install

On the target host:

```bash
tar -xzf openclaw-nas-agent-baseline-*.tar.gz
cd openclaw-nas-agent-baseline-*
sudo bash install.sh
```

Default install path:

```text
/opt/openclaw-nas-agent-baseline
```

Install and repair one account:

```bash
sudo bash install.sh --repair-user oc1 --check
```

Install and seed many accounts:

```bash
sudo bash install.sh --repair-users oc1,oc2,oc3
```

Force the default workspace files to be replaced:

```bash
sudo bash install.sh --repair-user oc1 --force-defaults
```

## What the package contains

- host install scripts
- container build scripts
- OpenClaw workspace defaults
- OpenClaw backup and repair scripts
- docs and examples

## What the package does not contain

- NAS credentials
- OpenClaw login tokens
- API keys
- SSH keys
- user memory databases
- NAS documents

Those stay on the host in each user account, especially under:

```text
/home/ocN/.openclaw
/home/ocN/nas_docs
```

## Mental model

The package makes a host repairable. It does not freeze every user state.

```text
install package -> /opt/openclaw-nas-agent-baseline
container image -> repeatable tool/runtime layer
/home/ocN/.openclaw -> account settings and tokens
/home/ocN/nas_docs -> account NAS mount
```
