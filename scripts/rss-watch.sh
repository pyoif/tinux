#!/usr/bin/env bash
# Watch QEMU's host-side RSS to see free page reporting reclaim memory:
# run something memory-hungry in the guest, exit it, and watch the numbers
# drop within a few seconds without any manual ballooning.
#
#   scripts/rss-watch.sh "$(pgrep -f qemu-system-aarch64 | head -1)" [interval-seconds]
set -euo pipefail

pid="${1:?usage: rss-watch.sh <qemu-pid> [interval]}"
interval="${2:-5}"

while kill -0 "$pid" 2>/dev/null; do
  awk '/^(VmRSS|VmHWM|VmSize)/{printf "%-8s %8.1f MiB\n",$1,$2/1024}' \
    "/proc/$pid/status" 2>/dev/null || exit 0
  echo "----"
  sleep "$interval"
done
