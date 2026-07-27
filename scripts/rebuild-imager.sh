#!/bin/bash
# Rebuild the Talos imager image from the fork source (sidero-talos).
#
# CRITICAL: passes PKG_KERNEL so the SBC kernel (with GMAC + RTL8365MB, gcc-built)
# is used instead of the stock Talos kernel (clang-built, no SBC network drivers).
# Without PKG_KERNEL, the resulting imager's UKI has no network drivers and e24c
# boots with no network (end0/wan never created).
#
# Usage: ./scripts/rebuild-imager.sh [tag]
# Output: ghcr.io/nhz-io/imager-rk3528:<tag>
# Default tag: v1.13.7-v13

set -eou pipefail

TAG="${1:-v1.13.7-v13}"
TALOS_SRC_DIR="${TALOS_SRC_DIR:-$HOME/talos/sidero-talos}"
IMAGE_PREFIX="${IMAGE_PREFIX:-ghcr.io/nhz-io}"
IMAGER_TAG="${IMAGE_PREFIX}/imager-rk3528:${TAG}"

# SBC kernel image (arm64, built by talos-sbc-rk3528 bldr kernel-radxa-e24c target).
# Contains RTL8365MB switch driver + Rockchip GMAC driver.
SBC_KERNEL_IMAGE="${SBC_KERNEL_IMAGE:-${IMAGE_PREFIX}/talos-kernel-rk3528:v0.5.1-talos}"

# Stock Sidero kernel for amd64 (SBC kernel is arm64-only).
STOCK_KERNEL_AMD64="${STOCK_KERNEL_AMD64:-ghcr.io/siderolabs/kernel:v1.13.0-49-g91fe0a0}"

echo "============================================"
echo "Rebuilding Talos imager: ${IMAGER_TAG}"
echo "  Source:      ${TALOS_SRC_DIR}"
echo "  SBC kernel:  ${SBC_KERNEL_IMAGE}"
echo "  AMD64 kernel: ${STOCK_KERNEL_AMD64}"
echo "============================================"

cd "${TALOS_SRC_DIR}"

# Build via Talos Makefile. The key build-args:
#   PKG_KERNEL: arm64 SBC kernel (with GMAC + RTL8365MB)
#   PKG_KERNEL_AMD64: stock Sidero amd64 kernel (SBC kernel is arm64-only)
#   TARGET_ARGS: passed through to docker buildx build (carries PKG_KERNEL_AMD64)
#   DEST: output directory for the tarball
DEST="${DEST:-/tmp/imager-build}"
mkdir -p "${DEST}"

make docker-imager \
  PLATFORM=linux/arm64 \
  PUSH=false \
  DEST="${DEST}" \
  PKG_KERNEL="${SBC_KERNEL_IMAGE}" \
  TARGET_ARGS="--build-arg=PKG_KERNEL_AMD64=${STOCK_KERNEL_AMD64}" \
  2>&1 | tail -10

# Load the tarball
echo ""
echo "=== loading imager ==="
docker load -i "${DEST}/imager.tar" 2>&1 | tail -3

# Re-tag to our naming convention
LOADED_TAG=$(docker load -i "${DEST}/imager.tar" 2>&1 | grep -o "Loaded image: .*" | sed 's/Loaded image: //')
docker tag "${LOADED_TAG}" "${IMAGER_TAG}"

echo ""
echo "============================================"
echo "Imager: ${IMAGER_TAG}"
echo "Verify: kernel should be gcc-built with RTL8365MB + GMAC drivers"
echo "Use in build.sh: IMAGER_TAG=${IMAGER_TAG} bash build.sh"
echo "============================================"
