# Self-sufficient aarch64 rootfs built with Nix. Unlike the runtime-tar overlay
# (which assumes the host rootfs has /usr/lib with libffi, libxcb, libwayland,
# libzstd and a working /etc), this derivation bundles everything bbport needs
# to run standalone under proot: bash, coreutils, python3, the Vulkan loader,
# the bbport closure, and the libraries a Mesa Turnip driver dynamically links
# against. The driver itself is still NOT bundled — the user imports it.
#
# The output is a derivation tree at $out. The build script collects $out plus
# the derivation's runtime closure (nix-store -qR) and packs them into a
# tar.zst. The result extracts to a directory the user enters with
#
#   proot -r <extract-dir> /opt/bbport/bin/bbport
#
# Why this exists: a previous pipeline layered this same runtime-tar on top of
# a Debian base built by debootstrap, but the Debian glibc is older than what
# the Nix-built libbbgpu.so was linked against (glibc 2.41 vs 2.44). The two
# could not coexist in one process, so the pipeline had to drag the entire
# nix closure into the Debian rootfs, defeating the point of a smaller base.
# This derivation sidesteps the problem by skipping the Debian layer entirely
# and producing a self-sufficient rootfs that the Nix-built bbport can load
# directly.
{ pkgs ? import <nixpkgs> { }
  # Store paths the prebuilt bbport ELF RUNPATHs reference, written by
  # packaging/runtime-tar.sh. nix-rootfs uses the same list because the bbport
  # binaries are identical.
, runtimePaths ? (if builtins.pathExists ./runtime-paths.nix then import ./runtime-paths.nix else [ ])
}:
let
  lib = pkgs.lib;
  arm = pkgs.stdenv.hostPlatform.isAarch64;
  root = ./..;
  src = builtins.path {
    name = "bbport-nix-rootfs-src";
    path = root;
    filter = path: type:
      let rel = lib.removePrefix (toString root + "/") (toString path);
      in builtins.elem rel [ "run.sh" ]
        || lib.any (dir: rel == dir || lib.hasPrefix (dir + "/") rel) [ "scripts" "patches" ];
  };
  python = pkgs.python3;
  runtimeStorePaths = map builtins.storePath runtimePaths;
  # Self-sufficient closure: the libraries the runtime-tar overlay expected the
  # host rootfs to provide. libxcb is included explicitly even though libx11
  # depends on it, so the bb-port-bundled Mesa driver import path resolves
  # libxcb without the user adding /usr/lib to LD_LIBRARY_PATH.
  runtimeLibPath = lib.makeLibraryPath ([
    pkgs.vulkan-loader
    pkgs.libglvnd
    pkgs.libx11
    pkgs.libxext
    pkgs.libxcb
    pkgs.wayland
    pkgs.libffi
    pkgs.zstd
  ] ++ runtimeStorePaths);
  runtimePath = lib.makeBinPath [
    pkgs.bash
    pkgs.coreutils
    pkgs.gnugrep
    pkgs.gnused
    pkgs.procps
    pkgs.util-linux
  ];
in
if !arm then
  throw "self-sufficient Nix rootfs packaging must be built for an aarch64-linux host/runner"
else
pkgs.stdenv.mkDerivation {
  pname = "bbport-nix-rootfs";
  version = "0.1";
  inherit src;
  # Adding bash / vulkan-loader to buildInputs pulls them into the runtime
  # closure. runtimeStorePaths covers the bbport-specific deps.
  buildInputs = [ pkgs.bash pkgs.vulkan-loader pkgs.vulkan-tools ] ++ runtimeStorePaths;
  dontBuild = true;
  dontConfigure = true;
  # dontPatchELF: bbport already carries Nix-style absolute RUNPATHs. Letting
  # the generic fixup phase rewrite them would break the layout.
  dontPatchELF = true;
  dontWrapGApps = true;

  installPhase = ''
    runHook preInstall
    d=$out/opt/bbport/share/bbport
    mkdir -p $d/bin/gpu $d/bin/cpu $out/opt/bbport/bin

    cp run.sh $d/
    cp -r scripts patches $d/
    install -m755 ${../out/bb-probe} $d/bin/bb-probe
    install -m755 ${../out/bb-gpu-capabilities} $d/bin/bb-gpu-capabilities
    install -m755 ${../out/gpu/libbbgpu.so} $d/bin/gpu/libbbgpu.so
    install -m755 ${../out/fex/libbbcpu.so} $d/bin/cpu/libbbcpu.so

    substitute ${./runtime-run.sh} $out/opt/bbport/bin/bbport \
      --replace-fail @PYTHON@ ${python}/bin/python3 \
      --replace-fail @PATH@ ${runtimePath} \
      --replace-fail @LD_LIBRARY_PATH@ ${runtimeLibPath} \
      --replace-fail @VULKANINFO@ ${pkgs.vulkan-tools}/bin/vulkaninfo \
      --replace-fail @BASH@ ${pkgs.bash}/bin/bash
    chmod +x $out/opt/bbport/bin/bbport

    substitute ${./runtime-driver.sh} $out/opt/bbport/bin/bbport-driver \
      --replace-fail @PYTHON@ ${python}/bin/python3
    chmod +x $out/opt/bbport/bin/bbport-driver

    # Minimal /etc. Without these, getpwnam and gethostbyname inside the
    # rootfs fail with "unknown user" / "no such host" and bbport's Python
    # scripts bail out before the game even starts. The contents match what
    # proot-distro's debian ships by default for a single-user system.
    mkdir -p $out/etc
    printf 'root:x:0:0:root:/root:/bin/sh\n' > $out/etc/passwd
    printf 'root:x:0:\n'                   > $out/etc/group
    cat > $out/etc/nsswitch.conf <<'NSS'
passwd:      files
group:       files
hosts:       files dns
NSS
    : > $out/etc/hosts
    : > $out/etc/resolv.conf

    # The wrapper execs bash and /usr/bin/env. Without these symlinks the
    # runtime fails with "exec format error" or "not found" inside proot.
    mkdir -p $out/bin $out/usr/bin
    ln -s ${pkgs.bash}/bin/bash        $out/bin/sh
    ln -s ${pkgs.bash}/bin/bash        $out/bin/bash
    ln -s ${pkgs.coreutils}/bin/env    $out/usr/bin/env

    cat > $out/opt/bbport/README-nix-rootfs.txt <<'DOC'
bbport self-sufficient Nix rootfs

A proot/chroot-ready rootfs containing the bbport runtime and its Nix closure.

Usage:

    proot -r <extract-dir> /opt/bbport/bin/bbport

The rootfs bundles bash, coreutils, python3, the Vulkan loader, libxcb,
libwayland, libffi, libzstd, and the bbport runtime closure. It does NOT
include a Vulkan GPU driver. Import one with:

    proot -r <extract-dir> /opt/bbport/bin/bbport-driver import <driver.zip>

Then launch the game with:

    proot -r <extract-dir> /opt/bbport/bin/bbport

Useful environment variables:

    BB_GAME_DIR=/path/to/CUSA03173
    BB_DATA_DIR=/path/to/writable/data
    BB_ANDROID_ROOTFS_PROFILE=0    disable the Android perf profile
DOC

    runHook postInstall
  '';
}
