# tiny-linux — a pocket Linux that gives memory back to Android

A ~2–3 MB aarch64 kernel (`virt-tiny` variant) or ~3–4 MB with the distro
layer (`distro` variant), plus a ~1 MB busybox initramfs, built
entirely in GitHub Actions and booted with QEMU from Termux. The guest runs
with a virtio-balloon that has **free page reporting** enabled, so whenever
the guest frees memory, QEMU hands those pages straight back to Android — no
manual ballooning, no phantom RSS, no angry lmkd.

## Quick start

1. Push this repo to GitHub (branch `main` or `master`, both trigger CI).
   The `kernel` workflow runs in ~5–8 minutes and **boots the kernel in QEMU
   on the runner** before you download anything.
2. Grab the output: Actions → latest run → artifacts `qemu-linux-virt-tiny`
   and `qemu-linux-distro`, or push a tag like `v0.1` and get a proper
   GitHub Release with all files attached individually (no zip).
3. On the phone, in Termux:

   ```sh
   pkg install qemu-system-aarch64 unzip
   unzip qemu-linux-distro.zip   # or qemu-linux-virt-tiny.zip
   sh run.sh
   ```

You land in a root shell on the serial console (`ttyAMA0`).

## Repo layout

```
.
├── .github/workflows/kernel.yml  # matrix build + smoke boot + artifact/release
├── kernel/virt-tiny.config       # base kernel fragment (tinyconfig + appliance)
├── kernel/distro.config          # systemd/glibc layer merged on top (2nd variant)
├── kernel/containers.config      # docker/podman layer merged on top (3rd variant)
├── scripts/
│   ├── check-fragment.sh         # fails CI if kconfig drops a requested option
│   ├── mkinitramfs.sh            # packs busybox + /init into rootfs.cpio.gz
│   ├── init                      # guest /init (PID 1)
│   └── udhcpc.script             # applies the DHCP lease QEMU slirp hands out
├── run.sh                        # Termux launcher (balloon + free-page-reporting on)
└── README.md
```

## What CI does

CI is a **build matrix** with three kernel variants (all smoke-booted):

| variant      | fragments                                                    | boots                     |
|--------------|--------------------------------------------------------------|---------------------------|
| `virt-tiny`  | `virt-tiny.config`                                           | busybox appliance, Alpine |
| `distro`     | `virt-tiny.config` + `distro.config`                         | Debian/Ubuntu (systemd)   |
| `containers` | `virt-tiny.config` + `distro.config` + `containers.config`   | docker/podman inside      |

1. `make ARCH=arm64 tinyconfig`, then merges the variant's fragments on top.
2. `scripts/check-fragment.sh` fails the build if kconfig **silently dropped**
   any requested option (unmet or hidden dependency) — this catches a missing
   console or balloon *before* the compile.
3. Builds `Image-<variant>.gz` with the LLVM toolchain (`clang` + `ld.lld` +
   the `llvm` binutils: `llvm-nm`, `llvm-objcopy`, `llvm-readelf`, ...) — no
   external cross toolchain needed for the kernel.
4. busybox is kernel-config independent, so a separate `busybox` job builds
   the static aarch64 binary **once** and packs `rootfs.cpio.gz`; each kernel
   variant downloads it for its smoke boot.
5. **Smoke test**: boots the result in QEMU right on the runner — balloon
   attached — and greps the guest banner out of the serial log.
6. Uploads one artifact per variant: `Image-<variant>.gz`, `rootfs.cpio.gz`,
   `run.sh` and `boot-<variant>.log`.
7. On a `v*` tag, a `release` job downloads all variant artifacts and attaches
   **every file individually** to the GitHub Release (no zip archives).

## Memory behavior (the whole point)

- `-m 256M` is a **cap**, not a reservation. QEMU's RSS only grows to what the
  guest actually touches (its high-water mark) and is fully returned when the
  process exits.
