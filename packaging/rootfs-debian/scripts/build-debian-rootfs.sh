#!/usr/bin/env bash
# Builds a Debian 13 (trixie) ARM64 bbport rootfs.
#
#   BLOODBORNE_ROOTFS_VERSION=r1 \
#   BBPORT_RUNTIME_TARBALL=dist/Bloodborne-bbport-runtime-aarch64.tar.gz \
#     bash packaging/rootfs-debian/scripts/build-debian-rootfs.sh
#
# Pipeline:
#   1. debootstrap a trixie minbase into the stage
#   2. install the explicit runtime dependency set
#   3. unpack the driverless bbport runtime into /opt/bbport
#   4. apply the launcher overlay
#   5. trim, verify, write the manifest, pack
#
# Runs where debootstrap is available: the CI runner (root, chroot) or a proot-distro
# Debian container (proot fallback, see common.sh). Unlike the DroidDeck path it needs no
# third-party linuxfs catalog.
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
package_root="$(cd -- "$script_dir/.." && pwd -P)"
repo_root="$(cd -- "$package_root/../.." && pwd -P)"
source "$script_dir/common.sh"

work="${WORK_DIR:-$repo_root/.work/rootfs-debian}"
dist="${DIST_DIR:-$repo_root/dist}"
version="${BLOODBORNE_ROOTFS_VERSION:-r1}"
stage="$work/rootfs"
suite="${BB_DEBIAN_SUITE:-trixie}"
arch=$(uname -m)

runtime_tar="${BBPORT_RUNTIME_TARBALL:-$repo_root/dist/Bloodborne-bbport-runtime-$arch.tar.gz}"
if [[ ! -f $runtime_tar ]]; then
    echo "Runtime tar not found: $runtime_tar" >&2
    echo "Build it first: bash build.sh && bash packaging/runtime-tar.sh" >&2
    exit 2
fi

mkdir -p "$work" "$dist"

if [[ -e $stage ]]; then
    # debootstrap leaves root-owned files; a plain rm fails without the write bit.
    chmod -R u+w "$stage" 2>/dev/null || true
    rm -rf "$stage"
fi

echo "== debian rootfs: base ($suite)"
# debootstrap-base.sh writes BASE_* assignments to stdout (see its contract).
# We use eval rather than sourcing a file: the previous version wrote a
# base-debian.env that the GHA runner's overlay filesystem refused to open
# with ENAMETOOLONG after debootstrap finished.
eval "$("$script_dir/debootstrap-base.sh" "$stage")"
echo "   base version: $BASE_VERSION"

echo "== debian rootfs: runtime dependencies"
"$script_dir/add-debian-extras.sh" "$stage"

echo "== debian rootfs: bbport runtime"
"$script_dir/install-bbport.sh" "$stage" "$runtime_tar"

if [[ -d $package_root/overlay/rootfs ]]; then
    echo "== debian rootfs: overlay"
    cp -a "$package_root/overlay/rootfs"/. "$stage"/
    while IFS= read -r f; do
        [[ -f $stage/$f ]] && chmod 755 "$stage/$f"
    done < <(cd "$package_root/overlay/rootfs" && find . -type f -perm -u+x -printf '%P\n' 2>/dev/null)
fi

echo "== debian rootfs: trim"
"$script_dir/trim-rootfs.sh" "$stage"

echo "== debian rootfs: guest home"
# The game (shadPS4 cache) and libs use non-recursive std::filesystem::create_directory on
# $HOME/.local/share/...; the parent must exist. root does not help. Ship the XDG dirs.
mkdir -p "$stage/root/.local/share" "$stage/root/.config" "$stage/root/.cache"

echo "== debian rootfs: verify"
BB_DEBIAN_SUITE="$suite" "$script_dir/verify-rootfs.sh" "$stage"

archive="$dist/bloodborne-debian-rootfs-$arch-$version.tar.zst"
json="$dist/bloodborne-debian-rootfs-$arch-$version.json"

echo "== debian rootfs: pack"
bb_tar_create_zst "$archive" "$stage"

echo "== debian rootfs: manifest"
BBPORT_RUNTIME_TARBALL="$runtime_tar" BB_DEBIAN_MIRROR="${BB_DEBIAN_MIRROR:-http://deb.debian.org/debian}" \
    "$script_dir/make-manifest.sh" "$archive" "$version" "$BASE_VERSION" "$json"

echo
ls -lh "$archive" "$json"