# OpenClaw NAS Agent Baseline

이 저장소는 고객사별 Linux 계정(`oc1`, `oc2`, ...)마다 독립된 OpenClaw
컨테이너를 만들고, 각 계정 전용 NAS 경로를 컨테이너에 붙이기 위한 설치
패키지다.

기본 목표는 **customer mode**다.

고객 배포용 Web UI는 **subdomain mode**를 기본으로 한다.

```text
권장: https://oc13.ji-tech.co.kr/
비권장: https://www.ji-tech.co.kr/oc13/
```

`/ocN` path 방식은 Apache 라우팅은 분리할 수 있지만 브라우저
`localStorage`가 같은 origin(`https://www.ji-tech.co.kr`)을 공유한다.
따라서 같은 브라우저에서 여러 계정을 테스트하면 Gateway URL/token 설정이
서로 섞일 수 있다. 고객에게 넘기는 구조는 `ocN.ji-tech.co.kr`처럼 origin을
계정별로 분리한다.

여기서 `rt`는 `runtime`의 약자다. `ocN_rt`는 고객에게 알려주거나 SSH로
접속시키는 계정이 아니라, OpenClaw gateway 컨테이너를 실행하기 위한 호스트
Linux 시스템 계정이다. 예를 들어 `TARGET_USER=oc13`이면 고객 계정은
`oc13`, 런타임 계정은 `oc13_rt`, NAS 공유용 그룹은 `oc13_data`가 된다.

이 분리가 필요한 이유는 고객 계정 `ocN`은 NAS를 읽을 수 있어야 하지만,
API key가 들어 있는 runtime env나 OpenClaw raw config는 읽으면 안 되기
때문이다. 그래서 고객이 SSH로 접속하는 계정과 OpenClaw 프로세스가 실제로
도는 계정을 분리한다.

```text
고객 계정 ocN:
  SSH 접속 가능
  /home/ocN/nas_docs 읽기 가능
  Docker 사용 불가
  API key/runtime env 읽기 불가
  OpenClaw raw config 읽기 불가

런타임(rt) 계정 ocN_rt:
  사람이 로그인하지 않는 시스템 계정
  OpenClaw gateway 컨테이너의 실행 UID/GID로 사용
  API key/runtime env 읽기 가능
  ocN_data 그룹을 통해 NAS 읽기 가능

NAS 공유 그룹 ocN_data:
  ocN과 ocN_rt가 같은 NAS 마운트를 읽기 위한 계정별 그룹
```

고객에게 계정을 넘기기 전에 반드시 customer-mode check가 통과해야 한다.

실행 순서는 아래처럼 읽으면 된다.

```text
일반 신규 설치:
  1 -> 2 -> 3 -> 4 -> 6 -> 7 -> 8 -> 9

기존 계정을 일부러 지우고 fresh install 재검증:
  1 -> 2 -> 3 -> 4 -> 5 -> 6 -> 7 -> 8 -> 9
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

관리자 계정에서 실행한다. 바꿀 값은 `TARGET_USER` 하나다. subdomain은
`TARGET_USER`에서 자동으로 만든다.

```bash
TARGET_USER=oc1
CONTROL_UI_HOST="$TARGET_USER.ji-tech.co.kr"
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
echo "control_ui_host=$CONTROL_UI_HOST"
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
OPENCLAW_PROXY_MODE=subdomain
OPENCLAW_CONTROL_UI_BASEPATH=/
OPENCLAW_CONTROL_UI_DISABLE_DEVICE_AUTH=1
OPENCLAW_PROXY_PUBLIC_ORIGIN=https://$CONTROL_UI_HOST
OPENCLAW_PROXY_ALLOWED_ORIGINS=https://$CONTROL_UI_HOST
OPENCLAW_GATEWAY_BIND=lan
EOF

sudo chown root:root "$TARGET_HOME/.openclaw-install.env"
sudo chmod 600 "$TARGET_HOME/.openclaw-install.env"
unset GEMINI_API_KEY
```

값 자체를 출력하지 않고 존재 여부만 확인한다.

```bash
sudo grep -q '^GEMINI_API_KEY=' "$TARGET_HOME/.openclaw-install.env" && echo gemini_key_present
sudo grep -q '^OPENCLAW_PROXY_MODE=subdomain$' "$TARGET_HOME/.openclaw-install.env" && echo proxy_mode_ok
sudo grep -q '^OPENCLAW_CONTROL_UI_BASEPATH=/$' "$TARGET_HOME/.openclaw-install.env" && echo basepath_ok
sudo grep -q "^OPENCLAW_PROXY_PUBLIC_ORIGIN=https://$CONTROL_UI_HOST$" "$TARGET_HOME/.openclaw-install.env" && echo origin_ok
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

