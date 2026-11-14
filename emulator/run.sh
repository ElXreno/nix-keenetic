usage() {
  cat >&2 <<'EOF'
usage: keenetic-emulator [options] <image.ext4>

  --kernel NAME        stock-like (vendor 4.9 tree) or generic (nixpkgs kernel)
  --kernel-image FILE  boot this arm64 Image instead, with --initramfs FILE
  --initramfs FILE     initramfs for --kernel-image (default: the one without modules)
  --ssh-port N         host port forwarded to guest TCP 2222 (default 2222, 0 disables)
  --forward H:G        extra host port H forwarded to guest TCP port G, repeatable
  --memory M           guest RAM (default 512M)
  --cpus N             guest CPUs (default 2)
  --label L            filesystem label for "opkg disk" (default: read from the image)
  --url URL            pass URL to "opkg disk <label>:/ <url>"
  --install FILE       put FILE into /install of the disk copy (tar.gz or ipk for npkg), repeatable
  --no-auto            do not run "opkg chroot" and "opkg disk" at boot
  --no-chroot          run "opkg disk" without "opkg chroot"
  --once               power off as soon as initrc has finished or failed
  --net MODE           static (default), dhcp, none or ADDRESS/PREFIX[,GATEWAY[,DNS]]
  --ballast SIZE       auto (default), 0 or a size such as 200M
  --memfree KB         MemFree the automatic ballast aims at (default 254280)
  --zram SIZE          zram swap size (default 512M, 0 disables)
  --builtin-unpack     unpack /opt/install with the built-in tar.gz reader instead of the firmware npkg
  --ndm-cwd DIR        working directory of the fake NDM (default /)
  --control PATH       unix socket of the control channel (default <workdir>/control.sock)
  --workdir DIR        where the disk copy, the console log and the socket live
  --keep               keep the work directory after the guest stops
  --append TEXT        extra kernel command line
EOF
  exit 64
}

kernel=$default_kernel
custom_image=
custom_initramfs=
ssh_port=2222
memory=512M
cpus=2
label=
url=
auto=1
chroot=1
once=0
net=static
ballast=auto
memfree=254280
zram=512M
unpack=
ndm_cwd=
control=
workdir=
short_control=
keep=0
append=
forwards=()
installs=()
image=

while [ $# -gt 0 ]; do
  case "$1" in
    --kernel) kernel=$2; shift 2 ;;
    --kernel-image) custom_image=$2; shift 2 ;;
    --initramfs) custom_initramfs=$2; shift 2 ;;
    --ssh-port) ssh_port=$2; shift 2 ;;
    --forward) forwards+=("$2"); shift 2 ;;
    --memory) memory=$2; shift 2 ;;
    --cpus) cpus=$2; shift 2 ;;
    --label) label=$2; shift 2 ;;
    --url) url=$2; shift 2 ;;
    --install) installs+=("$2"); shift 2 ;;
    --no-auto) auto=0; shift ;;
    --no-chroot) chroot=0; shift ;;
    --once) once=1; shift ;;
    --net) net=$2; shift 2 ;;
    --ballast) ballast=$2; shift 2 ;;
    --memfree) memfree=$2; shift 2 ;;
    --zram) zram=$2; shift 2 ;;
    --builtin-unpack) unpack=builtin; shift ;;
    --ndm-cwd) ndm_cwd=$2; shift 2 ;;
    --control) control=$2; shift 2 ;;
    --workdir) workdir=$2; shift 2 ;;
    --keep) keep=1; shift ;;
    --append) append=$2; shift 2 ;;
    -h | --help) usage ;;
    -*) echo "keenetic-emulator: unknown option $1" >&2; usage ;;
    *) image=$1; shift ;;
  esac
done

[ -n "$image" ] || usage
[ -r "$image" ] || { echo "keenetic-emulator: cannot read $image" >&2; exit 66; }

kernel_image=
kernel_initramfs=
kernel_description=
select_kernel "$kernel"
if [ -n "$custom_image" ]; then
  kernel_image=$custom_image
  kernel_initramfs=${custom_initramfs:-$plain_initramfs}
  kernel_description="custom image $custom_image"
  kernel=custom
fi

created=0
if [ -z "$workdir" ]; then
  workdir=$(mktemp -d "${TMPDIR:-/tmp}/keenetic-emulator.XXXXXX")
  created=1
else
  mkdir -p "$workdir"
fi
# shellcheck disable=SC2329
cleanup() {
  [ -z "$short_control" ] || rm -f "$short_control"
  if [ "$keep" = 0 ]; then
    rm -f "$workdir/disk.raw" "$workdir/partition.ext4" "$workdir/control.sock" "$workdir/control.path"
    if [ "$created" = 1 ]; then
      rm -rf "$workdir"
    fi
  fi
}
trap cleanup EXIT

