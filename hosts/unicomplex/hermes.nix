# Hermes Agent (NixOS module from the hermes-agent flake input), native mode.
#
# State: the module uses a static `hermes` user with stateDir /var/lib/hermes
# (no DynamicUser), which is the @hermes subvolume on the USB SSD, so it is
# covered by the btrbk snapshots. HERMES_HOME is /var/lib/hermes/.hermes.
#
# Secrets: /var/lib/hermes/env (root, 0600), e.g. OPENROUTER_API_KEY=...
# Activation merges it into $HERMES_HOME/.env, so after creating or changing
# it, re-run activation (nixos-rebuild switch) and restart the service.
{ config, pkgs, lib, hermes-agent, ... }:

{
  services.hermes-agent = {
    enable = true;

    # `messaging` is the small variant (~33 MB over minimal); the default
    # package bundles every optional integration (~700 MB).
    package = hermes-agent.packages.${pkgs.stdenv.hostPlatform.system}.messaging;

    environmentFiles = [ "/var/lib/hermes/env" ];

    settings = {
      # Inference via OpenRouter (the default when model.base_url is unset).
      # Paid variant: the :free one was unusable (HTTP 429 from the shared
      # upstream pool). Supports tool calling (per OpenRouter's model list).
      model.default = "google/gemma-4-26b-a4b-it";
      # Tool commands run on the Nano, as the hermes user, inside the
      # service's sandbox (ProtectSystem=strict, writes only to stateDir).
      terminal.backend = "local";
    };

    # Tools on the agent's PATH (the package already wraps git, ripgrep, node).
    extraPackages = with pkgs; [ curl jq file ];

    # `hermes` on the PATH with the service's HERMES_HOME, so the CLI shares
    # sessions, memory and skills with the service.
    addToSystemPackages = true;

    restart = "on-failure";
    restartSec = 10;
  };

  # Group membership gives the admin user access to the workspace and
  # /var/lib/hermes (2770). It does not give access to HERMES_HOME itself:
  # the module sets that to 2770, but Hermes chmods it back to 0700 whenever
  # it writes auth.json (secure_parent_dir() ignores managed mode).
  users.users.sirhc.extraGroups = [ config.services.hermes-agent.group ];

  # So `hermes` in an interactive shell runs as the hermes user, from its
  # workspace: same state as the service, and tool commands run as hermes
  # rather than as the admin user. (No sandbox, unlike the service.)
  environment.interactiveShellInit = ''
    hermes() {
      ( cd ${config.services.hermes-agent.workingDirectory} && command sudo -u ${config.services.hermes-agent.user} \
          env HERMES_HOME=${config.services.hermes-agent.stateDir}/.hermes HOME=${config.services.hermes-agent.stateDir} \
          hermes "$@" )
    }
  '';

  systemd.services.hermes-agent = {
    # /var/lib/hermes is mounted nofail; without the SSD don't start on the
    # empty directory underneath it on the SD card.
    unitConfig.RequiresMountsFor = [ "/var/lib/hermes" ];
    serviceConfig = {
      MemoryHigh = "1500M";
      MemoryMax = "2G";
    };
  };
}