관리자 계정에서 실행한다. 이 명령이 OpenClaw 설치, NAS 마운트, 런타임(rt)
계정 구성, 권한 잠금을 한 번에 수행한다.

기본 NAS를 쓰는 경우:

```bash
sudo env \
  OPENCLAW_CUSTOMER_MODE=1 \
  OPENCLAW_TARGET_USER="$TARGET_USER" \
  OPENCLAW_IMAGE=openclaw-nas-agent:baseline \
  OPENCLAW_INSTALL_ENV_FILE="$TARGET_HOME/.openclaw-install.env" \
  OPENCLAW_BASELINE_DIR=/opt/openclaw-nas-agent-baseline \
  OPENCLAW_PROXY_PUBLIC_ORIGIN="https://$CONTROL_UI_HOST" \
  OPENCLAW_PROXY_ALLOWED_ORIGINS="https://$CONTROL_UI_HOST" \
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
  OPENCLAW_PROXY_PUBLIC_ORIGIN="https://$CONTROL_UI_HOST" \
  OPENCLAW_PROXY_ALLOWED_ORIGINS="https://$CONTROL_UI_HOST" \
  openclaw-bootstrap < /dev/null
```

## 8. Subdomain Proxy 적용

관리자 계정에서 실행한다. 이 단계는 Apache가
`https://ocN.ji-tech.co.kr/...` 요청을 해당 계정 gateway의 root(`/`)로
보내도록 proxy conf를 준비하고, 운영 Apache에 활성화한다.

역할을 분리해서 이해하면 된다.

```text
Git repo:
  계정별 Apache 설정 파일을 생성하는 기준

/home/ocN/openclaw/deploy/apache-subdomain-ocN.conf:
  이 패키지가 생성하는 계정별 VirtualHost 원본

/etc/apache2/sites-available/ocN.ji-tech.co.kr.conf:
  Apache가 실제 운영 설정으로 읽을 사이트 파일

/etc/apache2/sites-enabled/ocN.ji-tech.co.kr.conf:
  a2ensite 후 활성화되는 심볼릭 링크
```

사전 조건:

```text
DNS: ocN.ji-tech.co.kr 이 이 서버를 가리킴
TLS: ocN.ji-tech.co.kr 을 포함하는 인증서 또는 wildcard 인증서가 Apache에 적용됨
Apache: ocN.ji-tech.co.kr 전용 VirtualHost를 sites-available/sites-enabled에 등록 가능
```

먼저 계정 홈의 `deploy` 폴더에 VirtualHost 원본을 생성한다.

```bash
sudo bash /opt/openclaw-nas-agent-baseline/scripts/write-apache-proxy-conf.sh \
  --user "$TARGET_USER" \
  --mode subdomain \
  --host "$CONTROL_UI_HOST" \
  --apply
```

이 스크립트는 `deploy.zip`과 같은 형식의 계정별 전체 VirtualHost 파일을
쓴다. 기본 출력 위치:

```text
/home/ocN/openclaw/deploy/apache-subdomain-ocN.conf
```

이 파일은 아직 Apache에 활성화된 것이 아니다. 신규 고객 계정이 추가될 때마다
운영자는 같은 파일을 `/etc/apache2/sites-available`에 설치하고 `a2ensite` 후
reload해야 한다. 이 단계를 빼면 `https://ocN.ji-tech.co.kr/` 요청은 Apache의
기본 사이트로 떨어질 수 있다.

```bash
sudo install -o root -g root -m 0644 \
  "$TARGET_HOME/openclaw/deploy/apache-subdomain-$TARGET_USER.conf" \
  "/etc/apache2/sites-available/$CONTROL_UI_HOST.conf"

sudo a2ensite "$CONTROL_UI_HOST.conf"
sudo apache2ctl -t
sudo systemctl reload apache2
```

정상 등록 여부 확인:

```bash
sudo apache2ctl -S | grep -A3 -B3 "$CONTROL_UI_HOST"
curl -k -I "https://$CONTROL_UI_HOST/"
```

