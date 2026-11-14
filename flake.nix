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
    in
    {
      lib.keeneticSystem = import ./lib/eval.nix { inherit nixpkgs; };

      keeneticModules.default = ./modules;

      checks = forBuildPlatforms (
        buildPlatform:
        let
          pkgs = nixpkgs.legacyPackages.${buildPlatform};
          minimal = self.lib.keeneticSystem {
            inherit buildPlatform;
            modules = [ ./tests/minimal.nix ];
          };
        in
        {
          minimal-image = pkgs.callPackage ./tests/image.nix { inherit (minimal.config.build) image; };
        }
      );

      formatter = forBuildPlatforms (buildPlatform: nixpkgs.legacyPackages.${buildPlatform}.nixfmt-tree);
    };
}
