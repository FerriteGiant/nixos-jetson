# Bring-up log (raw)

Chronological engineering notes with full measurements, addresses and
identifiers, kept for reference. The README has the curated version.


## 2026-11-03 — builder, flake, image

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

## 2026-11-03 — first boots

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

## 2026-11-03 — EMC (DRAM clock) scaling

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

## 2026-11-03 — Tailscale, self-update, reboot hang

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

## 2026-11-03 — Ethernet

- The 100 Mbit link (`Downshift occurred from negotiated speed 1Gbps to actual
  speed 100Mbps, check cabling!`) was the cable: after replacing it, `Link is
  Up - 1Gbps/Full`, no downshift, also after a reboot.
- PHY driver is the Realtek one (`Generic FE-GE Realtek PHY`, the RTL8168h
  internal PHY); NIC firmware `rtl8168h-2_0.0.2 02/26/15` loads (zstd-compressed
  firmware is supported by the kernel). EEE not supported.
- Throughput: 32.7 MB NAR from cache.nixos.org at up to 71.7 MB/s (~573
  Mbit/s; WAN/CDN-limited). `ethtool -S` error/drop counters all zero.

## 2026-11-04 — headless DT cleanup, rollback, storage

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

## 2026-11-04 — brownout / reset-reason detection

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

## 2026-11-04 — INA3221 power monitor

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

## 2026-11-04 — USB SSD validation

- **Hardware:** WD PC SA530 256 GB M.2 **SATA** SSD (`SDATB8Y256G1001`, fw
  40102101) in a VIA Labs **VL716** (`2109:0716`) enclosure; `uas` driver at
  5 Gbit/s through the carrier's internal USB 3 hub. Pre-existing empty btrfs
  `WD256` (made by Chris 2026-11-04).
- **Health (smartctl -d sat):** PASSED; 0 reallocated / uncorrectable / CRC
  errors, error log empty, wear indicator 98, 28 359 power-on h (used drive),
  34–38 °C. `smartctl -d snt*` probes send ATA PASS-THROUGH(12) (0xa1),
  which the bridge ignores → 60 s timeout + `uas_eh_device_reset` (seen twice,
  both from those probes; none during real I/O). Use `-d sat`.
- **Throughput** (fio, file on btrfs, direct I/O unless noted):

  | | SSD | SD card |
  |---|---|---|
  | seq read 1M | 384 MB/s | 83.6 MB/s |
  | seq write 1M | 121 MB/s (193 buffered) | 38.5 MB/s |
  | 4K rand read QD32 | 7952 IOPS | 1714 IOPS |
  | 4K rand write QD32 | 2706 IOPS | 341 IOPS |

  Direct write is not CPU-bound (72 % idle): drive/bridge write path.
- **Integrity:** 4 GiB urandom write → drop caches → sha256 match; btrfs scrub
  no errors (343 MiB/s).
- **TRIM:** drive supports it (deterministic, zeroed); the bridge advertises
  UNMAP in its LBP VPD page but reports `lbpme=0`, so the kernel set
  `provisioning_mode=full`. Forced `unmap`: `fstrim` trimmed 232.7 GiB, test
  file intact, scrub clean. Persisted with a udev rule on the **block** add
  event (`hosts/unicomplex/configuration.nix`); a `scsi_disk` add rule is
  overwritten when sd revalidates the disk. After reboot: unmap, DISC-MAX 4G.
- **Supply:** during SSD I/O VDD_IN min 4.976 V (≤ 872 mA); CPU ×4 stress +
  sustained SSD write: min **4.944 V**, mean 5.008 V, ≤ 1.17 A (~4.8 W).
  No vdd-in-monitor warnings.
