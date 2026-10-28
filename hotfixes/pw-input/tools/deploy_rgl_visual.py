"""Apply/rollback shot-only charge FX on the pinned PW 1.2.0 scripts."""
from pathlib import Path
import importlib.util,json,argparse
from datetime import datetime,timezone
ROOT=Path(__file__).resolve().parents[1]
def module(name):
 s=importlib.util.spec_from_file_location(name,ROOT/('tools/'+name+'.py'));m=importlib.util.module_from_spec(s);s.loader.exec_module(m);return m
b=module('deploy_blmu_qaam');p=module('patch_rgl_visual');d=b.d;mods=b.r.MODS
RECORD=ROOT/'results/rgl-visual-deployment.json'
HELPER='PWMkI/Scripts/runtime/pw-rgl-shot-visual.lua'
def check():
 b.check();r=d.read_json(RECORD)
 if r['status']!='applied':raise ValueError('Visual overlay not applied')
 for item in r['files']:
  if d.sha(d.safe_path(mods,item['relative']).read_bytes())!=item['after']:raise ValueError('Changed visual deployment')
 return {'status':'applied','id':'20261028-rgl-shot-visual-4','visual_trigger':'confirmed-projectile-launch','duration_seconds':1,'firing_gate':'unchanged'}
def apply():
 d.require_stopped()
 if RECORD.exists()and d.read_json(RECORD)['status']=='applied':return check()
 b.check()
 if d.safe_path(mods,HELPER).exists():raise ValueError('Unexpected existing helper')
 changes={rel:p.patch(rel,d.safe_path(mods,rel).read_bytes())for rel in p.HASHES}
 changes[HELPER]=(ROOT/'src/PWRuntime/pw-rgl-shot-visual.lua').read_bytes()
 backup=ROOT/'backups/rgl-visual'/datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
 items=[]
 for rel,data in changes.items():
  target=d.safe_path(mods,rel);old=target.read_bytes()if target.exists()else None
  items.append({'relative':rel,'before':d.sha(old)if old is not None else None,'after':d.sha(data)})
  if old is not None:d.atomic_write(d.safe_path(backup,rel),old)
 r={'status':'prepared','backup_root':str(backup),'files':items};d.atomic_write(RECORD,d.encode_json(r));attempted=[]
 try:
  d.require_stopped()
  for item in items:
   target=d.safe_path(mods,item['relative']);current=d.sha(target.read_bytes())if target.exists()else None
   if current!=item['before']:raise ValueError('Concurrent modification')
  for item in items:
   attempted.append(item);d.atomic_write(d.safe_path(mods,item['relative']),changes[item['relative']])
  r['status']='applied';d.atomic_write(RECORD,d.encode_json(r));return check()
 except Exception:
  conflicts=[]
  for item in reversed(attempted):
   target=d.safe_path(mods,item['relative']);current=d.sha(target.read_bytes())if target.exists()else None
   if current not in(item['before'],item['after']):conflicts.append(item['relative']);continue
   if item['before']is not None:d.atomic_write(target,d.safe_path(backup,item['relative']).read_bytes())
   elif target.exists():target.unlink()
  r['status']='recovery-required'if conflicts else'rolled-back';r['conflicts']=conflicts;d.atomic_write(RECORD,d.encode_json(r));raise
def rollback():
 d.require_stopped();check();r=d.read_json(RECORD);backup=Path(r['backup_root'])
 if not backup.resolve().is_relative_to((ROOT/'backups/rgl-visual').resolve()):raise ValueError('Unsafe backup path')
 for item in r['files']:
  if item['before']is not None and d.sha(d.safe_path(backup,item['relative']).read_bytes())!=item['before']:raise ValueError('Backup changed')
 for item in reversed(r['files']):
  target=d.safe_path(mods,item['relative'])
  if item['before']is not None:d.atomic_write(target,d.safe_path(backup,item['relative']).read_bytes())
  else:target.unlink()
 b.check();r['status']='rolled-back';d.atomic_write(RECORD,d.encode_json(r));return {'status':'restored-before-visual-overlay'}
if __name__=='__main__':
 parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('action',choices=['apply','check','rollback']);a=parser.parse_args();print(json.dumps(globals()[a.action](),indent=2))
