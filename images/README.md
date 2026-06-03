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

Directory layout:

```text
images/openclaw-nas-agent/   OpenClaw NAS Agent image recipe
images/hermes-workspace/     Hermes Agent + Workspace image recipe
images/shared/               document tooling shared by official images
images/openclaw-overlays/    OpenClaw UI overlays
```

If image publishing grows beyond a small number of official releases, this
directory can move to a dedicated image-release repository without changing the
server-side rollout model.
