{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib)
    any
    attrNames
    concatMap
    concatMapStringsSep
    concatStringsSep
    elem
    filter
    filterAttrs
    genAttrs
    hasInfix
    hasPrefix
    hasSuffix
    isList
    listToAttrs
    mapAttrs'
    mapAttrsToList
    mkIf
    mkOption
    nameValuePair
    optional
    optionalAttrs
    optionalString
    removePrefix
    removeSuffix
    splitString
    toInt
    types
    unique
    ;

  cfg = config.nixos;

  nixos = import "${pkgs.path}/nixos/lib/eval-config.nix" {
    system = null;
    modules = [
      cfg.configuration
      {
        nixpkgs.pkgs = pkgs;
        boot.isContainer = true;
        system.stateVersion = lib.trivial.release;
      }
    ];
  };

  inherit (nixos.config) systemd;

  ignoredPrefixes = [
    "Protect"
    "Private"
    "Restrict"
    "SystemCall"
    "Limit"
    "Memory"
    "CPU"
    "IO"
    "Tasks"
    "StartLimit"
    "Timeout"
    "Device"
    "Standard"
    "Syslog"
    "Kill"
    "Watchdog"
    "OOM"
  ];

  ignored = [
    "BindPaths"
    "BindReadOnlyPaths"
    "CapabilityBoundingSet"
    "Delegate"
    "ExecReload"
    "InaccessiblePaths"
    "KeyringMode"
    "LockPersonality"
    "Nice"
    "NoNewPrivileges"
    "NonBlocking"
    "NotifyAccess"
    "PIDFile"
    "ProcSubset"
    "ReadOnlyPaths"
    "ReadWritePaths"
    "RemainAfterExit"
    "RemoveIPC"
    "Restart"
    "RuntimeDirectoryPreserve"
    "Slice"
    "TemporaryFileSystem"
  ];

  directories = {
    StateDirectory = "/var/lib";
    CacheDirectory = "/var/cache";
    LogsDirectory = "/var/log";
    RuntimeDirectory = "/run";
    ConfigurationDirectory = "/etc";
  };

  directoryVariables = {
    StateDirectory = "STATE_DIRECTORY";
    CacheDirectory = "CACHE_DIRECTORY";
    LogsDirectory = "LOGS_DIRECTORY";
    RuntimeDirectory = "RUNTIME_DIRECTORY";
    ConfigurationDirectory = "CONFIGURATION_DIRECTORY";
  };

  handled = [
    "AmbientCapabilities"
    "DynamicUser"
    "Environment"
    "ExecStart"
    "ExecStartPre"
    "ExecStop"
    "ExecStopPost"
    "Group"
    "RestartSec"
    "Type"
    "UMask"
    "User"
    "WorkingDirectory"
  ]
  ++ attrNames directories
  ++ map (name: "${name}Mode") (attrNames directories);

  list = value: if isList value then value else [ value ];
  words =
    value: filter (word: word != "") (concatMap (item: splitString " " (toString item)) (list value));

  longrunTypes = [
    "simple"
    "exec"
    "notify"
    "notify-reload"
  ];

  defaultPath = map toString [
    pkgs.coreutils
    pkgs.findutils
    pkgs.gnugrep
    pkgs.gnused
    systemd.package
  ];

  command =
    line:
    let
      text = lib.trim (toString line);
      tolerant = hasPrefix "-" text;
      body = removePrefix "-" text;
      quoted = hasInfix "\"" body || hasInfix "'" body;
      shell =
        if quoted then
          body
        else
          concatStringsSep "" (
            map (part: if isList part then "\"\${${builtins.head part}}\"" else part) (
              builtins.split "\\$\\{([A-Za-z_][A-Za-z0-9_]*)}" body
            )
          );
      problem =
        if builtins.match "[+!@:|].*" body != null then
          "the prefix '${builtins.substring 0 1 body}' is not supported"
        else if builtins.match ".*[`;|&<>()*?~#\n\\\\].*" body != null then
          "it contains characters the shell would interpret"
        else if hasInfix "$$" body then
          "it contains '$$'"
        else if builtins.match "(.*[^%])?(%%)*%[^%].*" body != null then
          "it contains a % specifier"
        else
          null;
    in
    {
      inherit tolerant problem;
      text = lib.addContextFrom (toString line) shell;
      original = text;
    };

  seconds =
    value:
    let
      text = toString value;
      plain = builtins.match "([0-9]+)(s|sec)?" text;
      milliseconds = builtins.match "([0-9]+)ms" text;
      minutes = builtins.match "([0-9]+)(m|min)" text;
    in
    if plain != null then
      toInt (builtins.head plain)
    else if minutes != null then
      60 * toInt (builtins.head minutes)
    else if milliseconds != null then
      1
    else
      null;

  translate =
    name:
    let
      unit = systemd.services.${name};
      settings = unit.serviceConfig;
      type = settings.Type or "simple";
      oneshot = type == "oneshot";

      start = commandsOf "ExecStart";
      before = commandsOf "ExecStartPre";
      stop = commandsOf "ExecStop";
      after = commandsOf "ExecStopPost";
      commandsOf =
        directive:
        map command (
          builtins.foldl' (kept: line: if toString line == "" then [ ] else kept ++ [ line ]) [ ] (
            list (settings.${directive} or [ ])
          )
        );
      commands = start ++ before ++ stop ++ after;

      dynamic = (settings.DynamicUser or false) == true;
      user =
        if settings ? User then
          toString settings.User
        else if dynamic then
          name
        else
          null;
      group = if settings ? Group then toString settings.Group else null;

      paths = listToAttrs (
        concatMap (
          kind:
          map (directory: nameValuePair "${directories.${kind}}/${directory}" kind) (
            words (settings.${kind} or [ ])
          )
        ) (attrNames directories)
      );

      delay = if settings ? RestartSec then seconds settings.RestartSec else 0;

      siblings = filter (other: other != name && elem other cfg.services) (
        map (removeSuffix ".service") (unique (unit.requires ++ unit.after ++ unit.bindsTo))
      );

      foreign = filter (
        other: hasSuffix ".service" other && !elem (removeSuffix ".service" other) cfg.services
      ) (unit.requires ++ unit.bindsTo);

      unsupported = filter (
        directive:
        !elem directive handled
        && !elem directive ignored
        && !any (prefix: hasPrefix prefix directive) ignoredPrefixes
      ) (attrNames settings);

      lines = concatMapStringsSep "\n" (
        entry: if entry.tolerant then entry.text else "${entry.text} || exit 1"
      );

      problems =
        map (directive: "the directive ${directive} is not supported") unsupported
        ++ map (entry: "the command '${entry.original}': ${entry.problem}") (
          filter (entry: entry.problem != null) commands
        )
        ++ optional (!oneshot && !elem type longrunTypes) "Type=${type} is not supported"
        ++
          optional (start == [ ])
            "the NixOS configuration sets no ExecStart for it; a unit file shipped by a package cannot be translated"
        ++ optional (
          !oneshot && builtins.length start > 1
        ) "a long-running service needs exactly one ExecStart"
        ++ optional (!oneshot && stop != [ ]) "ExecStop of a long-running service is not supported"
        ++ optional (delay == null) "RestartSec=${toString settings.RestartSec} is not understood"
        ++ optional (systemd.sockets ? ${name}) "socket activation is not supported"
        ++ optional (
          unit.postStart != "" || settings ? ExecStartPost
        ) "postStart and ExecStartPost are not supported"
        ++ map (other: "it requires ${other}, which is not listed in nixos.services") foreign;
    in
    {
      inherit problems user;
      etc = filter (target: any (entry: hasInfix "/etc/${target}" entry.original) commands) (
        attrNames etcEntries
      );

      service = {
        type = if oneshot then "oneshot" else "longrun";
        dependencies = siblings;
        inherit user group;
        ambientCapabilities = optionals' (user != null) (words (settings.AmbientCapabilities or [ ]));
        directories = mapAttrs' (
          path: kind: nameValuePair path { mode = toString (settings."${kind}Mode" or "0755"); }
        ) paths;
        workingDirectory =
          if settings ? WorkingDirectory then removePrefix "-" (toString settings.WorkingDirectory) else null;
        umask = if settings ? UMask then toString settings.UMask else null;
        environment =
          filterAttrs (variable: _: variable != "PATH") (
            lib.mapAttrs (_: toString) (filterAttrs (_: value: value != null) unit.environment)
          )
          // listToAttrs (
            map (
              entry:
              let
                parts = builtins.match "([^=]+)=(.*)" (toString entry);
              in
              nameValuePair (builtins.head parts) (lib.addContextFrom (toString entry) (lib.last parts))
            ) (list (settings.Environment or [ ]))
          )
          // mapAttrs' (
            kind: variable:
            nameValuePair variable (
              concatStringsSep ":" (attrNames (filterAttrs (_: other: other == kind) paths))
            )
          ) (filterAttrs (kind: _: settings ? ${kind}) directoryVariables)
          // {
            PATH = concatStringsSep ":" (
              map (package: "${package}/bin") (filter (package: !elem (toString package) defaultPath) unit.path)
              ++ [ "/bin" ]
            );
          };
      }
      // (
        if oneshot then
          {
            up = lines (before ++ start);
            down = lines stop;
          }
        else
          {
            command = (builtins.head start).text;
            preStart = lines before;
            postStop =
              lines after
              + optionalString ((settings.RuntimeDirectoryPreserve or "no") == "no") (
                concatMapStringsSep "" (path: "\nrm -rf ${path}") (
                  attrNames (filterAttrs (_: kind: kind == "RuntimeDirectory") paths)
                )
              );
            restartDelay = if delay == null then 0 else delay;
          }
      );
    };

  optionals' = condition: value: if condition then value else [ ];

  etcEntries = mapAttrs' (_: entry: nameValuePair entry.target entry) (
    filterAttrs (_: entry: entry.enable) nixos.config.environment.etc
  );

  translated = genAttrs (filter (name: systemd.services ? ${name}) cfg.services) translate;

  accounts = unique (
    cfg.users ++ filter (user: user != null) (mapAttrsToList (_: unit: unit.user) translated)
  );

  etcTargets = unique (cfg.etc ++ concatMap (unit: unit.etc) (builtins.attrValues translated));
