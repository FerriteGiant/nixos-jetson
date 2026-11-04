# USB SSD (btrfs "WD256"): application data, logs, swap, snapshots.
# The SD card keeps /, /nix and /boot, so the Nano still boots without the
# SSD; everything here is nofail.
#
# Subvolumes (created once by hand, see README "USB SSD"):
#   @hermes     -> /var/lib/hermes   application state, snapshotted hourly
#   @log        -> /var/log          journal and other logs
#   @swap       -> /swap             4 GiB swap file (NOCOW), below zram in priority
#   @snapshots                       btrbk snapshot target
# Top level (subvolid=5) is mounted at /mnt/ssd for btrbk and scrub.
{ pkgs, ... }:

let
  dev = "/dev/disk/by-uuid/b660bf9a-79bd-4be0-997e-d1d7f84d17a9";
  common = [ "noatime" "compress=zstd:1" ];
  optional = [ "nofail" "x-systemd.device-timeout=30s" ];
in
{
  fileSystems."/mnt/ssd" = {
    device = dev;
    fsType = "btrfs";
    options = [ "subvolid=5" ] ++ common ++ optional;
  };
  fileSystems."/var/lib/hermes" = {
    device = dev;
    fsType = "btrfs";
    options = [ "subvol=@hermes" ] ++ common ++ optional;
  };
  fileSystems."/swap" = {
    device = dev;
    fsType = "btrfs";
    options = [ "subvol=@swap" ] ++ common ++ optional;
  };

  # /var/log is in NixOS's pathsNeededForBoot, so a fileSystems entry would be
  # mounted from the initrd, which has no USB storage, making boot depend on
  # the SSD. A plain systemd mount unit is handled in stage 2 instead.
  # systemd-journal-flush has RequiresMountsFor=/var/log/journal, so the
  # journal stays in /run until this is mounted (or for the whole boot if the
  # SSD is missing); nothing lands on the SD card underneath.
  systemd.mounts = [{
    what = dev;
    where = "/var/log";
    type = "btrfs";
    options = "subvol=@log,noatime,compress=zstd:1";
    wantedBy = [ "local-fs.target" ];
    mountConfig.TimeoutSec = "30s";
  }];
  services.journald.extraConfig = "SystemMaxUse=2G";

  # zram (priority 5) is used first; the SSD swap file is the overflow.
  swapDevices = [{
    device = "/swap/swapfile";
    priority = 1;
    options = [ "nofail" ];
  }];

  # Hourly read-only snapshots of @hermes into @snapshots.
  services.btrbk.instances.hermes = {
    onCalendar = "hourly";
    settings = {
      timestamp_format = "long";
      snapshot_preserve_min = "2d";
      snapshot_preserve = "48h 14d 8w 6m";
      volume."/mnt/ssd" = {
        snapshot_dir = "@snapshots";
        subvolume = "@hermes";
      };
    };
  };

  services.fstrim.enable = true; # weekly, all filesystems (SSD and SD card)
  services.btrfs.autoScrub = {
    enable = true;
    interval = "monthly";
    fileSystems = [ "/mnt/ssd" ];
  };
}
