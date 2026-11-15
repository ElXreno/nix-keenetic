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
  liveSwitchVersion = "2";
  inherit (config.system) runtimeDirectory;

  bootShell = buildPackages.runCommand "keenetic-boot-shell" { } ''
    mkdir -p $out/bin
    cp ${pkgs.busybox}/bin/busybox $out/bin/sh
  '';

  loginShell = buildPackages.writeTextFile {
    name = "login-shell";
    executable = true;
    text = ''
      #!${shell}
      [ -r /etc/profile ] && . /etc/profile
      exec ${shell} "$@"
    '';
  };

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

  lock = ''
    if [ -z "$KEENETIC_LOCK_HELD" ]; then
      mkdir -p ${runtimeDirectory}
      exec 9>${runtimeDirectory}/lock
      attempts=1500
      until flock -n 9; do
        attempts=$((attempts - 1))
        if [ "$attempts" -eq 0 ]; then
          echo "another switch has been running for five minutes, giving up" >&2
          exit 1
        fi
        sleep 0.2
      done
      export KEENETIC_LOCK_HELD=1
    fi
  '';

  switch = ''
    #!${shell}
    export PATH=@out@/sw/bin
    ${lock}
    confirmation=${runtimeDirectory}/confirmed-$(basename @out@)

    generation() {
      basename "$(readlink ${profile})" | cut -d- -f2
    }

    compatible() {
      [ "$(cat "$1/live-switch" 2>/dev/null)" = ${liveSwitchVersion} ]
    }

    rollback() {
      echo "rolling back: $1" >&2
      failed=$(generation)
      nix-env -p ${profile} --rollback
      nix-env -p ${profile} --delete-generations "$failed"
      previous=$(readlink -f ${profile})
      compatible "$previous" || @out@/initrc stop
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
    if [ "$current" != @out@ ] && [ -x "$current/initrc" ] && ! compatible "$current"; then
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
      setsid sh -c "unset KEENETIC_LOCK_HELD; sleep $timeout; exec @out@/switch --unconfirmed $(generation)" </dev/null >/dev/null 2>&1 9>&- &
      echo "waiting $timeout s for confirmation, otherwise back to $current"
    fi
  '';

  initrc = ''
    #!${shell}
    export PATH=@out@/sw/bin
    unset LD_LIBRARY_PATH
    ${lock}

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

    users.users.root = {
      uid = 0;
      description = "root";
      home = "/root";
      shell = "${loginShell}";
    };
    users.groups.root.gid = 0;

    environment.etc.shells.text = ''
      /bin/sh
      ${loginShell}
    '';

    system.activation = mkOrder 100 ''
      mkdir -p /etc /root /home /var/log /var/lib /var/cache /var/empty ${runtimeDirectory}
      for link in /var/run /run; do
        if [ "$(readlink $link)" != ${runtimeDirectory} ]; then
          rm -rf $link
          ln -s ${runtimeDirectory} $link
        fi
      done
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
          echo ${liveSwitchVersion} > $out/live-switch
        '';
  };
}
