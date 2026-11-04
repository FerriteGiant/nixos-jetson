{
  description = "Headless NixOS for the original Jetson Nano developer kit (P3450, mainline kernel)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    # Hermes Agent. Upstream treats Nix as best-effort ("Tier 2"), so pin a
    # tested revision and bump it deliberately. Its own nixpkgs is kept (not
    # `follows`): the package is built and tested upstream against it.
    hermes-agent.url = "github:NousResearch/hermes-agent/90c19e31968397a1d9bd1e9bb4f6d2c1d6f00be3";
  };

  outputs = { self, nixpkgs, hermes-agent }: {
    nixosConfigurations.unicomplex = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit hermes-agent; };
      modules = [
        hermes-agent.nixosModules.default
        ./hosts/unicomplex/configuration.nix
      ];
    };

    # Flashable SD-card image:  nix build .#sdImage
    packages.aarch64-linux.sdImage =
      self.nixosConfigurations.unicomplex.config.system.build.sdImage;
  };
}
