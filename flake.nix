{
  description = "NixOS configuration for unicomplex (original Jetson Nano, P3450 B01)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  };

  outputs = { self, nixpkgs }: {
    nixosConfigurations.unicomplex = nixpkgs.lib.nixosSystem {
      modules = [
        ./hosts/unicomplex/configuration.nix
      ];
    };

    # Flashable SD-card image:  nix build .#sdImage
    packages.aarch64-linux.sdImage =
      self.nixosConfigurations.unicomplex.config.system.build.sdImage;
  };
}
