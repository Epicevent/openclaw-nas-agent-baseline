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

테스트에 사용할 public repo commit과 공식 image release를 먼저 고정한다. 서버 반영은
[root 관리자 작업 - 호스트 준비](ROOT_ADMIN_TASKS.md#호스트-준비)의 공식 절차만 따른다.
여기서는 서버에 설치된 manifest 값을 테스트 기준으로 기록한다.

```bash
source /opt/openclaw-nas-agent-baseline/.openclaw-baseline-manifest
BASELINE_COMMIT="$source_commit"

echo "baseline_commit=$BASELINE_COMMIT"
echo "installed_source_commit=$source_commit"
```

테스트용 image는 public registry release 중 하나를 고른다. 서버에서 직접 rebuild하지
않는다.

```bash
sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh image-list
```

테스트 freeze는 “이번 테스트에 쓸 repo commit과 image digest를 고정한다”는 뜻이다.

## 2. Image 정책

다음 주 테스트는 검증된 공식 image release 하나를 기준으로 간다.

```text
하는 것:
  images.yaml에 등록되고 verify를 통과한 official image를 slot에 적용

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

실명과 실제 대응표는 public repo에 넣지 않는다. 서버의 private 원장을 기준으로
관리한다.

```text
원장 파일: /srv/openclaw-ops/slots.yaml
소유권:    root:svcops
권한:      0640
역할:      oc1~oc20 slot의 실제 배정 상태
```

이 파일은 새로 복사해서 만들지 않는다. 호스트 준비 단계에서 생성된 oc1~oc20
골격을 유지하고, 대상자가 생길 때 해당 slot entry의 값만 바꾼다.

원장에 저장하는 값:

```text
assignee:       테스트 대상자 식별명 또는 내부 코드
status:         ready / assigned / active_test 등 현재 상태
subdomain:      고객에게 넘길 실제 URL host
nas_share:      등록된 SMB 공유 경로
mount_name:     nas_docs 아래에 붙는 폴더명
dashboard_name: 화면에 표시할 이름
image_tag:      해당 slot이 쓰는 baseline image tag
last_gate:      마지막 release gate 결과와 시각
handoff:        SSH/token/URL 전달 상태
notes:          secret이 아닌 운영 메모
```

원장에 저장하지 않는 값:

```text
SSH password
고객 접속용 handoff credential 원문
NAS password
provider/API key
```

고객 접속용 handoff credential은 원장에 넣지 않는다. 조회가 필요하면
`svcops-control.sh handoff-credential ocN`을 사용한다.

상태값은 현재 운영 상태를 헷갈리지 않을 만큼만 둔다.

```text
ready
assigned
active_test
paused
revoked
turnover_needed
```

기본 전이는 아래처럼 본다.

```text
ready
→ assigned
→ release gate pass
→ handoff issued
→ active_test

revoked
→ turnover_needed
→ turnover 완료
→ ready
```

`active_test`는 접근권을 실제로 넘긴 뒤에만 쓴다. 원장에 대상자 이름만 적은
상태는 `assigned`다.

## 4. 대상자 배정

전체 slot 범위는 oc1~oc20이다. 특정 번호만 테스트용으로 고정하지 않는다.
처음 외부 전달 batch를 작게 가져가는 것은 운영 리스크를 낮추기 위한 선택일 뿐,
시스템의 slot 범위를 줄인다는 뜻이 아니다.

대상자를 넣을 때는 먼저 `ready` 상태인 slot을 고른다.

```text
확인할 것:
  status가 ready인가
  subdomain이 실제 전달할 host와 맞는가
  nas_share와 mount_name이 이번 대상자에게 맞는가
  image_tag가 freeze한 테스트 image와 맞는가
  last_gate가 너무 오래된 값이면 다시 gate를 돌릴 준비가 되어 있는가
```

배정 시 바꾸는 값은 보통 아래뿐이다.

```text
assignee
status: assigned
dashboard_name
notes
nas_share / mount_name, NAS가 기본값과 다를 때만
subdomain, 기본 ocN.ji-tech.co.kr이 아닐 때만
```

배정만 했다고 사용자에게 넘기지 않는다. release gate가 통과하고 SSH/token/URL
전달 상태를 기록한 뒤에만 `active_test`로 올린다.

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

실행 주체: **[운영계정: svcops] 또는 [root 관리자]**

```bash
sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh check \
  "$TARGET_USER" \
  "$CONTROL_UI_HOST"
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
/opt/openclaw-nas-agent-baseline/scripts/ops-monitor.sh drift-check \
  --registry /srv/openclaw-ops/slots.yaml \
  --report /srv/openclaw-ops/reports/drift-latest.txt
```

`install.sh`는 `/opt/openclaw-nas-agent-baseline/.openclaw-baseline-manifest`를 쓴다.
drift checker는 이 manifest의 `source_commit`과 `slots.yaml`의 `baseline_commit`도
비교한다. 즉 원장의 기준 commit과 서버에 실제 설치된 `/opt` 배포본이 다르면 fail이다.

PM2 상시 감시는 `svcops` 계정으로 실행한다. root PM2가 아니라 `svcops` PM2가
`svcops-control.sh` wrapper를 호출하는 구조다.

이 감시는 사람이 비밀번호를 입력할 수 없으므로 `svcops` sudoers는
`svcops-control.sh` wrapper에 대해 `NOPASSWD`여야 한다. 이 설정은
[root 관리자 작업 - 호스트 준비](ROOT_ADMIN_TASKS.md#호스트-준비)에서만 관리한다.

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
