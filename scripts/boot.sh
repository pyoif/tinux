#!/usr/bin/env bash
# Boot the appliance on Android (Termux) — or any Linux box with
# qemu-system-aarch64.
#
#   pkg install qemu-system-aarch64     # on Termux
#   ./scripts/boot.sh [shared-dir]
#
# Expects Image.gz + initramfs.cpio.gz in ./vm/ (unzip the CI artifact
# there), or override with the KERNEL / INITRD environment variables.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHARE="${1:-$HOME/vm-share}"
KERNEL="${KERNEL:-$HERE/../vm/Image.gz}"
INITRD="${INITRD:-$HERE/../vm/initramfs.cpio.gz}"

for f in "$KERNEL" "$INITRD"; do
  [ -f "$f" ] || {
    echo "missing $f" >&2
    echo "download the 'qemu-linux-tiny' artifact from Actions and unzip it into ./vm/" >&2
    exit 1
  }
done
mkdir -p "$SHARE"

ACCEL=(-cpu max)
if [ -w /dev/kvm ]; then
  ACCEL=(-enable-kvm -cpu host)
  echo ">> /dev/kvm found — using KVM"
fi

exec qemu-system-aarch64 \
  -machine virt "${ACCEL[@]}" -smp 2 -m 256M \
  -kernel "$KERNEL" \
  -initrd "$INITRD" \
  -append "console=ttyAMA0" \
  -device virtio-net-device,netdev=n0 \
  -netdev user,id=n0 \
  -fsdev local,id=fs0,path="$SHARE",security_model=none \
  -device virtio-9p-device,fsdev=fs0,mount_tag=host \
  -device virtio-balloon-device,free-page-reporting=on \
  -no-reboot \
  -nographic
