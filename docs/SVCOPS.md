# svcops 운영계정

`svcops`는 고객 계정이 아니라 운영자가 쓰는 제한 계정이다. full sudo 계정이
아니며, `/opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh`만 sudo로
실행한다. Linux 계정 생성, API key 입력, Docker 이미지 설치, Apache 운영 반영처럼
root가 필요한 작업은 [root 관리자 작업](ROOT_ADMIN_TASKS.md)에서 처리한다.

## 생성

`svcops` 생성은 root 작업이다.
[root 관리자 작업 - 호스트 준비](ROOT_ADMIN_TASKS.md#호스트-준비)에서 수행한다.

`--set-password`는 SSH 로그인용 비밀번호를 설정한다. `--nopasswd-sudo`는
`svcops-control.sh` wrapper만 비밀번호 없이 실행하게 허용한다. PM2 drift monitor는
사람이 비밀번호를 입력할 수 없으므로 이 설정이 기본 운영값이다.

허용되는 것은 다음 형태뿐이다.

```bash
sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh ...
```

`sudo bash`, `sudo su`, `sudo docker` 같은 임의 root 명령은 여전히 허용하지 않는다.

## 운영자 콘솔

`svcops`로 실행하는 localhost 전용 화면이다. 서버 외부에 직접 공개하지 않고 SSH
tunnel로 접속한다.

```bash
pm2 start /opt/openclaw-nas-agent-baseline/admin-cli/bin/openclaw-ops-console \
  --name openclaw-ops-console \
  -- --host 127.0.0.1 --port 18088
```

운영자 PC에서는 다음처럼 연결한다.

```bash
ssh -L 18088:127.0.0.1:18088 svcops@SERVER
```

브라우저 주소는 `http://127.0.0.1:18088`이다. 콘솔에서 실행하는 조치는
`svcops-control.sh` wrapper로만 처리되며, 결과는
`/srv/openclaw-ops/reports/actions.log`에 JSONL로 남는다. NAS password와 API key는
이 화면에서 입력하거나 저장하지 않는다. 고객 접속용 handoff credential은
`handoff-credential` 명령으로만 출력한다.

## 역할

```text
svcops:
  고객 배포 상태 점검
  fstab user-mount 규칙 등록
  subdomain 설정 적용
  customer-mode 격리 재적용

svcops가 하지 않는 것:
  sudo bash
  sudo su
  sudo docker
  sudo cat으로 secret 읽기
  /opt/openclaw-nas-agent-baseline 수정
```

## 사용 예

`svcops`로 로그인한 뒤 실행한다.

```bash
sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh nas-status oc1

sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh nas-status-all 1 20

sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh nas-requests 1 20

sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh nas-approve-share oc1

sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh nas-verify oc1

sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh nas-verify-all 1 20

sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh nas-register \
  oc1 \
  '//NAS_HOST/SHARE_NAME'

sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh nas-register-all \
  1 \
  20 \
  '//NAS_HOST/SHARE_NAME'

sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh nas-unregister-all \
  10 \
  19 \
  SHARE_NAME \
  --unmount \
  --delete-credential \
  --delete-empty-dir

sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh usage-all 1 20 24h

sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh usage oc13 24h

sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh shared-ollama-status

sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh shared-ollama-up qwen2.5-coder:7b

sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh heartbeat-status-all 1 20

sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh heartbeat-disable-all 1 20

sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh heartbeat-ollama-all 1 20 qwen2.5-coder:7b

sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh check \
  oc1 \
  oc1.ji-tech.co.kr

sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh nas-fstab \
  oc1 \
  '//NAS_HOST/SHARE_NAME'

sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh subdomain \
  oc1 \
  oc1.ji-tech.co.kr

sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh isolation oc1
```

`nas-register`는 fstab user-mount 규칙을 등록하고, 고객 계정에서 실행할 다음
명령을 같이 출력한다. `nas-register-all`은 여러 슬롯에 같은 공유 경로를 일괄
등록한다. `nas-status`와 `nas-status-all`은 mount 대상 공유경로와 mount 상태를
보여주지만 고객 NAS password는 출력하지 않는다.

이때 공유 경로는 원격 SMB source다. 붙는 위치는 공유 이름에서 자동으로 정한다.
예를 들어 `//192.168.0.222/hanpass`는 `/home/ocN/nas_docs/hanpass`에 붙는다.
OpenClaw 컨테이너에서는 `/home/node/nas_docs/hanpass`, Hermes 컨테이너에서는
`/workspace/nas_docs/hanpass`로 보인다. 여러 NAS 공유도 같은 방식으로 공유
이름별 폴더를 추가한다.

`nas-verify`는 고객 계정의 NAS mount와 OpenClaw 컨테이너 안의 NAS mount를 실제로
비교한다. 고객 계정은 CIFS로 mounted인데 컨테이너가 아직 일반 디렉터리를 보고
있으면 gateway 컨테이너만 재생성하고 다시 확인한다.

`usage-all`과 `usage`는 최근 OpenClaw activity를 계정별로 보여준다. 기본 지표는
gateway Docker log line 수, 마지막 gateway log timestamp, 컨테이너 안의 OpenClaw
log/state/workspace 변경량이다. 로그 내용, NAS credential, gateway token,
provider/API key는 출력하지 않는다. provider별 과금량이나 token 사용량은 provider
console 또는 별도 계량 로그에서 확인한다.

`heartbeat-status-all`은 계정별 `HEARTBEAT.md`와 `openclaw.json`의 heartbeat
설정을 함께 보여준다. `HEARTBEAT.md`는 scheduler가 아니라 optional checklist다.
`heartbeat-disable-all`은 `openclaw.json`의 `agents.defaults.heartbeat.every`와
`agents.list[].heartbeat.every`를 `0m`으로 만든 뒤 gateway를 재생성한다.
`shared-ollama-up`은 공용 Ollama 컨테이너와 model store를 준비한다.
`heartbeat-ollama-all`은 heartbeat를 다시 켜고 공용 Ollama endpoint와 model을
사용하게 한다.

고객이 `openclaw-nas-mount --request-share '//NAS_HOST/SHARE_NAME'`로 요청을
만들면 `nas-requests`로 확인하고 `nas-approve-share`로 승인한다. 승인 시 fstab
user-mount 규칙만 바뀌며 고객 NAS credential은 읽거나 만들지 않는다.
요청이 있으면 `nas-requests` 출력에 바로 실행할 `approve_command`가 함께 나온다.

## 작업 범위

```text
svcops가 직접 처리:
  고객 배포 상태 점검
  fstab user-mount 규칙 등록
  고객 NAS mount 상태 확인
  subdomain 설정 재적용
  customer-mode 격리 재적용

root 관리자에게 요청:
  서버 최초 설치
  고객 Linux 계정 생성과 비밀번호 설정
  baseline 이미지 빌드
  계정별 OpenClaw 설치
  runtime secret 주입 또는 교체
  Apache 운영 site 반영
  고객 접속용 handoff credential 출력
```

## 한계

`svcops`는 root가 아니다. 하지만 break-glass root는 여전히 존재해야 한다. root는
Linux 보안 모델상 고객 credential 파일을 읽을 수 있으므로, root 접근자는 별도
감사와 최소 인원 원칙으로 관리한다.
