{
  description = "Nix userspace for my Keenetic router";

  inputs.nix-keenetic.url = "github:ElXreno/nix-keenetic";

  outputs =
    { nix-keenetic, ... }:
    let
      system = "x86_64-linux";
      router = nix-keenetic.lib.keeneticSystem {
        buildPlatform = system;
        modules = [ ./router.nix ];
      };
    in
    {
      packages.${system} = {
        inherit (router.config.build) image deploy;
        default = router.config.build.deploy;
      };
    };
}
