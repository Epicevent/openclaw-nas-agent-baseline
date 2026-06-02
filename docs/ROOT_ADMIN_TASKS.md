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

## root 작업 전 고객 세션 확인

실행 주체: **[root 관리자]**

fresh install, slot turnover, runtime secret 주입, subdomain 재적용, gateway
재생성처럼 root가 고객 홈 내부 파일을 쓰는 작업 전에는 고객 계정의 active
session이 없어야 한다.

```bash
pgrep -u "$TARGET_USER" -a || echo "no_active_customer_process"
```

기존 고객을 새 사용자로 넘기는 turnover라면 접근 차단과 세션 종료가 먼저다.

```bash
sudo passwd -l "$TARGET_USER"
sudo pkill -KILL -u "$TARGET_USER" 2>/dev/null || true
pgrep -u "$TARGET_USER" -a || echo "no_active_customer_process"
```

## 호스트 준비

실행 주체: **[root 관리자]**

서버에 공개 repo 기준을 설치하거나 갱신할 때 실행한다.
`/opt/openclaw-nas-agent-baseline`은 git checkout이 아니라 `install.sh`가 만든
설치본이다. 따라서 `/opt`에서 `git pull`하지 않는다. 반영할 public repo commit을
명령이 먼저 계산하고, 그 commit을 checkout한 임시 repo에서 설치한다.

기본 설치 대상은 public repo `main`의 현재 commit이다. 테스트 freeze 이후에는
서버 설치본의 manifest와 private 원장의 `baseline_commit`이 같은 값이어야 한다.

```bash
REPO_URL="https://github.com/Epicevent/openclaw-nas-agent-baseline.git"
BASELINE_COMMIT="$(git ls-remote "$REPO_URL" refs/heads/main | awk '{print $1}')"
test -n "$BASELINE_COMMIT"

echo "will_install_commit=$BASELINE_COMMIT"

TMP_REPO="$(mktemp -d)/openclaw-nas-agent-baseline"

git clone "$REPO_URL" "$TMP_REPO"
cd "$TMP_REPO"
git checkout --detach "$BASELINE_COMMIT"

sudo bash install.sh --check
sudo bash /opt/openclaw-nas-agent-baseline/scripts/install-svcops-account.sh \
  --set-password \
  --nopasswd-sudo

source /opt/openclaw-nas-agent-baseline/.openclaw-baseline-manifest
test "$source_commit" = "$BASELINE_COMMIT"
echo "installed_source_commit=$source_commit"
```

`/srv/openclaw-ops/slots.yaml`이 있으면 `install.sh`가 private 원장의
`baseline_commit`을 `installed_source_commit`과 같은 값으로 갱신한다.

`--set-password`는 `svcops` 로그인용 비밀번호를 설정한다. `--nopasswd-sudo`는
`svcops-control.sh` wrapper만 비밀번호 없이 실행하게 열어 둔다. PM2 drift monitor는
`sudo -n`으로 wrapper를 호출하므로 이 옵션이 필요하다. 이 설정은 `sudo bash`,
`sudo docker`, 임의 root shell을 허용하지 않는다.

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

아래 `latest` 예시는 빠른 검증용이다. 장기 production에서는 `BASE_IMAGE`를 digest로
고정하고, 빌드에 들어가는 pip/npm/apt dependency도 pinning 정책을 둔다.

```bash
cd /opt/openclaw-nas-agent-baseline

sudo env \
  BASE_IMAGE=ghcr.io/openclaw/openclaw:latest \
  IMAGE_TAG=openclaw-nas-agent:baseline \
  bash scripts/build-container-baseline.sh
```

빌드 결과는 기록한다.

```bash
sudo docker image inspect openclaw-nas-agent:baseline \
  --format 'image_id={{.Id}} created={{.Created}}'
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

`--check`를 붙인 fresh install 검사는 provider/API key 없이도 통과할 수 있는
smoke check다. 최종 운영 완료 확인은 runtime secret 주입 후 `apply-runtime-secrets.sh
--check`로 따로 수행한다.

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

고객 접속용 handoff credential을 출력한다. OpenClaw slot이면 gateway token,
Hermes slot이면 Workspace password가 나온다.

```bash
sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh \
  handoff-credential "$TARGET_USER"
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
