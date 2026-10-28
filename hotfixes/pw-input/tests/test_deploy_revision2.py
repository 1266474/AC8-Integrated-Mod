from pathlib import Path
import importlib.util, shutil, unittest
from unittest import mock
import test_deploy_native as fixture
ROOT=Path(__file__).resolve().parents[1]
s=importlib.util.spec_from_file_location('rev2_deploy',ROOT/'tools/deploy_revision2.py')
r=importlib.util.module_from_spec(s);s.loader.exec_module(r)

class Revision2Deploy(unittest.TestCase):
    def setUp(self):
        self.base=fixture.DeploymentTests('test_idempotent_apply_and_rollback')
        self.base.setUp();self.addCleanup(self.base.doCleanups)
        self.base.do_apply()
        self.install=self.base.install;self.root=self.base.workspace
        self.mods=self.root/'mods';self.mods.mkdir()
        native=self.root/'src/MouseAim';shutil.copytree(self.base.source,native)
        (native/'build').mkdir();(native/'build/ac8_mouse_aim_010.dll').write_bytes(fixture.pe(b'revision 2'))
        (native/'src/main.cpp').write_bytes(b'revision 2 diagnostic source')
        pw=self.root/'src/PWRuntime';pw.mkdir()
        for name in ('pw-blmu-guidance.lua','pw-callback-profile.lua','pw-hud-discovery-budget.lua'):
            shutil.copyfile(ROOT/'src/PWRuntime'/name,pw/name)
        self.original_main=b"dofile(PWMkIRuntimeRoot..'runtime-pw-actor-registry-v21.lua')\ndofile(PWMkIRuntimeRoot..'runtime-pw-eufb-cloud-v113.lua')\n"
        self.original_radar=b'local registry=assert(PWActorRegistryV21)\nlocal function source_for(a)\nend\n api.activeOwners=active\n return valid(c)and c.bVisible and not c.bHiddenInGame\n'
        for rel,data in ((r.PW_MAIN,self.original_main),(r.RADAR,self.original_radar)):
            p=self.mods/rel;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(data)
        self.patchers=[mock.patch.object(r,'PW_MAIN_SHA',r.d.sha(self.original_main)),mock.patch.object(r,'RADAR_SHA',r.d.sha(self.original_radar)),mock.patch.object(r.d,'game_running',return_value=False)]
        for p in self.patchers:p.start();self.addCleanup(p.stop)
        self.before=self.snapshot()
    def snapshot(self):
        return {area:{p.relative_to(base).as_posix():p.read_bytes()for p in base.rglob('*')if p.is_file()}for area,base in (('package',self.install),('mods',self.mods))}
    def apply(self):return r.apply(self.install,self.mods,self.root)
    def test_two_area_pair_and_idempotent_rollback(self):
        self.assertEqual(self.apply()['id'],r.TAG)
        self.assertIn(b'callbackProfile',(self.mods/r.PW_MAIN).read_bytes())
        self.assertIn(b'discoveryBudget',(self.mods/r.RADAR).read_bytes())
        self.assertEqual(self.apply()['id'],r.TAG)
        r.rollback(self.install,self.mods,self.root);self.assertEqual(self.snapshot(),self.before)
    def test_unknown_pw_refused_before_package_changes(self):
        (self.mods/r.PW_MAIN).write_bytes(self.original_main+b'unknown')
        before=self.snapshot()
        with self.assertRaisesRegex(ValueError,'differs'):self.apply()
        self.assertEqual(self.snapshot(),before)
    def test_failed_mod_write_restores_already_written_native(self):
        real=r.write;failed=False
        def write(path,data):
            nonlocal failed
            if path==self.mods/r.PW_MAIN and not failed:failed=True;raise OSError('simulated PW write failure')
            return real(path,data)
        with mock.patch.object(r,'write',side_effect=write):
            with self.assertRaises(OSError):self.apply()
        self.assertEqual(self.snapshot(),self.before)
        self.assertEqual(r.d.read_json(r.record_path(self.root))['status'],'rolled-back')
    def test_game_running_refused(self):
        with mock.patch.object(r.d,'game_running',return_value=True):
            with self.assertRaisesRegex(RuntimeError,'running'):self.apply()
        self.assertEqual(self.snapshot(),self.before)
    def test_user_edits_preserved_on_refused_rollback(self):
        self.apply();p=self.mods/r.PW_MAIN;p.write_bytes(b'user edit')
        with self.assertRaisesRegex(ValueError,'changed'):r.rollback(self.install,self.mods,self.root)
        self.assertEqual(p.read_bytes(),b'user edit')
    def test_changed_backup_refused(self):
        self.apply();record=r.d.read_json(r.record_path(self.root))
        entry=next(x for x in record['files']if x['relative']==r.PW_MAIN)
        Path(record['backup_root']).joinpath(entry['backup']).write_bytes(b'tampered')
        with self.assertRaisesRegex(ValueError,'Backup changed'):r.rollback(self.install,self.mods,self.root)

if __name__=='__main__':unittest.main()
