# unicomplex — NixOS on the original Jetson Nano

Headless NixOS 26.05 on a Jetson Nano developer kit (P3450, B01 carrier,
4 GB), upstream kernel, no GPU stack. Future home of Hermes Agent.
Background and phased plan: [`jetson_nano_nixos_hermes_plan.md`](jetson_nano_nixos_hermes_plan.md).

## Status

| Phase (see plan) | State |
| --- | --- |
| A — preserve working system | Skipped by decision: Ubuntu card data is disposable; card will be reused. QSPI untouched. |
| B — Mint builder | **Done.** qemu-user binfmt + `extra-platforms = aarch64-linux`; Nix daemon upgraded 2.13.1 → 2.34.9 (needed for nixpkgs 26.05). |
| C — minimal image | **Done.** |
| D — write & boot | **Done 2026-11-03.** Boots unattended to login + SSH; no failed units. |
| E — qualify | **In progress.** EMC (DRAM clock) scaling fixed: 1600 MHz, ~11 GB/s. Open: Ethernet links at 100 Mbit (downshift; deferred), one slow (~2 min) reboot seen, Tailscale key, GitHub remote. |
| F — Hermes | Not started. |

## Build

```bash
nix build .#packages.aarch64-linux.sdImage -o result-sdimage
# -> result-sdimage/sd-image/nixos-unicomplex.img.zst  (~570 MiB, 2.45 GiB raw)
```

First build from scratch takes ~25 min on the laptop (mostly emulated
mkfs/zstd of the image); packages come from cache.nixos.org.

## Write the card

Data on the current card is disposable. From the laptop, with the card in a
reader (verify the device with `lsblk` first — this erases it):

```bash
zstdcat result-sdimage/sd-image/nixos-unicomplex.img.zst | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress
```

The root partition grows to fill the card on first boot.

## Access

| | |
| --- | --- |
| SSH | `ssh sirhc@192.168.17.179` (key only; DHCP on `eth0`, MAC `00:04:4b:ea:d9:87`). `unicomplex` doesn't resolve via the router yet. |
| Serial | `tools/nano-serial.py` — UARTA/J50, 115200 8N1, `ttyS0`; login `sirhc` / temporary password `unicomplex` (change it) |
| sudo | passwordless for wheel during bring-up |

## Updating a running system

Like the Linode, the Nano updates itself from a clone of this repo at
`~/nixos-jetson` (GitHub, per-repo deploy key `~/.ssh/github_deploy` with
write access, so it can also commit and push):

```bash
cd ~/nixos-jetson && git pull
rsf     # alias: sudo nixos-rebuild switch --flake ~/nixos-jetson
```

From the laptop (faster eval; pushes the closure):

```bash
T=$(nix build --no-link --print-out-paths .#nixosConfigurations.unicomplex.config.system.build.toplevel)
nix copy --no-check-sigs --to ssh-ng://sirhc@<nano> $T   # ssh-ng proxy doesn't pass trust
ssh sirhc@<nano> "sudo nix-env -p /nix/var/nix/profiles/system --set $T && sudo $T/bin/switch-to-configuration switch"
```

The bootloader install step (`system.build.installBootLoader`) runs the
stock extlinux builder and then syncs `boot.scr` and the EMC tables onto the
FAT partition. The partition-1 bootable flag only comes from the image
build.

## Boot chain

QSPI (CBoot → U-Boot 2020.04, default env) → distro_bootcmd scans `mmc 1`
bootable partitions → p1 (FAT) has no extlinux.conf, runs `/boot.scr`, which
(RAM only, no `saveenv`):

