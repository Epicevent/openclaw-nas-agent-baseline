# 테스트 운영 절차

이 문서는 테스트 slot을 실제 사용자에게 넘기기 전 확인 기준이다.

## 기준 파일

```text
/srv/openclaw-ops/slots.yaml
  slot -> lane만 기록한다.

/srv/openclaw-ops/images.yaml
  public registry image release와 digest를 기록한다.

/srv/openclaw-ops/nas-policy.yaml
  계정별 NAS 자동승인 grant를 기록한다.
```

사용자 실명, NAS password, API key, gateway token은 이 파일들에 저장하지 않는다.

## Lane

```text
oc1~oc14     openclaw
oc15~oc20    hermes
dev-oc       dev-openclaw
dev-hermess  dev-hermes
```

`oc1~oc20`은 image-only 고객 slot이다. dev lane은 고객 전달 대상이 아니다.

## NAS 요청 처리

고객은 자기 계정에서 요청을 만든다.

```bash
agent-nas-mount --request-share '//NAS_HOST/SHARE'
```

운영 자동승인:

```bash
sudo /opt/openclaw-nas-agent-baseline/scripts/ops-monitor.sh nas-request-check
```

상시 감시:

```bash
sudo -u svcops pm2 start /opt/openclaw-nas-agent-baseline/scripts/ops-monitor.sh \
  --name openclaw-nas-requests \
  -- nas-request-watch
```

자동승인은 fstab 등록까지만 처리한다. NAS credential 입력과 실제 mount는 고객
계정에서 수행한다.

## Health Check

```bash
sudo /opt/openclaw-nas-agent-baseline/scripts/ops-monitor.sh health-check \
  --report /srv/openclaw-ops/reports/health-latest.txt
```

상시 감시:

```bash
sudo -u svcops pm2 start /opt/openclaw-nas-agent-baseline/scripts/ops-monitor.sh \
  --name openclaw-ops-health \
  -- health-watch
```

health check는 live 상태를 본다.

```text
release gate
container image
customer NAS mount
container NAS visibility
customer slot source mode 금지 여부
```

## 사용자 전달 전 확인

```bash
sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh check oc15 oc15.ji-tech.co.kr
sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh nas-verify oc15
sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh image-status oc15
sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh runtime-secret-status oc15
```

다음 중 하나라도 발생하면 전달하지 않는다.

```text
다른 slot의 NAS가 보임
container에서 NAS가 보이지 않음
고객 계정이 sudo/docker 권한을 가짐
source mode가 고객 slot에 켜짐
runtime secret/config를 고객 계정이 읽을 수 있음
expected image와 running image가 다름
```

## Image Rollout

이미지 변경은 `/srv/openclaw-ops/images.yaml`에 등록된 release만 사용한다.

```bash
sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh image-release-add REF NAME
sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh image-release-verify NAME
sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh image-release-promote NAME hermes
sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh image-rollout hermes
```

`image-rollout openclaw`은 lane이 `openclaw`인 고객 slot만 대상으로 한다.
`image-rollout hermes`는 lane이 `hermes`인 고객 slot만 대상으로 한다.
