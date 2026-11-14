{
  system ? builtins.currentSystem,
  withStockLike ? true,
  nixpkgs ?
    let
      pin = (builtins.fromJSON (builtins.readFile ../flake.lock)).nodes.nixpkgs.locked;
    in
    builtins.fetchTarball {
      url = "https://github.com/${pin.owner}/${pin.repo}/archive/${pin.rev}.tar.gz";
      sha256 = pin.narHash;
    },
}:
let
  pkgs = import nixpkgs { inherit system; };
  target = import nixpkgs { system = "aarch64-linux"; };
  inherit (pkgs) lib;

  firmware = pkgs.fetchurl {
    url = "https://osvault.keenetic.net/KN-1012/5.01/KN-1012_stable_5.1.8_5.01.C.8.0-2.bin";
    sha256 = "dbad480dc6adb944e523448915895a29e8fb4f978119aa4db24daf61fbedcb75";
  };

  rootfs = pkgs.runCommand "keenetic-kn-1012-5.01.C.8.0-2-rootfs.squashfs" { } ''
    dd if=${firmware} of=$out bs=4096 skip=512 status=none
    truncate -s %4096 $out
  '';

  ndm =
    pkgs.runCommand "keenetic-fake-ndm"
      {
        src = ./ndm;
        nativeBuildInputs = [ pkgs.go ];
        env = {
          CGO_ENABLED = "0";
          GOOS = "linux";
          GOARCH = "arm64";
          GOFLAGS = "-buildvcs=false -trimpath";
          GOPROXY = "off";
        };
      }
      ''
        export HOME=$TMPDIR GOCACHE=$TMPDIR/cache GOPATH=$TMPDIR/go
        cp -r $src source
        cd source
        mkdir -p $out/bin
        go build -ldflags '-s -w' -o $out/bin/ndm .
      '';

  mkInitramfs =
    {
      name,
      modules ? null,
      moduleNames ? [ ],
    }:
    pkgs.runCommand "keenetic-emulator-initramfs-${name}.cpio.gz"
      {
        nativeBuildInputs = [
          pkgs.cpio
          pkgs.kmod
          pkgs.xz
          pkgs.zstd
        ];
      }
      ''
        mkdir -p root/dev root/proc root/sys root/newroot root/modules
        cp ${ndm}/bin/ndm root/init
        ${lib.optionalString (modules != null) ''
          version=$(ls ${modules}/lib/modules)
          for name in ${lib.concatStringsSep " " moduleNames}; do
            modprobe --dirname ${modules} --set-version "$version" --show-depends "$name" 2>/dev/null || true
          done | while read -r kind path _; do
            [ "$kind" = insmod ] || continue
            file=$(basename "$path")
            plain=''${file%.xz}
            plain=''${plain%.zst}
            [ -e "root/modules/$plain" ] && continue
            case "$file" in
              *.xz) xz -dc "$path" > "root/modules/$plain" ;;
              *.zst) zstd -dc "$path" > "root/modules/$plain" ;;
              *) cp "$path" "root/modules/$plain" ;;
            esac
            echo "$plain" >> root/modules/order
          done
        ''}
        (cd root && find . | LC_ALL=C sort | cpio --quiet -o -H newc -R 0:0 --reproducible) | gzip -9n > $out
      '';

  plainInitramfs = mkInitramfs { name = "plain"; };

  genericKernel = target.linux;

  stockLikeKernel = import ./kernel { inherit pkgs; };

  kernels = lib.filterAttrs (name: _: withStockLike || name != "stock-like") {
    generic = {
      image = "${genericKernel}/Image";
      initramfs = mkInitramfs {
        name = "generic";
        modules = genericKernel.modules or genericKernel;
        moduleNames = [
          "virtio_pci"
          "virtio_blk"
          "virtio_net"
          "squashfs"
          "xhci_pci"
          "usb_storage"
          "sd_mod"
          "ext4"
          "zram"
          "rtc_pl031"
        ];
      };
      description = "Linux ${genericKernel.version} from nixpkgs (aarch64 binary cache)";
    };
    stock-like = {
      image = "${stockLikeKernel}/Image";
      initramfs = plainInitramfs;
      description = "Linux ${stockLikeKernel.version} built from keenetic/kernel-49 with the KN-1012 configuration";
    };
  };

  kernelCases = lib.concatStrings (
    lib.mapAttrsToList (name: kernel: ''
      ${name})
        kernel_image=${kernel.image}
        kernel_initramfs=${kernel.initramfs}
        kernel_description=${lib.escapeShellArg kernel.description}
        ;;
    '') kernels
  );

  emulator = pkgs.writeShellApplication {
    name = "keenetic-emulator";
    runtimeInputs = [
      pkgs.qemu
      pkgs.coreutils
      pkgs.e2fsprogs
      pkgs.gnugrep
      pkgs.gnused
    ];
    text = ''
      rootfs=${rootfs}
      default_kernel=${if withStockLike then "stock-like" else "generic"}
      plain_initramfs=${plainInitramfs}
      select_kernel() {
        case "$1" in
      ${kernelCases}
          *)
            echo "keenetic-emulator: unknown kernel '$1' (${lib.concatStringsSep ", " (lib.attrNames kernels)})" >&2
            exit 64
            ;;
        esac
      }
      ${builtins.readFile ./run.sh}
    '';
  };

  control = pkgs.writeShellApplication {
    name = "keenetic-emulator-ctl";
    runtimeInputs = [
      pkgs.socat
      pkgs.coreutils
    ];
    text = builtins.readFile ./ctl.sh;
  };
in
{
  inherit
    firmware
    rootfs
    ndm
    kernels
    emulator
    control
    genericKernel
    stockLikeKernel
    ;
  default = pkgs.symlinkJoin {
    name = "keenetic-emulator";
    paths = [
      emulator
      control
    ];
    meta.mainProgram = "keenetic-emulator";
  };
}
