# Source Management

## Ownership

OpenClaw UI and runtime customizations are source-code changes. They do not
belong in this operations repository as generated patches or one-off asset
rewrites.

Use separate source repositories:

```text
Epicevent/openclaw-jitech
  OpenClaw custom source
  dashboard UI, default provider/model UX, branding, workflow behavior

Epicevent/hermes-jitech
  Hermes custom source
  Hermes UI, Gemini model UX, NAS workspace behavior, provider settings UX

Epicevent/openclaw-nas-agent-baseline
  host operations package
  image publishing recipes
  NAS/document tooling
  slot rollout and drift checks
```

OpenClaw and Hermes images are separate release lanes. They share the same
server rollout tools and private slot registry, but each image records its own
family, source ref, base image, and digest.

## Development Flow

Developers edit the custom source repository directly.

```text
change OpenClaw source
-> run the OpenClaw dev/build checks in that source checkout
-> commit the source change
-> publish a NAS Agent image from that exact source commit
-> roll out the image to selected slots
-> verify with browser/render checks and slot deployment checks
```

Do not edit minified `dist/control-ui/assets/index-*.js` output as the normal
customization path.

## Image Publishing Inputs

The OpenClaw image workflow requires both a frozen runtime base image and an
exact custom OpenClaw source commit.

```text
base_image:
  ghcr.io/epicevent/openclaw-nas-agent@sha256:<runtime-base-digest>

openclaw_source_repo:
  https://github.com/Epicevent/openclaw-jitech.git

openclaw_source_ref:
  40-character commit SHA from the custom source repo
```

The workflow rejects the upstream source repository:

```text
https://github.com/openclaw/openclaw.git
```

Upstream is used for merging and comparison, not as the direct production
source for JiTech images.

Hermes images use the same catalog fields. Until a Hermes custom source
repository is used by the image recipe, the Hermes image records the Hermes
runtime base image and Workspace image as its build inputs.

## Initial OpenClaw Seed

The current JiTech OpenClaw customization seed comes from the server checkout:

```text
server: gx10-947d
path: /home/oc1/openclaw
upstream_commit: 989e53c20d395d3c8bf47efc21fdb9d56e7227b0
```

Only product source changes belong in the source repository:

```text
ui/index.html
ui/src/ui/views/login-gate.ts
ui/src/ui/app-render.ts
ui/public/favicon.svg
ui/public/favicon.ico
ui/public/favicon-32.png
ui/public/apple-touch-icon.png
```

Server runtime files and permissions do not belong in the source repository:

```text
.env
docker-compose*.yml
Apache deploy conf
backup files
credential files
chmod-only changes
```

## Release Rule

An image release is acceptable only when it can answer these questions:

```text
Which custom OpenClaw source commit was used?
Which frozen runtime base digest was used?
Which image digest was published?
Which slots were rolled out?
Did the browser-render check and slot deployment check pass?
```

The image contains code and tools only. Secrets and customer state remain
outside the image.
