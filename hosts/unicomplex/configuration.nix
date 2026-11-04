{ pkgs, ... }:

{
  imports = [
    ../../modules/jetson-nano.nix
    ../../common-configuration.nix
  ];

  networking.hostName = "unicomplex";

  # USB SSD: WD PC SA530 256 GB (M.2 SATA) in a VIA Labs VL716 (2109:0716)
  # UAS enclosure. The bridge advertises UNMAP in its LBP VPD page but
  # reports lbpme=0 in READ CAPACITY(16), so the kernel picks
  # provisioning_mode=full (no discard). Forcing "unmap" works: fstrim
  # trimmed 232.7 GiB with data intact and clean scrubs (2026-11-04).
  # Note: smartctl -d snt* probes send ATA PASS-THROUGH(12), which this
  # bridge doesn't answer (60 s timeout + UAS reset); use -d sat.
  services.udev.extraRules = ''
    ACTION=="add|change", SUBSYSTEM=="scsi_disk", ATTRS{idVendor}=="2109", ATTRS{idProduct}=="0716", ATTR{provisioning_mode}="unmap"
  '';

  environment.systemPackages = with pkgs; [ btrfs-progs smartmontools ];

  system.stateVersion = "26.05";
}
