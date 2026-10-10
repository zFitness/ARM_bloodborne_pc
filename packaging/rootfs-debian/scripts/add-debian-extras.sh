#!/usr/bin/env bash
# Installs the explicit runtime dependency set into a staged Debian rootfs.
#
#   add-debian-extras.sh <stage-dir>
#
# The list is deliberately explicit rather than inherited from debootstrap defaults, so
# the rootfs contents are predictable and "why is this package here" is answerable. It
# covers what bbport's binaries actually link against, plus the Vulkan loader the game
# needs at runtime.
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/common.sh"

stage="${1:-}"
[[ -n $stage ]] || { echo 'usage: add-debian-extras.sh <stage-dir>' >&2; exit 64; }

# C/C++ runtime: libbbgpu.so is a C++ library and needs libstdc++/libgcc_s.
# Vulkan loader: the game's graphics path, and the ICD loader any driver import needs.
# SDL3: input (gamepad, keyboard, touchpad) via src/runtime_pad.c.
# ffmpeg runtime libs: gpu/shadps4's avplayer decodes video streams through libav*.
# X11/wayland/xkbcommon: SDL3's own dependencies, pulled in for the input path.
# ca-certificates: keeps apt usable behind a proxy that rewrites certificates.
#
# Deliberately absent: any Vulkan ICD (mesa-vulkan-drivers, firmware). The driverless
# contract requires the user to install or import one explicitly.
extras=(
    libc6
    libstdc++6
    libgcc-s1
    libvulkan1
    vulkan-tools
    libsdl3-0
    libavformat61
    libavcodec61
    libavutil59
    libswscale8
    libswresample5
    libx11-6
    libxkbcommon0
    libwayland-client0
    ca-certificates
)

echo "== debian extras: installing ${#extras[@]} packages"
echo "   ${extras[*]}"

bb_in_rootfs "$stage" /usr/bin/apt-get update -qq
bb_in_rootfs "$stage" /usr/bin/apt-get install -y -qq --no-install-recommends "${extras[@]}"

# Record what actually landed, so the manifest can report it and verify-rootfs can check
# the critical ones are present.
bb_in_rootfs "$stage" /usr/bin/dpkg-query -W -f='${Package} ${Version}\n' \
    > "$stage/../extras-packages.txt"

echo "== debian extras: done"
wc -l < "$stage/../extras-packages.txt" | sed 's/^/   packages installed: /'