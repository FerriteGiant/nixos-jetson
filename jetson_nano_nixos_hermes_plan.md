# Jetson Nano: headless NixOS host for Hermes

Updated: 2026-11-03

## Goal and current status

Run a headless NixOS system on Chris's original Jetson Nano, with no GPU acceleration, to host Hermes Agent. Models will run on other network nodes or through cloud APIs. Build the image on Linux Mint.

**Status: hardware and existing U-Boot identified; no NixOS image has been built or boot-tested.** This document records confirmed observations separately from proposed implementation steps. It is a bring-up plan, not a validated installation recipe.

Recommended approach: preserve the current microSD card and QSPI firmware, build a minimal upstream-kernel NixOS image on a spare card, and prove reliable serial/Ethernet/SSH operation before installing Hermes. There is no demonstrated reason to upgrade JetPack or reflash QSPI before the first experiment.

## 1. Confirmed hardware and running system

Evidence: user-supplied board photographs and Linux/U-Boot command output.

| Item | Observed value / interpretation |
| --- | --- |
| Kit part number | `945-13450-0000-100` |
| Carrier PCB marking | `180-13449-DAAF-B01` |
| Kit model | P3450, original Jetson Nano developer kit |
| Carrier | P3449, B01 revision |
| Runtime module identity | P3448-0000 family |
| SoC / architecture | Tegra210 / AArch64 |
| RAM reported by Linux | 3.9 GiB, consistent with the 4 GB model |
| Current hostname/user | `nanosaur` / `nanosaur` |
| OS | Ubuntu 18.04.5 LTS |
| Kernel | `4.9.201-tegra`, built February 19, 2021 |
| L4T | R32, revision 5.1 (32.5.1), corresponding to JetPack 4.5.1 [3] |
| SD device | `mmcblk0`, 58.2 GiB; nominal 64 GB card |
| Root-storage layout | One 58.2 GiB ext4 partition, `mmcblk0p1` |
| Flash device | `mtdblock0`, 4 MiB; consistent with module QSPI |
| Swap | Four zram devices of about 495.5 MiB each, about 1.9 GiB total |
| Build host | Linux Mint; host CPU architecture and Nix installation not yet recorded |

Device-tree model:

```text
NVIDIA Jetson Nano Developer Kit
```

Device-tree compatible strings:

```text
nvidia,p3449-0000-b00+p3448-0000-b00
nvidia,jetson-nano
nvidia,tegra210
```

The `b00` compatibility strings are not a reason to reclassify the visibly marked B01 carrier. Device-tree compatibility identifiers and PCB markings serve different purposes.

NVIDIA identifies this kit part number with a P3449 B01 carrier and P3448-0000 B01 development module [2]. The runtime evidence confirms the original 4 GB Nano family, not an Orin Nano.

## 2. Confirmed bootloader and boot configuration

Serial console works at **115200 baud, 8N1, flow control disabled**. Use 3.3 V TTL signalling, cross TX/RX, connect ground, and leave the adapter power pin disconnected. Capture output from power-on.

```text
U-Boot 2020.04-g6b630d64fd (Feb 19 2021 - 08:37:46 -0800)

bootcmd=run distro_bootcmd
boot_targets=mmc1 mmc0 usb0 nvme0 pxe dhcp
kernel_addr_r=0x84000000
ramdisk_addr_r=0x83200000
fdt_addr_r=0x83000000
fdtfile: not defined
```

The bootloader searches MMC devices before USB. U-Boot's MMC numbering must be checked rather than assumed to match Linux's `mmcblk` numbering.

Current active `/boot/extlinux/extlinux.conf` content:

```text
TIMEOUT 30
DEFAULT primary

MENU TITLE L4T boot options

LABEL primary
      MENU LABEL primary kernel
      LINUX /boot/Image
      INITRD /boot/initrd
      APPEND ${cbootargs} quiet root=/dev/mmcblk0p1 rw rootwait rootfstype=ext4 console=ttyS0,115200n8 console=tty0 fbcon=map:0 net.ifnames=0
```

