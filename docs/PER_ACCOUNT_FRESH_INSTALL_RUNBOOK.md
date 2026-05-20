# Per-Account Fresh Install Runbook

This runbook is account-neutral. Set `TARGET_USER` once, then run the sections
in order.

## 0. Select Target Account

Run as the sudo-capable admin account.

```bash
TARGET_USER=oc1  # change this for each account
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
test -n "$TARGET_HOME"
echo "target=$TARGET_USER home=$TARGET_HOME"
```

## 1. Account Prerequisites

```bash
id "$TARGET_USER"
test -d "$TARGET_HOME" && echo home_ok
id -nG "$TARGET_USER" | tr ' ' '\n' | grep -qx docker && echo docker_group_ok
```

If the account does not exist:

```bash
sudo adduser "$TARGET_USER"
sudo usermod -aG docker,openclaw-installers "$TARGET_USER"
```

## 2. Shared Bootstrap Patch

The bootstrap patch is a one-time host operation. Do not run it from a target
user's home path such as `/home/oc1/...`; that would make the runbook depend on
one account.

Use an admin checkout location when it exists:

```bash
PATCH_REPO=/opt/openclaw-nas-agent-baseline
test -f "$PATCH_REPO/scripts/patch-openclaw-bootstrap-install-env.sh" && echo patch_repo_ok
```

If there is no admin checkout, create a temporary checkout:

```bash
PATCH_REPO="$(mktemp -d)/openclaw-nas-agent-baseline"
git clone https://github.com/Epicevent/openclaw-nas-agent-baseline.git "$PATCH_REPO"
```

Patch and verify:

```bash
sudo bash "$PATCH_REPO/scripts/patch-openclaw-bootstrap-install-env.sh"
sudo bash "$PATCH_REPO/scripts/patch-openclaw-bootstrap-install-env.sh" --check
```

Expected:

```text
bootstrap_install_env=ok
```

Direct marker check:

```bash
grep -q OPENCLAW_BOOTSTRAP_INSTALL_ENV_PATCH /opt/openclaw-bootstrap/openclaw-bootstrap.sh && echo install_env_patch_ok
grep -q OPENCLAW_BOOTSTRAP_INSTALL_ENV_MAIN_CALL /opt/openclaw-bootstrap/openclaw-bootstrap.sh && echo main_call_ok
grep -q OPENCLAW_BOOTSTRAP_HOST_USER_RECREATE_PATCH /opt/openclaw-bootstrap/openclaw-bootstrap.sh && echo host_user_recreate_ok
```

## 3. Install Env

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
sudo test -f "$TARGET_HOME/.openclaw-install.env" && echo env_ok
sudo test "$(sudo stat -c '%a' "$TARGET_HOME/.openclaw-install.env")" = "600" && echo env_mode_ok
sudo grep -q '^GEMINI_API_KEY=' "$TARGET_HOME/.openclaw-install.env" && echo gemini_key_present
sudo grep -q "^OPENCLAW_CONTROL_UI_BASEPATH=/$TARGET_USER$" "$TARGET_HOME/.openclaw-install.env" && echo basepath_ok
```

## 4. NAS Mount

```bash
sudo test -d "$TARGET_HOME/nas_docs" || sudo mkdir -p "$TARGET_HOME/nas_docs"
sudo chown "$TARGET_USER:$TARGET_USER" "$TARGET_HOME/nas_docs"
```

If it is not already mounted:

```bash
TARGET_UID="$(id -u "$TARGET_USER")"
TARGET_GID="$(id -g "$TARGET_USER")"

sudo mount -t cifs //192.168.0.222/hanpass "$TARGET_HOME/nas_docs" \
  -o credentials=/etc/samba/hanpass.cred,uid="$TARGET_UID",gid="$TARGET_GID",forceuid,forcegid,ro,file_mode=0400,dir_mode=0500,iocharset=utf8,vers=3.1.1,nounix,noserverino,nosharesock
