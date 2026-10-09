#!/usr/bin/env bash
set -euo pipefail

if (( $# != 1 )); then
    echo "usage: install-bbport.sh <staged-rootfs>" >&2
    exit 64
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/common.sh"

stage="$1"

if [[ -n "${BBPORT_LAYER_TARBALL:-}" ]]; then
    echo "== bbport: extracting layer $BBPORT_LAYER_TARBALL"
    bb_tar_extract "$BBPORT_LAYER_TARBALL" "$stage"
elif [[ -n "${BBPORT_RUNTIME_TARBALL:-}" ]]; then
    echo "== bbport: extracting runtime $BBPORT_RUNTIME_TARBALL"
    bb_tar_extract "$BBPORT_RUNTIME_TARBALL" "$stage"
    if [[ ! -e "$stage/opt/bbport/bin/bbport-game" ]]; then
        mkdir -p "$stage/opt/bbport/bin"
        cat > "$stage/opt/bbport/bin/bbport-game" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exec /opt/bbport/bin/bbport "$@"
EOF
        chmod 755 "$stage/opt/bbport/bin/bbport-game"
    fi
else
    cat >&2 <<'EOF'
No bbport payload was provided.

Set one of:
  BBPORT_RUNTIME_TARBALL=/path/to/Bloodborne-bbport-runtime-aarch64.tar.gz
  BBPORT_LAYER_TARBALL=/path/to/bbport-droiddeck-aarch64-layer.tar.zst

The runtime tar is produced by:
  bash packaging/runtime-tar.sh
EOF
    exit 65
fi
