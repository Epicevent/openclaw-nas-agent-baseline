# NAS 리마운트 가이드

기본 운영 모델에서는 고객 계정이 자기 NAS credential 파일을 보유하고, sudo 없이
정해진 mountpoint만 mount한다.

## fstab 규칙 등록

관리자 계정에서 실행한다.

```bash
TARGET_USER=oc14
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
NAS_SHARE='//NAS_HOST/SHARE_NAME'

sudo bash /opt/openclaw-nas-agent-baseline/scripts/write-user-nas-fstab-entry.sh \
  --user "$TARGET_USER" \
  --share "$NAS_SHARE"
```

## 고객 계정에서 리마운트

고객 계정에서 실행한다.

```bash
umount "$HOME/nas_docs" 2>/dev/null || true
mount "$HOME/nas_docs"
findmnt -T "$HOME/nas_docs" -o TARGET,SOURCE,FSTYPE,OPTIONS
ls "$HOME/nas_docs" | head
```

credential 파일을 다시 만들어야 하면 고객 계정에서 실행한다.

```bash
umask 077

printf "NAS username: "
read NAS_USER

printf "NAS password: "
stty -echo
read NAS_PASS
stty echo
printf "\n"

{
  printf "username=%s\n" "$NAS_USER"
  printf "password=%s\n" "$NAS_PASS"
} > "$HOME/.nas-cifs.cred"

chmod 600 "$HOME/.nas-cifs.cred"
unset NAS_USER NAS_PASS
```

## 관리자 확인

```bash
TARGET_USER=oc14
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"

findmnt -T "$TARGET_HOME/nas_docs" -o TARGET,SOURCE,FSTYPE,OPTIONS
sudo -u "$TARGET_USER" test -r "$TARGET_HOME/nas_docs" && echo customer_nas_read_ok
```

## busy 처리

```bash
sudo fuser -vm /home/oc14/nas_docs
```

실서비스에서는 원인을 먼저 정리한 뒤 unmount한다. `umount -l`은 마지막 수단으로만
쓴다.
