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
    concatLists
    concatMapStrings
    concatStrings
    concatStringsSep
    escapeShellArg
    filterAttrs
    getBin
    hasPrefix
    hasSuffix
    listToAttrs
    mapAttrsToList
    mkEnableOption
    mkIf
    mkOption
    optionalAttrs
    optionals
    types
    ;

  cfg = config.s6;
  services = filterAttrs (_: service: service.enable) cfg.services;
  longruns = filterAttrs (_: service: service.type == "longrun") services;

  shell = "${pkgs.busybox}/bin/sh";
  s6 = getBin pkgs.s6;
  s6-rc = getBin pkgs.s6-rc;
  inherit (config.system) runtimeDirectory;
  scanDirectory = "${runtimeDirectory}/scan";
  liveDirectory = "${runtimeDirectory}/s6-rc";
  logDirectory = "${runtimeDirectory}/log";
  manifest = "${runtimeDirectory}/s6-rc-manifest";

  terminate = ''
    for step in -t -q kill; do
      pidof s6-svscan >/dev/null || break
      case $step in
        kill) killall -9 s6-svscan s6-supervise s6-log 2>/dev/null ;;
        *) ${s6}/bin/s6-svscanctl $step ${scanDirectory} 2>/dev/null ;;
      esac
      [ $step = -q ] && killall s6-supervise 2>/dev/null
      attempts=25
      while [ "$attempts" -gt 0 ] && pidof s6-svscan s6-supervise >/dev/null; do
        sleep 0.2
        attempts=$((attempts - 1))
      done
    done
  '';

  problems =
    name: service:
    let
      missing = builtins.filter (
        dependency: !(cfg.services.${dependency}.enable or false)
      ) service.dependencies;
    in
    [
      {
        assertion = builtins.match "[A-Za-z0-9_][A-Za-z0-9_.-]*" name != null;
        message = "s6.services.${name}: a name may only contain letters, digits, '_', '.' and '-'";
      }
      {
        assertion =
          name != "default" && !hasPrefix "s6rc-" name && !hasPrefix "s6-rc-" name && !hasSuffix "-log" name;
        message = "s6.services.${name}: this name is reserved (default, s6rc-*, s6-rc-*, *-log)";
      }
      {
        assertion = service.type != "longrun" || service.command != "";
        message = "s6.services.${name}: a longrun needs a command";
      }
      {
        assertion = service.type != "oneshot" || service.up != "";
        message = "s6.services.${name}: a oneshot needs up";
      }
      {
        assertion = missing == [ ];
        message = "s6.services.${name}: depends on unknown or disabled ${concatStringsSep ", " missing}";
      }
    ];

  script =
    name: text:
    buildPackages.writeTextFile {
      inherit name;
      executable = true;
      text = ''
        #!${shell}
        ${text}
      '';
    };

  dependencies =
    service:
    listToAttrs (
      map (dependency: {
        name = "dependencies.d/${dependency}";
        value = "";
      }) service.dependencies
    );

  definitions =
    name: service:
    if service.type == "oneshot" then
      {
        ${name} = {
          type = "oneshot\n";
          up = "${script "${name}-up" service.up}\n";
        }
        // optionalAttrs (service.down != "") {
          down = "${script "${name}-down" service.down}\n";
        }
        // dependencies service;
      }
    else
      {
        ${name} = {
          type = "longrun\n";
          producer-for = "${name}-log\n";
          run = ''
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
        }
        // dependencies service;
        "${name}-log" = {
          type = "longrun\n";
          consumer-for = "${name}\n";
          run = ''
            #!${shell}
            mkdir -p ${logDirectory}/${name}
            exec ${s6}/bin/s6-log -b n${toString service.log.files} s${toString service.log.size} T ${logDirectory}/${name}
          '';
        };
      };

  atomic = lib.concatMapAttrs definitions services;

  source = atomic // {
    default = {
      type = "bundle\n";
    }
    // listToAttrs (
      map (name: {
        name = "contents.d/${name}";
        value = "";
      }) (attrNames services)
    );
  };

  database =
    buildPackages.runCommand "s6-rc-services"
      {
        nativeBuildInputs = [
          buildPackages.jq
          buildPackages.s6-rc
        ];
        source = builtins.toJSON source;
        manifest = concatStrings (
          mapAttrsToList (
            name: files: "${name} ${builtins.hashString "sha256" (builtins.toJSON files)}\n"
          ) atomic
        );
        passAsFile = [
          "source"
          "manifest"
        ];
      }
      ''
        mkdir -p $out/source
        jq -r 'to_entries[] | .key as $service | .value | keys[] | "\($service)/\(.)"' $sourcePath | while read -r file; do
          mkdir -p "$(dirname "$out/source/$file")"
          jq -j --arg service "''${file%%/*}" --arg file "''${file#*/}" '.[$service][$file]' $sourcePath > "$out/source/$file"
        done
        chmod +x $out/source/*/run
        cp $manifestPath $out/manifest
        s6-rc-compile $out/compiled $out/source
        ${concatMapStrings
          (package: ''
            find $out/compiled -type f -exec sed -i 's|${
              getBin buildPackages.${package}
            }|${getBin pkgs.${package}}|g' {} +
            if grep -rqF ${getBin buildPackages.${package}} $out/compiled; then
              echo "the compiled database still refers to ${package} of the build platform" >&2
              exit 1
            fi
          '')
          (
            optionals (buildPackages.stdenv.hostPlatform != pkgs.stdenv.hostPlatform) [
              "s6"
              "s6-rc"
              "execline"
            ]
          )
        }
      '';
in
{
  options.s6 = {
    services = mkOption {
      default = { };
      description = "Services managed by s6-rc: supervised long-running processes and one-time tasks, started in dependency order.";
      type = types.attrsOf (
        types.submodule {
          options = {
            enable = mkEnableOption "this service" // {
              default = true;
            };

            type = mkOption {
              type = types.enum [
                "longrun"
                "oneshot"
              ];
              default = "longrun";
              description = "Whether this is a supervised process (`longrun`) or a task that runs once when the service is brought up (`oneshot`).";
            };

            dependencies = mkOption {
              type = types.listOf types.str;
              default = [ ];
              description = "Services that have to be up before this one starts; they are stopped after it.";
            };

            command = mkOption {
              type = types.str;
              default = "";
              description = "Command line that runs a longrun in the foreground.";
            };

            environment = mkOption {
              type = types.attrsOf types.str;
              default = { };
              description = "Environment variables of a longrun.";
            };

            preStart = mkOption {
              type = types.lines;
              default = "";
              description = "Shell commands run before every start of a longrun.";
            };

            up = mkOption {
              type = types.lines;
              default = "";
              description = "Shell commands that bring a oneshot up.";
            };

            down = mkOption {
              type = types.lines;
              default = "";
              description = "Shell commands that bring a oneshot down.";
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
    assertions = concatLists (mapAttrsToList problems services);

    environment.packages = [
      pkgs.s6
      pkgs.s6-rc
      pkgs.execline
    ];

    system.initrc.start = ''
      scan=${scanDirectory}
      live=${liveDirectory}
      compiled=${database}/compiled
      settle=false

      if pidof s6-svscan >/dev/null && [ ! -e "$live" ]; then
        ${terminate}
      fi
      if ! [ -p "$scan/.s6-svscan/control" ] || ! pidof s6-svscan >/dev/null; then
        rm -rf "$scan" "$live" "$live":* ${manifest} ${runtimeDirectory}/services
        mkdir -p "$scan" ${logDirectory}
        setsid env -u KEENETIC_LOCK_HELD ${s6}/bin/s6-svscan "$scan" </dev/null >>${logDirectory}/s6-svscan.log 2>&1 9>&- &
        attempts=50
        while [ "$attempts" -gt 0 ] && ! [ -p "$scan/.s6-svscan/control" ]; do
          sleep 0.2
          attempts=$((attempts - 1))
        done
      fi

      if [ ! -e "$live" ]; then
        ${s6-rc}/bin/s6-rc-init -c "$compiled" -l "$live" "$scan" || status=1
        settle=true
      elif [ "$(readlink -f "$live/compiled")" != "$compiled" ]; then
        while read -r name hash; do
          previous=$(awk -v name="$name" '$1 == name { print $2 }' ${manifest})
          if [ -n "$previous" ] && [ "$previous" != "$hash" ]; then
            echo "$name restart"
          fi
        done < ${database}/manifest > ${runtimeDirectory}/s6-rc-conversion
        ${s6-rc}/bin/s6-rc-update -b -l "$live" -f ${runtimeDirectory}/s6-rc-conversion "$compiled" || status=1
        settle=true
      fi

      if [ "$(readlink -f "$live/compiled")" = "$compiled" ]; then
        cp ${database}/manifest ${manifest}
      fi

      ${s6-rc}/bin/s6-rc -b -l "$live" -u -t 15000 change default || status=1

      if $settle; then
        for name in ${concatStringsSep " " (attrNames longruns)}; do
          echo "$name $(${s6}/bin/s6-svstat -o pid "$scan/$name" 2>/dev/null)"
        done > "$scan/.settling.$$"
        sleep 2
        while read -r name pid; do
          if [ "$(${s6}/bin/s6-svstat -o up,pid "$scan/$name" 2>/dev/null)" != "true $pid" ]; then
            echo "service $name keeps restarting" >&2
            status=1
          fi
        done < "$scan/.settling.$$"
        rm -f "$scan/.settling.$$"
      fi
    '';

    system.initrc.stop = ''
      if [ -e ${liveDirectory} ]; then
        ${s6-rc}/bin/s6-rc -b -l ${liveDirectory} -da -t 10000 change
      fi
      ${terminate}
      if ! pidof s6-svscan >/dev/null; then
        rm -rf ${scanDirectory} ${liveDirectory} ${liveDirectory}:* ${manifest}
      fi
    '';
  };
}
