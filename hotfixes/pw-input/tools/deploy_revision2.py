"""Version-guarded BLMU guidance and automatic profiling, layered over rev 1."""
from pathlib import Path
import argparse, importlib.util, json, os, sys
from datetime import datetime, timezone

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('native_deploy',ROOT/'tools/deploy_native.py')
d=importlib.util.module_from_spec(spec);spec.loader.exec_module(d)
MODS=Path(os.environ['LOCALAPPDATA'])/'Programs/AC8 Integrated/data/ue4ss-mods'
PW_MAIN='PWMkI/Scripts/main.lua'
PW_MAIN_SHA='B27AB6EE2381C1A29FB5924213E17B5116E8825EA1A35E31C5EAD6D86E1FE41B'
RADAR='PWMkI/Scripts/runtime/runtime-pw-cockpit-radar-v74.lua'
RADAR_SHA='50C2AD7D53046F53827BFB4F59D4364EC2DAD7CBBED9EBA028E4C5E5B024327B'
TAG='20261028-blmu-profile-2'
SCRIPT_PREFIX='payload/Game/Binaries/Win64/ue4ss/Mods/AC8MouseAim/Scripts/'

def write(path,data):d.atomic_write(path,data)
def record_path(root):return root/'results/revision2-deployment.json'
def target(install,mods,item):return d.safe_path(install if item['area']=='package'else mods,item['relative'])
def candidate_paths(root):
    if (root/'src/MouseAim').is_dir():return root/'src/MouseAim',root/'src/PWRuntime'
    return root.parents[1]/'native',root/'src/PWRuntime'

def patched_main(original):
    if d.sha(original)!=PW_MAIN_SHA:raise ValueError('Unsupported PW-MkI entry point')
    text=original.decode('utf-8').replace('\r\n','\n')
    anchor="dofile(PWMkIRuntimeRoot..'runtime-pw-actor-registry-v21.lua')"
    tail="dofile(PWMkIRuntimeRoot..'runtime-pw-eufb-cloud-v113.lua')"
    if text.count(anchor)!=1 or text.count(tail)!=1:raise ValueError('Ambiguous PW entry point')
    prelude="""local callbackProfile=dofile(PWMkIRuntimeRoot..'pw-callback-profile.lua')
callbackProfile.install=callbackProfile.install or function()end
callbackProfile.restore=callbackProfile.restore or function()end
callbackProfile.install()
local loaded,loadError=pcall(function()
dofile(PWMkIRuntimeRoot..'pw-blmu-guidance.lua')"""
    ending="""end)
callbackProfile.restore()
if not loaded then error(loadError,0)end"""
    return text.replace(anchor,anchor+'\n'+prelude).replace(tail,tail+'\n'+ending).encode('utf-8')

def patched_radar(original):
    if d.sha(original)!=RADAR_SHA:raise ValueError('Unsupported PW cockpit radar revision')
    text=original.decode('utf-8').replace('\r\n','\n')
    edits={
        'local registry=assert(PWActorRegistryV21)':"local registry=assert(PWActorRegistryV21)\nlocal discoveryBudget=dofile(PWMkIRuntimeRoot..'pw-hud-discovery-budget.lua')",
        'local function source_for(a)':"local function source_for(a)\n local now=registry.static('/Script/Engine.Default__GameplayStatics'):GetTimeSeconds(a)\n if not discoveryBudget.allow(identity(a),now)then return end",
        ' api.activeOwners=active':' discoveryBudget.prune(seen)\n api.activeOwners=active',
        ' return valid(c)and c.bVisible and not c.bHiddenInGame':""" if not(valid(c)and c.bVisible and not c.bHiddenInGame)then return false end
 local gs=registry.static('/Script/Engine.Default__GameplayStatics')
 local cm=gs:GetPlayerCameraManager(a,0)
 return discoveryBudget.visible(true,valid(cm)and cm:GetCameraLocation()or nil,a:K2_GetActorLocation())""",
    }
    for before,after in edits.items():
        if text.count(before)!=1:raise ValueError('Ambiguous radar source anchor')
        text=text.replace(before,after)
    return text.encode('utf-8')

