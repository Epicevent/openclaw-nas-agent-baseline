# OpenClaw NAS Agent Baseline

Start here. For a first install, do not read the other docs first.

This repo has one job:

```text
Build an OpenClaw runtime image with document/NAS tools, then let the shared
openclaw-bootstrap install that image for one Linux account.
```

This repo does not own:

- Linux account policy
- NAS credentials
- reverse proxy config
- OpenClaw gateway tokens
- Gemini/API secrets

## Flow

```text
Once per host:
  install this repo under /opt
  patch the shared openclaw-bootstrap

Once per account:
  prepare the Linux user
  create ~/.openclaw-install.env
  mount NAS at ~/nas_docs
  enter that account
  clone this repo
  build openclaw-nas-agent:baseline
  run openclaw-bootstrap
  verify
```

## 1. Host Setup

Run as a sudo-capable admin account.

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

## 2. Prepare One Account

Change only `TARGET_USER` for each account.

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
sudo usermod -aG docker,openclaw-installers "$TARGET_USER"

id "$TARGET_USER"
echo "home=$TARGET_HOME"
```

If the account was newly created or just added to the Docker group, open a new
login session for that account before running Docker commands as it.

## 3. Create Install Env

Run as the admin account.

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

## 4. Mount NAS

Run as the admin account.

```bash
sudo mkdir -p "$TARGET_HOME/nas_docs"
sudo chown "$TARGET_USER:$TARGET_USER" "$TARGET_HOME/nas_docs"
sudo test -f /etc/samba/hanpass.cred && echo cifs_cred_ok

TARGET_UID="$(id -u "$TARGET_USER")"
TARGET_GID="$(id -g "$TARGET_USER")"

if ! findmnt -T "$TARGET_HOME/nas_docs" >/dev/null 2>&1; then
  sudo mount -t cifs //192.168.0.222/hanpass "$TARGET_HOME/nas_docs" \
    -o credentials=/etc/samba/hanpass.cred,uid="$TARGET_UID",gid="$TARGET_GID",forceuid,forcegid,ro,file_mode=0400,dir_mode=0500,iocharset=utf8,vers=3.1.1,nounix,noserverino,nosharesock
fi
```

Verify:

```bash
findmnt -T "$TARGET_HOME/nas_docs" && echo nas_mount_ok
sudo -u "$TARGET_USER" test -r "$TARGET_HOME/nas_docs" && echo nas_read_ok
```

## 5. Fresh Install As Target User

Enter the target account:

```bash
sudo su - "$TARGET_USER"
cd "$HOME"
```

For a real new account this reset usually removes nothing. For a reinstall
test, it removes the previous OpenClaw state but keeps env and NAS.

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

test -f "$HOME/.openclaw-install.env" && echo env_still_ok
findmnt -T "$HOME/nas_docs" && echo nas_still_ok
```

Clone and build:

```bash
git clone https://github.com/Epicevent/openclaw-nas-agent-baseline.git \
  "$HOME/openclaw-nas-agent-baseline-fresh"

cd "$HOME/openclaw-nas-agent-baseline-fresh"
git rev-parse --short HEAD

BASE_IMAGE=ghcr.io/openclaw/openclaw:latest \
IMAGE_TAG=openclaw-nas-agent:baseline \
bash scripts/build-container-baseline.sh
```

Install with bootstrap:

```bash
OPENCLAW_IMAGE=openclaw-nas-agent:baseline \
OPENCLAW_INSTALL_ENV_FILE="$HOME/.openclaw-install.env" \
OPENCLAW_BASELINE_DIR="$HOME/openclaw-nas-agent-baseline-fresh" \
OPENCLAW_PROXY_PUBLIC_ORIGIN=https://ji-tech.co.kr \
OPENCLAW_PROXY_ALLOWED_ORIGINS=https://ji-tech.co.kr,https://www.ji-tech.co.kr \
openclaw-bootstrap < /dev/null
```

## 6. Verify

```bash
docker ps --filter "name=openclaw-$(id -un)" \
  --format 'container={{.Names}} image={{.Image}} status={{.Status}}'
```

```bash
python3 - <<'PY'
import json, os, pathlib
cfg=json.load(open(os.path.expanduser("~/.openclaw/openclaw.json"), encoding="utf-8"))
web_search=cfg.get("plugins", {}).get("entries", {}).get("google", {}).get("config", {}).get("webSearch", {})
runtime_env=pathlib.Path("~/openclaw/.env").expanduser()
runtime_env_gemini_present = False
if runtime_env.exists():
    runtime_env_gemini_present = any(
        line.startswith("GEMINI_API_KEY=")
        for line in runtime_env.read_text(encoding="utf-8", errors="replace").splitlines()
    )
print({
  "gemini_config_api_key_present": "apiKey" in web_search,
  "gemini_runtime_env_present": runtime_env_gemini_present,
  "gateway_token_present": bool(cfg.get("gateway", {}).get("auth", {}).get("token")),
  "default_model": cfg.get("agents", {}).get("defaults", {}).get("model", {}).get("primary"),
})
PY
```

Expected:

```text
gemini_config_api_key_present: False
gemini_runtime_env_present: True
gateway_token_present: True
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

Print the gateway token:

```bash
python3 - <<'PY'
import json, os
cfg=json.load(open(os.path.expanduser("~/.openclaw/openclaw.json"), encoding="utf-8"))
print(cfg["gateway"]["auth"]["token"])
PY
```

If the browser asks for device approval:

```bash
cd "$HOME/openclaw-nas-agent-baseline-fresh"
bash scripts/approve-openclaw-device.sh DEVICE_ID_FROM_BROWSER
```

## Reference

Do not start with these. They are for debugging or background.

- [Bootstrap compatibility](docs/BOOTSTRAP_COMPATIBILITY.md)
- [Container baseline](docs/CONTAINER_BASELINE.md)
- [Install settings](docs/INSTALL_SETTINGS.md)
- [Install package](docs/INSTALL_PACKAGE.md)
- [Recovery](docs/OPENCLAW_RECOVERY.md)
- [Remount guide](docs/REMOUNT_GUIDE.md)
