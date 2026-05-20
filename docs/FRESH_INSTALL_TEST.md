# Empty-State Fresh Install Test

This is the concrete test form of the account-neutral runbook in the repository
README. Set `TARGET_USER` first, then run the commands for that account.

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
| host operation | Create the Linux account, NAS/proxy prerequisites, and shared bootstrap. |
| this repository | Build `openclaw-nas-agent:baseline` from `container/Dockerfile` and provide install-settings/check helpers. |
| `openclaw-bootstrap` | Install/start OpenClaw for the current Linux account from empty state and apply install settings. |

If empty-state installation fails, the fix belongs in `openclaw-bootstrap` or
the host prerequisites, not in a second fresh-install wrapper script.

## Assumptions

Set the target:

```bash
TARGET_USER=oc1  # change this for each account
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
```

The host already has:

- Linux user `$TARGET_USER`
- Docker access for the admin account running the test
- CIFS credentials at `/etc/samba/hanpass.cred`
- shared bootstrap at `/usr/local/bin/openclaw-bootstrap`
- reverse proxy routing `/$TARGET_USER/` to the account gateway
- private install settings at `$TARGET_HOME/.openclaw-install.env`

Before running the destructive test, the shared bootstrap must have the install
env hook. This is a one-time host operation, not part of account reinstall. Do
not rely on a target user's home directory to find this patch helper.

```bash
PATCH_REPO=/opt/openclaw-nas-agent-baseline
if [ ! -f "$PATCH_REPO/scripts/patch-openclaw-bootstrap-install-env.sh" ]; then
  PATCH_REPO="$(mktemp -d)/openclaw-nas-agent-baseline"
  git clone https://github.com/Epicevent/openclaw-nas-agent-baseline.git "$PATCH_REPO"
fi

sudo bash "$PATCH_REPO/scripts/patch-openclaw-bootstrap-install-env.sh"
sudo bash "$PATCH_REPO/scripts/patch-openclaw-bootstrap-install-env.sh" --check
```

Expected:

```text
bootstrap_install_env=ok
bootstrap_customer_mode=ok
```

The install settings file must include Gemini when Gemini is required for the
account:

```bash
GEMINI_API_KEY=...
OPENCLAW_DEFAULT_MODEL=...
OPENCLAW_CONTROL_UI_BASEPATH=/$TARGET_USER
OPENCLAW_PROXY_PUBLIC_ORIGIN=https://ji-tech.co.kr
OPENCLAW_PROXY_ALLOWED_ORIGINS=https://ji-tech.co.kr,https://www.ji-tech.co.kr
```

After the destructive reset, the repo image is rebuilt from the installed
baseline package in `/opt`.

## Destructive Reset

Run as admin.

This intentionally deletes per-user OpenClaw state. It must not delete NAS,
proxy, fstab, CIFS credentials, `$TARGET_HOME/.openclaw-install.env`, or
`/opt/openclaw-bootstrap`.

```bash
set -eu

sudo docker ps -a --filter "label=com.docker.compose.project=openclaw-$TARGET_USER" \
  --format '{{.Names}}' | xargs -r sudo docker rm -f

sudo rm -rf "$TARGET_HOME/openclaw"
sudo rm -rf "$TARGET_HOME/.openclaw"
sudo rm -rf "$TARGET_HOME/.openclaw-auth-profile-secrets"
sudo rm -rf "$TARGET_HOME/.config/openclaw"
sudo rm -rf "$TARGET_HOME/.cache/openclaw"
sudo rm -rf "$TARGET_HOME/openclaw-nas-agent-baseline-fresh"

sudo docker rmi openclaw-nas-agent:baseline 2>/dev/null || true

sudo test -f "$TARGET_HOME/.openclaw-install.env"
sudo test -f /etc/samba/hanpass.cred
```

At this point the account is empty from OpenClaw's point of view.

## Build Baseline Image

Run as admin from the installed baseline package.

```bash
cd /opt/openclaw-nas-agent-baseline

sudo env \
  BASE_IMAGE=ghcr.io/openclaw/openclaw:latest \
  IMAGE_TAG=openclaw-nas-agent:baseline \
  bash scripts/build-container-baseline.sh
```

## Bootstrap Command

Run as admin. The customer account does not need Docker group membership.

