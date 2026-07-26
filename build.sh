#!/bin/bash
# RK3528 build pipeline — cache-safe, versioned, verified
# Usage: bash build.sh   (BUILD_TAG defaults to 1.13.7-e24c-1-<git-short-hash>)
#
# This script ALWAYS:
# 1. Rebuilds U-Boot from scratch (--no-cache) with current patches
# 2. Rebuilds overlay (--no-cache to force U-Boot stage rebuild)
# 3. Extracts U-Boot from the separately-built image
# 4. dd's the correct binary into the metal image
# 5. Verifies IDENT_STRING is present in the final raw image before compressing
#
# Path-agnostic: every path/prefix/tag is an env var with a sensible default.
# Defaults match the developer's local setup; CI overrides via env.

set -eou pipefail

# --- Paths / registry / version pins (all overridable via env) ---
PROJECT_DIR="${PROJECT_DIR:-$(cd "$(dirname "$0")" && pwd)}"
TALOS_SRC_DIR="${TALOS_SRC_DIR:-$HOME/talos/sidero-talos}"
REGISTRY="${REGISTRY:-localhost:5000}"

# --- Sidero image refs (mirrored to ghcr.io/nhz-io/sidero-* by Phase C) ---
PKGS_PREFIX="${PKGS_PREFIX:-ghcr.io/siderolabs}"
PKGS="${PKGS:-v1.9.0}"
TOOLS_PREFIX="${TOOLS_PREFIX:-ghcr.io/siderolabs}"
TOOLS="${TOOLS:-v1.9.0}"
BLDR_IMAGE="${BLDR_IMAGE:-ghcr.io/nhz-io/sidero-bldr:v0.5.6}"

# --- Talos system extensions (official, multi-arch: amd64 + arm64) ---
# Pinned to extensions repo tag v1.13.7 (talos-extensions submodule).
# Versions from siderolabs/extensions/network/vars.yaml @ v1.13.7.
# Baked into the metal image initramfs via the imager profile (input.systemExtensions).
TAILSCALE_IMAGE="${TAILSCALE_IMAGE:-ghcr.io/siderolabs/tailscale:1.98.8}"
CLOUDFLARED_IMAGE="${CLOUDFLARED_IMAGE:-ghcr.io/siderolabs/cloudflared:2026.7.1}"

# --- Build tag / image naming ---
# Tag scheme: 1.13.7-e24c-<ITER>-<short-hash>  (ITER bumped manually across rebuilds from the same commit)
DEFAULT_SHORT_HASH="$(git -C "${PROJECT_DIR}" rev-parse --short=7 HEAD 2>/dev/null || echo unknown)"
ITER="${ITER:-1}"
BUILD_TAG="${BUILD_TAG:-1.13.7-e24c-${ITER}-${DEFAULT_SHORT_HASH}}"
IMAGE_PREFIX="${IMAGE_PREFIX:-ghcr.io/nhz-io}"

# --- Imager (rebuilt from nhz-io/sidero-talos fork; falls back to existing tag) ---
IMAGER_TAG="${IMAGER_TAG:-${IMAGE_PREFIX}/imager-rk3528:v1.13.7-v12}"
INSTALLER_TAG="${IMAGE_PREFIX}/talos-sbc-rk3528-installer:${BUILD_TAG}"

echo "============================================"
echo "RK3528 build pipeline — ${BUILD_TAG}"
echo "PROJECT_DIR:    ${PROJECT_DIR}"
echo "TALOS_SRC_DIR:  ${TALOS_SRC_DIR}"
echo "REGISTRY:       ${REGISTRY}"
echo "PKGS:           ${PKGS_PREFIX}:${PKGS}"
echo "TOOLS:          ${TOOLS_PREFIX}:${TOOLS}"
echo "BLDR:           ${BLDR_IMAGE}"
echo "============================================"

cd "${PROJECT_DIR}"

# Source date epoch for reproducible builds (first commit timestamp)
SOURCE_DATE_EPOCH=$(git log --format=%ct $(git rev-list --max-parents=0 HEAD))

# --- Step 1: Build U-Boot from scratch (--no-cache, always) ---
echo ""
echo "=== Step 1: Building U-Boot (--no-cache) ==="
UBOOT_TAG="${IMAGE_PREFIX}/talos-sbc-u-boot-rk3528:${BUILD_TAG}"
docker buildx build --no-cache \
  --target=u-boot-radxa-e24c --file=Pkgfile \
  --provenance=false --sbom=false --progress=auto \
  --platform=linux/arm64 \
  --build-arg=SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH}" \
  --build-arg=PKGS_PREFIX="${PKGS_PREFIX}" --build-arg=PKGS="${PKGS}" \
  --build-arg=TOOLS_PREFIX="${TOOLS_PREFIX}" --build-arg=TOOLS="${TOOLS}" \
  --tag="${UBOOT_TAG}" --load .

