# Host-agnostic baseline (adapted from nixos_server/nix-config).
{ config, pkgs, ... }:

{
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  networking.usePredictableInterfaceNames = false;
  networking.useDHCP = false;
  networking.interfaces.eth0.useDHCP = true;

  users.users.sirhc = {
    isNormalUser = true;
    home = "/home/sirhc";
    extraGroups = [ "wheel" "dialout" ];
    openssh.authorizedKeys.keys = [ "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEF7yFtlcWwqMMtn92SW3FW7lTfBPUPkAyW+yDTUrcZW cwgreenley@gmail.com" ];
    # Serial-console login only (SSH password auth is off). Change with
    # `passwd` after first boot; this value is only applied on first creation.
    initialPassword = "unicomplex";
  };

  # Bring-up convenience: full sudo over SSH without a password.
  # Tighten to nixos-rebuild-only (as on the Linode) once the board is stable.
  security.sudo.wheelNeedsPassword = false;

  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    trusted-users = [ "sirhc" ]; # allow pushing closures built on the laptop
  };

  # Building these under emulation is slow and they're not needed headless.
  documentation.nixos.enable = false;
  programs.command-not-found.enable = false;

  programs.vim.enable = true;
  programs.vim.defaultEditor = true;

  environment.systemPackages = with pkgs; [
    inetutils
    mtr
    sysstat
    wget
    git
    screen
    tmux
    htop
    tree
    pciutils
    usbutils
    lm_sensors
  ];
}
