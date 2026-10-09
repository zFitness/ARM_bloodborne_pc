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
driver source/version, rootfs/proot environment and startup log when testing on
hardware.
