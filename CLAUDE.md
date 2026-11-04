# CLAUDE.md

Guidance for Claude Code working in this repository.

## Overview

Flake-based NixOS for **unicomplex**, an original Jetson Nano developer kit
(P3450: P3448-0000 module, P3449 B01 carrier, Tegra210, 4 GB). Headless, no
GPU/CUDA; it will eventually host Hermes Agent with remote inference.
Background, hardware evidence and the phased plan:
`jetson_nano_nixos_hermes_plan.md`. `README.md`: current system, how to
reproduce it, how it was worked out (curated, readable). `docs/bringup-log.md`:
raw dated engineering notes with full measurements.

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
  (Ubuntu 18.04 / L4T 32.5.1). After NixOS: `ssh sirhc@unicomplex` (currently 192.168.17.179; name not in router DNS yet).
- Bootloader: vendor U-Boot 2020.04 in QSPI. **Never** flash QSPI or
  `saveenv` without explicit approval; use temporary `setenv` at the U-Boot
  prompt for experiments.

## Tools

- `tools/nano-serial.py` — serial console: `log`, `uboot [-f SECS] CMD…`, `send`
- `tools/reboot-cycle.sh [N] [HOST]` — timed reboots + health line per cycle
- `tools/boot-menu-pick.py N [HOST]` — reboot and pick extlinux entry N (rollback)
- `tools/l4t-emc-to-bin.py` — L4T EMC DT tables → mainline binary (used by the build)
- `tools/membw.c` — DRAM bandwidth check (expect ~11 GB/s copy at 1600 MHz)

Only one process may read the serial port at a time (readers split the data).

## Key constraints

- U-Boot `ramdisk_addr_r=0x83200000` is only 14 MiB below
  `kernel_addr_r=0x84000000` and initrd_high=~0, so the ~25 MB systemd initrd
  would be overwritten. Fix: only SD partition 1 (FAT) is bootable and holds
  `/boot.scr`, which sets `ramdisk_addr_r=0xa0000000` then `sysboot`s
  partition 2's extlinux.conf. The env's `preboot` hook is NOT executed by
  this U-Boot. `boot.scr` and the bootable flag come only from the image
  build. `hardware.enableAllHardware` is forced off to keep the initrd lean.
- `pgrep -f`/`pkill -f` patterns run via the Bash tool match the tool's own
  command line; use `pgrep -f '[t]ools/nano-serial'` style patterns.
- Kernel is the release default (`pkgs.linuxPackages`), from cache. Boot-critical
  Tegra drivers (sdhci-tegra, max77620, i2c-tegra, pci-tegra, serial) are `=y`;
  `mmc_block`, `r8169`, `xhci-tegra` are modules.
- Change one major variable at a time while boot-debugging.

## Workflow

Commit sensible, self-contained changes with descriptive messages. Append
findings to `docs/bringup-log.md` (dated, detailed) and keep `README.md`
current at a readable level: no serial numbers, MACs, IPs or vendor part
names there.
