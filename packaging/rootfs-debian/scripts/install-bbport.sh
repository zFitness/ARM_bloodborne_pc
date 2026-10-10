#!/usr/bin/env bash
# Installs the bbport runtime into a staged Debian rootfs, from the same driverless
# runtime tarball the DroidDeck path uses.
#
#   install-bbport.sh <stage-dir> <runtime-tar>
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
package_root="$(cd -- "$script_dir/.." && pwd -P)"
repo_root="$(cd -- "$package_root/../.." && pwd -P)"
source "$script_dir/common.sh"

stage="${1:-}"
runtime="${2:-}"
[[ -n $stage && -n $runtime ]] || { echo 'usage: install-bbport.sh <stage-dir> <runtime-tar>' >&2; exit 64; }
[[ -f $runtime ]] || {
    echo "Runtime tar not found: $runtime" >&2
    echo "Build it first: bash build.sh && bash packaging/runtime-tar.sh" >&2
    exit 2
}

if [[ "${BBPORT_SKIP_RUNTIME_CHECK:-0}" != 1 && -x $repo_root/packaging/check-runtime-tar.sh ]]; then
    bash "$repo_root/packaging/check-runtime-tar.sh" "$runtime"
fi

echo "== bbport: installing runtime into $stage"
bb_tar_extract "$runtime" "$stage"

[[ -x $stage/opt/bbport/bin/bbport ]] || {
    echo "Runtime tar missing /opt/bbport/bin/bbport: $runtime" >&2
    exit 2
}

# bbport-game is the entry name the packaged layout and the DroidDeck launcher expect.
# runtime-tar.sh already ships one, but create it if this tarball predates that.
if [[ ! -x $stage/opt/bbport/bin/bbport-game ]]; then
    cat > "$stage/opt/bbport/bin/bbport-game" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exec /opt/bbport/bin/bbport "$@"
EOF
    chmod 755 "$stage/opt/bbport/bin/bbport-game"
fi
chmod 755 "$stage/opt/bbport/bin/bbport" "$stage/opt/bbport/bin/bbport-game"

echo "== bbport: installed"
find "$stage/opt/bbport" -maxdepth 4 -type f -name '*.so' -o -type f -name 'bb-probe' \
    | sed "s|$stage||" | sort | sed 's/^/   /'