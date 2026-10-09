#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <runtime-tar-archive-or-staging-dir>" >&2
    exit 2
fi

target=$1
if [[ -d $target ]]; then
    list=$(cd "$target" && find . -print | sed 's#^\./##' | sort)
else
    case $target in
        *.tar|*.tar.gz|*.tgz|*.tar.xz|*.txz|*.tar.zst|*.tzst) ;;
        *) echo "Not a supported tar archive: $target" >&2; exit 2 ;;
    esac
    list=$(tar -tf "$target" | sed 's#^\./##; s#/*$##' | sort -u)
fi

require() {
    local path=$1
    if ! grep -Fxq "$path" <<< "$list"; then
        echo "Missing required path: $path" >&2
        exit 1
    fi
}

forbid_match() {
    local pattern=$1
    if grep -Eq "$pattern" <<< "$list"; then
        echo "Forbidden path matched: $pattern" >&2
        grep -E "$pattern" <<< "$list" >&2
        exit 1
    fi
}

require "opt/bbport/bin/bbport"
require "opt/bbport/bin/bbport-driver"
require "opt/bbport/share/bbport/run.sh"
require "opt/bbport/share/bbport/scripts/prepare.py"
require "opt/bbport/share/bbport/scripts/patches.py"
require "opt/bbport/share/bbport/scripts/vulkan_driver_store.py"
require "opt/bbport/share/bbport/patches/Bloodborne.xml"
require "opt/bbport/share/bbport/bin/bb-probe"
require "opt/bbport/share/bbport/bin/bb-gpu-capabilities"
require "opt/bbport/share/bbport/bin/gpu/libbbgpu.so"
require "opt/bbport/share/bbport/bin/cpu/libbbcpu.so"

forbid_match '(^|/)launcher(/|$)'
forbid_match '(^|/)fsr4_shaders(/|$)'
forbid_match '(^|/)fsr4_411(/|$)'
forbid_match '(^|/)tools/fsr4cap(/|$)'
forbid_match '(^|/)tools/fetch_fsr4_assets\.sh$'
forbid_match '(^|/)bbport-entry($|\.c$)'
forbid_match '(^|/)MangoHud|(^|/)mangohud(/|$)'
forbid_match '(^|/)share/vulkan/icd\.d/[^/]+\.json$'
forbid_match '(^|/)(freedreno|radeon|intel|nvidia|lvp|lavapipe|panfrost|broadcom|asahi)_icd\.[^.]+\.json$'
forbid_match '(^|/)libvulkan_(freedreno|radeon|intel|lvp|lavapipe|panfrost|broadcom|asahi|nvidia)[^/]*\.so'
forbid_match '(^|/)libVkLayer_MESA[^/]*\.so'

echo "Driverless runtime tar contents OK: $target"
