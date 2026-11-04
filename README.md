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
| E — qualify | **Done 2026-11-04.** EMC (DRAM clock) scaling fixed: 1600 MHz, ~11 GB/s. Reboot hang fixed. Self-update via GitHub + Tailscale working. Ethernet 1 Gbit/s (cable). Headless DT cleanup. Rollback via boot menu, storage stress + integrity OK. |
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
| Health | `voltage [-w]` (INA3221 rails V/mA/mW + this boot's supply-dip events), `bootreason [N]` (reset reason of the last N boots), `journalctl -u vdd-in-monitor -p warning` (supply dips) |

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
- One `systemctl reboot` stalled ~2 min after `shutdown[1]: Rebooting.` before
  TegraBoot started; see next section.

### 2026-11-03 — Tailscale, self-update, reboot hang

- Tailscale up via `/etc/tailscale-authkey` (100.86.57.92, `--ssh`).
- GitHub `FerriteGiant/nixos-jetson` (private) with a per-repo deploy key
  (write) generated on the Nano. `git pull && rsf` on the Nano: 71 s,
  same store path as the laptop build. `git push --dry-run` from the Nano OK.
- **Reboot hang:** timestamped serial (`host time` per line) showed a
  128.2 s gap between the last kernel line and TegraBoot in slow cycles, i.e.
  the max77620 watchdog (max timeout ~128 s, armed by systemd-shutdown)
  rescuing a hung restart. In slow cycles the last line is
  `tegra-xusb 70090000.usb: Firmware timestamp…` (controller being resumed
  from runtime suspend during device shutdown); fast ones continue
  `r8169 … Link is Down` / `kvm: exiting…` / `reboot: Restarting system`.
  Before: 4/7 reboots slow (~190 s to SSH vs ~65 s). With
  `70090000.usb/power/control=on` (udev rule): 10/10 immediate.
- `reboot-cycle.sh`, 6 cycles: ~64 s reboot→SSH, `running`, no failed units,
  EMC 1600 MHz, same 5 known err-level messages each boot.
- Side effect of blacklisting host1x: `i2c@7000c700` (HDMI DDC) waits forever
  for the dpaux pinmux, and `tegra-pmc`/`tegra-mc` `sync_state()` stays
  pending. Harmless; cleaner to disable those nodes in the DT (todo).
- From the laptop, `ssh sirhc@unicomplex` occasionally fails with `socket:
  Address family not supported by protocol` right after a reboot (name briefly
  resolving to an IPv6 address the laptop can't use). `ssh -4` or the Tailscale
  IP works.

### 2026-11-03 — Ethernet

- The 100 Mbit link (`Downshift occurred from negotiated speed 1Gbps to actual
  speed 100Mbps, check cabling!`) was the cable: after replacing it, `Link is
  Up - 1Gbps/Full`, no downshift, also after a reboot.
- PHY driver is the Realtek one (`Generic FE-GE Realtek PHY`, the RTL8168h
  internal PHY); NIC firmware `rtl8168h-2_0.0.2 02/26/15` loads (zstd-compressed
  firmware is supported by the kernel). EEE not supported.
- Throughput: 32.7 MB NAR from cache.nixos.org at up to 71.7 MB/s (~573
  Mbit/s; WAN/CDN-limited). `ethtool -S` error/drop counters all zero.

### 2026-11-04 — headless DT cleanup, rollback, storage

- DT overlay disables `/host1x@50000000`, `/i2c@7000c700`, `/mipi@700e3000`:
  no more deferred probes or pending `sync_state()`. Remaining err-level
  messages each boot (cosmetic): 4× `tegra-clk-debug: … connection ID is
  greater than 16`, 1× `max77620 … Failed to create device link`.
- Rollback: `tools/boot-menu-pick.py 4` selected generation 4 in the extlinux
  menu over serial; `/run/booted-system` = gen 4 (own DTB, no udev fix:
  `power/control=auto`). Plain reboot returned to the default (gen 6).
- SD card (`USD00`, 58.2 GiB, 02/2020) at UHS-I SDR104. fio direct I/O: seq
  write 38.5 MB/s, seq read 83.6 MB/s, 4K rand read 1714 IOPS (QD32), 4K rand
  write 341 IOPS. 2 GiB urandom write → drop caches → sha256 read-back match.
  No mmc/ext4/I/O errors. Random-write IOPS are the weak spot; consider a USB
  SSD for Hermes state (plan, phase E/F).

### 2026-11-04 — brownout / reset-reason detection

- TegraBoot prints the MAX77620 **NVERC** (non-volatile event recorder) every
  boot: `pmic max77620 NVERC : 0x..`. Observed values matched events:
  `0x00` every clean software reboot; `0x02` (WTCHDG) both 128 s watchdog
  reboots; `0x40` (MBU, input undervoltage) and `0x50` (MBU + MBLSD,
  low-input shutdown) after pulling the power plug. **A brownout shows as
  0x40/0x10 on a boot where nobody pulled the plug**; it can't be told apart
  from a deliberate unplug.
- Linux reads NVERC (`i2cget -f -y 1 0x3c 0x0c`) as `0x00` even right after
  a plug cycle → TegraBoot clears it before Linux. The Tegra PMC sysfs
  `reset_reason` does distinguish `POWER_ON_RESET` (plug cycle) from
  `SW_MAIN` (software reboot), but can't say *why* power went away; NVERC can.
- U-Boot `i2c dev 0; i2c md 0x3c 0x0c 1` also reads 0x00 (cleared). But
  CBoot's DT (`fdt addr ${fdt_copy_src_addr}; fdt print /chosen`) has
  `reset { pmic_reset_status = <0x40>; pmc_reset_status = <0x0>; }`, and
  `/chosen/reset` is in `fdt_copy_node_paths`, so Linux sees it at
  `/proc/device-tree/chosen/reset/`. **`pmic-reset-reason.service`** decodes
  and logs it each boot (warning level for watchdog/thermal/undervoltage):
  - plug cycle: `PMIC NVERC=0x40 -> MBU(input-undervoltage); Tegra PMC reset:
    power-on (0x00000000)` + `input power dropped: brownout, unless the board
    was unplugged`
  - `systemctl reboot`: `PMIC NVERC=0x00; Tegra PMC reset: software-reboot
    (0x00000003) (clean)`
  - Check with `journalctl -b -u pmic-reset-reason` (or `-b -1` etc.).
- NVERC bit names beyond the observed 0x02/0x10/0x40 are from the MAX77620
  register description, not observed here.
- **INA3221 power monitor** enabled (see next section).

### 2026-11-04 — INA3221 power monitor

- Not on `i2c@7000c400` (U-Boot bus 2 probe: empty; bus 3 = c500: only EEPROMs
  0x50/0x57). It's at 0x40 on **`i2c@546c0000` (VI I2C, L4T bus 6)**, a
  child of host1x. host1x is now enabled (unblacklisted) with all its
  display/camera children disabled in the DT; `ti,ina3221` node with
  `VDD_IN`/`VDD_GPU`/`VDD_CPU`, 5 mΩ shunts (as in L4T). hwmon `ina3221`
  (`in1..3`, `curr1..3`); no deferred probes / pending sync_state.
- 5 Hz sampling of VDD_IN (supply as connected on 2026-11-04):

  | | V min / mean | I mean / max | P |
  |---|---|---|---|
  | idle | 4.664 / 4.714 V | 546 / 640 mA | ~2.6 W |
  | stress-ng 4 CPU + 2 vm (256M) | **4.536** / 4.589 V | 1128 / 1360 mA | ~5.2 W |

  ~0.13 V sag for ~0.6 A → ~0.2 Ω source + cable resistance. Already below
  5 V −5 % (4.75 V) at idle. An SSD (~0.5–1 A more) would push it lower.
- **Switched to the 5 V barrel jack (J48)**, same test:

  | | V min / mean | I mean / max | P |
  |---|---|---|---|
  | idle | 5.088 / 5.096 V | 492 / 760 mA | ~2.5 W |
  | stress-ng 4 CPU + 2 vm (256M) | **4.968** / 5.009 V | 1042 / 1256 mA | ~5.2 W |

  In spec under load with ~0.2 V margin; ~0.09 V sag per ~0.55 A. The swap
  itself was logged by pmic-reset-reason as `NVERC=0x40 -> MBU`, as expected.
- VDD_GPU 0 mA (GPU power-gated); VDD_CPU ≈ 100 mA idle. Shunt values are
  L4T's; bus voltages don't depend on them, currents do.
- **`vdd-in-monitor.service`** (`modules/vdd-in-monitor.sh`): samples VDD_IN
  at 5 Hz, 1 s moving average (5 samples); warning when the average drops
  below **4700 mV**, clears above 4750 mV (hysteresis), reminder at most
  once a minute while low (with the lowest average), notice on recovery
  (duration + lowest), info summary hourly. ~0.7 % of one core. Thresholds
  are env vars in `modules/jetson-nano.nix`. Test with raised thresholds
  (5050/5080) + stress burst produced exactly: warn → reminders → recovered →
  summary. Check: `journalctl -u vdd-in-monitor -p warning`.
