{
  config,
  lib,
  buildPackages,
  pkgs,
  ...
}:
let
  inherit (lib)
    concatStrings
    mapAttrsToList
    mkIf
    mkOption
    types
    ;

  cfg = config.cron;

  crontabs = buildPackages.writeTextDir "root" (
    concatStrings (
      mapAttrsToList (
        name: job:
        "${job.schedule} ${
          buildPackages.writeTextFile {
            name = "cron-${name}";
            executable = true;
            text = ''
              #!${pkgs.busybox}/bin/sh
              ${job.command}
            '';
          }
        }\n"
      ) cfg.jobs
    )
  );
in
{
  options.cron.jobs = mkOption {
    default = { };
    description = "Commands run on a schedule by the cron daemon of busybox, as root and in the router's time zone.";
    type = types.attrsOf (
      types.submodule {
        options = {
          schedule = mkOption {
            type = types.strMatching "[^ ]+ [^ ]+ [^ ]+ [^ ]+ [^ ]+";
            example = "30 3 * * *";
            description = "When to run: minute, hour, day of month, month and day of week in crontab notation.";
          };
          command = mkOption {
            type = types.lines;
            description = "Shell commands to run.";
          };
        };
      }
    );
  };

  config = mkIf (cfg.jobs != { }) {
    s6.services.crond.command = "crond -f -d 8 -c ${crontabs}";
  };
}
