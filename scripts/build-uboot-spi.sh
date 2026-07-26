#!/bin/bash
# Build U-Boot SPI flash image for the Radxa E24C.
#
# Produces u-boot-rockchip-spi.bin (1.6 MB) for flashing via rkdeveloptool
# to the E24C's onboard SPI NOR flash. Once flashed, BROM loads U-Boot SPL
# from SPI → U-Boot inits PCIe → loads Talos UKI from NVMe's EFI partition.
#
# This script bypasses bldr/Pkgfile because the bldr v0.5.6 frontend fails
# to template the tools-* pkg.yaml files (source.sha256 should be 64 chars
# long errors) regardless of PKGS/TOOLS version. Direct Docker build works.
#
# Build deps: gcc, libgnutls28-dev (EFI capsule support), python3+pyelftools
# (binman), swig + device-tree-compiler (DTS compilation).
#
# Output: /tmp/u-boot-rockchip-spi-direct.bin
#
# Flash to E24C SPI (in Maskrom mode — hold recovery button + power on):
#   rkdeveloptool ld                                              # verify
#   sudo rkdeveloptool db rk3528_spl_loader_v1.07.104.bin        # init RAM
#   sudo rkdeveloptool wl 0 /tmp/u-boot-rockchip-spi-direct.bin   # write SPI
#   sudo rkdeveloptool rd                                          # reset
#
# Loader download:
#   curl -LO https://dl.radxa.com/rock2/images/loader/rk3528_spl_loader_v1.07.104.bin

set -eou pipefail

SRC="${SRC:-$(cd "$(dirname "$0")/.." && pwd)/kwiboo-u-boot-rockchip}"
RKBIN="${RKBIN:-$(cd "$(dirname "$0")/.." && pwd)/rockchip-rkbin}"
OUT="${OUT:-/tmp/u-boot-rockchip-spi-direct.bin}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [ ! -d "$SRC" ]; then
    echo "FATAL: U-Boot source not found at $SRC"
    echo "Set SRC env var to the kwiboo-u-boot-rockchip checkout"
    exit 1
fi

if [ ! -d "$RKBIN" ]; then
    echo "FATAL: rkbin source not found at $RKBIN"
    echo "Set RKBIN env var to the rockchip-rkbin checkout"
    exit 1
fi

echo "=== Building U-Boot SPI image (direct, no bldr) ==="
echo "Source: $SRC"
echo "rkbin:  $RKBIN"
echo "Output: $OUT"
echo ""

# Copy source so we don't pollute the submodule working tree
cp -a "$SRC/." "$WORK/"

docker run --rm --platform linux/arm64 \
  -v "$WORK:/work" -w /work \
  -v "$RKBIN:/rkbin:ro" \
  debian:bookworm-slim bash -c '
    set -e
    echo "--- installing build deps ---"
    apt-get update -qq 2>/dev/null
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
      build-essential gcc g++ bc bison flex libssl-dev libgnutls28-dev \
      python3 python3-pip \
      swig device-tree-compiler cpio 2>&1 | tail -3

    echo "--- installing python deps (binman needs pyelftools) ---"
    pip3 install --break-system-packages pyelftools setuptools 2>&1 | tail -2

    echo "--- locating rkbin blobs ---"
    # Layout per artifacts/rkbin/rk3528/pkg.yaml
    BL31="/rkbin/bin/rk35/rk3528_bl31_v1.20.elf"
    TPL="/rkbin/bin/rk35/rk3528_ddr_1056MHz_v1.11.bin"
    if [ ! -f "$BL31" ] || [ ! -f "$TPL" ]; then
      echo "FATAL: missing rkbin blobs"
      ls -la /rkbin/bin/rk35/ 2>&1 | head -10
      exit 1
    fi
    echo "BL31: $BL31"
    echo "TPL:  $TPL"

    echo "--- configuring (radxa-e24c-rk3528_defconfig) ---"
    make radxa-e24c-rk3528_defconfig 2>&1 | tail -3

    echo "--- building ---"
    make -j "$(nproc)" \
      HOSTLDLIBS_mkimage="-lssl -lcrypto" \
      BL31="$BL31" \
      ROCKCHIP_TPL="$TPL" 2>&1 | tail -10

    echo "--- build outputs ---"
    ls -la u-boot-rockchip.bin u-boot-rockchip-spi.bin 2>&1
    if [ ! -f u-boot-rockchip-spi.bin ]; then
      echo "FATAL: u-boot-rockchip-spi.bin not built"
      ls -la *.bin *.img 2>&1
      exit 1
    fi
  '

cp "$WORK/u-boot-rockchip-spi.bin" "$OUT"

echo ""
echo "=== Verifying EFI boot support ==="
strings "$OUT" | grep -iE "bootefi|BOOTAA64|distro_bootcmd" | head -5 || {
    echo "WARNING: no EFI boot support found in SPI image"
}

echo ""
echo "=== DONE ==="
echo "SPI binary: $OUT ($(ls -lh "$OUT" | awk '"'"'{print $5}'"'"'))"
echo ""
echo "Flash to E24C SPI (put board in Maskrom mode first):"
echo "  sudo rkdeveloptool db rk3528_spl_loader_v1.07.104.bin"
echo "  sudo rkdeveloptool wl 0 $OUT"
echo "  sudo rkdeveloptool rd"