```bash
sudo env \
  OPENCLAW_CUSTOMER_MODE=1 \
  OPENCLAW_TARGET_USER="$TARGET_USER" \
  OPENCLAW_IMAGE=openclaw-nas-agent:baseline \
  OPENCLAW_INSTALL_ENV_FILE="$TARGET_HOME/.openclaw-install.env" \
  OPENCLAW_BASELINE_DIR=/opt/openclaw-nas-agent-baseline \
  OPENCLAW_PROXY_PUBLIC_ORIGIN=https://ji-tech.co.kr \
  OPENCLAW_PROXY_ALLOWED_ORIGINS=https://ji-tech.co.kr,https://www.ji-tech.co.kr \
  openclaw-bootstrap < /dev/null
```

That is the contract. No separate `fresh-install-account.sh` should be needed.
Gemini is part of this install contract, not a later restore step.
The Gemini API key must be provided to the Gateway runtime environment, not
stored as a literal `apiKey` in `~/.openclaw/openclaw.json`.

## Success Checks

Run as admin.

```bash
for i in $(seq 1 30); do
  status=$(sudo docker inspect "openclaw-$TARGET_USER-openclaw-gateway-1" \
    --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' \
    2>/dev/null || echo missing)
  echo "health_attempt_$i=$status"
  [ "$status" = healthy ] && break
  sleep 2
done

sudo docker ps --filter "name=openclaw-$TARGET_USER-openclaw-gateway-1" \
  --format 'container={{.Names}} image={{.Image}} status={{.Status}} ports={{.Ports}}'

sudo docker inspect "openclaw-$TARGET_USER-openclaw-gateway-1" \
  --format 'config_image={{.Config.Image}} user={{.Config.User}} workdir={{.Config.WorkingDir}}'

sudo bash /opt/openclaw-nas-agent-baseline/scripts/check-customer-mode-isolation.sh \
  --user "$TARGET_USER"
```

Expected:

```text
container=openclaw-<account>-openclaw-gateway-1
image=openclaw-nas-agent:baseline
status=Up ... (healthy)
```

## Install Settings Check

Run as admin without printing secrets.

```bash
sudo jq '{
  gemini_config_api_key_present: (.plugins.entries.google.config.webSearch.apiKey != null),
  gemini_search_provider: .tools.web.search.provider,
  default_model: .agents.defaults.model.primary,
  gateway_token_present: (.gateway.auth.token != null)
}' "$TARGET_HOME/.openclaw/openclaw.json"

sudo grep -q '^GEMINI_API_KEY=' "$TARGET_HOME/openclaw/.env" && echo gemini_runtime_env_present
```

Expected:

```json
{
  "gemini_config_api_key_present": false,
  "gemini_search_provider": "gemini",
  "gateway_token_present": true
}
```

```text
gemini_runtime_env_present
```

To print the gateway token without exposing API keys:

```bash
sudo python3 - <<PY
import json
cfg=json.load(open("$TARGET_HOME/.openclaw/openclaw.json", encoding="utf-8"))
print(cfg["gateway"]["auth"]["token"])
PY
```

## NAS and Tool Checks

Run as admin.

```bash
sudo docker exec "openclaw-$TARGET_USER-openclaw-gateway-1" sh -lc '
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

Run as admin or from a host shell. The default gateway port is derived from the account
suffix, so `oc1` is `28789`, `oc2` is `28889`, and so on.

```bash
slot="$(printf '%s' "$TARGET_USER" | sed -n 's/^oc\([0-9][0-9]*\)$/\1/p')"
slot="${slot:-1}"
port=$((28789 + (slot - 1) * 100))
base="/$TARGET_USER"

for url in "http://127.0.0.1:${port}${base}/" "https://ji-tech.co.kr${base}/" "https://www.ji-tech.co.kr${base}/"; do
  printf '%s ' "$url"
  curl -k -sS -o /dev/null -w 'code=%{http_code} redirect=%{redirect_url}\n' --max-time 8 "$url" || true
done
```

Expected:

```text
http://127.0.0.1:<port>/<account>/ code=200 redirect=
https://ji-tech.co.kr/<account>/ code=200 redirect=
https://www.ji-tech.co.kr/<account>/ code=200 redirect=
```

## Device Pairing

If the browser asks for a one-time device approval, do not disable device auth.
Approve only the displayed device id:

```bash
sudo bash /opt/openclaw-nas-agent-baseline/scripts/approve-openclaw-device.sh \
  --user "$TARGET_USER" \
  DEVICE_ID_FROM_BROWSER
```

To inspect pending/known devices:

```bash
sudo bash /opt/openclaw-nas-agent-baseline/scripts/approve-openclaw-device.sh \
  --user "$TARGET_USER" \
  --list
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
