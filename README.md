# OpenClaw NAS Agent Baseline

이 저장소는 고객사별 Linux 계정(`oc1`, `oc2`, ...)마다 독립된 OpenClaw
컨테이너를 만들고, 각 계정 전용 NAS 경로를 컨테이너에 붙이기 위한 설치
패키지다.

기본 목표는 **customer mode**다.

```text
고객 계정 ocN:
  SSH 접속 가능
  /home/ocN/nas_docs 읽기 가능
  Docker 사용 불가
  API key/runtime env 읽기 불가
  OpenClaw raw config 읽기 불가

런타임 계정 ocN_rt:
  사람이 로그인하지 않는 시스템 계정
  OpenClaw gateway 컨테이너 실행
  API key/runtime env 읽기 가능
  ocN_data 그룹을 통해 NAS 읽기 가능
```

고객에게 계정을 넘기기 전에 반드시 customer-mode check가 통과해야 한다.

실행 순서는 아래처럼 읽으면 된다.

```text
일반 신규 설치:
  1 -> 2 -> 3 -> 4 -> 6 -> 7 -> 8

기존 계정을 일부러 지우고 fresh install 재검증:
  1 -> 2 -> 3 -> 4 -> 5 -> 6 -> 7 -> 8
```

## 1. Host Setup

sudo 가능한 관리자 계정에서 한 번 실행한다.

```bash
TMP_REPO="$(mktemp -d)/openclaw-nas-agent-baseline"
git clone https://github.com/Epicevent/openclaw-nas-agent-baseline.git "$TMP_REPO"
cd "$TMP_REPO"

sudo bash install.sh
```

공용 bootstrap에 이 저장소의 설치 hook을 패치한다.

```bash
PATCH_REPO=/opt/openclaw-nas-agent-baseline

sudo bash "$PATCH_REPO/scripts/patch-openclaw-bootstrap-install-env.sh"
sudo bash "$PATCH_REPO/scripts/patch-openclaw-bootstrap-install-env.sh" --check
```

정상 출력:

```text
bootstrap_install_env=ok
bootstrap_customer_mode=ok
```

## 2. 계정 준비

관리자 계정에서 실행한다. 바꿀 값은 `TARGET_USER` 하나다.

```bash
TARGET_USER=oc1
```

이후 명령은 위에서 지정한 `TARGET_USER` 기준으로 실행한다. 다른 계정을
작업할 때는 이 한 줄만 바꾼다.

```bash
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

주의: 고객 계정을 Docker 그룹에 넣지 않는다.

## 3. 설치 입력 파일 만들기

`$TARGET_HOME/.openclaw-install.env`는 설치 입력 파일이다. API key는 여기에
들어가지만, 설치 후 고객 계정은 이 파일을 읽을 수 없다.

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

값 자체를 출력하지 않고 존재 여부만 확인한다.

```bash
sudo grep -q '^GEMINI_API_KEY=' "$TARGET_HOME/.openclaw-install.env" && echo gemini_key_present
sudo grep -q "^OPENCLAW_CONTROL_UI_BASEPATH=/$TARGET_USER$" "$TARGET_HOME/.openclaw-install.env" && echo basepath_ok
```

## 4. NAS 준비와 전달 방식

이 단계는 NAS를 직접 마운트하는 단계가 아니다. bootstrap이 마운트할 수
있도록 디렉터리와 credential 파일 존재만 확인한다.

```bash
sudo mkdir -p "$TARGET_HOME/nas_docs"
sudo chown "$TARGET_USER:$TARGET_USER" "$TARGET_HOME/nas_docs"
sudo test -f /etc/samba/hanpass.cred && echo cifs_cred_ok
```

기본 NAS 값은 bootstrap patch 안에 들어 있다.

```text
OPENCLAW_CUSTOMER_SHARE=//192.168.0.222/hanpass
OPENCLAW_CUSTOMER_CREDENTIALS=/etc/samba/hanpass.cred
```

기본값을 쓸 때는 bootstrap 명령에 NAS 값을 따로 적지 않아도 된다.

NAS share나 credential 파일이 기본값과 다르면, bootstrap 실행 명령의
`sudo env` 블록에 아래 두 줄을 추가해서 전달한다.

```bash
OPENCLAW_CUSTOMER_SHARE='//192.168.0.222/hanpass' \
OPENCLAW_CUSTOMER_CREDENTIALS=/etc/samba/hanpass.cred \
```

실제 마운트는 customer-mode bootstrap이 수행한다. 최종 마운트 권한은
`ocN`과 `ocN_rt`만 읽을 수 있는 형태다.

## 5. 선택: Fresh Install 재검증 시작점

새 계정에 처음 설치하는 경우에는 이 단계는 건너뛴다.

이미 설치된 계정을 일부러 지우고 fresh install을 검증할 때만 실행한다.
이 블록을 실행하면 OpenClaw 설치물과 컨테이너가 삭제된다. 따라서 실행한
뒤에는 반드시 6번 이미지 빌드와 7번 bootstrap을 다시 실행해야 한다.

이 블록은 NAS, proxy, `.openclaw-install.env`, CIFS credential은 지우지
않는다.

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

삭제가 끝났는지 확인한다.

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

sudo docker image inspect openclaw-nas-agent:baseline >/dev/null 2>&1 \
  && echo image_still_exists \
  || echo image_deleted
```

