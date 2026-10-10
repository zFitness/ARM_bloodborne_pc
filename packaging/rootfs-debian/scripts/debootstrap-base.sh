#!/usr/bin/env bash
# Generates the Debian base rootfs with debootstrap.
#
#   debootstrap-base.sh <stage-dir>
#
# Runs inside the proot-distro Debian container, or anywhere with root and debootstrap.
#
# Output contract: the absolute path of the env file on stdout. The caller's
# `env_file=$(...)` captures that and sources it for the BASE_* variables. All
# progress logs go to stderr so they do not pollute the captured value.
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
package_root="$(cd -- "$script_dir/.." && pwd -P)"
repo_root="$(cd -- "$package_root/../.." && pwd -P)"
source "$script_dir/common.sh"

stage="${1:-}"
[[ -n $stage ]] || { echo 'usage: debootstrap-base.sh <stage-dir>' >&2; exit 64; }

suite="${BB_DEBIAN_SUITE:-trixie}"
mirror="${BB_DEBIAN_MIRROR:-http://deb.debian.org/debian}"
env_file="$(dirname -- "$stage")/base-debian.env"

if [[ ! $(command -v debootstrap) ]]; then
    echo 'Need debootstrap (Debian: apt install debootstrap debian-archive-keyring).' >&2
    exit 69
fi

if [[ -e $stage ]]; then
    echo "== debian base: reusing existing $stage" >&2
else
    echo "== debian base: debootstrap --variant=minbase $suite ($mirror)" >&2
    mkdir -p "$stage"
    # --variant=minbase trims priority:required packages that the default base pulls in.
    # The extras bbport actually needs are installed by add-debian-extras.sh with an
    # explicit list, so nothing here is implied by debootstrap's defaults.
    debootstrap --arch=arm64 --variant=minbase \
        --include=ca-certificates,apt-utils \
        "$suite" "$stage" "$mirror"
fi

echo "== debian base: verifying layout" >&2
for path in bin/sh etc/apt/sources.list var/lib/dpkg/status etc/debian_version; do
    if [[ ! -e $stage/$path ]]; then
        echo "debootstrap output missing $path; the base is incomplete." >&2
        exit 2
    fi
done

# debootstrap leaves its log behind; it is build noise, not part of the rootfs.
rm -f "$stage/debootstrap.log"

{
    bb_env_assignment BASE_VERSION "$suite"
    bb_env_assignment BASE_URL "$mirror"
    bb_env_assignment BASE_ARCHIVE ""
    bb_env_assignment BASE_CATALOG ""
    bb_env_assignment BASE_SHA256 ""
    bb_env_assignment BASE_SIZE "$(bb_dir_size "$stage")"
} > "$env_file"

# Only the env file path on stdout; everything else went to stderr above.
echo "$env_file"