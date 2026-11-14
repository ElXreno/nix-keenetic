{
  description = "Nix-managed userspace for Keenetic routers, living on the OPKG drive";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;
      buildPlatforms = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forBuildPlatforms = lib.genAttrs buildPlatforms;

      emulatorFor =
        system: withStockLike:
        (import ./emulator {
          inherit system withStockLike;
          nixpkgs = nixpkgs.outPath;
        }).default;
    in
    {
      lib.keeneticSystem = import ./lib/eval.nix { inherit nixpkgs; };

      keeneticModules.default = ./modules;

      templates.default = {
        path = ./templates/default;
        description = "Nix userspace for one Keenetic router: image and deploy script";
      };

      packages = forBuildPlatforms (buildPlatform: {
        emulator = emulatorFor buildPlatform true;
        emulator-generic = emulatorFor buildPlatform false;
      });

      checks = forBuildPlatforms (
        buildPlatform:
        let
          pkgs = nixpkgs.legacyPackages.${buildPlatform};
          minimal = self.lib.keeneticSystem {
            inherit buildPlatform;
            modules = [ ./tests/minimal.nix ];
          };
          inherit (minimal.config.build) image;
        in
        {
          minimal-image = pkgs.callPackage ./tests/image.nix { inherit image; };
          emulator-boot = pkgs.callPackage ./tests/emulator.nix {
            inherit image;
            emulator = self.packages.${buildPlatform}.emulator-generic;
          };
        }
      );

      formatter = forBuildPlatforms (buildPlatform: nixpkgs.legacyPackages.${buildPlatform}.nixfmt-tree);
    };
}
