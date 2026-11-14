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
    types
    ;

  cfg = config.services.dropbear;

  hostKey = "/etc/dropbear/dropbear_ed25519_host_key";
  pidFile = "/var/run/dropbear.pid";
in
{
  options.services.dropbear = {
    enable = mkEnableOption "the Dropbear SSH server inside the Nix environment";

    port = mkOption {
      type = types.port;
      default = 2222;
      description = "Port to listen on; 22 belongs to the KeeneticOS command line.";
    };

    authorizedKeys = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Public keys allowed to log in as root.";
    };
  };

  config = mkIf cfg.enable {
    environment.packages = [ pkgs.dropbear ];

    environment.etc."dropbear/authorized_keys".text = concatStringsSep "\n" cfg.authorizedKeys;

    system.activation = ''
      mkdir -p /root/.ssh
      chmod 700 /root /root/.ssh
      ln -sfn /etc/dropbear/authorized_keys /root/.ssh/authorized_keys
    '';

    system.initrc.start = ''
      [ -f ${hostKey} ] || dropbearkey -t ed25519 -f ${hostKey}
      dropbear -s -p ${toString cfg.port} -r ${hostKey} -P ${pidFile}
    '';

    system.initrc.stop = ''
      [ -f ${pidFile} ] && kill "$(cat ${pidFile})"
    '';
  };
}
