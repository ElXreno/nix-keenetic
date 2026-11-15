{
  config,
  lib,
  buildPackages,
  ...
}:
let
  inherit (lib)
    all
    attrNames
    concatStrings
    concatStringsSep
    elem
    mapAttrsToList
    mkOption
    types
    ;

  events = [
    "button"
    "fs"
    "ifcreated"
    "ifdestroyed"
    "ifip6changed"
    "ifipchanged"
    "iflayerchanged"
    "ifstatechanged"
    "neighbour"
    "netfilter"
    "schedule"
    "sms"
    "time"
    "usb"
    "user"
    "wan"
  ];

  script =
    event: name: hook:
    buildPackages.writeTextFile {
      name = "${event}-${name}";
      executable = true;
      text = ''
        #!/opt${config.build.bootShell}/bin/sh
        unset LD_LIBRARY_PATH
        . /etc/profile
        export PATH=/bin
        ${hook.text}
      '';
    };
in
{
  options.ndm.hooks = mkOption {
    default = { };
    example = {
      netfilter."10-rules".text = ''
        [ "$table" = filter ] || exit 0
        logger "KeeneticOS rebuilt the $type filter table"
      '';
    };
    description = ''
      Scripts KeeneticOS runs on its events, by event and then by name: the
      scripts of one event run in the order of their names, with the details
      of the event in the environment. Events: ${concatStringsSep ", " events}.
    '';
    type = types.addCheck (types.attrsOf (
      types.attrsOf (
        types.submodule {
          options.text = mkOption {
            type = types.lines;
            description = "Body of the shell script.";
          };
        }
      )
    )) (hooks: all (event: elem event events) (attrNames hooks));
  };

  config.system.activation = ''
    rm -rf /etc/ndm.new /etc/ndm.old
    mkdir -p /etc/ndm.new
    ${concatStrings (
      mapAttrsToList (
        event: hooks:
        concatStrings (
          mapAttrsToList (name: hook: ''
            mkdir -p /etc/ndm.new/${event}.d
            cp ${script event name hook} /etc/ndm.new/${event}.d/${name}
            chmod 755 /etc/ndm.new/${event}.d/${name}
          '') hooks
        )
      ) config.ndm.hooks
    )}
    [ -d /etc/ndm ] && mv /etc/ndm /etc/ndm.old
    mv /etc/ndm.new /etc/ndm
    rm -rf /etc/ndm.old
  '';
}
