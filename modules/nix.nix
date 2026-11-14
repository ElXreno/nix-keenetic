{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib)
    concatStringsSep
    isBool
    isList
    mapAttrsToList
    mkEnableOption
    mkIf
    mkOption
    types
    ;

  cfg = config.nix;

  render =
    value:
    if isBool value then
      (if value then "true" else "false")
    else if isList value then
      concatStringsSep " " value
    else
      toString value;
in
{
  options.nix = {
    enable = mkEnableOption "Nix on the router, the receiving end of `nix copy`" // {
      default = true;
    };

    package = mkOption {
      type = types.package;
      default = pkgs.nixStatic;
      defaultText = "pkgs.nixStatic";
      description = "Nix package put on the router.";
    };

    settings = mkOption {
      type = types.attrsOf (
        types.oneOf [
          types.bool
          types.int
          types.str
          (types.listOf types.str)
        ]
      );
      default = { };
      description = "Entries of nix.conf.";
    };
  };

  config = mkIf cfg.enable {
    environment.packages = [ cfg.package ];

    nix.settings = {
      sandbox = false;
      filter-syscalls = false;
      build-users-group = "";
      experimental-features = [ "nix-command" ];
    };

    environment.etc."nix/nix.conf".text = concatStringsSep "\n" (
      mapAttrsToList (name: value: "${name} = ${render value}") cfg.settings
    );
  };
}
