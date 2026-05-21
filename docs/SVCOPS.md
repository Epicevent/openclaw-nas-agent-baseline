# svcops 운영계정

`svcops`는 고객 계정이 아니라 운영자가 쓰는 제한 계정이다. full sudo 계정이
아니며, `/opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh`만 sudo로
실행한다. Linux 계정 생성, API key 입력, Docker 이미지 설치, Apache 운영 반영처럼
root가 필요한 작업은 [root 관리자 작업](ROOT_ADMIN_TASKS.md)에서 처리한다.

## 생성

root 또는 break-glass 관리자 계정에서 실행한다.

```bash
cd "$(mktemp -d)"
git clone https://github.com/Epicevent/openclaw-nas-agent-baseline.git
cd openclaw-nas-agent-baseline

sudo bash install.sh
sudo bash /opt/openclaw-nas-agent-baseline/scripts/install-svcops-account.sh --set-password
```

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

sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh nas-verify oc1

sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh nas-verify-all 1 20

sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh nas-register \
  oc1 \
  '//NAS_HOST/SHARE_NAME'

sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh nas-register-all \
  1 \
  20 \
  '//NAS_HOST/SHARE_NAME'

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

`nas-verify`는 고객 계정의 NAS mount와 OpenClaw 컨테이너 안의 NAS mount를 실제로
비교한다. 고객 계정은 CIFS로 mounted인데 컨테이너가 아직 일반 디렉터리를 보고
있으면 gateway 컨테이너만 재생성하고 다시 확인한다.

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
  .openclaw-install.env 작성
  baseline 이미지 빌드
  계정별 OpenClaw 설치
  Apache 운영 site 반영
  Gateway token 출력
```

## 한계

`svcops`는 root가 아니다. 하지만 break-glass root는 여전히 존재해야 한다. root는
Linux 보안 모델상 고객 credential 파일을 읽을 수 있으므로, root 접근자는 별도
감사와 최소 인원 원칙으로 관리한다.
