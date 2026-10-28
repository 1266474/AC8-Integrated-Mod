"""Version-pinned PW-MkI RGL compatibility patch; offline single-player only.

prepare (the default) writes only the workspace. apply/rollback refuse to run
while AceCombat8 is running, and refuse unknown or user-modified target files.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import io
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
from typing import Any


PROJECT_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_MODS_ROOT = Path(os.environ.get("LOCALAPPDATA", str(Path.home() / "AppData/Local"))) / "Programs/AC8 Integrated/data/ue4ss-mods"
DLL_RELATIVE = Path("AC8OverrideLoader/dlls/main.dll")
LUA_RELATIVE = Path("PWMkI/Scripts/runtime/pw-rgl-reticle-v32.lua")
DLL_ORIGINAL_SHA256 = "ba01a751ea0f09f1b0a2f4a73c758389b59f8ad30973293d4ac7cec0d48c9e28"
DLL_PATCHED_SHA256 = "54fc41b68ed8f83d8fd6051dc0de06da2495697b0eb46b0be49de4063dfe415d"
LUA_ORIGINAL_SHA256 = "0037e2635d89c9f327e44161b03aa8892fd45a802c3eb2bb4a8880030027ace1"
DLL_LIMIT_OFFSET = 0x205C4
LUA_OLD = b" assert(type(half)=='number'and half>=.1 and half<=60,'MSL acquisition angle unavailable')"
LUA_NEW = b" assert(type(half)=='number'and half==half and math.abs(half)<math.huge and half>=.1 and half<=180,'MSL acquisition angle unavailable')"
# Filled from the pinned input and its exact replacement; verified in tests.
LUA_PATCHED_SHA256 = "36aa59558bf77aeb24ca15fcd44035b23e14e47d7a47df90e75baad217a2e37b"
PATCH_ID = "pwmki-1.2.0-rgl-enhanced-angle-v1"


class PatchError(RuntimeError):
    """A failed precondition; no unknown bytes may be overwritten."""


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def specifications() -> tuple[dict[str, Any], ...]:
    return (
        {"relative": DLL_RELATIVE, "original": DLL_ORIGINAL_SHA256, "patched": DLL_PATCHED_SHA256},
        {"relative": LUA_RELATIVE, "original": LUA_ORIGINAL_SHA256, "patched": LUA_PATCHED_SHA256},
    )


def build_patch(relative: Path, original: bytes) -> bytes:
    spec = next((item for item in specifications() if item["relative"] == relative), None)
    if spec is None or sha256(original) != spec["original"]:
        raise PatchError(f"Unknown original version: {relative}")
    if relative == DLL_RELATIVE:
        expected = struct.pack("<f", 60.0)
        if original[DLL_LIMIT_OFFSET:DLL_LIMIT_OFFSET + 4] != expected:
            raise PatchError("The native 60-degree limit signature does not match.")
        patched = original[:DLL_LIMIT_OFFSET] + struct.pack("<f", 180.0) + original[DLL_LIMIT_OFFSET + 4:]
        changes = [index for index, (before, after) in enumerate(zip(original, patched)) if before != after]
        if changes != [0x205C6, 0x205C7] or len(original) != len(patched):
            raise PatchError("Unexpected native binary changes.")
    else:
        if original.count(LUA_OLD) != 1:
            raise PatchError("The original Lua angle validation signature does not match.")
        patched = original.replace(LUA_OLD, LUA_NEW, 1)
    if sha256(patched) != spec["patched"]:
        raise PatchError(f"Patched output hash mismatch: {relative}")
    return patched


def atomic_write(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temp_name: str | None = None
    try:
        with tempfile.NamedTemporaryFile(mode="wb", prefix=f".{path.name}.railgun-", suffix=".tmp", dir=path.parent, delete=False) as handle:
            temp_name = handle.name
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp_name, path)
        temp_name = None
    finally:
        if temp_name:
            Path(temp_name).unlink(missing_ok=True)


def running_game_processes() -> list[str]:
    if os.name == "nt":
        try:
            result = subprocess.run(["tasklist", "/FO", "CSV", "/NH"], capture_output=True, text=True, check=True, timeout=20)
        except (OSError, subprocess.SubprocessError) as exc:
            raise PatchError(f"Cannot verify that AceCombat8 has exited: {exc}") from exc
        rows = csv.reader(io.StringIO(result.stdout))
        return [row[0] for row in rows if row and row[0].casefold().startswith("acecombat8")]
    try:
        result = subprocess.run(["ps", "-A", "-o", "comm="], capture_output=True, text=True, check=True, timeout=20)
    except (OSError, subprocess.SubprocessError) as exc:
        raise PatchError(f"Cannot verify that AceCombat8 has exited: {exc}") from exc
    return [line.strip() for line in result.stdout.splitlines() if Path(line.strip()).name.casefold().startswith("acecombat8")]


def require_game_closed() -> None:
    processes = running_game_processes()
    if processes:
        raise PatchError("Close AceCombat8 before changing Mod files: " + ", ".join(processes))


def classify(spec: dict[str, Any], data: bytes) -> str:
    digest = sha256(data)
    if digest == spec["original"]:
        return "original"
    if digest == spec["patched"]:
        return "patched"
    raise PatchError(f"Unknown or modified target: {spec['relative']} (sha256={digest})")


def inspect_targets(mods_root: Path) -> list[dict[str, Any]]:
    targets = []
    for spec in specifications():
        path = mods_root / spec["relative"]
        if path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(mods_root.resolve()):
            raise PatchError(f"Required regular target file missing: {path}")
        data = path.read_bytes()
        targets.append({"spec": spec, "path": path, "data": data, "state": classify(spec, data)})
    return targets


def manifest_path(workspace: Path) -> Path:
    return workspace / "backups/railgun/manifest.json"


def original_path(workspace: Path, relative: Path) -> Path:
    return workspace / "backups/railgun/originals" / relative


def staged_path(workspace: Path, relative: Path) -> Path:
    return workspace / "patches/railgun" / relative


def make_manifest(mods_root: Path) -> dict[str, Any]:
    return {
        "schema": 1,
        "patch_id": PATCH_ID,
        "mods_root": str(mods_root.resolve()),
        "native_change": {"offset": "0x205C4", "before_hex": "00007042", "after_hex": "00003443", "half_angle_limit_degrees": 180},
        "files": [{"relative": item["relative"].as_posix(), "original_sha256": item["original"], "patched_sha256": item["patched"]} for item in specifications()],
    }


def load_manifest(workspace: Path, mods_root: Path) -> dict[str, Any]:
    path = manifest_path(workspace)
    try:
        actual = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise PatchError(f"Prepare a verified backup first: {path}") from exc
    expected = make_manifest(mods_root)
    # Bind backups to the installation that was explicitly prepared.
    if actual != expected:
        raise PatchError("The backup manifest does not match this tool version and installation.")
    for item in specifications():
        backup = original_path(workspace, item["relative"])
        if not backup.is_file() or sha256(backup.read_bytes()) != item["original"]:
            raise PatchError(f"Original backup missing or modified: {backup}")
    return actual


def prepare(mods_root: Path, workspace: Path) -> dict[str, Any]:
    targets = inspect_targets(mods_root)
    desired_manifest = make_manifest(mods_root)
    existing_manifest = manifest_path(workspace)
    if existing_manifest.exists():
        load_manifest(workspace, mods_root)
    elif any(item["state"] == "patched" for item in targets):
        raise PatchError("Patched targets have no verified original backup in this workspace.")
    originals: list[tuple[dict[str, Any], bytes]] = []
    for target in targets:
        spec = target["spec"]
        original = target["data"] if target["state"] == "original" else original_path(workspace, spec["relative"]).read_bytes()
        if sha256(original) != spec["original"]:
            raise PatchError("Original backup hash mismatch.")
        backup = original_path(workspace, spec["relative"])
        if backup.exists() and sha256(backup.read_bytes()) != spec["original"]:
            raise PatchError(f"Refusing to overwrite a modified backup: {backup}")
        originals.append((spec, original))
    # All source versions and backups have been checked before writing artifacts.
    for spec, original in originals:
        backup = original_path(workspace, spec["relative"])
        if not backup.exists():
            atomic_write(backup, original)
        atomic_write(staged_path(workspace, spec["relative"]), build_patch(spec["relative"], original))
    atomic_write(existing_manifest, (json.dumps(desired_manifest, ensure_ascii=False, indent=2) + "\n").encode("utf-8"))
    atomic_write(workspace / "patches/railgun/manifest.json", (json.dumps(desired_manifest, ensure_ascii=False, indent=2) + "\n").encode("utf-8"))
    return {"operation": "prepare", "installation_changed": False, "manifest": str(existing_manifest), "patches": str(workspace / "patches/railgun"), "files": desired_manifest["files"]}


def check(mods_root: Path) -> dict[str, Any]:
    targets = inspect_targets(mods_root)
    return {"operation": "check", "all_patched": all(item["state"] == "patched" for item in targets), "files": [{"path": str(item["path"]), "state": item["state"], "sha256": sha256(item["data"])} for item in targets]}


def change_targets(mods_root: Path, workspace: Path, *, rollback: bool) -> dict[str, Any]:
    require_game_closed()
    load_manifest(workspace, mods_root)
    targets = inspect_targets(mods_root)
    changes: list[tuple[dict[str, Any], bytes]] = []
    for target in targets:
        spec = target["spec"]
        if rollback:
            desired = original_path(workspace, spec["relative"]).read_bytes()
            desired_hash = spec["original"]
        else:
            path = staged_path(workspace, spec["relative"])
            if not path.is_file():
                raise PatchError(f"Prepared patch missing: {path}")
            desired = path.read_bytes()
            desired_hash = spec["patched"]
            # Rebuild from the verified backup: both signatures and output hash
            # are checked even if a staged artifact was externally replaced.
            expected = build_patch(spec["relative"], original_path(workspace, spec["relative"]).read_bytes())
            if desired != expected:
                raise PatchError(f"Prepared patch bytes changed: {path}")
        if sha256(desired) != desired_hash:
            raise PatchError(f"Requested target bytes have the wrong hash: {target['path']}")
        if target["data"] != desired:
            changes.append((target, desired))
    require_game_closed()
    for target in targets:
        if target["path"].read_bytes() != target["data"]:
            raise PatchError(f"Target changed during preflight: {target['path']}")
    written: list[dict[str, Any]] = []
    try:
        for target, desired in changes:
            atomic_write(target["path"], desired)
            written.append(target)
            if target["path"].read_bytes() != desired:
                raise PatchError(f"Write verification failed: {target['path']}")
    except Exception as exc:
        recovery_errors = []
        for target in reversed(written):
            try:
                atomic_write(target["path"], target["data"])
            except Exception as recovery_exc:
                recovery_errors.append(str(recovery_exc))
        suffix = " Original state was restored." if not recovery_errors else " Recovery errors: " + "; ".join(recovery_errors)
        raise PatchError(f"Target update failed: {exc}.{suffix}") from exc
    return {"operation": "rollback" if rollback else "apply", "updated": len(changes), "already_in_requested_state": not changes, "files": [{"path": str(target["path"]), "sha256": sha256(target["path"].read_bytes())} for target in targets]}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", nargs="?", default="prepare", choices=("prepare", "apply", "check", "rollback"))
    parser.add_argument("--mods-root", type=Path, default=DEFAULT_MODS_ROOT, help="The installation's data/ue4ss-mods folder.")
    parser.add_argument("--workspace", type=Path, default=PROJECT_ROOT, help="Workspace used for patches and verified original backups.")
    args = parser.parse_args(argv)
    try:
        mods_root, workspace = args.mods_root.resolve(), args.workspace.resolve()
        if args.command == "prepare":
            result = prepare(mods_root, workspace)
        elif args.command == "check":
            result = check(mods_root)
        else:
            result = change_targets(mods_root, workspace, rollback=args.command == "rollback")
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 1 if args.command == "check" and not result["all_patched"] else 0
    except (PatchError, OSError) as exc:
        print(json.dumps({"error": str(exc)}, ensure_ascii=False), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
