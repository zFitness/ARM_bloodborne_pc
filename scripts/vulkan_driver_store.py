#!/usr/bin/env python3
"""Manage external Vulkan drivers for the rootfs runtime package."""

from __future__ import annotations

import argparse
import datetime as _dt
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tarfile
import tempfile
import zipfile


AARCH64 = 183
ANDROID_ONLY_LIBS = (
    b"libandroid.so",
    b"libbase.so",
    b"libcutils.so",
    b"libgui.so",
    b"libhardware.so",
    b"liblog.so",
    b"libnativewindow.so",
)


class DriverError(Exception):
    pass


def data_dir(env=os.environ) -> Path:
    if env.get("BB_DATA_DIR"):
        return Path(env["BB_DATA_DIR"])
    if env.get("XDG_DATA_HOME"):
        return Path(env["XDG_DATA_HOME"]) / "bbport"
    return Path(env.get("HOME", ".")) / ".local" / "share" / "bbport"


def store_dir(env=os.environ) -> Path:
    return Path(env["BB_DRIVER_STORE"]) if env.get("BB_DRIVER_STORE") else data_dir(env) / "drivers"


def sanitize_id(text: str) -> str:
    text = Path(text).name
    for suffix in (".tar.gz", ".tar.xz", ".tar.bz2", ".tar.zst", ".tgz", ".txz", ".zip"):
        if text.endswith(suffix):
            text = text[: -len(suffix)]
            break
    text = re.sub(r"[^A-Za-z0-9._-]+", "-", text.strip().lower()).strip("._-")
    return text or "driver"


def read_json(path: Path) -> dict:
    try:
        return json.loads(path.read_text())
    except Exception as exc:  # noqa: BLE001 - diagnostics include JSON parser details.
        raise DriverError(f"cannot parse JSON {path}: {exc}") from exc


