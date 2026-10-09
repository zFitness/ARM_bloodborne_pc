---
name: android-rootfs-runtime
description: "Use when a bbport Android rootfs build misbehaves around the Vulkan driver, libraries, display or audio: an imported driver that looks ineffective, \"Installed Vulkan doesn't implement the VK_KHR_surface extension\", missing libzstd/libffi, silent audio."
version: 1.0.0
author: zFitness
license: MIT
metadata:
  hermes:
    tags: [bbport, android, rootfs, vulkan, turnip, proot, termux, audio]
    related_skills: []
---

# bbport in the Android rootfs (proot + Termux:X11)

## Overview

The Android build runs the same runtime as the desktop build, inside a rootfs with a
`proot`-based Android host layer. Two library worlds coexist, and the loader only sees one of
them:

| | packaged closure (`@LD_LIBRARY_PATH@`, nix store) | rootfs system libraries (`/usr/lib`) |
|---|---|---|
| used by | the probe, the Vulkan loader, the Python tooling | the rootfs's glibc, `bb-probe`'s extra deps, imported ICDs |
| searched by | prepended by the wrapper | **not** searched by the closure's glibc |

An imported Linux/rootfs ICD (Mesa Turnip wants `libzstd`, `libxcb-*`, `libwayland-client`,
`libxshmfence`, ...) and `bb-probe` itself (`libffi`) resolve dependencies from the rootfs's
`/usr/lib`. Those directories must reach `LD_LIBRARY_PATH` right before the loader starts, or
the loader silently drops the ICD and every symptom points somewhere else.

## When to Use

- A driver imports successfully and the game then fails with
  `Failed to create window: Installed Vulkan doesn't implement the VK_KHR_surface extension`.
- The loader log shows `Failed loading library associated with ICD JSON ...: libzstd.so.1:
  cannot open shared object file`, or `bb-probe: libffi.so.8: cannot open shared object file`.
- You are changing anything about the Android driver store, the runtime wrapper, `run.sh`, the
  rootfs library path, or the audio path.
- You are reproducing an issue on a stock rootfs rather than a locally patched one.

Don't use for: game-side emulation/bug reports unrelated to the runtime (Vulkan rendering
bugs, FEXCore CPU issues, patch/content problems).

## Runtime layout

- `/opt/bbport/bin/bbport` — wrapper: resolves the driver env, `--vulkan-info`, then the
  library path, then `run.sh`.
- `/opt/bbport/bin/bbport-driver` — thin script that runs `$root/scripts/vulkan_driver_store.py`
  with the packaged Python, so it inherits the *caller's* library path, not the wrapper's.
- `/opt/bbport/share/bbport/{run.sh,scripts/,bin/bb-probe}` — the actual launcher and probe.
- Driver store `~/.local/share/bbport/drivers/<id>/{manifest.json,icd.d/,source/}`; the selected
  driver is the one `bbport-driver current` prints.

## Fix invariant

Append `BB_ANDROID_SYSTEM_LIBRARY_DIRS` (`/usr/local/lib:/usr/lib:/lib:/usr/lib64`) to
`LD_LIBRARY_PATH` via `bb_android_apply_library_path()`
(`scripts/android_rootfs_profile.sh`), called immediately before the loader starts — from
`run.sh` (after the Python tooling) and from `packaging/runtime-run.sh` (both the
`--vulkan-info` branch and the `run.sh` exec). The helper is idempotent, skips missing
directories and never prepends, so the closure and the imported driver's own directories keep
priority.

**Never apply it for the whole wrapper.** The packaged tooling runs on the closure's glibc and
the rootfs's older `/usr/lib/libm.so.6` has no `GLIBC_2.44`:

```
ImportError: /usr/lib/libm.so.6: version `GLIBC_2.44' not found
    (required by .../lib-dynload/math.cpython-314-aarch64-linux-gnu.so)
```

The same applies to `bbport --vulkan-info`: without the call in that branch it reports a
working imported driver as broken.

## Day-to-day commands (host = Termux)

```bash
# game (auto-extracts on first run; bundled proot + loader, Termux:X11 :0)
bash ~/run-bb-r1.sh
bash ~/run-bb-r1.sh /bin/sh                      # shell inside the guest

# import a Linux/rootfs ICD package (not an Android/AdrenoTools-only one), then check it
bash ~/run-bb-r1.sh /opt/bbport/bin/bbport-driver import "/storage/emulated/0/games/驱动/Turnip-v26.3.0-20261008-r2-Linux.zip"
bash ~/run-bb-r1.sh /opt/bbport/bin/bbport-driver current
bash ~/run-bb-r1.sh /opt/bbport/bin/bbport --vulkan-info

