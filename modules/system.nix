{
  config,
  lib,
  pkgs,
  buildPackages,
  ...
}:
let
  inherit (lib)
    mkOption
    mkOrder
    optionalString
    types
    ;

  shell = "${pkgs.busybox}/bin/sh";
  profile = "/nix/var/nix/profiles/system";
  inherit (config.system) runtimeDirectory;

  bootShell = buildPackages.runCommand "keenetic-boot-shell" { } ''
    mkdir -p $out/bin
    cp ${pkgs.busybox}/bin/busybox $out/bin/sh
  '';

  bootstrap = buildPackages.writeTextFile {
    name = "initrc";
    executable = true;
    text = ''
      #!/opt${bootShell}/bin/sh
      exec ${profile}/initrc "$@"
    '';
  };

  activate = ''
    #!${shell}
    export PATH=@out@/sw/bin
    ${config.system.activation}
  '';

  switch = ''
    #!${shell}
    export PATH=@out@/sw/bin
    confirmation=${runtimeDirectory}/confirmed-$(basename @out@)

    if [ "$1" = --confirm ]; then
      mkdir -p ${runtimeDirectory}
      touch "$confirmation"
      ${optionalString (config.system.keepGenerations != null) ''
        nix-env -p ${profile} --delete-generations +${toString config.system.keepGenerations}
        nix-store --gc 2>&1 | tail -n 1
      ''}
      exit 0
    fi

    timeout=0
    if [ "$1" = --confirm-timeout ]; then
      timeout=$2
    fi

    current=$(readlink -f ${profile})
    if [ "$current" != @out@ ] && [ -x "$current/initrc" ] && [ ! -e "$current/live-switch" ]; then
      "$current/initrc" stop
    fi
    nix-env -p ${profile} --set @out@
    @out@/initrc start
    status=$?
    echo "generation $(basename "$(readlink ${profile})" | cut -d- -f2) active: @out@"

    if [ "$timeout" -gt 0 ] && [ "$current" != @out@ ] && [ -x "$current/switch" ]; then
      rm -f "$confirmation"
      setsid sh -c "sleep $timeout; [ -e $confirmation ] || [ \"\$(readlink -f ${profile})\" != @out@ ] || exec $current/switch" </dev/null >/dev/null 2>&1 &
      echo "waiting $timeout s for confirmation, otherwise back to $current"
    fi
    exit $status
  '';

  initrc = ''
    #!${shell}
    export PATH=@out@/sw/bin
    unset LD_LIBRARY_PATH

    start() {
      @out@/activate
      . /etc/profile
      export PATH=/bin
      ${config.system.initrc.start}
    }

    stop() {
      :
      ${config.system.initrc.stop}
    }

    case "''${1:-start}" in
      start) start ;;
      stop) stop ;;
      restart)
        stop
        start
        ;;
      *)
        echo "usage: $0 start|stop|restart" >&2
        exit 1
        ;;
    esac
  '';
in
{
  options = {
    system = {
      activation = mkOption {
        type = types.lines;
        default = "";
        description = "Shell commands that bring the root filesystem in line with the configuration.";
      };

      keepGenerations = mkOption {
        type = types.nullOr types.ints.positive;
        default = null;
        description = "Number of newest generations to keep; older ones are deleted and the store is garbage collected once a deploy is confirmed. Nothing is deleted when unset.";
      };

      runtimeDirectory = mkOption {
        type = types.str;
        default = "/tmp/nix-run";
        description = "Directory on the router's tmpfs that /var/run points to; /tmp/run belongs to KeeneticOS.";
      };

      initrc = {
        start = mkOption {
          type = types.lines;
          default = "";
          description = "Shell commands run after activation when the OPKG drive comes up.";
        };
        stop = mkOption {
          type = types.lines;
          default = "";
          description = "Shell commands run before the OPKG drive goes away.";
        };
      };
    };

    build.bootShell = mkOption {
      type = types.package;
      internal = true;
      description = "Shell as a regular file, the only kind of interpreter KeeneticOS accepts for scripts it runs itself.";
    };

    build.bootstrap = mkOption {
      type = types.package;
      internal = true;
      description = "The /etc/initrc that KeeneticOS runs; its interpreter has to be a regular file reachable without symlinks into /nix.";
    };

    build.toplevel = mkOption {
      type = types.package;
      internal = true;
      description = "System profile: sw, etc, activate, initrc and switch.";
    };
  };

  config = {
    environment.packages = [ pkgs.busybox ];

    environment.etc = {
      passwd.text = "root:x:0:0:root:/root:/bin/sh";
      group.text = "root:x:0:";
      shells.text = "/bin/sh";
    };

    system.activation = mkOrder 100 ''
      mkdir -p /etc /root /home /var/log ${runtimeDirectory}
      if [ "$(readlink /var/run)" != ${runtimeDirectory} ]; then
        rm -rf /var/run
        ln -s ${runtimeDirectory} /var/run
      fi
      cp ${bootstrap} /etc/initrc.new
      chmod 755 /etc/initrc.new
      mv -f /etc/initrc.new /etc/initrc
    '';

    build.bootShell = bootShell;
    build.bootstrap = bootstrap;

    build.toplevel =
      buildPackages.runCommand "keenetic-system"
        {
          inherit activate initrc switch;
          passAsFile = [
            "activate"
            "initrc"
            "switch"
          ];
        }
        ''
          mkdir $out
          ln -s ${config.build.path} $out/sw
          ln -s ${config.build.etc} $out/etc
          substitute $activatePath $out/activate --subst-var out
          substitute $initrcPath $out/initrc --subst-var out
          substitute $switchPath $out/switch --subst-var out
          chmod +x $out/activate $out/initrc $out/switch
          touch $out/live-switch
        '';
  };
}
