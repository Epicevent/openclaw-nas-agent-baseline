# root 관리자 작업

이 문서는 full sudo/root 권한이 필요한 작업만 모아 둔다. 평소 운영은
`svcops` 계정에서 진행하고, 여기 있는 명령은 서버 초기 구성이나 계정별 설치처럼
구조적으로 root 권한이 필요한 때만 실행한다.

## 대상 계정 지정

실행 주체: **[root 관리자]**

```bash
TARGET_USER=oc1
CONTROL_UI_HOST="$TARGET_USER.ji-tech.co.kr"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
```

## 호스트 준비

실행 주체: **[root 관리자]**

서버당 한 번 실행한다.

```bash
TMP_REPO="$(mktemp -d)/openclaw-nas-agent-baseline"
git clone https://github.com/Epicevent/openclaw-nas-agent-baseline.git "$TMP_REPO"
cd "$TMP_REPO"

sudo bash install.sh
```

제한 운영계정 `svcops`를 만든다.

```bash
sudo bash /opt/openclaw-nas-agent-baseline/scripts/install-svcops-account.sh --set-password
```

## 고객 Linux 계정 준비

실행 주체: **[root 관리자]**

```bash
TARGET_USER=oc1
CONTROL_UI_HOST="$TARGET_USER.ji-tech.co.kr"
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
echo "control_ui_host=$CONTROL_UI_HOST"
```

고객 계정은 Docker 그룹에 넣지 않는다.

## baseline 이미지 빌드

실행 주체: **[root 관리자]**

```bash
cd /opt/openclaw-nas-agent-baseline

sudo env \
  BASE_IMAGE=ghcr.io/openclaw/openclaw:latest \
  IMAGE_TAG=openclaw-nas-agent:baseline \
  bash scripts/build-container-baseline.sh
```

## 계정별 OpenClaw 설치

실행 주체: **[root 관리자]**

먼저 고객 계정이 `/home/ocN/nas_docs/SHARE_NAME` 형태의 하위 폴더를 CIFS로
mount했는지 확인한다.

```bash
MOUNT_NAME=SHARE_NAME

findmnt -T "$TARGET_HOME/nas_docs/$MOUNT_NAME" -o TARGET,SOURCE,FSTYPE,OPTIONS
test "$(findmnt -T "$TARGET_HOME/nas_docs/$MOUNT_NAME" -n -o FSTYPE)" = cifs && echo nas_mounted_cifs
```

설치한다.

```bash
sudo bash /opt/openclaw-nas-agent-baseline/scripts/install-customer-slot-from-image.sh \
  --user "$TARGET_USER" \
  --host "$CONTROL_UI_HOST" \
  --image openclaw-nas-agent:baseline
```

부분 설치물을 덮어써야 할 때만 `--force`를 붙인다.

```bash
sudo bash /opt/openclaw-nas-agent-baseline/scripts/install-customer-slot-from-image.sh \
  --user "$TARGET_USER" \
  --host "$CONTROL_UI_HOST" \
  --image openclaw-nas-agent:baseline \
  --force
```

## runtime secret 주입 또는 교체

실행 주체: **[root 관리자]**

설치와 provider/API key 주입은 별도 단계다. fresh install 직후 또는 key 교체가
필요할 때 실행한다.

```bash
SECRET_ENV="/root/openclaw-runtime-secrets.$TARGET_USER.env"
sudo install -o root -g root -m 600 /dev/null "$SECRET_ENV"

read -rsp "GEMINI_API_KEY for $TARGET_USER: " GEMINI_API_KEY
printf '\n'

sudo tee "$SECRET_ENV" >/dev/null <<EOF
GEMINI_API_KEY=$GEMINI_API_KEY
EOF

sudo chown root:root "$SECRET_ENV"
sudo chmod 600 "$SECRET_ENV"
unset GEMINI_API_KEY
```

값 자체를 출력하지 않고 존재 여부만 확인한다.

```bash
sudo grep -q '^GEMINI_API_KEY=' "$SECRET_ENV" && echo gemini_key_present
```

주입하고 gateway를 재생성한다.

```bash
sudo bash /opt/openclaw-nas-agent-baseline/scripts/apply-runtime-secrets.sh \
  --user "$TARGET_USER" \
  --host "$CONTROL_UI_HOST" \
  --env-file "$SECRET_ENV" \
  --check
```

## Apache 운영 반영

실행 주체: **[root 관리자]**

Apache가 `/etc/apache2/openclaw/*.conf` 같은 별도 디렉터리를 이미 include하도록
구성되어 있다면 이 단계는 현장 정책에 맞게 조정한다. 개별 site 파일로 등록하는
경우에는 아래처럼 적용한다.

```bash
sudo install -o root -g root -m 0644 \
  "$TARGET_HOME/openclaw/deploy/apache-subdomain-$TARGET_USER.conf" \
  "/etc/apache2/sites-available/$CONTROL_UI_HOST.conf"

sudo a2ensite "$CONTROL_UI_HOST.conf"
sudo apache2ctl -t
sudo systemctl reload apache2
```

확인한다.

```bash
sudo apache2ctl -S | grep -A3 -B3 "$CONTROL_UI_HOST"
curl -k -I "https://$CONTROL_UI_HOST/"
```

## 고객 전달 정보

실행 주체: **[root 관리자]**

Gateway token을 출력한다.

```bash
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"

sudo python3 - <<PY
import json
from pathlib import Path

cfg = json.loads(Path("$TARGET_HOME/.openclaw/openclaw.json").read_text(encoding="utf-8"))
print(cfg["gateway"]["auth"]["token"])
PY
```

고객에게 전달할 URL 형식:

```text
https://ocN.ji-tech.co.kr/
```

정상 설치에서는 별도의 device approval이 뜨지 않아야 한다. 그래도 구버전
OpenClaw에서 device approval을 요구하면 브라우저에 표시된 device id만 승인한다.

```bash
DEVICE_ID=DEVICE_ID_FROM_BROWSER

sudo bash /opt/openclaw-nas-agent-baseline/scripts/approve-openclaw-device.sh \
  --user "$TARGET_USER" \
  "$DEVICE_ID"
```

pending device 확인:

```bash
sudo bash /opt/openclaw-nas-agent-baseline/scripts/approve-openclaw-device.sh \
  --user "$TARGET_USER" \
  --list
```

## 신규 설치 재검증용 삭제

실행 주체: **[root 관리자]**

이미 설치된 계정을 일부러 지우고 신규 설치를 검증할 때만 실행한다.
이 블록은 OpenClaw 설치물과 컨테이너를 삭제한다. NAS mount, Apache 설정,
고객 NAS credential은 삭제하지 않는다.

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

삭제 확인:

```bash
echo "TARGET_USER=$TARGET_USER"
echo "TARGET_HOME=$TARGET_HOME"

sudo docker ps -a --filter "label=com.docker.compose.project=openclaw-$TARGET_USER" \
  --format '{{.Names}}'

sudo test ! -e "$TARGET_HOME/openclaw" && echo openclaw_dir_deleted
sudo test ! -e "$TARGET_HOME/.openclaw" && echo openclaw_state_deleted
sudo test ! -e "$TARGET_HOME/.openclaw-auth-profile-secrets" && echo auth_secrets_deleted
sudo test ! -e "$TARGET_HOME/.config/openclaw" && echo config_deleted
sudo test ! -e "$TARGET_HOME/.cache/openclaw" && echo cache_deleted
```

삭제 후에는 baseline 이미지 빌드와 계정별 OpenClaw 설치를 다시 실행한다.
