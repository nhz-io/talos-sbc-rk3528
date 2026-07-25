# talos-sbc-rk3528

Talos Linux SBC overlay for Radxa E24C (Rockchip RK3528A).

Builds U-Boot (from Kwiboo's branch) and the kernel-side RTL8365MB dumb-switch
patch, assembles a metal-arm64 Talos image ready to flash to microSD (or NVMe
post-install).

## Status

v30 boots cleanly to Talos maintenance mode on Radxa E24C.

- Kernel: stock Linux 6.18.39 (Talos config-arm64) — 6.19 crashes in
  `genpd_power_off_work_fn` on RK3528 SCMI; 6.18.39 is the known-good baseline.
- Boot cmdline: `ip=wan:dhcp talos.network.interface.ignore=end0` — kernel
  DHCPs on the `wan` interface; `end0` (DSA master) is suppressed at the
  Talos level to prevent the end0 DHCP loop.
- RTL8365MB dumb-switch patch: patches `drivers/net/dsa/realtek/rtl8365mb.c`
  to force CPU tag insertion to NONE and enable hardware L2 forwarding between
  ports. Load-bearing for production (wire-speed L2) but did not fix DHCP.

See `~/Library/Mobile Documents/iCloud~md~obsidian/Documents/Personal/Main Vault/Talos/`
for the full design notes and milestone history.

## Supply chain

All external sources forked into the `nhz-io` GitHub org at pinned tags:

| Fork | Upstream | Pinned at | Purpose |
|------|----------|-----------|---------|
| `nhz-io/kwiboo-u-boot-rockchip` | `Kwiboo/u-boot-rockchip` | `affa0a9` | Radxa E24C defconfig + DTS |
| `nhz-io/rockchip-rkbin` | `rockchip-linux/rkbin` | `74213af` | DDR init + BL31 blobs (proprietary) |
| `nhz-io/sidero-talos` | `siderolabs/talos` | `v1.13.7` + branch `v1.13.7-rk3528` | Talos OS source + custom modules |
| `nhz-io/sidero-bldr` | `siderolabs/bldr` | `v0.5.6` | Sidero build frontend (Go) |
| `nhz-io/sidero-toolchain` | `siderolabs/toolchain` | `v1.13.0` | binutils + gcc + musl + golang from source |
| `nhz-io/sidero-tools` | `siderolabs/tools` | `v1.13.0` | Cross-toolchain (dtc, elfutils, etc.) |
| `nhz-io/sidero-pkgs` | `siderolabs/pkgs` | `v1.13.0` | ~50 individual package sources (kernel, runc, ...) |

Container images mirrored to `ghcr.io/nhz-io/`:

- `ghcr.io/nhz-io/sidero-bldr:v0.5.6`
- `ghcr.io/nhz-io/sidero-toolchain:v1.13.0`
- `ghcr.io/nhz-io/sidero-tools:v1.13.0-8-gc2844e6`

Individual PKGS packages (`dosfstools`, `kernel`, `runc`, ...) are mirrored
lazily — only when the build pulls them. To mirror on-demand:

```bash
docker buildx imagetools create \
  --tag ghcr.io/nhz-io/sidero-<name>:<tag> \
  ghcr.io/siderolabs/<name>:<tag>
```

## Requirements

- Docker with `buildx` support
- `git`, `zstd`
- Local docker registry (for the build pipeline to push intermediate overlays to)

## Usage

### One-time setup

```bash
# Clone this repo
git clone https://github.com/nhz-io/talos-sbc-rk3528.git ~/talos-sbc-rk3528

# Clone the Talos source fork
./scripts/setup-talos-src.sh

# Optional: rebuild imager from fork (default: reuses existing published tag)
./scripts/rebuild-imager.sh
```

### Build

```bash
BUILD_TAG=v31 bash build.sh
```

Output: `~/talos-src-v1.13.7/_out/metal-arm64-v31.raw.zst`

### Flash

```bash
zstd -d metal-arm64-v31.raw.zst -o metal-arm64-v31.raw
sudo dd if=metal-arm64-v31.raw of=/dev/rdiskN bs=4M conv=sync
```

## Environment variables

`build.sh` honors these env vars (defaults match local dev setup; CI overrides):

| Var | Default | What it controls |
|-----|---------|-------------------|
| `BUILD_TAG` | `v30` | Tag suffix for all built images |
| `PROJECT_DIR` | `$(dirname $0)` | Repo path (where Pkgfile lives) |
| `TALOS_SRC_DIR` | `$HOME/talos-src-v1.13.7` | Talos source path |
| `REGISTRY` | `localhost:5000` | Where to push overlay + installer images |
| `PKGS_PREFIX` | `ghcr.io/siderolabs` | Sidero package image namespace |
| `PKGS` | `v1.9.0` | Sidero package tag |
| `TOOLS_PREFIX` | `ghcr.io/siderolabs` | Tools image namespace |
| `TOOLS` | `v1.9.0` | Tools image tag |
| `BLDR_IMAGE` | `ghcr.io/nhz-io/sidero-bldr:v0.5.6` | bldr syntax image |
| `IMAGE_PREFIX` | `ghcr.io/nhz-io` | Where to push U-Boot + overlay images |
| `IMAGER_TAG` | `ghcr.io/nhz-io/imager-rk3528:v1.13.7-v12` | Imager image to use |

## Layout

```
talos-sbc-rk3528/
├── Pkgfile                          # bldr manifest (vars + steps per artifact)
├── build.sh                         # Production build pipeline (path-agnostic)
├── artifacts/
│   ├── kernel/radxa-e24c/
│   │   ├── pkg.yaml                 # Kernel build stage
│   │   ├── config/config-arm64      # Talos config-arm64 (stock v1.13.7)
│   │   ├── files/rk3528-*.dts|dtb   # E24C DTB injected into final image
│   │   └── patches/
│   │       └── 0001-rtl8365mb-dumb-switch-mode.patch
│   ├── rkbin/rk3528/pkg.yaml        # DDR + BL31 blobs
│   └── u-boot/radxa-e24c/pkg.yaml   # U-Boot build stage (Kwiboo fork)
├── installers/radxa-e24c/
│   ├── pkg.yaml
│   └── src/main.go                 # Installer logic (DTB inject, etc.)
├── internal/base/pkg.yaml           # Base layer
├── profiles/radxa-e24c/             # SBC profile
└── scripts/
    ├── setup-talos-src.sh           # Idempotent fork clone
    └── rebuild-imager.sh            # Rebuilds imager from talos fork source
```

## License

Same as `siderolabs/sbc-template` (upstream).
