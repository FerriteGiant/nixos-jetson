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
| E — qualify | Next. Open items: Ethernet links at 100 Mbit (downshift), `tegra210-emc` fails to probe (no DRAM DVFS), hostname not in router DNS yet. |
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

Once it boots (TBD — either build on the Nano or push from the laptop):

```bash
# on the Nano, from a checkout:
sudo nixos-rebuild switch --flake .#unicomplex
# or from the laptop:
nix run nixpkgs#nixos-rebuild -- switch --flake .#unicomplex \
  --target-host sirhc@unicomplex --sudo
```

Note: `/boot.scr` on the FAT partition and the partition-1 bootable flag are
written only when the image is built; `nixos-rebuild` does not touch them
(it only rewrites `/boot/extlinux/extlinux.conf` on partition 2, which
`boot.scr` chains to).

## Boot chain

QSPI (CBoot → U-Boot 2020.04, default env) → distro_bootcmd scans `mmc 1`
bootable partitions → p1 (FAT) has no extlinux.conf, runs `/boot.scr` →
`setenv ramdisk_addr_r 0xa0000000` (RAM only) → `sysboot mmc 1:2 …
/boot/extlinux/extlinux.conf` → NixOS generation menu → kernel + upstream
`tegra210-p3450-0000.dtb` → systemd initrd → root `NIXOS_SD`.

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