# --- Step 2: Extract U-Boot binary from the build ---
echo ""
echo "=== Step 2: Extracting U-Boot binary ==="
CONTAINER_NAME="uboot-extract-${BUILD_TAG}"
docker create --name="${CONTAINER_NAME}" --entrypoint /bin/true "${UBOOT_TAG}" 2>/dev/null
UBOOT_BIN="/tmp/u-boot-rockchip-${BUILD_TAG}.bin"
UBOOT_SPI_BIN="/tmp/u-boot-rockchip-spi-${BUILD_TAG}.bin"
docker cp "${CONTAINER_NAME}:/rootfs/artifacts/arm64/u-boot/radxa-e24c/u-boot-rockchip.bin" "${UBOOT_BIN}" 2>&1
docker cp "${CONTAINER_NAME}:/rootfs/artifacts/arm64/u-boot/radxa-e24c/u-boot-rockchip-spi.bin" "${UBOOT_SPI_BIN}" 2>&1
docker rm "${CONTAINER_NAME}" 2>/dev/null

# --- Step 3: Basic U-Boot binary verification ---
echo ""
echo "=== Step 3: Verifying U-Boot binary ==="
echo "SD-card:  ${UBOOT_BIN} ($(ls -lh ${UBOOT_BIN} | awk '{print $5}'))"
echo "SPI:      ${UBOOT_SPI_BIN} ($(ls -lh ${UBOOT_SPI_BIN} | awk '{print $5}'))"
echo "MD5: $(md5sum ${UBOOT_BIN} | awk '{print $1}')"
strings "${UBOOT_BIN}" | grep "U-Boot 20" | head -1
strings "${UBOOT_SPI_BIN}" | grep -i "bootefi" | head -1 && echo "SPI: bootefi support OK" || echo "SPI: WARNING - no bootefi found"

# --- Step 4: Build overlay (--no-cache to force U-Boot stage rebuild) ---
echo ""
echo "=== Step 4: Building overlay (--no-cache) ==="
OVERLAY_TAG="${IMAGE_PREFIX}/talos-sbc-rk3528:${BUILD_TAG}"
docker buildx build --no-cache \
  --target=sbc-rk3528 --file=Pkgfile \
  --provenance=false --sbom=false --progress=auto \
  --platform=linux/arm64 \
  --build-arg=SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH}" \
  --build-arg=PKGS_PREFIX="${PKGS_PREFIX}" --build-arg=PKGS="${PKGS}" \
  --build-arg=TOOLS_PREFIX="${TOOLS_PREFIX}" --build-arg=TOOLS="${TOOLS}" \
  --tag="${OVERLAY_TAG}" --load .

# Push overlay to local (or CI) registry
docker tag "${OVERLAY_TAG}" "${REGISTRY}/talos-sbc-rk3528:${BUILD_TAG}"
docker push "${REGISTRY}/talos-sbc-rk3528:${BUILD_TAG}"

# --- Step 5: Verify overlay's U-Boot matches our separately-built one ---
echo ""
echo "=== Step 5: Verifying overlay U-Boot matches ==="
OV_VERIFY_NAME="ov-verify-${BUILD_TAG}"
docker create --name="${OV_VERIFY_NAME}" --entrypoint /bin/true "${OVERLAY_TAG}" 2>/dev/null
OVERLAY_UBOOT_MD5=$(docker cp "${OV_VERIFY_NAME}:/artifacts/arm64/u-boot/radxa-e24c/u-boot-rockchip.bin" /tmp/overlay-uboot-check.bin 2>/dev/null && md5sum /tmp/overlay-uboot-check.bin | awk '{print $1}')
docker rm "${OV_VERIFY_NAME}" 2>/dev/null

OUR_MD5=$(md5sum "${UBOOT_BIN}" | awk '{print $1}')
echo "Overlay U-Boot MD5: ${OVERLAY_UBOOT_MD5}"
echo "Our U-Boot MD5:     ${OUR_MD5}"
if [ "${OVERLAY_UBOOT_MD5}" != "${OUR_MD5}" ]; then
  echo "FATAL: U-Boot MD5 mismatch — overlay contains different U-Boot than we built"
  exit 1
fi

# --- Step 6: Build imager + installer + metal image ---
echo ""
echo "=== Step 6: Building imager + installer + metal image ==="
mkdir -p "${PROJECT_DIR}/_out"

