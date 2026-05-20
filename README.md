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

getent group docker >/dev/null || sudo groupadd docker
getent group openclaw-installers >/dev/null || sudo groupadd openclaw-installers

# Temporary bootstrap access only. The customer-mode isolation script removes
# docker before the account is handed to a customer.
sudo usermod -aG docker,openclaw-installers "$TARGET_USER"

id "$TARGET_USER"
echo "home=$TARGET_HOME"
```

Do not give the customer this account yet.

## Create Install Env

This file is install input. It is locked down by the customer-mode isolation
step after bootstrap.

```bash
sudo install -o "$TARGET_USER" -g "$TARGET_USER" -m 600 /dev/null "$TARGET_HOME/.openclaw-install.env"

read -rsp "GEMINI_API_KEY for $TARGET_USER: " GEMINI_API_KEY
printf '\n'

sudo tee "$TARGET_HOME/.openclaw-install.env" >/dev/null <<EOF
GEMINI_API_KEY=$GEMINI_API_KEY
OPENCLAW_DEFAULT_MODEL=google/gemini-3.1-pro-preview
OPENCLAW_CONTROL_UI_BASEPATH=/$TARGET_USER
OPENCLAW_PROXY_PUBLIC_ORIGIN=https://ji-tech.co.kr
OPENCLAW_PROXY_ALLOWED_ORIGINS=https://ji-tech.co.kr,https://www.ji-tech.co.kr
OPENCLAW_GATEWAY_BIND=lan
EOF

sudo chown "$TARGET_USER:$TARGET_USER" "$TARGET_HOME/.openclaw-install.env"
sudo chmod 600 "$TARGET_HOME/.openclaw-install.env"
unset GEMINI_API_KEY
```

Verify without printing secrets:

```bash
sudo grep -q '^GEMINI_API_KEY=' "$TARGET_HOME/.openclaw-install.env" && echo gemini_key_present
sudo grep -q "^OPENCLAW_CONTROL_UI_BASEPATH=/$TARGET_USER$" "$TARGET_HOME/.openclaw-install.env" && echo basepath_ok
```

## Mount NAS For Bootstrap

The customer-mode isolation step remounts this with the final shared group
permissions. This bootstrap mount only needs to let the initial install work.

```bash
sudo mkdir -p "$TARGET_HOME/nas_docs"
sudo chown "$TARGET_USER:$TARGET_USER" "$TARGET_HOME/nas_docs"
sudo test -f /etc/samba/hanpass.cred && echo cifs_cred_ok

TARGET_UID="$(id -u "$TARGET_USER")"
TARGET_GID="$(id -g "$TARGET_USER")"

if ! findmnt -T "$TARGET_HOME/nas_docs" >/dev/null 2>&1; then
  sudo mount -t cifs //192.168.0.222/hanpass "$TARGET_HOME/nas_docs" \
    -o credentials=/etc/samba/hanpass.cred,uid="$TARGET_UID",gid="$TARGET_GID",forceuid,forcegid,ro,file_mode=0400,dir_mode=0700,iocharset=utf8,vers=3.1.1,nounix,noserverino,nosharesock
fi
```

Verify:

```bash
findmnt -T "$TARGET_HOME/nas_docs" && echo nas_mount_ok
sudo -u "$TARGET_USER" test -r "$TARGET_HOME/nas_docs" && echo nas_read_ok
```

## Bootstrap In Staging Mode

This step uses the existing shared bootstrap. It is a staging step, not the
final customer state.

Open a new login session for the target account so its temporary Docker group is
visible:

```bash
sudo su - "$TARGET_USER"
cd "$HOME"
```

For a reinstall test, remove previous OpenClaw state but keep env and NAS:

```bash
docker ps -a --filter "label=com.docker.compose.project=openclaw-$(id -un)" \
  --format '{{.Names}}' | xargs -r docker rm -f

rm -rf "$HOME/openclaw"
rm -rf "$HOME/.openclaw"
rm -rf "$HOME/.openclaw-auth-profile-secrets"
rm -rf "$HOME/.config/openclaw"
rm -rf "$HOME/.cache/openclaw"
rm -rf "$HOME/openclaw-nas-agent-baseline-fresh"

docker rmi openclaw-nas-agent:baseline 2>/dev/null || true
```

Clone, build, and bootstrap:

```bash
git clone https://github.com/Epicevent/openclaw-nas-agent-baseline.git \
  "$HOME/openclaw-nas-agent-baseline-fresh"

cd "$HOME/openclaw-nas-agent-baseline-fresh"

BASE_IMAGE=ghcr.io/openclaw/openclaw:latest \
IMAGE_TAG=openclaw-nas-agent:baseline \
bash scripts/build-container-baseline.sh

OPENCLAW_IMAGE=openclaw-nas-agent:baseline \
OPENCLAW_INSTALL_ENV_FILE="$HOME/.openclaw-install.env" \
OPENCLAW_BASELINE_DIR="$HOME/openclaw-nas-agent-baseline-fresh" \
OPENCLAW_PROXY_PUBLIC_ORIGIN=https://ji-tech.co.kr \
OPENCLAW_PROXY_ALLOWED_ORIGINS=https://ji-tech.co.kr,https://www.ji-tech.co.kr \
openclaw-bootstrap < /dev/null
```

Exit back to the admin account:

```bash
exit
```

## Apply Customer Mode

Run as admin before giving the account to a customer:

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
PASS customer_docker_blocked
PASS customer_proc_env_gemini_blocked
PASS container_env_gemini_present
PASS container_nas_read_ok
```

Now the account can be handed to the customer.

## Customer Smoke Test

Open a fresh customer session using the hostname and account that will be given
to that customer:

```bash
# Replace both values before running. This is not a literal copy/paste command.
TARGET_USER=oc1
SSH_HOST=YOUR_CUSTOMER_SSH_HOST
ssh "$TARGET_USER@$SSH_HOST"

# Optional shortcut when this SSH client has a matching ~/.ssh/config alias:
# ssh oc1
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
