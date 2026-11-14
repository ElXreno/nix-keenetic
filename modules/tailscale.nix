{
  config,
  lib,
  pkgs,
  buildPackages,
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

  unwrapped = buildPackages.runCommand "tailscale-unwrapped-${pkgs.tailscale.version}" { } ''
    mkdir -p $out/bin
    cp ${pkgs.tailscale}/bin/.tailscaled-wrapped $out/bin/tailscaled
    ln -s tailscaled $out/bin/tailscale
  '';

  stateDirectory = "/var/lib/tailscale";
  socket = "/var/run/tailscale/tailscaled.sock";
in
{
  options.services.tailscale = {
    enable = mkEnableOption "the Tailscale daemon";

    package = mkOption {
      type = types.package;
      default = if cfg.userspaceNetworking then unwrapped else pkgs.tailscale;
      defaultText = "the tailscaled binary of pkgs.tailscale without its wrapper when userspaceNetworking is on, pkgs.tailscale otherwise";
      description = "Tailscale package. The wrapper of pkgs.tailscale only adds iptables, iproute2, shadow, getent and procps to PATH, which userspace networking does not call; set pkgs.tailscale here for Tailscale SSH.";
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
          "${cfg.package}/bin/tailscaled"
          "--statedir=${stateDirectory}"
          "--socket=${socket}"
        ]
        ++ optional cfg.userspaceNetworking "--tun=userspace-networking"
        ++ cfg.extraFlags
      );
    };
  };
}
