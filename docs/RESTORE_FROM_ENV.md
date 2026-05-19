# Restore From Old `.env`

Use this when a fresh install must recover values from an older OpenClaw `.env`
file, such as `OPENCLAW_GATEWAY_TOKEN` or `GEMINI_API_KEY`.

This is different from snapshot restore:

- snapshot restore brings back a whole previous `.openclaw` state
- env restore imports selected values into the new fresh state

## Supported Inputs

The importer currently understands these important values:

- `OPENCLAW_GATEWAY_TOKEN`
- `GEMINI_API_KEY`
- `OPENCLAW_DEFAULT_MODEL`
- `OPENCLAW_SANDBOX`
- `OPENCLAW_GATEWAY_BIND`
- `OPENCLAW_CONTROL_UI_BASEPATH`
- `OPENCLAW_PROXY_PUBLIC_ORIGIN`
- `OPENCLAW_PROXY_ALLOWED_ORIGINS`

It can also update the runtime `~/openclaw/.env` with safe whitelisted
OpenClaw/OTel/bootstrap variables from the old env file.

The script does not print secret values.

## Where To Put The Old Env

Put the old env file somewhere private on the target account:

```bash
mkdir -p /home/oc1/.openclaw-recovery/import
chmod 700 /home/oc1/.openclaw-recovery /home/oc1/.openclaw-recovery/import

# copy .env.oc1 here by scp, sftp, or another secure channel
chmod 600 /home/oc1/.openclaw-recovery/import/.env.oc1
```

Do not commit this file to GitHub.

## Import After Fresh Install

Run after:

1. `repair-openclaw-state.sh`
2. `openclaw-bootstrap`

Example:

```bash
cd /home/oc1/openclaw-nas-agent-baseline-fresh

bash scripts/import-openclaw-env.sh \
  --home /home/oc1 \
  --env-file /home/oc1/.openclaw-recovery/import/.env.oc1
```

Then restart the gateway:

```bash
docker restart openclaw-oc1-openclaw-gateway-1
```

## Verify Without Printing Secrets

```bash
jq '{
  gateway: {
    auth_mode: .gateway.auth.mode,
    token_present: (.gateway.auth.token != null),
    controlUi: .gateway.controlUi
  },
  gemini_api_key_present: (.plugins.entries.google.config.webSearch.apiKey != null),
  default_model: .agents.defaults.model.primary
}' /home/oc1/.openclaw/openclaw.json
```

Expected:

```json
{
  "gateway": {
    "auth_mode": "token",
    "token_present": true
  },
  "gemini_api_key_present": true
}
```

## Fresh Install Sequence With Env Restore

The high-level flow becomes:

```bash
# 1. build baseline image
BASE_IMAGE=ghcr.io/openclaw/openclaw:latest \
IMAGE_TAG=openclaw-nas-agent:baseline \
bash scripts/build-container-baseline.sh

# 2. create fresh .openclaw defaults
OPENCLAW_CONTROL_UI_BASEPATH=/oc1 \
OPENCLAW_PROXY_PUBLIC_ORIGIN=https://ji-tech.co.kr \
OPENCLAW_PROXY_ALLOWED_ORIGINS=https://ji-tech.co.kr,https://www.ji-tech.co.kr \
bash scripts/repair-openclaw-state.sh --home /home/oc1 --no-backup --force-defaults

# 3. start gateway
OPENCLAW_IMAGE=openclaw-nas-agent:baseline \
OPENCLAW_PROXY_PUBLIC_ORIGIN=https://ji-tech.co.kr \
OPENCLAW_PROXY_ALLOWED_ORIGINS=https://ji-tech.co.kr,https://www.ji-tech.co.kr \
openclaw-bootstrap < /dev/null

# 4. import old secrets/config values
bash scripts/import-openclaw-env.sh \
  --home /home/oc1 \
  --env-file /home/oc1/.openclaw-recovery/import/.env.oc1

# 5. restart to apply imported token/config
docker restart openclaw-oc1-openclaw-gateway-1
```
