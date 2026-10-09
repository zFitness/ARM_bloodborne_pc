#!/usr/bin/env bash
set -euo pipefail

# Command-line entry for the ARM64 rootfs/proot package. The package is
# intentionally driverless: Vulkan must come from an imported Linux/rootfs driver
# or an explicit user override.
root=${BBPORT_ROOT:-/opt/bbport/share/bbport}
if [[ ! -d $root ]]; then
    echo "bbport: runtime directory not found: $root" >&2
    echo "Set BBPORT_ROOT if the runtime package is not installed under /opt/bbport." >&2
    exit 1
fi

export BB_PREBUILT=1
export BB_PROBE=${BB_PROBE:-$root/bin/bb-probe}
export PYTHON=${PYTHON:-@PYTHON@}
export PATH="@PATH@${PATH:+:$PATH}"
export LD_LIBRARY_PATH="@LD_LIBRARY_PATH@${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export BB_DATA_DIR=${BB_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/bbport}
mkdir -p "$BB_DATA_DIR"

driver_tool=$root/scripts/vulkan_driver_store.py
if [[ ${1:-} == --driver ]]; then
    shift
    exec "$PYTHON" "$driver_tool" "$@"
fi

if [[ -n ${VK_DRIVER_FILES:-} ]]; then
    echo "Vulkan driver: override VK_DRIVER_FILES=$VK_DRIVER_FILES" >&2
elif [[ -n ${VK_ICD_FILENAMES:-} ]]; then
    echo "Vulkan driver: override VK_ICD_FILENAMES=$VK_ICD_FILENAMES" >&2
else
    args=(env)
    if [[ -n ${BB_VULKAN_DRIVER_ID:-} ]]; then
        args+=(--id "$BB_VULKAN_DRIVER_ID")
    fi
    if ! driver_env=$("$PYTHON" "$driver_tool" "${args[@]}"); then
        echo "Import a Linux/rootfs Vulkan driver first:" >&2
        echo "  /opt/bbport/bin/bbport-driver import <driver.zip-or-directory>" >&2
        echo "Or set VK_DRIVER_FILES to an explicit Linux ICD JSON." >&2
        exit 1
    fi
    eval "$driver_env"
    if [[ -n ${BB_DRIVER_LD_LIBRARY_PATH:-} ]]; then
        export LD_LIBRARY_PATH="$BB_DRIVER_LD_LIBRARY_PATH${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    fi
    echo "Vulkan driver: imported $BB_VULKAN_DRIVER_ID ($VK_DRIVER_FILES)" >&2
fi

if [[ ${1:-} == --vulkan-info ]]; then
    exec @VULKANINFO@ --summary
fi

if [[ -n ${BB_GAME_DIR:-} && ! -f $BB_GAME_DIR/eboot.bin ]]; then
    echo "No eboot.bin in BB_GAME_DIR=$BB_GAME_DIR." >&2
    exit 1
fi

cd "$root"
exec @BASH@ ./run.sh "$@"