This entry supplies no explicit DTB. The new upstream-kernel entry should provide one explicitly with `FDT`, using the DTB built with that kernel, rather than inheriting the vendor tree. An undefined `fdtfile` is not itself a boot failure.

L4T 32.5 moved Nano developer-kit boot firmware into QSPI [4]. This release, the visible flash device, and the single-partition SD layout strongly support that configuration here. An upstream-kernel boot has not yet been demonstrated.

### Load-address constraint

The existing initrd load address is only **14 MiB below the kernel load address**:

```text
0x84000000 - 0x83200000 = 0x00e00000 = 14 MiB
```

An initrd larger than that gap would overlap the kernel's initial load region if these addresses are used directly. This is a potential image-layout problem, not evidence of a present failure.

Before booting, inspect the actual kernel/initrd/DTB sizes, DRAM and reserved regions, and kernel relocation requirements. Choose non-overlapping load addresses with adequate headroom. Do not assume a generic address copied from another Jetson is safe. Test address changes with temporary `setenv` commands first; do not use `saveenv` during the initial experiment.

Useful read-only U-Boot inspection commands:

```text
bdinfo
mmc list
printenv bootcmd boot_targets
printenv kernel_addr_r ramdisk_addr_r fdt_addr_r
printenv fdt_high initrd_high bootm_low bootm_size
```

Undefined variables are useful information. To continue normal boot:

```text
run bootcmd
```

## 3. What upstream support does and does not establish

- `anduril/jetpack-nixos` explicitly excludes the original Nano, TX1, and TX2. Disabling CUDA does not make that project support this board [1].
- Mainline Linux includes `nvidia/tegra210-p3450-0000.dts` [5]. This is the initial board target to investigate, not proof that all B01 peripherals work under the selected kernel.
- NixOS supports AArch64 and publishes an ARM64 binary cache [6].
- NixOS can generate extlinux configuration for U-Boot via `boot.loader.generic-extlinux-compatible.enable` [7].
- The linked Nano blog explicitly describes its modern GPU-free Linux proposal as untested [8]. It is motivation, not a successful installation report.
- NVIDIA early boot firmware remains necessary even when NVIDIA GPU drivers and CUDA are absent.

## 4. Recommended implementation sequence

### Phase A — Preserve the working system

1. Keep the original card intact and use a spare microSD for the experiment.
2. Save the complete serial boot log, U-Boot environment output, current extlinux configuration, and this document on Mint.
3. If making a full original-card backup, shut down the Nano and image the card from Mint while its filesystems are unmounted. Avoid a live block copy of a changing root filesystem.
4. Record the flash layout with `cat /proc/mtd`. Before any later firmware modification, establish the appropriate QSPI backup and recovery procedure.
5. Retain serial access throughout bring-up. Do not perform QSPI flashing or persistent U-Boot environment changes merely to test the first image.

**Exit criterion:** original card remains bootable and recovery access is available.

### Phase B — Prepare Linux Mint as a builder

Record host information:

```bash
uname -m
cat /etc/os-release
command -v nix
nix --version  # if installed
```

If Nix is absent, install it using the current official Linux instructions [9]. Nix recommends a multi-user daemon installation for ordinary systemd-based Linux hosts. This installs Nix alongside Mint; Mint does not need to be replaced by NixOS.

Enable the `nix-command` and `flakes` experimental features in the appropriate Nix configuration if using flakes. Keep the project's configuration and `flake.lock` in version control, and pin nixpkgs to an exact revision through that lock file.

**Architecture decision:** if Mint reports `x86_64`, setting the target to `aarch64-linux` does not by itself make ARM build steps executable. For the initial attempt, use native AArch64 derivations with QEMU user-mode/binfmt emulation on Mint and cached ARM64 packages wherever available. Verify that an AArch64 executable actually runs and that the Nix daemon recognizes the extra supported system. A remote ARM64 builder is an alternative. True cross-compilation is a separate approach and can introduce additional package issues; do not silently mix the two.

