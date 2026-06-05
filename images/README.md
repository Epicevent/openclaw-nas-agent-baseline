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

OpenClaw UI/runtime customization is developed in the custom OpenClaw source
repository, then this directory builds an image from that exact source commit.
Hermes images have two source refs: Hermes Agent for backend/runtime behavior
and Hermes Workspace for the browser UI. Do not maintain normal UI
customization as minified asset rewrites here.

Directory layout:

```text
images/openclaw-nas-agent/   OpenClaw NAS Agent image recipe
images/hermes-workspace/     Hermes Agent base + Workspace source image recipe
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
