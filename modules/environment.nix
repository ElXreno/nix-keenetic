{
  config,
  lib,
  buildPackages,
  ...
}:
let
  inherit (lib)
    attrValues
    concatMapStrings
    concatStrings
    escapeShellArg
    getBin
    mapAttrsToList
    mkBefore
    mkDefault
    mkIf
    mkOption
    types
    ;

  etcEntries = attrValues config.environment.etc;
in
{
  options = {
    environment = {
      packages = mkOption {
        type = types.listOf types.package;
        default = [ ];
        description = "Packages whose bin and sbin directories are linked into the system profile.";
      };

      variables = mkOption {
        type = types.attrsOf types.str;
        default = { };
        description = "Environment variables exported by /etc/profile, for login shells and services alike.";
      };

      profileExtra = mkOption {
        type = types.lines;
        default = "";
        description = "Shell commands appended to /etc/profile.";
      };

      etc = mkOption {
        default = { };
        description = "Files linked into /etc.";
        type = types.attrsOf (
          types.submodule (
            { name, config, ... }:
            {
              options = {
                target = mkOption {
                  type = types.str;
                  default = name;
                  description = "Path of the entry below /etc.";
                };
                text = mkOption {
                  type = types.nullOr types.lines;
                  default = null;
                  description = "Contents of the file.";
                };
                source = mkOption {
                  type = types.path;
                  description = "File the entry links to.";
                };
              };

              config.source = mkIf (config.text != null) (
                mkDefault (buildPackages.writeText (baseNameOf name) config.text)
              );
            }
          )
        );
      };
    };

    build = {
      path = mkOption {
        type = types.package;
        internal = true;
        description = "Merged bin directory of all packages.";
      };
      etc = mkOption {
        type = types.package;
        internal = true;
        description = "Tree that /etc/static points to.";
      };
    };
  };

  config = {
    environment.etc.profile.text = ''
      ${concatStrings (
        mapAttrsToList (name: value: ''
          export ${name}=${escapeShellArg value}
        '') config.environment.variables
      )}
      ${config.environment.profileExtra}
    '';

    build.path =
      buildPackages.runCommand "keenetic-path" { paths = map getBin config.environment.packages; }
        ''
          mkdir -p $out/bin
          for package in $paths; do
            for directory in bin sbin; do
              [ -d "$package/$directory" ] || continue
              for file in "$package/$directory"/*; do
                [ -e "$out/bin/$(basename "$file")" ] || ln -s "$file" $out/bin/
              done
            done
          done
        '';

    build.etc = buildPackages.runCommand "keenetic-etc" { } ''
      mkdir -p $out
      ${concatMapStrings (entry: ''
        mkdir -p "$out/$(dirname ${escapeShellArg entry.target})"
        ln -s ${entry.source} $out/${escapeShellArg entry.target}
      '') etcEntries}
    '';

    system.activation = mkBefore ''
      mkdir -p /etc
      ln -sfn @out@/etc /etc/static
      find /etc -xdev -type l | while read -r link; do
        case "$(readlink "$link")" in
          /etc/static/*) [ -e "$link" ] || rm -f "$link" ;;
        esac
      done
      ${concatMapStrings (entry: ''
        mkdir -p "$(dirname ${escapeShellArg "/etc/${entry.target}"})"
        ln -sfn ${escapeShellArg "/etc/static/${entry.target}"} ${escapeShellArg "/etc/${entry.target}"}
      '') etcEntries}
    '';
  };
}
