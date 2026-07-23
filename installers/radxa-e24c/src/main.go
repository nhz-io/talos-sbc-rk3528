// This Source Code Form is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

package main

import (
	"fmt"
	"os"
	"path/filepath"

	"github.com/siderolabs/go-copy/copy"
	"github.com/siderolabs/talos/pkg/machinery/overlay"
	"github.com/siderolabs/talos/pkg/machinery/overlay/adapter"
	"golang.org/x/sys/unix"
)

const (
	// U-Boot is written at 32KB offset (Rockchip convention: 512 * 64)
	ubootOffset int64 = 512 * 64
	// DTB path relative to the artifacts directory
	dtbPath = "rockchip/rk3528-radxa-e24c.dtb"
)

func main() {
	adapter.Execute(&RadxaE24CInstaller{})
}

type RadxaE24CInstaller struct{}

type radxaE24CExtraOptions struct {
	Console    []string `json:"console"`
	ConfigFile string   `json:"configFile"`
}

func (i *RadxaE24CInstaller) GetOptions(extra radxaE24CExtraOptions) (overlay.Options, error) {
	kernelArgs := []string{
		"earlycon=uart8250,mmio32,0xff9f0000",
		"console=ttyS0,1500000n8",
		"sysctl.kernel.kexec_load_disabled=1",
		"talos.dashboard.disabled=1",
		"slab_nomerge",
		"consoleblank=0",
		"cgroup_enable=cpuset",
		"swapaccount=1",
		"coherent_pool=2M",
	}

	kernelArgs = append(kernelArgs, extra.Console...)

	return overlay.Options{
		Name:       "radxa-e24c",
		KernelArgs: kernelArgs,
		PartitionOptions: overlay.PartitionOptions{
			Offset: 2048 * 10,
		},
	}, nil
}

func (i *RadxaE24CInstaller) Install(options overlay.InstallOptions[radxaE24CExtraOptions]) error {
	uBootBin := filepath.Join(options.ArtifactsPath, "arm64/u-boot/radxa-e24c/u-boot-rockchip.bin")

	if err := writeUBoot(uBootBin, options.InstallDisk); err != nil {
		return fmt.Errorf("writing u-boot: %w", err)
	}

	src := filepath.Join(options.ArtifactsPath, "arm64/dtb", dtbPath)
	dst := filepath.Join(options.MountPrefix, "boot/EFI/dtb", dtbPath)

	if err := copyFileAndCreateDir(src, dst); err != nil {
		return fmt.Errorf("copying DTB: %w", err)
	}

	if options.ExtraOptions.ConfigFile != "" {
		// placeholder for future config file handling
	}

	return nil
}

func writeUBoot(uBootBin, installDisk string) error {
	f, err := os.OpenFile(installDisk, os.O_RDWR|unix.O_CLOEXEC, 0o666)
	if err != nil {
		return fmt.Errorf("opening install disk: %w", err)
	}
	defer f.Close() //nolint:errcheck

	uboot, err := os.ReadFile(uBootBin)
	if err != nil {
		return fmt.Errorf("reading u-boot binary: %w", err)
	}

	if _, err = f.WriteAt(uboot, ubootOffset); err != nil {
		return fmt.Errorf("writing u-boot at offset %d: %w", ubootOffset, err)
	}

	// Sync to ensure writes are flushed before any loopback device is unmounted
	return f.Sync()
}

func copyFileAndCreateDir(src, dst string) error {
	if err := os.MkdirAll(filepath.Dir(dst), 0o600); err != nil {
		return fmt.Errorf("creating DTB directory: %w", err)
	}

	return copy.File(src, dst)
}