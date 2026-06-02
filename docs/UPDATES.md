# Updates

OpenClaw 업데이트는 고객 Web UI 버튼으로 처리하지 않는다. 공식 이미지를 public
registry에 올리고, 운영서버가 digest 기준으로 pull, 검증, rollout한다.

이미지에는 OpenClaw 코드, 대시보드 UI, 문서 처리 도구, locale/font 같은 실행환경만
들어간다. API key, NAS credential, gateway token, 고객 문서, slot registry, 서버별
`.env`는 이미지 밖에 둔다.

## 기본 흐름

```text
public image push
-> image-release-add
-> image-release-verify
-> image-release-promote
-> image-rollout
-> check/drift
```

기본 repository:

```text
ghcr.io/epicevent/openclaw-nas-agent
```

## Staging 적용

```bash
IMAGE_REF="ghcr.io/epicevent/openclaw-nas-agent:dashboard-20260602-r1"
IMAGE_NAME="dashboard-20260602-r1"

sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh \
  image-release-add "$IMAGE_REF" "$IMAGE_NAME"

sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh \
  image-release-verify "$IMAGE_NAME"

sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh \
  image-release-promote "$IMAGE_NAME" staging

sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh \
  image-rollout staging
```

`staging`은 기본 fallback으로 `oc1`에 적용된다. 장기 운영에서는
`/srv/openclaw-ops/slots.yaml`에 slot별 `image_channel`을 명시한다.

## 실험 slot 적용

`oc15`부터 `oc20`까지 실험 slot에 같은 이미지를 적용한다.

```bash
sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh \
  image-release-promote "$IMAGE_NAME" oc15-20-test

sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh \
  image-rollout oc15-20-test
```

## 확인

```bash
sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh image-status-all 1 20

sudo /opt/openclaw-nas-agent-baseline/scripts/openclaw-ops-drift-check.sh \
  --registry /srv/openclaw-ops/slots.yaml \
  --images /srv/openclaw-ops/images.yaml \
  --report /srv/openclaw-ops/reports/drift-latest.txt
```

slot 하나를 직접 확인한다.

```bash
sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh \
  check oc1 oc1.ji-tech.co.kr
```

## 롤백

slot 하나를 이전에 기록된 이미지로 되돌린다.

```bash
sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh image-rollback oc1
```

여러 slot에 적용한 뒤 문제가 있으면 영향을 받은 slot만 순차적으로 rollback한다.

## 세부 문서

이미지 release cache, channel, drift 판정 기준은
[Public registry 이미지 업데이트](PUBLIC_REGISTRY_IMAGES.md)를 따른다.