[ -n "$control" ] || control=$workdir/control.sock
if [ ${#control} -gt 100 ]; then
  short_control=$(mktemp -u "${XDG_RUNTIME_DIR:-/tmp}/keenetic-emulator.XXXXXX.sock")
  echo "keenetic-emulator: $control is too long for a unix socket, using $short_control" >&2
  control=$short_control
fi
printf '%s\n' "$control" >"$workdir/control.path"
[ -n "$label" ] || label=$(e2label "$image" 2>/dev/null || true)
[ -n "$label" ] || label=NIX

le32() {
  local value=$1 encoded
  encoded=$(printf '\\x%02x\\x%02x\\x%02x\\x%02x' $((value & 255)) $((value >> 8 & 255)) $((value >> 16 & 255)) $((value >> 24 & 255)))
  printf '%b' "$encoded"
}

start=8064
size=$(stat -L -c %s "$image")
sectors=$(((size + 511) / 512))
disk=$workdir/disk.raw
rm -f "$disk"
truncate -s $(((start + sectors) * 512)) "$disk"
{
  printf '\x4b\x4e\x31\x30'
  printf '\x00\x00'
  printf '\x00\xfe\xff\xff\x83\xfe\xff\xff'
  le32 "$start"
  le32 "$sectors"
} | dd of="$disk" bs=1 seek=440 conv=notrunc status=none
printf '\x55\xaa' | dd of="$disk" bs=1 seek=510 conv=notrunc status=none
source=$image
if [ ${#installs[@]} -gt 0 ]; then
  source=$workdir/partition.ext4
  cp --no-preserve=mode "$image" "$source"
  debugfs -w -R "mkdir /install" "$source" >/dev/null 2>&1 || true
  for archive in "${installs[@]}"; do
    debugfs -w -R "write $archive /install/$(basename "$archive")" "$source" >/dev/null 2>&1
  done
fi
dd if="$source" of="$disk" bs=1M seek=$((start * 512)) oflag=seek_bytes conv=notrunc,sparse status=none

cmdline="console=ttyAMA0 panic=-1 ndm.auto=$auto ndm.chroot=$chroot ndm.once=$once ndm.disk=$label ndm.net=$net ndm.ballast=$ballast ndm.memfree=$memfree ndm.zram=$zram"
[ -z "$url" ] || cmdline="$cmdline ndm.url=$url"
[ -z "$unpack" ] || cmdline="$cmdline ndm.npkg=$unpack"
[ -z "$ndm_cwd" ] || cmdline="$cmdline ndm.cwd=$ndm_cwd"
[ -z "$append" ] || cmdline="$cmdline $append"

netdev=user,id=net0
if [ "$ssh_port" != 0 ]; then
  netdev="$netdev,hostfwd=tcp:127.0.0.1:$ssh_port-:2222"
fi
for forward in "${forwards[@]}"; do
  netdev="$netdev,hostfwd=tcp:127.0.0.1:${forward%%:*}-:${forward##*:}"
done

{
  echo "keenetic-emulator: kernel $kernel: $kernel_description"
  echo "keenetic-emulator: image $image (label $label) as USB disk, partition 1 at sector $start"
  echo "keenetic-emulator: work directory $workdir, control socket $control, console log $workdir/console.log"
  if [ "$ssh_port" != 0 ]; then
    echo "keenetic-emulator: guest TCP 2222 is 127.0.0.1:$ssh_port"
  fi
  echo "keenetic-emulator: the console takes fake NDM commands (help, show log, poweroff); Ctrl-C kills QEMU"
} >&2

status=0
qemu-system-aarch64 \
  -machine virt,gic-version=3 \
  -cpu cortex-a53 \
  -smp "$cpus" \
  -m "$memory" \
  -display none \
  -no-reboot \
  -kernel "$kernel_image" \
  -initrd "$kernel_initramfs" \
  -append "$cmdline" \
  -chardev "stdio,id=console,logfile=$workdir/console.log,logappend=off" \
  -serial chardev:console \
  -chardev "socket,id=control,path=$control,server=on,wait=off" \
  -serial chardev:control \
  -drive "if=none,id=rootfs,file=$rootfs,format=raw,readonly=on" \
  -device virtio-blk-pci,drive=rootfs \
  -device qemu-xhci,id=xhci \
  -drive "if=none,id=opkg,file=$disk,format=raw" \
  -device usb-storage,bus=xhci.0,drive=opkg,removable=on \
  -netdev "$netdev" \
  -device virtio-net-pci,netdev=net0 || status=$?

result=$(sed -n 's/.*Emulator: exit status \([0-9]*\).*/\1/p' "$workdir/console.log" | tail -n 1)
if [ -n "$result" ]; then
  exit "$result"
fi
if [ "$status" = 0 ]; then
  status=1
fi
echo "keenetic-emulator: the guest stopped without reporting a status" >&2
exit "$status"
