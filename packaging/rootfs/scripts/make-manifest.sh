#!/usr/bin/env bash
set -euo pipefail

if (( $# != 4 )); then
    echo "usage: make-manifest.sh <archive> <version> <base-version> <output-json>" >&2
    exit 64
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
package_root="$(cd -- "$script_dir/.." && pwd -P)"
repo_root="$(cd -- "$package_root/../.." && pwd -P)"
source "$script_dir/common.sh"

archive="$1"
version="$2"
base_version="$3"
out="$4"

sha="$(bb_sha256 "$archive")"
size="$(bb_file_size "$archive")"
bbport_commit="unknown"
if [[ -d "$repo_root/.git" || -f "$repo_root/.git" ]]; then
    bbport_commit="$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || echo unknown)"
fi

python3 - "$out" "$version" "$base_version" "$bbport_commit" "$archive" "$sha" "$size" <<'PY'
import json
import pathlib
import sys

out, version, base_version, commit, archive, sha, size = sys.argv[1:]
data = {
    "schemaVersion": 1,
    "kind": "bloodborne-droid-rootfs",
    "version": version,
    "arch": "aarch64",
    "base": {
        "source": "The412Banner/winlator-contents",
        "linuxfs": base_version,
    },
    "bbport": {
        "source": "ARM_bloodborne_pc",
        "commit": commit,
        "entrypoint": "/usr/local/bin/bloodborne-launch",
    },
    "file": pathlib.Path(archive).name,
    "sha256": sha,
    "size": int(size),
    "entrypoint": "/usr/local/bin/bloodborne-launch",
}
pathlib.Path(out).write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
PY

echo "== manifest: $out"
