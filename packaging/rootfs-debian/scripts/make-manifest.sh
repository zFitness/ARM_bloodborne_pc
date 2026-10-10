#!/usr/bin/env bash
# Writes the .json manifest describing a built Debian rootfs.
#
#   make-manifest.sh <archive> <version> <base-version> <output.json>
#
# The DroidDeck manifest records BASE_VERSION/BASE_SHA256; for the Debian path the
# equivalent provenance is the suite, the mirror it came from, the bbport commit, and
# the sha256 of the runtime tarball it was built from. Those are what someone needs to
# reproduce or bisect a rootfs.
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/common.sh"

archive="${1:-}"
version="${2:-}"
base_version="${3:-}"
json="${4:-}"
[[ -n $archive && -n $version && -n $json ]] || {
    echo 'usage: make-manifest.sh <archive> <version> <base-version> <output.json>' >&2
    exit 64
}

repo_root="$(cd -- "$script_dir/../../.." && pwd -P)"
arch=$(uname -m)

commit=unknown
if [[ -d $repo_root/.git || -f $repo_root/.git ]]; then
    commit=$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || echo unknown)
fi

runtime_tar="${BBPORT_RUNTIME_TARBALL:-$repo_root/dist/Bloodborne-bbport-runtime-$arch.tar.gz}"
runtime_sha=""
if [[ -f $runtime_tar ]]; then
    runtime_sha=$(bb_sha256 "$runtime_tar")
else
    runtime_tar=""
fi

[[ -f $archive ]] && archive_sha=$(bb_sha256 "$archive") || archive_sha=""

cat > "$json" <<EOF
{
  "name": "bloodborne-debian-rootfs",
  "version": "$version",
  "architecture": "$arch",
  "base": {
    "distribution": "debian",
    "version": "$base_version",
    "mirror": "${BB_DEBIAN_MIRROR:-http://deb.debian.org/debian}",
    "generated_by": "debootstrap --variant=minbase"
  },
  "bbport": {
    "commit": "$commit",
    "runtime_tar": "${runtime_tar##*/}",
    "runtime_tar_sha256": "$runtime_sha"
  },
  "artifact": {
    "file": "${archive##*/}",
    "size": $(bb_file_size "$archive" 2>/dev/null || echo 0),
    "sha256": "$archive_sha"
  },
  "contents": {
    "install_path": "/opt/bbport",
    "entry_point": "/opt/bbport/bin/bbport",
    "package_manager": "apt",
    "vulkan_driver": "not bundled; install mesa-vulkan-drivers or run /opt/bbport/bin/bbport-driver import"
  }
}
EOF

cat "$json"