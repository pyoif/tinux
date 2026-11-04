#!/usr/bin/env bash
# check-fragment.sh <fragment> <final-.config>
#
# kconfig silently drops any option whose dependencies are unmet.
# This turns that silent drop into a loud CI failure *before* the
# 5-minute compile, so you can never build a kernel that is missing
# its serial console or balloon without knowing.
#
# Always invoke as:   bash scripts/check-fragment.sh <fragment> <.config>
# (calling it via bash means the git exec bit can never cause exit 126)
set -euo pipefail

fragment="$1"
config="$2"
[ -r "$fragment" ] && [ -r "$config" ] || {
    echo "usage: bash $0 <fragment> <.config>" >&2
    exit 2
}

status=0

# 1) everything the fragment requests (=y or =value) must be in .config
while IFS= read -r line; do
    if ! grep -q "^${line}$" "$config"; then
        echo "MISSING   ${line}" >&2
        echo "          -> a dependency is not satisfied; check its 'depends on'" >&2
        status=1
    fi
done < <(grep -E '^CONFIG_[A-Za-z0-9_]+=' "$fragment")

# 2) everything the fragment wants OFF must stay off
while IFS= read -r line; do
    sym="$(printf '%s\n' "$line" | sed -E 's/^# (CONFIG_[A-Za-z0-9_]+) is not set$/\1/')"
    if grep -q "^${sym}=" "$config"; then
        echo "NOT-OFF   ${sym}  (fragment asked for it to be unset)" >&2
        status=1
    fi
done < <(grep -E '^# CONFIG_[A-Za-z0-9_]+ is not set$' "$fragment" || true)

# 3) hard rule: page poisoning breaks free page reporting
if grep -q '^CONFIG_PAGE_POISONING=y' "$config"; then
    echo "FORBIDDEN CONFIG_PAGE_POISONING=y — QEMU skips pages the guest" >&2
    echo "          poisons, so free page reporting would reclaim nothing." >&2
    status=1
fi

if [ "$status" -ne 0 ]; then
    echo "fragment check FAILED" >&2
    exit 1
fi
echo "fragment OK — every requested option is present in $config"
