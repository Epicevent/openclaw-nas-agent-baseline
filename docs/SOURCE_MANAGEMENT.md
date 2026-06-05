# Source Management

## Ownership

제품 소스는 이 운영 저장소에서 다루지 않는다. 이 저장소는 제품 source repo를
checkout하거나, 제품 UI를 빌드하거나, generated asset을 패치하지 않는다.

제품 변경은 별도 source/image lane에서 끝나야 한다.

```text
Epicevent/openclaw-jitech
  OpenClaw custom source and product image publishing

Epicevent/hermes-jitech
  Hermes Agent custom source and product image publishing

Epicevent/hermes-workspace-jitech
  Hermes Workspace custom source and product image publishing

Epicevent/openclaw-nas-agent-baseline
  host operations package
  NAS/document wrapper recipe
  slot rollout and health checks
```

이 저장소가 허용하는 입력은 이미 빌드된 runtime image digest다.

```text
allowed:
  ghcr.io/.../openclaw-product@sha256:<digest>
  ghcr.io/.../hermes-product@sha256:<digest>

not allowed:
  product source repository URL
  product source commit used as build input
  minified dist patch input
```

이미지에 source labels가 이미 들어 있다면 운영 도구가 읽어 표시할 수 있다. 그것은
감사용 메타데이터일 뿐이고, 이 저장소가 해당 source를 가져와 빌드한다는 뜻이
아니다.

## Development Flow

제품 개발은 제품 source repo에서 한다.

```text
change product source
-> product repo build/test
-> product repo publishes product runtime image
-> operations repo wraps that image with NAS/document tools if needed
-> image-release-add / verify
-> dev or staging rollout
-> customer slot rollout
```

`oc1` through `oc20` are customer slots. They must run registry images only.
They must not receive source bind mounts.

## Dev Slots

개발 확인은 별도 managed dev slot에서만 한다.

```text
dev-oc
  OpenClaw-family dev confirmation slot
  public host: dev-oc.ji-tech.co.kr

dev-hermess
  Hermes-family dev confirmation slot
  public host: dev-hermess.ji-tech.co.kr
```

`dev-oc` and `dev-hermess` are not sudo/docker accounts. They are managed like
customer accounts, with separate runtime users and data groups. The developer
account `openclawdev` owns local source checkouts and build tools.

Source mode is only valid for dev slots:

```bash
sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh dev-slot-status dev-oc
sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh source-mode-enable dev-oc
sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh source-mode-disable dev-oc
```

Running source mode against an `ocN` customer slot is a configuration error.

## Runtime Wrapper Inputs

OpenClaw-family wrapper input:

```text
base_image:
  already-built OpenClaw-family runtime image digest
```

Hermes-family wrapper input:

```text
base_image:
  already-built Hermes-family runtime image digest
```

The wrapper image adds shared NAS/HWP document tools and slot glue only. It
does not build OpenClaw, Hermes Agent, or Hermes Workspace source.

## Release Rule

An image release is acceptable only when it can answer these questions:

```text
Which product runtime image digest was wrapped?
Which operations package commit created the wrapper?
Which final wrapper image digest was published?
Which slots were rolled out?
Did browser/render checks and slot deployment checks pass?
```

The image contains code and tools only. Secrets and customer state remain
outside the image.
