# Empty-State Fresh Install Test

This test proves the real package contract:

```text
If a Linux account has no ~/openclaw and no ~/.openclaw,
the shared openclaw-bootstrap command must create a working OpenClaw instance
using the baseline image built from this repository, with required install
settings such as Gemini already applied.
```

This is not a restore test. It does not keep old state alive, move it aside, or
replay a manual recovery sequence.

## Role Split

| Layer | Job |
| --- | --- |
| host operation | Create the Linux account, Docker access, NAS mount, proxy route, and shared bootstrap. |
| this repository | Build `openclaw-nas-agent:baseline` from `container/Dockerfile` and provide install-settings/check helpers. |
| `openclaw-bootstrap` | Install/start OpenClaw for the current Linux account from empty state and apply install settings. |

If empty-state installation fails, the fix belongs in `openclaw-bootstrap` or
the host prerequisites, not in a second fresh-install wrapper script.

## Assumptions

The host already has:

- Linux user `oc1`
- Docker access for `oc1`
- NAS mounted at `/home/oc1/nas_docs`
- shared bootstrap at `/usr/local/bin/openclaw-bootstrap`
- reverse proxy routing `/oc1/` to the oc1 gateway
- private install settings at `/home/oc1/.openclaw-install.env`

Before running the destructive test, the shared bootstrap must have the install
env hook. This is a one-time host operation, not part of account reinstall:

```bash
cd /home/oc1/openclaw-nas-agent-baseline-fresh
sudo bash scripts/patch-openclaw-bootstrap-install-env.sh
sudo bash scripts/patch-openclaw-bootstrap-install-env.sh --check
```

Expected:

```text
bootstrap_install_env=ok
```

The install settings file must include Gemini when Gemini is required for the
account:

```bash
GEMINI_API_KEY=...
OPENCLAW_DEFAULT_MODEL=...
OPENCLAW_CONTROL_UI_BASEPATH=/oc1
OPENCLAW_PROXY_PUBLIC_ORIGIN=https://ji-tech.co.kr
OPENCLAW_PROXY_ALLOWED_ORIGINS=https://ji-tech.co.kr,https://www.ji-tech.co.kr
```

After the destructive reset, the repo image is rebuilt from GitHub in the
`Build From GitHub` step below.

## Destructive Reset

Run as `oc1`.

This intentionally deletes per-user OpenClaw state. It must not delete NAS,
proxy, fstab, CIFS credentials, `/home/oc1/.openclaw-install.env`, or
`/opt/openclaw-bootstrap`.

```bash
set -eu

cd /home/oc1

docker ps -a --filter 'label=com.docker.compose.project=openclaw-oc1' \
  --format '{{.Names}}' | xargs -r docker rm -f

rm -rf "$HOME/openclaw"
rm -rf "$HOME/.openclaw"
rm -rf "$HOME/.openclaw-auth-profile-secrets"
rm -rf "$HOME/.config/openclaw"
rm -rf "$HOME/.cache/openclaw"

docker rmi openclaw-nas-agent:baseline 2>/dev/null || true
rm -rf "$HOME/openclaw-nas-agent-baseline-fresh"

test -f "$HOME/.openclaw-install.env"
findmnt -T "$HOME/nas_docs"
```

At this point the account is empty from OpenClaw's point of view.

## Build From GitHub

Run as `oc1`.

```bash
git clone https://github.com/Epicevent/openclaw-nas-agent-baseline.git \
  "$HOME/openclaw-nas-agent-baseline-fresh"

cd "$HOME/openclaw-nas-agent-baseline-fresh"

BASE_IMAGE=ghcr.io/openclaw/openclaw:latest \
IMAGE_TAG=openclaw-nas-agent:baseline \
bash scripts/build-container-baseline.sh
```

## Bootstrap Command

Run as `oc1`.

```bash
OPENCLAW_IMAGE=openclaw-nas-agent:baseline \
OPENCLAW_INSTALL_ENV_FILE="$HOME/.openclaw-install.env" \
OPENCLAW_BASELINE_DIR="$HOME/openclaw-nas-agent-baseline-fresh" \
OPENCLAW_PROXY_PUBLIC_ORIGIN=https://ji-tech.co.kr \
OPENCLAW_PROXY_ALLOWED_ORIGINS=https://ji-tech.co.kr,https://www.ji-tech.co.kr \
openclaw-bootstrap < /dev/null
```

That is the contract. No separate `fresh-install-account.sh` should be needed.
Gemini is part of this install contract, not a later restore step.

## Success Checks

Run as `oc1`.

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
container=openclaw-oc1-openclaw-gateway-1
image=openclaw-nas-agent:baseline
status=Up ... (healthy)
```

## Install Settings Check

Run as `oc1`.

```bash
jq '{
  gemini_api_key_present: (.plugins.entries.google.config.webSearch.apiKey != null),
  default_model: .agents.defaults.model.primary,
  gateway_token_present: (.gateway.auth.token != null)
}' /home/oc1/.openclaw/openclaw.json
```

Expected:

```json
{
  "gemini_api_key_present": true,
  "gateway_token_present": true
}
```

To print the gateway token without exposing API keys:

```bash
python3 - <<'PY'
import json, os
cfg=json.load(open(os.path.expanduser("~/.openclaw/openclaw.json"), encoding="utf-8"))
print(cfg["gateway"]["auth"]["token"])
PY
```

## NAS and Tool Checks

Run as `oc1`.

```bash
docker exec openclaw-oc1-openclaw-gateway-1 sh -lc '
  echo id=$(id)
  ls -ld /home/node/.openclaw /home/node/.openclaw/workspace /home/node/nas_docs
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
nas_sample=1
python_modules=ok
tools=ok
```

`nas_sample` may be greater than `1`; the important point is that it is not `0`
when the NAS contains files.

## Dashboard Checks

Run as `oc1`.

```bash
for url in http://127.0.0.1:28789/oc1/ https://ji-tech.co.kr/oc1/ https://www.ji-tech.co.kr/oc1/; do
  printf '%s ' "$url"
  curl -k -sS -o /dev/null -w 'code=%{http_code} redirect=%{redirect_url}\n' --max-time 8 "$url" || true
done
```

Expected:

```text
http://127.0.0.1:28789/oc1/ code=200 redirect=
https://ji-tech.co.kr/oc1/ code=200 redirect=
https://www.ji-tech.co.kr/oc1/ code=200 redirect=
```

## Device Pairing

If the browser asks for a one-time device approval, do not disable device auth.
Approve only the displayed device id:

```bash
cd "$HOME/openclaw-nas-agent-baseline-fresh"
bash scripts/approve-openclaw-device.sh DEVICE_ID_FROM_BROWSER
```

To inspect pending/known devices:

```bash
bash scripts/approve-openclaw-device.sh --list
```

## What This Test Does Not Preserve

Because the state directories are deleted, these old values are intentionally
not preserved:

- previous gateway token
- auth profiles
- exec approvals
- prior model settings
- memory databases
- task run databases

Gemini/API-key settings are not in that list when an install env file is part
of the account contract. They must be applied during bootstrap. See
[INSTALL_SETTINGS.md](INSTALL_SETTINGS.md).
