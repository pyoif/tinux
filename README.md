# tiny-linux — a pocket Linux that gives memory back to Android

A ~2–3 MB aarch64 kernel plus a ~1 MB busybox initramfs, built entirely in
GitHub Actions and booted with QEMU from Termux. The guest runs with a
virtio-balloon that has **free page reporting** enabled, so whenever the guest
frees memory, QEMU hands those pages straight back to Android — no manual
ballooning, no phantom RSS, no angry lmkd.

## Quick start

1. Push this repo to GitHub (branch `main` or `master`, both trigger CI).
   The `kernel` workflow runs in ~5–8 minutes and **boots the kernel in QEMU
   on the runner** before you download anything.
2. Grab the output: Actions → latest run → artifact `qemu-linux-aarch64`,
   or push a tag like `v0.1` and get a proper GitHub Release.
3. On the phone, in Termux:

   ```sh
   pkg install qemu-system-aarch64 unzip
   unzip qemu-linux-aarch64.zip
   sh run.sh
   ```

You land in a root shell on the serial console (`ttyAMA0`).

## Repo layout

```
.
├── .github/workflows/kernel.yml  # build + smoke boot + artifact/release
├── kernel/virt-tiny.config       # the whole kernel config, on top of tinyconfig
├── scripts/
│   ├── check-fragment.sh         # fails CI if kconfig drops a requested option
│   ├── mkinitramfs.sh            # packs busybox + /init into rootfs.cpio.gz
│   ├── init                      # guest /init (PID 1)
│   └── udhcpc.script             # applies the DHCP lease QEMU slirp hands out
├── run.sh                        # Termux launcher (balloon + free-page-reporting on)
└── README.md
```

## What CI does

1. `make ARCH=arm64 tinyconfig`, then merges `kernel/virt-tiny.config` on top.
2. `scripts/check-fragment.sh` fails the build if kconfig **silently dropped**
   any requested option (unmet dependency) — this catches a missing console or
   balloon *before* the compile.
3. Builds `Image.gz` with clang + lld (no external cross toolchain).
4. Cross-compiles static busybox with `gcc-aarch64-linux-gnu`.
5. `scripts/mkinitramfs.sh` packs busybox + `/init` into `rootfs.cpio.gz`.
6. **Smoke test**: boots the result in QEMU right on the runner — balloon
   attached — and greps the guest banner out of the serial log.
7. Uploads `Image.gz`, `rootfs.cpio.gz`, `run.sh` and `boot.log`.

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

## Troubleshooting

- **`Permission denied` / exit 126 on a script** — the file was committed
  without its executable bit (GitHub web editor / Windows). Fix it for good:

  ```sh
  git update-index --chmod=+x scripts/check-fragment.sh
  git commit -m "scripts: fix exec bit" && git push
  ```

  This repo also invokes every script as `bash scripts/...`, so the exec bit
  can never break CI again.
- **`MISSING CONFIG_...` from check-fragment** — that option's dependency
  isn't met. Look the symbol up in the kernel's Kconfig and add whatever it
  `depends on` to the fragment.
- **Smoke test failed** — download the artifact and read `boot.log`
  (the upload runs even on failure).
- **Bumping the kernel** — change the branch in the workflow
  (`linux-6.12.y` → any stable branch). Everything else stays the same.
