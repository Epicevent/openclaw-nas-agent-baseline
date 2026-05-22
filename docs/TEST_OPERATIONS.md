# 테스트 운영 절차

이 문서는 다음 주 고객 테스트를 넘기기 전 운영 사고를 막기 위한 기준이다.
새 기능 개발 문서가 아니라, 기준점을 고정하고 slot 상태를 같은 방식으로 확인하기
위한 문서다.

## 원칙

```text
1. baseline을 먼저 고정한다.
2. 고객별 Docker image를 만들지 않는다.
3. 실명, 실제 subdomain, 실제 NAS share 대응표는 private 원장에만 둔다.
4. slot별 release gate를 통과한 계정만 사용자에게 넘긴다.
5. P0 보안 문제가 아니면 테스트 중 public repo를 계속 흔들지 않는다.
```

## 1. Baseline Freeze

실행 주체: **[root 관리자]**

테스트에 사용할 public repo commit과 Docker image tag를 먼저 고정한다.
`/opt/openclaw-nas-agent-baseline`은 git checkout이 아니라 `install.sh`가 만든
설치본이므로, `git pull`이나 `/opt`의 `git rev-parse`로 기준을 잡지 않는다.
기준 commit을 checkout한 임시 repo에서 `install.sh`를 실행하고, 설치본 manifest를
기준으로 삼는다.

```bash
BASELINE_COMMIT="<public repo commit>"
TEST_IMAGE_TAG="openclaw-nas-agent:baseline-test-$(date +%Y%m%d)"

TMP_REPO="$(mktemp -d)/openclaw-nas-agent-baseline"
git clone https://github.com/Epicevent/openclaw-nas-agent-baseline.git "$TMP_REPO"
cd "$TMP_REPO"
git checkout "$BASELINE_COMMIT"

sudo bash install.sh --check
sudo bash /opt/openclaw-nas-agent-baseline/scripts/install-svcops-account.sh \
  --set-password \
  --nopasswd-sudo

source /opt/openclaw-nas-agent-baseline/.openclaw-baseline-manifest

echo "baseline_commit=$BASELINE_COMMIT"
echo "installed_source_commit=$source_commit"
echo "test_image_tag=$TEST_IMAGE_TAG"
```

테스트용 image는 하나만 만든다.

```bash
sudo env \
  BASE_IMAGE=ghcr.io/openclaw/openclaw:latest \
  IMAGE_TAG="$TEST_IMAGE_TAG" \
  bash /opt/openclaw-nas-agent-baseline/scripts/build-container-baseline.sh
```

빌드 결과는 private 원장에 기록한다.

```bash
sudo docker image inspect "$TEST_IMAGE_TAG" \
  --format 'image_id={{.Id}} created={{.Created}}'
```

장기 production에서는 `BASE_IMAGE=...:latest`가 아니라 digest-pinned image와 pinned
dependency 기준이 필요하다. 테스트 freeze는 “이번 테스트에 쓸 기준을 고정한다”는
뜻이지, 장기 supply-chain hardening이 완료됐다는 뜻이 아니다.

## 2. Image 정책

다음 주 테스트는 공통 baseline image 하나로 간다.

```text
하는 것:
  openclaw-nas-agent:baseline-test-YYYYMMDD 하나를 모든 테스트 slot에 사용

하지 않는 것:
  oc13 전용 image
  oc14 전용 image
  고객별 dashboard/subdomain/NAS 때문에 image rebuild
```

image 변경이 필요한 경우는 실행환경 자체가 바뀌는 경우뿐이다.

```text
image 변경 사유:
  문서 처리 도구 추가
  HWP/OCR/LibreOffice/Python package 변경
  OpenClaw runtime 자체 변경

image 변경 사유 아님:
  subdomain 변경
  dashboard 표시명 변경
  NAS share 변경
  사용자 변경
  provider/API key 변경
```

## 3. Private Slot 원장

실명과 실제 대응표는 public repo에 넣지 않는다. private 위치에 `slots.yaml` 또는
`slots.xlsx`로 관리한다.

예시 구조:

```yaml
baseline:
  repo: Epicevent/openclaw-nas-agent-baseline
  baseline_commit: "<git rev-parse HEAD>"
  image_tag: "openclaw-nas-agent:baseline-test-YYYYMMDD"
  frozen_at: "YYYY-MM-DDTHH:MM:SS+09:00"

slots:
  - person: "<private>"
    user: "oc13"
    subdomain: "oc13.example.com"
    nas_share: "//NAS_HOST/SHARE_NAME"
    mount_name: "SHARE_NAME"
    dashboard_name: "<private>"
    image_tag: "openclaw-nas-agent:baseline-test-YYYYMMDD"
    status: "reserved"
    notes: ""
```

상태값은 좁게 유지한다.

```text
reserved
nas_registered
mounted
container_visible
installed
secret_injected
verified
active_test
paused
revoked
```

## 4. 테스트 Slot 범위

처음 테스트는 2~3개 slot만 확정한다.

```text
권장:
  기준 slot 1개
  실제 테스트 사용자 1~2개
```