DNS와 TLS 준비가 끝나기 전에는 deploy 폴더에 파일만 둬도 된다. 다만 고객에게
전달하는 실제 접속 URL은 Apache 사이트 활성화까지 끝난 뒤에만 정상 동작한다.

이미 설치된 계정을 subdomain mode로 전환할 때는 아래 helper를 사용한다. 이
명령은 `openclaw.json`, `openclaw/.env`, deploy conf를 맞춘 뒤 gateway
컨테이너를 force-recreate한다.

```bash
sudo bash /opt/openclaw-nas-agent-baseline/scripts/apply-subdomain-mode.sh \
  --user "$TARGET_USER" \
  --host "$CONTROL_UI_HOST"
```

고객 배포에서 `/ocN` path mode를 쓰지 않는다.

## 9. 설치 확인

관리자 계정에서 실행한다. 최종 완료 판정은 `deployment` 체크로 한다. 이
스크립트는 내부에서 customer-mode 격리 체크를 먼저 실행한 뒤, Apache
VirtualHost 등록과 실제 공개 URL 응답까지 확인한다.

```bash
sudo bash /opt/openclaw-nas-agent-baseline/scripts/check-customer-deployment.sh \
  --user "$TARGET_USER" \
  --expected-basepath / \
  --expected-origin "https://$CONTROL_UI_HOST"
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
PASS control_ui_allowed_origin_ok
PASS customer_docker_blocked
PASS customer_proc_env_gemini_blocked
PASS container_env_gemini_present
PASS container_nas_read_ok
PASS customer_isolation_ok
PASS container_exists_for_document_baseline
PASS container_locale_utf8
PASS container_ko_locale_available
PASS container_korean_fonts_available
PASS container_cmd_libreoffice_ok
PASS container_cmd_pandoc_ok
PASS container_cmd_tesseract_ok
PASS container_cmd_hwp5txt_ok
PASS container_cmd_hwp5proc_ok
PASS container_tesseract_kor_available
PASS container_python_document_modules_ok
PASS container_korean_file_smoke_ok
PASS apache_subdomain_basepath_ok
PASS apache_expected_host_parse_ok
PASS apache_syntax_ok
PASS apache_vhost_registered_ok
PASS apache_vhost_config_exists
PASS apache_backend_port_ok
PASS public_url_openclaw_page_ok
```

`apache_vhost_registered_ok`, `apache_vhost_config_exists`,
`apache_backend_port_ok`, `public_url_openclaw_page_ok` 중 하나가 실패하면 아직
`/etc/apache2` 운영 반영이 끝난 것이 아니다. 이 체크는
`sites-available/sites-enabled`에 개별 파일이 있는 방식뿐 아니라,
`/etc/apache2/openclaw/*.conf`처럼 별도 디렉터리를 Apache가 include하는 방식도
정상으로 인정한다. 이 상태가 맞지 않으면 브라우저가 OpenClaw가 아니라 기본
회사 홈페이지를 볼 수 있다.

알 수 없는 서브도메인이 OpenClaw UI를 보여주면 안 되는 정책이라면 아래처럼
추가로 확인한다.

```bash
sudo bash /opt/openclaw-nas-agent-baseline/scripts/check-customer-deployment.sh \
  --user "$TARGET_USER" \
  --expected-basepath / \
  --expected-origin "https://$CONTROL_UI_HOST" \
  --expect-unknown-origin-rejected "https://xn--ok0b5a690d.ji-tech.co.kr"
```

현재 운영 정책상 알 수 없는 서브도메인이 default vhost의 Control UI 껍데기까지
보여도 괜찮다면 이 옵션은 쓰지 않는다.

`container_env_gemini_present` 또는 `container_nas_read_ok`가 실패하고
컨테이너가 `restarting/unhealthy`면 먼저 로그를 본다.

```bash
sudo docker logs --tail=200 "openclaw-$TARGET_USER-openclaw-gateway-1"
```

## 10. 고객에게 전달할 Web UI 정보

고객 계정은 Docker나 raw config를 읽을 수 없으므로, 최초 접속 정보는
관리자가 확인해서 전달한다.

Gateway token 출력:

대상 계정을 바꿔야 하면 먼저 이 값만 바꾼다.

```bash
TARGET_USER=oc1
CONTROL_UI_HOST="$TARGET_USER.ji-tech.co.kr"
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
https://ocN.ji-tech.co.kr/
```

예:

```text
https://oc13.ji-tech.co.kr/
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

## 11. 고객 계정 Smoke Test

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
