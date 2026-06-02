#!/usr/bin/env bash
set -euo pipefail

BASE_IMAGE="${BASE_IMAGE:-nousresearch/hermes-agent:latest}"
HERMES_WORKSPACE_IMAGE="${HERMES_WORKSPACE_IMAGE:-ghcr.io/outsourc-e/hermes-workspace:latest}"
IMAGE_TAG="${IMAGE_TAG:-ghcr.io/epicevent/openclaw-nas-agent:hermes-workspace-local}"
DOCKER_BUILD_PULL="${DOCKER_BUILD_PULL:-0}"
DOCKER_BUILD_NO_CACHE="${DOCKER_BUILD_NO_CACHE:-0}"

build_args=()
if [[ "$DOCKER_BUILD_PULL" =~ ^(1|true|yes|on)$ ]]; then
  build_args+=(--pull)
fi
if [[ "$DOCKER_BUILD_NO_CACHE" =~ ^(1|true|yes|on)$ ]]; then
  build_args+=(--no-cache)
fi

docker build "${build_args[@]}" \
  --build-arg "BASE_IMAGE=$BASE_IMAGE" \
  --build-arg "HERMES_WORKSPACE_IMAGE=$HERMES_WORKSPACE_IMAGE" \
  -t "$IMAGE_TAG" \
  -f container/hermes/Dockerfile .

echo "built image: $IMAGE_TAG"
docker image inspect "$IMAGE_TAG" --format 'image_id={{.Id}} os={{.Os}} arch={{.Architecture}} tags={{json .RepoTags}}'
