"""Deploy this local AC8 native hotfix without bypassing package verification.

prepare/check are read-only with respect to the installed package. apply and
rollback refuse a running game and unknown file contents. Original manifests
remain in the external backup directory, not inside the payload.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parents[1]
REPO = ROOT.parents[1]
NATIVE_SOURCE = ROOT / "src/MouseAim" if (ROOT / "src/MouseAim").is_dir() else REPO / "native"
INSTALL = Path(os.environ.get("LOCALAPPDATA", str(Path.home() / "AppData/Local"))) / "Programs/AC8 Integrated/versions/2.5.2"
ORIGINAL_NATIVE_SHA256 = "1F0644A5CAAE181428E45F73450C75FEACBCB4CD92EBAF2655098EAFA7494AB6"
DLL_REL = "payload/Game/Binaries/Win64/ue4ss/Mods/AC8MouseAim/Scripts/ac8_mouse_aim_010.dll"
TAG = "20261028-input-inbox-1"


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest().upper()


def read_json(path: Path):
    return json.loads(path.read_text(encoding="utf-8-sig"))


def encode_json(value) -> bytes:
    return (json.dumps(value, ensure_ascii=False, indent=2) + "\n").encode("utf-8")


def safe_path(root: Path, relative: str) -> Path:
    rel = PurePosixPath(relative.replace("\\", "/"))
    if rel.is_absolute() or not rel.parts or any(p in ("..", "") or ":" in p for p in rel.parts):
        raise ValueError(f"Unsafe relative path: {relative}")
    result = root.joinpath(*rel.parts)
    if not result.resolve().is_relative_to(root.resolve()):
        raise ValueError(f"Path escaped installation: {relative}")
    for node in [result, *result.parents]:
        if node == root.parent:
            break
        if node.is_symlink() or (hasattr(node, "is_junction") and node.is_junction()):
            raise ValueError(f"Filesystem link refused: {node}")
    return result


def game_running() -> bool:
    result = subprocess.run(
        ["tasklist.exe", "/FI", "IMAGENAME eq AceCombat8.exe", "/FO", "CSV", "/NH"],
        capture_output=True, text=True, errors="replace", check=True,
    )
    return bool(re.search(r'(?im)^"AceCombat8\.exe"', result.stdout))


def require_stopped():
    if game_running():
        raise RuntimeError("AceCombat8.exe is running; close the game and wait for cleanup first.")


def parse_files(data: bytes) -> list[tuple[str, str]]:
    entries = []
    seen = set()
    for line in data.decode("utf-8-sig").splitlines():
        if not line.strip():
            continue
        match = re.fullmatch(r"([a-fA-F0-9]{64})  (.+)", line)
        if not match:
            raise ValueError("Invalid FILES.sha256 line")
        digest, rel = match.groups()
        rel = rel.replace("\\", "/")
        if rel.casefold() in seen:
            raise ValueError(f"Duplicate FILES.sha256 entry: {rel}")
        seen.add(rel.casefold())
        entries.append((digest.upper(), rel))
    return entries


def verify_package(install: Path):
    files = parse_files((install / "FILES.sha256").read_bytes())
    for expected, rel in files:
        path = safe_path(install, rel)
        if not path.is_file() or sha(path.read_bytes()) != expected:
            raise ValueError(f"Package file changed or missing: {rel}")
    manifest = read_json(install / "payload-manifest.json")
    seen = set()
    for item in manifest:
        rel = item["Path"].replace("\\", "/")
        if rel.casefold() in seen:
            raise ValueError(f"Duplicate payload manifest entry: {rel}")
        seen.add(rel.casefold())
        path = safe_path(install / "payload", rel)
        if not path.is_file() or sha(path.read_bytes()) != item["SHA256"].upper():
            raise ValueError(f"Payload mismatch: {rel}")
    actual = {p.relative_to(install / "payload").as_posix().casefold()
              for p in (install / "payload").rglob("*") if p.is_file()}
    if seen != actual:
        raise ValueError("Payload inventory differs from manifest")
    info = read_json(install / "package-info.json")
    if info["version"] != "2.5.2" or info["game_build"] != "25201480":
        raise ValueError("This hotfix supports package 2.5.2 / game build 25201480 only")
    if sha(safe_path(install, DLL_REL).read_bytes()) != info["native_sha256"].upper():
        raise ValueError("package-info native hash differs from payload")
    return files, manifest, info


def validate_dll(data: bytes):
    if len(data) < 0x40 or data[:2] != b"MZ":
        raise ValueError("Candidate native module is not a PE DLL")
    pe = int.from_bytes(data[0x3C:0x40], "little")
    if data[pe:pe + 4] != b"PE\0\0" or data[pe + 4:pe + 6] != b"\x64\x86":
        raise ValueError("Candidate module must be an x64 PE image")
    flags = int.from_bytes(data[pe + 22:pe + 24], "little")
    if not flags & 0x2000:
        raise ValueError("Candidate PE image does not have the DLL flag")


def make_changes(install: Path, source: Path, dll: Path) -> dict[str, bytes]:
    files, manifest, info = verify_package(install)
    old_dll = safe_path(install, DLL_REL).read_bytes()
    if sha(old_dll) != ORIGINAL_NATIVE_SHA256:
        raise ValueError("Unknown native original; refusing to patch this package")
    candidate = dll.read_bytes()
    validate_dll(candidate)
    if candidate == old_dll:
        raise ValueError("Candidate DLL is unchanged")
    changes = {DLL_REL: candidate}
    # Synchronize only the source and headers used by the native build. Test
    # outputs and build directories never become part of the installed package.
    for folder in ("src", "include"):
        base = source / folder
        if not base.is_dir():
            raise ValueError(f"Missing candidate source directory: {base}")
        for file in sorted(base.rglob("*")):
            if not file.is_file():
                continue
            if file.is_symlink():
                raise ValueError(f"Candidate source link refused: {file}")
            rel = "source/MouseAim/" + file.relative_to(source).as_posix()
            target = safe_path(install, rel)
            content = file.read_bytes()
            if not target.exists() or target.read_bytes() != content:
                changes[rel] = content
    # The companion bridge Lua lives beside MouseAim rather than in its C++
    # source tree. It is deliberately explicit and restricted to Lua files.
    scripts = source.parent / "Scripts"
    if not scripts.is_dir():
        scripts = source.parent / "package-template/payload/Game/Binaries/Win64/ue4ss/Mods/AC8MouseAim/Scripts"
    if scripts.is_dir():
        for file in sorted(scripts.rglob("*.lua")):
            if file.is_symlink() or not file.resolve().is_relative_to(scripts.resolve()):
                raise ValueError(f"Candidate script link refused: {file}")
            rel = "payload/Game/Binaries/Win64/ue4ss/Mods/AC8MouseAim/Scripts/" + file.relative_to(scripts).as_posix()
            target = safe_path(install, rel)
            content = file.read_bytes()
            if not target.exists() or target.read_bytes() != content:
                changes[rel] = content
    native_rel = DLL_REL.removeprefix("payload/")
    if sum(item["Path"].replace("\\", "/") == native_rel for item in manifest) != 1:
        raise ValueError("Native DLL manifest entry is missing or ambiguous")
    manifest_by_path = {item["Path"].replace("\\", "/"): item for item in manifest}
    for rel, content in changes.items():
        if not rel.startswith("payload/"):
            continue
        payload_rel = rel.removeprefix("payload/")
        if payload_rel in manifest_by_path:
            manifest_by_path[payload_rel]["SHA256"] = sha(content)
        else:
            item = {"Path": payload_rel.replace("/", "\\"), "SHA256": sha(content)}
            manifest.append(item)
            manifest_by_path[payload_rel] = item
    changes["payload-manifest.json"] = encode_json(manifest)
    info["native_sha256"] = sha(candidate).lower()
    info["local_hotfix"] = {"id": TAG, "base_version": "2.5.2", "official_release": False}
    changes["package-info.json"] = encode_json(info)
    listed = {rel.casefold() for _, rel in files}
    native_records = [p for p in changes if p.casefold() not in listed]
    updated = [(sha(changes[rel]) if rel in changes else digest, rel) for digest, rel in files]
    updated.extend((sha(changes[rel]), rel) for rel in sorted(native_records))
    changes["FILES.sha256"] = ("\n".join(f"{h.lower()}  {p}" for h, p in updated) + "\n").encode("utf-8")
    return changes


def atomic_write(path: Path, data: bytes):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".ac8-hotfix-tmp")
    if temporary.exists():
        raise ValueError(f"Temporary file already exists: {temporary}")
    try:
        temporary.write_bytes(data)
        os.replace(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()


def record_path(workspace: Path):
    return workspace / "results/native-deployment.json"


def check_deployment(install: Path, workspace: Path):
    files, manifest, info = verify_package(install)
    result = {"package_files": len(files), "payload_files": len(manifest),
              "native_sha256": info["native_sha256"], "local_hotfix": info.get("local_hotfix")}
    record = record_path(workspace)
    if record.exists():
        state = read_json(record)
        if state.get("status") == "applied":
            if Path(state["install_root"]).resolve() != install.resolve():
                raise ValueError("Deployment record belongs to another installation")
            for item in state["files"]:
                path = safe_path(install, item["relative"])
                if not path.is_file() or sha(path.read_bytes()) != item["after_sha256"]:
                    raise ValueError(f"Deployed file changed: {item['relative']}")
    return result


def apply(install: Path, source: Path, dll: Path, workspace: Path):
    require_stopped()
    state_path = record_path(workspace)
    if state_path.exists():
        state = read_json(state_path)
        if state.get("status") == "applied":
            result = check_deployment(install, workspace)
            if sha(dll.read_bytes()) != result["native_sha256"].upper():
                raise ValueError("A different hotfix is already deployed; rollback first")
            return {"status": "already-applied", **result}
        if state.get("status") != "rolled-back":
            raise ValueError("An incomplete deployment record exists; recover before deploying")
    changes = make_changes(install, source, dll)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    backup_root = workspace / "backups/native" / stamp
    backup_root.mkdir(parents=True, exist_ok=False)
    records = []
    originals = {}
    for rel, after in changes.items():
        target = safe_path(install, rel)
        before = target.read_bytes() if target.is_file() else None
        originals[rel] = before
        backup = safe_path(backup_root, rel)
        if before is not None:
            backup.parent.mkdir(parents=True, exist_ok=True)
            backup.write_bytes(before)
            if backup.read_bytes() != before:
                raise IOError(f"Backup readback failed: {rel}")
        records.append({"relative": rel, "before_sha256": sha(before) if before is not None else None,
                        "after_sha256": sha(after), "backup": str(backup) if before is not None else None})
    state = {"schema": 1, "id": TAG, "status": "prepared", "install_root": str(install.resolve()),
             "created_utc": stamp, "files": records}
    state_path.parent.mkdir(parents=True, exist_ok=True)
    atomic_write(state_path, encode_json(state))
    written = []
    try:
        require_stopped()
        for item in records:
            rel = item["relative"]
            target = safe_path(install, rel)
            actual = sha(target.read_bytes()) if target.is_file() else None
            if actual != item["before_sha256"]:
                raise ValueError(f"File changed during deployment: {rel}")
            written.append(rel)
            atomic_write(target, changes[rel])
        verify_package(install)
    except BaseException:
        conflicts = []
        for rel in reversed(written):
            target = safe_path(install, rel)
            before = originals[rel]
            current = target.read_bytes() if target.is_file() else None
            if current not in (before, changes[rel]):
                conflicts.append(rel)
                continue
            if before is None:
                if target.exists():
                    target.unlink()
            else:
                atomic_write(target, before)
        state["status"] = "recovery-required" if conflicts else "rolled-back"
        if conflicts:
            state["recovery_conflicts"] = conflicts
        atomic_write(state_path, encode_json(state))
        raise
    state["status"] = "applied"
    atomic_write(state_path, encode_json(state))
    return {"status": "applied", "changed_files": len(records), "record": str(state_path),
            **check_deployment(install, workspace)}


def rollback(install: Path, workspace: Path):
    require_stopped()
    state_path = record_path(workspace)
    state = read_json(state_path)
    if Path(state["install_root"]).resolve() != install.resolve():
        raise ValueError("Deployment record belongs to another installation")
    if state["status"] == "rolled-back":
        return {"status": "already-rolled-back"}
    if state["status"] != "applied":
        raise ValueError("Deployment did not finish; inspect the prepared record before recovery")
    for item in state["files"]:
        target = safe_path(install, item["relative"])
        if not target.is_file() or sha(target.read_bytes()) != item["after_sha256"]:
            raise ValueError(f"Changed file prevents safe rollback: {item['relative']}")
        if item["backup"] is not None:
            backup = Path(item["backup"])
            if not backup.resolve().is_relative_to((workspace / "backups/native").resolve()):
                raise ValueError("Backup path escaped workspace")
            if sha(backup.read_bytes()) != item["before_sha256"]:
                raise ValueError(f"Backup was changed: {item['relative']}")
    for item in reversed(state["files"]):
        target = safe_path(install, item["relative"])
        if item["backup"] is None:
            target.unlink()
        else:
            atomic_write(target, Path(item["backup"]).read_bytes())
    verify_package(install)
    state["status"] = "rolled-back"
    atomic_write(state_path, encode_json(state))
    return {"status": "rolled-back", "changed_files": len(state["files"])}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", nargs="?", choices=("prepare", "apply", "check", "rollback"), default="prepare")
    parser.add_argument("--install-root", type=Path, default=INSTALL)
    parser.add_argument("--workspace", type=Path, default=ROOT)
    parser.add_argument("--source-root", type=Path, default=NATIVE_SOURCE)
    parser.add_argument("--dll", type=Path, default=NATIVE_SOURCE / "build/ac8_mouse_aim_010.dll")
    args = parser.parse_args()
    try:
        if args.action == "prepare":
            changes = make_changes(args.install_root, args.source_root, args.dll)
            result = {"status": "prepared-read-only", "changes": [{"relative": r, "after_sha256": sha(b)} for r, b in changes.items()]}
        elif args.action == "apply":
            result = apply(args.install_root, args.source_root, args.dll, args.workspace)
        elif args.action == "check":
            result = check_deployment(args.install_root, args.workspace)
        else:
            result = rollback(args.install_root, args.workspace)
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0
    except Exception as error:
        print(f"REFUSED: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
