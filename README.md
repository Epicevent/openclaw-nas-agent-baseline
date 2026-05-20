# OpenClaw NAS Agent Baseline

Start here.

This repo builds the OpenClaw runtime image and provides the host-side helpers
needed to run one isolated OpenClaw instance per Linux customer account.

The default target is **customer mode**:

```text
Customer account ocN:
  can SSH in
  can read /home/ocN/nas_docs
  cannot use Docker
  cannot read runtime env/API keys
  cannot read OpenClaw raw config

Runtime account ocN_rt:
  is not a human login account
  runs the OpenClaw gateway container
  reads API keys from runtime env
  reads NAS through ocN_data group
```

Do not hand an account to a customer until the customer-mode check passes.

## Host Setup

Run once as a sudo-capable admin account:

```bash
TMP_REPO="$(mktemp -d)/openclaw-nas-agent-baseline"
git clone https://github.com/Epicevent/openclaw-nas-agent-baseline.git "$TMP_REPO"
cd "$TMP_REPO"

sudo bash install.sh
```

Patch the shared bootstrap:

```bash
PATCH_REPO=/opt/openclaw-nas-agent-baseline

sudo bash "$PATCH_REPO/scripts/patch-openclaw-bootstrap-install-env.sh"
sudo bash "$PATCH_REPO/scripts/patch-openclaw-bootstrap-install-env.sh" --check
```

Expected:

```text
bootstrap_install_env=ok
bootstrap_customer_mode=ok
```

## Prepare One Account

Run as admin. Change only `TARGET_USER`.

```bash
TARGET_USER=oc1
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"

if ! id "$TARGET_USER" >/dev/null 2>&1; then
  sudo useradd -m -s /bin/bash "$TARGET_USER"
  sudo passwd "$TARGET_USER"
  TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
fi

getent group openclaw-installers >/dev/null || sudo groupadd openclaw-installers

sudo usermod -aG openclaw-installers "$TARGET_USER"

id "$TARGET_USER"
echo "home=$TARGET_HOME"
```

Do not give the customer this account yet.

## Create Install Env

This file is install input. It is locked down by the customer-mode isolation
bootstrap path and is not readable by the customer account.

```bash
sudo install -o root -g root -m 600 /dev/null "$TARGET_HOME/.openclaw-install.env"

read -rsp "GEMINI_API_KEY for $TARGET_USER: " GEMINI_API_KEY
printf '\n'

sudo tee "$TARGET_HOME/.openclaw-install.env" >/dev/null <<EOF
GEMINI_API_KEY=$GEMINI_API_KEY
OPENCLAW_DEFAULT_MODEL=google/gemini-3.1-pro-preview
OPENCLAW_CONTROL_UI_BASEPATH=/$TARGET_USER
OPENCLAW_CONTROL_UI_DISABLE_DEVICE_AUTH=1
OPENCLAW_PROXY_PUBLIC_ORIGIN=https://ji-tech.co.kr
OPENCLAW_PROXY_ALLOWED_ORIGINS=https://ji-tech.co.kr,https://www.ji-tech.co.kr
OPENCLAW_GATEWAY_BIND=lan
EOF

sudo chown root:root "$TARGET_HOME/.openclaw-install.env"
sudo chmod 600 "$TARGET_HOME/.openclaw-install.env"
unset GEMINI_API_KEY
```

Verify without printing secrets:

```bash
sudo grep -q '^GEMINI_API_KEY=' "$TARGET_HOME/.openclaw-install.env" && echo gemini_key_present
sudo grep -q "^OPENCLAW_CONTROL_UI_BASEPATH=/$TARGET_USER$" "$TARGET_HOME/.openclaw-install.env" && echo basepath_ok
```

## NAS Prerequisites

Direct customer-mode bootstrap remounts the account NAS path with the final
customer/runtime shared permissions.

```bash
sudo mkdir -p "$TARGET_HOME/nas_docs"
sudo chown "$TARGET_USER:$TARGET_USER" "$TARGET_HOME/nas_docs"
sudo test -f /etc/samba/hanpass.cred && echo cifs_cred_ok
```

For a non-default share or credentials file, pass these to bootstrap:

```bash
OPENCLAW_CUSTOMER_SHARE=//server/share
OPENCLAW_CUSTOMER_CREDENTIALS=/path/to/cifs.cred
```

## Bootstrap In Customer Mode

Run as admin. The customer account does not need Docker group membership.

Build the baseline image:

```bash
cd /opt/openclaw-nas-agent-baseline

sudo env \
  BASE_IMAGE=ghcr.io/openclaw/openclaw:latest \
  IMAGE_TAG=openclaw-nas-agent:baseline \
  bash scripts/build-container-baseline.sh
```

For a reinstall test, remove previous OpenClaw state but keep env and NAS:

