{ pkgs }:
let
  cross = pkgs.pkgsCross.aarch64-multiplatform;
  prefix = cross.stdenv.cc.targetPrefix;

  sdk = pkgs.fetchFromGitHub {
    owner = "keenetic";
    repo = "keenetic-sdk";
    rev = "5c74fc4d907383c91e8d6af3f5d67501f7acb171";
    sha256 = "160iyma3jabff6sbqpfhc62p8al7v9ycshzmydsblgp1ir8dv5q3";
  };

  kconfig =
    pkgs.runCommand "keenetic-kconfig"
      {
        src = ./kconfig;
        nativeBuildInputs = [ pkgs.go ];
        env = {
          CGO_ENABLED = "0";
          GOFLAGS = "-buildvcs=false -trimpath";
          GOPROXY = "off";
        };
      }
      ''
        export HOME=$TMPDIR GOCACHE=$TMPDIR/cache GOPATH=$TMPDIR/go
        cp -r $src source
        cd source
        mkdir -p $out/bin
        go build -o $out/bin/kconfig .
      '';
in
pkgs.gcc14Stdenv.mkDerivation {
  pname = "linux-keenetic-kn-1012-virt";
  version = "4.9-ndm-5";

  src = pkgs.fetchFromGitHub {
    owner = "keenetic";
    repo = "kernel-49";
    rev = "f792c9826181743d9b0014b5f0f39f7a5a4e212c";
    sha256 = "1kkhd2lqjspbp974xlrl4kzj8iihq931h5wd3qaawr0n2jylcd9b";
  };

  nativeBuildInputs = [
    cross.buildPackages.gcc14
    cross.buildPackages.binutils
    kconfig
    pkgs.bc
    pkgs.perl
    pkgs.kmod
  ];

  hardeningDisable = [ "all" ];
  enableParallelBuilding = true;

  postPatch = ''
    for file in $(find . -name Makefile -o -name Makefile.include -o -name install.sh); do
      sed -i "$file" -e 's|/usr/bin/||g ; s|/bin/||g ; s|/sbin/||g'
    done
    patchShebangs scripts
  '';

  makeFlags = [
    "ARCH=arm64"
    "CROSS_COMPILE=${prefix}"
    "HOSTCC=cc"
    "KBUILD_BUILD_USER=emulator"
    "KBUILD_BUILD_HOST=nix"
    "KBUILD_BUILD_TIMESTAMP=1970-01-01"
  ];

  configurePhase = ''
    runHook preConfigure
    kconfig -sdk ${sdk} -target mt7981 -board KN-1012 -version 4.9 -fragment ${./virt.config} -report package-overrides > .config
    cp .config requested-config
    make $makeFlags olddefconfig
    runHook postConfigure
  '';

  buildFlags = [ "Image" ];

  installPhase = ''
    runHook preInstall
    mkdir -p $out
    cp arch/arm64/boot/Image $out/Image
    cp .config $out/config
    cp requested-config package-overrides System.map $out/
    runHook postInstall
  '';

  dontStrip = true;
  dontFixup = true;
}
