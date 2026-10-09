#!/usr/bin/env bash
set -euo pipefail

if (( $# != 1 )); then
    echo "usage: verify-rootfs.sh <staged-rootfs>" >&2
    exit 64
fi

stage="$1"
missing=0

check() {
    local path="$1"
    if [[ ! -e "$stage/$path" ]]; then
        echo "missing: /$path" >&2
        missing=1
    fi
}

check usr/bin/gamescope
check usr/local/bin/bloodborne-launch
check usr/local/share/bloodborne/default-bbport.ini
check usr/local/share/bloodborne/default-env
check usr/local/share/bloodborne/runtime-manifest.json
check opt/bbport/bin/bbport
check opt/bbport/bin/bbport-driver
check opt/bbport/bin/bbport-game
check opt/bbport/share/bbport/run.sh

if (( missing )); then
    exit 3
fi

echo "== verify: rootfs looks usable"
