# Updates

OpenClaw NAS Agent updates are handled by replacing slot images from the public
registry. Images contain code, UI, document tools, fonts, and locale packages.
They do not contain API keys, NAS credentials, gateway tokens, customer
documents, slot registries, or server `.env` files.

Default image repository:

```text
ghcr.io/epicevent/openclaw-nas-agent
```

## Flow

```text
public image push
-> image-release-add
-> image-release-verify
-> image-release-promote
-> image-rollout
-> check/drift
```

## Add And Verify One Image

```bash
IMAGE_REF="ghcr.io/epicevent/openclaw-nas-agent:dashboard-20260602-r1"
IMAGE_NAME="dashboard-20260602-r1"

sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh \
  image-release-add "$IMAGE_REF" "$IMAGE_NAME"

sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh \
  image-release-verify "$IMAGE_NAME"
```

## Apply To Staging

`staging` targets `oc1` when no explicit slot channel is set.

```bash
sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh \
  image-release-promote "$IMAGE_NAME" staging

sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh \
  image-rollout staging
```

## Apply To Experimental Slots

`oc15-20-test` targets `oc15` through `oc20` when no explicit slot channel is
set.

```bash
sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh \
  image-release-promote "$IMAGE_NAME" oc15-20-test

sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh \
  image-rollout oc15-20-test
```

## Apply To A Range

```bash
sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh \
  image-rollout-range 1 20 "$IMAGE_NAME"
```

## Check

```bash
sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh image-status-all 1 20

sudo /opt/openclaw-nas-agent-baseline/scripts/openclaw-ops-drift-check.sh \
  --registry /srv/openclaw-ops/slots.yaml \
  --images /srv/openclaw-ops/images.yaml \
  --report /srv/openclaw-ops/reports/drift-latest.txt

sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh \
  check oc1 oc1.ji-tech.co.kr
```

## Rollback

```bash
sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh image-rollback oc1
```

## Hermes Slots

Hermes images use the same image release commands. Applying a `family=hermes`
image creates one integrated container in the target slot:

```text
openclaw-gateway
```

That container runs Hermes Agent and Hermes Workspace together. The public
subdomain points to Workspace on container port `3000`. Hermes Agent API and the
raw Hermes dashboard remain container-local. The Workspace login password is
slot-local server secret state, not image metadata.

```text
/srv/openclaw-ops/reports/hermes-workspace-ocN.password
```

For more detail, see [Public Registry Image Updates](PUBLIC_REGISTRY_IMAGES.md).