# audio: Termux pulseaudio (OpenSL ES sink) as the server, guest connects over TCP
bash ~/bb-audio.sh start | stop | status
```

Healthy game log:

```
Vulkan driver: imported <id> (.../icd.d/freedreno_icd.aarch64.json)
Bloodborne™ The Old Hunters Edition | entry=0xa0 | image=91,042,036 bytes
Runtime: audio backend pulseaudio     # without a server: "audio backend alsa" + "timer sink"
Frame pacing: median 16.7 ms          # ~60 FPS
```

## Verify a driver/library change

The discriminating check — `--vulkan-info` runs the real loader with the game's library path:

```bash
# fix ON (default) -> expect 0
timeout 200 env BB_GUEST_LD_LIBRARY_PATH= VK_LOADER_DEBUG=error bash ~/run-bb-r1.sh /opt/bbport/bin/bbport --vulkan-info 2>&1 \
  | grep -c 'Failed loading library associated with ICD JSON'

# fix OFF (simulate a stock rootfs) -> expect > 0
timeout 200 env BB_GUEST_LD_LIBRARY_PATH= BB_ANDROID_SYSTEM_LIBRARY_DIRS=/nonexistent VK_LOADER_DEBUG=error \
  bash ~/run-bb-r1.sh /opt/bbport/bin/bbport --vulkan-info 2>&1 | grep -c 'Failed loading library associated with ICD JSON'
```

`BB_GUEST_LD_LIBRARY_PATH=` is a launcher knob that drops its own fallback, so only the
runtime's path is tested. Then confirm a real run: the driver line appears, no `Failed loading
library associated with ICD JSON`, `bb-probe` stays alive, frame pacing lines keep coming.

Unit tests:

```bash
cd <repo> && python3 -m unittest discover -s tests -p 'test_android_rootfs_profile.py'
cd <repo> && python3 -m unittest discover -s tests -p 'test_vulkan_driver_store.py'
```

Note: `.github/workflows/` runs no tests, so these are manual gates; the ordering constraints
above (call site after the tooling, before `--vulkan-info` and the probe) are what a regression
breaks first.

## Common Pitfalls

1. **Trusting `ldd`/`ldconfig`.** `ldd` is the rootfs's script, and the rootfs's glibc searches
   `/usr/lib` by default, so it reports everything as found while the game still fails on the
   closure's glibc. Running `ldconfig` inside the rootfs even creates `/etc/ld.so.cache` and
   can make the failure vanish by accident — a stock rootfs has no such cache, so remove it
   (or use a fresh extraction) before claiming a reproduction. `bbport --vulkan-info` is the
   check that matches the game.
2. **Adding the directories too early** — see the `GLIBC_2.44` `ImportError` above.
3. **Assuming the driver is loadable because the import succeeded.** `bbport-driver import`
   records `unresolved_libraries` in the manifest and warns, but a driver whose dependencies
   are only reachable at game time differs from one that is genuinely incomplete.
4. **Forgetting that a driver must be imported and selected** before the game will use it;
   `bbport-driver list`/`current` show what is actually in effect.
5. **Android cannot create hard links** (`link(2)` -> EPERM): extracting a rootfs tar that
   contains hard links fails wholesale. Use a hard-link-free extractor or `tar
   --hard-dereference`.
6. **`/storage/emulated/0` cannot hold symlinks** and the rootfs has thousands: keep the rootfs
   on `/data`, archives on `/storage`.
7. **Leaking the host environment into the guest.** Set `HOME=/root` and a guest `PATH`
   (`/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin`) explicitly, otherwise
   `#!/usr/bin/env bash` fails with `env: 'bash': No such file or directory`.
8. **Using `$PREFIX/bin/proot`** instead of the rootfs's bundled
   `/opt/android-host/proot` + `PROOT_LOADER=/opt/android-host/loader`.
9. **Expecting audio to work out of the box.** Android gives the guest no `/dev/snd`, so ALSA
   falls back to a timer sink (silent). Use the Termux pulseaudio server with
   `PULSE_SERVER=tcp:127.0.0.1:4713` and `SDL_AUDIODRIVER=pulse`. The `*.so` files an APK
   injects under `arm64-v8a/` (PulseAudio stack, `libffi`, `libwayland-server`, `libltdl`) are
   **bionic** builds (`NEEDED libc.so`, not `libc.so.6`) plus a bionic `libpulseaudio.so`
   daemon — they belong to the Android side, not to the glibc guest.
10. **Reading too much into `--vulkan-info`.** A display/`KHR_display` error can still appear
    with the ICD loaded (no `/dev/dri`); it does not affect the game path.

## Verification Checklist

- [ ] `bash -n run.sh packaging/runtime-run.sh scripts/android_rootfs_profile.sh` clean
- [ ] `python3 -m py_compile scripts/vulkan_driver_store.py` clean
- [ ] `test_android_rootfs_profile.py` and `test_vulkan_driver_store.py` pass
- [ ] `bb_android_apply_defaults` does **not** touch `LD_LIBRARY_PATH` (regression guard)
- [ ] Every call site sits after the driver tooling and before `--vulkan-info` / the probe
- [ ] `--vulkan-info` A/B: 0 failures with the fix, > 0 without it
- [ ] A real game run reaches `Runtime:`/`Frame pacing:` with `bb-probe` alive
- [ ] Any patched rootfs copy mirrors the same ordering as the repo (they drift easily)
