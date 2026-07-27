# Agent Instructions — talos-sbc-rk3528

This repo builds the Radxa E24C (RK3528A) Talos SBC image, U-Boot, and extensions.

## Build rules (NON-NEGOTIABLE)

### 1. The imager MUST be built with the SBC kernel

The SBC kernel (`ghcr.io/nhz-io/talos-kernel-rk3528:v0.5.1-talos`) contains the Rockchip GMAC driver + RTL8365MB switch driver. Without it, e24c boots with NO network interfaces — `end0`/`wan` are never created and every service hangs.

- Use `scripts/rebuild-imager.sh` — it passes `PKG_KERNEL` + `PKG_KERNEL_AMD64` correctly.
- NEVER run `make docker-imager` directly without `PKG_KERNEL`. The Makefile defaults to the stock Sidero kernel (clang, no SBC drivers).
- The amd64 kernel uses stock Sidero (`ghcr.io/siderolabs/kernel:v1.13.0-49-g91fe0a0`) because the SBC kernel is arm64-only.

### 2. Use `--tmpfs /tmp` for builds on macOS

macOS APFS is case-insensitive. The tailscale extension image has case-variant file pairs (`libip6t_HL.so` + `libip6t_hl.so`) that collide on APFS. `archiver.Untar` uses `os.O_EXCL` and fails.

Both `build.sh` Step 6a (installer) and Step 6b (metal image) use `--tmpfs /tmp:rw,exec,size=2g` instead of `-v /tmp:/tmp`. Do not revert this.

### 3. Tag scheme: `<version>-e24c-<ITERATION>-<git-short-hash>`

All three parts required: `e24c` marker, iteration number (bump from previous), AND 7-char git hash. Example: `v1.13.7-e24c-2-e794f71`.

### 4. Do not reuse artifacts from broken builds

When rebuilding the imager, verify the kernel is correct before deploying:
```
docker create --entrypoint /bin/true ghcr.io/nhz-io/imager-rk3528:<tag>
docker cp <cid>:/usr/install/arm64/vmlinuz /tmp/vmlinuz
sha256sum /tmp/vmlinuz   # must match known-good SBC kernel: 71db7b0952...
```

If the hash differs from the known-good SBC kernel, the imager was built with the wrong kernel. Rebuild with `PKG_KERNEL`.

### 5. Extensions are official Sidero images (no fork/build needed)

- `ghcr.io/siderolabs/tailscale:1.98.8` — multi-arch (amd64 + arm64)
- `ghcr.io/siderolabs/cloudflared:2026.7.1` — multi-arch (amd64 + arm64)
- Versions pinned to extensions repo tag `v1.13.7` (see `network/vars.yaml`)

The `talos-extensions` submodule is a supply-chain reference only. Do not build extensions from it.

### 6. Do not pivot to destructive fallbacks when a fix is available

If `talosctl upgrade` fails, investigate the root cause. Do not jump to wiping NVMe / reflashing / rescue image / etcd reset. The effivarfs issue was fixed with a code patch (tolerate RO efivarfs + `loader.conf default`), not a reflash.

Reinstall is a LAST resort, not a first response.

### 7. Do not declare success without observed verification

"Upgrade exit code 0" is NOT success. Success is:
1. Node reachable at `55.55.55.243` over the network
2. `talosctl get extensions` shows the expected extensions
3. `talosctl services` shows `ext-tailscale` + `ext-cloudflared` as Running
4. Node Ready in k8s

### 8. Stick to proven methods

Read `build.sh`, `scripts/rebuild-imager.sh`, and the Obsidian note `Building Talos SBC RK3528 Overlay.md` before modifying the build flow. Don't invent new build paths. The existing flow works — changes should be additive.

## Build artifacts

| Artifact | Current tag | Purpose |
|----------|-------------|---------|
| `ghcr.io/nhz-io/imager-rk3528` | `v1.13.7-v14` | Imager (SBC kernel + effivarfs patch) |
| `ghcr.io/nhz-io/talos-sbc-rk3528-installer` | `1.13.7-e24c-3-a6c1bdc` | Extended installer (tailscale + cloudflared baked in UKI) |

## Fork branch + tag

- Fork: `nhz-io/sidero-talos`, branch `v1.13.7-rk3528`
- Tag: `v1.13.7-e24c-2-e794f71` at HEAD `e794f71`
- effivarfs patch: commit `a6c1bdc52`
- Makefile sed fix: commit `e794f71`

## Cluster: shinsenkyo

| Node | Role | IP | Tailscale IP | Talos version | Extensions |
|------|------|----|----|----|----|
| e24c | control-plane | 55.55.55.243 | 100.101.108.84 | v1.13.7-e24c-2-e794f71 | tailscale, cloudflared |
| tenma | worker | 55.55.55.90 | 100.116.29.109 | v1.13.7 (factory schematic aa3a362a) | tailscale, cloudflared, nvidia 595.71.05, i915, intel-ucode, mei |

SOPS-encrypted configs in `talos-local-cluster` (private repo). Decrypt before use:
```bash
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
sops --decrypt e24c/talosconfig > /tmp/tc.yaml
TALOSCONFIG=/tmp/tc.yaml talosctl -n 55.55.55.243 version
rm /tmp/tc.yaml
```

## Known-good kernel hash (for verification)

SBC kernel vmlinuz SHA256: `71db7b0952c9616d0008...` (first 20 chars). If the imager's vmlinuz doesn't start with this hash, it has the wrong (stock) kernel.
