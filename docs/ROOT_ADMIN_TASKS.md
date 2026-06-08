# root 관리자 작업

이 문서는 full sudo/root 권한이 필요한 작업만 모은다. 평소 운영은 `svcops`
계정에서 wrapper로 수행한다.

## 새 운영 도구 우선 설치

실행 주체: **root 관리자**

새 설치와 새 운영 기준은 `agent-runtime-ops`다. 기존 baseline은 서버 호환용
운영 패키지다.

먼저 새 운영 도구를 설치하거나 갱신한다.

```bash
sudo -v && curl -fsSL https://raw.githubusercontent.com/Epicevent/agent-runtime-ops/main/go | sudo bash
sudo bash /opt/agent-runtime-ops/install.sh --check
sudo -u svcops opsctl profile list
```

## 기준 계정

실행 주체: **root 관리자**

```bash
TARGET_USER=oc1
CONTROL_UI_HOST="$TARGET_USER.ji-tech.co.kr"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
```

## 고객 세션 확인

실행 주체: **root 관리자**

slot 설치, turnover, runtime secret 주입, Apache 반영, gateway 재생성처럼 root가
고객 홈 내부 파일을 쓰는 작업 전에는 고객 계정의 active session이 없어야 한다.

```bash
pgrep -u "$TARGET_USER" -a || echo "no_active_customer_process"
```

기존 고객에서 새 사용자로 넘기는 turnover라면 접근 차단과 세션 종료가 먼저다.

```bash
sudo passwd -l "$TARGET_USER"
sudo pkill -KILL -u "$TARGET_USER" 2>/dev/null || true
pgrep -u "$TARGET_USER" -a || echo "no_active_customer_process"
```

## 기존 baseline 운영 패키지 설치

실행 주체: **root 관리자**

이 절차는 기존 서버 호환을 위해 남긴다. 새 runtime profile, apply/check/rollback,
rollout 설계는 `agent-runtime-ops`에서 다룬다.

`/opt/openclaw-nas-agent-baseline`은 git checkout이 아니라 `install.sh`가 만든
설치본이다. `/opt` 안에서 `git pull`하지 않는다.

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

`install.sh`는 운영 패키지만 설치한다. 고객 slot, runtime image, product state,
recovery state는 설치 단계에서 수정하지 않는다.

## 고객 Linux 계정 준비

실행 주체: **root 관리자**

```bash
TARGET_USER=oc1
CONTROL_UI_HOST="$TARGET_USER.ji-tech.co.kr"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"

if ! id "$TARGET_USER" >/dev/null 2>&1; then
  sudo useradd -m -s /bin/bash "$TARGET_USER"
  sudo passwd "$TARGET_USER"
  TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
fi

id "$TARGET_USER"
echo "home=$TARGET_HOME"
echo "control_ui_host=$CONTROL_UI_HOST"
```

고객 계정은 `sudo`와 `docker` 그룹에 넣지 않는다.

## 공식 이미지 등록

실행 주체: **root 관리자**

고객 slot에 적용할 이미지는 public registry release로 준비한다. 운영서버에서 임의로
제품 이미지를 직접 굽지 않는다.

```bash
IMAGE_REF="ghcr.io/epicevent/openclaw-nas-agent:hermes-workspace-20260603-r16"
IMAGE_NAME="hermes-workspace-20260603-r16"

sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh \
  image-release-add "$IMAGE_REF" "$IMAGE_NAME"

sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh \
  image-release-verify "$IMAGE_NAME"

sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh image-list
```

검증이 통과하면 `/srv/openclaw-ops/images.yaml`에 public ref, immutable runtime
ref, digest, image id가 기록된다.

## 계정별 image 적용

실행 주체: **root 관리자**

먼저 고객 계정의 NAS가 fstab의 정확한 `//HOST/SHARE` source로
CIFS mount되어 있는지 확인한다.

```bash
NAS_SHARE='//NAS_HOST/SHARE'
MOUNT_POINT="$(awk -v share="$NAS_SHARE" '$0 !~ /^[[:space:]]*#/ && $1 == share && $3 == "cifs" { print $2; exit }' /etc/fstab)"
test -n "$MOUNT_POINT"

findmnt -M "$MOUNT_POINT" -o TARGET,SOURCE,FSTYPE,OPTIONS
test "$(findmnt -M "$MOUNT_POINT" -n -o SOURCE)" = "$NAS_SHARE" && echo nas_source_ok
test "$(findmnt -M "$MOUNT_POINT" -n -o FSTYPE)" = cifs && echo nas_mounted_cifs
```

OpenClaw family slot:

```bash
sudo /opt/openclaw-nas-agent-baseline/scripts/slot-control.sh install-openclaw \
  --user "$TARGET_USER" \
  --host "$CONTROL_UI_HOST" \
  --image "$IMAGE_REF"
```

Hermes family slot:

```bash
sudo /opt/openclaw-nas-agent-baseline/scripts/slot-control.sh install-hermes \
  --user "$TARGET_USER" \
  --host "$CONTROL_UI_HOST" \
  --image "$IMAGE_REF"
```

이미 설치된 slot을 같은 family image로 교체해야 할 때만 `--force`를 붙인다.

## runtime secret 주입

실행 주체: **root 관리자**

설치와 provider/API key 주입은 별도 단계다.

```bash
SECRET_ENV="/root/agent-runtime-secrets.$TARGET_USER.env"
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

주입 후 gateway를 재생성한다.

```bash
sudo /opt/openclaw-nas-agent-baseline/scripts/slot-control.sh runtime-secrets \
  --user "$TARGET_USER" \
  --host "$CONTROL_UI_HOST" \
  --env-file "$SECRET_ENV" \
  --check
```

## Apache 반영

실행 주체: **root 관리자**

slot 설치가 만든 Apache conf를 서버 Apache에 반영한다.

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

## 고객 전달 정보 확인

실행 주체: **root 관리자**

handoff credential을 출력한다. OpenClaw family면 gateway token, Hermes family면
Workspace password가 나온다.

```bash
sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh \
  handoff-credential "$TARGET_USER"
```

고객에게 전달하는 URL:

```text
https://ocN.ji-tech.co.kr/
```

## 신규 설치 재검증용 제거

실행 주체: **root 관리자**

이미 설치한 계정의 agent runtime을 지우고 새 image 설치를 검증할 때만 실행한다.
NAS mount, Apache 서버 설정, 고객 NAS credential은 삭제하지 않는다.

```bash
sudo docker ps -a --filter "label=com.docker.compose.project=openclaw-$TARGET_USER" \
  --format '{{.Names}}' | xargs -r sudo docker rm -f

sudo rm -rf "$TARGET_HOME/openclaw"
sudo rm -rf "$TARGET_HOME/.openclaw"
sudo rm -rf "$TARGET_HOME/.hermes"
sudo rm -rf "$TARGET_HOME/.openclaw-auth-profile-secrets"
sudo rm -rf "$TARGET_HOME/.config/openclaw"
sudo rm -rf "$TARGET_HOME/.cache/openclaw"
```

삭제 확인:

```bash
sudo docker ps -a --filter "label=com.docker.compose.project=openclaw-$TARGET_USER" \
  --format '{{.Names}}'

sudo test ! -e "$TARGET_HOME/openclaw" && echo compose_dir_deleted
sudo test ! -e "$TARGET_HOME/.openclaw" && echo openclaw_state_deleted
sudo test ! -e "$TARGET_HOME/.hermes" && echo hermes_state_deleted
```
