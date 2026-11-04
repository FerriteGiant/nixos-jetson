# Board support for the original Jetson Nano developer kit (P3450 = P3448
# module + P3449 B01 carrier), booted by the vendor U-Boot 2020.04 that L4T
# 32.5.1 installed in QSPI. Upstream kernel, no GPU/CUDA stack.
{ config, lib, pkgs, modulesPath, ... }:

let
  # PMIC power-off for systemd-shutdown (see "Power-off" below).
  pmicPowerOff = pkgs.writeShellScript "jetson-pmic-poweroff" ''
    [ "$1" = poweroff ] || exit 0
    export PATH=${lib.makeBinPath [ pkgs.i2c-tools pkgs.coreutils ]}
    bus=""
    for d in /sys/bus/i2c/devices/*-003c; do
      [ "$(tr -d '\0' < "$d/of_node/compatible" 2>/dev/null)" = "maxim,max77620" ] && bus=''${d##*/} && bus=''${bus%%-*}
    done
    [ -n "$bus" ] || { echo "jetson-pmic-poweroff: PMIC not found" > /dev/kmsg; exit 0; }
    v=$(i2cget -f -y "$bus" 0x3c 0x41) || exit 0
    echo "jetson-pmic-poweroff: PMIC on i2c-$bus, ONOFFCNFG1=$v -> setting SFT_RST" > /dev/kmsg
    sync
    i2cset -f -y "$bus" 0x3c 0x41 $(( v | 0x80 ))
  '';

  # Physical addresses of the EMC timing tables (see boot.scr and the DT
  # overlay below). Free since ramdisk_addr_r moved: between the CBoot DT
  # copy at 0x83100000 and the kernel at 0x84000000.
  emcNominalAddr = "0x83400000";
  emcDeratedAddr = "0x83408000";
  emcRegionSize = "0x8000"; # must match REGION_SIZE in tools/l4t-emc-to-bin.py

  # L4T's non-relocatable default ramdisk_addr_r (0x83200000) leaves 14 MiB
  # before the kernel at 0x84000000 (initrd_high=~0), so our ~25 MB systemd
  # initrd gets overwritten by the kernel ("Initramfs unpacking failed:
  # ZSTD-compressed data is corrupt"). 0xa0000000 is above the kernel (ends
  # ~0x87eb0000), scriptaddr/pxefile (0x9000000x), the XUSB fw blob
  # (~0x92ca8000), and far below U-Boot's relocated copy (~0xfc5f0000).
  ramdiskAddr = "0xa0000000";

  # The vendor default env has
  #   fdt_copy_node_paths=...:/external-memory-controller@7001b000:/memory@80000000
  # i.e. U-Boot replaces the upstream EMC node with L4T's (wrong clocks,
  # L4T-format tables, and a phandle that collides with /i2c@7000c700).
  # Same list minus the EMC node:
  fdtCopyNodePaths = lib.concatStringsSep ":" [
    "/chosen/plugin-manager"
    "/chosen/reset"
    "/chosen/display-board"
    "/chosen/proc-board"
    "/chosen/pmu-board"
    "/memory@80000000"
  ];

  # The L4T env's `preboot` hook is NOT executed by this U-Boot build, so we
  # use distro boot: only SD partition 1 (FAT) is flagged bootable; U-Boot
  # finds no extlinux.conf there but runs /boot.scr, which adjusts the env
  # (RAM only; no saveenv, no QSPI writes) and then sysboots partition 2's
  # NixOS-managed extlinux.conf.
  bootScript = pkgs.writeText "boot.cmd" ''
    echo "unicomplex boot.scr"
    setenv ramdisk_addr_r ${ramdiskAddr}
    setenv fdt_copy_node_paths ${fdtCopyNodePaths}
    mw.b ${emcNominalAddr} 0 ${emcRegionSize}
    mw.b ${emcDeratedAddr} 0 ${emcRegionSize}
    load ''${devtype} ''${devnum}:1 ${emcNominalAddr} /emc-nominal.bin
    load ''${devtype} ''${devnum}:1 ${emcDeratedAddr} /emc-derated.bin
    sysboot ''${devtype} ''${devnum}:2 any ''${pxefile_addr_r} /boot/extlinux/extlinux.conf
  '';

  # Contents of the FAT partition: boot.scr plus the EMC DVFS tables
  # converted from L4T's DT format to mainline's binary format.
  firmwarePartition = pkgs.runCommand "jetson-nano-firmware-partition"
    { nativeBuildInputs = [ pkgs.buildPackages.ubootTools pkgs.buildPackages.python3 ]; }
    ''
      mkdir -p $out
      mkimage -A arm64 -O linux -T script -C none -n unicomplex-boot \
        -d ${bootScript} $out/boot.scr
      python3 ${../tools/l4t-emc-to-bin.py} ${../hw/l4t-emc-table-ramcode0.dtsi} \
        $out/emc-nominal.bin $out/emc-derated.bin
    '';

  # Runs after the stock extlinux installer on every `nixos-rebuild
  # boot/switch`, so boot.scr and the EMC tables stay in sync with the config.
  syncFirmwarePartition = pkgs.writeShellScript "sync-jetson-firmware-partition" ''
    set -eu
    export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.util-linux pkgs.diffutils ]}
    dev=/dev/disk/by-label/FIRMWARE
    [ -e "$dev" ] || { echo "jetson: $dev not found, skipping firmware sync" >&2; exit 0; }
    mnt=$(mktemp -d)
    mount -t vfat "$dev" "$mnt"
    trap 'umount "$mnt"; rmdir "$mnt"' EXIT
    for f in ${firmwarePartition}/*; do
      n=$(basename "$f")
      if ! cmp -s "$f" "$mnt/$n"; then
        echo "jetson: updating FIRMWARE/$n"
        cp "$f" "$mnt/$n.tmp" && sync && mv "$mnt/$n.tmp" "$mnt/$n"
      fi
    done
    rm -f "$mnt/u-boot-preboot.scr" # obsolete
    sync
  '';
in
{
  imports = [
    "${modulesPath}/installer/sd-card/sd-image.nix"
    ./board-commands.nix
  ];

  # sd-image.nix turns on enableAllHardware, which stuffs ~100 modules into
  # the initrd; keep it lean.
  hardware.enableAllHardware = lib.mkForce false;

  nixpkgs.hostPlatform = "aarch64-linux";

  # --- Boot -----------------------------------------------------------------
  boot.loader.grub.enable = false;
  boot.loader.generic-extlinux-compatible.enable = true;
  boot.loader.generic-extlinux-compatible.configurationLimit = 10;
  # Stock extlinux installer + FAT partition sync (see above).
  system.build.installBootLoader = lib.mkForce (pkgs.writeShellScript "install-jetson-bootloader" ''
    set -e
    ${config.boot.loader.generic-extlinux-compatible.populateCmd} -c "$@"
    ${syncFirmwarePartition}
  '');

  # Default kernel of the pinned release (6.18 LTS); comes from the binary
  # cache, so nothing is compiled.
  boot.kernelPackages = pkgs.linuxPackages;

  # Emits an explicit "FDT" line in extlinux.conf so U-Boot loads the
  # upstream device tree instead of handing over the L4T one.
  hardware.deviceTree.name = "nvidia/tegra210-p3450-0000.dtb";

  # EMC (DRAM clock) scaling: mainline's tegra210-emc needs the timing tables
  # in reserved memory; boot.scr loads them there from the FAT partition.
  hardware.deviceTree.overlays = [{
    name = "jetson-nano-emc-tables";
    dtsText = ''
      /dts-v1/;
      /plugin/;
      / {
        compatible = "nvidia,p3450-0000";

        fragment@0 {
          target-path = "/";
          __overlay__ {
            reserved-memory {
              #address-cells = <2>;
              #size-cells = <2>;
              ranges;

              emc_nominal: emc-table@${lib.removePrefix "0x" emcNominalAddr} {
                compatible = "nvidia,tegra210-emc-table";
                reg = <0x0 ${emcNominalAddr} 0x0 ${emcRegionSize}>;
              };

              emc_derated: emc-table@${lib.removePrefix "0x" emcDeratedAddr} {
                compatible = "nvidia,tegra210-emc-table";
                reg = <0x0 ${emcDeratedAddr} 0x0 ${emcRegionSize}>;
              };
            };
          };
        };

        fragment@1 {
          target-path = "/external-memory-controller@7001b000";
          __overlay__ {
            memory-region = <&emc_nominal>, <&emc_derated>;
            memory-region-names = "nominal", "derated";
          };
        };
      };
    '';
  }
    # Headless: disable the display/camera side in the DT (the drivers are
    # blacklisted below). Otherwise fw_devlink keeps waiting for them:
    # i2c@7000c700 (HDMI DDC) needs the dpaux pinmux, and tegra-pmc/tegra-mc
    # sync_state() (powering off unused domains) stays pending on unbound
    # host1x children and the MIPI calibration block. host1x itself stays
    # enabled only because it hosts i2c@546c0000 ("VI I2C", L4T bus 6), where
    # the module's INA3221 power monitor lives.
  {
    name = "jetson-nano-headless";
    dtsText = let
      off = path: n: ''fragment@${toString n} { target-path = "${path}"; __overlay__ { status = "disabled"; }; };'';
      nodes = [
        "/i2c@7000c700" "/mipi@700e3000"
        "/host1x@50000000/dc@54200000" "/host1x@50000000/dc@54240000"
        "/host1x@50000000/dpaux@54040000" "/host1x@50000000/dpaux@545c0000"
        "/host1x@50000000/sor@54540000" "/host1x@50000000/sor@54580000"
        "/host1x@50000000/vi@54080000" "/host1x@50000000/vic@54340000"
      ];
    in ''
      /dts-v1/;
      /plugin/;
      / {
        compatible = "nvidia,p3450-0000";
        ${lib.concatStringsSep "
        " (lib.imap0 (i: p: off p i) nodes)}
      };
    '';
  }

    # INA3221 3-channel power monitor on the P3448 module (as in L4T's
    # tegra210-porg DT: POM_5V_IN / POM_5V_GPU / POM_5V_CPU, 5 mOhm shunts).
    # hwmon: `sensors ina3221-*`; in1 = 5 V input rail (brownout margin).
  {
    name = "jetson-nano-ina3221";
    dtsText = ''
      /dts-v1/;
      /plugin/;
      / {
        compatible = "nvidia,p3450-0000";
        fragment@0 {
          target-path = "/host1x@50000000/i2c@546c0000";
          __overlay__ {
            #address-cells = <1>;
            #size-cells = <0>;
            power-sensor@40 {
              compatible = "ti,ina3221";
              reg = <0x40>;
              #address-cells = <1>;
              #size-cells = <0>;
              input@0 { reg = <0>; label = "VDD_IN";  shunt-resistor-micro-ohms = <5000>; };
              input@1 { reg = <1>; label = "VDD_GPU"; shunt-resistor-micro-ohms = <5000>; };
              input@2 { reg = <2>; label = "VDD_CPU"; shunt-resistor-micro-ohms = <5000>; };
            };
          };
        };
      };
    '';
  }];

  # Mainline has no EMC devfreq governor for Tegra210, so the DRAM would sit
  # at the 204 MHz boot clock. The Nano only has two EMC rates (204/1600
  # MHz); pin the top one (~5x memory bandwidth). The driver still applies
  # temperature-based refresh/derating on its own.
  boot.kernelModules = [ "tegra210_emc" "i2c-dev" ]; # i2c-dev: PMIC power-off hook
  systemd.services.emc-max-rate = {
    description = "Run the DRAM (EMC) at 1600 MHz";
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-modules-load.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      d=/sys/kernel/debug/emc
      for i in $(seq 1 30); do [ -e $d/min_rate ] && break; sleep 1; done
      echo 1600000000 > $d/max_rate
      echo 1600000000 > $d/min_rate
      echo "EMC clock: $(cat /sys/kernel/debug/clk/emc/clk_rate) Hz"
    '';
  };

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
  # no camera input (tegra-video). host1x is needed for the VI I2C bus.
  boot.blacklistedKernelModules = [ "nouveau" "tegra_drm" "tegra_video" ];

  # Why did the last boot happen? TegraBoot reads (and thereby clears) the
  # MAX77620 PMIC's NVERC event register, but CBoot records it in its DT as
  # /chosen/reset/pmic_reset_status, which U-Boot copies into ours
  # (fdt_copy_node_paths keeps /chosen/reset). Observed: 0x00 clean reboot,
  # 0x02 watchdog, 0x40/0x50 power pulled. Undervoltage bits on a boot where
  # nobody unplugged it = brownout. Check: journalctl -b -u pmic-reset-reason
  systemd.services.pmic-reset-reason = {
    description = "Log PMIC reset reason (brownout/watchdog detection)";
    wantedBy = [ "multi-user.target" ];
    serviceConfig.Type = "oneshot";
    path = [ pkgs.coreutils ];
    script = ''
      f=/proc/device-tree/chosen/reset/pmic_reset_status
      [ -e $f ] || { echo "<4>no $f (bootloader did not pass it)"; exit 0; }
      v=$(( 0x$(od -An -tx1 $f | tr -d ' \n') ))
      pmc=$(od -An -tx1 /proc/device-tree/chosen/reset/pmc_reset_status 2>/dev/null | tr -d ' \n')
      bits=""
      for b in "0x01 SHDN(shutdown)" "0x02 WTCHDG(watchdog)" "0x04 HDRST(hard-reset)" \
               "0x08 TOVLD(thermal-overload)" "0x10 MBLSD(low-input-shutdown)" \
               "0x20 MBO(input-overvoltage)" "0x40 MBU(input-undervoltage)" "0x80 RSTIN(reset-input)"; do
        m=''${b%% *}; [ $(( v & m )) -ne 0 ] && bits="$bits ''${b#* }"
      done
      case $(( 0x''${pmc:-0} )) in
        0) why=power-on ;; 1) why=watchdog ;; 2) why=thermal-sensor ;;
        3) why=software-reboot ;; 4) why=lp0-wake ;; *) why=unknown ;;
      esac
      msg=$(printf "PMIC NVERC=0x%02x%s; Tegra PMC reset: %s (0x%s)" $v "''${bits:+ ->$bits}" "$why" "$pmc")
      if [ $(( v & 0x7a )) -ne 0 ]; then
        echo "<4>$msg"
        if [ $(( v & 0x50 )) -ne 0 ]; then
          echo "<4>input power dropped: brownout, unless the board was unplugged"
        fi
      else
        echo "<6>$msg (clean)"
      fi
    '';
  };

  # Supply monitor: INA3221 VDD_IN at 5 Hz, 1 s moving average; warns below
  # 4.7 V (clears above 4.75 V), reminds at most once a minute while low,
  # hourly info summary. journalctl -u vdd-in-monitor -p warning
  systemd.services.vdd-in-monitor = {
    description = "Monitor 5 V input (VDD_IN) for supply dips";
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.coreutils ];
    environment = {
      LOW_MV = "4700";
      CLEAR_MV = "4750";
      WINDOW = "5";
      PERIOD = "0.2";
      REMIND_S = "60";
      SUMMARY_S = "3600";
    };
    serviceConfig = {
      ExecStart = "${pkgs.bash}/bin/bash ${./vdd-in-monitor.sh}";
      Restart = "always";
      RestartSec = 10;
      Nice = 10;
      DynamicUser = true; # only reads sysfs
    };
  };

  # Power-off: Linux's PSCI SYSTEM_OFF call isn't implemented by the L4T
  # secure firmware ("Tegra System Off: operation not handled", EL3 panic);
  # the board then hangs powered on. Once, the PMIC watchdog rebooted it ~80 s
  # later (NVERC 0x02); another time it stayed hung. The max77620 driver's
  # own power-off handler
  # is never installed because PSCI already claims pm_power_off. So power
  # off the PMIC from a systemd-shutdown hook instead (same register write
  # the driver would do: ONOFFCNFG1 0x41, SFT_RST bit 7). Reboots unaffected.
  # systemd-shutdown looks for hooks in /etc/systemd/system-shutdown (and its
  # own store path), not /lib/...; the final stage runs from the shutdown
  # ramfs, so the hook goes there. systemd.shutdown covers the no-ramfs case.
  systemd.shutdownRamfs.contents."/etc/systemd/system-shutdown/jetson-pmic-poweroff".source = pmicPowerOff;
  systemd.shutdown.jetson-pmic-poweroff = pmicPowerOff;

  # Reboot hang: if the XUSB (USB3) controller is runtime-suspended when the
  # kernel runs its shutdown pass, it gets resumed (firmware reload) and the
  # restart hangs about half the time, until the max77620 watchdog (~128 s)
  # resets the board. Keeping the controller out of runtime suspend fixed
  # it (5/5 immediate resets vs ~4/7 hangs).
  services.udev.extraRules = ''
    ACTION=="add", SUBSYSTEM=="platform", KERNEL=="70090000.usb", ATTR{power/control}="on"
  '';

  # --- SD image -------------------------------------------------------------
  sdImage = {
    populateFirmwareCommands = ''
      cp ${firmwarePartition}/* firmware/
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