```bash
sudo docker ps -a --filter "label=com.docker.compose.project=openclaw-$TARGET_USER" \
  --format '{{.Names}}' | xargs -r sudo docker rm -f

sudo rm -rf "$TARGET_HOME/openclaw"
sudo rm -rf "$TARGET_HOME/.openclaw"
sudo rm -rf "$TARGET_HOME/.openclaw-auth-profile-secrets"
sudo rm -rf "$TARGET_HOME/.config/openclaw"
sudo rm -rf "$TARGET_HOME/.cache/openclaw"
sudo rm -rf "$TARGET_HOME/openclaw-nas-agent-baseline-fresh"

sudo docker rmi openclaw-nas-agent:baseline 2>/dev/null || true
```

Run bootstrap:

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

## Verify Customer Mode

Run as admin before giving the account to a customer:

```bash
sudo bash /opt/openclaw-nas-agent-baseline/scripts/check-customer-mode-isolation.sh \
  --user "$TARGET_USER"
```

If converting an older staging install, use the migration helper:

```bash
sudo bash /opt/openclaw-nas-agent-baseline/scripts/apply-customer-mode-isolation.sh \
  --user "$TARGET_USER" \
  --check
```

Expected pass lines:

```text
PASS customer_not_in_docker_group
PASS customer_nas_read_ok
PASS runtime_env_exists
PASS config_exists
PASS customer_runtime_env_blocked
PASS customer_config_blocked
PASS config_has_no_literal_api_key
PASS control_ui_device_auth_disabled
PASS customer_docker_blocked
PASS customer_proc_env_gemini_blocked
PASS container_env_gemini_present
PASS container_nas_read_ok
```

Now the account can be handed to the customer.

## First Web UI Access

After customer-mode bootstrap passes its check, the customer account has no
Docker or raw config access. An admin should provide the first Gateway
connection details.

Print the Gateway token as admin:

```bash
TARGET_USER=oc1
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"

sudo python3 - <<PY
import json
from pathlib import Path

cfg = json.loads(Path("$TARGET_HOME/.openclaw/openclaw.json").read_text(encoding="utf-8"))
print(cfg["gateway"]["auth"]["token"])
PY
```

Use the token with the account's proxied Control UI URL:

```text
https://YOUR_CONTROL_UI_HOST/$TARGET_USER/
```

Normal installs should not ask for device approval. The install settings set
`gateway.controlUi.dangerouslyDisableDeviceAuth=true`, so the hosted Control UI
uses Gateway token auth without a separate browser-device approval step.

Verify the setting as admin:

```bash
TARGET_USER=oc1
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"

sudo python3 - <<PY
import json
from pathlib import Path

cfg = json.loads(Path("$TARGET_HOME/.openclaw/openclaw.json").read_text(encoding="utf-8"))
print(cfg.get("gateway", {}).get("controlUi", {}).get("dangerouslyDisableDeviceAuth") is True)
PY
```

If an older OpenClaw build still asks for device approval, approve only the
device id shown by the browser:

```bash
TARGET_USER=oc1
DEVICE_ID=DEVICE_ID_FROM_BROWSER

sudo bash /opt/openclaw-nas-agent-baseline/scripts/approve-openclaw-device.sh \
  --user "$TARGET_USER" \
  "$DEVICE_ID"
```

To inspect pending or known devices:

```bash
TARGET_USER=oc1

sudo bash /opt/openclaw-nas-agent-baseline/scripts/approve-openclaw-device.sh \
  --user "$TARGET_USER" \
  --list
```

## Customer Smoke Test

Open a new terminal and start a fresh customer SSH session:

```bash
TARGET_USER=oc1
SSH_HOST=YOUR_CUSTOMER_SSH_HOST
ssh "$TARGET_USER@$SSH_HOST"
```

Expected:

```bash
id
ls ~/nas_docs | head
cat ~/openclaw/.env
cat ~/.openclaw/openclaw.json
docker ps
```

Expected behavior:

```text
id
  no docker group

ls ~/nas_docs
  works

cat ~/openclaw/.env
  Permission denied

cat ~/.openclaw/openclaw.json
  Permission denied

docker ps
  permission denied
```

## Reference

- [Customer mode runtime isolation](docs/CUSTOMER_MODE_RUNTIME_ISOLATION.md)
- [Bootstrap compatibility](docs/BOOTSTRAP_COMPATIBILITY.md)
- [Container baseline](docs/CONTAINER_BASELINE.md)
- [Install settings](docs/INSTALL_SETTINGS.md)
- [Install package](docs/INSTALL_PACKAGE.md)
- [Recovery](docs/OPENCLAW_RECOVERY.md)
- [Remount guide](docs/REMOUNT_GUIDE.md)
