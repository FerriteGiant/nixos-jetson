# NixOS on the original Jetson Nano

A flake for running headless NixOS 26.05 on the original (Maxwell, 4 GB)
Jetson Nano developer kit, with the **mainline** Linux kernel and no NVIDIA
GPU stack. It boots from an SD card through NVIDIA's stock bootloader, which
stays unmodified in the module's QSPI flash. Memory clock scaling, power
monitoring and reset-reason logging all work; the GPU, display and camera
are deliberately left off.

- [1. What works](#1-what-works)
- [2. Installation](#2-installation)
- [3. How it was worked out](#3-how-it-was-worked-out)

---

## 1. What works

### At a glance

| | |
| --- | --- |
| OS | NixOS 26.05, flake-based, nixpkgs pinned in `flake.lock` |
| Kernel | Mainline 6.18 LTS (the nixpkgs default, from the binary cache, so nothing is compiled) |
| Device tree | Upstream `tegra210-p3450-0000.dtb` plus three small overlays (memory clock tables, headless, power monitor) |
| Bootloader | NVIDIA's stock CBoot + U-Boot in QSPI; untouched, nothing saved to its environment |
| CPU | 4× Cortex-A57, frequency scaling 204 MHz – 1.55 GHz |
| RAM | 4 GB LPDDR4 at **1600 MHz**, about 11 GB/s copy bandwidth |
| Storage | Root filesystem on the SD card (ext4) |
| Network | Gigabit Ethernet (DHCP); optional Tailscale |
| Not used | GPU, display/HDMI, camera; disabled in the device tree |

It takes about a minute from power-on (or `reboot`) to SSH.
Repeated reboots, memory and CPU stress, storage integrity tests and
rollback to older generations have all been tested (section 3).

### Layout of this repo

```
flake.nix                           nixosConfigurations.<host> + packages.aarch64-linux.sdImage
common-configuration.nix            user, SSH, Tailscale, sudo, nix settings, packages
hosts/<host>/configuration.nix      hostname and host-specific hardware quirks
modules/jetson-nano.nix             everything board-specific (boot, DT overlays, services)
modules/board-commands.nix          `voltage` and `bootreason`
modules/vdd-in-monitor.sh           supply-dip monitor
hw/l4t-emc-table-ramcode0.dtsi      NVIDIA's memory timing tables (source data)
tools/                              serial console, reboot and benchmark helpers
```

### Boot chain

The stock bootloader expects NVIDIA's own kernel. Three things about it
needed working around, all of them from a U-Boot script, so the flash and the
saved U-Boot environment stay untouched:

1. **The initrd load address.** U-Boot loads the initrd only 14 MiB below the
   kernel and never relocates it. NixOS's systemd initrd is about 25 MB, so
   the kernel would overwrite its end. The script moves it to `0xa0000000`.
2. **The memory-controller node.** U-Boot copies some nodes from NVIDIA's
   device tree into the one it boots with. One of them replaces the mainline
   memory-controller node with NVIDIA's version, which the mainline driver
   can't use. The script removes that node from the copy list.
3. **The memory timing tables.** The script loads them into reserved RAM so
   the mainline driver can find them (see below).

How the script gets run: the SD card has a small FAT partition (1) and the
ext4 root (2). Only the FAT partition is marked bootable, so U-Boot's normal
boot search finds no `extlinux.conf` there and runs its `/boot.scr` instead.
The script makes the changes above in RAM, then hands over to the
NixOS-managed `/boot/extlinux/extlinux.conf` on partition 2.

```
QSPI: CBoot → U-Boot ─▶ SD p1 (FAT): /boot.scr
                          │  ramdisk address, EMC node, EMC tables (RAM only)
                          ▼
                        SD p2 (ext4): /boot/extlinux/extlinux.conf
                          │  NixOS generation menu (5 s), kernel + DTB + initrd
                          ▼
                        systemd initrd → root by label → NixOS
```

`nixos-rebuild` keeps everything in sync: its bootloader step writes
`extlinux.conf` as usual, then refreshes `boot.scr` and the timing tables on
the FAT partition.

### Memory clock (EMC)

Out of the box the RAM ran at the 204 MHz clock the bootloader leaves it at,
which gave about 2.2 GB/s. Mainline Linux has the right driver
(`tegra210-emc`), but it expects the bootloader to supply the memory timing
tables in a binary format in reserved memory. NVIDIA's bootloader instead
passes them as device-tree nodes in its own older format, and in the process
breaks the mainline node.

The fix:

- The timing tables for the 4 GB developer kit's RAM type (RAM code 0: 204
  and 1600 MHz, normal and high-temperature variants) were extracted from
  what NVIDIA's bootloader passes in.
- `tools/l4t-emc-to-bin.py` converts them to the mainline binary layout at
  build time, and they're loaded into two reserved-memory regions declared by
  a device-tree overlay.
- The driver now probes and offers both rates. Mainline has no automatic
  memory frequency governor for this chip, so `emc-max-rate.service` pins
  1600 MHz at boot. The driver still adjusts refresh for temperature on its
  own.

Result: about **11 GB/s** copy bandwidth, a **5× improvement**. Validated with
memtester under concurrent CPU load and repeated 204↔1600 MHz switching.

### Power monitoring

The module has a 3-channel power monitor (INA3221) on the 5 V input, CPU and
GPU rails. Upstream doesn't describe it, so an overlay adds it on the bus
where it lives. That bus belongs to the camera/display block, which is
otherwise disabled. Readings appear as a standard hwmon device.

- **`voltage`** prints each rail's voltage, current and power, followed by
  any supply dips logged this boot. `voltage -w` refreshes every second.
- **`vdd-in-monitor.service`** samples the 5 V input five times a second and
  averages over one second.
  - It logs a **warning** when the average drops below 4.70 V. It clears
    only above 4.75 V, so a supply hovering at the threshold doesn't flood
    the log.
  - While the input stays low it reminds at most once a minute; it logs a
    notice on recovery with the duration and lowest value.
  - It logs an hourly summary at info level.
  - Thresholds are set in `modules/jetson-nano.nix`.

On a decent 5 V barrel-jack supply the input stays comfortably above the
warning threshold even under full load; micro-USB supplies tend not to.

### Boot reason logging

The power-management chip (PMIC) records why the board last reset or lost
power. NVIDIA's first-stage bootloader reads that register (which clears it)
and passes the value along in the device tree. `pmic-reset-reason.service`
decodes it on every boot, together with the SoC's own reset status.

- **`bootreason [N]`** lists the reason for the last N boots (default 5).

| What you see | Meaning |
| --- | --- |
| `NVERC=0x00 … software-reboot … (clean)` | Normal reboot |
| `-> WTCHDG(watchdog)` | The hardware watchdog had to reset the board |
| `-> MBU(input-undervoltage)` and/or `MBLSD(low-input-shutdown)` | Input power collapsed: either unplugged, or a **brownout** |

Anything other than a clean result is logged as a warning. An undervoltage on
a boot where nobody pulled the plug means the supply browned out.

### Reboot reliability

Without intervention, about half of all reboots hung for roughly two minutes
until the PMIC's watchdog reset the board. The cause was the USB 3
controller: if it is runtime-suspended when the kernel shuts down, waking it
during shutdown sometimes stalls the restart. A udev rule keeps that
controller out of runtime suspend. Since then, every reboot has been
immediate.

### Headless device tree

The NVIDIA GPU driver and the display and camera drivers are blocked from
loading. The display and camera nodes are also disabled in the device tree.
Only the bus that hosts the power monitor stays enabled. Disabling the nodes
rather than just blocking the drivers lets the kernel finish its power-domain
cleanup instead of waiting forever for devices that will never probe.

### Access and updates

- **SSH:** key-only login for the user defined in `common-configuration.nix`;
  password authentication and root login are disabled.
- **Tailscale (optional):** enabled with Tailscale SSH. It connects
  automatically once an auth key is placed in `/etc/tailscale-authkey`.
- **Serial console:** 115200 8N1 on the carrier's debug UART header, via a
  3.3 V UART-to-USB adapter. The console also gets a login prompt, and
  `tools/nano-serial.py` can log it or drive the U-Boot prompt.
- **sudo:** passwordless for the wheel group, a bring-up convenience. A
  `NOPASSWD` rule for `nixos-rebuild` alone is also included, so tightening
  is a one-line change.

**Self-updating:** the Nano can rebuild itself from a clone of this repo. The
config expects the clone at `~/nixos-jetson` and a GitHub deploy key at
`~/.ssh/github_deploy`. A deploy key is limited to a single repo; give it
write access if the Nano should also commit and push.

```bash
cd ~/nixos-jetson && git pull
rsf        # alias for: sudo nixos-rebuild switch --flake ~/nixos-jetson
```

A rebuild on the Nano takes about a minute, since packages come from the
binary cache, and gives the same result as building on another machine. Old
generations stay in the boot menu for rollback.

### Health commands

| Command | Shows |
| --- | --- |
| `voltage [-w]` | Power rails now, plus this boot's supply dips |
| `bootreason [N]` | Why each of the last N boots happened |
| `journalctl -u vdd-in-monitor -p warning` | Supply dips, any boot |
| `sudo cat /sys/kernel/debug/clk/emc/clk_rate` | Memory clock (expect 1600000000) |
| `sensors` | Temperatures and raw hwmon values |

### Known quirks

- A few harmless kernel messages appear at err level on each boot:
  clock-debug name warnings and one PMIC device-link warning.
- There's no RTC battery, so the clock is wrong until NTP syncs, shortly
  after the network comes up.
- The memory timing tables are for RAM code 0 (the 4 GB developer kit). See
  the caveat in section 2.

---

## 2. Installation

These steps take a Nano from whatever it's running (typically NVIDIA's
Ubuntu image) to the system described above. The SD card gets erased.

### Prerequisites

- **Board:** an original Jetson Nano developer kit (4 GB, B01 carrier).
  The module's QSPI flash must hold the boot firmware from **L4T 32.5 or
  newer** (JetPack 4.5+); only 32.5.1 has actually been tested. Check from
  NVIDIA's Ubuntu with `cat /etc/nv_tegra_release`. If it's older, update the
  QSPI firmware with NVIDIA's JetPack 4.5+ tools first (SDK Manager or
  `flash.sh`).
