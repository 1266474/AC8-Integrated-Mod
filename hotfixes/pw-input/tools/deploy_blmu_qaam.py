"""Guarded BLMU MSL/QAAM overlay on an applied revision 2; game must be closed."""
from pathlib import Path
import argparse,json,importlib.util
from datetime import datetime,timezone
ROOT=Path(__file__).resolve().parents[1]
s=importlib.util.spec_from_file_location('revision2',ROOT/'tools/deploy_revision2.py')
r=importlib.util.module_from_spec(s);s.loader.exec_module(r);d=r.d
REL='PWMkI/Scripts/runtime/pw-blmu-guidance.lua'
TAG='20261028-blmu-msl-qaam-3'
record=ROOT/'results/blmu-qaam-deployment.json'
roots={'package':d.INSTALL,'mods':r.MODS,'workspace':ROOT}
def target(item):return d.safe_path(roots[item['area']],item['relative'])
def check():
 a=d.read_json(record)
 if a['status']!='applied':raise ValueError('Overlay not applied')
 for item in a['files']:
  if d.sha(target(item).read_bytes())!=item['after']:raise ValueError('Changed deployment: '+item['relative'])
 r.check(d.INSTALL,r.MODS,ROOT)
 return {'status':'applied','id':TAG,'tracking':1,'rotation':150,'homing_angle':160}
def apply():
 d.require_stopped()
 if record.exists()and d.read_json(record)['status']=='applied':return check()
 r.check(d.INSTALL,r.MODS,ROOT)
 files,_,info=d.verify_package(d.INSTALL)
 info['local_hotfix'].update(blmu_guidance=1,blmu_rotation=150,blmu_homing_angle=160,blmu_overlay=TAG)
 changes={('mods',REL):(ROOT/'src/PWRuntime/pw-blmu-guidance.lua').read_bytes(),('package','package-info.json'):d.encode_json(info)}
 changes['package','FILES.sha256']=''.join((d.sha(changes['package',rel])if('package',rel)in changes else digest).lower()+'  '+rel+'\n'for digest,rel in files).encode()
 # Preserve the original revision-2 record in the overlay backup, then update
 # its owned hashes so revision-2 check and rollback remain usable.
 rev=d.read_json(r.record_path(ROOT))
 for item in rev['files']:
  if(item['area'],item['relative'])in changes:item['after_sha256']=d.sha(changes[item['area'],item['relative']])
 changes['workspace','results/revision2-deployment.json']=d.encode_json(rev)
 backup=ROOT/'backups/blmu-qaam'/datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
 items=[]
 for(area,rel),data in changes.items():
  item={'area':area,'relative':rel,'after':d.sha(data)};old=target(item).read_bytes()
  item['before']=d.sha(old);item['backup']=area+'/'+rel
  d.atomic_write(d.safe_path(backup,item['backup']),old);items.append(item)
 a={'id':TAG,'status':'prepared','backup_root':str(backup),'files':items}
 d.atomic_write(record,d.encode_json(a));attempted=[]
 try:
  d.require_stopped()
  for item in items:
   if d.sha(target(item).read_bytes())!=item['before']:raise ValueError('Concurrent change')
  for item in items:
   attempted.append(item);d.atomic_write(target(item),changes[item['area'],item['relative']])
  a['status']='applied';d.atomic_write(record,d.encode_json(a));return check()
 except Exception:
  conflicts=[]
  for item in reversed(attempted):
   if d.sha(target(item).read_bytes())not in(item['before'],item['after']):conflicts.append(item['relative']);continue
   d.atomic_write(target(item),d.safe_path(backup,item['backup']).read_bytes())
  a['status']='recovery-required'if conflicts else'rolled-back';a['conflicts']=conflicts
  d.atomic_write(record,d.encode_json(a));raise
def rollback():
 d.require_stopped();check();a=d.read_json(record);backup=Path(a['backup_root'])
 if not backup.resolve().is_relative_to((ROOT/'backups/blmu-qaam').resolve()):raise ValueError('Unsafe backup path')
 for item in a['files']:
  if d.sha(d.safe_path(backup,item['backup']).read_bytes())!=item['before']:raise ValueError('Backup changed')
 for item in reversed(a['files']):d.atomic_write(target(item),d.safe_path(backup,item['backup']).read_bytes())
 r.check(d.INSTALL,r.MODS,ROOT);a['status']='rolled-back';d.atomic_write(record,d.encode_json(a))
 return {'status':'restored-revision2'}
if __name__=='__main__':
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('action',choices=['apply','check','rollback']);a=p.parse_args()
 print(json.dumps(globals()[a.action](),indent=2))
