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
  Hermes Agent custom source
  backend/runtime behavior, provider defaults, tool/runtime behavior

Epicevent/hermes-workspace-jitech
  Hermes Workspace custom source
  browser UI, Gemini model UX, NAS workspace display, provider settings UX

Epicevent/openclaw-nas-agent-baseline
  host operations package
  image publishing recipes
  NAS/document tooling
  slot rollout and health checks
```

OpenClaw and Hermes images are separate release lanes. They share the same
server rollout tools and private slot registry, but each image records its own
family, source ref, base image, and digest.

## Development Flow

Developers edit the custom source repository directly. Customer slots are not
development workspaces.

```text
change OpenClaw source
-> run the OpenClaw dev/build checks in that source checkout
-> check it through the dev slot subdomain
-> commit the source change
-> publish a NAS Agent image from that exact source commit
-> roll out the image to selected slots
-> verify with browser/render checks and slot deployment checks
```

Do not edit minified `dist/control-ui/assets/index-*.js` output as the normal
customization path.

## Dev Slots

`oc1` through `oc20` are customer slots. They must run registry images only.
They must not receive source bind mounts.

Development confirmation uses separate managed slots:

```text
dev-oc
  OpenClaw source confirmation slot
  public host: dev-oc.ji-tech.co.kr
  source path: /home/openclawdev/src/openclaw-jitech

dev-hermess
  Hermes source confirmation slot
  public host: dev-hermess.ji-tech.co.kr
  workspace source path: /home/openclawdev/src/hermes-workspace-jitech
  agent source path: /home/openclawdev/src/hermes-jitech
```

`dev-oc` and `dev-hermess` are not sudo/docker accounts. They are managed like
customer accounts, with separate runtime users and data groups. The developer
account `openclawdev` owns and builds source; the dev slots only expose the
result through their containers and Apache subdomains.

Hermes has two source lanes. The visible web app is Hermes Workspace, so
`source-mode-enable dev-hermess` mounts `/home/openclawdev/src/hermes-workspace-jitech`
into `/opt/hermes-workspace`. The Hermes Agent runtime source remains separate
and is used by image builds only when that runtime itself is customized.

Source mode is only valid for dev slots:

```bash
sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh dev-slot-status dev-oc
sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh source-mode-enable dev-oc
sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh source-mode-disable dev-oc
```

Running source mode against an `ocN` customer slot is a configuration error.

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

Hermes images use the same catalog fields, but they have two upstream inputs:
the Hermes Agent runtime image and the Hermes Workspace UI source/image. A
Workspace-only customization must not pretend to be a Hermes Agent runtime
change.

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
For Hermes, which Agent source commit was represented by the base image?
For Hermes, which Workspace source commit was built into the UI?
Which image digest was published?
Which slots were rolled out?
Did the browser-render check and slot deployment check pass?
```

The image contains code and tools only. Secrets and customer state remain
outside the image.
