# Updates

OpenClaw NAS Agent updates are image rollouts from the public registry.
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
For OpenClaw source-built images, the catalog includes:

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

For Hermes images, the catalog records `family=hermes`, the Hermes Agent base
image, the Hermes Agent source ref that matches that base, and the Hermes
Workspace source ref that was built into the final image.

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

The host operations package does not build images during normal server
operation. Public image publishing is handled by workflow-dispatched image
recipes under `images/`.

OpenClaw customization source is not maintained as post-build asset patches in
this repository. OpenClaw images are built from a managed custom source commit;
see [Source Management](SOURCE_MANAGEMENT.md).

Currently active recipes:

```text
images/hermes-workspace/     Hermes Agent base + Workspace source integrated image
images/shared/               document tooling shared by official images
images/openclaw-nas-agent/   base wrapper for OpenClaw-compatible images
```

Publishing workflows are separated by runtime family:

```text
publish-openclaw-nas-agent-image.yml
publish-hermes-nas-agent-image.yml
```

One-off overlay directories and per-customer image artifacts do not stay in
this repository. A published image becomes usable only after it is added,
verified, promoted, and rolled out by the commands above.
