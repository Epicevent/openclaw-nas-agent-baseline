#!/usr/bin/env bash
set -euo pipefail

BASE_IMAGE="${BASE_IMAGE:-}"
IMAGE_TAG="${IMAGE_TAG:-openclaw-nas-agent:baseline}"
DOCKER_BUILD_PULL="${DOCKER_BUILD_PULL:-0}"
DOCKER_BUILD_NO_CACHE="${DOCKER_BUILD_NO_CACHE:-0}"

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

build_args=()
if [[ "$DOCKER_BUILD_PULL" =~ ^(1|true|yes|on)$ ]]; then
  build_args+=(--pull)
fi
if [[ "$DOCKER_BUILD_NO_CACHE" =~ ^(1|true|yes|on)$ ]]; then
  build_args+=(--no-cache)
fi

docker build "${build_args[@]}" \
  --build-arg "BASE_IMAGE=$BASE_IMAGE" \
  -t "$IMAGE_TAG" \
  -f container/Dockerfile .

echo "built image: $IMAGE_TAG"
