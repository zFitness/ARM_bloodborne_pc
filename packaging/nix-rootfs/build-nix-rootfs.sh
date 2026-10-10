#!/usr/bin/env bash
# Builds a self-sufficient aarch64 Nix rootfs for bbport.
#
#   bash packaging/nix-rootfs/build-nix-rootfs.sh
#
# Output: dist/bloodborne-nix-rootfs-aarch64-<version>.tar.zst
#
# Pipeline:
#   1. nix-build packaging/nix-rootfs/nix-rootfs.nix - the derivation emits
#      /opt/bbport, /etc, and /bin symlinks.
#   2. Copy the derivation's $out into a staging directory.
#   3. Copy the runtime closure (nix-store -qR) into staging/nix/store so the
#      bbport binary's RUNPATH (/nix/store/...) resolves at runtime.
#   4. Pack the staging tree as tar.zst.
#
# The output is a self-contained rootfs. Extract it to a directory and enter
# with `proot -r <dir> /opt/bbport/bin/bbport` — no host-system libraries
# required.
set -euo pipefail
# Build the repo root path correctly. This script lives at
# packaging/nix-rootfs/build-nix-rootfs.sh, so two dirname steps are needed to
# get back to the repo root (the parallel packaging/runtime-tar.sh only needs
# one). The previous /.. landed us in packaging/ and out/bb-probe resolved
# under packaging/out/bb-probe, which does not exist.
cd -- "$(dirname -- "$0")/../.."
repo_root="$PWD"

arch=$(uname -m)
case "$arch:$arch" in
    aarch64:aarch64) ;;
    *) echo "self-sufficient Nix rootfs must be built on an aarch64 Linux host/runner" >&2; exit 1 ;;
esac

version="${BLOODBORNE_NIX_ROOTFS_VERSION:-r1}"

missing=()
[[ -x out/bb-probe ]] || missing+=("out/bb-probe")
[[ -x out/bb-gpu-capabilities ]] || missing+=("out/bb-gpu-capabilities")
[[ -f out/gpu/libbbgpu.so ]] || missing+=("out/gpu/libbbgpu.so")
[[ -f out/fex/libbbcpu.so ]] || missing+=("out/fex/libbbcpu.so")
if (( ${#missing[@]} )); then
    printf 'Build first: bash build.sh (missing %s)\n' "${missing[*]}" >&2
    exit 1
fi

if ! command -v nix-build >/dev/null; then
    echo 'Need nix-build (Nix package).' >&2
    exit 1
fi

if ! command -v nix-store >/dev/null; then
    echo 'Need nix-store (Nix package).' >&2
    exit 1
fi

# runtime-tar.sh writes this list from readelf. nix-rootfs reuses it because
# the bbport binaries are identical.
if [[ ! -f packaging/runtime-paths.nix ]]; then
    echo 'packaging/runtime-paths.nix missing; run packaging/runtime-tar.sh once to generate it.' >&2
    exit 1
fi

read -r -a nix_build <<< "${NIX_BUILD:-nix-build}"
include=()
[[ -n ${BB_NIXPKGS:-} ]] && include=(-I "nixpkgs=$BB_NIXPKGS")

work=$(mktemp -d)
cleanup() {
    chmod -R u+w "$work" 2>/dev/null || true
    rm -rf "$work"
}
trap cleanup EXIT
result=$work/result
"${nix_build[@]}" "${include[@]}" packaging/nix-rootfs/nix-rootfs.nix -o "$result" >/dev/null

stage=$work/stage
mkdir -p "$stage/nix/store"
cp -a "$result"/. "$stage"/

# Mirror the nix store closure into the rootfs. /opt/bbport/.../libbbgpu.so
# has RUNPATH entries like /nix/store/<hash>-glibc-2.44-25/lib, and the only
# way those resolve inside the extracted rootfs is by having a real /nix/store
# tree there.
result_real=$(realpath "$result")
while IFS= read -r path; do
    [[ $path == "$result_real" ]] && continue
    case $path in
        /nix/store/*) cp -a "$path" "$stage/nix/store/" ;;
    esac
done < <(nix-store -qR "$result_real")

bash packaging/nix-rootfs/check-nix-rootfs.sh "$stage"

mkdir -p dist
archive="dist/bloodborne-nix-rootfs-$arch-$version.tar.zst"
echo "== nix rootfs: packing $archive"
tar -C "$stage" --numeric-owner --owner=0 --group=0 --zstd -cf "$archive" .
ls -lh "$archive"

uncompressed=$(du -sh "$stage" | cut -f1)
nixsize=$(du -sh "$stage/nix/store" 2>/dev/null | cut -f1)
printf '   staged %s (nix store %s)\n' "$uncompressed" "$nixsize"
