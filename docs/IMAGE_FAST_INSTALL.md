# Image Fast Install

이미지 기반 신규설치는 `openclaw-bootstrap`을 실행하지 않는다.

필요한 전제는 세 가지다.

```text
1. ocN Linux 계정이 있다.
2. /home/ocN/nas_docs/SHARE_NAME 하위 폴더가 고객 NAS credential로 CIFS mount되어 있다.
3. openclaw-nas-agent:baseline 이미지가 이미 빌드되어 있다.
```

fresh install은 provider/API key 없이 완료할 수 있어야 한다. key 주입과 교체는
설치 이후 `apply-runtime-secrets.sh`로 별도 처리한다. legacy install-env import는
production fresh install 경로에서 자동 실행되지 않는다.

또한 image fast install은 workspace recovery를 자동 실행하지 않는다. 기본
workspace 파일 seed, snapshot restore, workspace NAS symlink 재생성은
`scripts/recovery/` 아래의 명시적 recovery 절차에서만 수행한다.

따라서 image fast install의 `--check`는 구조 smoke check다. provider/API key까지
포함한 final check는 runtime secret 주입 후 `apply-runtime-secrets.sh --check`에서
수행한다.

설치 명령:

```bash
TARGET_USER=oc20
CONTROL_UI_HOST="$TARGET_USER.ji-tech.co.kr"

sudo bash /opt/openclaw-nas-agent-baseline/scripts/install-customer-slot-from-image.sh \
  --user "$TARGET_USER" \
  --host "$CONTROL_UI_HOST" \
  --image openclaw-nas-agent:baseline
```

provider/API key를 주입하거나 교체할 때:

```bash
sudo install -o root -g root -m 0600 /dev/null "/root/openclaw-runtime-secrets.$TARGET_USER.env"
sudo editor "/root/openclaw-runtime-secrets.$TARGET_USER.env"

# 예:
# GEMINI_API_KEY=...

sudo bash /opt/openclaw-nas-agent-baseline/scripts/apply-runtime-secrets.sh \
  --user "$TARGET_USER" \
  --host "$CONTROL_UI_HOST" \
  --env-file "/root/openclaw-runtime-secrets.$TARGET_USER.env" \
  --check
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
