{
  config,
  lib,
  buildPackages,
  ...
}:
let
  inherit (lib) mkOption optionalString types;

  cfg = config.deploy;
  inherit (config.build) toplevel;
in
{
  options = {
    deploy = {
      host = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Address of the router; without it the deploy script takes the address as its argument.";
      };

      user = mkOption {
        type = types.str;
        default = "root";
        description = "User to log in as.";
      };

      port = mkOption {
        type = types.port;
        default = config.services.dropbear.port;
        defaultText = "config.services.dropbear.port";
        description = "SSH port of the Nix environment on the router.";
      };
    };

    build.deploy = mkOption {
      type = types.package;
      internal = true;
      description = "Script that copies the system to the router and switches to it.";
    };
  };

  config.build.deploy = buildPackages.writeShellApplication {
    name = "keenetic-deploy";
    runtimeInputs = [
      buildPackages.nix
      buildPackages.openssh
    ];
    text = ''
      host=''${1:-${optionalString (cfg.host != null) cfg.host}}
      if [ -z "$host" ]; then
        echo "usage: keenetic-deploy <host>" >&2
        exit 1
      fi
      target=${cfg.user}@$host

      export NIX_SSHOPTS="-p ${toString cfg.port} ''${NIX_SSHOPTS:-}"
      echo "copying ${toplevel} to $target"
      nix --extra-experimental-features nix-command copy --no-check-sigs --to "ssh://$target" ${toplevel}
      echo "switching $target"
      # shellcheck disable=SC2086
      ssh $NIX_SSHOPTS "$target" ${toplevel}/switch
    '';
  };
}