- **Power:** a 5 V / 4 A barrel-jack supply with the J48 jumper fitted.
  Micro-USB supplies sag below spec under load.
- **SD card:** 32 GB or larger; a USB card reader for the build machine.
- **UART-to-USB adapter (3.3 V)** on the debug UART header. It's optional
  once everything works, but it's the only way to see what goes wrong before
  the network is up.
- **Build machine:** x86_64 Linux with Nix **2.18 or newer** (nixpkgs 26.05
  requires it; a modern daemon is needed for builds), flakes enabled, and
  qemu user-mode emulation for aarch64:

  ```bash
  sudo apt install qemu-user-static           # or your distro's equivalent
  echo 'extra-platforms = aarch64-linux' | sudo tee -a /etc/nix/nix.conf
  sudo systemctl restart nix-daemon
  ```

  Almost everything comes prebuilt from cache.nixos.org; only small glue
  steps run under emulation.

### Steps

1. **Adapt the config.**
   - In `common-configuration.nix`, set your user name, SSH public key and
     git identity, and change the temporary serial-console password. Remove
     the Tailscale lines if you don't use it.
   - Rename `hosts/<host>/` and the matching `nixosConfigurations.<host>`
     entry in `flake.nix` to your hostname.
   - The host config carries a TRIM quirk for one specific USB-SATA bridge;
     drop it if you don't have that enclosure.
