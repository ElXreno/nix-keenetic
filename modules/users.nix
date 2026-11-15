{ config, lib, ... }:
let
  inherit (lib)
    attrNames
    concatMapStrings
    concatStringsSep
    filter
    fromHexString
    groupBy
    mapAttrs
    mapAttrs'
    mapAttrsToList
    mkOption
    nameValuePair
    substring
    types
    unique
    ;

  cfg = config.users;

  derived =
    name: 61184 + lib.mod (fromHexString (substring 0 7 (builtins.hashString "sha256" name))) 4336;

  ids = {
    users = mapAttrs (name: user: if user.uid == null then derived name else user.uid) cfg.users;
    groups = mapAttrs (name: group: if group.gid == null then derived name else group.gid) cfg.groups;
  };

  duplicates =
    kind: table:
    mapAttrsToList (id: names: {
      assertion = builtins.length names == 1;
      message = "users.${kind}: ${concatStringsSep ", " names} share the id ${id}; set one of them explicitly";
    }) (groupBy (name: toString table.${name}) (attrNames table));
in
{
  options.users = {
    users = mkOption {
      default = { };
      description = "Accounts written to /etc/passwd.";
      type = types.attrsOf (
        types.submodule (
          { name, ... }:
          {
            options = {
              uid = mkOption {
                type = types.nullOr types.ints.unsigned;
                default = null;
                description = "User id; when unset it is derived from the name and stays the same across builds.";
              };
              group = mkOption {
                type = types.str;
                default = name;
                description = "Primary group; it is created when no such group is declared.";
              };
              extraGroups = mkOption {
                type = types.listOf types.str;
                default = [ ];
                description = "Further groups of the account.";
              };
              description = mkOption {
                type = types.str;
                default = "";
                description = "Comment field of the account.";
              };
              home = mkOption {
                type = types.str;
                default = "/var/empty";
                description = "Home directory.";
              };
              shell = mkOption {
                type = types.str;
                default = "/bin/false";
                description = "Login shell.";
              };
            };
          }
        )
      );
    };

    groups = mkOption {
      default = { };
      description = "Groups written to /etc/group.";
      type = types.attrsOf (
        types.submodule {
          options = {
            gid = mkOption {
              type = types.nullOr types.ints.unsigned;
              default = null;
              description = "Group id; when unset it is derived from the name and stays the same across builds.";
            };
            members = mkOption {
              type = types.listOf types.str;
              default = [ ];
              description = "Accounts that have this group as a further group.";
            };
          };
        }
      );
    };

    ids = mkOption {
      type = types.attrs;
      internal = true;
      readOnly = true;
      description = "Numeric ids of all accounts and groups.";
    };
  };

  config = {
    users.ids = ids;

    users.groups = mapAttrs' (_: user: nameValuePair user.group { }) cfg.users;

    assertions =
      duplicates "users" ids.users
      ++ duplicates "groups" ids.groups
      ++ mapAttrsToList (name: user: {
        assertion = filter (group: !(cfg.groups ? ${group})) user.extraGroups == [ ];
        message = "users.users.${name}: extraGroups names a group that is not declared";
      }) cfg.users;

    environment.etc = {
      passwd.text = concatMapStrings (
        name:
        let
          user = cfg.users.${name};
        in
        "${name}:x:${toString ids.users.${name}}:${
          toString ids.groups.${user.group}
        }:${user.description}:${user.home}:${user.shell}\n"
      ) (attrNames cfg.users);

      group.text = concatMapStrings (
        name:
        let
          members = unique (
            cfg.groups.${name}.members
            ++ filter (user: builtins.elem name cfg.users.${user}.extraGroups) (attrNames cfg.users)
          );
        in
        "${name}:x:${toString ids.groups.${name}}:${concatStringsSep "," members}\n"
      ) (attrNames cfg.groups);
    };
  };
}
