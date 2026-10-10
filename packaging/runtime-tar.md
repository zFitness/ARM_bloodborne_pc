# Driverless Runtime Tar Package

`packaging/runtime-tar.sh` builds a rootfs/proot overlay archive for ARM64
Android/Linux environments. The archive contains the bbport runtime and Vulkan
loader tooling, but it intentionally does not include Turnip or any other Vulkan
GPU driver.

Build on an aarch64 Linux host or runner:

```bash
bash build.sh
bash packaging/runtime-tar.sh
```

The output is:

```text
dist/Bloodborne-bbport-runtime-aarch64.tar.gz
```

The archive is intended to be extracted into a rootfs/proot tree. It installs
the runtime entry and driver manager at:

```bash
/opt/bbport/bin/bbport
/opt/bbport/bin/bbport-driver
```

Import a Linux/rootfs Vulkan driver before launching:

```bash
/opt/bbport/bin/bbport-driver import /path/to/linux-vulkan-driver.zip
BB_GAME_DIR=/path/to/CUSA03173 /opt/bbport/bin/bbport
```

`/opt/bbport/bin/bbport` is the single launch entry; the archive does not include a
`bbport-game` alias or a `bloodborne-launch` shim.

The archive ships `/opt/bbport/share/bbport/compat`, a directory of the libraries an
external Vulkan driver resolves at load time (wayland, zlib, zstd, libdrm, libxcb,
libX11-xcb, libxkbcommon, libstdc++, glibc, libxshmfence). The entry puts this directory
first on `LD_LIBRARY_PATH`, so an imported Linux/Turnip driver loads with no manual
library-path configuration and never mixes with older copies from the base rootfs.

An already-extracted rootfs from before this change does not contain `compat/`: rebuild the
runtime tar and rootfs, or add the same library links under `/opt/bbport/share/bbport/compat`
by hand.

Useful environment variables:

- `BB_GAME_DIR`: Bloodborne dump directory containing `eboot.bin`.
- `BB_DATA_DIR`: writable directory for generated files, saves, settings,
  shader cache and imported drivers. Defaults to `~/.local/share/bbport`.
- `BB_DRIVER_STORE`: explicit imported-driver store. Defaults to
  `$BB_DATA_DIR/drivers`.
- `BB_VULKAN_DRIVER_ID`: select one imported driver for this launch.
- `VK_DRIVER_FILES`: lower-level Vulkan ICD override. If unset, the wrapper
  uses the selected imported driver and fails when none is available.
- `BBPORT_ROOT`: override the runtime root when testing outside `/opt/bbport`.
- `BB_ANDROID_ROOTFS_PROFILE`: Android/rootfs performance profile. The packaged
  `/opt/bbport/bin/bbport` wrapper defaults it to `1`; set it to `0` for plain
  runtime defaults.

## Android rootfs performance profile

When `BB_ANDROID_ROOTFS_PROFILE=1`, the wrapper and `run.sh` fill conservative
mobile defaults only for variables the user did not set:

```text
BB_PREP_WORKERS=2
BB_COPY_THREADS=1
BB_VK_RECORD_THREADS=1
BB_PIPE_SPIN_US=20
BB_GPU_SPIN_US=0
BB_FRAMES_AHEAD=1
BB_FRAME_STATS=1
BB_PC_MODEL_PROBE_ANY_GPU=1
```

Every value remains a normal environment-variable override. For a stronger SoC,
try `BB_PREP_WORKERS=3` or `4` and `BB_VK_RECORD_THREADS=2`; for thermal or
frame-time stability, reduce worker counts before increasing frames ahead.

The profile tries to detect big cores from Linux CPU topology and exports
`BB_HOST_AFFINITY_CPUS` for the runtime. You can provide it yourself, for
example:

```bash
BB_HOST_AFFINITY_CPUS=4-7 BB_GAME_DIR=/games/CUSA03173 /opt/bbport/bin/bbport
```

Affinity and priority are best-effort: if the rootfs/proot environment does not
allow `sched_setaffinity`, `taskset` or nice changes, the game still starts and
prints a warning. Set `BB_ANDROID_ROOTFS_PROFILE=0` to disable the profile
entirely for comparison.

For startup-patched resolutions, 720p and 1080p keep the default PS4 direct
memory size unless `BB_DMEM_MB` is set by the user. Outputs above 1080p still
raise the default direct memory size for the high-resolution graphics heap path.

## Storage and cache placement

Keep `BB_GAME_DIR`, `BB_DATA_DIR`, shader cache and imported drivers on fast
rootfs storage, such as an ext4/f2fs directory inside the rootfs/proot
environment. Avoid `/sdcard`, `/storage/emulated/*` and FUSE-backed paths for
the game dump or cache, because slow read/write and mmap behavior can show up as
loading stutter or shader/pipeline cache stalls. The profile prints warnings for
known slow or unwritable paths but does not move user data automatically.

## PC memory model on Turnip-like drivers

`BB_PC_MODEL=1` selects the new memory and translation model. AMD GPUs are still
accepted directly. In the Android rootfs profile, non-AMD drivers use
`BB_PC_MODEL_PROBE_ANY_GPU=1`: the runtime first checks for exportable cached
system memory, dma-buf support and offset mmap behavior. If the probe fails,
direct memory stays on the compatible path and the log explains why.

`BB_PC_MODEL_ANY_GPU=1` remains a force switch for experiments. Use it only for
A/B testing and include the startup log when reporting issues.

Driver diagnostics:

```bash
/opt/bbport/bin/bbport-driver list
/opt/bbport/bin/bbport-driver current
/opt/bbport/bin/bbport --vulkan-info
```

Use Linux/rootfs driver packages that contain Vulkan ICD JSON files and aarch64
driver libraries. Android app or AdrenoTools-only driver packages are not Linux
ICD drivers; the importer rejects packages that only expose Android injection
metadata or Android-only ABI libraries.

The package intentionally does not include:

- Bloodborne game files.
- Vulkan GPU ICD JSON files or driver libraries.
- GTK launcher or desktop files.
- AppImage or Steam overlay/fossilize entrypoints.
- MangoHud.
- `fsr4_shaders`, `fsr4_411`, `tools/fsr4cap`, FSR download scripts, or FSR
  4.1.1 DLL capture/extraction tools.

Validate a generated archive:

```bash
bash packaging/check-runtime-tar.sh dist/Bloodborne-bbport-runtime-aarch64.tar.gz
```

Device validation is still required for real releases. Record the device, GPU,
driver source/version, rootfs/proot environment, startup log, Android rootfs
profile summary, key `BB_*` overrides, `BB_FRAME_STATS` output and whether
`BB_PC_MODEL=1` was enabled when testing on hardware.