def write_json(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")


def load_index(store: Path) -> dict:
    path = store / "index.json"
    if not path.exists():
        return {"drivers": {}}
    try:
        data = json.loads(path.read_text())
    except json.JSONDecodeError:
        return {"drivers": {}}
    if not isinstance(data.get("drivers"), dict):
        data["drivers"] = {}
    return data


def save_index(store: Path, data: dict) -> None:
    write_json(store / "index.json", data)


def selected_path(store: Path) -> Path:
    return store / "selected"


def safe_extract_zip(archive: Path, dest: Path) -> None:
    with zipfile.ZipFile(archive) as zf:
        for info in zf.infolist():
            target = (dest / info.filename).resolve()
            if not str(target).startswith(str(dest.resolve()) + os.sep):
                raise DriverError(f"unsafe archive member: {info.filename}")
        zf.extractall(dest)


def safe_extract_tar(archive: Path, dest: Path) -> None:
    try:
        with tarfile.open(archive) as tf:
            for member in tf.getmembers():
                target = (dest / member.name).resolve()
                if not str(target).startswith(str(dest.resolve()) + os.sep):
                    raise DriverError(f"unsafe archive member: {member.name}")
            tf.extractall(dest)
    except tarfile.TarError:
        try:
            subprocess.run(["tar", "-xf", str(archive), "-C", str(dest)], check=True)
        except (OSError, subprocess.CalledProcessError) as exc:
            raise DriverError(f"cannot extract {archive}: {exc}") from exc


def is_archive(path: Path) -> bool:
    name = path.name
    return name.endswith((".zip", ".tar", ".tar.gz", ".tgz", ".tar.xz", ".txz", ".tar.bz2", ".tbz2", ".tar.zst", ".tzst"))


def prepare_input(path: Path, temp: Path) -> Path:
    if path.is_dir():
        return path
    if not path.exists():
        raise DriverError(f"driver input does not exist: {path}")
    if not is_archive(path):
        raise DriverError(f"driver input must be a directory or archive: {path}")
    if path.name.endswith(".zip"):
        safe_extract_zip(path, temp)
    else:
        safe_extract_tar(path, temp)
    return temp


def has_android_markers(root: Path) -> bool:
    markers = {"meta.json", "adrenotools.json", "driver.json"}
    for item in root.rglob("*"):
        lower = item.name.lower()
        if lower in markers or "adrenotools" in lower or lower in {"arm64-v8a", "armeabi-v7a"}:
            return True
    return False


def icd_jsons(root: Path) -> list[Path]:
    candidates = []
    for path in root.rglob("*.json"):
        lower = str(path).lower()
        if "/icd.d/" in lower or "icd" in path.name.lower():
            candidates.append(path)
    if not candidates:
        for path in root.rglob("*.json"):
            try:
                data = read_json(path)
            except DriverError:
                continue
            if isinstance(data.get("ICD"), dict) and data["ICD"].get("library_path"):
                candidates.append(path)
    return sorted(set(candidates))


def resolve_library(root: Path, icd: Path, library_path: str) -> Path | None:
    lib = Path(library_path)
    probes = []
    if lib.is_absolute():
        probes.append(root / str(lib).lstrip("/"))
    else:
        probes.append(icd.parent / lib)
    probes.extend(p for p in root.rglob(lib.name) if p.is_file())
    for probe in probes:
        if probe.exists() and probe.is_file():
            return probe.resolve()
    return None


def elf_machine(path: Path) -> int | None:
    data = path.read_bytes()[:20]
    if len(data) < 20 or data[:4] != b"\x7fELF":
        return None
    if data[5] == 1:
        return int.from_bytes(data[18:20], "little")
    if data[5] == 2:
        return int.from_bytes(data[18:20], "big")
    return None


def android_only_library(path: Path) -> bytes | None:
    try:
        data = path.read_bytes()
    except OSError:
        return None
    for lib in ANDROID_ONLY_LIBS:
        if lib in data:
            return lib
    return None


def so_files(root: Path) -> list[Path]:
    files = []
    for path in root.rglob("*"):
        if path.is_file() and (path.name.endswith(".so") or ".so." in path.name):
            files.append(path)
    return files


def find_driver(root: Path) -> tuple[Path, dict, Path]:
    errors = []
    for icd in icd_jsons(root):
        try:
            data = read_json(icd)
        except DriverError as exc:
            errors.append(str(exc))
            continue
        library_path = data.get("ICD", {}).get("library_path")
        if not library_path:
            errors.append(f"{icd}: missing ICD.library_path")
            continue
        library = resolve_library(root, icd, str(library_path))
        if not library:
            errors.append(f"{icd}: missing driver library {library_path}")
            continue
        machine = elf_machine(library)
        if machine != AARCH64:
            arch = "not an ELF file" if machine is None else f"ELF machine {machine}"
            errors.append(f"{library}: expected aarch64 ELF, got {arch}")
            continue
        android_lib = android_only_library(library)
        if android_lib:
            errors.append(f"{library}: depends on Android-only {android_lib.decode()}")
            continue
        return icd.resolve(), data, library.resolve()
    if has_android_markers(root):
        raise DriverError(
            "Android/AdrenoTools-only driver package is not a Linux/rootfs Vulkan driver; "
            "choose a Linux/rootfs variant with ICD JSON and aarch64 driver libraries."
        )
    if errors:
        raise DriverError("; ".join(errors))
    raise DriverError("missing Linux Vulkan ICD JSON; choose a Linux/rootfs driver package")


def copy_tree_contents(src: Path, dst: Path) -> None:
    dst.mkdir(parents=True, exist_ok=True)
    for item in src.iterdir():
        target = dst / item.name
        if item.is_dir():
            shutil.copytree(item, target, symlinks=True)
        else:
            shutil.copy2(item, target, follow_symlinks=False)


def unique_driver_id(store: Path, base: str, explicit: bool, force: bool) -> str:
    driver_id = sanitize_id(base)
    if force or not (store / driver_id).exists():
        return driver_id
    if explicit:
        raise DriverError(f"driver id already exists: {driver_id} (use --force to replace)")
    suffix = 2
    while (store / f"{driver_id}-{suffix}").exists():
        suffix += 1
    return f"{driver_id}-{suffix}"


def import_driver(path: Path, *, env=os.environ, driver_id: str | None = None,
                  label: str | None = None, set_default: bool = True,
                  force: bool = False) -> dict:
    store = store_dir(env)
    store.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="bbport-driver-") as tmp_name:
        scan_root = prepare_input(path, Path(tmp_name)).resolve()
        icd, icd_data, library = find_driver(scan_root)
        base = driver_id or label or path.name
        final_id = unique_driver_id(store, base, driver_id is not None, force)
        target = store / final_id
        if target.exists():
            shutil.rmtree(target)
        source = target / "source"
        copy_tree_contents(scan_root, source)
        icd_rel = icd.relative_to(scan_root)
        lib_rel = library.relative_to(scan_root)
        copied_icd = source / icd_rel
        copied_lib = source / lib_rel
        normalized = target / "icd.d" / copied_icd.name
        icd_data = dict(icd_data)
        icd_data["ICD"] = dict(icd_data.get("ICD", {}))
        icd_data["ICD"]["library_path"] = str(copied_lib.resolve())
        write_json(normalized, icd_data)
        library_dirs = sorted({str(p.parent.resolve()) for p in so_files(source)} | {str(copied_lib.parent.resolve())})
        manifest = {
            "id": final_id,
            "label": label or final_id,
            "source": str(path),
            "imported_at": _dt.datetime.now(_dt.timezone.utc).isoformat(),
            "icd_json": str(normalized.resolve()),
            "library_path": str(copied_lib.resolve()),
            "library_search_paths": library_dirs,
            "notes": ["Linux/rootfs Vulkan ICD imported by bbport-driver."],
        }
        write_json(target / "manifest.json", manifest)
        index = load_index(store)
        index["drivers"][final_id] = {"manifest": str((target / "manifest.json").resolve()), "label": manifest["label"]}
        save_index(store, index)
        if set_default:
            selected_path(store).write_text(final_id + "\n")
        return manifest