정상적으로 지워졌다면 `*_deleted` 출력이 보인다. 이 상태는 OpenClaw가
없는 상태이므로, 반드시 6번 이미지 빌드와 7번 bootstrap을 이어서 실행한다.

## 6. Baseline 이미지 빌드

관리자 계정에서 실행한다. 5번에서 이미지를 지웠다면 이 단계가 다시
필요하다.

```bash
cd /opt/openclaw-nas-agent-baseline

sudo env \
  BASE_IMAGE=ghcr.io/openclaw/openclaw:latest \
  IMAGE_TAG=openclaw-nas-agent:baseline \
  bash scripts/build-container-baseline.sh
```

## 7. Customer Mode Bootstrap

관리자 계정에서 실행한다. 이 명령이 OpenClaw 설치, NAS 마운트, runtime
계정 구성, 권한 잠금을 한 번에 수행한다.

기본 NAS를 쓰는 경우:

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

NAS 값을 직접 전달해야 하는 경우:

```bash
sudo env \
  OPENCLAW_CUSTOMER_MODE=1 \
  OPENCLAW_TARGET_USER="$TARGET_USER" \
  OPENCLAW_CUSTOMER_SHARE='//192.168.0.222/hanpass' \
  OPENCLAW_CUSTOMER_CREDENTIALS=/etc/samba/hanpass.cred \
  OPENCLAW_IMAGE=openclaw-nas-agent:baseline \
  OPENCLAW_INSTALL_ENV_FILE="$TARGET_HOME/.openclaw-install.env" \
  OPENCLAW_BASELINE_DIR=/opt/openclaw-nas-agent-baseline \
  OPENCLAW_PROXY_PUBLIC_ORIGIN=https://ji-tech.co.kr \
  OPENCLAW_PROXY_ALLOWED_ORIGINS=https://ji-tech.co.kr,https://www.ji-tech.co.kr \
  openclaw-bootstrap < /dev/null
```

## 8. 설치 확인

관리자 계정에서 실행한다.

```bash
sudo bash /opt/openclaw-nas-agent-baseline/scripts/check-customer-mode-isolation.sh \
  --user "$TARGET_USER"
```

정상 출력에는 아래 PASS들이 포함되어야 한다.

```text
PASS customer_not_in_docker_group
PASS customer_nas_read_ok
PASS runtime_env_exists
PASS config_exists
PASS customer_runtime_env_blocked
PASS customer_config_blocked
PASS config_has_no_literal_api_key
PASS control_ui_device_auth_disabled
PASS control_ui_basepath_ok
PASS customer_docker_blocked
PASS customer_proc_env_gemini_blocked
PASS gateway_port_slot_ok
PASS container_env_gemini_present
PASS container_nas_read_ok
```

`container_env_gemini_present` 또는 `container_nas_read_ok`가 실패하고
컨테이너가 `restarting/unhealthy`면 먼저 로그를 본다.

```bash
sudo docker logs --tail=200 "openclaw-$TARGET_USER-openclaw-gateway-1"
```

## 9. 고객에게 전달할 Web UI 정보

고객 계정은 Docker나 raw config를 읽을 수 없으므로, 최초 접속 정보는
관리자가 확인해서 전달한다.

Gateway token 출력:

대상 계정을 바꿔야 하면 먼저 이 값만 바꾼다.

```bash
TARGET_USER=oc1
```

그 다음 token을 출력한다.

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
https://YOUR_CONTROL_UI_HOST/$TARGET_USER/
```

정상 설치에서는 별도의 device approval이 뜨지 않아야 한다. 현재 hosted
customer flow에서는 아래 설정을 사용한다.

```json
{
  "gateway": {
    "controlUi": {
      "dangerouslyDisableDeviceAuth": true
    }
  }
}
```

그래도 구버전 OpenClaw에서 device approval을 요구하면, 브라우저에 표시된
device id만 승인한다.

```bash
DEVICE_ID=DEVICE_ID_FROM_BROWSER
```

```bash
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

## 10. 고객 계정 Smoke Test

새 터미널에서 고객 계정으로 SSH 접속한다.

```bash
TARGET_USER=oc1
```

```bash
SSH_HOST=YOUR_CUSTOMER_SSH_HOST
ssh "$TARGET_USER@$SSH_HOST"
```

고객 계정에서 확인한다.

```bash
id
ls ~/nas_docs | head
cat ~/openclaw/.env
cat ~/.openclaw/openclaw.json
docker ps
```

기대 결과:

```text
id
  docker group 없음

ls ~/nas_docs
  읽기 가능

cat ~/openclaw/.env
  Permission denied

cat ~/.openclaw/openclaw.json
  Permission denied

docker ps
  permission denied
```

## 참고 문서

- [Customer mode runtime isolation](docs/CUSTOMER_MODE_RUNTIME_ISOLATION.md)
- [Bootstrap compatibility](docs/BOOTSTRAP_COMPATIBILITY.md)
- [Container baseline](docs/CONTAINER_BASELINE.md)
- [Install settings](docs/INSTALL_SETTINGS.md)
- [Install package](docs/INSTALL_PACKAGE.md)
- [Recovery](docs/OPENCLAW_RECOVERY.md)
- [Remount guide](docs/REMOUNT_GUIDE.md)
