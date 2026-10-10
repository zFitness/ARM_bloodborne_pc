#!/usr/bin/env bash
# Validates a self-sufficient bbport Nix rootfs.
#
#   check-nix-rootfs.sh <archive-or-staging-dir>
#
# Three groups of checks:
#   1. bbport tree     - the runtime layout the launcher/import tools expect
#   2. /etc + /bin     - the bits that make getpwnam / exec work inside proot
#   3. closure         - /nix/store is present so the bbport RUNPATHs resolve
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <archive-or-staging-dir>" >&2
    exit 2
fi

target=$1
if [[ -d $target ]]; then
    list=$(cd "$target" && find . -print | sed 's#^\./##; s#/*$##' | sort -u)
else
    case $target in
        *.tar|*.tar.gz|*.tgz|*.tar.xz|*.txz|*.tar.zst|*.tzst) ;;
        *) echo "Not a supported tar archive: $target" >&2; exit 2 ;;
    esac
    list=$(tar -tf "$target" | sed 's#^\./##; s#/*$##' | sort -u)
fi

ok()   { printf '   ok      %s\n' "$*"; }
bad()  { printf '   MISSING %s\n' "$*" >&2; fail=1; }
nope() { printf '   UNEXPECTED %s\n' "$*" >&2; fail=1; }
fail=0

echo "== nix rootfs: bbport tree"
for path in \
    opt/bbport/bin/bbport \
    opt/bbport/bin/bbport-driver \
    opt/bbport/share/bbport/run.sh \
    opt/bbport/share/bbport/scripts/prepare.py \
    opt/bbport/share/bbport/scripts/patches.py \
    opt/bbport/share/bbport/scripts/vulkan_driver_store.py \
    opt/bbport/share/bbport/patches/Bloodborne.xml \
    opt/bbport/share/bbport/bin/bb-probe \
    opt/bbport/share/bbport/bin/bb-gpu-capabilities \
    opt/bbport/share/bbport/bin/gpu/libbbgpu.so \
    opt/bbport/share/bbport/bin/cpu/libbbcpu.so
do
    if grep -Fxq "$path" <<< "$list"; then ok "$path"; else bad "$path"; fi
done

# Same exclusions as the runtime-tar: the bbport-tar pipeline strips the
# launcher, FSR assets, MangoHud and the Vulkan ICD drivers. nix-rootfs must
# obey the same boundary.
forbid_match() {
    if grep -Eq "$1" <<< "$list"; then
        printf '   forbidden: %s\n' "$1" >&2
        grep -E "$1" <<< "$list" >&2
        fail=1
    fi
}
forbid_match '(^|/)launcher(/|$)'
forbid_match '(^|/)fsr4_shaders(/|$)'
forbid_match '(^|/)fsr4_411(/|$)'
forbid_match '(^|/)tools/fsr4cap(/|$)'
forbid_match '(^|/)share/vulkan/icd\.d/[^/]+\.json$'
forbid_match '(^|/)(freedreno|radeon|intel|nvidia|lvp|lavapipe|panfrost|broadcom|asahi)_icd\.[^.]+\.json$'
forbid_match '(^|/)libvulkan_(freedreno|radeon|intel|lvp|lavapipe|panfrost|broadcom|asahi|nvidia)[^/]*\.so'
forbid_match '(^|/)libVkLayer_MESA[^/]*\.so'

echo "== nix rootfs: /etc and entrypoints"
for path in \
    etc/passwd etc/group etc/nsswitch.conf \
    bin/sh bin/bash usr/bin/env
do
    if grep -Fxq "$path" <<< "$list"; then ok "$path"; else bad "$path"; fi
done

echo "== nix rootfs: closure"
nix_count=$(grep -cE '^nix/store/[^/]+/' <<< "$list" || true)
if (( nix_count < 5 )); then
    printf '   MISSING: too few /nix/store/ entries (%d); bbport closure is incomplete\n' "$nix_count" >&2
    fail=1
else
    ok "/nix/store/ ($nix_count entries)"
fi

if (( fail )); then
    echo "nix rootfs: FAILED" >&2
    exit 2
fi
echo "== nix rootfs: all checks passed"
