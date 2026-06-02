# Public Registry Image Updates

OpenClaw NAS Agent images are distributed from a public Docker registry.
Images contain runtime code, dashboard UI, document tooling, fonts, and locale
packages. They must not contain API keys, NAS credentials, gateway tokens,
customer documents, slot registries, or host `.env` files.

Default image repository:

```text
ghcr.io/epicevent/openclaw-nas-agent
```

Example official image tags:

```text
ghcr.io/epicevent/openclaw-nas-agent:baseline-20260522
ghcr.io/epicevent/openclaw-nas-agent:dashboard-20260602-r1
ghcr.io/epicevent/openclaw-nas-agent:document-heavy-20260602-r1
```

## Release Flow

Run as the restricted operations account through `svcops-control.sh`.

```bash
sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh \
  image-release-add ghcr.io/epicevent/openclaw-nas-agent:dashboard-20260602-r1

sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh \
  image-release-verify dashboard-20260602-r1

sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh \
  image-release-promote dashboard-20260602-r1 staging

sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh \
  image-rollout staging
```

The release cache is stored in:

```text
/srv/openclaw-ops/images.yaml
```

This file records public image refs, immutable runtime refs, image ids, status,
and channel assignments. It is private operations state, but it must not contain
secrets.

## Channels

```text
default       stable baseline slots
staging       oc1 validation
oc15-20-test  experimental rollout slots
production    customer-facing rollout after approval
```

`image-rollout staging` targets `oc1` when no explicit channel fields are present
in `slots.yaml`.

`image-rollout oc15-20-test` targets `oc15` through `oc20` when no explicit
channel fields are present in `slots.yaml`.

For precise long-term operation, set each slot in `/srv/openclaw-ops/slots.yaml`
with:

```yaml
image_channel: "oc15-20-test"
image_name: "dashboard-20260602-r1"
```

Existing fields such as `image_tag` are still read for compatibility.

## Slot Commands

Apply one official image to one slot:

```bash
sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh \
  image-rollout-slot oc15 dashboard-20260602-r1
```

Apply one official image to a slot range:

```bash
sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh \
  image-rollout-range 1 20 dashboard-20260602-r1
```

This is the explicit full-slot operation. It still requires the image to be
registered and verified first.

Check running images:

```bash
sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh image-status oc15
sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh image-status-all 15 20
```

Rollback one slot to the previous recorded image:

```bash
sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh image-rollback oc15
```

## Verification Rules

`image-release-verify` pulls the public image and checks:

```text
image is pullable
image id and digest are recorded
no secret-looking runtime env value is baked into the image
document baseline commands exist
Korean locale and fonts exist
Python document modules exist
```

Images that fail verification are marked `failed` and cannot be rolled out.

## Drift

Drift check resolves the expected image in this order:

```text
slot image_name
slot image_channel
legacy slot image_tag
meta.image_id fallback
```

It then compares the expected image id or digest with the running gateway
container. A slot running an image not listed in the public image release cache
is treated as drift unless it still matches the legacy `meta.image_id` fallback.
