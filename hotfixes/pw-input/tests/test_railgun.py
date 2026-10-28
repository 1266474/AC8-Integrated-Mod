"""Run from hotfixes/pw-input after local prepare:
python -m unittest discover -s tests -p test_railgun.py -v

Uses Lua 5.4+ via lupa to execute the actual patched reticle module. Deployment
tests run against temporary installation copies; they never edit real Mods.
"""
from __future__ import annotations

import importlib.util
import json
import math
from pathlib import Path
import struct
import tempfile
import unittest
from unittest import mock

try:
    from lupa import LuaRuntime
except ImportError:
    LuaRuntime = None


ROOT = Path(__file__).resolve().parents[1]
module_spec = importlib.util.spec_from_file_location("patch_railgun", ROOT / "tools/patch_railgun.py")
assert module_spec and module_spec.loader
patch = importlib.util.module_from_spec(module_spec)
module_spec.loader.exec_module(patch)


def originals() -> dict[Path, bytes]:
    result = {}
    for item in patch.specifications():
        backup = patch.original_path(ROOT, item["relative"])
        candidate = backup if backup.is_file() else patch.DEFAULT_MODS_ROOT / item["relative"]
        if not candidate.is_file():
            raise unittest.SkipTest("Matched PW-MkI 1.2.0 originals are not available; run local prepare first.")
        data = candidate.read_bytes()
        if patch.sha256(data) != item["original"]:
            raise unittest.SkipTest("Matched original PW-MkI payload is unavailable; run local prepare first.")
        result[item["relative"]] = data
    return result


class PatchBytesTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.original = originals()

    def test_native_patch_changes_only_the_angle_upper_bound(self):
        original = self.original[patch.DLL_RELATIVE]
        changed = patch.build_patch(patch.DLL_RELATIVE, original)
        self.assertEqual(len(original), len(changed))
        self.assertEqual([i for i, pair in enumerate(zip(original, changed)) if pair[0] != pair[1]], [0x205C6, 0x205C7])
        self.assertEqual(struct.unpack_from("<f", changed, patch.DLL_LIMIT_OFFSET)[0], 180)
        self.assertEqual(patch.sha256(changed), patch.DLL_PATCHED_SHA256)

    def test_unknown_native_version_is_rejected(self):
        data = bytearray(self.original[patch.DLL_RELATIVE])
        data[100] ^= 1
        with self.assertRaises(patch.PatchError):
            patch.build_patch(patch.DLL_RELATIVE, bytes(data))

    def test_lua_patch_preserves_everything_except_validation(self):
        original = self.original[patch.LUA_RELATIVE]
        changed = patch.build_patch(patch.LUA_RELATIVE, original)
        self.assertEqual(changed.replace(patch.LUA_NEW, patch.LUA_OLD, 1), original)
        self.assertEqual(patch.sha256(changed), patch.LUA_PATCHED_SHA256)

    def test_enhanced_half_angle_converts_to_valid_native_cosine(self):
        # The audited native helper doubles this half-angle, then computes
        # cos(full-angle*pi/360). This covers the formerly rejected negative
        # cosine domain without claiming to execute the game in this unit test.
        for half, full in ((32.5, 65), (60, 120), (160, 320), (180, 360)):
            with self.subTest(half=half):
                self.assertEqual(2 * half, full)
                self.assertAlmostEqual(math.cos(full * math.pi / 360), math.cos(math.radians(half)), places=12)
        self.assertLess(math.cos(math.radians(160)), 0)


@unittest.skipIf(LuaRuntime is None, "Optional integration tests require lupa; see requirements-test.txt")
class ReticleLuaTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.original = originals()[patch.LUA_RELATIVE]

    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute("PWActorRegistryV21={static=function(path) return {} end}")
        self.make_plane = self.lua.eval("""function(angle)
            return {GetComponentByClass=function(self, cls)
                return {EquippedWeapons={Configs={[2]={WeaponClassDefaultObject={LockonAngle=angle}}}}}
            end}
        end""")
        self.make_target = self.lua.eval("function(category) return {GameObjectCategory=category, IsValid=function() return true end} end")
        changed = patch.build_patch(patch.LUA_RELATIVE, self.original)
        self.reticle = self.lua.execute(changed.decode("utf-8"))

    def test_original_reproduces_160_degree_failure(self):
        old = self.lua.execute(self.original.decode("utf-8"))
        with self.assertRaisesRegex(Exception, "MSL acquisition angle unavailable"):
            old.airLockHalf(self.make_plane(160))

    def test_valid_boundaries_and_enhanced_angles_are_preserved(self):
        for value in (0.1, 32.5, 60, 60.01, 90, 160, 179.999, 180):
            with self.subTest(value=value):
                self.assertEqual(self.reticle.airLockHalf(self.make_plane(value)), value)

    def test_invalid_or_nonfinite_angles_cannot_open_the_gate(self):
        for value in (None, "160", True, False, 0, -1, 0.099, 180.001, 360, math.nan, math.inf, -math.inf):
            with self.subTest(value=str(value)):
                with self.assertRaisesRegex(Exception, "MSL acquisition angle unavailable"):
                    self.reticle.airLockHalf(self.make_plane(value))

    def test_air_targets_use_enhanced_acquisition_without_expanding_ground_circle(self):
        plane = self.make_plane(160)
        geometry = self.lua.table_from({"half": 2.7})
        for category in (1, 2):
            with self.subTest(category=category):
                self.assertEqual(self.reticle.acquisitionHalf(plane, geometry, self.make_target(category)), 160)
        for category in (3, 4, 5):
            with self.subTest(category=category):
                self.assertEqual(self.reticle.acquisitionHalf(plane, geometry, self.make_target(category)), 2.7)


class DeploymentTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.original = originals()

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="ac8-railgun-test-")
        self.addCleanup(self.directory.cleanup)
        self.base = Path(self.directory.name)
        self.mods = self.base / "mods"
        self.workspace = self.base / "workspace"
        for relative, data in self.original.items():
            target = self.mods / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
        self.process_mock = mock.patch.object(patch, "running_game_processes", return_value=[])
        self.process_mock.start()
        self.addCleanup(self.process_mock.stop)

    def assert_original(self):
        for relative, data in self.original.items():
            self.assertEqual((self.mods / relative).read_bytes(), data)

    def prepare(self):
        return patch.prepare(self.mods, self.workspace)

    def apply(self):
        return patch.change_targets(self.mods, self.workspace, rollback=False)

    def rollback(self):
        return patch.change_targets(self.mods, self.workspace, rollback=True)

    def test_prepare_makes_backups_and_payload_without_changing_installation(self):
        result = self.prepare()
        self.assertFalse(result["installation_changed"])
        self.assert_original()
        for item in patch.specifications():
            self.assertEqual(patch.original_path(self.workspace, item["relative"]).read_bytes(), self.original[item["relative"]])
            self.assertEqual(patch.sha256(patch.staged_path(self.workspace, item["relative"]).read_bytes()), item["patched"])
        patch.load_manifest(self.workspace, self.mods)

    def test_apply_check_idempotent_apply_and_rollback(self):
        self.prepare()
        self.assertFalse(patch.check(self.mods)["all_patched"])
        self.assertEqual(self.apply()["updated"], 2)
        self.assertTrue(patch.check(self.mods)["all_patched"])
        self.assertEqual(self.apply()["updated"], 0)
        self.assertEqual(self.rollback()["updated"], 2)
        self.assert_original()
        self.assertEqual(self.rollback()["updated"], 0)

    def test_prepare_is_idempotent_after_apply_and_keeps_original_backups(self):
        self.prepare()
        self.apply()
        self.prepare()
        self.assertTrue(patch.check(self.mods)["all_patched"])
        for relative, data in self.original.items():
            self.assertEqual(patch.original_path(self.workspace, relative).read_bytes(), data)

    def test_running_game_blocks_apply_and_rollback(self):
        self.prepare()
        with mock.patch.object(patch, "running_game_processes", return_value=["AceCombat8.exe"]):
            with self.assertRaisesRegex(patch.PatchError, "Close AceCombat8"):
                self.apply()
            with self.assertRaisesRegex(patch.PatchError, "Close AceCombat8"):
                self.rollback()
        self.assert_original()

    def test_unknown_installation_fails_before_creating_artifacts(self):
        (self.mods / patch.DLL_RELATIVE).write_bytes(b"unknown DLL")
        with self.assertRaisesRegex(patch.PatchError, "Unknown or modified target"):
            self.prepare()
        self.assertFalse(patch.manifest_path(self.workspace).exists())

    def test_tampered_stage_is_rejected_before_any_target_changes(self):
        self.prepare()
        patch.staged_path(self.workspace, patch.LUA_RELATIVE).write_bytes(b"tampered patch")
        with self.assertRaisesRegex(patch.PatchError, "Prepared patch bytes changed"):
            self.apply()
        self.assert_original()

    def test_tampered_backup_is_never_restored(self):
        self.prepare()
        patch.original_path(self.workspace, patch.LUA_RELATIVE).write_bytes(b"tampered backup")
        with self.assertRaisesRegex(patch.PatchError, "backup missing or modified"):
            self.apply()
        self.assert_original()

    def test_external_lua_changes_block_entire_rollback(self):
        self.prepare()
        self.apply()
        lua_path = self.mods / patch.LUA_RELATIVE
        lua_path.write_bytes(lua_path.read_bytes() + b"-- external user edit\n")
        native_before = (self.mods / patch.DLL_RELATIVE).read_bytes()
        with self.assertRaisesRegex(patch.PatchError, "Unknown or modified target"):
            self.rollback()
        self.assertEqual((self.mods / patch.DLL_RELATIVE).read_bytes(), native_before)
        self.assertTrue(lua_path.read_bytes().endswith(b"-- external user edit\n"))

    def test_target_change_between_prepare_and_apply_is_not_overwritten(self):
        self.prepare()
        target = self.mods / patch.LUA_RELATIVE
        target.write_bytes(target.read_bytes() + b"-- externally changed\n")
        with self.assertRaises(patch.PatchError):
            self.apply()
        self.assertEqual((self.mods / patch.DLL_RELATIVE).read_bytes(), self.original[patch.DLL_RELATIVE])

    def test_manifest_is_bound_to_its_prepared_installation(self):
        self.prepare()
        manifest = patch.manifest_path(self.workspace)
        data = json.loads(manifest.read_text(encoding="utf-8"))
        data["mods_root"] = str(self.mods / "different-install")
        manifest.write_text(json.dumps(data), encoding="utf-8")
        with self.assertRaisesRegex(patch.PatchError, "manifest does not match"):
            self.apply()
        self.assert_original()

    def test_second_file_write_failure_restores_first_file(self):
        self.prepare()
        real_write = patch.atomic_write
        fail_once = True

        def write(path, data):
            nonlocal fail_once
            if path == self.mods / patch.LUA_RELATIVE and fail_once:
                fail_once = False
                raise OSError("simulated second-file write failure")
            return real_write(path, data)

        with mock.patch.object(patch, "atomic_write", side_effect=write):
            with self.assertRaisesRegex(patch.PatchError, "Original state was restored"):
                self.apply()
        self.assert_original()


if __name__ == "__main__":
    unittest.main(verbosity=2)
