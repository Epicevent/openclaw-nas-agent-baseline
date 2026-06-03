# Dashboard Image Overlay: dashboard-20260602-r1

This overlay contains the OpenClaw UI customization used to build:

```text
ghcr.io/epicevent/openclaw-nas-agent:dashboard-20260602-r1
```

Base OpenClaw source:

```text
repository=https://github.com/openclaw/openclaw.git
commit=989e53c20d395d3c8bf47efc21fdb9d56e7227b0
```

The overlay is copied onto the OpenClaw source tree before building the
OpenClaw runtime image. The NAS Agent document baseline is then applied as a
second image layer with `images/openclaw-nas-agent/Dockerfile`.

Do not store runtime secrets, NAS credentials, gateway tokens, customer
documents, slot registries, or server `.env` files in this directory.