The exact binfmt setup depends on the Mint release, which has not been provided. Reserve tens of gigabytes of free disk space as a planning allowance; actual use depends on cache hits and whether a kernel rebuild is needed.

**Exit criterion:** a small AArch64 derivation can be built or substituted and executed through the selected build route.

### Phase C — Define a minimal, board-specific NixOS image

Create a flake exposing an SD image build. Its initial scope should include:

- `aarch64-linux` target with a pinned upstream kernel and matching DTBs.
- An extlinux-readable partition layout supported by the installed U-Boot; do not assume a generic UEFI ISO will work.
- Explicit `nvidia/tegra210-p3450-0000.dtb` selection.
- A root filesystem identified by a stable label or UUID rather than a guessed MMC number.
- A generated NixOS boot entry including the correct store-path init command. A kernel and root partition alone are not a complete NixOS boot entry.
- Serial output and login on the kernel's appropriate UART device. Start from the observed `ttyS0,115200n8`, verify upstream naming, and omit `quiet` while debugging.
- SD/MMC controller, root filesystem, and other boot-critical drivers in the kernel or initrd.
- Tegra PCIe/Ethernet and, when needed, USB/PHY support and firmware. Check the actual selected kernel configuration rather than assuming all drivers are enabled.
- DHCP, OpenSSH, a named administrator account, and Chris's SSH public key. Keep password-based remote login disabled unless explicitly needed.
- No desktop, CUDA, TensorRT, or NVIDIA graphics stack.

If “no GPU support” means no GPU driver initialization at all, disable the GPU node or relevant driver after basic boot is established. A headless system can otherwise still probe a GPU.

Do not add Hermes, local browsers, or container workloads yet. Select a supported nixpkgs baseline and change one major variable at a time during boot debugging.

**Exit criterion:** image builds; partition layout, extlinux paths, root identifier, kernel configuration, and load-region sizes have been inspected. A successful build does not establish hardware compatibility.

### Phase D — Write and boot the spare card

1. Identify the spare card by model and size on Mint. Verify the target before writing; image writing erases that target.
2. Write the uncompressed image to the whole spare-card device and finish pending writes before removal.
3. Power off the Nano, replace its card, and start serial capture before power-on.
4. Interrupt U-Boot if temporary load-address changes are required. Keep changes in RAM during this stage.
5. Capture the entire attempt, including the last output before any hang.

Troubleshoot according to the last successful stage:

| Failure | First checks |
| --- | --- |
| No extlinux menu | MMC selection, partition flags/layout, filesystem readability, config location |
| Kernel/initrd/DTB cannot load | Paths, file sizes, readable filesystem, address ranges |
| Hang after starting kernel | DTB, console selection, kernel image format/relocation, reserved memory |
| Kernel runs but cannot mount root | Root label/UUID, MMC driver, initrd modules, filesystem support |
| Userspace runs but no SSH | NIC/PCIe driver, firmware, DHCP, firewall, SSH service and key |

If the kernel fails before userspace, consider a smaller diagnostic initramfs to isolate kernel/DTB issues before rebuilding the full system repeatedly.

### Phase E — Qualify the headless host

- Repeat cold boots and warm reboots.
- Verify Ethernet reconnects after cable removal and DHCP renewal.
- Exercise sustained network traffic and storage writes; check kernel logs for errors.
- Verify temperature reporting and throttling under CPU load; verify fan control if a fan is added.
- Confirm system time is correct for TLS/API connections.
- Confirm NixOS generation updates and recovery to a previous boot entry.
- Test USB storage before moving the root filesystem or Hermes state to a USB SSD.

**Exit criterion:** stable serial/SSH access, storage, networking, thermal behavior, and recovery across repeated boots. GPIO, cameras, graphics, and video acceleration are outside the initial acceptance scope.

### Phase F — Add Hermes

