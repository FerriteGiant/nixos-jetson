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

  # Let the admin user use the CLI against the shared state (files are 0007).
  users.users.sirhc.extraGroups = [ config.services.hermes-agent.group ];

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