def check(install,mods,root):
    record=d.read_json(record_path(root))
    if record['status']!='applied':raise ValueError('Revision 2 is not applied')
    if Path(record['install_root']).resolve()!=install.resolve()or Path(record['mods_root']).resolve()!=mods.resolve():raise ValueError('Record belongs to another installation')
    for item in record['files']:
        p=target(install,mods,item)
        if not p.is_file()or d.sha(p.read_bytes())!=item['after_sha256']:raise ValueError('Deployed file changed: '+item['relative'])
    return {'status':'applied','id':TAG,**d.verify_package(install)[2]['local_hotfix']}

def prepare(install,mods,root):
    d.require_stopped()
    # Rev 1's immutable deployment hashes validate the complete previous state.
    first=d.read_json(root/'results/native-deployment.json')
    if first['status']!='applied':raise ValueError('Apply revision 1 first')
    d.check_deployment(install,root)
    files,manifest,info=d.verify_package(install)
    if info.get('local_hotfix',{}).get('id')!='20261028-input-inbox-1':raise ValueError('Unsupported base revision')
    native,pw=candidate_paths(root)
    dll=(native/'build/ac8_mouse_aim_010.dll').read_bytes();d.validate_dll(dll)
    if d.sha(dll)==info['native_sha256'].upper():raise ValueError('Build the revision 2 native DLL first')
    if d.sha(d.safe_path(mods,PW_MAIN).read_bytes())!=PW_MAIN_SHA:raise ValueError('PW-MkI main.lua differs from pinned 1.2.0')
    changes={('package',d.DLL_REL):dll}
    for folder in ('src','include'):
        for p in sorted((native/folder).rglob('*')):
            if p.is_file():
                if p.is_symlink():raise ValueError('Candidate symlink refused')
                rel='source/MouseAim/'+p.relative_to(native).as_posix()
                before=d.safe_path(install,rel)
                if not before.exists()or before.read_bytes()!=p.read_bytes():changes['package',rel]=p.read_bytes()
    changes['package',SCRIPT_PREFIX+'ac8_mouse_aim_010.dll.pw-profile-v2']=b'PW callback profiling protocol 2\n'
    changes['mods',PW_MAIN]=patched_main(d.safe_path(mods,PW_MAIN).read_bytes())
    changes['mods',RADAR]=patched_radar(d.safe_path(mods,RADAR).read_bytes())
    for name in ('pw-blmu-guidance.lua','pw-callback-profile.lua','pw-hud-discovery-budget.lua'):
        rel='PWMkI/Scripts/runtime/'+name
        if d.safe_path(mods,rel).exists():raise ValueError('New PW module already exists: '+rel)
        changes['mods',rel]=(pw/name).read_bytes()
    by_path={x['Path'].replace('\\','/'):x for x in manifest}
    for (area,rel),data in changes.items():
        if area!='package'or not rel.startswith('payload/'):continue
        key=rel[len('payload/'):]
        if key in by_path:by_path[key]['SHA256']=d.sha(data)
        else:manifest.append({'Path':key.replace('/','\\'),'SHA256':d.sha(data)})
    changes['package','payload-manifest.json']=d.encode_json(manifest)
    info['native_sha256']=d.sha(dll).lower()
    info['local_hotfix']={'id':TAG,'base_version':'2.5.2','official_release':False,'stutter_status':'under-investigation','blmu_guidance':.9}
    changes['package','package-info.json']=d.encode_json(info)
    listed={rel for _,rel in files}
    updated=[(d.sha(changes['package',rel])if('package',rel)in changes else digest,rel)for digest,rel in files]
    updated.extend((d.sha(data),rel)for(area,rel),data in changes.items()if area=='package'and rel not in listed)
    changes['package','FILES.sha256']=(''.join(h.lower()+'  '+rel+'\n'for h,rel in updated)).encode()
    return changes

