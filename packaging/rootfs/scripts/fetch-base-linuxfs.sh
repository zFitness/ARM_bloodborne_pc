#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
package_root="$(cd -- "$script_dir/.." && pwd -P)"
repo_root="$(cd -- "$package_root/../.." && pwd -P)"
source "$script_dir/common.sh"

work="${WORK_DIR:-$repo_root/.work/rootfs}"
mkdir -p "$work"

catalog_url="${LINUXFS_CATALOG_URL:-https://raw.githubusercontent.com/The412Banner/winlator-contents/main/linuxfs.json}"
catalog="$work/linuxfs.json"
archive="$work/linuxfs.tar.zst"
env_file="$work/base-linuxfs.env"

if [[ -n "${BASE_ARCHIVE:-}" ]]; then
    [[ -f "$BASE_ARCHIVE" ]] || { echo "BASE_ARCHIVE does not exist: $BASE_ARCHIVE" >&2; exit 2; }
    {
        bb_env_assignment BASE_VERSION "${BASE_VERSION:-local}"
        bb_env_assignment BASE_URL "file://$BASE_ARCHIVE"
        bb_env_assignment BASE_SHA256 "$(bb_sha256 "$BASE_ARCHIVE")"
        bb_env_assignment BASE_SIZE "$(bb_file_size "$BASE_ARCHIVE")"
        bb_env_assignment BASE_ARCHIVE "$BASE_ARCHIVE"
        bb_env_assignment BASE_CATALOG ""
    } > "$env_file"
    echo "$env_file"
    exit 0
fi

echo "== linuxfs: fetching catalog $catalog_url" >&2
curl -L --fail --retry 3 --retry-delay 2 -o "$catalog" "$catalog_url"

read -r version url sha size < <(python3 - "$catalog" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)

print(data["version"], data["url"], data["sha256"], data.get("size") or data.get("file_size") or 0)
PY
)

if [[ ! -f "$archive" ]]; then
    echo "== linuxfs: downloading $url" >&2
    curl -L --fail --retry 3 --retry-delay 2 -o "$archive" "$url"
fi

echo "== linuxfs: verifying sha256" >&2
actual="$(bb_sha256 "$archive")"
if [[ "$actual" != "$sha" ]]; then
    echo "linuxfs checksum mismatch: expected $sha, got $actual" >&2
    exit 2
fi

{
    bb_env_assignment BASE_VERSION "$version"
    bb_env_assignment BASE_URL "$url"
    bb_env_assignment BASE_SHA256 "$sha"
    bb_env_assignment BASE_SIZE "$size"
    bb_env_assignment BASE_ARCHIVE "$archive"
    bb_env_assignment BASE_CATALOG "$catalog"
} > "$env_file"

echo "$env_file"
