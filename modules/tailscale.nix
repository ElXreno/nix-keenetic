{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib)
    concatStringsSep
    mkEnableOption
    mkIf
    mkOption
    optional
    types
    ;

  cfg = config.services.tailscale;

  stateDirectory = "/var/lib/tailscale";
  socket = "/var/run/tailscale/tailscaled.sock";
in
{
  options.services.tailscale = {
    enable = mkEnableOption "the Tailscale daemon";

    package = mkOption {
      type = types.package;
      default = pkgs.tailscale;
      defaultText = "pkgs.tailscale";
      description = "Tailscale package.";
    };

    userspaceNetworking = mkOption {
      type = types.bool;
      default = true;
      description = "Run without a tun device, routes and firewall rules, so the router's own networking stays untouched.";
    };

    extraFlags = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Extra arguments for tailscaled.";
    };
  };

  config = mkIf cfg.enable {
    environment.packages = [ cfg.package ];

    s6.services.tailscaled = {
      preStart = ''
        mkdir -p ${stateDirectory} "$(dirname ${socket})"
      '';
      command = concatStringsSep " " (
        [
          "tailscaled"
          "--statedir=${stateDirectory}"
          "--socket=${socket}"
        ]
        ++ optional cfg.userspaceNetworking "--tun=userspace-networking"
        ++ cfg.extraFlags
      );
    };
  };
}
