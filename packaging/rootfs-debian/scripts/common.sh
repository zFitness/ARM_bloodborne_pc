#!/usr/bin/env bash
# Helpers shared by the Debian rootfs packaging scripts.
#
# Sourced, not executed.

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

bb_dir_size() {
    du -sb "$1" 2>/dev/null | awk '{print $1}'
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

# Packs a staged rootfs so it can be extracted by an unprivileged Android user with a plain
# `tar -xf`:
#   --hard-dereference  stores hard-link members as independent copies. Android's untrusted-app
#                       SELinux policy rejects link(2) on app-private storage, so a tar with
#                       hard links (perl, terminfo, ...) aborts the extractor with EPERM.
#   --exclude=./dev/*   drops device nodes. An unprivileged extractor cannot mknod them and a
#                       proot consumer binds the host /dev anyway; the (now empty) /dev dir is
#                       kept.
bb_tar_create_zst() {
    local archive=$1 source_dir=$2
    mkdir -p "$(dirname -- "$archive")"
    local pack=(--hard-dereference --exclude=./dev/*)
    if bb_tar_supports_zstd; then
        tar "${pack[@]}" --zstd -cf "$archive" -C "$source_dir" .
    else
        command -v zstd >/dev/null 2>&1 || { echo "Need zstd to create $archive." >&2; return 69; }
        tar "${pack[@]}" -cf - -C "$source_dir" . | zstd -T0 -19 -f -o "$archive"
    fi
}

# Reads the Debian release out of a staged rootfs. Used for the manifest, so a rootfs
# whose base version silently differs from the requested suite is visible.
bb_read_base_version() {
    local stage=$1
    if [[ -r $stage/etc/debian_version ]]; then
        tr -d '[:space:]' < "$stage/etc/debian_version"
    else
        echo "unknown"
    fi
}

# Runs a command with the staged rootfs as its root.
#
# Prefers chroot (fast, real) and falls back to proot where chroot is unavailable or
# unprivileged. The runner has root so it uses chroot; a developer running from Termux
# gets proot instead.
#
#   bb_in_rootfs <stage> <command...>
bb_in_rootfs() {
    local stage=$1
    shift
    if [[ $(id -u) == 0 ]] && command -v chroot >/dev/null 2>&1; then
        chroot "$stage" /usr/bin/env \
            DEBIAN_FRONTEND=noninteractive \
            PATH=/usr/sbin:/usr/bin:/sbin:/bin \
            "$@"
    elif command -v proot >/dev/null 2>&1; then
        proot -q -r "$stage" -b /dev -b /proc -b /sys -w / \
            /usr/bin/env \
            DEBIAN_FRONTEND=noninteractive \
            PATH=/usr/sbin:/usr/bin:/sbin:/bin \
            "$@"
    else
        echo "Need root (for chroot) or proot to install packages into the rootfs." >&2
        return 69
    fi
}