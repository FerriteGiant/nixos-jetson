# CLAUDE.md

Guidance for Claude Code working in this repository.

## Overview

Flake-based NixOS for **unicomplex**, an original Jetson Nano developer kit
(P3450: P3448-0000 module, P3449 B01 carrier, Tegra210, 4 GB). Headless, no
GPU/CUDA; it will eventually host Hermes Agent with remote inference.
Background, hardware evidence and the phased plan:
`jetson_nano_nixos_hermes_plan.md`. Current state and bring-up findings:
`README.md`.

The style mirrors `../nixos_server/nix-config` (the Linode host).

## Layout

```
flake.nix                       # nixos-26.05; nixosConfigurations.unicomplex + packages.aarch64-linux.sdImage
common-configuration.nix        # host-agnostic baseline: ssh, user sirhc, sudo, nix settings, packages
modules/jetson-nano.nix         # board support: kernel, DTB, console, initrd, firmware, sd-image
hosts/unicomplex/configuration.nix
```

## Build host

Builds run on the Linux Mint laptop (x86_64) as native `aarch64-linux`
derivations through qemu-user binfmt (`extra-platforms = aarch64-linux` in
`/etc/nix/nix.conf`, Nix daemon >= 2.34). Almost everything is substituted from
cache.nixos.org; do not switch to cross-compilation (no cache hits, kernel
rebuild). Nixpkgs 26.05 needs Nix >= 2.18 for evaluation and a modern daemon
for structured-attrs builds.

```bash
nix build .#packages.aarch64-linux.sdImage -o result-sdimage   # flashable image (.img.zst)
nix build .#nixosConfigurations.unicomplex.config.system.build.toplevel
```

The flake only sees git-tracked files: `git add` new files before building.

## Hardware access

- Serial console: `/dev/serial/by-id/usb-1a86_USB_Single_Serial_5734003039-if00`
  (ttyACM0), 115200 8N1, Nano UARTA = `ttyS0`. pyserial is available on the laptop.
- Network: MAC `00:04:4b:ea:d9:87`. Before NixOS: `ssh nanosaur@nanosaur`
  (Ubuntu 18.04 / L4T 32.5.1). After NixOS: `ssh sirhc@unicomplex`.
- Bootloader: vendor U-Boot 2020.04 in QSPI. **Never** flash QSPI or
  `saveenv` without explicit approval; use temporary `setenv` at the U-Boot
  prompt for experiments.

## Key constraints

- U-Boot `ramdisk_addr_r=0x83200000` is only 14 MiB below
  `kernel_addr_r=0x84000000`: the initrd must stay < 14 MiB, or override
  `ramdisk_addr_r` at the U-Boot prompt. Hence `hardware.enableAllHardware =
  mkForce false` and a minimal `boot.initrd.availableKernelModules`.
- Kernel is the release default (`pkgs.linuxPackages`), from cache. Boot-critical
  Tegra drivers (sdhci-tegra, max77620, i2c-tegra, pci-tegra, serial) are `=y`;
  `mmc_block`, `r8169`, `xhci-tegra` are modules.
- Change one major variable at a time while boot-debugging.

## Workflow

Commit sensible, self-contained changes with descriptive messages; keep
`README.md` (status / bring-up log) up to date with findings.
