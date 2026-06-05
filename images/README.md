# Official Image Recipes

This directory contains public image recipes only.

It is not runtime operations state. It must not contain:

```text
API keys
NAS credentials
gateway tokens
customer documents
slots.yaml
host .env files
```

The host package installs and rolls out images through `svcops-control.sh`. It
does not build images during normal server operation.

OpenClaw/Hermes customization source is developed in product repositories.
This directory does not checkout those repositories and does not build product
source. It wraps already-built runtime image digests with shared NAS/HWP
document tools.

Directory layout:

```text
images/openclaw-nas-agent/   OpenClaw-family runtime wrapper
images/hermes-workspace/     Hermes-family runtime wrapper
images/shared/               document tooling shared by official images
```

Image publishing is split by runtime family:

```text
.github/workflows/publish-openclaw-nas-agent-image.yml
.github/workflows/publish-hermes-nas-agent-image.yml
```

If image publishing grows beyond a small number of official releases, this
directory can move to a dedicated image-release repository without changing the
server-side rollout model.
