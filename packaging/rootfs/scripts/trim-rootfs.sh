#!/usr/bin/env bash
set -euo pipefail

if (( $# != 1 )); then
    echo "usage: trim-rootfs.sh <staged-rootfs>" >&2
    exit 64
fi

stage="$1"

echo "== trim: conservative cleanup"
rm -rf "$stage/var/cache/pacman/pkg" \
       "$stage/var/lib/pacman/sync" \
       "$stage/tmp"/* \
       "$stage/var/tmp"/* 2>/dev/null || true

find "$stage/usr/share" -maxdepth 2 \( -name man -o -name info -o -name doc \) -type d -prune -exec rm -rf {} + 2>/dev/null || true
