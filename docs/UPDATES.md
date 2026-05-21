# Updates

OpenClaw 업데이트는 고객 Web UI 버튼으로 처리하지 않는다. 운영 업데이트는
관리자가 baseline image를 새로 빌드하고 슬롯별로 검증하면서 적용한다.

## 원칙

```text
고객:
  Web UI 사용
  자기 NAS credential 관리
  자기 NAS mount

관리자:
  OpenClaw base image 선택
  baseline image 빌드
  gateway 컨테이너 재생성
  deployment check
```

Web UI에 업데이트 배너가 보여도 고객 운영 절차로 보지 않는다. 컨테이너 image
기반 설치에서는 업데이트가 skip되거나 상태 파일/로그만 바뀔 수 있다.

## staging slot에서 검증

```bash
TARGET_USER=oc20
CONTROL_UI_HOST="$TARGET_USER.ji-tech.co.kr"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
```

업데이트 전 상태를 기록한다.

```bash
CONTAINER="openclaw-$TARGET_USER-openclaw-gateway-1"

sudo docker inspect "$CONTAINER" \
  --format 'image={{.Config.Image}} image_id={{.Image}} user={{.Config.User}} status={{.State.Status}}'

sudo docker exec "$CONTAINER" sh -lc 'openclaw --version'
```

base image를 먼저 갱신하고 버전을 확인한다. base image가 그대로면 baseline을
다시 빌드해도 OpenClaw 버전은 바뀌지 않는다.

```bash
cd /opt/openclaw-nas-agent-baseline

BASE_IMAGE=ghcr.io/openclaw/openclaw:latest

sudo docker pull "$BASE_IMAGE"
sudo docker run --rm "$BASE_IMAGE" sh -lc 'openclaw --version'
```

baseline image를 빌드한다. 운영 업데이트에서는 이전 cache를 믿지 않는다.

```bash
sudo env \
  BASE_IMAGE="$BASE_IMAGE" \
  IMAGE_TAG=openclaw-nas-agent:baseline \
  DOCKER_BUILD_PULL=1 \
  DOCKER_BUILD_NO_CACHE=1 \
  bash scripts/build-container-baseline.sh

sudo docker run --rm openclaw-nas-agent:baseline sh -lc 'openclaw --version'
```

staging slot gateway를 재생성한다.

```bash
sudo bash scripts/apply-subdomain-mode.sh \
  --user "$TARGET_USER" \
  --host "$CONTROL_UI_HOST"
```

검증한다.

```bash
sudo bash scripts/check-customer-deployment.sh \
  --user "$TARGET_USER" \
  --expected-basepath / \
  --expected-origin "https://$CONTROL_UI_HOST"
```

## 전체 슬롯 적용

staging slot이 통과한 뒤에만 순차 적용한다.

```bash
cd /opt/openclaw-nas-agent-baseline

for i in $(seq 1 20); do
  TARGET_USER="oc$i"
  CONTROL_UI_HOST="$TARGET_USER.ji-tech.co.kr"

  echo "== update $TARGET_USER =="

  sudo bash scripts/apply-subdomain-mode.sh \
    --user "$TARGET_USER" \
    --host "$CONTROL_UI_HOST"

  sudo bash scripts/check-customer-deployment.sh \
    --user "$TARGET_USER" \
    --expected-basepath / \
    --expected-origin "https://$CONTROL_UI_HOST"
done
```

## 완료 확인

모든 계정이 같은 image id와 OpenClaw 버전을 봐야 한다.

```bash
for i in $(seq 1 20); do
  u="oc$i"
  c="openclaw-$u-openclaw-gateway-1"
  printf "%-5s " "$u"
  sudo docker inspect "$c" \
    --format 'image={{.Config.Image}} image_id={{.Image}} status={{.State.Status}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}'
  sudo docker exec "$c" sh -lc 'openclaw --version | head -1'
done
```

## 롤백

롤백은 이전 baseline image tag가 있을 때만 단순하다. 운영 업데이트 전에는
이전 image id를 기록해둔다.

```bash
sudo docker image ls openclaw-nas-agent
```

현재 방식에서 `openclaw-nas-agent:baseline` tag만 덮어쓴다면, 롤백은 이전
image를 다시 tag한 뒤 같은 순차 적용 절차를 반복한다.
