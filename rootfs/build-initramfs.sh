#!/usr/bin/env bash
# Builds a static busybox and packs it into rootfs/initramfs.cpio.gz
# (this is the entire guest userspace: ~1 MB, no package manager).
#
# Cross-compiles for aarch64 automatically when run on another host arch.
set -euo pipefail

BUSYBOX_VERSION="${BUSYBOX_VERSION:-1.36.1}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="${ROOT}/rootfs/build"
OUT="${ROOT}/rootfs/initramfs.cpio.gz"

# Cross toolchain when the build host is not aarch64
if [ "$(uname -m)" = "aarch64" ] || [ "$(uname -m)" = "arm64" ]; then
  CROSS=""
else
  CROSS="${CROSS_COMPILE:-aarch64-linux-gnu-}"
  command -v "${CROSS}gcc" >/dev/null || {
    echo "need an aarch64 cross compiler (e.g. 'apt install gcc-aarch64-linux-gnu')" >&2
    exit 1
  }
fi

rm -rf "$BUILD"
mkdir -p "$BUILD"

# ---- 1. build static busybox ----
cd "$BUILD"
curl -fL --retry 3 -o "busybox-${BUSYBOX_VERSION}.tar.bz2" \
  "https://busybox.net/downloads/busybox-${BUSYBOX_VERSION}.tar.bz2"
tar xf "busybox-${BUSYBOX_VERSION}.tar.bz2"
cd "busybox-${BUSYBOX_VERSION}"

make CROSS_COMPILE="$CROSS" defconfig
sed -i 's/^# CONFIG_STATIC is not set/CONFIG_STATIC=y/' .config
sed -i 's/^CONFIG_DEBUG=y/# CONFIG_DEBUG is not set/' .config
# busybox 1.36.1 'tc' applet does not compile against modern kernel
# headers (struct tc_cbq_* removed) — drop it, an appliance doesn't need it
sed -i 's/^CONFIG_TC=y/# CONFIG_TC is not set/' .config
# (subshell: `yes` takes a harmless SIGPIPE when oldconfig finishes,
#  which would fail the script under `set -o pipefail`)
( set +o pipefail; yes '' | make CROSS_COMPILE="$CROSS" oldconfig )
make CROSS_COMPILE="$CROSS" -j"$(nproc)"
[ -x busybox ]

# ---- 2. assemble the root tree ----
IR="$BUILD/initramfs"
rm -rf "$IR"
mkdir -p "$IR"/bin "$IR"/sbin "$IR"/usr/bin "$IR"/usr/sbin \
         "$IR"/etc/init.d "$IR"/proc "$IR"/sys "$IR"/dev \
         "$IR"/run "$IR"/root "$IR"/tmp "$IR"/mnt/host
chmod 1777 "$IR/tmp"

cp busybox "$IR/bin/busybox"
# Enumerate applets: the just-built busybox is an aarch64 binary and cannot
# run on an x86_64 build host (e.g. the GitHub runner), so fall back to
# parsing the applet table the build generated.
if ./busybox --list >/dev/null 2>&1; then
  applets="$(./busybox --list)"
else
  applets="$(awk '/applet_names/{flag=1} flag{print} flag&&/;/{exit}' \
    include/applet_tables.h | grep -oE '"[^"]*"' | tr -d '"' | grep -vxF '\0')"
fi
[ -n "$applets" ] || { echo "failed to enumerate busybox applets" >&2; exit 1; }
for app in $applets; do
  ln -s busybox "$IR/bin/$app"
done

cp "$ROOT/rootfs/init"          "$IR/init"
cp "$ROOT/rootfs/inittab"       "$IR/etc/inittab"
cp "$ROOT/rootfs/rcS"           "$IR/etc/init.d/rcS"
cp "$ROOT/rootfs/udhcpc.script" "$IR/etc/udhcpc.script"
chmod 0755 "$IR/init" "$IR/etc/init.d/rcS" "$IR/etc/udhcpc.script"

echo 'root:x:0:0:root:/root:/bin/sh' > "$IR/etc/passwd"
echo 'root:x:0:'                    > "$IR/etc/group"
echo 'tinyvm'                        > "$IR/etc/hostname"
echo 'nameserver 10.0.2.3'           > "$IR/etc/resolv.conf"   # QEMU slirp DNS

# ---- 3. pack ----
(cd "$IR" && find . | cpio -o -H newc -R root:root 2>/dev/null) | gzip -9 > "$OUT"
ls -lh "$OUT"
