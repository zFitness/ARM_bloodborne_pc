#!/usr/bin/env bash
# Trims a staged Debian rootfs: removes package-manager caches and build leftovers.
#
#   trim-rootfs.sh <stage-dir>
#
# Removing the apt lists is the big win — they run to tens of MB and can be regenerated
# by the user with one apt-get update inside the rootfs.
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/common.sh"

stage="${1:-}"
[[ -n $stage ]] || { echo 'usage: trim-rootfs.sh <stage-dir>' >&2; exit 64; }

before=$(bb_dir_size "$stage")
echo "== trim: before $(numfmt --to=iec "$before" 2>/dev/null || echo "$before")"

# chmod first: these paths can hold read-only files, and rm -rf on a read-only file in a
# directory the user owns still works, but a read-only directory needs the write bit.
for path in \
    var/lib/apt/lists \
    var/cache/apt/archives \
    var/cache/debconf \
    var/log/apt \
    var/log/journal \
    tmp
do
    [[ -e $stage/$path ]] || continue
    chmod -R u+w "$stage/$path" 2>/dev/null || true
done

rm -rf \
    "$stage/var/lib/apt/lists"/* \
    "$stage/var/cache/apt/archives"/*.deb \
    "$stage/var/cache/debconf"/*-old \
    "$stage/var/log/apt"/*.log \
    "$stage/tmp"/* 2>/dev/null || true

# Empty dpkg metadata and leftover logs add up.
: > "$stage/var/log/dpkg.log" 2>/dev/null || true
rm -f "$stage/var/log/alternatives.log" 2>/dev/null || true

after=$(bb_dir_size "$stage")
echo "== trim: after  $(numfmt --to=iec "$after" 2>/dev/null || echo "$after")"
echo "== trim: freed  $(numfmt --to=iec "$((before - after))" 2>/dev/null || echo "$((before - after))")"