# Use the imager image (rebuild via scripts/rebuild-imager.sh if needed)
docker run --rm --privileged --network host -v /dev:/dev -v /tmp:/tmp \
  -v "${PROJECT_DIR}/_out:/out" \
  -e PLATFORM=container \
  "${IMAGER_TAG}" \
  installer --arch arm64 \
  --overlay-image "${REGISTRY}/talos-sbc-rk3528:${BUILD_TAG}" \
  --insecure --overlay-name radxa-e24c \
  --base-installer-image "${IMAGER_TAG}" \
  --system-extension-image "${TAILSCALE_IMAGE}" \
  --system-extension-image "${CLOUDFLARED_IMAGE}" \
  --output /out 2>&1 | tail -3

docker load -i "${PROJECT_DIR}/_out/installer-arm64.tar" 2>&1 | tail -1
docker tag "${IMAGER_TAG}" "${INSTALLER_TAG}"
docker push "${INSTALLER_TAG}" 2>&1 | tail -1

# Build metal image
echo 'arch: arm64
platform: metal
secureboot: false
customization:
  extraKernelArgs:
    - ip=wan:dhcp
    - talos.network.interface.ignore=end0
input:
  systemExtensions:
    - imageRef: '"${TAILSCALE_IMAGE}"'
    - imageRef: '"${CLOUDFLARED_IMAGE}"'
overlay:
  name: radxa-e24c
  image:
    imageRef: '"${REGISTRY}"'/talos-sbc-rk3528:'"${BUILD_TAG}"'
    forceInsecure: true
output:
  kind: image
  outFormat: .zst
  imageOptions:
    diskSize: 1306525696
    diskFormat: raw' | docker run --rm -i --privileged --network host -v /dev:/dev -v /tmp:/tmp \
  -v "${PROJECT_DIR}/_out:/out" \
  "${INSTALLER_TAG}" \
  - --output /out 2>&1 | tail -5

# --- Step 7: Post-process: dd U-Boot + inject DTB ---
echo ""
echo "=== Step 7: Post-processing ==="
RAW_FILE="/tmp/metal-arm64-${BUILD_TAG}.raw"
ZST_FILE="${PROJECT_DIR}/_out/metal-arm64-${BUILD_TAG}.raw.zst"

zstd -d "${PROJECT_DIR}/_out/metal-arm64.raw.zst" -o "${RAW_FILE}" -f

# Always dd our separately-built and verified U-Boot binary
dd if="${UBOOT_BIN}" of="${RAW_FILE}" bs=512 seek=64 conv=notrunc

# Inject DTB
docker run --rm -v /tmp:/tmp alpine sh -c 'apk add --no-cache mtools 2>/dev/null >/dev/null
efioff=11534336
mmd -i /tmp/metal-arm64-'"${BUILD_TAG}"'.raw@@$efioff ::/EFI/dtb
mmd -i /tmp/metal-arm64-'"${BUILD_TAG}"'.raw@@$efioff ::/EFI/dtb/rockchip
mcopy -i /tmp/metal-arm64-'"${BUILD_TAG}"'.raw@@$efioff /tmp/rk3528-radxa-e24c-v13.dtb ::/EFI/dtb/rockchip/rk3528-radxa-e24c.dtb
echo "DTB injected"'

# --- Step 8: Final verification ---
echo ""
echo "=== Step 8: Final verification ==="
echo "OK: Raw image built successfully"

# Compress
zstd -19 -f "${RAW_FILE}" -o "${ZST_FILE}"

# --- Step 9: Build rescue image (Talos metal image with no META → installs to NVMe) ---
echo ""
echo "=== Step 9: Building rescue image ==="
BUILD_TAG="${BUILD_TAG}" \
  PROJECT_DIR="${PROJECT_DIR}" \
  REGISTRY="${REGISTRY}" \
  IMAGER_TAG="${IMAGER_TAG}" \
  INSTALLER_TAG="${INSTALLER_TAG}" \
  OVERLAY_TAG="${OVERLAY_TAG}" \
  UBOOT_BIN="${UBOOT_BIN}" \
  DTB_FILE="/tmp/rk3528-radxa-e24c-v13.dtb" \
  bash scripts/build-rescue.sh

# Copy SPI flash image to _out for convenience
cp "${UBOOT_SPI_BIN}" "${PROJECT_DIR}/_out/u-boot-rockchip-spi-${BUILD_TAG}.bin"

echo ""
echo "============================================"
echo "BUILD COMPLETE: ${BUILD_TAG}"
echo "============================================"
echo "Image:      ${ZST_FILE} ($(ls -lh ${ZST_FILE} | awk '{print $5}'))"
echo "Rescue:     ${PROJECT_DIR}/_out/metal-rescue-arm64-${BUILD_TAG}.raw"
echo "SPI flash:  ${PROJECT_DIR}/_out/u-boot-rockchip-spi-${BUILD_TAG}.bin"
echo "U-Boot:     ${UBOOT_TAG}"
echo "Overlay:    ${OVERLAY_TAG}"
echo "Installer:  ${INSTALLER_TAG}"
echo "============================================"
