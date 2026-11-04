#!/usr/bin/env bash
# Verifies every 'CONFIG_X=y' line of the fragment survived into the final
# .config. Kconfig silently drops options whose dependencies are unmet, so
# this turns an invisible config regression into a loud CI failure.
#
# usage: check-fragment.sh <final .config> <fragment>
set -euo pipefail

final="${1:?usage: check-fragment.sh <final .config> <fragment>}"
fragment="${2:?usage: check-fragment.sh <final .config> <fragment>}"

dropped=0
while IFS= read -r want; do
  case "$want" in ''|\#*) continue ;; esac
  if ! grep -qxF "$want" "$final"; then
    echo "DROPPED: $want"
    dropped=1
  fi
done < "$fragment"

if [ "$dropped" -ne 0 ]; then
  echo "Fragment options were dropped (missing dependencies)." >&2
  echo "Fix kernel/virt-tiny.config or add the missing dependency." >&2
  exit 1
fi
echo "check-fragment: all fragment options present in final .config"