2. **Build the image** (about 25 minutes the first time):

   ```bash
   nix build .#packages.aarch64-linux.sdImage -o result-sdimage
   ```

3. **Write the card.** Check the device name with `lsblk` first:

   ```bash
   sudo wipefs -a /dev/sdX
   zstdcat result-sdimage/sd-image/*.img.zst | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress
   ```

   `wipefs` matters if the card previously had a GPT partition table: its
   backup copy at the end of the card would otherwise linger.
4. **Boot.** Put the card in the Nano, attach serial if you have it, and
   power on. You should see the boot script's banner, the NixOS menu, kernel
   messages, then a login prompt within about a minute. The root partition
   grows to fill the card on first boot.
5. **Log in** with `ssh <user>@<host>`; find the IP from your router or
   the serial console.
6. **Post-install:**
   - Tailscale: put an auth key in `/etc/tailscale-authkey` (mode 600) and
     run `sudo systemctl restart tailscaled-autoconnect`.
   - Self-updates: push your adapted config to your own GitHub repo, generate
     a key on the Nano (`ssh-keygen -t ed25519 -f ~/.ssh/github_deploy`), add
     it to that repo as a deploy key, and clone the repo to `~/nixos-jetson`.
   - Change the password with `passwd`.
7. **Check:** `bootreason`, `voltage`, `systemctl --failed`, and the memory
   clock should read 1600000000 (see Health commands).

