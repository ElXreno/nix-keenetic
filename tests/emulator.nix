{
  runCommand,
  emulator,
  image,
}:
runCommand "keenetic-emulator-boot" { nativeBuildInputs = [ emulator ]; } ''
  if ! keenetic-emulator --once --ssh-port 0 --kernel generic --workdir $PWD/work ${image} > console.log 2>&1; then
    tail -n 80 console.log >&2
    exit 1
  fi
  touch $out
''