def manifest_for(driver_id: str | None, *, env=os.environ) -> dict:
    store = store_dir(env)
    if not driver_id:
        selected = selected_path(store)
        if not selected.exists():
            raise DriverError(
                "no Vulkan driver selected. Import one with `bbport-driver import <driver.zip>` "
                "or set VK_DRIVER_FILES explicitly."
            )
        driver_id = selected.read_text().strip()
    index = load_index(store)
    entry = index.get("drivers", {}).get(driver_id)
    if not entry:
        raise DriverError(f"unknown Vulkan driver id: {driver_id}")
    manifest = read_json(Path(entry["manifest"]))
    icd = Path(manifest["icd_json"])
    if not icd.exists():
        raise DriverError(f"selected driver {driver_id} is missing ICD JSON: {icd}")
    return manifest


def list_drivers(*, env=os.environ) -> list[dict]:
    store = store_dir(env)
    index = load_index(store)
    current = selected_path(store).read_text().strip() if selected_path(store).exists() else ""
    items = []
    for driver_id, entry in sorted(index.get("drivers", {}).items()):
        try:
            manifest = read_json(Path(entry["manifest"]))
        except DriverError:
            manifest = {"id": driver_id, "label": entry.get("label", driver_id), "icd_json": "(missing)"}
        manifest["selected"] = driver_id == current
        items.append(manifest)
    return items


def remove_driver(driver_id: str, *, env=os.environ) -> None:
    store = store_dir(env)
    index = load_index(store)
    if driver_id not in index.get("drivers", {}):
        raise DriverError(f"unknown Vulkan driver id: {driver_id}")
    shutil.rmtree(store / driver_id, ignore_errors=True)
    del index["drivers"][driver_id]
    save_index(store, index)
    selected = selected_path(store)
    if selected.exists() and selected.read_text().strip() == driver_id:
        selected.unlink()


def select_driver(driver_id: str, *, env=os.environ) -> dict:
    manifest = manifest_for(driver_id, env=env)
    selected_path(store_dir(env)).write_text(driver_id + "\n")
    return manifest


def shell_env(manifest: dict) -> str:
    paths = ":".join(manifest.get("library_search_paths", []))
    return "\n".join((
        f"export VK_DRIVER_FILES={shlex.quote(manifest['icd_json'])}",
        f"BB_DRIVER_LD_LIBRARY_PATH={shlex.quote(paths)}",
        f"export BB_VULKAN_DRIVER_ID={shlex.quote(manifest['id'])}",
    ))


def cmd_import(args: argparse.Namespace) -> int:
    manifest = import_driver(Path(args.input), driver_id=args.id, label=args.label,
                             set_default=not args.no_select, force=args.force)
    print(f"Imported Vulkan driver {manifest['id']}")
    print(f"ICD: {manifest['icd_json']}")
    if not args.no_select:
        print(f"Selected: {manifest['id']}")
    else:
        print(f"Select with: bbport-driver select {manifest['id']}")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="bbport-driver")
    sub = parser.add_subparsers(dest="command", required=True)

    p_import = sub.add_parser("import", help="import a Linux/rootfs Vulkan driver")
    p_import.add_argument("input")
    p_import.add_argument("--id")
    p_import.add_argument("--label")
    p_import.add_argument("--force", action="store_true")
    p_import.add_argument("--no-select", action="store_true")
    p_import.set_defaults(func=cmd_import)

    p_list = sub.add_parser("list", help="list imported drivers")
    p_list.set_defaults(func=lambda args: print_driver_list() or 0)

    p_select = sub.add_parser("select", help="select the default driver")
    p_select.add_argument("id")
    p_select.set_defaults(func=lambda args: print_selected(select_driver(args.id)) or 0)

    p_current = sub.add_parser("current", help="show the selected driver")
    p_current.set_defaults(func=lambda args: print_selected(manifest_for(None)) or 0)

    p_remove = sub.add_parser("remove", help="remove an imported driver")
    p_remove.add_argument("id")
    p_remove.set_defaults(func=lambda args: remove_driver(args.id) or 0)

    p_env = sub.add_parser("env", help="print shell exports for a selected driver")
    p_env.add_argument("--id")
    p_env.set_defaults(func=lambda args: print(shell_env(manifest_for(args.id))) or 0)

    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except DriverError as exc:
        print(f"bbport-driver: {exc}", file=sys.stderr)
        return 1


def print_driver_list() -> None:
    drivers = list_drivers()
    if not drivers:
        print("No Vulkan drivers imported.")
        return
    for item in drivers:
        mark = "*" if item.get("selected") else " "
        print(f"{mark} {item['id']}  {item.get('label', item['id'])}  {item.get('icd_json', '')}")


def print_selected(manifest: dict) -> None:
    print(f"Driver: {manifest['id']}")
    print(f"ICD: {manifest['icd_json']}")
    if manifest.get("library_search_paths"):
        print("Library paths: " + ":".join(manifest["library_search_paths"]))


if __name__ == "__main__":
    raise SystemExit(main())
