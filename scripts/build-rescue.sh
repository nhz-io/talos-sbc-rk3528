#!/bin/bash
# Build Talos rescue image for NVMe install.
#
# This is NOT a "rescue" in the Alpine/dd sense. It's a normal Talos metal
# image with NO META partition + an embedded machine config that sets
# install.disk=/dev/nvme0n1. When booted from SD:
#   1. Talos boots normally (same kernel, U-Boot, DTB, overlay as production)
#   2. machined sees no META → Installed()=false → runs Install sequence
#   3. Pulls installer image → writes Talos to /dev/nvme0n1
#   4. Reboots → user removes SD → boots from NVMe → maintenance mode
#
# Requires network at boot (to pull installer image — standard Talos install flow).
#
# Inputs (env):
#   BUILD_TAG       — e.g. 1.13.7-e24c-1-45e581e
#   PROJECT_DIR     — talos-sbc-rk3528 repo root
#   REGISTRY        — e.g. localhost:5000
#   IMAGER_TAG      — e.g. ghcr.io/nhz-io/imager-rk3528:v1.13.7-v12
#   INSTALLER_TAG   — e.g. ghcr.io/nhz-io/talos-sbc-rk3528-installer:${BUILD_TAG}
#   OVERLAY_TAG     — e.g. ghcr.io/nhz-io/talos-sbc-rk3528:${BUILD_TAG}
#   UBOOT_BIN       — path to u-boot-rockchip.bin (from main build Step 2)
#   DTB_FILE        — path to rk3528-radxa-e24c-v13.dtb
#
# Output:
#   ${PROJECT_DIR}/_out/metal-rescue-arm64-${BUILD_TAG}.raw  (uncompressed)

set -eou pipefail

# --- Validate inputs ---
: "${BUILD_TAG:?BUILD_TAG required}"
: "${PROJECT_DIR:?PROJECT_DIR required}"
: "${REGISTRY:?REGISTRY required}"
: "${IMAGER_TAG:?IMAGER_TAG required}"
: "${INSTALLER_TAG:?INSTALLER_TAG required}"
: "${OVERLAY_TAG:?OVERLAY_TAG required}"
: "${UBOOT_BIN:?UBOOT_BIN required}"
: "${DTB_FILE:?DTB_FILE required}"

mkdir -p "${PROJECT_DIR}/_out"

RESCUE_RAW="/tmp/metal-rescue-arm64-${BUILD_TAG}.raw"
RESCUE_ZST="${PROJECT_DIR}/_out/metal-rescue-arm64-${BUILD_TAG}.raw.zst"
RESCUE_FINAL="${PROJECT_DIR}/_out/metal-rescue-arm64-${BUILD_TAG}.raw"

echo "============================================"
echo "Building rescue image: ${BUILD_TAG}"
echo "  Installer: ${INSTALLER_TAG}"
echo "  Overlay:   ${OVERLAY_TAG}"
echo "  U-Boot:    ${UBOOT_BIN}"
echo "  DTB:       ${DTB_FILE}"
echo "============================================"

# --- Step 1: Write embedded machine config ---
# install.disk + install.image + install.wipe triggers the Talos Install sequence
# when booted from SD (no META → Installed()=false → Install runs)
EMBEDDED_CONFIG="/tmp/rescue-config-${BUILD_TAG}.yaml"
cat > "${EMBEDDED_CONFIG}" <<EOF
machine:
  install:
    disk: /dev/nvme0n1
    image: "${INSTALLER_TAG}"
    wipe: true
EOF

echo ""
echo "=== Step 1: embedded machine config ==="
cat "${EMBEDDED_CONFIG}"
echo ""

echo "=== Step 2: building rescue metal image via imager ==="
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
    imageRef: '"${OVERLAY_TAG}"'
    forceInsecure: true
output:
  kind: image
  outFormat: raw
  imageOptions:
    diskSize: 1306525696
    diskFormat: raw' | docker run --rm -i --privileged --network host -v /dev:/dev -v /tmp:/tmp \
  -v "${PROJECT_DIR}/_out:/out" \
  -v "${EMBEDDED_CONFIG}:/config.yaml:ro" \
  "${IMAGER_TAG}" \
  - --output /out \
  --embedded-config-path /config.yaml 2>&1 | tail -10

