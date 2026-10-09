#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat >&2 <<'EOF'
usage: build-bbport-layer-from-runtime-tar.sh <runtime.tar.*> [output.tar.zst]

Builds a rootfs-relative bbport layer from this repository's driverless runtime
tar. The output contains /opt/bbport plus a bbport-game compatibility entry for
the DroidDeck Bloodborne launcher.
EOF
}

if (( $# < 1 || $# > 2 )); then
    usage
    exit 64
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
package_root="$(cd -- "$script_dir/.." && pwd -P)"
repo_root="$(cd -- "$package_root/../.." && pwd -P)"
source "$script_dir/common.sh"

runtime="$(cd -- "$(dirname -- "$1")" && pwd -P)/$(basename -- "$1")"
out="${2:-$repo_root/dist/bbport-droiddeck-aarch64-layer.tar.zst}"
work="${WORK_DIR:-$repo_root/.work/rootfs}"

[[ -f "$runtime" ]] || { echo "Runtime tar not found: $runtime" >&2; exit 2; }

if [[ "${BBPORT_SKIP_RUNTIME_CHECK:-0}" != 1 && -x "$repo_root/packaging/check-runtime-tar.sh" ]]; then
    bash "$repo_root/packaging/check-runtime-tar.sh" "$runtime"
fi

stage="$work/bbport-layer"
tmp_stage="$work/bbport-layer.tmp"
for path in "$stage" "$tmp_stage"; do
    if [[ -e "$path" ]]; then
        chmod -R u+w "$path" 2>/dev/null || true
        rm -rf "$path"
    fi
done
mkdir -p "$tmp_stage"

echo "== bbport layer: extracting runtime $runtime"
bb_tar_extract "$runtime" "$tmp_stage"

[[ -x "$tmp_stage/opt/bbport/bin/bbport" ]] || {
    echo "Runtime tar missing executable opt/bbport/bin/bbport: $runtime" >&2
    exit 2
}

bbport_bin="$tmp_stage/opt/bbport/bin"
chmod u+w "$tmp_stage/opt" "$tmp_stage/opt/bbport" "$bbport_bin" 2>/dev/null || true
rm -f "$bbport_bin/bbport-game"
cat > "$bbport_bin/bbport-game" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exec /opt/bbport/bin/bbport "$@"
EOF
chmod 755 "$bbport_bin/bbport-game"

mv "$tmp_stage" "$stage"

echo "== bbport layer: packing $out"
bb_tar_create_zst "$out" "$stage"
ls -lh "$out"
