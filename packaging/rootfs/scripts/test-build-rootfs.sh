#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
package_root="$(cd -- "$script_dir/.." && pwd -P)"
repo_root="$(cd -- "$package_root/../.." && pwd -P)"
source "$script_dir/common.sh"

work="${WORK_DIR:-$repo_root/.work/rootfs-test}"
dist="$work/dist"

if [[ -e "$work" ]]; then
    chmod -R u+w "$work" 2>/dev/null || true
    rm -rf "$work"
fi
mkdir -p "$work/base/usr/bin" \
    "$work/base/usr/local/bin" \
    "$work/base/usr/share" \
    "$work/runtime/opt/bbport/bin" \
    "$work/runtime/opt/bbport/share/bbport/bin/gpu" \
    "$work/runtime/opt/bbport/share/bbport/bin/cpu" \
    "$work/runtime/opt/bbport/share/bbport/scripts" \
    "$work/runtime/opt/bbport/share/bbport/patches"

cat > "$work/base/usr/bin/gamescope" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$work/base/usr/local/bin/droiddeck-session" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$work/base/usr/bin/gamescope" "$work/base/usr/local/bin/droiddeck-session"

cat > "$work/runtime/opt/bbport/bin/bbport" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$work/runtime/opt/bbport/bin/bbport-driver" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$work/runtime/opt/bbport/share/bbport/run.sh" <<'EOF'
#!/bin/sh
exit 0
EOF
for file in prepare.py patches.py android_rootfs_profile.sh vulkan_driver_store.py; do
    printf '# test placeholder\n' > "$work/runtime/opt/bbport/share/bbport/scripts/$file"
done
printf '<patches />\n' > "$work/runtime/opt/bbport/share/bbport/patches/Bloodborne.xml"
for file in bb-probe bb-gpu-capabilities gpu/libbbgpu.so cpu/libbbcpu.so; do
    printf '# test placeholder\n' > "$work/runtime/opt/bbport/share/bbport/bin/$file"
done
chmod +x "$work/runtime/opt/bbport/bin/bbport" \
    "$work/runtime/opt/bbport/bin/bbport-driver" \
    "$work/runtime/opt/bbport/share/bbport/run.sh" \
    "$work/runtime/opt/bbport/share/bbport/bin/bb-probe" \
    "$work/runtime/opt/bbport/share/bbport/bin/bb-gpu-capabilities" \
    "$work/runtime/opt/bbport/share/bbport/bin/gpu/libbbgpu.so" \
    "$work/runtime/opt/bbport/share/bbport/bin/cpu/libbbcpu.so"
chmod 555 "$work/runtime/opt" "$work/runtime/opt/bbport" "$work/runtime/opt/bbport/bin"

bb_tar_create_zst "$work/base.tar.zst" "$work/base"
tar -czf "$work/runtime.tar.gz" -C "$work/runtime" .

BASE_ARCHIVE="$work/base.tar.zst" \
BASE_VERSION=test \
BBPORT_RUNTIME_TARBALL="$work/runtime.tar.gz" \
BLOODBORNE_ROOTFS_VERSION=test \
DIST_DIR="$dist" \
WORK_DIR="$work/build" \
"$script_dir/build-rootfs.sh"

test -s "$dist/bloodborne-droid-rootfs-aarch64-test.tar.zst"
test -s "$dist/bloodborne-droid-rootfs-aarch64-test.json"
echo "test-build-rootfs: ok"
