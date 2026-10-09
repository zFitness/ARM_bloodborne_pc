# DroidDeck rootfs packaging

This directory builds the DroidDeck-compatible Bloodborne runtime rootfs from
this repository.

The pipeline is:

1. Build the aarch64 bbport runtime tar with `packaging/runtime-tar.sh`.
2. Convert that runtime tar to a rootfs-relative `/opt/bbport` layer.
3. Download or use a supplied DroidDeck base `linuxfs.tar.zst`.
4. Apply the Bloodborne launcher overlay.
5. Pack the combined rootfs and write a manifest.

The output files are:

```text
dist/bloodborne-droid-rootfs-aarch64-<version>.tar.zst
dist/bloodborne-droid-rootfs-aarch64-<version>.json
```

## Local build

Build on an aarch64 Linux host or runner:

```bash
bash build.sh
bash packaging/runtime-tar.sh
BLOODBORNE_ROOTFS_VERSION=dev \
BBPORT_RUNTIME_TARBALL=dist/Bloodborne-bbport-runtime-aarch64.tar.gz \
  bash packaging/rootfs/scripts/build-rootfs.sh
```

If `BBPORT_RUNTIME_TARBALL` is not set, `build-rootfs.sh` uses
`dist/Bloodborne-bbport-runtime-aarch64.tar.gz` when it exists.

To avoid downloading the DroidDeck base during tests, pass a local base archive:

```bash
BASE_ARCHIVE=/path/to/linuxfs.tar.zst \
BASE_VERSION=local \
BBPORT_RUNTIME_TARBALL=dist/Bloodborne-bbport-runtime-aarch64.tar.gz \
  bash packaging/rootfs/scripts/build-rootfs.sh
```

Run the lightweight packaging test without a real DroidDeck base or real
runtime:

```bash
bash packaging/rootfs/scripts/test-build-rootfs.sh
```

## GitHub Actions

`.github/workflows/rootfs.yml` builds the bbport runtime tar first, then packages
the combined rootfs from the same checkout. The workflow uploads both rootfs
files to the requested GitHub Release tag:

```text
dist/bloodborne-droid-rootfs-aarch64-<version>.tar.zst
dist/bloodborne-droid-rootfs-aarch64-<version>.json
```
