#!/data/data/com.termux/files/usr/bin/bash
# run.sh — boot the appliance from Termux (any sh works: `sh run.sh`).
#
# prerequisites:  pkg install qemu-system-aarch64
# files needed:   Image.gz and rootfs.cpio.gz (from the CI artifact or
#                 release), sitting next to this script
#
# keys inside QEMU:  Ctrl-A x = quit     Ctrl-A c = monitor
set -eu

DIR="$(cd "$(dirname "$0")" && pwd)"
# release artifacts are per-variant: Image-virt-tiny.gz / Image-distro.gz
KERNEL="$DIR/Image-distro.gz"
[ -f "$KERNEL" ] || KERNEL="$DIR/Image-virt-tiny.gz"
[ -f "$KERNEL" ] || KERNEL="$DIR/Image.gz"
INITRD="$DIR/rootfs.cpio.gz"

command -v qemu-system-aarch64 >/dev/null 2>&1 || {
    echo "QEMU missing — run: pkg install qemu-system-aarch64" >&2
    exit 1
}
for f in "$KERNEL" "$INITRD"; do
    [ -f "$f" ] || { echo "missing $f (grab it from the Actions artifact)" >&2; exit 1; }
done

# -m is a cap, not a reservation: untouched memory never leaves Android,
# and the balloon with free-page-reporting hands freed pages straight back.
exec qemu-system-aarch64 \
    -M virt \
    -cpu max \
    -smp 2 \
    -m 256M \
    -kernel "$KERNEL" \
    -initrd "$INITRD" \
    -append "console=ttyAMA0 panic=-1" \
    -device virtio-balloon-device,free-page-reporting=on \
    -device virtio-net-device,netdev=n0 \
    -netdev user,id=n0 \
    -no-reboot \
    -nographic
