"""External Vulkan driver import store tests."""

from paths import ROOT  # noqa: F401 - adds scripts/ to sys.path.
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock
import zipfile

import vulkan_driver_store as drivers


def fake_elf(machine=drivers.AARCH64, extra=b""):
    header = bytearray(b"\x7fELF")
    header.extend([2, 1, 1, 0])
    header.extend(b"\0" * 10)
    header.extend(int(machine).to_bytes(2, "little"))
    header.extend(b"\0" * 44)
    header.extend(extra)
    return bytes(header)


class VulkanDriverStoreTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.env = {"BB_DATA_DIR": str(self.root / "data")}

    def make_driver(self, root, *, library="libvulkan_freedreno.so", machine=drivers.AARCH64,
                    library_path="../../../lib/libvulkan_freedreno.so", extra=b""):
        icd_dir = root / "share" / "vulkan" / "icd.d"
        lib_dir = root / "lib"
        icd_dir.mkdir(parents=True)
        lib_dir.mkdir()
        (lib_dir / library).write_bytes(fake_elf(machine, extra))
        icd = icd_dir / "freedreno_icd.aarch64.json"
        icd.write_text(json.dumps({"file_format_version": "1.0.0", "ICD": {
            "library_path": library_path,
            "api_version": "1.3.0",
        }}))
        return icd, lib_dir / library

    def test_import_directory_normalizes_icd_and_selects_driver(self):
        source = self.root / "driver"
        self.make_driver(source)

        manifest = drivers.import_driver(source, env=self.env, driver_id="turnip-linux")

        self.assertEqual(manifest["id"], "turnip-linux")
        self.assertEqual(drivers.manifest_for(None, env=self.env)["id"], "turnip-linux")
        normalized = Path(manifest["icd_json"])
        self.assertTrue(normalized.exists())
        data = json.loads(normalized.read_text())
        self.assertTrue(Path(data["ICD"]["library_path"]).is_absolute())
        self.assertTrue(Path(data["ICD"]["library_path"]).exists())
        self.assertIn(str(Path(data["ICD"]["library_path"]).parent), manifest["library_search_paths"])

    def test_import_zip_archive(self):
        source = self.root / "zip-driver"
        self.make_driver(source)
        archive = self.root / "driver.zip"
        with zipfile.ZipFile(archive, "w") as zf:
            for path in source.rglob("*"):
                if path.is_file():
                    zf.write(path, path.relative_to(source))

        manifest = drivers.import_driver(archive, env=self.env, driver_id="zipdrv")

        self.assertEqual(manifest["id"], "zipdrv")
        self.assertTrue(Path(manifest["icd_json"]).exists())

    def test_env_output_uses_selected_driver(self):
        source = self.root / "driver"
        self.make_driver(source)
        drivers.import_driver(source, env=self.env, driver_id="drv")

        output = drivers.shell_env(drivers.manifest_for(None, env=self.env))

        self.assertIn("export VK_DRIVER_FILES=", output)
        self.assertIn("BB_DRIVER_LD_LIBRARY_PATH=", output)
        self.assertIn("export BB_VULKAN_DRIVER_ID=drv", output)

    def test_rejects_missing_icd(self):
        source = self.root / "missing-icd"
        (source / "lib").mkdir(parents=True)
        (source / "lib" / "libvulkan_freedreno.so").write_bytes(fake_elf())

        with self.assertRaisesRegex(drivers.DriverError, "missing Linux Vulkan ICD JSON"):
            drivers.import_driver(source, env=self.env)

    def test_rejects_missing_library(self):
        source = self.root / "missing-library"
        self.make_driver(source, library_path="../../../lib/missing.so")

        with self.assertRaisesRegex(drivers.DriverError, "missing driver library"):
            drivers.import_driver(source, env=self.env)

    def test_rejects_wrong_architecture(self):
        source = self.root / "wrong-arch"
        self.make_driver(source, machine=62)

        with self.assertRaisesRegex(drivers.DriverError, "expected aarch64 ELF"):
            drivers.import_driver(source, env=self.env)

    def test_rejects_android_only_package_without_linux_icd(self):
        source = self.root / "android-package"
        source.mkdir()
        (source / "meta.json").write_text("{}")
        (source / "arm64-v8a").mkdir()
        (source / "arm64-v8a" / "libvulkan_freedreno.so").write_bytes(fake_elf())

        with self.assertRaisesRegex(drivers.DriverError, "Android/AdrenoTools-only"):
            drivers.import_driver(source, env=self.env)

    def test_rejects_android_only_library_dependency(self):
        source = self.root / "android-lib"
        self.make_driver(source, extra=b"\0liblog.so\0")

        with self.assertRaisesRegex(drivers.DriverError, "Android-only liblog.so"):
            drivers.import_driver(source, env=self.env)

    def test_remove_clears_selected_driver(self):
        source = self.root / "driver"
        self.make_driver(source)
        drivers.import_driver(source, env=self.env, driver_id="drv")

        drivers.remove_driver("drv", env=self.env)

        self.assertEqual(drivers.list_drivers(env=self.env), [])
        with self.assertRaisesRegex(drivers.DriverError, "no Vulkan driver selected"):
            drivers.manifest_for(None, env=self.env)

    def test_import_records_unresolved_libraries(self):
        source = self.root / "driver"
        self.make_driver(source)

        manifest = drivers.import_driver(source, env=self.env, driver_id="drv")

        # Kept even when empty so the manifest schema is stable.
        self.assertEqual(manifest["unresolved_libraries"], [])

    def test_import_reports_libraries_the_loader_cannot_resolve(self):
        source = self.root / "driver"
        self.make_driver(source)
        result = subprocess.CompletedProcess(
            args=["ldd"], returncode=0,
            stdout="\tlibzstd.so.1 => not found\n\tlibc.so.6 => /usr/lib/libc.so.6\n",
            stderr="")
        with mock.patch.object(drivers.shutil, "which", return_value="/usr/bin/ldd"), \
                mock.patch.object(drivers.subprocess, "run", return_value=result):
            manifest = drivers.import_driver(source, env=self.env, driver_id="drv")

        self.assertEqual(manifest["unresolved_libraries"], ["libzstd.so.1"])
        self.assertTrue(any("libzstd.so.1" in note for note in manifest["notes"]))

    def test_unresolved_libraries_is_quiet_without_ldd(self):
        with mock.patch.object(drivers.shutil, "which", return_value=None):
            self.assertEqual(drivers.unresolved_libraries(Path("/nonexistent/lib.so")), [])

    def test_unresolved_libraries_checks_with_the_profile_library_path(self):
        """The check must mirror the game's library path, or it warns about libs that resolve."""
        libdir = self.root / "syslib"
        libdir.mkdir()
        env = {"LD_LIBRARY_PATH": "/closure/lib",
               "BB_ANDROID_SYSTEM_LIBRARY_DIRS": f"{libdir}:{self.root / 'absent'}"}
        captured = {}

        def fake_run(argv, **kwargs):
            captured["env"] = kwargs.get("env", {})
            return subprocess.CompletedProcess(argv, 0, stdout="", stderr="")

        with mock.patch.object(drivers.shutil, "which", return_value="/usr/bin/ldd"), \
                mock.patch.object(drivers.subprocess, "run", side_effect=fake_run):
            drivers.unresolved_libraries(Path("/nowhere/lib.so"), env=env)

        self.assertEqual(captured["env"]["LD_LIBRARY_PATH"], f"/closure/lib:{libdir}")


if __name__ == "__main__":
    unittest.main()
