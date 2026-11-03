# Board support for the original Jetson Nano developer kit (P3450 = P3448
# module + P3449 B01 carrier), booted by the vendor U-Boot 2020.04 that L4T
# 32.5.1 installed in QSPI. Upstream kernel, no GPU/CUDA stack.
{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    "${modulesPath}/installer/sd-card/sd-image.nix"
  ];

  # sd-image.nix turns on enableAllHardware, which stuffs ~100 modules into
  # the initrd. Vendor U-Boot loads the initrd only 14 MiB below the kernel
  # (0x83200000 vs 0x84000000), so the initrd must stay small.
  hardware.enableAllHardware = lib.mkForce false;

  nixpkgs.hostPlatform = "aarch64-linux";

  # --- Boot -----------------------------------------------------------------
  # U-Boot's distro_bootcmd finds /boot/extlinux/extlinux.conf on the
  # partition flagged bootable (sd-image flags the ext4 root partition).
  boot.loader.grub.enable = false;
  boot.loader.generic-extlinux-compatible.enable = true;
  boot.loader.generic-extlinux-compatible.configurationLimit = 10;

  # Default kernel of the pinned release (6.18 LTS); comes from the binary
  # cache, so nothing is compiled.
  boot.kernelPackages = pkgs.linuxPackages;

  # Emits an explicit "FDT" line in extlinux.conf so U-Boot loads the
  # upstream device tree instead of handing over the L4T one.
  hardware.deviceTree.name = "nvidia/tegra210-p3450-0000.dtb";

  # Debug UART (UARTA, J50 header). Upstream dt aliases it to serial0 -> ttyS0.
  # Kept last so it is /dev/console and gets the serial getty.
  boot.kernelParams = [ "earlycon" "console=tty0" "console=ttyS0,115200n8" ];
  boot.consoleLogLevel = 7; # verbose while bringing the board up

  # SD controller, PMIC regulators, I2C, pinctrl and ext4 are all built into
  # the nixpkgs kernel (=y); only the MMC block layer is a module.
  boot.initrd.includeDefaultModules = false;
  boot.initrd.availableKernelModules = [ "mmc_block" ];

  # --- Firmware -------------------------------------------------------------
  # Only what this board needs instead of all of linux-firmware:
  # Tegra210 XUSB (USB3 controller) and the RTL8168h NIC.
  hardware.firmware = [
    (pkgs.runCommand "jetson-nano-firmware" { } ''
      mkdir -p $out/lib/firmware/nvidia
      cp -rL ${pkgs.linux-firmware}/lib/firmware/nvidia/tegra210 $out/lib/firmware/nvidia/
      cp -rL ${pkgs.linux-firmware}/lib/firmware/rtl_nic $out/lib/firmware/
    '')
  ];

  # --- No GPU ---------------------------------------------------------------
  # Headless: no GPU (nouveau), no display controller / HDMI (tegra-drm),
  # no camera input (tegra-video), and their common bus driver (host1x).
  boot.blacklistedKernelModules = [ "nouveau" "tegra_drm" "tegra_video" "host1x" ];

  # --- SD image -------------------------------------------------------------
  sdImage = {
    # Vendor ramdisk_addr_r (0x83200000) leaves 14 MiB before the kernel at
    # 0x84000000 and initrd_high=~0 means no relocation, so our ~25 MB
    # systemd initrd gets overwritten by the kernel ("Initramfs unpacking
    # failed: ZSTD-compressed data is corrupt" on first boot). Move it to
    # 0xa0000000: above the kernel (ends ~0x87eb0000), scriptaddr/pxefile
    # (0x9000000x), the XUSB fw blob (~0x92ca8000), and far below U-Boot's
    # relocated copy (~0xfc5f0000). RAM-only setenv; no saveenv, no QSPI.
    #
    # How: the L4T env's `preboot` hook is NOT executed by this U-Boot build,
    # so use distro boot instead. Only partition 1 (FAT) is flagged bootable;
    # U-Boot's scan finds no extlinux.conf there but runs /boot.scr, which
    # fixes the address and then sysboots partition 2's extlinux.conf (still
    # managed by nixos-rebuild as usual).
    populateFirmwareCommands =
      let
        bootScript = pkgs.writeText "boot.cmd" ''
          echo "unicomplex boot.scr: ramdisk_addr_r -> 0xa0000000"
          setenv ramdisk_addr_r 0xa0000000
          sysboot ''${devtype} ''${devnum}:2 any ''${pxefile_addr_r} /boot/extlinux/extlinux.conf
        '';
      in
      ''
        ${pkgs.buildPackages.ubootTools}/bin/mkimage -A arm64 -O linux -T script -C none \
          -n unicomplex-boot -d ${bootScript} firmware/boot.scr
      '';
    # sd-image flags the root partition bootable; move the flag to the FAT one.
    postBuildCommands = ''
      sfdisk --no-reread --no-tell-kernel --activate $img 1
      sfdisk --dump $img
    '';
    populateRootCommands = ''
      mkdir -p ./files/boot
      ${config.boot.loader.generic-extlinux-compatible.populateCmd} \
        -c ${config.system.build.toplevel} -d ./files/boot
    '';
  };
  image.baseName = lib.mkDefault "nixos-${config.networking.hostName}";

  # 4 GB RAM, no swap partition.
  zramSwap.enable = true;
}
