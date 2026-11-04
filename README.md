# qemu-linux-tiny

A tiny aarch64 Linux appliance for terminal emulators on Android
(but it boots anywhere `qemu-system-aarch64` exists):

- **Image.gz ≈ 2.2 MB** — Linux 6.12 built from `tinyconfig` + a small
  virtio fragment, cross-compiled in GitHub Actions
- **initramfs ≈ 1.2 MB** — static busybox, ~400 applets, boots to a root
  shell in a few seconds
- QEMU's `-M virt` + `-nographic`: the serial console **is** your terminal
- **free page reporting** — when the guest frees memory, QEMU hands the
  pages back to the host within seconds, automatically

Everything here was built and boot-tested end to end:
the guest booted, got an IP over QEMU's user-mode NAT, mounted the host
share over 9p, and freeing 100 MB inside the guest shrank the QEMU
process by ~96 MB on the host — no ballooning commands involved.

## Quick start

1. Push this repo to GitHub → **Actions** → run the **kernel** workflow →
   download the `qemu-linux-tiny` artifact (`Image.gz`, `initramfs.cpio.gz`,
   `.config`). Artifacts expire after 90 days — push a `v*` tag to also get
   a Release with the files attached.
2. On the phone (Termux):

   ```sh
   pkg install qemu-system-aarch64 git
   git clone https://github.com/you/qemu-linux-tiny && cd qemu-linux-tiny
   mkdir vm && unzip qemu-linux-tiny.zip -d vm   # the artifact
   ./scripts/boot.sh                              # shares $HOME/vm-share
   ```

3. Inside the guest:

   ```sh
   ls /mnt/host      # the folder shared from Android (9p)
   poweroff          # clean exit (PSCI SYSTEM_OFF, QEMU just stops)
   ```

## Repo layout

```
.github/workflows/kernel.yml   CI: build + boot-test + artifact + release
kernel/virt-tiny.config        kconfig fragment merged over tinyconfig
scripts/check-fragment.sh       CI guard: fails if an option got dropped
scripts/boot.sh                 QEMU launcher for Termux / desktop
scripts/rss-watch.sh            watch qemu RSS to see reclaim happen
rootfs/build-initramfs.sh       builds static busybox, packs initramfs
rootfs/init                    guest /init (PID 1 -> busybox init)
rootfs/inittab                 console shell respawn setup
rootfs/rcS                     mounts, DHCP, 9p, prints BOOT-OK
rootfs/udhcpc.script           tiny DHCP event handler
```

## What CI does

1. Shallow-clones a stable branch (`linux-6.12.y` — override via the
   workflow_dispatch input; bump to the current LTS when it goes EOL).
2. `tinyconfig` + `kernel/virt-tiny.config` → `olddefconfig`, then
   `check-fragment.sh` fails the build if any requested option was silently
   dropped because of a missing Kconfig dependency.
3. Builds `Image.gz` with clang (LLVM=1).
4. Cross-builds static busybox and packs the initramfs.
5. **Boots the result in QEMU on the runner** and requires the guest to
   print `BOOT-OK`, `NET-OK`, `9P-OK`, and no panic. A broken kernel
   can never produce a green check.

## Memory: automatic reclaim

`boot.sh` attaches `-device virtio-balloon-device,free-page-reporting=on`
and the kernel builds in `CONFIG_VIRTIO_BALLOON=y` + `CONFIG_PAGE_REPORTING=y`.
The guest kernel periodically walks its free-page lists and hands free pages
to QEMU, which `madvise(MADV_DONTNEED)`s them — the host OS reclaims them
from the QEMU process immediately. There is nothing to drive: no balloon
targets, no monitor commands, no OOM risk (pages only leave once the guest
has already freed them).

Measured on QEMU 10 / kernel 6.12 (256M guest, RSS of the QEMU process):

```
idle                    ~112 MiB
dd 100 MB in guest     ~216 MiB
after rm (seconds)     ~122 MiB   <- -96 MiB, automatic
```

Watch it live with `scripts/rss-watch.sh`. Two caveats:

- Only *free* pages are returned; guest page cache is not "free", so a
  cache-heavy workload holds its share. Manual ballooning (QEMU monitor,
  `balloon 128M` — MB in HMP, bytes in QMP) is still there if you ever
  need to squeeze cache too.
- Do not enable `CONFIG_PAGE_POISONING` in the guest — QEMU skips
  reported pages when the guest poisons freed pages.

## Terminal emulator notes

- With `-nographic`, the monitor is muxed onto the same stdio:
  **Ctrl-A c** switches console ↔ monitor, **Ctrl-A x** quits QEMU,
  and guest bash's Ctrl-A (beginning-of-line) needs **Ctrl-A a** to pass
  through. Your app must forward these raw.
- Ctrl-A b sends a break; boot.sh passes `-no-reboot` so a guest `reboot`
  exits QEMU instead of restarting.
- If the device exposes `/dev/kvm`, boot.sh automatically switches to
  `-enable-kvm -cpu host` (near-native). Most phones don't.
- 128–256 MB of guest RAM is plenty; keep `-m` modest — Android's lmkd
  targets big processes under memory pressure.

## Tuning

- Size: add/remove options in `kernel/virt-tiny.config`. Keep
  `check-fragment.sh` green — it is the difference between "config I
  believe works" and "config that works". The CI-built `.config` is inside
  the artifact for reference.
- A real distro instead of busybox: unpack an Alpine minirootfs into a
  directory, or keep this kernel and switch the rootfs to an ext4 image
  (`-drive if=none,...,id=hd0 -device virtio-blk-device,drive=hd0` +
  `root=/dev/vda`). Kernel already has EXT4 + virtio-blk built in.
- CPU/RAM: `-smp` / `-m` in `scripts/boot.sh`.
- The initramfs is RAM-only; changes inside the VM do not persist across
  boots. Use `/mnt/host` (9p share) for anything you want to keep.

## Troubleshooting

- `qemu-system-aarch64: failed to find romfile "efi-virtio.rom"` — you are
  using a QEMU without its data files and no explicit network device
  (QEMU tries to add a default NIC with an option ROM). Reinstall QEMU
  properly, or pass `-nic none` if you want no network.
- Nothing appears on the serial console — did the artifact unzip into
  `./vm/`? Check the paths `boot.sh` prints on startup.
- `balloon` units: HMP `balloon 128` means 128 MB, QMP's `balloon` takes
  bytes — always type `balloon 128M` in the HMP monitor.
- Kernel branch EOL — see https://endoflife.date/linux, change the branch
  in the workflow input, and let `check-fragment.sh` + the boot smoke
  test catch any config regressions.
