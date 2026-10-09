"""Android rootfs profile: the rootfs's system libraries reach the loader, and only there.

Importing a Linux/rootfs Vulkan driver only works if the loader can resolve the ICD's
dependencies (Mesa Turnip: libzstd, libxcb-*, libwayland-client, ...) and the prebuilt
bb-probe's own (libffi): the wrapper's library path covers the packaged closure only, and
that closure's glibc does not search /usr/lib.

The directories must NOT be added for the whole wrapper: the packaged tooling (bbport-driver
is Python) runs on the closure's glibc and the rootfs's older /usr/lib/libm.so.6 has no
GLIBC_2.44, so it dies with "ImportError: /usr/lib/libm.so.6: version `GLIBC_2.44' not
found". Only the game/loader start gets them (run.sh, packaging/runtime-run.sh).
"""
from paths import ROOT
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

PROFILE = ROOT / "scripts" / "android_rootfs_profile.sh"


def run_profile(body: str, env: dict) -> subprocess.CompletedProcess:
    """Source the profile script and run body, like the rootfs wrapper and run.sh do."""
    script = f"set -euo pipefail\nsource {PROFILE!s}\n{body}\n"
    base = {k: v for k, v in os.environ.items()
            if not k.startswith(("BB_ANDROID", "LD_LIBRARY_PATH"))}
    base.update(env)
    return subprocess.run(["bash", "-c", script], capture_output=True, text=True, env=base)


DEFAULTS = "bb_android_apply_defaults\nprintf 'PATH=%s\\n' \"${LD_LIBRARY_PATH:-}\"\n"


class AndroidRootfsProfileTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.libs = []
        for name in ("lib-a", "lib-b"):
            path = self.root / name
            path.mkdir()
            self.libs.append(str(path))

    def library_dirs(self, *extra: str) -> str:
        return ":".join([*self.libs, *extra])

    def apply(self, env: dict) -> subprocess.CompletedProcess:
        body = ("bb_android_apply_library_path\n"
                "printf 'PATH=%s\\n' \"${LD_LIBRARY_PATH:-}\"\n")
        return run_profile(body, env)

    def test_system_library_directories_are_appended(self):
        result = self.apply({
            "BB_ANDROID_ROOTFS_PROFILE": "1",
            "LD_LIBRARY_PATH": "/closure/lib",
            "BB_ANDROID_SYSTEM_LIBRARY_DIRS": self.library_dirs(),
        })

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("PATH=/closure/lib:" + ":".join(self.libs), result.stdout)

    def test_missing_directories_are_skipped(self):
        result = self.apply({
            "BB_ANDROID_ROOTFS_PROFILE": "1",
            "LD_LIBRARY_PATH": "/closure/lib",
            "BB_ANDROID_SYSTEM_LIBRARY_DIRS": self.library_dirs(str(self.root / "absent")),
        })

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("PATH=/closure/lib:" + ":".join(self.libs) + "\n", result.stdout)
        self.assertNotIn("absent", result.stdout)

    def test_already_present_directory_is_not_duplicated(self):
        result = self.apply({
            "BB_ANDROID_ROOTFS_PROFILE": "1",
            "LD_LIBRARY_PATH": f"/closure/lib:{self.libs[0]}",
            "BB_ANDROID_SYSTEM_LIBRARY_DIRS": self.library_dirs(),
        })

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"PATH=/closure/lib:{self.libs[0]}:{self.libs[1]}\n", result.stdout)
        self.assertEqual(result.stdout.count(self.libs[0]), 1)

    def test_disabled_profile_leaves_library_path_alone(self):
        result = self.apply({
            "BB_ANDROID_ROOTFS_PROFILE": "0",
            "LD_LIBRARY_PATH": "/closure/lib",
            "BB_ANDROID_SYSTEM_LIBRARY_DIRS": self.library_dirs(),
        })

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("PATH=/closure/lib\n", result.stdout)

    def test_apply_library_path_is_idempotent(self):
        body = ("bb_android_apply_library_path\n"
                "bb_android_apply_library_path\n"
                "printf 'PATH=%s\\n' \"${LD_LIBRARY_PATH:-}\"\n")
        result = run_profile(body, {
            "BB_ANDROID_ROOTFS_PROFILE": "1",
            "LD_LIBRARY_PATH": "/closure/lib",
            "BB_ANDROID_SYSTEM_LIBRARY_DIRS": self.library_dirs(),
        })

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("PATH=/closure/lib:" + ":".join(self.libs) + "\n", result.stdout)

    def test_empty_configuration_adds_nothing(self):
        result = self.apply({
            "BB_ANDROID_ROOTFS_PROFILE": "1",
            "LD_LIBRARY_PATH": "/closure/lib",
            "BB_ANDROID_SYSTEM_LIBRARY_DIRS": "",
        })

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("PATH=/closure/lib\n", result.stdout)

    def test_defaults_do_not_touch_the_library_path(self):
        """The tooling in the wrapper (Python on the closure's glibc) must stay unaffected."""
        result = run_profile(DEFAULTS, {
            "BB_ANDROID_ROOTFS_PROFILE": "1",
            "LD_LIBRARY_PATH": "/closure/lib",
            "BB_ANDROID_SYSTEM_LIBRARY_DIRS": self.library_dirs(),
        })

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("PATH=/closure/lib\n", result.stdout)

    def test_system_library_dirs_variable_is_exported(self):
        body = ("printf 'DIRS=%s\\n' \"$(env | grep '^BB_ANDROID_SYSTEM_LIBRARY_DIRS=' | cut -d= -f2)\"\n"
                "printf 'PATH=%s\\n' \"${LD_LIBRARY_PATH:-}\"\n")
        result = run_profile(body, {
            "BB_ANDROID_ROOTFS_PROFILE": "1",
            "LD_LIBRARY_PATH": "/closure/lib",
            "BB_ANDROID_SYSTEM_LIBRARY_DIRS": self.library_dirs(),
        })

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("DIRS=" + self.library_dirs(), result.stdout)


if __name__ == "__main__":
    unittest.main()