```

Verify:

```bash
findmnt -T "$TARGET_HOME/nas_docs" && echo nas_mount_ok
sudo -u "$TARGET_USER" test -r "$TARGET_HOME/nas_docs" && echo nas_read_ok
```

## 5. Enter Target Account

```bash
sudo su - "$TARGET_USER"
cd "$HOME"
```

All following commands run as the target account.

## 6. Destructive OpenClaw Reset

This deletes OpenClaw state for the target account. It must not delete
`$HOME/.openclaw-install.env`, `$HOME/nas_docs`, proxy config, fstab, CIFS
credentials, or `/opt/openclaw-bootstrap`.

```bash
cd "$HOME"

docker ps -a --filter "label=com.docker.compose.project=openclaw-$(id -un)" \
  --format '{{.Names}}' | xargs -r docker rm -f

rm -rf "$HOME/openclaw"
rm -rf "$HOME/.openclaw"
rm -rf "$HOME/.openclaw-auth-profile-secrets"
rm -rf "$HOME/.config/openclaw"
rm -rf "$HOME/.cache/openclaw"

docker rmi openclaw-nas-agent:baseline 2>/dev/null || true
rm -rf "$HOME/openclaw-nas-agent-baseline-fresh"
```

Verify preserved inputs:

```bash
test -f "$HOME/.openclaw-install.env" && echo env_still_ok
findmnt -T "$HOME/nas_docs" && echo nas_still_ok
```

## 7. Clone Baseline Repo

```bash
git clone https://github.com/Epicevent/openclaw-nas-agent-baseline.git \
  "$HOME/openclaw-nas-agent-baseline-fresh"

cd "$HOME/openclaw-nas-agent-baseline-fresh"
git rev-parse --short HEAD
```

## 8. Build Baseline Image

```bash
BASE_IMAGE=ghcr.io/openclaw/openclaw:latest \
IMAGE_TAG=openclaw-nas-agent:baseline \
bash scripts/build-container-baseline.sh
```

## 9. Run Bootstrap

```bash
OPENCLAW_IMAGE=openclaw-nas-agent:baseline \
OPENCLAW_INSTALL_ENV_FILE="$HOME/.openclaw-install.env" \
OPENCLAW_BASELINE_DIR="$HOME/openclaw-nas-agent-baseline-fresh" \
OPENCLAW_PROXY_PUBLIC_ORIGIN=https://ji-tech.co.kr \
OPENCLAW_PROXY_ALLOWED_ORIGINS=https://ji-tech.co.kr,https://www.ji-tech.co.kr \
openclaw-bootstrap < /dev/null
```

## 10. Verify Install

```bash
docker ps --filter "name=openclaw-$(id -un)" \
  --format 'container={{.Names}} image={{.Image}} status={{.Status}}'
```

```bash
python3 - <<'PY'
import json, os
cfg=json.load(open(os.path.expanduser("~/.openclaw/openclaw.json"), encoding="utf-8"))
print({
  "gemini_api_key_present": bool(cfg.get("plugins", {}).get("entries", {}).get("google", {}).get("config", {}).get("webSearch", {}).get("apiKey")),
  "gateway_token_present": bool(cfg.get("gateway", {}).get("auth", {}).get("token")),
  "default_model": cfg.get("agents", {}).get("defaults", {}).get("model", {}).get("primary"),
})
PY
```

```bash
docker exec "openclaw-$(id -un)-openclaw-gateway-1" sh -lc '
  id
  test -d /home/node/.openclaw && echo openclaw_bind_ok
  test -d /home/node/nas_docs && echo nas_bind_ok
  printf "nas_sample="
  find /home/node/nas_docs -maxdepth 1 -mindepth 1 2>/dev/null | head -3 | wc -l
'
```

## 11. Print Gateway Token

```bash
python3 - <<'PY'
import json, os
cfg=json.load(open(os.path.expanduser("~/.openclaw/openclaw.json"), encoding="utf-8"))
print(cfg["gateway"]["auth"]["token"])
PY
```

## 12. Approve Browser Device

If the browser asks for one-time approval:

```bash
cd "$HOME/openclaw-nas-agent-baseline-fresh"
bash scripts/approve-openclaw-device.sh DEVICE_ID_FROM_BROWSER
```

To list devices:

```bash
bash scripts/approve-openclaw-device.sh --list
```
