#!/bin/bash
# Rebuild the Talos imager image from the fork source.
# Usage: ./scripts/rebuild-imager.sh [tag]
#
# Outputs a docker image: ghcr.io/nhz-io/imager-rk3528:<tag>
# Default tag: v1.13.7-rk3528-v1  (matches "after migration" target per plan)

set -eou pipefail

TAG="${1:-v1.13.7-rk3528-v1}"
TALOS_SRC_DIR="${TALOS_SRC_DIR:-$HOME/talos-src-v1.13.7}"
IMAGE_PREFIX="${IMAGE_PREFIX:-ghcr.io/nhz-io}"
IMAGER_TAG="${IMAGE_PREFIX}/imager-rk3528:${TAG}"

echo "Rebuilding Talos imager image from ${TALOS_SRC_DIR}"
echo "Target: ${IMAGER_TAG}"

# Use Talos's own Makefile target for the imager.
# Talos Makefile expects REGISTRY, USERNAME, IMAGE_TAG, TARGETARCH.
cd "${TALOS_SRC_DIR}"

# Build the imager image via Talos Dockerfile (image-imager target).
# This produces a container image that can run installer commands.
docker buildx build \
  --target=imager \
  --file=Dockerfile \
  --platform=linux/arm64 \
  --build-arg=USER=nhz-io \
  --build-arg=TAG=${TAG} \
  --tag="${IMAGER_TAG}" \
  --load . 2>&1 | tail -5

echo ""
echo "Imager image: ${IMAGER_TAG}"
echo "Use it in build.sh via: IMAGER_TAG=${IMAGER_TAG} bash build.sh"