- With `free-page-reporting=on`, pages the guest kernel frees back to its buddy
  allocator are reported through the balloon and QEMU `madvise(MADV_DONTNEED)`s
  them — Android RSS drops **automatically**, within a second or so.
- **Not covered**: guest page cache. Only genuinely free buddy pages get
  reported; files cached in the guest stay in RSS until the guest drops them.
- Manual ballooning still works: `Ctrl-A c` → monitor → `balloon 128M`
  (HMP numbers are megabytes; QMP numbers are bytes).
- Want a bigger guest? Raise `-m` in `run.sh` (e.g. `-m 1G`) — untouched
  memory never leaves Android anyway.

Verify from another Termux session:

```sh
grep VmRSS /proc/$(pidof qemu-system-aarch64)/status
```

then inside the guest:

```sh
dd if=/dev/zero of=/tmp/junk bs=1M count=100; rm /tmp/junk
```

Re-check `VmRSS` — it climbs ~100 MB and falls back on its own after `rm`.

## Optional: mount your Termux home in the guest

Add to `run.sh` before `-nographic`:

```sh
    -fsdev local,id=share,path="$HOME",security_model=none \
    -device virtio-9p-device,fsdev=share,mount_tag=host \
```

then in the guest:

```sh
mkdir -p /mnt/host && mount -t 9p -o trans=virtio host /mnt/host
```

## Running real distro rootfs (Alpine, Debian, ...)

**Alpine (musl/busybox/openrc): boots on the base kernel already** — it needs
nothing beyond `virt-tiny.config` (BINFMT_ELF, ext4, virtio-blk/net, devtmpfs,
PACKET for udhcpc are all in).

**Debian/Ubuntu (glibc/systemd): needs the `distro` variant** (`Image-distro.gz`,
built from `kernel/distro.config`) — the
tinyconfig base switches off most of systemd's required list (CGROUPS,
INOTIFY_USER, SIGNALFD, TIMERFD, EVENTFD, FHANDLE, FANOTIFY, SECCOMP,
SYSVIPC...). The layer also adds the cheap "recommended" set (MEMCG,
cgroup CPU controller, PSI, namespaces), RTC + virtio-rng (correct clock and
entropy — TLS/apk need them), and squashfs/vfat/overlayfs. Both fragments are
verified against the real linux-6.12.y tree by `check-fragment.sh` in CI.