in
{
  options.nixos = {
    configuration = mkOption {
      type = types.deferredModule;
      default = { };
      example = lib.literalExpression "{ services.vnstat.enable = true; }";
      description = "NixOS configuration that the services listed in `nixos.services` are taken from. It is only evaluated: nothing else of it reaches the router.";
    };

    services = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "vnstat" ];
      description = "systemd services of `nixos.configuration` to run under s6-rc. Sandboxing and resource limits are dropped; a service that needs something that cannot be provided fails the evaluation.";
    };

    users = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Further accounts of `nixos.configuration` to create; those named by `User=` are created by themselves.";
    };

    etc = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "unbound/unbound.conf" ];
      description = "Further `environment.etc` entries of `nixos.configuration` to install; those named in the command lines are installed by themselves.";
    };
  };

  config = mkIf (cfg.services != [ ] || cfg.users != [ ] || cfg.etc != [ ]) {
    assertions =
      map (name: {
        assertion = systemd.services ? ${name};
        message = "nixos.services: the NixOS configuration has no service ${name}";
      }) cfg.services
      ++ concatMap (
        name:
        optional (systemd.services ? ${name} && translated.${name}.problems != [ ]) {
          assertion = false;
          message = "nixos.services: ${name} cannot run under s6-rc:\n${
            concatMapStringsSep "\n" (problem: "    ${problem}") translated.${name}.problems
          }";
        }
      ) cfg.services
      ++ map (target: {
        assertion = etcEntries ? ${target};
        message = "nixos.etc: the NixOS configuration has no environment.etc entry ${target}";
      }) cfg.etc;

    s6.services = lib.mapAttrs (_: unit: unit.service) (
      filterAttrs (name: unit: systemd.services ? ${name} && unit.problems == [ ]) translated
    );

    users.users = genAttrs accounts (
      name:
      let
        user = nixos.config.users.users.${name} or null;
      in
      optionalAttrs (user != null) (
        {
          inherit (user) description;
          home = toString user.home;
        }
        // optionalAttrs (user.group != "") { inherit (user) group; }
        // optionalAttrs (user.uid != null) { inherit (user) uid; }
      )
    );

    users.groups = listToAttrs (
      concatMap (
        name:
        let
          user = nixos.config.users.users.${name} or null;
          group = if user == null then null else nixos.config.users.groups.${user.group} or null;
        in
        optional (group != null && group.gid != null) (nameValuePair user.group { inherit (group) gid; })
      ) accounts
    );

    environment.etc = genAttrs etcTargets (target: {
      source = "${etcEntries.${target}.source}";
    });
  };
}
