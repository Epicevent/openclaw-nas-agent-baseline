# OpenClaw Recovery Model

The goal is not to make OpenClaw settings impossible to change. The goal is to
make a damaged account repairable with a known procedure.

## What is fixed by the image

The container image should carry tools and runtimes:

- OpenClaw runtime base
- apt packages for document reading
- Python and Node dependencies
- `clawhub`
- command aliases such as `7z`

If the container is recreated from the same image, these should come back.

## What is fixed by per-user state repair

OpenClaw state is mounted outside the image, normally like this:

```text
/home/ocN/.openclaw        -> container /home/node/.openclaw
/home/ocN/nas_docs         -> container /home/node/nas_docs
```

That state can drift or break. The repair scripts handle the recoverable layer:

- `~/.openclaw/openclaw.json`
- `~/.openclaw/exec-approvals.json`
- `~/.openclaw/agents`
- `~/.openclaw/plugin-skills`
- `~/.openclaw/workspace/AGENTS.md`
- `~/.openclaw/workspace/TOOLS.md`
- `~/.openclaw/workspace/RECOVERY.md`
- `~/.openclaw/workspace/.clawhub`
- `~/.openclaw/workspace/.openclaw`
- `~/.openclaw/workspace/skills`
- workspace symlinks to `~/nas_docs`

The scripts intentionally do not back up or restore NAS content.

## What is left outside the public repo

Keep these out of GitHub:

- NAS credentials
- API keys and tokens
- SSH keys
- user memory databases
- task run databases
- device identity files
- logs

Those may be backed up by an operator through another private mechanism, but
they do not belong in this public baseline.

## Commands

Create a per-user snapshot:

```bash
cd /opt/openclaw-nas-agent-baseline
sudo bash scripts/recovery/backup-openclaw-state.sh --user oc1
```

Repair with repo defaults:

```bash
sudo bash scripts/recovery/repair-openclaw-state.sh --user oc1
```

When explicitly used for recovery on an empty account, the repair script also
creates a minimal `~/.openclaw/openclaw.json` with:

- `gateway.mode=local`
- generated per-user gateway token
- control UI base path
- optional allowed origins from `OPENCLAW_PROXY_PUBLIC_ORIGIN` or
  `OPENCLAW_PROXY_ALLOWED_ORIGINS`
- heartbeat disabled with `agents.defaults.heartbeat.every=0m`

This is not part of the production image fast install path. Fresh install
initializes only the minimal runtime config it needs and does not run workspace
recovery, default workspace seeding, or snapshot restore.

Repair and overwrite default workspace files:

```bash
sudo bash scripts/recovery/repair-openclaw-state.sh --user oc1 --force-defaults
```

Restore from a snapshot:

```bash
sudo bash scripts/recovery/repair-openclaw-state.sh --user oc1 \
  --snapshot /home/oc1/.openclaw-recovery/snapshots/openclaw-state-oc1-YYYYMMDDHHMMSS.tar.gz
```

Use only trusted snapshots. Do not restore a customer-supplied tarball as-is.
Before restore, inspect the archive for absolute paths, `..`, symlinks,
hardlinks, and special files.

```bash
tar -tzvf "$SNAPSHOT" \
  | awk '$1 ~ /^l|^h|^c|^b|^p/ || $6 ~ /^\// || $6 ~ /(^|\/)\.\.($|\/)/ { print }'
```

The command above should print nothing for a normal trusted recovery archive.

Run for many accounts:

```bash
cd /opt/openclaw-nas-agent-baseline
for i in $(seq 1 20); do
  sudo bash scripts/recovery/repair-openclaw-state.sh --user "oc$i"
done
```

## Operator check

After repair:

```bash
sudo -u oc1 test -L /home/oc1/.openclaw/workspace/nas_docs
sudo -u oc1 ls -ld /home/oc1/.openclaw /home/oc1/.openclaw/workspace
sudo -u oc1 ls /home/oc1/nas_docs >/dev/null
```

Inside the container:

```bash
docker exec openclaw-oc1-openclaw-gateway-1 sh -lc '
  id
  ls -ld /home/node/.openclaw /home/node/nas_docs
  cd /home/node/.openclaw/workspace/openclaw-nas-agent-baseline
  bash scripts/check-baseline.sh
'
```