Hermes exposes an `aarch64-linux` flake target and a NixOS module. Upstream classifies Nix integration as best-effort/Tier 2 [10,11]. Pin a tested Hermes revision rather than tracking an unverified moving branch.

Recommended starting arrangement:

| Component | Location |
| --- | --- |
| Hermes service, scheduler, gateway, session/memory state | Nano |
| LLM inference | Network inference host or cloud API |
| Heavy shell tasks/builds | Separate execution host via SSH |
| Browser automation and heavy MCP processes | Offload or leave disabled initially |

Start with the native NixOS module, explicit dependencies, persistent writable state, and secrets loaded from files outside the Nix store. Container deployment is an alternative if required tools depend on a mutable conventional Linux environment; confirm ARM64 image availability and resource use before adopting it.

Configure the model endpoint, model identifier, credentials, and tool-calling behavior. Remote inference does not automatically move shell execution: configure Hermes's terminal backend separately [12]. Test a real tool call, not just a chat completion.

Keep state on local storage and back it up. Avoid treating a network-mounted SQLite database as equivalent to a local filesystem. Use service restart policies, bounded logs, and zram as needed. Verify recovery after a model-server outage and Nano reboot.

The 4 GB capacity appears reasonable for modest orchestration with remote inference; this is an engineering assessment, not a measured Hermes-on-Nano memory benchmark.

## 5. Remaining decisions and information

- Mint version, host architecture, RAM/free disk, and whether Nix is already installed.
- SSH public key and desired new NixOS hostname/user.
- Spare-card capacity.
- Selected nixpkgs/kernel revision and confirmed driver configuration.
- Actual kernel/initrd sizes and safe load addresses.
- Whether the current vendor U-Boot boots that upstream kernel/DTB combination.
- Hermes inference endpoint/model, messaging integration, and local versus remote tool requirements.

**Immediate next action:** prepare and validate the Mint ARM64 build environment, then implement the minimal image flake. Do not begin by modifying QSPI or installing Hermes onto the old Ubuntu system.

## 6. Sources

Hardware values and bootloader output above come directly from the user-provided photos and logs on 2026-11-03. Public references were consulted during this investigation; moving repository links may change.

1. [anduril/jetpack-nixos — supported hardware](https://github.com/anduril/jetpack-nixos)
2. [NVIDIA Jetson Download Center — kit and carrier references](https://developer.nvidia.com/embedded/downloads)
3. [NVIDIA L4T 32.5.1](https://developer.nvidia.com/embedded/linux-tegra-r3251)
4. [NVIDIA L4T 32.5 — QSPI boot firmware change](https://developer.nvidia.com/embedded/linux-tegra-r325)
5. [Upstream Linux Nano device tree](https://github.com/torvalds/linux/blob/master/arch/arm64/boot/dts/nvidia/tegra210-p3450-0000.dts)
6. [NixOS on ARM](https://wiki.nixos.org/wiki/NixOS_on_ARM)
7. [NixOS U-Boot documentation](https://wiki.nixos.org/wiki/U-Boot)
8. [Why Jetson Nano Still Matters in 2026 — untested mainline proposal](https://brtkwr.com/posts/2026-03-06-why-jetson-nano-still-matters-in-2026/)
9. [Official Nix installation instructions](https://nixos.org/download/)
10. [Hermes Nix/NixOS setup](https://github.com/NousResearch/hermes-agent/blob/main/website/docs/getting-started/nix-setup.md)
11. [Hermes flake architecture targets](https://github.com/NousResearch/hermes-agent/blob/main/flake.nix)
12. [Hermes configuration](https://hermes-agent.nousresearch.com/docs/user-guide/configuration)
13. [NVIDIA Nano boot flow](https://docs.nvidia.com/jetson/archives/l4t-archived/l4t-3275/Tegra%20Linux%20Driver%20Package%20Development%20Guide/bootflow_jetson_nano.html)
14. [U-Boot Nano size-limit patch discussion](https://lists.u-boot-project.org/pipermail/u-boot/2025-August/596938.html)
