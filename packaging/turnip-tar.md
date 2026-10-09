# Minimal Turnip Tar Package

`packaging/turnip-tar.sh` builds a rootfs/proot overlay archive for ARM64
Adreno devices using the bundled Turnip Vulkan driver. It is a separate package
path from the AppImage and is meant for environments where a GTK launcher,
Steam-specific handling and FSR asset tools are unnecessary.

Build on an aarch64 Linux host or runner:

```bash
bash build.sh
bash packaging/turnip-tar.sh
```

The output is:

```text
dist/Bloodborne-bbport-turnip-aarch64.tar.gz
```

The archive is intended to be extracted into a rootfs/proot tree. It installs
the runtime entry at:

```bash
/opt/bbport/bin/bbport-turnip
```

Run it with your own Bloodborne CUSA03173 v1.09 dump:

```bash
BB_GAME_DIR=/path/to/CUSA03173 /opt/bbport/bin/bbport-turnip
```

Useful environment variables:

- `BB_GAME_DIR`: Bloodborne dump directory containing `eboot.bin`.
- `BB_DATA_DIR`: writable directory for generated files, saves, settings and
  shader cache. Defaults to `~/.local/share/bbport`.
- `BB_TURNIP_ICD`: explicit replacement for the bundled Turnip ICD.
- `VK_DRIVER_FILES`: lower-level Vulkan ICD override. If unset, the wrapper
  uses the bundled Turnip ICD.
- `BBPORT_ROOT`: override the runtime root when testing outside `/opt/bbport`.

Diagnostics:

```bash
/opt/bbport/bin/bbport-turnip --vulkan-info
```

The package intentionally does not include:

- Bloodborne game files.
- GTK launcher or desktop files.
- AppImage or Steam overlay/fossilize entrypoints.
- MangoHud.
- Non-Turnip Vulkan ICD selection logic.
- `fsr4_shaders`, `fsr4_411`, `tools/fsr4cap`, FSR download scripts, or FSR
  4.1.1 DLL capture/extraction tools.

Validate a generated archive:

```bash
bash packaging/check-turnip-tar.sh dist/Bloodborne-bbport-turnip-aarch64.tar.gz
```

Device validation is still required for real releases. Record the device,
GPU, Mesa/Turnip version, rootfs/proot environment and startup log when testing
on hardware.
