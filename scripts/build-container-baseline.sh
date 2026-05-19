#!/usr/bin/env bash
set -euo pipefail

BASE_IMAGE="${BASE_IMAGE:-}"
IMAGE_TAG="${IMAGE_TAG:-openclaw-nas-agent:baseline}"

if [[ -z "$BASE_IMAGE" ]]; then
  cat >&2 <<'MSG'
error: BASE_IMAGE is required.

Set it to the OpenClaw runtime image currently used by the container.

Example:
  BASE_IMAGE=ghcr.io/example/openclaw-runtime:latest \
  IMAGE_TAG=openclaw-nas-agent:baseline \
  bash scripts/build-container-baseline.sh
MSG
  exit 1
fi

docker build \
  --build-arg "BASE_IMAGE=$BASE_IMAGE" \
  -t "$IMAGE_TAG" \
  -f container/Dockerfile .

echo "built image: $IMAGE_TAG"
