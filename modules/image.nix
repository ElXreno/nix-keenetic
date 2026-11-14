{
  config,
  lib,
  buildPackages,
  ...
}:
let
  inherit (lib) mkOption types;

  cfg = config.image;
  inherit (config.build) toplevel;

  closure = buildPackages.closureInfo { rootPaths = [ toplevel ]; };
  profiles = "/nix/var/nix/profiles";
in
{
  options = {
    image = {
      label = mkOption {
        type = types.strMatching "[A-Za-z0-9_-]{1,16}";
        default = "NIX";
        description = "Filesystem label, the name `opkg disk` refers to.";
      };

      uuid = mkOption {
        type = types.str;
        default = "6b65656e-6574-4963-8e69-786f70740001";
        description = "Filesystem UUID.";
      };

      extraSpace = mkOption {
        type = types.ints.positive;
        default = 256;
        description = "Free space in MiB left in the image on top of the closure.";
      };
    };

    build.image = mkOption {
      type = types.package;
      internal = true;
      description = "ext4 image of the OPKG partition.";
    };
  };

  config.build.image =
    buildPackages.runCommand "keenetic-${cfg.label}.ext4"
      {
        nativeBuildInputs = [
          buildPackages.e2fsprogs
          buildPackages.fakeroot
          buildPackages.nix
        ];
      }
      ''
        root=$PWD/root
        mkdir -p $root/nix/store $root${profiles}
        mkdir -p $root/{etc,dev,proc,sys,tmp,root,home,usr,var/log}
        chmod 1777 $root/tmp
        ln -s . $root/opt
        ln -s ${config.system.runtimeDirectory} $root/var/run

        xargs -a ${closure}/store-paths cp -a -t $root/nix/store
        nix-store --store "local?root=$root" --load-db < ${closure}/registration

        ln -s ${toplevel} $root${profiles}/system-1-link
        ln -s system-1-link $root${profiles}/system
        ln -s ${profiles}/system/sw/bin $root/bin
        ln -s ${profiles}/system/sw/bin $root/usr/bin

        cp ${config.build.bootstrap} $root/etc/initrc
        chmod 755 $root/etc/initrc

        used=$(du -sm $root | cut -f1)
        truncate -s $((used * 105 / 100 + ${toString cfg.extraSpace}))M image

        export SOURCE_DATE_EPOCH=1
        fakeroot mkfs.ext4 -q \
          -b 4096 \
          -L ${cfg.label} \
          -U ${cfg.uuid} \
          -E hash_seed=${cfg.uuid} \
          -O ^orphan_file,^metadata_csum_seed \
          -d $root image

        mv image $out
      '';
}