테스트 대상자 수, 각 대상자 `ocN`, subdomain, NAS share는 private 원장에 먼저
고정한다. 확정되지 않은 slot을 미리 사용자에게 넘기지 않는다.

## 5. Slot Release Gate

사용자에게 넘기기 전 각 slot은 같은 기준을 통과해야 한다.

실행 주체: **[root 관리자]**

```bash
TARGET_USER=oc13
CONTROL_UI_HOST="$TARGET_USER.ji-tech.co.kr"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"

pgrep -u "$TARGET_USER" -a || echo "no_active_customer_process"
id "$TARGET_USER"
```

실행 주체: **[운영계정: svcops]**

```bash
sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh nas-status "$TARGET_USER"
sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh nas-verify "$TARGET_USER"
```

실행 주체: **[root 관리자]**

```bash
sudo bash /opt/openclaw-nas-agent-baseline/scripts/check-customer-deployment.sh \
  --user "$TARGET_USER" \
  --expected-basepath / \
  --expected-origin "https://$CONTROL_UI_HOST"
```

통과 기준:

```text
ocN 계정 존재
ocN이 docker/sudo group에 없음
subdomain이 해당 slot gateway로 연결
OpenClaw allowedOrigins가 해당 subdomain
fstab rule 등록
active CIFS mount 확인
container에서 NAS visibility 확인
runtime secret 필요 시 주입 완료
deployment check 통과
```

웹이 뜨는 것만으로는 release gate 통과가 아니다.

## 6. 커스텀 분류

테스트 중 요청은 같은 층위로 취급하지 않는다.

```text
subdomain 변경:
  보안/라우팅 변경
  Apache + OpenClaw allowedOrigins + private 원장 갱신 필요

dashboard 표시명 변경:
  UX 변경
  권한 경계 변경 아님

NAS 변경:
  데이터 접근 권한 변경
  fstab + credential + mount + container visibility 검증 필요

image 변경:
  실행환경 변경
  이번 테스트 중 원칙적으로 금지
```

## 7. 중단 기준

아래는 품질 이슈가 아니라 보안 이슈다. 발견 즉시 테스트를 멈춘다.

```text
다른 사용자의 NAS가 보임
잘못된 subdomain이 다른 slot으로 연결됨
고객 계정이 docker/sudo 권한을 가짐
runtime secret/config를 고객이 읽을 수 있음
turnover 후 이전 NAS/session이 남음
```

아래는 기록하고 계속 테스트할 수 있다.

```text
응답 느림
문서 일부 못 읽음
요약 품질 낮음
UI 문구 이상함
```

## 8. 월요일 오전 검증 순서

```text
1. private 원장의 baseline commit/image tag 확인
2. 기준 slot deployment check
3. 테스트 slot 설치 또는 상태 확인
4. NAS mount 확인
5. container visibility 확인
6. subdomain 접속 확인
7. runtime secret 주입 여부 확인
8. private 원장 상태 갱신
9. 사용자 전달
```

## 9. Drift Check

`slots.yaml`은 선언된 운영 상태이고, 서버는 실제 상태다. 둘이 같다고 믿지
않고 주기적으로 비교한다.

read-only drift checker:

```bash
/opt/openclaw-nas-agent-baseline/scripts/openclaw-ops-drift-check.sh \
  --registry /srv/openclaw-ops/slots.yaml \
  --report /srv/openclaw-ops/reports/drift-latest.txt
```

`install.sh`는 `/opt/openclaw-nas-agent-baseline/.openclaw-baseline-manifest`를 쓴다.
drift checker는 이 manifest의 `source_commit`과 `slots.yaml`의 `baseline_commit`도
비교한다. 즉 원장의 기준 commit과 서버에 실제 설치된 `/opt` 배포본이 다르면 fail이다.

PM2 상시 감시는 `svcops` 계정으로 실행한다. root PM2가 아니라 `svcops` PM2가
`svcops-control.sh` wrapper를 호출하는 구조다.

이 감시는 사람이 비밀번호를 입력할 수 없으므로 `svcops` sudoers는
`svcops-control.sh` wrapper에 대해 `NOPASSWD`여야 한다. 계정 생성 시 다음 형태를
사용한다.

```bash
sudo bash /opt/openclaw-nas-agent-baseline/scripts/install-svcops-account.sh --set-password --nopasswd-sudo
```

이 설정은 wrapper만 passwordless로 허용한다. full sudo, Docker 직접 실행, 임의 root
shell을 허용하는 설정이 아니다.

```text
process name:
  openclaw-ops-drift

report:
  /srv/openclaw-ops/reports/drift-latest.txt

check interval:
  기본 900초
```

비교하는 핵심 항목:

```text
release gate PASS 여부
registry의 NAS share와 실제 host/container CIFS source 일치 여부
registry의 mount_name과 실제 mountpoint 일치 여부
registry의 image_id와 실제 container image id 일치 여부
```

`last_gate`는 과거 검증 기록이고, drift check는 현재 상태 검증이다.
