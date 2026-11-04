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

  # Same as the Linode: put a key from the Tailscale admin console in
  # /etc/tailscale-authkey (mode 600); tailscaled-autoconnect logs in once.
  services.tailscale.enable = true;
  services.tailscale.authKeyFile = "/etc/tailscale-authkey";
  services.tailscale.extraUpFlags = [ "--ssh" ];

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
  # Tighten to the nixos-rebuild-only rule below (as on the Linode) once the
  # board is stable.
  security.sudo.wheelNeedsPassword = false;
  security.sudo.extraRules = [{
    users = [ "sirhc" ];
    commands = [{
      command = "/run/current-system/sw/bin/nixos-rebuild";
      options = [ "NOPASSWD" ];
    }];
  }];

  # Self-update from ~/nixos-jetson (clone of the GitHub repo). With no
  # #attr, nixos-rebuild picks nixosConfigurations.<hostname>.
  environment.shellAliases = {
    rsf = "sudo nixos-rebuild switch --flake ~/nixos-jetson";
  };

  # Push/pull the config repo with a per-repo GitHub deploy key
  # (~/.ssh/github_deploy, generated on the box, write access enabled).
  programs.ssh.knownHosts."github.com".publicKey =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl";
  programs.ssh.extraConfig = ''
    Host github.com
      IdentityFile ~/.ssh/github_deploy
      IdentitiesOnly yes
  '';
  programs.git = {
    enable = true;
    config = {
      init.defaultBranch = "main";
      pull.ff = "only";
      user.name = "sirhc@${config.networking.hostName}";
      user.email = "cwgreenley@gmail.com";
    };
  };

  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    trusted-users = [ "sirhc" ]; # allow pushing closures built on the laptop
  };

  # Keep the store from growing forever: weekly, drop generations older than
  # 14 days (the rollback window; the boot menu keeps at most 10) and collect
  # unreferenced paths, then hard-link identical files. Timers are persistent,
  # so a run missed while powered off happens at the next boot.
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };
  nix.optimise.automatic = true;

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
    screen
    tmux
    htop
    tree
    pciutils
    usbutils
    lm_sensors
  ];
}