1. `setenv ramdisk_addr_r 0xa0000000` (initrd clear of the kernel)
2. drops `/external-memory-controller@7001b000` from `fdt_copy_node_paths`
   (stops U-Boot replacing the upstream EMC node with L4T's)
3. zeroes and loads `emc-nominal.bin`/`emc-derated.bin` to
   `0x83400000`/`0x83408000`
4. `sysboot mmc 1:2 … /boot/extlinux/extlinux.conf`

→ NixOS generation menu → kernel + upstream `tegra210-p3450-0000.dtb` (+
overlay: EMC reserved-memory regions) → systemd initrd → root `NIXOS_SD` →
`emc-max-rate.service` pins DRAM at 1600 MHz.

### Recovery

If `boot.scr` is broken, interrupt U-Boot over serial and run:

```
setenv ramdisk_addr_r 0xa0000000
sysboot mmc 1:2 any 0x90100000 /boot/extlinux/extlinux.conf
```

Older NixOS generations are in the extlinux menu (5 s timeout).

## Bring-up log

### 2026-11-03 — builder, flake, image

- Laptop: Mint 21.3 x86_64. Nix 2.13.1 could not evaluate nixpkgs 26.05
  (needs ≥ 2.18) and its daemon broke structured-attrs builds
  (`source-stdenv.sh: /setup: No such file or directory`). Upgraded to 2.34.9.
- Jetson (Ubuntu): `/proc/mtd` → `mtd0` 4 MiB `spi32766.0` (QSPI).
  NIC: RTL8111/8168 rev 15 on Tegra PCIe.
- U-Boot (`printenv`/`bdinfo`, captured over serial):
  - DRAM banks `0x80000000+0x7ee00000`, `0x100000000+0x7f200000`;
    U-Boot relocated at `0xfed2f000`, fdt/stack around `0xfc5fa000`.
  - `kernel_addr_r=0x84000000 ramdisk_addr_r=0x83200000 fdt_addr_r=0x83000000
    scriptaddr=0x90000000 pxefile_addr_r=0x90100000`,
    `initrd_high=fdt_high=ffffffffffffffff` (no relocation),
    `xusb_fw_addr=92ca828c`, `bootdelay=2`.
  - `mmc list`: SD slot is **mmc 1** (`sdhci@700b0000`), mmc 0 is empty.
  - The env defines `preboot` (sources `/u-boot-preboot.scr` from `mmc 1:1`)
    but this build **never runs it** (no `CONFIG_USE_PREBOOT`, evidently).
- Kernel 6.18.60 (nixpkgs default): `Image` 64.5 MB, header `image_size`
  62.7 MiB → occupies `0x84000000–0x87eb0000`.
  sdhci-tegra, max77620 (mfd/regulator/pinctrl/gpio), i2c-tegra, pci-tegra,
  phy-tegra-xusb, serial 8250/tegra, ext4 are built in; `mmc_block`, `r8169`,
  `xhci-tegra`, `tegra-soctherm`, `tegra210-emc` are modules.
- initrd: 26.05's default **systemd stage 1 is 25.3 MB** (86 MB unpacked:
  systemd, openssl, tpm2-tss…) even with only `mmc_block` + defaults, far
  over the 14 MiB gap. Scripted stage 1 is deprecated (removal in 26.11), so
  the initrd is moved to `0xa0000000` instead (see Boot chain).
- `sd-image.nix` enables `hardware.enableAllHardware`; forced off.
- linux-firmware `nvidia/tegra210/nvjpg.bin` is a symlink into `tegra186/`;
  copy with `cp -rL`.
- System closure 1.6 GiB.
- Verified image: p1 FAT `FIRMWARE` 30 MiB with `u-boot-preboot.scr`
  (legacy script image), p2 ext4 `NIXOS_SD` flagged bootable;
  `/boot/extlinux/extlinux.conf` has LINUX/INITRD/FDT (`tegra210-p3450-0000.dtb`)
  and `init=` for the system closure; 5 s menu timeout.

### 2026-11-03 — first boots

- Wrote the card from the laptop (`wipefs -a` first to drop the old GPT
  backup header, then `dd`).
