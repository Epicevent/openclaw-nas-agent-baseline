# svcops 운영계정

`svcops`는 고객 계정이 아니라 운영자가 쓰는 제한 계정이다. full sudo 계정이
아니며, `/opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh`만 sudo로
실행한다. Linux 계정 생성, API key 입력, Docker 이미지 설치, Apache 운영 반영처럼
root가 필요한 작업은 [root 관리자 작업](ROOT_ADMIN_TASKS.md)에서 처리한다.

## 생성

`svcops` 생성은 root 작업이다. 같은 shell 절차를 여기 다시 복붙하지 않고
[root 관리자 작업 - 호스트 준비](ROOT_ADMIN_TASKS.md#호스트-준비)를 따른다.

`--set-password`는 SSH 로그인용 비밀번호를 설정한다. `--nopasswd-sudo`는
`svcops-control.sh` wrapper만 비밀번호 없이 실행하게 허용한다. PM2 drift monitor는
사람이 비밀번호를 입력할 수 없으므로 이 설정이 기본 운영값이다.

허용되는 것은 다음 형태뿐이다.

```bash
sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh ...
```

`sudo bash`, `sudo su`, `sudo docker` 같은 임의 root 명령은 여전히 허용하지 않는다.

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

sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh nas-unregister-all 10 19

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
예를 들어 `//192.168.0.222/hanpass`는 `/home/ocN/nas_docs/hanpass`에 붙고,
OpenClaw 컨테이너에서는 `/home/node/nas_docs/hanpass`로 보인다. 여러 NAS 공유도
같은 방식으로 공유 이름별 폴더를 추가한다.

`nas-verify`는 고객 계정의 NAS mount와 OpenClaw 컨테이너 안의 NAS mount를 실제로
비교한다. 고객 계정은 CIFS로 mounted인데 컨테이너가 아직 일반 디렉터리를 보고
있으면 gateway 컨테이너만 재생성하고 다시 확인한다.

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
  Gateway token 출력
```

## 한계

`svcops`는 root가 아니다. 하지만 break-glass root는 여전히 존재해야 한다. root는
Linux 보안 모델상 고객 credential 파일을 읽을 수 있으므로, root 접근자는 별도
감사와 최소 인원 원칙으로 관리한다.
