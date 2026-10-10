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
# compat/ first: an imported external Vulkan driver (Turnip/…) resolves its DT_NEEDED purely
# through LD_LIBRARY_PATH and must hit the runtime's own nix libs before the base rootfs's
# older copies. Packed at build time by packaging/runtime-tar.nix.
export LD_LIBRARY_PATH="$root/compat${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export LD_LIBRARY_PATH="@LD_LIBRARY_PATH@${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export BB_DATA_DIR=${BB_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/bbport}
export BB_ANDROID_ROOTFS_PROFILE=${BB_ANDROID_ROOTFS_PROFILE:-1}
# The game's shadPS4 cache and other components create $HOME/.local/share/<app> with a
# non-recursive create_directory; the parent XDG dirs must already exist (root does not
# help). Create them so a fresh rootfs launches without any user setup.
mkdir -p "$BB_DATA_DIR" \
    "${XDG_DATA_HOME:-$HOME/.local/share}" \
    "${XDG_CONFIG_HOME:-$HOME/.config}" \
    "${XDG_CACHE_HOME:-$HOME/.cache}"

if [[ -f $root/scripts/android_rootfs_profile.sh ]]; then
    source "$root/scripts/android_rootfs_profile.sh"
    bb_android_apply_defaults
    bb_android_apply_process_affinity
fi

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
    # Same library path as the game: the rootfs's own system libraries are not in the
    # packaged closure, and this diagnostic would otherwise report the imported driver as
    # broken ("Failed loading library associated with ICD JSON ...: libzstd.so.1").
    if declare -F bb_android_apply_library_path >/dev/null; then
        bb_android_apply_library_path
    fi
    exec @VULKANINFO@ --summary
fi

if [[ -n ${BB_GAME_DIR:-} && ! -f $BB_GAME_DIR/eboot.bin ]]; then
    echo "No eboot.bin in BB_GAME_DIR=$BB_GAME_DIR." >&2
    exit 1
fi

# The rootfs's own system libraries are not part of the packaged closure: an imported
# Linux/rootfs Vulkan driver (Mesa Turnip: libzstd, libxcb-*, libwayland-client, ...) and the
# prebuilt bb-probe (libffi) resolve them from /usr/lib, which this runtime's glibc does not
# search. Added here, after the packaged tooling (Python on the closure's glibc) has run.
if declare -F bb_android_apply_library_path >/dev/null; then
    bb_android_apply_library_path
fi

cd "$root"
exec @BASH@ ./run.sh "$@"
