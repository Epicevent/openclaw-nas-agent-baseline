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
ghcr.io/epicevent/openclaw-nas-agent:hermes-workspace-20260602-r1
```

## Release Flow

The public image is built and pushed by GitHub Actions:

```text
.github/workflows/publish-openclaw-nas-agent-image.yml
.github/workflows/publish-hermes-nas-agent-image.yml
```

The `dashboard-20260602-r1` image uses the overlay in:

```text
image-overlays/dashboard-20260602-r1
```

The `hermes-workspace-20260602-r1` image is an integrated Hermes image. It uses
the official Hermes Agent image as its base, copies Hermes Workspace into the
same final image, and installs the same NAS Agent document baseline packages.

Build it with:

```bash
IMAGE_TAG=ghcr.io/epicevent/openclaw-nas-agent:hermes-workspace-20260602-r1 \
  bash scripts/build-hermes-integrated-image.sh
```

`family=hermes` images are not a plain OpenClaw image swap. Rollout rewrites the
target slot compose to run one integrated container:

```text
openclaw-gateway     ghcr.io/epicevent/openclaw-nas-agent:<hermes-workspace tag>
```

The container runs both Hermes Agent and Hermes Workspace. The public Apache
subdomain points to Workspace on container port `3000`. Hermes Agent API and the
raw Hermes dashboard stay on container-local loopback ports. The image keeps
the official Hermes Docker entrypoint (`/init` plus `main-wrapper.sh`) so the
built-in gateway and dashboard supervision follows upstream Docker behavior.
Hermes Workspace is added as a separate s6 service in the same container and
connects to the gateway and dashboard over loopback to use the extended Hermes
APIs for settings, sessions, skills, config, MCP, and jobs. The slot NAS is
mounted read-only into the same container at:

```text
/workspace/nas_docs
/opt/data/nas_docs
/home/node/nas_docs
```

Hermes Agent stores provider API keys in its own profile env file. In this
deployment, that container path maps to the host as:

```text
/opt/data/.env                 # inside container
/home/ocN/.hermes/.env         # host bind mount
```

When converting an existing OpenClaw slot to a Hermes image, the rollout moves
allowlisted provider keys from the previous slot compose `.env` into
`/home/ocN/.hermes/.env`, such as `GEMINI_API_KEY` or `GOOGLE_API_KEY`. The
previous compose `.env` is also saved as:

```text
/home/ocN/openclaw/.env.bak.hermes-YYYYMMDDHHMMSS
```

If a slot was converted before this preservation behavior existed, re-inject the
provider key through the normal runtime secret path. For Hermes slots,
`apply-runtime-secrets.sh` writes provider keys to `/home/ocN/.hermes/.env`; for
OpenClaw slots it writes them to the existing compose runtime env path.

Hermes Workspace is password-protected with `HERMES_PASSWORD`. The password is
slot-local runtime secret state and is not stored in public image metadata.
`install-hermes-slot-from-image.sh` writes the generated handoff password to a
root-managed handoff file and prints only the file path:

```text
/srv/openclaw-ops/handoff/hermes-workspace-ocN.env
```

The same explicit handoff command is used for Hermes Workspace passwords and
OpenClaw gateway tokens:

```bash
sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh \
  handoff-credential ocN
```

After the image is available in GHCR, run the server-side rollout commands as
the restricted operations account through `svcops-control.sh`.

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
