#!/usr/bin/env bash
# Builds dist/Bloodborne-bbport-turnip-<arch>.tar.gz for rootfs/proot use.
# Run build.sh first on an aarch64 Linux host/runner.
set -euo pipefail
cd -- "$(dirname -- "$0")/.."

missing=()
[[ -x out/bb-probe ]] || missing+=("out/bb-probe")
[[ -x out/bb-gpu-capabilities ]] || missing+=("out/bb-gpu-capabilities")
[[ -f out/gpu/libbbgpu.so ]] || missing+=("out/gpu/libbbgpu.so")
[[ -f out/fex/libbbcpu.so ]] || missing+=("out/fex/libbbcpu.so")
if (( ${#missing[@]} )); then
    printf 'Build first: bash build.sh (missing %s)\n' "${missing[*]}" >&2
    exit 1
fi
if ! command -v readelf >/dev/null; then
    echo 'Need readelf from binutils to collect runtime RUNPATHs.' >&2
    exit 1
fi
if ! command -v nix-build >/dev/null || ! command -v nix-store >/dev/null; then
    echo 'Need Nix with nix-build and nix-store to build the Turnip tar closure.' >&2
    exit 1
fi

case "$(uname -s):$(uname -m)" in
    Linux:aarch64) ;;
    *) echo 'minimal Turnip tar must be built on an aarch64 Linux host/runner.' >&2; exit 1 ;;
esac

read -r -a nix_build <<< "${NIX_BUILD:-nix-build}"
include=()
if [[ -n ${BB_NIXPKGS:-} ]]; then include=(-I "nixpkgs=$BB_NIXPKGS"); fi

libs=(out/bb-probe out/bb-gpu-capabilities out/gpu/libbbgpu.so out/fex/libbbcpu.so)
{
    echo '['
    for elf in "${libs[@]}"; do
        readelf -d "$elf" | sed -n 's/.*\[\(.*\)\]/\1/p' | tr ':' '\n'
    done | grep -o '^/nix/store/[^/]*' | sort -u | grep -v -- '-nix-shell$' | sed 's/.*/  "&"/'
    echo ']'
} > packaging/runtime-paths.nix

work=$(mktemp -d)
cleanup() {
    chmod -R u+w "$work" 2>/dev/null || true
    rm -rf "$work"
}
trap cleanup EXIT
result=$work/result
"${nix_build[@]}" "${include[@]}" packaging/turnip-tar.nix -o "$result" >/dev/null

stage=$work/stage
mkdir -p "$stage/nix/store"
cp -a "$result"/. "$stage"/

result_real=$(realpath "$result")
while IFS= read -r path; do
    [[ $path == "$result_real" ]] && continue
    case $path in
        /nix/store/*) cp -a "$path" "$stage/nix/store/" ;;
    esac
done < <(nix-store -qR "$result_real")

bash packaging/check-turnip-tar.sh "$stage"

arch=$(uname -m)
mkdir -p dist
archive=dist/Bloodborne-bbport-turnip-$arch.tar.gz
tar -C "$stage" --numeric-owner --owner=0 --group=0 -czf "$archive" .
bash packaging/check-turnip-tar.sh "$archive"
ls -lh "$archive"
