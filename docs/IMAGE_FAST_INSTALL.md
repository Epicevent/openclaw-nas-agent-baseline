# Image Fast Install

이미지 기반 신규설치는 `openclaw-bootstrap`을 실행하지 않는다.

필요한 전제는 네 가지다.

```text
1. ocN Linux 계정이 있다.
2. /home/ocN/.openclaw-install.env가 있다.
3. /home/ocN/nas_docs/SHARE_NAME 하위 폴더가 고객 NAS credential로 CIFS mount되어 있다.
4. openclaw-nas-agent:baseline 이미지가 이미 빌드되어 있다.
```

설치 명령:

```bash
TARGET_USER=oc20
CONTROL_UI_HOST="$TARGET_USER.ji-tech.co.kr"

sudo bash /opt/openclaw-nas-agent-baseline/scripts/install-customer-slot-from-image.sh \
  --user "$TARGET_USER" \
  --host "$CONTROL_UI_HOST" \
  --image openclaw-nas-agent:baseline
```

이 명령이 만드는 것:

```text
/home/ocN/openclaw/docker-compose.yml
/home/ocN/openclaw/docker-compose.host-user.yml
/home/ocN/openclaw/.env
/home/ocN/.openclaw/openclaw.json
/home/ocN/.openclaw/workspace
/home/ocN/openclaw/deploy/apache-subdomain-ocN.conf
ocN_rt
ocN_data
openclaw-ocN-openclaw-gateway-1
```

이 명령이 하지 않는 것:

```text
Linux 계정 password 설정
고객 NAS credential 생성
NAS mount 수행
baseline image 빌드
운영 Apache sites-available/sites-enabled 등록
DNS/TLS 설정
```

완료 확인:

```bash
sudo bash /opt/openclaw-nas-agent-baseline/scripts/check-customer-deployment.sh \
  --user "$TARGET_USER" \
  --expected-basepath / \
  --expected-origin "https://$CONTROL_UI_HOST"
```
