{ nixpkgs }:
{
  modules,
  buildPlatform,
  hostPlatform ? "aarch64-linux",
  specialArgs ? { },
}:
nixpkgs.lib.evalModules {
  inherit specialArgs;
  modules = [
    ../modules
    {
      _module.args = {
        pkgs = import nixpkgs { system = hostPlatform; };
        buildPackages = import nixpkgs { system = buildPlatform; };
      };
    }
  ]
  ++ modules;
}
