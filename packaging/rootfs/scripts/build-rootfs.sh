#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
package_root="$(cd -- "$script_dir/.." && pwd -P)"
repo_root="$(cd -- "$package_root/../.." && pwd -P)"
source "$script_dir/common.sh"

work="${WORK_DIR:-$repo_root/.work/rootfs}"
dist="${DIST_DIR:-$repo_root/dist}"
version="${BLOODBORNE_ROOTFS_VERSION:-r1}"
stage="$work/rootfs"

mkdir -p "$work" "$dist"

if [[ -z "${BBPORT_LAYER_TARBALL:-}" ]]; then
    default_runtime="$repo_root/dist/Bloodborne-bbport-runtime-aarch64.tar.gz"
    if [[ -z "${BBPORT_RUNTIME_TARBALL:-}" && -f "$default_runtime" ]]; then
        BBPORT_RUNTIME_TARBALL="$default_runtime"
        export BBPORT_RUNTIME_TARBALL
    fi
    if [[ -n "${BBPORT_RUNTIME_TARBALL:-}" ]]; then
        BBPORT_LAYER_TARBALL="$work/bbport-droiddeck-aarch64-layer.tar.zst"
        export BBPORT_LAYER_TARBALL
        "$script_dir/build-bbport-layer-from-runtime-tar.sh" "$BBPORT_RUNTIME_TARBALL" "$BBPORT_LAYER_TARBALL"
    fi
fi

env_file="$("$script_dir/fetch-base-linuxfs.sh")"
source "$env_file"

echo "== rootfs: staging $BASE_VERSION"
if [[ -e "$stage" ]]; then
    chmod -R u+w "$stage" 2>/dev/null || true
    rm -rf "$stage"
fi
mkdir -p "$stage"
bb_tar_extract "$BASE_ARCHIVE" "$stage"

echo "== rootfs: applying overlay"
cp -a "$package_root/overlay/rootfs"/. "$stage"/
chmod 755 "$stage/usr/local/bin/bloodborne-launch"

"$script_dir/install-bbport.sh" "$stage"

manifest_in="$stage/usr/local/share/bloodborne/runtime-manifest.json.in"
manifest="$stage/usr/local/share/bloodborne/runtime-manifest.json"
bbport_commit="unknown"
if [[ -d "$repo_root/.git" || -f "$repo_root/.git" ]]; then
    bbport_commit="$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || echo unknown)"
fi
sed -e "s/@VERSION@/$version/g" \
    -e "s/@BASE_VERSION@/$BASE_VERSION/g" \
    -e "s/@BBPORT_COMMIT@/$bbport_commit/g" \
    "$manifest_in" > "$manifest"
rm -f "$manifest_in"

"$script_dir/trim-rootfs.sh" "$stage"
"$script_dir/verify-rootfs.sh" "$stage"

archive="$dist/bloodborne-droid-rootfs-aarch64-$version.tar.zst"
json="$dist/bloodborne-droid-rootfs-aarch64-$version.json"

echo "== pack: $archive"
bb_tar_create_zst "$archive" "$stage"
"$script_dir/make-manifest.sh" "$archive" "$version" "$BASE_VERSION" "$json"

ls -lh "$archive" "$json"
