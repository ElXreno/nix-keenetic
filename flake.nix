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

      optionsDocFor =
        buildPlatform:
        let
          system = self.lib.keeneticSystem {
            inherit buildPlatform;
            modules = [ ];
          };
        in
        (nixpkgs.legacyPackages.${buildPlatform}.nixosOptionsDoc {
          options = removeAttrs system.options [ "_module" ];
          transformOptions =
            option:
            option
            // {
              declarations = map (
                path:
                let
                  name = lib.removePrefix "${self}/" (toString path);
                in
                {
                  inherit name;
                  url = "https://github.com/ElXreno/nix-keenetic/blob/main/${name}";
                }
              ) option.declarations;
            };
        }).optionsCommonMark;
    in
    {
      lib.keeneticSystem = import ./lib/eval.nix { inherit nixpkgs; };

      templates.default = {
        path = ./templates/default;
        description = "Nix userspace for one Keenetic router: image and deploy script";
      };

      packages = forBuildPlatforms (buildPlatform: {
        emulator = emulatorFor buildPlatform true;
        emulator-generic = emulatorFor buildPlatform false;
        docs = nixpkgs.legacyPackages.${buildPlatform}.callPackage ./docs {
          optionsDoc = optionsDocFor buildPlatform;
        };
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
          inherit (self.packages.${buildPlatform}) docs;
          emulator-boot = pkgs.callPackage ./tests/emulator.nix {
            inherit image;
            emulator = self.packages.${buildPlatform}.emulator-generic;
          };
          deploy = pkgs.callPackage ./tests/deploy.nix {
            inherit buildPlatform;
            inherit (self.lib) keeneticSystem;
            emulator = self.packages.${buildPlatform}.emulator-generic;
          };
          deploy-vendor-kernel = pkgs.callPackage ./tests/deploy.nix {
            inherit buildPlatform;
            inherit (self.lib) keeneticSystem;
            emulator = self.packages.${buildPlatform}.emulator;
            kernel = "stock-like";
          };
        }
      );

      formatter = forBuildPlatforms (buildPlatform: nixpkgs.legacyPackages.${buildPlatform}.nixfmt-tree);
    };
}
