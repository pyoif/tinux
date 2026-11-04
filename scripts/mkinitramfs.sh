#!/usr/bin/env bash
# mkinitramfs.sh <aarch64-static-busybox> <out.cpio.gz>
#
# Packs the tiny userland (busybox + /init) into a gzip'd newc cpio.
# Designed for GitHub Actions (passwordless sudo for mknod); if mknod
# is impossible it just warns — /init recovers its stdio from devtmpfs
# anyway.
set -euo pipefail

busybox="$1"
out="$2"
here="$(cd "$(dirname "$0")" && pwd)"

[ -x "$busybox" ] || { echo "usage: $0 <busybox-binary> <out.cpio.gz>" >&2; exit 2; }

root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT

mkdir -p "$root"/bin "$root"/sbin "$root"/etc "$root"/proc "$root"/sys \
         "$root"/dev "$root"/root "$root"/tmp "$root"/mnt "$root"/home \
         "$root"/usr/share/udhcpc

install -m 0755 "$busybox"                    "$root/bin/busybox"
install -m 0755 "$here/init"                  "$root/init"
install -m 0755 "$here/udhcpc.script"         "$root/usr/share/udhcpc/default.script"

echo 'root:x:0:0:root:/root:/bin/sh' > "$root/etc/passwd"
echo 'root:x:0:'                     > "$root/etc/group"
printf 'nameserver 10.0.2.3\n'       > "$root/etc/resolv.conf"   # QEMU slirp DNS
echo 'tiny'                          > "$root/etc/hostname"

# the kernel opens /dev/console before running /init — provide it
if [ ! -e "$root/dev/console" ]; then
    mknod -m 600 "$root/dev/console" c 5 1 2>/dev/null \
      || sudo -n mknod -m 600 "$root/dev/console" c 5 1 2>/dev/null \
      || echo "WARN: could not create /dev/console (init recovers via devtmpfs)" >&2
fi

mkdir -p "$(dirname "$out")"
( cd "$root" && find . | cpio -o -H newc -R 0:0 2>/dev/null | gzip -9 ) > "$out"

echo "wrote $out ($(du -h "$out" | cut -f1))"
