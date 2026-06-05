# Updates

Slot runtime updates are image rollouts from the public registry.
Images contain code, UI, document tools, fonts, and locale packages. They do
not contain API keys, NAS credentials, gateway tokens, customer documents,
slot registries, or server `.env` files.

Default image repository:

```text
ghcr.io/epicevent/openclaw-nas-agent
```

## Standard Flow

```text
public image push
-> image-release-add
-> image-release-verify
-> image-release-promote
-> image-rollout
-> check/health
```

Use the exact public registry tag that was published for the release. The tag
is a human label; the server records and verifies the pulled digest.

```bash
IMAGE_REF="ghcr.io/epicevent/openclaw-nas-agent:hermes-workspace-20260603-r16"
IMAGE_NAME="hermes-workspace-20260603-r16"

sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh \
  image-release-add "$IMAGE_REF" "$IMAGE_NAME"

sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh \
  image-release-verify "$IMAGE_NAME"
```

`image-release-add` stores the release metadata in `/srv/openclaw-ops/images.yaml`.
The operations repo registers and rolls out already-built runtime images by digest.
If an image already has source labels, they are recorded only as audit metadata.
They are not build inputs for this repo.

```text
family
source_repo
source_ref
base_image
registry_ref
runtime_ref
digest
image_id
status
```

For Hermes images, the catalog records `family=hermes` and the wrapped base
image. Source metadata can be displayed if the product image provides labels.

```text
agent_source_repo
agent_source_ref
workspace_source_repo
workspace_source_ref
```

## Rollout

`staging` targets `oc1` when no explicit slot channel is set.

```bash
sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh \
  image-release-promote "$IMAGE_NAME" staging

sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh \
  image-rollout staging
```

`oc15-20-test` targets `oc15` through `oc20` when no explicit slot channel is
set.

```bash
sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh \
  image-release-promote "$IMAGE_NAME" oc15-20-test

sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh \
  image-rollout oc15-20-test
```

For a direct range:

```bash
sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh \
  image-rollout-range 1 20 "$IMAGE_NAME"
```

## Check And Rollback

```bash
sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh image-status-all 1 20

sudo /opt/openclaw-nas-agent-baseline/scripts/ops-monitor.sh health-check \
  --registry /srv/openclaw-ops/slots.yaml \
  --images /srv/openclaw-ops/images.yaml \
  --report /srv/openclaw-ops/reports/health-latest.txt

sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh \
  check oc1 oc1.ji-tech.co.kr
```

```bash
sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh image-rollback oc1
```

## Image Recipes

The host operations package does not build product source. Public image
publishing here only wraps already-built runtime images with shared NAS/HWP
document tools.

OpenClaw/Hermes customization source is not maintained as post-build asset
patches in this repository. Product source and product images are handled by
their own repositories; see [Source Management](SOURCE_MANAGEMENT.md).

Currently active recipes:

```text
images/hermes-workspace/     Hermes-family runtime wrapper
images/shared/               document tooling shared by official images
images/openclaw-nas-agent/   OpenClaw-family runtime wrapper
```

Publishing workflows are separated by runtime family:

```text
publish-openclaw-nas-agent-image.yml
publish-hermes-nas-agent-image.yml
```

One-off overlay directories and per-customer image artifacts do not stay in
this repository. A published image becomes usable only after it is added,
verified, promoted, and rolled out by the commands above.
