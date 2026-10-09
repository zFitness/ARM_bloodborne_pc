#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <turnip-tar-archive-or-staging-dir>" >&2
    exit 2
fi

target=$1
tmp=
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

require_match() {
    local pattern=$1
    if ! grep -Eq "$pattern" <<< "$list"; then
        echo "Missing required pattern: $pattern" >&2
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

require "opt/bbport/bin/bbport-turnip"
require "opt/bbport/share/bbport/run.sh"
require "opt/bbport/share/bbport/scripts/prepare.py"
require "opt/bbport/share/bbport/scripts/patches.py"
require "opt/bbport/share/bbport/patches/Bloodborne.xml"
require "opt/bbport/share/bbport/bin/bb-probe"
require "opt/bbport/share/bbport/bin/bb-gpu-capabilities"
require "opt/bbport/share/bbport/bin/gpu/libbbgpu.so"
require "opt/bbport/share/bbport/bin/cpu/libbbcpu.so"
require_match '^nix/store/[^/]+/share/vulkan/icd.d/freedreno_icd\.[^.]+\.json$'

forbid_match '(^|/)launcher(/|$)'
forbid_match '(^|/)fsr4_shaders(/|$)'
forbid_match '(^|/)fsr4_411(/|$)'
forbid_match '(^|/)tools/fsr4cap(/|$)'
forbid_match '(^|/)tools/fetch_fsr4_assets\.sh$'
forbid_match '(^|/)bbport-entry($|\.c$)'
forbid_match '(^|/)MangoHud|(^|/)mangohud(/|$)'
forbid_match '(^|/)nvidia_icd\.[^.]+\.json$'
forbid_match '(^|/)radeon_icd\.[^.]+\.json$'
forbid_match '(^|/)intel_icd\.[^.]+\.json$'
forbid_match '(^|/)lvp_icd\.[^.]+\.json$'

echo "Turnip tar contents OK: $target"
