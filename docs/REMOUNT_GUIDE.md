# NAS 리마운트 가이드

## 전체 oc1~oc20 리마운트

```bash
for i in $(seq 1 20); do
  u="oc$i"

  echo "remounting $u"

  sudo umount "/home/$u/nas_docs" 2>/dev/null || true

  sudo mkdir -p "/home/$u/nas_docs"
  sudo chown "$u:$u" "/home/$u/nas_docs"
  sudo chmod 700 "/home/$u/nas_docs"

  sudo mount -t cifs //192.168.0.222/hanpass "/home/$u/nas_docs" \
    -o credentials=/etc/samba/hanpass.cred,uid=$(id -u "$u"),gid=$(id -g "$u"),forceuid,forcegid,ro,file_mode=0400,dir_mode=0700,iocharset=utf8,vers=3.1.1,sec=ntlmssp
done
```

## 특정 계정만 리마운트

```bash
u="oc14"

sudo umount "/home/$u/nas_docs" 2>/dev/null || true

sudo mkdir -p "/home/$u/nas_docs"
sudo chown "$u:$u" "/home/$u/nas_docs"
sudo chmod 700 "/home/$u/nas_docs"

sudo mount -t cifs //192.168.0.222/hanpass "/home/$u/nas_docs" \
  -o credentials=/etc/samba/hanpass.cred,uid=$(id -u "$u"),gid=$(id -g "$u"),forceuid,forcegid,ro,file_mode=0400,dir_mode=0700,iocharset=utf8,vers=3.1.1,sec=ntlmssp
```

## 확인

```bash
findmnt -T /home/oc14/nas_docs
stat -c '%a %A %U:%G %n' /home/oc14/nas_docs
sudo su - oc14
cd ~/nas_docs
ls
exit
```

## 다른 계정 접근 차단 확인

```bash
sudo su - oc15
ls /home/oc14/nas_docs
exit
```

정상이라면 `Permission denied`가 나와야 한다.

## busy 처리

```bash
sudo fuser -vm /home/oc14/nas_docs
sudo umount -l /home/oc14/nas_docs
```

## credentials 재입력

```bash
sudo bash -c '
install -d -m 0755 /etc/samba
umask 077
read -rp "CIFS username: " u
read -rsp "CIFS password: " p
echo
printf "username=%s\npassword=%s\n" "$u" "$p" > /etc/samba/hanpass.cred
chown root:root /etc/samba/hanpass.cred
chmod 600 /etc/samba/hanpass.cred
'
```
