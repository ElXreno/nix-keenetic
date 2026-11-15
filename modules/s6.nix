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
    optionalString
    toLower
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
        assertion = service.user == null || config.users.users ? ${service.user};
        message = "s6.services.${name}: the account ${toString service.user} is not declared in users.users";
      }
      {
        assertion = service.group == null || config.users.groups ? ${service.group};
        message = "s6.services.${name}: the group ${toString service.group} is not declared in users.groups";
      }
      {
        assertion = service.user != null || (service.group == null && service.ambientCapabilities == [ ]);
        message = "s6.services.${name}: group and ambientCapabilities need a user";
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

  identity =
    service:
    let
      uid = toString config.users.ids.users.${service.user};
      gid = toString config.users.ids.groups.${group service};
    in
    {
      inherit uid gid;
      groups = concatStringsSep "," (
        [ gid ]
        ++ map (name: toString config.users.ids.groups.${name}) (
          builtins.filter (
            name:
            name != group service
            && (
              builtins.elem name config.users.users.${service.user}.extraGroups
              || builtins.elem service.user config.users.groups.${name}.members
            )
          ) (attrNames config.users.groups)
        )
      );
    };

  group =
    service: if service.group != null then service.group else config.users.users.${service.user}.group;

  environment =
    service:
    concatStrings (
      mapAttrsToList (variable: value: ''
        export ${variable}=${escapeShellArg value}
      '') service.environment
    );

  prepare =
    service:
    concatStrings (
      mapAttrsToList (
        directory: settings:
        ''
          mkdir -p ${escapeShellArg directory}
          chmod ${settings.mode} ${escapeShellArg directory}
        ''
        + optionalString (service.user != null) ''
          chown ${(identity service).uid}:${(identity service).gid} ${escapeShellArg directory}
        ''
      ) service.directories
    )
    + optionalString (service.workingDirectory != null) ''
      cd ${escapeShellArg service.workingDirectory}
    ''
    + optionalString (service.umask != null) ''
      umask ${service.umask}
    '';

  drop =
    service: program:
    let
      inherit (identity service) uid gid groups;
      capabilities = concatStringsSep "," (map toLower service.ambientCapabilities);
    in
    if service.user == null then
      program
    else if service.ambientCapabilities == [ ] then
      "${s6}/bin/s6-applyuidgid -u ${uid} -g ${gid} -G ${groups} -- ${program}"
    else
      "${getBin pkgs.libcap}/bin/capsh --caps='${capabilities}+eip cap_setpcap,cap_setuid,cap_setgid+ep' --keep=1 --gid=${gid} --groups=${groups} --uid=${uid} --addamb=${capabilities} --shell=${program} --";

  definitions =
    name: service:
    if service.type == "oneshot" then
      {
        ${name} = {
          type = "oneshot\n";
          up = "${script "${name}-up" ''
            ${environment service}
            ${prepare service}
            exec ${drop service (script "${name}-up-commands" service.up)}
          ''}\n";
        }
        // optionalAttrs (service.down != "") {
          down = "${script "${name}-down" ''
            ${environment service}
            exec ${drop service (script "${name}-down-commands" service.down)}
          ''}\n";
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
            ${environment service}
            ${prepare service}
            exec ${drop service (
              script "${name}-commands" ''
                ${service.preStart}
                exec ${service.command}
              ''
            )}
          '';
        }
        // optionalAttrs (service.postStop != "" || service.restartDelay > 0) {
          finish = ''
            #!${shell}
            exec 2>&1
            ${environment service}
            ${service.postStop}
            ${optionalString (service.restartDelay > 0) "sleep ${toString service.restartDelay}"}
          '';
          timeout-finish = "${toString ((service.restartDelay + 5) * 1000)}\n";
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
      }) (attrNames (filterAttrs (_: service: service.autoStart) services))
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
        for finish in $out/source/*/finish; do
          [ -e "$finish" ] && chmod +x "$finish"
        done
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

            autoStart = mkOption {
              type = types.bool;
              default = true;
              description = "Whether the service is brought up with the system. A oneshot that is not can be run on a schedule, see `s6.runOneshot`.";
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

            postStop = mkOption {
              type = types.lines;
              default = "";
              description = "Shell commands run as root every time a longrun has exited.";
            };

            restartDelay = mkOption {
              type = types.ints.unsigned;
              default = 0;
              description = "Seconds to wait before a longrun that exited is started again.";
            };

            user = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = "Account from `users.users` the commands run as; root when unset.";
            };

            group = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = "Group the commands run as; the primary group of the account when unset.";
            };

            ambientCapabilities = mkOption {
              type = types.listOf types.str;
              default = [ ];
              example = [ "CAP_NET_BIND_SERVICE" ];
              description = "Capabilities kept when the commands run as an account other than root.";
            };

            directories = mkOption {
              type = types.attrsOf (
                types.submodule {
                  options.mode = mkOption {
                    type = types.str;
                    default = "0755";
                    description = "Permissions of the directory.";
                  };
                }
              );
              default = { };
              example = {
                "/var/lib/example" = { };
              };
              description = "Directories created before the commands run and handed to the account of the service.";
            };

            workingDirectory = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = "Directory the commands run in.";
            };

            umask = mkOption {
              type = types.nullOr types.str;
              default = null;
              example = "0077";
              description = "File mode creation mask of the commands.";
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

  options.s6.runOneshot = mkOption {
    type = types.functionTo types.str;
    readOnly = true;
    default =
      name:
      "${s6-rc}/bin/s6-rc -b -l ${liveDirectory} -d -t 60000 change ${name} && ${s6-rc}/bin/s6-rc -b -l ${liveDirectory} -u change ${name}";
    defaultText = lib.literalMD "a command that brings the oneshot down and up again";
    description = "Function from the name of a oneshot to the shell command that runs it once more, for use in `cron.jobs`.";
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
        changed=
        while read -r name hash; do
          previous=$(awk -v name="$name" '$1 == name { print $2 }' ${manifest})
          if [ -n "$previous" ] && [ "$previous" != "$hash" ]; then
            changed="$changed $name"
          fi
        done < ${database}/manifest
        ${s6-rc}/bin/s6-rc-update -b -t 30000 -l "$live" "$compiled"
        if [ "$(readlink -f "$live/compiled")" = "$compiled" ] && [ -n "$changed" ]; then
          ${s6-rc}/bin/s6-rc -b -l "$live" -d -t 15000 change $changed || status=1
        fi
        settle=true
      fi

      if [ "$(readlink -f "$live/compiled")" = "$compiled" ]; then
        cp ${database}/manifest ${manifest}
      else
        echo "the service database was not switched" >&2
        status=1
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
