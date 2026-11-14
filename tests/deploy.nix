{
  lib,
  runCommand,
  closureInfo,
  openssh,
  nix,
  gnutar,
  emulator,
  keeneticSystem,
  buildPlatform,
  kernel ? "generic",
}:
let
  system =
    marker:
    (keeneticSystem {
      inherit buildPlatform;
      modules = [
        {
          image.label = "NIXTEST";
          deploy.host = "127.0.0.1";
          services.dropbear.enable = true;
          environment.etc = {
            marker.text = marker;
            "dropbear/authorized_keys".source = lib.mkForce "/etc/test-authorized-keys";
          };
          ndm.hooks.netfilter."10-test".text = ''
            echo "$1 $table" >> /tmp/hook.log
          '';
        }
      ];
    }).config.build;

  first = system "first";
  second = system "second";
  closure = closureInfo { rootPaths = [ second.toplevel ]; };
in
runCommand "keenetic-deploy-check-${kernel}"
  {
    nativeBuildInputs = [
      emulator
      openssh
      nix
      gnutar
    ];
  }
  ''
    export HOME=$PWD

    ssh-keygen -q -t ed25519 -N "" -f key
    mkdir -p inject/etc
    cp key.pub inject/etc/test-authorized-keys
    tar --owner=0 --group=0 -C inject -czf keys.tar.gz etc

    source=$PWD/source
    mkdir -p $source/nix/store
    xargs -a ${closure}/store-paths cp -a -t $source/nix/store
    nix-store --store "local?root=$source" --load-db < ${closure}/registration

    keenetic-emulator --kernel ${kernel} --ssh-port 2222 --workdir $PWD/work --install keys.tar.gz \
      ${first.image} > console.log 2>&1 &
    emulator=$!

    options="-i $PWD/key -o IdentitiesOnly=yes -o UserKnownHostsFile=$PWD/known_hosts -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5"
    remote() {
      ssh -p 2222 $options root@127.0.0.1 "$@"
    }
    control() {
      keenetic-emulator-ctl -s $PWD/work/control.sock "$1"
    }
    fail() {
      echo "$1" >&2
      tail -n 60 console.log >&2
      exit 1
    }

    attempts=90
    until remote true 2>/dev/null; do
      attempts=$((attempts - 1))
      [ "$attempts" -gt 0 ] || fail "no SSH login"
      kill -0 $emulator 2>/dev/null || fail "the emulator exited"
      sleep 2
    done

    [ "$(remote cat /etc/marker)" = first ] || fail "the image did not boot into the first system"
    dropbear=$(remote s6-svstat -o pid /tmp/nix-run/scan/dropbear)

    NIX_REMOTE="local?root=$source" NIX_SSHOPTS="$options" ${second.deploy}/bin/keenetic-deploy
    [ "$(remote cat /etc/marker)" = second ] || fail "the deploy did not switch to the second system"
    [ "$(remote s6-svstat -o pid /tmp/nix-run/scan/dropbear)" = "$dropbear" ] || fail "an unchanged service was restarted"

    [ "$(remote 'echo $SSL_CERT_FILE')" = /etc/ssl/certs/ca-certificates.crt ] || fail "a remote command did not get the profile"

    control 'hook netfilter table=filter'
    [ "$(remote cat /tmp/hook.log)" = "hook filter" ] || fail "the netfilter hook did not run"

    control poweroff
    wait $emulator || true
    touch $out
  ''
