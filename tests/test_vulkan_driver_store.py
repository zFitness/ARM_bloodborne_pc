"""External Vulkan driver import store tests."""

from paths import ROOT  # noqa: F401 - adds scripts/ to sys.path.
import json
from pathlib import Path
import tempfile
import unittest
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


if __name__ == "__main__":
    unittest.main()