### Caveats

- **RAM code.** The memory timing tables in `hw/` are for RAM code 0, which
  is what the 4 GB developer kit reports (`dmesg | grep "RAM code"`). A
  board with a different RAM code needs its own tables. Extract them from
  `/proc/device-tree/external-memory-controller@7001b000/` *before* adding
  this repo's boot script, since the script stops U-Boot from copying them,
  then point the converter at them. Booting with the wrong tables is safe
  at 204 MHz, but switching to 1600 MHz could corrupt memory, so check
  before relying on it.
- **U-Boot environment.** The boot script assumes the stock default
  environment, in particular the default node list in
  `fdt_copy_node_paths`. If someone has saved a custom environment on your
  board, compare it with `modules/jetson-nano.nix`.
- **Recovery.** If the boot script ever breaks, interrupt U-Boot over serial
  and boot by hand:

  ```
  setenv ramdisk_addr_r 0xa0000000
  sysboot mmc 1:2 any 0x90100000 /boot/extlinux/extlinux.conf
  ```

  Older generations are always available in the boot menu
  (`tools/boot-menu-pick.py` selects one over serial).

---

## 3. How it was worked out

Every change was tested on the hardware, one at a time, with the serial
console captured from power-on.

**Starting point.** The existing NVIDIA image showed which bootloader was in
QSPI (L4T 32.5.1: CBoot + U-Boot 2020.04). U-Boot's environment and memory
map were captured over serial (`printenv`, `bdinfo`): load addresses, the
`fdt_copy_node_paths` list, and that the SD slot is `mmc 1`. That map shaped
every later decision. The nixpkgs default kernel turned out to have all the
Tegra drivers needed for booting built in, so the initrd only needed the MMC
block driver, and the kernel could come straight from the binary cache.

**Build host.** An older Nix (2.13) couldn't evaluate nixpkgs 26.05, and
its daemon failed builds that use structured attributes, with an error
pointing at a missing `$stdenv`. Upgrading Nix fixed both. Emulated aarch64
builds worked once qemu binfmt was registered.

**The initrd overlap.** U-Boot leaves 14 MiB below the kernel and doesn't
relocate the initrd. Trimming modules didn't help: the systemd initrd in
26.05 is about 25 MB on its own, and the older script-based initrd is being
removed in 26.11. The first boot failed exactly as predicted:
`Initramfs unpacking failed: ZSTD-compressed data is corrupt`.
- U-Boot's environment had a `preboot` hook that looked like the obvious
  fix, but this build never runs it.
- Setting `ramdisk_addr_r` by hand at the U-Boot prompt proved the rest of
  the system booted fine.
