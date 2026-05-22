# Slot Turnover

`slot turnover`는 이미 운영 중인 `ocN` 슬롯을 새 사용자에게 넘기는 절차다. 새 서버나 새 슬롯을 만드는 fresh install과 다르다.

## 유지하는 것

```text
Linux 계정명: ocN
subdomain: https://ocN.example.com/
port와 compose project 이름
/home/ocN/openclaw 디렉터리 구조
baseline Docker image
```

`ocN`은 사람 이름이 아니라 운영 슬롯이다. URL과 포트는 유지하지만, 이전 사용자의 상태와 secret은 유지하지 않는다.

## 반드시 교체하는 것

```text
SSH password 또는 authorized_keys
OpenClaw session/state/workspace/cache
Gateway auth token
runtime env: /home/ocN/openclaw/.env
install env: /home/ocN/.openclaw-install.env
provider/API keys
NAS credential: /home/ocN/.openclaw-nas/credentials/*.cred
남아 있는 CIFS mount
```

새 사용자가 이전 사용자의 API key, gateway token, 세션, NAS credential을 이어받으면 turnover 실패다.

## 운영 흐름

실행 주체: root 관리자.

```bash
TARGET_USER=oc20
CONTROL_UI_HOST="$TARGET_USER.ji-tech.co.kr"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
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

SSH 접근권을 교체한다.

```bash
sudo passwd "$TARGET_USER"
```

SSH key 방식이면 운영 정책에 맞게 아래 파일을 새 사용자 키로 교체한다.

```text
/home/ocN/.ssh/authorized_keys
```

새 runtime/install env는 새 사용자 기준으로 다시 만든다. API key는 이전 사용자 것을 재사용하지 않는다.

```bash
sudo install -o root -g root -m 0600 /dev/null "$TARGET_HOME/.openclaw-install.env"

sudo editor "$TARGET_HOME/.openclaw-install.env"
```

최소 예시는 아래 형태다.

```bash
GEMINI_API_KEY=NEW_CUSTOMER_KEY
OPENCLAW_PROXY_MODE=subdomain
OPENCLAW_CONTROL_UI_BASEPATH=/
OPENCLAW_PROXY_PUBLIC_ORIGIN=https://oc20.ji-tech.co.kr
OPENCLAW_PROXY_ALLOWED_ORIGINS=https://oc20.ji-tech.co.kr
```

NAS share는 운영계정이 등록하고, credential은 고객 계정이 직접 입력한다.

```bash
sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh nas-register "$TARGET_USER" '//NAS_HOST/SHARE_NAME'
```

고객 계정에서:

```bash
openclaw-nas-mount --mount-name SHARE_NAME --reset-credential
openclaw-nas-mount --mount-name SHARE_NAME --status
```

OpenClaw는 fast install 경로로 다시 구성한다.

```bash
sudo /opt/openclaw-nas-agent-baseline/scripts/install-customer-slot-from-image.sh \
  --user "$TARGET_USER" \
  --host "$CONTROL_UI_HOST" \
  --force \
  --check
```

최종 확인은 운영계정에서 한다.

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
새 .openclaw-install.env와 runtime .env가 root:root 0600
고객 계정은 runtime env/config를 읽지 못함
고객 계정은 docker group에 없음
컨테이너는 새 NAS mount를 /home/node/nas_docs/SHARE_NAME에서 읽음
subdomain origin은 해당 ocN host만 허용
```

## 하지 않는 것

```text
userdel로 ocN을 삭제하지 않는다.
port/subdomain/compose project 이름을 바꾸지 않는다.
이전 사용자 API key를 유지하지 않는다.
이전 gateway token을 유지하지 않는다.
고객 NAS password를 운영자에게 전달하지 않는다.
```