def apply(install,mods,root):
    d.require_stopped()
    rp=record_path(root)
    if rp.exists()and d.read_json(rp)['status']=='applied':return check(install,mods,root)
    changes=prepare(install,mods,root)
    stamp=datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
    backup=root/'backups/revision2'/stamp;items=[]
    for(area,rel),content in changes.items():
        item={'area':area,'relative':rel,'after_sha256':d.sha(content)}
        p=target(install,mods,item);old=p.read_bytes()if p.exists()else None
        item['before_sha256']=d.sha(old)if old is not None else None
        item['backup']=f'{area}/{rel}'if old is not None else None
        if old is not None:write(d.safe_path(backup,item['backup']),old)
        items.append(item)
    record={'id':TAG,'status':'prepared','install_root':str(install.resolve()),'mods_root':str(mods.resolve()),'backup_root':str(backup.resolve()),'files':items}
    write(rp,d.encode_json(record));attempted=[]
    try:
        d.require_stopped()
        for item in items:
            p=target(install,mods,item)
            current=p.read_bytes()if p.exists()else None
            if(d.sha(current)if current is not None else None)!=item['before_sha256']:raise ValueError('Concurrent file change: '+item['relative'])
        for item in items:
            p=target(install,mods,item);attempted.append(item)
            write(p,changes[item['area'],item['relative']])
            if d.sha(p.read_bytes())!=item['after_sha256']:raise ValueError('Write readback mismatch')
        d.verify_package(install)
    except Exception:
        conflicts=[]
        for item in reversed(attempted):
            p=target(install,mods,item)
            current=d.sha(p.read_bytes())if p.exists()else None
            if current not in (item['before_sha256'],item['after_sha256']):conflicts.append(item['relative']);continue
            if item['backup']:write(p,d.safe_path(backup,item['backup']).read_bytes())
            elif p.exists():p.unlink()
        record['status']='recovery-required'if conflicts else'rolled-back';record['conflicts']=conflicts
        write(rp,d.encode_json(record));raise
    record['status']='applied';write(rp,d.encode_json(record));return check(install,mods,root)

def rollback(install,mods,root):
    d.require_stopped();check(install,mods,root)
    rp=record_path(root);r=d.read_json(rp);backup=Path(r['backup_root'])
    if not backup.resolve().is_relative_to((root/'backups/revision2').resolve()):raise ValueError('Backup escaped workspace')
    for item in r['files']:
        if item['backup']and d.sha(d.safe_path(backup,item['backup']).read_bytes())!=item['before_sha256']:raise ValueError('Backup changed')
    for item in reversed(r['files']):
        p=target(install,mods,item)
        if item['backup']:write(p,d.safe_path(backup,item['backup']).read_bytes())
        else:p.unlink()
    d.check_deployment(install,root)
    r['status']='rolled-back';write(rp,d.encode_json(r));return {'status':'rolled-back-to-revision1'}

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('action',choices=['prepare','apply','check','rollback'])
    ap.add_argument('--install-root',type=Path,default=d.INSTALL);ap.add_argument('--mods-root',type=Path,default=MODS);ap.add_argument('--workspace',type=Path,default=ROOT)
    a=ap.parse_args()
    try:
        if a.action=='prepare':result={'status':'prepared-read-only','files':[{'area':area,'relative':rel,'after_sha256':d.sha(data)}for(area,rel),data in prepare(a.install_root,a.mods_root,a.workspace).items()]}
        else:result=globals()[a.action](a.install_root,a.mods_root,a.workspace)
        print(json.dumps(result,ensure_ascii=False,indent=2));return 0
    except Exception as e:print('REFUSED: '+str(e),file=sys.stderr);return 1
if __name__=='__main__':raise SystemExit(main())