- **Boot 1:** U-Boot 2020.04 loaded extlinux → kernel + DTB fine, but
  `Initramfs unpacking failed: ZSTD-compressed data is corrupt` → oops in
  `free_initrd_mem`, hang. No `preboot` output: the hook isn't executed.
  U-Boot also reports `Loading Environment from SPI Flash... bad CRC, using
  default environment` — env has never been saved.
- **Boot 2:** interrupted U-Boot over serial, `setenv ramdisk_addr_r
  0xa0000000`, `boot` → full boot to `unicomplex login:` in ~40 s; SSH OK.
- Switched to the `boot.scr` method (only p1 bootable); applied in place on
  the running system (copied `boot.scr` to p1, `sfdisk --activate
  /dev/mmcblk1 1`, removed `u-boot-preboot.scr`).
- **Boot 3:** unattended reboot: `Found U-Boot script /boot.scr` → NixOS. ✅
- Health: `systemctl is-system-running` = running, no failed units; NTP
  synced (no RTC battery: clock is wrong until NTP); root grown to 58 GB;
  3.5 GB RAM free; thermal zones cpu/gpu/pllx/mem readable (~25 °C idle).
- Linux names the SD card `mmcblk1` (U-Boot: `mmc 1`).
- Known warnings: `tegra210-emc` probe fails (-2, no DRAM frequency
  scaling); `tegra-vi` missing `ports` (camera, irrelevant); thermal
  cooling-map phandle warnings; `max77620` device-link warning; `tegra_drm`
  and `host1x` load (display; harmless, could be blacklisted).
- Ethernet: RTL8168h on generic PHY driver; link
  `Downshift occurred from negotiated speed 1Gbps to actual speed 100Mbps,
  check cabling!` — check cable/switch port, then the Realtek PHY driver.

### 2026-11-03 — EMC (DRAM clock) scaling

- Symptom: `emc` clock stuck at 204 MHz; `tegra210-emc` probe -2;
  `could not find phandle 480/286`. DRAM bandwidth (tools/membw.c, 4
  threads, 64 MiB arrays): copy 2245 / scale 2213 / triad 1909 MB/s.
- Cause: vendor U-Boot env
  `fdt_copy_node_paths=…:/external-memory-controller@7001b000:/memory@80000000`
  copies CBoot's L4T EMC node over the upstream one: L4T clocks list (phandles
  from the L4T tree), L4T-format `emc-table@<ramcode>/emc-table@<khz>`
  children, and phandle 0x21, which collides with `/i2c@7000c700`. The upstream
  DT also lacks the `nvidia,tegra210-emc-table` reserved memory that
  mainline expects the bootloader to fill.
- Board RAM code 0 (`tegra-mc: … RAM code 0`). L4T has tables for RAM
  codes 0 and 2; each has nominal + derated entries at 204000 and 1600000 kHz,
  revision 0x7 (= mainline's r21021 sequence).
- Fix: see Boot chain. Converter maps L4T props 1:1 onto
  `struct tegra210_emc_timing` (4928 B; checked against the v6.18 header).
- Result: driver probes (`available_rates 204000000 1600000000`); 50
  transitions 204↔1600 clean; copy 11256 / scale 10986 / triad 9266 MB/s
  (5×). memtester 2G (1 loop, all 16 tests ok) concurrently with 3-core
  stress-ng at 1600 MHz, ~18 min: no errors; peak ~60 °C.
- Mainline has no Tegra210 EMC devfreq governor, so `emc-max-rate.service`
  pins 1600 MHz (the driver still handles temperature derating/refresh).
- CPU: `cpufreq-dt`/schedutil, 204–1555.5 MHz. Under 3-core load 1.555 GHz
  at ~40 °C (cpu-thermal).
- One `systemctl reboot` (before the EMC change, at ~29 min uptime) stalled ~2
  min after `shutdown[1]: Rebooting.` before TegraBoot started (both normal and
  this one report `Power-up reason: pmc por`). Others are immediate. Watch.
