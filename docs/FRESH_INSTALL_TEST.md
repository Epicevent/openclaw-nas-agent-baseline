# Fresh Install Test

This document reproduces the destructive `oc1` fresh install test.

The test proves this repository can rebuild a new OpenClaw runtime for one
account when NAS and reverse proxy infrastructure already exist.

It does **not** prove that user secrets are preserved.

## What This Test Proves

Proved:

- a fresh clone of this repository can build `openclaw-nas-agent:baseline`
- a new `~/.openclaw` can be seeded from repo defaults
- a new `~/openclaw` runtime checkout can be created by `openclaw-bootstrap`
- the gateway can start from fresh config
- the gateway uses `openclaw-nas-agent:baseline`
- the per-user NAS mount is visible in the container
- document-reading tools exist in the container
- the existing reverse proxy path can return HTTP 200

Not proved:

- preserving old OpenClaw login state
- preserving previous gateway token
- preserving API keys
- preserving auth profiles
- preserving exec approvals
- preserving old user memory or task state

Fresh install means those old values are intentionally not restored.

## Assumptions

The host already has:

- Linux user `oc1`
- Docker access for `oc1`
- NAS mounted at `/home/oc1/nas_docs`
- shared bootstrap at `/usr/local/bin/openclaw-bootstrap`
- reverse proxy already routing `/oc1/` to the oc1 gateway

Expected bootstrap placement:

```text
/opt/openclaw-bootstrap/openclaw-bootstrap.sh
/usr/local/bin/openclaw-bootstrap -> /opt/openclaw-bootstrap/openclaw-bootstrap.sh
```

Expected NAS:

```text
/home/oc1/nas_docs
```

## Current Known Good Commit

The successful test used:

```text
5e6a700 Seed minimal gateway config for fresh OpenClaw
```

This commit matters because the first fresh attempt failed until
`repair-openclaw-state.sh` learned to seed a minimal gateway config.

## Destructive Scope

This test removes or moves:

- `openclaw-oc1-openclaw-gateway-1`
- `/home/oc1/.openclaw`
- `/home/oc1/openclaw`
- `openclaw-nas-agent:baseline`

This test must not remove:

- `/home/oc1/nas_docs`
- NAS mount configuration
- `/etc/fstab`
- CIFS credentials
- reverse proxy configuration
- `/opt/openclaw-bootstrap`

## Step 0: Verify Starting State

Run as `oc1`:

```bash
id
command -v openclaw-bootstrap
ls -ld /home/oc1 /home/oc1/.openclaw /home/oc1/nas_docs /home/oc1/openclaw 2>/dev/null || true
findmnt -T /home/oc1/nas_docs
docker ps -a --filter 'label=com.docker.compose.project=openclaw-oc1' \
  --format '{{.Names}}\t{{.Image}}\t{{.Status}}'
```

## Step 1: Move Existing State Aside

This does not delete the old state. It moves it under a timestamped test folder.

Run as `oc1`:

```bash
set -eu
stamp=$(date +%Y%m%d%H%M%S)
base=/home/oc1/fresh-install-test-$stamp
mkdir -p "$base"
echo "test_base=$base"

docker ps -a --filter 'label=com.docker.compose.project=openclaw-oc1' \
  --format '{{.Names}}' | xargs -r docker rm -f

if [ -d /home/oc1/.openclaw ]; then
  mv /home/oc1/.openclaw "$base/.openclaw.old"
fi

if [ -d /home/oc1/openclaw ]; then
  mv /home/oc1/openclaw "$base/openclaw.old"
fi

if docker image inspect openclaw-nas-agent:baseline >/dev/null 2>&1; then
  docker rmi openclaw-nas-agent:baseline
fi

findmnt -T /home/oc1/nas_docs
```

## Step 2: Fresh Clone Package Repo

Run as `oc1`:

```bash
set -eu
pkg=/home/oc1/openclaw-nas-agent-baseline-fresh
rm -rf "$pkg"
git clone https://github.com/Epicevent/openclaw-nas-agent-baseline.git "$pkg"
cd "$pkg"
git rev-parse --short HEAD
```

Expected head for this recorded run:

```text
5e6a700
```

## Step 3: Build Baseline Image

Run as `oc1` from the fresh repo clone:

```bash
BASE_IMAGE=ghcr.io/openclaw/openclaw:latest \
IMAGE_TAG=openclaw-nas-agent:baseline \
bash scripts/build-container-baseline.sh

docker image inspect openclaw-nas-agent:baseline \
  --format 'baseline_user={{.Config.User}} id={{.Id}} size={{.Size}}'
```

Expected:

```text
baseline_user=node
```

## Step 4: Seed Fresh OpenClaw State

Run as `oc1` from the fresh repo clone:

```bash
OPENCLAW_CONTROL_UI_BASEPATH=/oc1 \
OPENCLAW_PROXY_PUBLIC_ORIGIN=https://ji-tech.co.kr \
OPENCLAW_PROXY_ALLOWED_ORIGINS=https://ji-tech.co.kr,https://www.ji-tech.co.kr \
bash scripts/repair-openclaw-state.sh --home /home/oc1 --no-backup --force-defaults
```

Expected output includes:

```text
seeded: /home/oc1/.openclaw/workspace/AGENTS.md
seeded: /home/oc1/.openclaw/workspace/TOOLS.md
seeded: /home/oc1/.openclaw/workspace/RECOVERY.md
seeded: /home/oc1/.openclaw/openclaw.json
repair complete
```

The repair script creates a fresh gateway token. Do not print that token into
shared logs or chat.

## Step 5: Start OpenClaw Through Shared Bootstrap

Run as `oc1`:

```bash
OPENCLAW_IMAGE=openclaw-nas-agent:baseline \
OPENCLAW_PROXY_PUBLIC_ORIGIN=https://ji-tech.co.kr \
OPENCLAW_PROXY_ALLOWED_ORIGINS=https://ji-tech.co.kr,https://www.ji-tech.co.kr \
openclaw-bootstrap < /dev/null
```

Expected output includes:

```text
OpenClaw clone/start messages
gateway.controlUi.allowedOrigins applied
Container openclaw-oc1-openclaw-gateway-1 Started
```

## Step 6: Verify Container Health

Run as `oc1`:

```bash
for i in $(seq 1 30); do
  status=$(docker inspect openclaw-oc1-openclaw-gateway-1 \
    --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' \
    2>/dev/null || echo missing)
  echo "health_attempt_$i=$status"
  [ "$status" = healthy ] && break
  sleep 2
done

docker ps --filter name=openclaw-oc1-openclaw-gateway-1 \
  --format 'container={{.Names}} image={{.Image}} status={{.Status}} ports={{.Ports}}'

docker inspect openclaw-oc1-openclaw-gateway-1 \
  --format 'config_image={{.Config.Image}} user={{.Config.User}} workdir={{.Config.WorkingDir}}'
```

Expected:

```text
health_attempt_1=healthy
container=openclaw-oc1-openclaw-gateway-1 image=openclaw-nas-agent:baseline status=Up ... (healthy)
config_image=openclaw-nas-agent:baseline user=1006:1006 workdir=/app
```

## Step 7: Verify NAS and Tools Inside Container

Run as `oc1`:

```bash
docker exec openclaw-oc1-openclaw-gateway-1 sh -lc '
  echo id=$(id)
  echo home=$HOME
  ls -ld /home/node/.openclaw /home/node/.openclaw/workspace /home/node/nas_docs
  ls -l /home/node/.openclaw/workspace/AGENTS.md \
        /home/node/.openclaw/workspace/TOOLS.md \
        /home/node/.openclaw/workspace/RECOVERY.md \
        /home/node/.openclaw/workspace/nas_docs
  printf "nas_sample="
  find /home/node/nas_docs -maxdepth 1 -mindepth 1 2>/dev/null | head -3 | wc -l
  for x in openclaw rg jq yq file 7z 7zz libreoffice soffice pandoc pdftotext pdfinfo tesseract ocrmypdf xlsx2csv in2csv ssconvert antiword catdoc clawhub; do
    command -v "$x" >/dev/null || { echo "missing:$x"; exit 1; }
  done
  python3 - <<PY
import pptx, docx, pandas, openpyxl
print("python_modules=ok")
PY
  echo tools=ok
'
```

Expected:

```text
nas_sample=3
python_modules=ok
tools=ok
```

## Step 8: Verify Fresh Config Without Printing Secrets

Run as `oc1`:

```bash
jq '{gateway:{mode:.gateway.mode, auth_mode:.gateway.auth.mode, token_present:(.gateway.auth.token != null), port:.gateway.port, bind:.gateway.bind, controlUi:.gateway.controlUi}, agents:{workspace:.agents.defaults.workspace}}' \
  /home/oc1/.openclaw/openclaw.json
```

Expected:

```json
{
  "gateway": {
    "mode": "local",
    "auth_mode": "token",
    "token_present": true,
    "port": 18789,
    "bind": "lan",
    "controlUi": {
      "basePath": "/oc1",
      "allowedOrigins": [
        "https://ji-tech.co.kr",
        "https://www.ji-tech.co.kr"
      ],
      "allowInsecureAuth": true,
      "dangerouslyDisableDeviceAuth": true
    }
  },
  "agents": {
    "workspace": "/home/node/.openclaw/workspace"
  }
}
```

## Step 9: Verify Local and External Dashboard

Run as `oc1`:

```bash
for url in http://127.0.0.1:28789/ http://127.0.0.1:28789/oc1/; do
  printf '%s ' "$url"
  curl -sS -o /dev/null -w 'code=%{http_code} redirect=%{redirect_url}\n' --max-time 5 "$url" || true
done

for url in https://ji-tech.co.kr/oc1/ https://www.ji-tech.co.kr/oc1/; do
  printf '%s ' "$url"
  curl -k -sS -o /dev/null -w 'code=%{http_code} redirect=%{redirect_url}\n' --max-time 8 "$url" || true
done
```

Expected:

```text
http://127.0.0.1:28789/ code=404 redirect=
http://127.0.0.1:28789/oc1/ code=200 redirect=
https://ji-tech.co.kr/oc1/ code=200 redirect=
https://www.ji-tech.co.kr/oc1/ code=200 redirect=
```

## Step 10: Verify Skills

Run as `oc1`:

```bash
docker exec openclaw-oc1-openclaw-gateway-1 sh -lc 'openclaw skills check | sed -n "1,80p"'
```

Expected summary from the recorded run:

```text
Total: 58
Eligible: 17
Visible to model: 17
Available as command: 16
```

## Recorded Successful Result

Recorded final state:

```text
container=openclaw-oc1-openclaw-gateway-1
image=openclaw-nas-agent:baseline
status=healthy
user=1006:1006
local dashboard=/oc1/ -> 200
external dashboard=https://ji-tech.co.kr/oc1/ -> 200
external dashboard=https://www.ji-tech.co.kr/oc1/ -> 200
```

Backups created during the recorded run:

```text
/home/oc1/fresh-install-test-20260519172101
/home/oc1/fresh-install-test-20260519172717
```

## Known Limitation

This fresh install test intentionally loses prior secrets because it moves the
old `.openclaw` away and does not restore it.

Examples of values not preserved by this test:

- previous gateway token
- Google API key
- auth profiles
- exec approvals
- prior agent model settings
- memory databases
- task run databases

If those must survive reinstall, run a separate secret export/import or snapshot
restore flow. That is a different test from this fresh install test.

For old `.env` based recovery, see [RESTORE_FROM_ENV.md](RESTORE_FROM_ENV.md).
