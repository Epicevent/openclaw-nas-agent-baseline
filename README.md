# AI Agent Slot Operations

이 저장소는 제품 소스 저장소가 아니라 서버 운영 패키지다.

담당 범위는 다음이다.

```text
host install
svcops/root wrapper
NAS mount 운영
public registry image release / rollout
slot health check
operator console
```

담당하지 않는 것은 다음이다.

```text
OpenClaw/Hermes 제품 소스 개발
고객별 secret 저장
NAS 문서 저장
고객 slot 안에서 source 개발
host에서 제품 런타임 도구 설치
```

OpenClaw와 Hermes 커스터마이즈는 별도 제품 소스 저장소에서 개발한다. 이 운영
패키지는 그 소스 commit으로 발행된 public registry image를 서버 slot에 적용하고
검증한다.

## 실행 주체

```text
root 관리자
  서버 초기 준비, Linux 계정 생성, runtime secret 주입, Apache 반영, slot 설치/갱신.

svcops
  제한 운영 계정. sudo로 svcops-control.sh wrapper만 실행한다.

ocN
  고객 계정. sudo/docker 권한이 없고 자기 NAS credential만 직접 입력한다.

dev-oc / dev-hermess
  개발 확인용 slot. 고객 계정과 같은 권한 모델이지만 source mode만 허용된다.

openclawdev
  개발자/build 계정. 제품 소스 수정과 image build를 담당한다.
```

## 운영 상태 파일

```text
/srv/openclaw-ops/slots.yaml
  slot -> lane만 기록한다.

/srv/openclaw-ops/images.yaml
  public registry image ref, digest, source ref, channel 상태를 기록한다.

/srv/openclaw-ops/nas-policy.yaml
  계정별 NAS 자동승인 grant 정책을 기록한다.

/srv/openclaw-ops/reports/actions.log
  운영 조치 감사 로그를 기록한다.
```

`slots.yaml`에는 NAS password, API key, gateway token, 고객 문서, handoff 값,
release gate 기록, 기대 NAS share를 저장하지 않는다.

## Host Install

서버 설치본 기준은 manifest의 `source_commit`이다.

```text
/opt/openclaw-nas-agent-baseline/.openclaw-baseline-manifest
```

host 설치 절차는 [root 관리자 작업](docs/ROOT_ADMIN_TASKS.md)에만 둔다. README는
일상 운영 기준과 책임 범위만 설명한다.

`install.sh`는 운영 패키지만 설치한다. 제품 source, customer slot, runtime image,
recovery state는 설치 단계에서 건드리지 않는다.

## NAS 자동승인

고객 슬롯과 개발 슬롯은 자기 계정에서 NAS mount 요청을 만든다.

```bash
agent-nas-mount --request-share '//NAS_HOST/SHARE'
```

운영 자동승인은 `/srv/openclaw-ops/nas-policy.yaml`의 계정별 grant만 본다.
범위 안이면 fstab managed entry를 자동 등록하고, 범위 밖이면 request를
rejected로 이동한다. NAS username/password는 해당 Linux 계정에서 직접 입력한다.

```bash
sudo /opt/openclaw-nas-agent-baseline/scripts/ops-monitor.sh nas-request-check
```

상시 감시는 `svcops` PM2에서 실행한다.

```text
process: openclaw-nas-requests
command: ops-monitor.sh nas-request-watch
```

정책 형식은 [NAS Policy](docs/NAS_POLICY.md)를 따른다.

## Health Check

`health-check`는 lane 저장소, image catalog, live server 상태를 읽어 현재 상태를
확인한다. NAS 상태는 `slots.yaml`의 기대값과 비교하지 않고 실제
fstab/mount/container visibility를 본다.

```bash
sudo /opt/openclaw-nas-agent-baseline/scripts/ops-monitor.sh health-check \
  --report /srv/openclaw-ops/reports/health-latest.txt
```

관리 화면은 `health-latest.txt`, `images.yaml`, live wrapper 결과를 묶어서 보여준다.

## Image Rollout

고객 slot인 `oc1~oc20`은 image-only로 운영한다. source mount는 금지한다.

```text
oc1~oc14   lane=openclaw
oc15~oc20  lane=hermes
```

이미지는 public registry에서 pull하고 digest 기준으로 검증한다.

```text
image-release-add
image-release-verify
image-release-promote
image-rollout
image-rollback
```

자세한 절차는 [Updates](docs/UPDATES.md)를 따른다.

## Dev Slot

개발 확인은 고객 slot에서 하지 않는다.

```text
dev-oc       OpenClaw source mode 확인
dev-hermess  Hermes source mode 확인
```

dev slot에서 확인한 source commit으로 image를 발행하고, 그 image만 고객 slot에
rollout한다. source/image 경계는 [Source Management](docs/SOURCE_MANAGEMENT.md)를
따른다.

## 보안 기준

```text
고객 계정은 sudo/docker 권한이 없어야 한다.
고객 slot은 registry image digest만 바라봐야 한다.
dev slot 요청은 NAS 자동승인 대상이 아니다.
root/admin 작업 중 고객 active session이 있으면 안 된다.
secret 원문은 slots.yaml, images.yaml, actions.log에 저장하지 않는다.
```
