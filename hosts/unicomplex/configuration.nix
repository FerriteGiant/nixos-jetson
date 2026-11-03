{ ... }:

{
  imports = [
    ../../modules/jetson-nano.nix
    ../../common-configuration.nix
  ];

  networking.hostName = "unicomplex";

  system.stateVersion = "26.05";
}
