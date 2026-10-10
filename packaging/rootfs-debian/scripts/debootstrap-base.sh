#!/usr/bin/env bash
# Generates the Debian base rootfs with debootstrap.
#
#   debootstrap-base.sh <stage-dir>
#
# Runs inside the proot-distro Debian container, or anywhere with root and debootstrap.
#
# Output contract: prints KEY=VALUE lines to stdout, one per line, with values
# shell-escaped via printf %q. The caller runs them through `eval` to import the
# variables (BASE_VERSION, BASE_URL). debootstrap's own output is rerouted to
# stderr so it does not pollute the captured value stream. Progress logs from
# this script also go to stderr.
#
# Why not a file: the previous version wrote an env file at
# $(dirname "$stage")/base-debian.env and the caller sourced it. On the
# GitHub Actions runner, the open() of that file failed with ENAMETOOLONG
# (most likely a side effect of `du` walking the freshly-bootstrapped rootfs
# on the overlay filesystem), and bash reported the redirection target as the
# failing path. Stdout-as-value-stream removes the file from the picture.
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
package_root="$(cd -- "$script_dir/.." && pwd -P)"
repo_root="$(cd -- "$package_root/../.." && pwd -P)"
source "$script_dir/common.sh"

stage="${1:-}"
[[ -n $stage ]] || { echo 'usage: debootstrap-base.sh <stage-dir>' >&2; exit 64; }

suite="${BB_DEBIAN_SUITE:-trixie}"
mirror="${BB_DEBIAN_MIRROR:-http://deb.debian.org/debian}"

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
    # Both stdout and stderr from debootstrap go to stderr: the stdout path is the
    # variable stream that the caller evals.
    debootstrap --arch=arm64 --variant=minbase \
        --include=ca-certificates,apt-utils \
        "$suite" "$stage" "$mirror" >&2
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

# Variable stream on stdout. Only BASE_VERSION and BASE_URL are actually consumed
# by the caller; the others are emitted for symmetry and so a future caller can
# inspect provenance without going back to the stage.
bb_env_assignment BASE_VERSION "$suite"
bb_env_assignment BASE_URL "$mirror"
bb_env_assignment BASE_ARCHIVE ""
bb_env_assignment BASE_CATALOG ""
bb_env_assignment BASE_SHA256 ""