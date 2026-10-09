#!/usr/bin/env bash
set -euo pipefail

# Minimal command-line entry for the Turnip tar package. It intentionally avoids
# the GTK launcher, AppImage entrypoint, Steam overlay handling and host ICD
# probing used by the desktop package.
root=${BBPORT_ROOT:-/opt/bbport/share/bbport}
if [[ ! -d $root ]]; then
    echo "bbport-turnip: runtime directory not found: $root" >&2
    echo "Set BBPORT_ROOT if the tar package is not installed under /opt/bbport." >&2
    exit 1
fi

export BB_PREBUILT=1
export BB_PROBE=${BB_PROBE:-$root/bin/bb-probe}
export PYTHON=${PYTHON:-@PYTHON@}
export PATH="@PATH@${PATH:+:$PATH}"
export LD_LIBRARY_PATH="@LD_LIBRARY_PATH@${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export BB_DATA_DIR=${BB_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/bbport}
mkdir -p "$BB_DATA_DIR"

if [[ -n ${BB_TURNIP_ICD:-} ]]; then
    export VK_DRIVER_FILES=$BB_TURNIP_ICD
elif [[ -z ${VK_DRIVER_FILES:-} ]]; then
    export VK_DRIVER_FILES="@TURNIP_ICD@"
fi
echo "Vulkan: Turnip ICD $VK_DRIVER_FILES" >&2

if [[ ${1:-} == --vulkan-info ]]; then
    exec @VULKANINFO@ --summary
fi

if [[ -n ${BB_GAME_DIR:-} && ! -f $BB_GAME_DIR/eboot.bin ]]; then
    echo "No eboot.bin in BB_GAME_DIR=$BB_GAME_DIR." >&2
    exit 1
fi

cd "$root"
exec @BASH@ ./run.sh "$@"
