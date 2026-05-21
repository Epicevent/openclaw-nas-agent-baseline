# svcops 운영계정

`svcops`는 고객 계정이 아니라 운영자가 쓰는 제한 계정이다. full sudo 계정이
아니며, `/opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh`만 sudo로
실행한다.

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

## 한계

`svcops`는 root가 아니다. 하지만 break-glass root는 여전히 존재해야 한다. root는
Linux 보안 모델상 고객 credential 파일을 읽을 수 있으므로, root 접근자는 별도
감사와 최소 인원 원칙으로 관리한다.
