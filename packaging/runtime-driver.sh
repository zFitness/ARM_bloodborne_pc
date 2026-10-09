#!/usr/bin/env bash
set -euo pipefail

root=${BBPORT_ROOT:-/opt/bbport/share/bbport}
if [[ ! -d $root ]]; then
    echo "bbport-driver: runtime directory not found: $root" >&2
    echo "Set BBPORT_ROOT if the runtime package is not installed under /opt/bbport." >&2
    exit 1
fi

export PYTHON=${PYTHON:-@PYTHON@}
export BB_DATA_DIR=${BB_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/bbport}
mkdir -p "$BB_DATA_DIR"
exec "$PYTHON" "$root/scripts/vulkan_driver_store.py" "$@"
