# Slot Turnover

`slot turnover`는 이미 운영 중인 `ocN` 슬롯을 새 사용자에게 넘기기 위한 절차다.
fresh install과 다르다. URL, port, Linux 계정명은 유지하지만 이전 사용자의
상태와 secret은 유지하지 않는다.

## 유지하는 것

```text
Linux 계정명: ocN
subdomain: https://ocN.example.com/
port와 compose project 이름
/home/ocN/openclaw 디렉터리 구조
baseline Docker image
```

`ocN`은 사람 이름이 아니라 운영 슬롯이다. 고객에게 보이는 URL과 port는 유지한다.

## 반드시 교체하는 것

```text
SSH password 또는 authorized_keys
OpenClaw session/state/workspace/cache
Gateway auth token
runtime env: /home/ocN/openclaw/.env
legacy install env: /home/ocN/.openclaw-install.env
provider/API keys
NAS credential: /home/ocN/.openclaw-nas/credentials/*.cred
남아 있는 CIFS mount
```

새 사용자가 이전 사용자의 API key, gateway token, session, NAS credential을
사용할 수 있으면 turnover 실패다.

## 운영 순서

실행 주체: **[root 관리자]**

```bash
TARGET_USER=oc20
CONTROL_UI_HOST="$TARGET_USER.ji-tech.co.kr"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
```

가장 먼저 기존 고객의 접근을 차단한다. cleanup보다 이 단계가 먼저다.

```bash
sudo passwd -l "$TARGET_USER"
sudo pkill -KILL -u "$TARGET_USER" 2>/dev/null || true
```

현재 gateway를 내린다.

```bash
sudo docker rm -f "openclaw-$TARGET_USER-openclaw-gateway-1" 2>/dev/null || true
sudo docker rm -f "openclaw-$TARGET_USER-openclaw-cli-1" 2>/dev/null || true
```

남아 있는 CIFS mount를 전부 내린다.

```bash
findmnt -R "$TARGET_HOME/nas_docs" -n -o TARGET 2>/dev/null \
  | sort -r \
  | while read -r mp; do
      [ "$mp" = "$TARGET_HOME/nas_docs" ] && continue
      sudo umount "$mp" 2>/dev/null || true
    done
```

이전 사용자의 상태와 secret을 제거한다.

```bash
sudo rm -rf "$TARGET_HOME/.openclaw"
sudo rm -rf "$TARGET_HOME/.openclaw-auth-profile-secrets"
sudo rm -rf "$TARGET_HOME/.config/openclaw"
sudo rm -rf "$TARGET_HOME/.cache/openclaw"
sudo rm -rf "$TARGET_HOME/.openclaw-nas/credentials"
sudo rm -f "$TARGET_HOME/.nas-cifs.cred"
sudo rm -f "$TARGET_HOME/openclaw/.env"
sudo rm -f "$TARGET_HOME/.openclaw-install.env"
```

NAS share는 운영계정이 등록하고, NAS credential은 새 고객이 직접 입력한다.

```bash
sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh nas-register "$TARGET_USER" '//NAS_HOST/SHARE_NAME'
```

고객 계정에서:

```bash
openclaw-nas-mount --mount-name SHARE_NAME --reset-credential
openclaw-nas-mount --mount-name SHARE_NAME --status
```

OpenClaw는 이미지 기반 fresh install 경로로 다시 만든다. 이때 provider/API key는
필수가 아니다.

```bash
sudo /opt/openclaw-nas-agent-baseline/scripts/install-customer-slot-from-image.sh \
  --user "$TARGET_USER" \
  --host "$CONTROL_UI_HOST" \
  --force \
  --check
```

provider/API key는 설치 후 별도 파일에서 주입한다.

```bash
SECRET_ENV="/root/openclaw-runtime-secrets.$TARGET_USER.env"
sudo install -o root -g root -m 0600 /dev/null "$SECRET_ENV"
sudo editor "$SECRET_ENV"

sudo /opt/openclaw-nas-agent-baseline/scripts/apply-runtime-secrets.sh \
  --user "$TARGET_USER" \
  --host "$CONTROL_UI_HOST" \
  --env-file "$SECRET_ENV" \
  --check
```

새 고객 접근권은 cleanup과 재설치가 끝난 뒤 부여한다.

```bash
sudo passwd -u "$TARGET_USER" 2>/dev/null || true
sudo passwd "$TARGET_USER"
```

SSH key 방식이면 운영 정책에 맞게 아래 파일을 새 사용자 키로 교체한다.

```text
/home/ocN/.ssh/authorized_keys
```

최종 확인은 운영계정에서 수행한다.

```bash
sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh nas-verify "$TARGET_USER"

sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh check \
  "$TARGET_USER" \
  "$CONTROL_UI_HOST"
```

## 완료 조건

```text
이전 CIFS mount가 남아 있지 않음
이전 NAS credential이 남아 있지 않음
이전 .openclaw state/cache/session이 남아 있지 않음
runtime .env는 root:root 0600
고객 계정은 runtime env/config를 읽지 못함
고객 계정은 docker group에 없음
컨테이너는 NAS mount를 /home/node/nas_docs/SHARE_NAME에서 읽음
subdomain origin은 해당 ocN host만 허용
새 provider/API key가 runtime env에 주입됨
```

## 하지 않는 것

```text
userdel로 ocN을 삭제하지 않는다.
port/subdomain/compose project 이름을 바꾸지 않는다.
이전 사용자 API key를 유지하지 않는다.
이전 gateway token을 유지하지 않는다.
고객 NAS password를 운영자에게 전달하지 않는다.
```
