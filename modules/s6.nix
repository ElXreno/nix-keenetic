{
  config,
  lib,
  pkgs,
  buildPackages,
  ...
}:
let
  inherit (lib)
    attrNames
    concatStrings
    concatStringsSep
    escapeShellArg
    filterAttrs
    getBin
    mapAttrsToList
    mkEnableOption
    mkIf
    mkOption
    types
    ;

  cfg = config.s6;
  services = filterAttrs (_: service: service.enable) cfg.services;

  shell = "${pkgs.busybox}/bin/sh";
  s6 = getBin pkgs.s6;
  scanDirectory = "${config.system.runtimeDirectory}/scan";
  serviceDirectory = "${config.system.runtimeDirectory}/services";
  logDirectory = "${config.system.runtimeDirectory}/log";

  runScript =
    name: service:
    buildPackages.writeTextFile {
      name = "${name}-run";
      executable = true;
      text = ''
        #!${shell}
        exec 2>&1
        ${concatStrings (
          mapAttrsToList (variable: value: ''
            export ${variable}=${escapeShellArg value}
          '') service.environment
        )}
        ${service.preStart}
        exec ${service.command}
      '';
    };

  logScript =
    name: service:
    buildPackages.writeTextFile {
      name = "${name}-log";
      executable = true;
      text = ''
        #!${shell}
        mkdir -p ${logDirectory}/${name}
        exec ${s6}/bin/s6-log -b n${toString service.log.files} s${toString service.log.size} T ${logDirectory}/${name}
      '';
    };
in
{
  options.s6 = {
    services = mkOption {
      default = { };
      description = "Long-running services supervised by s6.";
      type = types.attrsOf (
        types.submodule {
          options = {
            enable = mkEnableOption "this service" // {
              default = true;
            };

            command = mkOption {
              type = types.str;
              description = "Command line that runs the service in the foreground.";
            };

            environment = mkOption {
              type = types.attrsOf types.str;
              default = { };
              description = "Environment variables of the service.";
            };

            preStart = mkOption {
              type = types.lines;
              default = "";
              description = "Shell commands run before every start of the service.";
            };

            log = {
              files = mkOption {
                type = types.ints.positive;
                default = 4;
                description = "Number of rotated log files to keep.";
              };
              size = mkOption {
                type = types.ints.positive;
                default = 262144;
                description = "Size in bytes at which a log file is rotated.";
              };
            };
          };
        }
      );
    };
  };

  config = mkIf (services != { }) {
    environment.packages = [ pkgs.s6 ];

    system.initrc.start = ''
      scan=${scanDirectory}
      definitions=${serviceDirectory}
      wanted=${escapeShellArg (concatStringsSep " " (attrNames services))}
      changed=
      removed=
      mkdir -p "$scan" "$definitions" ${logDirectory}

      supervised=false
      if [ -p "$scan/.s6-svscan/control" ] && pidof s6-svscan >/dev/null; then
        supervised=true
      fi

      sync_service() {
        mkdir -p "$definitions/$1/log"
        if [ "$(readlink "$definitions/$1/run")" != "$2" ]; then
          ln -sfn "$2" "$definitions/$1/run"
          changed="$changed $1"
        fi
        if [ "$(readlink "$definitions/$1/log/run")" != "$3" ]; then
          ln -sfn "$3" "$definitions/$1/log/run"
          changed="$changed $1/log"
        fi
        [ -L "$scan/$1" ] || ln -s "$definitions/$1" "$scan/$1"
      }

      ${concatStrings (
        mapAttrsToList (name: service: ''
          sync_service ${name} ${runScript name service} ${logScript name service}
        '') services
      )}
      for link in "$scan"/*; do
        [ -L "$link" ] || continue
        name=$(basename "$link")
        case " $wanted " in
          *" $name "*) ;;
          *)
            rm -f "$link"
            removed="$removed $name"
            ;;
        esac
      done

      if $supervised; then
        ${s6}/bin/s6-svscanctl -an "$scan"
        for name in $changed; do
          if ${s6}/bin/s6-svok "$definitions/$name"; then
            ${s6}/bin/s6-svc -wr -T 10000 -r "$definitions/$name" || status=1
          fi
        done
      else
        setsid ${s6}/bin/s6-svscan "$scan" </dev/null >>${logDirectory}/s6-svscan.log 2>&1 &
      fi

      for name in $removed; do
        attempts=25
        while [ "$attempts" -gt 0 ] && ${s6}/bin/s6-svok "$definitions/$name"; do
          sleep 0.2
          attempts=$((attempts - 1))
        done
        rm -rf "$definitions/$name"
      done

      for name in $wanted; do
        attempts=50
        while [ "$attempts" -gt 0 ] && [ "$(${s6}/bin/s6-svstat -u "$scan/$name" 2>/dev/null)" != true ]; do
          sleep 0.2
          attempts=$((attempts - 1))
        done
        if [ "$attempts" -eq 0 ]; then
          echo "service $name did not start" >&2
          status=1
        fi
      done

      if [ -n "$changed" ] || ! $supervised; then
        for name in $wanted; do
          echo "$name $(${s6}/bin/s6-svstat -o pid "$scan/$name" 2>/dev/null)"
        done > "$scan/.settling"
        sleep 2
        while read -r name pid; do
          if [ "$(${s6}/bin/s6-svstat -o up,pid "$scan/$name" 2>/dev/null)" != "true $pid" ]; then
            echo "service $name keeps restarting" >&2
            status=1
          fi
        done < "$scan/.settling"
        rm -f "$scan/.settling"
      fi
    '';

    system.initrc.stop = ''
      if [ -p ${scanDirectory}/.s6-svscan/control ]; then
        ${s6}/bin/s6-svscanctl -t ${scanDirectory}
        attempts=25
        while [ "$attempts" -gt 0 ] && pidof s6-svscan >/dev/null; do
          sleep 0.2
          attempts=$((attempts - 1))
        done
      fi
    '';
  };
}
