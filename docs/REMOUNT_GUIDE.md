# NAS 리마운트 가이드

기본 운영 모델에서는 고객 계정이 자기 NAS credential 파일을 보유하고, sudo 없이
정해진 mountpoint만 mount한다.

## fstab 규칙 등록

관리자 계정에서 실행한다.

이미 `nas_docs`가 마운트되어 있으면 먼저 gateway를 멈추고 unmount한다. CIFS가
read-only로 올라와 있는 상태에서는 mountpoint 소유권을 바꿀 수 없고, 그 상태를
완료로 보면 안 된다.

```bash
TARGET_USER=oc14
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
NAS_SHARE='//NAS_HOST/SHARE_NAME'

sudo docker rm -f "openclaw-$TARGET_USER-openclaw-gateway-1" 2>/dev/null || true

if [ "$(findmnt -T "$TARGET_HOME/nas_docs" -n -o TARGET 2>/dev/null | head -1)" = "$TARGET_HOME/nas_docs" ]; then
  sudo umount "$TARGET_HOME/nas_docs"
fi

sudo bash /opt/openclaw-nas-agent-baseline/scripts/write-user-nas-fstab-entry.sh \
  --user "$TARGET_USER" \
  --share "$NAS_SHARE"
```

## 고객 계정 credential

고객 계정에서 실행한다.

```bash
openclaw-nas-mount --reset-credential
```

## 고객 계정에서 리마운트

고객 계정에서 실행한다.

```bash
openclaw-nas-mount --remount
```

상태만 볼 때:

```bash
openclaw-nas-mount --status
```

여기서 `registered_share`가 고객 계정이 mount하려는 SMB 공유 경로다.
`next_action`은 현재 상태에서 다음에 실행할 명령을 가리킨다.

## gateway 다시 시작

관리자 계정에서 실행한다.

```bash
TARGET_USER=oc14
CONTROL_UI_HOST="${CONTROL_UI_HOST:-$TARGET_USER.ji-tech.co.kr}"

sudo bash /opt/openclaw-nas-agent-baseline/scripts/apply-subdomain-mode.sh \
  --user "$TARGET_USER" \
  --host "$CONTROL_UI_HOST"
```

## 관리자 확인

```bash
TARGET_USER=oc14
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"

findmnt -T "$TARGET_HOME/nas_docs" -o TARGET,SOURCE,FSTYPE,OPTIONS
sudo -u "$TARGET_USER" test -r "$TARGET_HOME/nas_docs" && echo customer_nas_read_ok
test "$(findmnt -T "$TARGET_HOME/nas_docs" -n -o FSTYPE)" = cifs && echo customer_nas_mounted_cifs
```

## busy 처리

```bash
TARGET_USER=oc14
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"

sudo fuser -vm "$TARGET_HOME/nas_docs"
```

실서비스에서는 원인을 먼저 정리한 뒤 unmount한다. `umount -l`은 마지막 수단으로만
쓴다.