# Imager outputs metal-arm64.raw (regardless of rescue/production)
# Rename to rescue-specific name
mv "${PROJECT_DIR}/_out/metal-arm64.raw" "${RESCUE_RAW}" 2>/dev/null || \
  mv "${PROJECT_DIR}/_out/metal-arm64-raw" "${RESCUE_RAW}" 2>/dev/null || true

if [ ! -f "${RESCUE_RAW}" ]; then
  echo "FATAL: imager did not produce metal-arm64.raw in _out/"
  ls -la "${PROJECT_DIR}/_out/"
  exit 1
fi

ls -lh "${RESCUE_RAW}"

# --- Step 3: dd U-Boot binary (same as main build Step 7) ---
echo ""
echo "=== Step 3: dd U-Boot ==="
dd if="${UBOOT_BIN}" of="${RESCUE_RAW}" bs=512 seek=64 conv=notrunc

# --- Step 4: Delete META partition (force Talos to see Installed()=false) ---
# The imager auto-creates a META partition. For the rescue image, we MUST NOT
# have META — otherwise Talos considers itself installed and skips the install
# sequence. With no META, Talos sees VolumePhaseMissing → Installed()=false →
# runs Install sequence → writes to /dev/nvme0n1 per embedded config.
echo ""
echo "=== Step 4: deleting META partition (force install sequence on boot) ==="
docker run --rm -v /tmp:/tmp alpine sh -c 'apk add --no-cache sgdisk 2>/dev/null >/dev/null
sgdisk -d 2 /tmp/metal-rescue-arm64-'"${BUILD_TAG}"'.raw 2>&1
echo "META partition deleted"
sgdisk -p /tmp/metal-rescue-arm64-'"${BUILD_TAG}"'.raw 2>&1 | tail -6'

# --- Step 5: Inject DTB ---
echo ""
echo "=== Step 5: inject DTB ==="
# DTB_FILE may already be at /tmp/rk3528-radxa-e24c-v13.dtb (from main build);
# copy only if source is elsewhere
if [ "${DTB_FILE}" != "/tmp/rk3528-radxa-e24c-v13.dtb" ]; then
    cp "${DTB_FILE}" "/tmp/rk3528-radxa-e24c-v13.dtb"
fi
docker run --rm -v /tmp:/tmp alpine sh -c 'apk add --no-cache mtools 2>/dev/null >/dev/null
efioff=11534336
mmd -i /tmp/metal-rescue-arm64-'"${BUILD_TAG}"'.raw@@$efioff ::/EFI/dtb 2>/dev/null || true
mmd -i /tmp/metal-rescue-arm64-'"${BUILD_TAG}"'.raw@@$efioff ::/EFI/dtb/rockchip 2>/dev/null || true
mcopy -i /tmp/metal-rescue-arm64-'"${BUILD_TAG}"'.raw@@$efioff /tmp/rk3528-radxa-e24c-v13.dtb ::/EFI/dtb/rockchip/rk3528-radxa-e24c.dtb
echo "DTB injected"'

# --- Step 6: Move to final output (uncompressed) ---
echo ""
echo "=== Step 6: finalizing ==="
mv "${RESCUE_RAW}" "${RESCUE_FINAL}"
sync

echo ""
echo "============================================"
echo "RESCUE BUILD COMPLETE: ${BUILD_TAG}"
echo "============================================"
echo "Image: ${RESCUE_FINAL} ($(ls -lh ${RESCUE_FINAL} | awk '{print $5}'))"
echo ""
echo "Boot flow:"
echo "  1. Flash ${RESCUE_FINAL} to SD card via Etcher"
echo "  2. Boot E24C from SD — Talos boots, sees no META, runs Install sequence"
echo "  3. Talos pulls installer image ${INSTALLER_TAG}"
echo "  4. Talos writes itself to /dev/nvme0n1, reboots"
echo "  5. Remove SD card, boot from NVMe — Talos maintenance mode"
echo "  6. apply-config --insecure --nodes 55.55.55.243 --file controlplane.yaml"
echo "============================================"
