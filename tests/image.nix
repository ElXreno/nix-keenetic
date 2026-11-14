{
  runCommand,
  e2fsprogs,
  image,
}:
runCommand "keenetic-image-check" { nativeBuildInputs = [ e2fsprogs ]; } ''
  e2fsck -fn ${image}

  features=$(dumpe2fs -h ${image} 2>/dev/null | sed -n 's/^Filesystem features: *//p')
  case " $features " in
    *" orphan_file "*)
      echo "orphan_file lets a newer kernel leave orphan_present behind, which Linux 4.9 refuses to mount" >&2
      exit 1
      ;;
  esac

  for path in /etc/initrc /bin /usr/bin /opt/etc/initrc /nix/var/nix/profiles/system /nix/var/nix/db/db.sqlite; do
    debugfs -R "stat $path" ${image} 2>&1 | grep -q '^Inode:' || {
      echo "$path is missing from the image" >&2
      exit 1
    }
  done

  touch $out
''
