import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

SPEC = importlib.util.spec_from_file_location("deploy_native", Path(__file__).resolve().parents[1] / "tools/deploy_native.py")
d = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(d)


def pe(label):
    data = bytearray(160)
    data[:2] = b"MZ"
    data[0x3C:0x40] = (64).to_bytes(4, "little")
    data[64:68] = b"PE\0\0"
    data[68:70] = b"\x64\x86"
    data[86:88] = (0x2000).to_bytes(2, "little")
    return bytes(data) + label


class DeploymentTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        base = Path(self.temp.name)
        self.install, self.source, self.workspace = base / "install", base / "source", base / "work"
        self.install.mkdir()
        self.workspace.mkdir()
        (self.source / "src").mkdir(parents=True)
        (self.source / "include").mkdir()
        self.original = pe(b"original")
        self.candidate = pe(b"local fixed")
        self.dll = base / "candidate.dll"
        self.dll.write_bytes(self.candidate)
        self.write(d.DLL_REL, self.original)
        self.write("source/MouseAim/src/main.cpp", b"old source")
        self.write("source/MouseAim/include/api.h", b"same header")
        self.lua_rel = "payload/Game/Binaries/Win64/ue4ss/Mods/AC8MouseAim/Scripts/main.lua"
        self.write(self.lua_rel, b"old Lua bridge")
        (self.source.parent / "Scripts").mkdir()
        (self.source.parent / "Scripts/main.lua").write_bytes(b"timed Lua bridge")
        (self.source / "src/main.cpp").write_bytes(b"new source")
        (self.source / "src/inbox.h").write_bytes(b"new inbox")
        (self.source / "include/api.h").write_bytes(b"same header")
        self.manifest = [{"Path": d.DLL_REL.removeprefix("payload/").replace("/", "\\"), "SHA256": d.sha(self.original)}]
        self.manifest.append({"Path": self.lua_rel.removeprefix("payload/").replace("/", "\\"), "SHA256": d.sha(b"old Lua bridge")})
        self.write("payload-manifest.json", d.encode_json(self.manifest))
        self.write("package-info.json", d.encode_json({"version": "2.5.2", "game_build": "25201480", "native_sha256": d.sha(self.original)}))
        self.write("trust.sig", b"do not modify update signature")
        initial = {p.relative_to(self.install).as_posix(): p.read_bytes() for p in self.install.rglob("*") if p.is_file()}
        self.write("FILES.sha256", ("\n".join(f"{d.sha(b).lower()}  {p}" for p, b in initial.items()) + "\n").encode())
        self.before = {p.relative_to(self.install).as_posix(): p.read_bytes() for p in self.install.rglob("*") if p.is_file()}
        self.addCleanup(mock.patch.stopall)
        mock.patch.object(d, "ORIGINAL_NATIVE_SHA256", d.sha(self.original)).start()
        mock.patch.object(d, "game_running", return_value=False).start()

    def write(self, rel, content):
        path = self.install / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)

    def do_apply(self):
        return d.apply(self.install, self.source, self.dll, self.workspace)

    def test_apply_full_integrity_and_rollback_byte_identical(self):
        result = self.do_apply()
        self.assertEqual(result["status"], "applied")
        self.assertEqual((self.install / d.DLL_REL).read_bytes(), self.candidate)
        self.assertEqual((self.install / "source/MouseAim/src/main.cpp").read_bytes(), b"new source")
        self.assertEqual((self.install / "source/MouseAim/src/inbox.h").read_bytes(), b"new inbox")
        self.assertEqual((self.install / self.lua_rel).read_bytes(), b"timed Lua bridge")
        self.assertTrue(d.read_json(self.install / "package-info.json")["local_hotfix"])
        self.assertEqual((self.install / "trust.sig").read_bytes(), b"do not modify update signature")
        d.verify_package(self.install)
        record = d.read_json(d.record_path(self.workspace))
        self.assertNotIn("source/MouseAim/include/api.h", {p["relative"] for p in record["files"]})
        d.rollback(self.install, self.workspace)
        after = {p.relative_to(self.install).as_posix(): p.read_bytes() for p in self.install.rglob("*") if p.is_file()}
        self.assertEqual(self.before, after)

    def test_idempotent_apply_and_rollback(self):
        self.do_apply()
        self.assertEqual(self.do_apply()["status"], "already-applied")
        d.rollback(self.install, self.workspace)
        self.assertEqual(d.rollback(self.install, self.workspace)["status"], "already-rolled-back")

    def test_new_lua_file_registered_in_both_inventories_and_removed_on_rollback(self):
        (self.source.parent / "Scripts/performance.lua").write_bytes(b"return 42")
        self.do_apply()
        rel = "payload/Game/Binaries/Win64/ue4ss/Mods/AC8MouseAim/Scripts/performance.lua"
        self.assertEqual((self.install / rel).read_bytes(), b"return 42")
        self.assertIn(rel, {p for _, p in d.parse_files((self.install / "FILES.sha256").read_bytes())})
        d.verify_package(self.install)
        d.rollback(self.install, self.workspace)
        self.assertFalse((self.install / rel).exists())

    def test_no_companion_lua_directory_is_supported(self):
        (self.source.parent / "Scripts/main.lua").unlink()
        (self.source.parent / "Scripts").rmdir()
        self.do_apply()
        self.assertEqual((self.install / self.lua_rel).read_bytes(), b"old Lua bridge")

    def test_unknown_original_native_refused_even_with_consistent_manifests(self):
        with mock.patch.object(d, "ORIGINAL_NATIVE_SHA256", "0" * 64):
            with self.assertRaisesRegex(ValueError, "Unknown native"):
                self.do_apply()
        self.assertFalse(d.record_path(self.workspace).exists())

    def test_changed_source_preflight_refused_before_writing(self):
        self.write("source/MouseAim/src/main.cpp", b"other user change")
        with self.assertRaisesRegex(ValueError, "Package file changed"):
            self.do_apply()
        self.assertEqual((self.install / d.DLL_REL).read_bytes(), self.original)

    def test_game_running_refused_before_writing(self):
        with mock.patch.object(d, "game_running", return_value=True):
            with self.assertRaisesRegex(RuntimeError, "running"):
                self.do_apply()
        self.assertFalse(d.record_path(self.workspace).exists())

    def test_rollback_refuses_new_user_change(self):
        self.do_apply()
        self.write("source/MouseAim/src/main.cpp", b"user changes after patch")
        with self.assertRaisesRegex(ValueError, "Changed file"):
            d.rollback(self.install, self.workspace)
        self.assertEqual((self.install / d.DLL_REL).read_bytes(), self.candidate)

    def test_modified_backup_refused(self):
        self.do_apply()
        record = d.read_json(d.record_path(self.workspace))
        Path(record["files"][0]["backup"]).write_bytes(b"bad backup")
        with self.assertRaisesRegex(ValueError, "Backup was changed"):
            d.rollback(self.install, self.workspace)

    def test_partial_write_failure_restores_all_files(self):
        write = d.atomic_write
        failed = False
        def fail_once(path, data):
            nonlocal failed
            if path == self.install / "source/MouseAim/src/main.cpp" and not failed:
                failed = True
                raise OSError("injected write failure")
            return write(path, data)
        with mock.patch.object(d, "atomic_write", side_effect=fail_once):
            with self.assertRaisesRegex(OSError, "injected"):
                self.do_apply()
        self.assertTrue(failed)
        after = {p.relative_to(self.install).as_posix(): p.read_bytes() for p in self.install.rglob("*") if p.is_file()}
        self.assertEqual(self.before, after)
        self.assertEqual(d.read_json(d.record_path(self.workspace))["status"], "rolled-back")

    def test_game_started_during_preparation_leaves_original_files(self):
        with mock.patch.object(d, "game_running", side_effect=[False, True]):
            with self.assertRaisesRegex(RuntimeError, "running"):
                self.do_apply()
        self.assertEqual((self.install / d.DLL_REL).read_bytes(), self.original)
        self.assertEqual(d.read_json(d.record_path(self.workspace))["status"], "rolled-back")

    def test_partial_failure_does_not_overwrite_concurrent_user_change(self):
        write = d.atomic_write
        failed = False
        def fail_after_user_change(path, data):
            nonlocal failed
            if path == self.install / "source/MouseAim/src/main.cpp" and not failed:
                failed = True
                (self.install / d.DLL_REL).write_bytes(b"new concurrent user contents")
                raise OSError("concurrent edit")
            return write(path, data)
        with mock.patch.object(d, "atomic_write", side_effect=fail_after_user_change):
            with self.assertRaisesRegex(OSError, "concurrent edit"):
                self.do_apply()
        self.assertEqual((self.install / d.DLL_REL).read_bytes(), b"new concurrent user contents")
        self.assertEqual(d.read_json(d.record_path(self.workspace))["status"], "recovery-required")

    def test_manifest_path_escape_refused(self):
        manifest = [{"Path": "../outside", "SHA256": "0" * 64}]
        self.write("payload-manifest.json", d.encode_json(manifest))
        # Rewrite FILES to keep its checksum correct; payload validation still
        # must reject traversal instead of accidentally reading another file.
        entries = d.parse_files((self.install / "FILES.sha256").read_bytes())
        self.write("FILES.sha256", ("\n".join(f"{d.sha((self.install/p).read_bytes())}  {p}" for _, p in entries) + "\n").encode())
        with self.assertRaisesRegex(ValueError, "Unsafe relative path"):
            self.do_apply()

    def test_non_x64_candidate_refused(self):
        self.dll.write_bytes(b"not a DLL")
        with self.assertRaisesRegex(ValueError, "not a PE DLL"):
            self.do_apply()


if __name__ == "__main__":
    unittest.main()