- The permanent fix uses U-Boot's normal boot-script search: mark the FAT
  partition bootable, put `boot.scr` there, and have it chain to
  `extlinux.conf`. It was applied to the running card in place, then built
  into the image.

**Memory clock.** The memory clock read 204 MHz and `tegra210-emc` failed
to probe. Several warnings pointed the same way: the kernel couldn't find
referenced device-tree nodes, and the thermal zones' references were broken.
- Dumping the live device tree showed the memory-controller node wasn't the
  upstream one. U-Boot had replaced it, via `fdt_copy_node_paths`, with
  NVIDIA's version: different clocks, NVIDIA-format timing tables, and a node
  handle that collided with an I2C bus.
- Mainline instead wants a binary table array in reserved memory.
- NVIDIA's per-property format maps one-to-one onto the mainline struct.
  The converter checks every field against the kernel header's layout, and
  gcc agreed on the struct size.
- The table revision matched the only clock-change sequence mainline
  supports.
- Rollout went in stages: confirm the driver probes at 204 MHz, switch by
  hand while watching serial, toggle 50 times, run memtester under CPU load,
  and only then pin 1600 MHz at boot.

**Reboot hang.** Some reboots took about 3 minutes instead of 1.
- A serial capture with a host-side timestamp on every line showed a
  128 s gap between the kernel's last message and the bootloader. 128 s is
  the PMIC watchdog's maximum timeout, so the restart itself was hanging.
- In every slow case, the last message was the USB 3 controller reloading
  its firmware. It was being woken from runtime suspend during shutdown.
- Keeping it out of runtime suspend: 10 of 10 reboots clean, against about
  half hanging before.

**Headless cleanup.** Blocking the display drivers left the kernel waiting
on devices that would never probe. That kept power-domain cleanup pending
and an I2C bus deferred. Disabling those nodes in the device tree fixed it.

**Boot reason.** The bootloader prints the PMIC's event register on every
boot. Correlating its values with known events made it readable: 0 for a
normal reboot, the watchdog bit for the hung reboots, undervoltage bits for
pulled plugs. Linux and U-Boot both read 0, because the first-stage
bootloader clears the register on read. But that bootloader's own device
tree (inspected from U-Boot) holds a copy under `/chosen/reset`, and U-Boot
already copies that node into the kernel's device tree. So Linux could read
it all along.

**Power monitor.** The first guess, one of the general I2C buses, was empty
when probed from U-Boot. NVIDIA's tools read the monitor from the camera
block's I2C controller, which sits under the display/camera bus. Re-enabling
just that bus, with everything else on it disabled, made the monitor appear.
Its first readings showed the micro-USB supply already below the Nano's
5 V −5 % input spec at idle and sagging further under load. A barrel-jack
supply kept it in spec. The reset-reason and voltage-monitor services were
then built, and tested by temporarily raising thresholds and generating
load.

**Other findings.**
- Ethernet negotiated only 100 Mbit/s; the cable was faulty.
- Rollback was tested by picking an old generation from the boot menu over
  serial.
- The SD card passed fio and a write/read-back checksum test. Its
  random-write performance is the main bottleneck for write-heavy workloads,
  so a USB SSD is worth adding for application data.

**Tools** in `tools/`:

| Tool | Purpose |
| --- | --- |
| `nano-serial.py` | Log the serial console, or stop U-Boot and run commands at its prompt |
| `reboot-cycle.sh` | Timed reboots with a health check after each |
| `boot-menu-pick.py` | Reboot and pick a boot-menu entry over serial |
| `membw.c` | Memory bandwidth benchmark |
| `l4t-emc-to-bin.py` | Memory timing table converter (also used by the build) |

The serial tools default to the original author's adapter and host: set
`NANO_SERIAL` to your adapter's device (e.g. `/dev/serial/by-id/…`) and pass
your `user@host` to the reboot helpers. Only one program can read the serial
port at a time; a second reader (including a terminal left open) splits the
data between them.
