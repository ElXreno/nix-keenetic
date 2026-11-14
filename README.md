# nix-keenetic

Declarative, Nix-built userspace for Keenetic routers. It lives on a USB drive
the same way Entware does, runs next to the stock KeeneticOS and is updated over
SSH, one generation per deploy.

This is not NixOS: the kernel, PID 1 and the network stay with KeeneticOS. What
you get is a `/nix/store` on the drive, a system profile built from a small set
of modules, services supervised by s6 and a `deploy` script.

## Status

Works on a Keenetic Giga (KN-1012, MT7981B, aarch64) with KeeneticOS 5.1.8
(`5.01.C.8.0-2`). That is the only hardware it has been run on. Other aarch64
models with the OPKG component should behave the same, but nobody has checked.
MIPS models are not supported: there is no binary cache for them.

## Requirements

- A Keenetic with an aarch64 CPU and a USB port.
- KeeneticOS components: USB storage, the ext file system and OPKG ("Open
  Package support").
- A USB drive with an ext4 partition. The base system takes about 100 MB on the
  drive, about 280 MB with Tailscale.
- A machine with Nix to build on. Packages for the router come prebuilt from
  `cache.nixos.org`, the glue is built for your own platform, so no cross
  compilation and no binfmt are involved.

## Quick start

1. Create a configuration from the template and put your SSH public key and the
   router address into `router.nix`:

   ```
   nix flake init -t github:ElXreno/nix-keenetic
   ```

2. Build the image and write it into the partition of the drive, then grow the
   file system to the size of the partition:

   ```
   nix build .#image
   sudo dd if=result of=/dev/sdX1 bs=4M conv=fsync
   sudo e2fsck -f /dev/sdX1
   sudo resize2fs /dev/sdX1
   ```

3. Plug the drive into the router and enable it in the KeeneticOS command line
   (SSH or telnet to the router itself). The label is `image.label`:

   ```
   opkg chroot
   opkg disk NIX:/
   system configuration save
   ```

4. Log in to the Nix environment. It listens on its own port, 22 stays with
   KeeneticOS:

   ```
   ssh -p 2222 root@192.168.1.1
   ```

5. From now on change `router.nix` and deploy over the network:

   ```
   nix run .#deploy
   ```

   Every deploy is a new generation of `/nix/var/nix/profiles/system`. Services
   whose definition did not change keep running. After the switch the script
   opens a fresh SSH connection to confirm it; if that does not happen within
   `deploy.confirmTimeout` seconds, the router returns to the previous
   generation by itself. To go back by hand, run the `switch` script of an
   older generation on the router:

   ```
   /nix/var/nix/profiles/system-3-link/switch
   ```

## Configuration

A configuration is a list of modules evaluated by `lib.keeneticSystem`:

```nix
nix-keenetic.lib.keeneticSystem {
  buildPlatform = "x86_64-linux";
  modules = [ ./router.nix ];
}
```

The result has `config.build.image` (ext4 image of the partition),
`config.build.deploy` (copy and switch script) and `config.build.toplevel`.

| Option | Meaning |
|---|---|
| `environment.packages` | Packages on `PATH` |
| `environment.etc.<name>.{text,source}` | Files in `/etc` |
| `environment.variables`, `environment.profileExtra` | `/etc/profile`, read by login shells and services |
| `s6.services.<name>.{command,environment,preStart,log}` | A supervised service with a rotated log in `/tmp/nix-run/log/<name>` |
| `services.dropbear.{enable,port,authorizedKeys}` | SSH into the environment, key authentication only |
| `services.tailscale.{enable,userspaceNetworking,extraFlags}` | Tailscale; without a tun device, routes or firewall rules by default |
| `nix.{enable,package,settings}` | Static Nix on the router, needed for deploys |
| `ndm.hooks.<event>.<name>.text` | Scripts KeeneticOS runs on its events (`netfilter`, `wan`, `ifstatechanged` and the other `/opt/etc/ndm/*.d` directories) |
| `deploy.{host,user,port,confirmTimeout}` | Where `deploy` connects to and how long the router waits for the confirmation |
| `system.keepGenerations` | Keep this many generations and collect garbage after a confirmed deploy; unset keeps everything |
| `image.{label,uuid,extraSpace}` | Image parameters |
| `system.activation`, `system.initrc.{start,stop}` | Hooks into activation and into the script KeeneticOS runs |

The package set is plain nixpkgs for `aarch64-linux`, passed to modules as
`pkgs`.

## How it works

KeeneticOS mounts the partition at `/opt` and, with `opkg chroot` enabled,
changes the root to it before running `/opt/etc/initrc`. The image therefore is
a root file system: `/nix`, `/etc`, `/var`, with `/bin` pointing into the system
profile. `initrc` runs the activation script of the current generation (links
`/etc`, prepares `/var/run` on the router's tmpfs) and then brings the s6
supervision tree in line with the configuration.

Things KeeneticOS insists on, found by reading its OPKG component and confirmed
on hardware:

- The interpreter in the first line of `initrc` is looked up by KeeneticOS
  itself, before the chroot. It has to be a regular executable file under
  `/opt`, not a symlink into `/nix`. The generated `initrc` points at a copy of
  the shell in the store through its `/opt/nix/store/...` path.
- `/opt/opt` has to be a symlink to `.`. A directory there breaks start-up.
- `/tmp` inside the environment is the router's own `/tmp`. `/tmp/run` belongs
  to KeeneticOS, runtime state of this project goes to `/tmp/nix-run`.
- Scripts get `LD_LIBRARY_PATH` pointing into `/opt`; it is unset before
  anything from the store runs.

## Limitations

- The stock kernel is Linux 4.9 without cgroups, seccomp, user, PID and network
  namespaces, overlayfs or FUSE. There are no containers and no sandboxing, and
  software that needs newer kernel interfaces will not run.
- Nix on the router is there to receive closures. Building on the router is not
  a goal: `sandbox` and `filter-syscalls` are off.
- Firewall and routing belong to KeeneticOS, which rebuilds its rules whenever
  it likes. No module here touches them; rules of your own go into an
  `ndm.hooks.netfilter` script so that they are put back after every rebuild.
- A command passed directly to `ssh host command` does not read `/etc/profile`,
  so it sees UTC and none of `environment.variables`.

## Emulator

`nix run .#emulator -- image.ext4` boots an image the way the router does, in
QEMU: two Cortex-A53 cores, 512 MB of RAM, the image as a USB drive, the stock
KeeneticOS root file system and a reimplementation of the OPKG part of its
system manager. `--ssh-port 2222` forwards SSH to the guest, so `deploy` can be
tested against it.

- `.#emulator` builds a kernel from Keenetic's published 4.9 source tree with
  the configuration of the KN-1012. The first build compiles a cross toolchain
  and the kernel.
- `.#emulator-generic` uses the aarch64 kernel from nixpkgs. Fast to get, but it
  does not have the limits of the real kernel.

The emulator downloads the KeeneticOS firmware image from the vendor's server at
build time. It does not emulate Wi-Fi, the switch or the rest of KeeneticOS.

`nix flake check` builds the minimal image, boots it in the emulator, logs in
over SSH, deploys a second generation and runs a hook.

## License

MIT, see [LICENSE](LICENSE).
