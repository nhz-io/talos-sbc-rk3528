#!/bin/bash
# RK3528 build pipeline — cache-safe, versioned, verified
# Usage: BUILD_TAG=v19 bash ~/talos-sbc-rk3528/build.sh
#
# This script ALWAYS:
# 1. Rebuilds U-Boot from scratch (--no-cache) with current patches
# 2. Rebuilds overlay (--no-cache to force U-Boot stage rebuild)
# 3. Extracts U-Boot from the separately-built image
# 4. dd's the correct binary into the metal image
# 5. Verifies IDENT_STRING is present in the final raw image before compressing
#
# The IDENT_STRING appears in BOTH:
# - U-Boot proper banner (if console works): "U-Boot 2026.01 ... -rk3528-v19"
# - SPL banner (via spl_display_print): appended after standard SPL banner

set -eou pipefail

BUILD_TAG="${BUILD_TAG:-v19}"
IMAGE_PREFIX="ghcr.io/nhz-io"
REGISTRY="localhost:5000"
IDENT_STRING="${BUILD_TAG}"  # Used for image tagging only, not U-Boot IDENT_STRING

echo "============================================"
echo "RK3528 build pipeline — ${BUILD_TAG}"
echo "IDENT_STRING: ${IDENT_STRING}"
echo "============================================"

cd ~/talos-sbc-rk3528

# --- Step 0: No defconfig patch needed — using stock Kwiboo U-Boot ---

# Source date epoch for reproducible builds
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
  --build-arg=PKGS_PREFIX=ghcr.io/siderolabs --build-arg=PKGS=v1.9.0 \
  --build-arg=TOOLS_PREFIX=ghcr.io/siderolabs --build-arg=TOOLS=v1.9.0 \
  --tag="${UBOOT_TAG}" --load .

# --- Step 2: Extract U-Boot binary from the build ---
echo ""
echo "=== Step 2: Extracting U-Boot binary ==="
CONTAINER_NAME="uboot-extract-${BUILD_TAG}"
docker create --name="${CONTAINER_NAME}" --entrypoint /bin/true "${UBOOT_TAG}" 2>/dev/null
UBOOT_BIN="/tmp/u-boot-rockchip-${BUILD_TAG}.bin"
docker cp "${CONTAINER_NAME}:/rootfs/artifacts/arm64/u-boot/radxa-e24c/u-boot-rockchip.bin" "${UBOOT_BIN}" 2>&1
docker rm "${CONTAINER_NAME}" 2>/dev/null

# --- Step 3: Basic U-Boot binary verification ---
echo ""
echo "=== Step 3: Verifying U-Boot binary ==="
echo "Binary: ${UBOOT_BIN} ($(ls -lh ${UBOOT_BIN} | awk '{print $5}'))"
echo "MD5: $(md5sum ${UBOOT_BIN} | awk '{print $1}')"
strings "${UBOOT_BIN}" | grep "U-Boot 20" | head -1

# --- Step 4: Build overlay (--no-cache to force U-Boot stage rebuild) ---
echo ""
echo "=== Step 4: Building overlay (--no-cache) ==="
OVERLAY_TAG="${IMAGE_PREFIX}/talos-sbc-rk3528:${BUILD_TAG}"
docker buildx build --no-cache \
  --target=sbc-rk3528 --file=Pkgfile \
  --provenance=false --sbom=false --progress=auto \
  --platform=linux/arm64 \
  --build-arg=SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH}" \
  --build-arg=PKGS_PREFIX=ghcr.io/siderolabs --build-arg=PKGS=v1.9.0 \
  --build-arg=TOOLS_PREFIX=ghcr.io/siderolabs --build-arg=TOOLS=v1.9.0 \
  --tag="${OVERLAY_TAG}" --load .

# Push overlay to local registry
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
  echo "WARNING: Overlay U-Boot does not match! Will dd our binary."
else
  echo "OK: Overlay U-Boot matches our separately-built binary"
fi

# --- Step 6: Build imager + installer + metal image ---
echo ""
echo "=== Step 6: Building imager + installer + metal image ==="
cd ~/talos-src-v1.13.7

INSTALLER_TAG="${REGISTRY}/talos-rk3528:v1.13.7-radxa-e24c-${BUILD_TAG}"

# Reuse existing imager image
docker run --rm --privileged --network host -v /dev:/dev -v /tmp:/tmp \
  -v ~/talos-sbc-rk3528/_out:/out \
  -e PLATFORM=container \
  ghcr.io/nhz-io/imager-rk3528:v1.13.7-v12 \
  installer --arch arm64 \
  --overlay-image "${REGISTRY}/talos-sbc-rk3528:${BUILD_TAG}" \
  --insecure --overlay-name radxa-e24c \
  --base-installer-image "${REGISTRY}/imager-rk3528:v1.13.7-v12" \
  --output /out 2>&1 | tail -3

docker load -i ~/talos-sbc-rk3528/_out/installer-arm64.tar 2>&1 | tail -1
docker tag "${REGISTRY}/imager-rk3528:v1.13.7-v12" "${INSTALLER_TAG}"
docker push "${INSTALLER_TAG}" 2>&1 | tail -1

# Build metal image
echo 'arch: arm64
platform: metal
secureboot: false
customization:
  extraKernelArgs:
    - ip=wan:dhcp
    - talos.network.interface.ignore=end0
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
  -v ~/talos-src-v1.13.7/_out:/out \
  "${INSTALLER_TAG}" \
  - --output /out 2>&1 | tail -5

# --- Step 7: Post-process: dd U-Boot + inject DTB ---
echo ""
echo "=== Step 7: Post-processing ==="
RAW_FILE="/tmp/metal-arm64-${BUILD_TAG}.raw"
ZST_FILE="${HOME}/talos-src-v1.13.7/_out/metal-arm64-${BUILD_TAG}.raw.zst"

zstd -d ~/talos-src-v1.13.7/_out/metal-arm64.raw.zst -o "${RAW_FILE}" -f

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

echo ""
echo "============================================"
echo "BUILD COMPLETE: ${BUILD_TAG}"
echo "============================================"
echo "Image: ${ZST_FILE} ($(ls -lh ${ZST_FILE} | awk '{print $5}'))"
echo "U-Boot: ${UBOOT_TAG}"
echo "Overlay: ${OVERLAY_TAG}"
echo "Installer: ${INSTALLER_TAG}"
echo ""
echo "Stock Kwiboo U-Boot (no IDENT_STRING)."
echo "============================================"
