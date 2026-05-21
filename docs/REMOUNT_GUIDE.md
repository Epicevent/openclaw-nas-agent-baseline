# NAS 리마운트 가이드

기본 운영 모델에서는 고객 계정이 자기 NAS credential 파일을 보유하고, sudo 없이
정해진 mountpoint만 mount한다.

현재 지원하는 mount 구조는 공유 이름별 하위 폴더 방식이다.

```text
//NAS_HOST/SHARE_NAME -> /home/ocN/nas_docs/SHARE_NAME -> /home/node/nas_docs/SHARE_NAME
```

`share`는 원격 SMB 공유 경로이고, 붙는 위치는 공유 이름에서 자동으로 정한다.
예를 들어 `//192.168.0.222/hanpass`는 `/home/ocN/nas_docs/hanpass`에 붙는다.

## fstab 규칙 등록

관리자 계정에서 실행한다.

이미 같은 공유 이름의 하위 폴더가 마운트되어 있으면 먼저 gateway를 멈추고
unmount한다. CIFS가 read-only로 올라와 있는 상태에서는 mountpoint 소유권을 바꿀
수 없고, 그 상태를 완료로 보면 안 된다.

```bash
TARGET_USER=oc14
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
NAS_SHARE='//NAS_HOST/SHARE_NAME'
MOUNT_NAME="${NAS_SHARE##*/}"

sudo docker rm -f "openclaw-$TARGET_USER-openclaw-gateway-1" 2>/dev/null || true

if [ "$(findmnt -T "$TARGET_HOME/nas_docs/$MOUNT_NAME" -n -o TARGET 2>/dev/null | head -1)" = "$TARGET_HOME/nas_docs/$MOUNT_NAME" ]; then
  sudo umount "$TARGET_HOME/nas_docs/$MOUNT_NAME"
fi

sudo bash /opt/openclaw-nas-agent-baseline/scripts/write-user-nas-fstab-entry.sh \
  --user "$TARGET_USER" \
  --share "$NAS_SHARE"
```

## 고객 계정 credential

고객 계정에서 실행한다.

```bash
openclaw-nas-mount --mount-name SHARE_NAME --reset-credential
```

## 고객 계정에서 리마운트

고객 계정에서 실행한다.

```bash
openclaw-nas-mount --mount-name SHARE_NAME --remount
```

상태만 볼 때:

```bash
openclaw-nas-mount --mount-name SHARE_NAME --status
```

다른 공유 경로가 필요할 때:

```bash
openclaw-nas-mount --request-share '//NAS_HOST/SHARE_NAME'
```

여기서 `registered_share`가 고객 계정이 mount하려는 SMB 공유 경로다.
`next_action`은 현재 상태에서 다음에 실행할 명령을 가리킨다.
이 상태는 고객 Linux 계정 기준이며, OpenClaw 컨테이너가 같은 NAS를 보는지는
운영계정의 `nas-verify`로 확인한다.

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
MOUNT_NAME=SHARE_NAME

findmnt -T "$TARGET_HOME/nas_docs/$MOUNT_NAME" -o TARGET,SOURCE,FSTYPE,OPTIONS
sudo -u "$TARGET_USER" test -r "$TARGET_HOME/nas_docs/$MOUNT_NAME" && echo customer_nas_read_ok
test "$(findmnt -T "$TARGET_HOME/nas_docs/$MOUNT_NAME" -n -o FSTYPE)" = cifs && echo customer_nas_mounted_cifs
```

## busy 처리

```bash
TARGET_USER=oc14
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
MOUNT_NAME=SHARE_NAME

sudo fuser -vm "$TARGET_HOME/nas_docs/$MOUNT_NAME"
```

실서비스에서는 원인을 먼저 정리한 뒤 unmount한다. `umount -l`은 마지막 수단으로만
쓴다.
