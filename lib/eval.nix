{ nixpkgs }:
{
  modules,
  buildPlatform,
  hostPlatform ? "aarch64-linux",
  specialArgs ? { },
}:
let
  inherit (nixpkgs) lib;

  evaluated = lib.evalModules {
    inherit specialArgs;
    modules = [
      ../modules
      "${nixpkgs}/nixos/modules/misc/assertions.nix"
      {
        _module.args = {
          pkgs = import nixpkgs { system = hostPlatform; };
          buildPackages = import nixpkgs { system = buildPlatform; };
        };
      }
    ]
    ++ modules;
  };

  failed = map (entry: entry.message) (
    builtins.filter (entry: !entry.assertion) evaluated.config.assertions
  );
in
if failed != [ ] then
  throw "\nFailed assertions:\n${lib.concatMapStringsSep "\n" (message: "- ${message}") failed}"
else
  lib.showWarnings evaluated.config.warnings evaluated
