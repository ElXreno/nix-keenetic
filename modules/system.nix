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

    generation() {
      basename "$(readlink ${profile})" | cut -d- -f2
    }

    rollback() {
      echo "rolling back: $1" >&2
      failed=$(generation)
      nix-env -p ${profile} --rollback
      nix-env -p ${profile} --delete-generations "$failed"
      previous=$(readlink -f ${profile})
      [ -e "$previous/live-switch" ] || @out@/initrc stop
      "$previous/initrc" start
      echo "generation $(generation) active again: $previous" >&2
    }

    case "$1" in
      --confirm)
        mkdir -p ${runtimeDirectory}
        touch "$confirmation"
        ${optionalString (config.system.keepGenerations != null) ''
          nix-env -p ${profile} --delete-generations +${toString config.system.keepGenerations}
          nix-store --gc 2>&1 | tail -n 1
        ''}
        exit 0
        ;;
      --unconfirmed)
        if [ ! -e "$confirmation" ] && [ "$(readlink -f ${profile})" = @out@ ] && [ "$(generation)" = "$2" ]; then
          rollback "no confirmation arrived"
        fi
        exit 0
        ;;
    esac

    timeout=0
    if [ "$1" = --confirm-timeout ]; then
      timeout=$2
    fi

    current=$(readlink -f ${profile})
    if [ "$current" != @out@ ] && [ -x "$current/initrc" ] && [ ! -e "$current/live-switch" ]; then
      "$current/initrc" stop
    fi
    nix-env -p ${profile} --set @out@ || exit 1

    if ! @out@/initrc start; then
      if [ "$current" != @out@ ] && [ -x "$current/initrc" ]; then
        rollback "the new generation did not start"
      fi
      exit 1
    fi
    echo "generation $(generation) active: @out@"

    if [ "$timeout" -gt 0 ] && [ "$current" != @out@ ] && [ -x "$current/initrc" ]; then
      rm -f "$confirmation"
      setsid sh -c "sleep $timeout; exec @out@/switch --unconfirmed $(generation)" </dev/null >/dev/null 2>&1 &
      echo "waiting $timeout s for confirmation, otherwise back to $current"
    fi
  '';

  initrc = ''
    #!${shell}
    export PATH=@out@/sw/bin
    unset LD_LIBRARY_PATH

    start() {
      status=0
      @out@/activate
      . /etc/profile
      export PATH=/bin
      ${config.system.initrc.start}
      return $status
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
