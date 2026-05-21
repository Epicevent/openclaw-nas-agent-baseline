# Slot Turnover

`slot turnover`는 이미 운영 중인 `ocN` 슬롯을 새 사용자에게 넘기는 절차다.
fresh install이 아니다.

## 유지하는 것

```text
Linux 계정명: ocN
UID/GID
subdomain, Apache, TLS
Docker compose 디렉터리: /home/ocN/openclaw
runtime env: /home/ocN/openclaw/.env
install env: /home/ocN/.openclaw-install.env
fstab NAS mount 규칙
baseline image
```

## 교체하거나 삭제하는 것

```text
SSH 비밀번호 또는 authorized_keys
고객 NAS credential: /home/ocN/.openclaw-nas/credentials/*.cred
NAS mount 세션
OpenClaw 사용자 상태: /home/ocN/.openclaw
OpenClaw auth/profile/cache 상태
shell history 등 이전 사용자 흔적
```

## 절차

관리자 계정에서 시작한다.

```bash
TARGET_USER=oc20
CONTROL_UI_HOST="$TARGET_USER.ji-tech.co.kr"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
```

현재 상태를 확인한다.

```bash
sudo docker ps --filter "name=openclaw-$TARGET_USER-openclaw-gateway-1" \
  --format 'container={{.Names}} status={{.Status}}'

findmnt -R "$TARGET_HOME/nas_docs" -o TARGET,SOURCE,FSTYPE,OPTIONS || true
```

gateway를 멈춘다.

```bash
sudo docker rm -f "openclaw-$TARGET_USER-openclaw-gateway-1" 2>/dev/null || true
sudo docker rm -f "openclaw-$TARGET_USER-openclaw-cli-1" 2>/dev/null || true
```

NAS mount를 내리고 이전 고객 credential을 제거한다.

```bash
findmnt -R "$TARGET_HOME/nas_docs" -n -o TARGET 2>/dev/null \
  | sort -r \
  | while read -r mp; do
      [ "$mp" = "$TARGET_HOME/nas_docs" ] && continue
      sudo umount "$mp" 2>/dev/null || true
    done

sudo rm -rf "$TARGET_HOME/.openclaw-nas/credentials"
sudo rm -f "$TARGET_HOME/.nas-cifs.cred"
```

이전 사용자의 OpenClaw 상태를 제거한다.

```bash
sudo rm -rf "$TARGET_HOME/.openclaw"
sudo rm -rf "$TARGET_HOME/.openclaw-auth-profile-secrets"
sudo rm -rf "$TARGET_HOME/.config/openclaw"
sudo rm -rf "$TARGET_HOME/.cache/openclaw"
```

필요하면 shell 접근권도 교체한다.

```bash
sudo passwd "$TARGET_USER"
```

SSH key 방식이면 운영 정책에 맞게 `$TARGET_HOME/.ssh/authorized_keys`를 교체한다.

새 사용자가 고객 계정으로 접속해 NAS credential을 만들고 mount한다. 운영자가
등록한 공유 경로가 `//NAS_HOST/SHARE_NAME`이면 mount 이름은 `SHARE_NAME`이다.

```bash
openclaw-nas-mount --mount-name SHARE_NAME --reset-credential
openclaw-nas-mount --mount-name SHARE_NAME --status
```

관리자 계정에서 OpenClaw 상태를 다시 만든다. 이 단계는 재설치가 아니라 기존
compose/runtime을 유지한 상태에서 새 사용자 상태만 다시 만드는 것이다.

```bash
cd /opt/openclaw-nas-agent-baseline

sudo bash scripts/apply-openclaw-install-env.sh \
  --env-file "$TARGET_HOME/.openclaw-install.env" \
  --user "$TARGET_USER"

sudo bash scripts/repair-openclaw-state.sh \
  --user "$TARGET_USER" \
  --force-defaults \
  --no-backup

sudo bash scripts/apply-subdomain-mode.sh \
  --user "$TARGET_USER" \
  --host "$CONTROL_UI_HOST" \
  --no-recreate

sudo bash scripts/apply-customer-mode-isolation.sh \
  --user "$TARGET_USER" \
  --no-remount \
  --check
```

최종 확인은 deployment check로 한다.

```bash
sudo bash /opt/openclaw-nas-agent-baseline/scripts/check-customer-deployment.sh \
  --user "$TARGET_USER" \
  --expected-basepath / \
  --expected-origin "https://$CONTROL_UI_HOST"
```

## 하지 않는 것

```text
userdel로 ocN을 삭제하지 않는다.
/home/ocN/openclaw를 지우지 않는다.
baseline image를 지우지 않는다.
bootstrap을 다시 실행하지 않는다.
NAS username/password를 관리자에게 전달하지 않는다.
```
