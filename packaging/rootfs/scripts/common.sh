#!/usr/bin/env bash

bb_sha256() {
    local file=$1
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$file" | awk '{print $1}'
    else
        echo "Need sha256sum or shasum." >&2
        return 69
    fi
}

bb_file_size() {
    wc -c < "$1" | tr -d ' '
}

bb_env_assignment() {
    local name=$1 value=$2
    printf '%s=%q\n' "$name" "$value"
}

bb_tar_supports_zstd() {
    tar --help 2>/dev/null | grep -q -- '--zstd'
}

bb_tar_extract() {
    local archive=$1 dest=$2
    mkdir -p "$dest"
    case "$archive" in
        *.tar.zst|*.tzst)
            if bb_tar_supports_zstd; then
                tar --zstd -xf "$archive" -C "$dest"
            else
                command -v zstd >/dev/null 2>&1 || { echo "Need zstd to extract $archive." >&2; return 69; }
                zstd -dc "$archive" | tar -xf - -C "$dest"
            fi
            ;;
        *.tar.gz|*.tgz)
            tar -xzf "$archive" -C "$dest"
            ;;
        *.tar)
            tar -xf "$archive" -C "$dest"
            ;;
        *)
            echo "Unsupported tar archive: $archive" >&2
            return 64
            ;;
    esac
}

bb_tar_create_zst() {
    local archive=$1 source_dir=$2
    mkdir -p "$(dirname -- "$archive")"
    if bb_tar_supports_zstd; then
        tar --zstd -cf "$archive" -C "$source_dir" .
    else
        command -v zstd >/dev/null 2>&1 || { echo "Need zstd to create $archive." >&2; return 69; }
        tar -cf - -C "$source_dir" . | zstd -T0 -19 -f -o "$archive"
    fi
}
