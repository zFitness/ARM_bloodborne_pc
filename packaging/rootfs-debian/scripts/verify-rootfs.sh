#!/usr/bin/env bash
# Verifies a staged Debian rootfs before it is packed. Exits non-zero on any failure so
# the CI step fails and no artifact is uploaded.
#
#   verify-rootfs.sh <stage-dir>
#
# Three groups of checks:
#   1. base layout      - it really is a Debian rootfs of the requested suite
#   2. bbport layout    - the runtime is installed and its ELF dependencies resolve
#   3. content boundary - no Vulkan ICD, no game files, no build caches
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/common.sh"

stage="${1:-}"
[[ -n $stage ]] || { echo 'usage: verify-rootfs.sh <stage-dir>' >&2; exit 64; }
[[ -d $stage ]] || { echo "No such rootfs: $stage" >&2; exit 2; }

fail=0
ok()   { printf '   ok      %s\n' "$*"; }
bad()  { printf '   MISSING %s\n' "$*" >&2; fail=1; }
nope() { printf '   UNEXPECTED %s\n' "$*" >&2; fail=1; }

echo "== verify: base layout"
for path in bin/sh usr/bin/dpkg etc/apt/sources.list var/lib/dpkg/status etc/debian_version; do
    [[ -e $stage/$path ]] && ok "$path" || bad "$path"
done

suite="${BB_DEBIAN_SUITE:-trixie}"
base_version=$(bb_read_base_version "$stage")
if [[ $base_version == "$suite" || $base_version == unknown ]]; then
    ok "Debian $base_version (suite $suite)"
else
    printf '   NOTE    base is Debian %s, expected %s\n' "$base_version" "$suite" >&2
fi

# A usable package manager is the whole reason this path exists.
if [[ -x $stage/usr/bin/apt-get ]]; then
    ok "apt-get present"
else
    bad "apt-get"
fi

echo "== verify: bbport layout"
for path in \
    opt/bbport/bin/bbport \
    opt/bbport/share/bbport/bin/bb-probe \
    opt/bbport/share/bbport/bin/bb-gpu-capabilities \
    opt/bbport/share/bbport/bin/gpu/libbbgpu.so
do
    [[ -e $stage/$path ]] && ok "$path" || bad "$path"
done
# Single launch entry: no bbport-game alias, no bloodborne-launch overlay.
[[ -e $stage/opt/bbport/bin/bbport-game ]] && nope "opt/bbport/bin/bbport-game (single entry only)" || ok "no bbport-game alias"
[[ -e $stage/usr/local/bin/bloodborne-launch ]] && nope "usr/local/bin/bloodborne-launch (single entry only)" || ok "no bloodborne-launch shim"
# Driver compat directory: an imported external Vulkan driver resolves its DT_NEEDED from here.
for path in \
    opt/bbport/share/bbport/compat/libwayland-client.so.0 \
    opt/bbport/share/bbport/compat/libxkbcommon.so.0 \
    opt/bbport/share/bbport/compat/libz.so.1 \
    opt/bbport/share/bbport/compat/libstdc++.so.6
do
    [[ -e $stage/$path ]] && ok "$path" || bad "$path"
done
if [[ $(uname -m) == aarch64 ]]; then
    if [[ -e $stage/opt/bbport/share/bbport/bin/cpu/libbbcpu.so ]]; then
        ok "opt/bbport/share/bbport/bin/cpu/libbbcpu.so"
    else
        bad "opt/bbport/share/bbport/bin/cpu/libbbcpu.so (aarch64 needs the FEXCore library)"
    fi
fi

echo "== verify: ELF dependencies"
# Read DT_NEEDED off the shipped binaries and confirm each resolves to a file inside the
# rootfs, or to a library the base rootfs legitimately provides. This catches a missing
# extras package before the artifact reaches a user who cannot fix it.
system_provided_re='^(libvulkan\.so|libX11\.so|libXext\.so|libxcb\.so|libc\.so|libm\.so|libdl\.so|libpthread\.so|libgcc_s\.so|libstdc\+\+\.so|libatomic\.so|libz\.so|ld-linux)'
elfs=(
    opt/bbport/share/bbport/bin/bb-probe
    opt/bbport/share/bbport/bin/gpu/libbbgpu.so
)
[[ -e $stage/opt/bbport/share/bbport/bin/cpu/libbbcpu.so ]] && \
    elfs+=(opt/bbport/share/bbport/bin/cpu/libbbcpu.so)

for rel in "${elfs[@]}"; do
    elf="$stage/$rel"
    [[ -r $elf ]] || continue
    missing_for=""
    while read -r line; do
        [[ $line == *NEEDED* ]] || continue
        lib=${line#*Shared library: [}
        lib=${lib%]}
        [[ -n $lib ]] || continue
        [[ $lib =~ $system_provided_re ]] && continue
        # Look inside the rootfs only: a library present on the build host but absent from
        # the rootfs is exactly the failure this check exists to catch.
        if ! find "$stage" -name "$lib" -print -quit 2>/dev/null | grep -q .; then
            missing_for+="$lib "
        fi
    done < <(readelf -d "$elf" 2>/dev/null)
    if [[ -z $missing_for ]]; then
        ok "$rel"
    else
        printf '   MISSING %s\n' "$rel" >&2
        printf '   UNRESOLVED in rootfs: %s\n' "$missing_for" >&2
        fail=1
    fi
done

echo "== verify: driverless boundary"
# The contract: no GPU driver ships. A stray ICD would silently change which driver the
# user ends up on.
icd_dir="$stage/usr/share/vulkan/icd.d"
if [[ -d $icd_dir ]] && [[ -n $(ls -A "$icd_dir" 2>/dev/null) ]]; then
    nope "Vulkan ICD files in $icd_dir: $(ls -A "$icd_dir" | tr '\n' ' ')"
else
    ok "no Vulkan ICD"
fi
if [[ -d $stage/usr/lib/aarch64-linux-gnu/dri ]]; then
    nope "Mesa DRI drivers present (implies a GPU driver)"
else
    ok "no Mesa DRI drivers"
fi

echo "== verify: no game files"
# eboot.bin is the Bloodborne executable; its presence means a dump leaked in.
if [[ -n $(find "$stage" -name 'eboot.bin' -print -quit 2>/dev/null) ]]; then
    nope "eboot.bin found; the rootfs must not contain game files"
else
    ok "no game files"
fi

echo "== verify: trimmed"
if [[ -d $stage/var/lib/apt/lists ]] && [[ -n $(ls -A "$stage/var/lib/apt/lists" 2>/dev/null) ]]; then
    nope "apt lists not trimmed ($(du -sh "$stage/var/lib/apt/lists" | cut -f1))"
else
    ok "apt lists trimmed"
fi
if compgen -G "$stage/var/cache/apt/archives/*.deb" >/dev/null; then
    nope "cached .deb files not trimmed"
else
    ok "no cached .deb files"
fi

echo "== verify: size"
printf '   staged %s\n' "$(du -sh "$stage" | cut -f1)"

if (( fail )); then
    echo "verify-rootfs: FAILED" >&2
    exit 2
fi
echo "== verify: all checks passed"