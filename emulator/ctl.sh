socket=${KEENETIC_EMULATOR_CONTROL:-}
limit=900
while [ $# -gt 0 ]; do
  case "$1" in
    -s) socket=$2; shift 2 ;;
    -t) limit=$2; shift 2 ;;
    *) break ;;
  esac
done
if [ -z "$socket" ] || [ $# -eq 0 ]; then
  echo "usage: keenetic-emulator-ctl [-s <control socket>] [-t <seconds>] <command...>" >&2
  echo "       the socket may also come from KEENETIC_EMULATOR_CONTROL; try the command 'help'" >&2
  exit 64
fi

coproc channel { timeout "$limit" socat - "UNIX-CONNECT:$socket"; }
printf '%s\n' "$*" >&"${channel[1]}"
verdict="error: no answer"
while IFS= read -r line <&"${channel[0]}"; do
  line=${line%$'\r'}
  case "$line" in
    "= "*)
      verdict=${line#= }
      break
      ;;
    *) printf '%s\n' "$line" ;;
  esac
done
# shellcheck disable=SC2154
kill "$channel_PID" 2>/dev/null || true
if [ "$verdict" != ok ]; then
  echo "keenetic-emulator-ctl: $verdict" >&2
  exit 1
fi