To boot a distro instead of the busybox appliance, swap the `-initrd` boot for
a disk (build the image **in CI or on a PC** — Termux can't loop-mount):

```sh
# e.g. in a CI step: alpine-minirootfs → ext4 image
truncate -s 512M alpine.img
mkfs.ext4 alpine.img
sudo mount -o loop alpine.img /mnt
sudo tar -xzf alpine-minirootfs-*-aarch64.tar.gz -C /mnt
sudo umount /mnt
```

```sh
# then on the phone:
qemu-system-aarch64 -M virt -cpu max -smp 2 -m 512M \
  -kernel Image.gz -append "console=ttyAMA0 root=/dev/vda rw" \
  -drive if=none,file=alpine.img,format=raw,id=hd0 \
  -device virtio-blk-device,drive=hd0 \
  -device virtio-balloon-device,free-page-reporting=on \
  -device virtio-rng-device \
  -device virtio-net-device,netdev=n0 -netdev user,id=n0 \
  -nographic
```

For Debian, unpack a Debian arm64 rootfs (e.g. a cloud image converted with
`qemu-img convert`, or a `debootstrap`/`mmdebstrap` chroot, or a `docker
export`ed `debian:bookworm` rootfs) into the image the same way, and give it
`-m 1G` — systemd wants more room than busybox.

### What still won't work

- **No loadable modules** — everything needed is built in (fine on QEMU virt,
  where the device set is fixed); `modprobe` inside the distro will just fail
  for things the kernel doesn't carry.
- **No containers on the base variants** — docker/podman need BPF, veth,
  bridge and netfilter on top of this config. That's exactly what the
  **`containers` variant** (`Image-containers.gz`) adds; see `kernel/containers.config`.
- **Filesystems**: ext4, squashfs, vfat, 9p, tmpfs, overlayfs — **no** btrfs,
  xfs, f2fs (each is one fragment line + a rebuild away).
- **No** sound, USB, or 32-bit (armhf) binary compat.

## Troubleshooting

- **`Permission denied` / exit 126 on a script** — the file was committed
  without its executable bit (GitHub web editor / Windows). Fix it for good:

  ```sh
  git update-index --chmod=+x scripts/check-fragment.sh
  git commit -m "scripts: fix exec bit" && git push
  ```

  This repo also invokes every script as `bash scripts/...`, so the exec bit
  can never break CI again.
- **`llvm-readelf: not found` / `llvm-nm` / `llvm-objcopy` (exit 127 in
  `vdso_prepare`)** — `LLVM=1` doesn't just use clang as the compiler; per
  the kernel's own `Documentation/kbuild/llvm.rst`, it expands to the full
  list `CC=clang LD=ld.lld AR=llvm-ar NM=llvm-nm STRIP=llvm-strip
  OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump READELF=llvm-readelf ...`.
  Installing `clang` + `lld` is therefore *not* enough — the vdso build
  dies almost immediately. The `llvm` package ships the whole `llvm-*`
  suite (its postinst creates the unversioned names like `llvm-nm` via
  update-alternatives). Fix: add `llvm` to the `apt-get install` list in
  `.github/workflows/kernel.yml`.
  Alternative if you ever want it: drop `LLVM=1` and build with the GCC
  cross toolchain instead — `make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-`
  (that compiler is already installed for busybox). Slightly bigger kernel.
- **`MISSING CONFIG_VIRTIO_NET=y`** — two known causes, both verified on
  real linux-6.12.y:
  1. `VIRTIO_NET` lives **inside `if NETDEVICES`** in `drivers/net/Kconfig` —
     an *implicit* dependency that never appears in its own Kconfig block
     (the file even says: *"All the following symbols are dependent on
     NETDEVICES - do not repeat that for each of the symbols"*). `tinyconfig`
     is built on `allnoconfig`, which flips every prompted symbol — including
     `NETDEVICES` — to n. Fix: `CONFIG_NETDEVICES=y`.
  2. Every virtio driver `depends on VIRTIO`, and `VIRTIO` is a *hidden*
     symbol: no prompt, only a transport's `select` can turn it on. On
     `-M virt` the transport is MMIO, so the fragment must contain
     `CONFIG_VIRTIO_MMIO=y`. (`CONFIG_VIRTIO_MENU=y` merely opens the menu —
     it enables nothing. PCI is useless here: `-M virt` exposes devices on
     the MMIO bus.)
- **`MISSING CONFIG_...` (other) from check-fragment** — that option's
  dependency isn't met. Look the symbol up in the kernel's Kconfig **and
  check whether it sits inside an `if <SYMBOL>` block** — the enclosing
  `if` is an implicit dependency that won't show in the symbol's own block.
  Fastest way to see the unmet dependency with values:
  `make ARCH=arm64 LLVM=1 menuconfig`, press `/`, type the symbol name —
  it prints e.g. `Depends on: ... NETDEVICES [=n]`.
- **`MISSING CONFIG_SQUASHFS=y`** — squashfs is sourced inside
  `if MISC_FILESYSTEMS` in `fs/Kconfig`; with the gate off, kconfig writes
  **no line at all** for SQUASHFS (not even a "not set"), so the fragment line
  is silently discarded. Fix: `CONFIG_MISC_FILESYSTEMS=y`.
- **Smoke test failed** — download the artifact
  (`qemu-linux-<variant>`) and read `boot-<variant>.log`
  (the upload runs even on failure).
- **Bumping the kernel** — change the branch in the workflow
  (`linux-6.12.y` → any stable branch). Everything else stays the same.
