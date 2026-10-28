"""Execute real BLMU policy and scoped callback profiler with Lua stubs."""
from pathlib import Path
import unittest,importlib.util
try:
    from lupa import LuaRuntime
except ImportError:
    LuaRuntime=None

ROOT=Path(__file__).resolve().parents[1]
def runtime():
    if LuaRuntime is None:raise unittest.SkipTest("Install optional Lupa for Lua tests.")
    lua=LuaRuntime(unpack_returned_tuples=True)
    lua.execute('''
print=function()end
hooks={}; loops={}; actors={}; configs={}
function valid()return true end
function weapon(kind,value)
 local o={HomingForesightAmount=value,MaxRotationAngle=40,MaxHomingAngle=75,Ammo=42,SpeedMaximum=1234,bIsHoming=true}
 function o:IsValid()return true end
 function o:IsActorBeingDestroyed()return false end
 function o:GetClass()return {GetFName=function()return {ToString=function()return kind end}end}end
 return o
end
function RegisterHook(name,fn)hooks[name]=fn end
function RegisterBeginPlayPostHook(fn)hooks.begin=fn end
function LoopInGameThreadWithDelay(interval,fn,...)loops[#loops+1]={interval=interval,fn=fn,args=table.pack(...)};return #loops end
LoopInGameThreadAfterFrames=LoopInGameThreadWithDelay
PWActorRegistryV21={list=function(kind)return actors[kind]or{}end,static=function()return {}end}
configs.GetArrayNum=function()return #configs end
activator={IsValid=valid,EquippedWeapons={IsValid=valid,Configs=configs}}
plane={IsValid=valid,IsActorBeingDestroyed=function()return false end,GetComponentByClass=function()return activator end}
actors.BP_PlayerPlane_PW0001_pwmk_C={plane}
''')
    return lua

class Guidance(unittest.TestCase):
    def setUp(self):
        self.lua=runtime()
        self.lua.execute('M=(function()\n'+(ROOT/'src/PWRuntime/pw-blmu-guidance.lua').read_text()+'\nend)()')
    def test_private_player_and_wingman_only(self):
        self.lua.execute('''
for _,kind in ipairs({'BP_PW_BLMU_C','BP_PW_WingmanBLMU_V58_C'})do
 local w=weapon(kind,0);assert(M.apply(w));assert(w.HomingForesightAmount==1)
 assert(w.MaxRotationAngle==150 and w.MaxHomingAngle==160)
 assert(w.Ammo==42 and w.SpeedMaximum==1234 and w.bIsHoming==true)
 assert(not M.apply(w))
end
for _,kind in ipairs({'BP_PW_RGL_C','BP_PW_EUFB_C','BP_plwp_6aam_a0_C'})do
 local w=weapon(kind,0);assert(not M.apply(w));assert(w.HomingForesightAmount==0)
end
''')
    def test_unknown_invalid_values_refused(self):
        self.lua.execute('''
for _,v in ipairs({-1,3,math.huge,-math.huge,0/0,'unknown'})do
 local w=weapon('BP_PW_BLMU_C',v);assert(not pcall(M.apply,w))
end
assert(not M.apply(nil));assert(not M.apply({IsValid=function()return false end}))
''')
    def test_late_loadout_and_existing_pool_audit(self):
        self.lua.execute('''
local c=weapon('BP_PW_BLMU_C',.1);configs[1]={WeaponClassDefaultObject=c}
local w=weapon('BP_PW_BLMU_C',0);actors.BP_PW_BLMU_C={w}
assert(loops[1].interval==1000 and loops[1].fn()==false)
assert(c.HomingForesightAmount==1 and w.HomingForesightAmount==1)
w.HomingForesightAmount=0
hooks['/Script/Live.LiveWeaponBase:OnInitialized']({get=function()return w end})
assert(w.HomingForesightAmount==1)
configs[1]={WeaponClassDefaultObject=weapon('BP_PW_BLMU_C',0)}
M.refresh();assert(configs[1].WeaponClassDefaultObject.HomingForesightAmount==1)
''')
    def test_setter_failure_restores_scalar(self):
        self.lua.execute('''
local w=weapon('BP_PW_BLMU_C',nil);local v=.2
setmetatable(w,{__index=function(_,k)if k=='HomingForesightAmount'then return v end end,
 __newindex=function(t,k,x)if k=='HomingForesightAmount'then v=x;if x==1 then error('setter failed after mutation')end else rawset(t,k,x)end end})
assert(not pcall(M.apply,w));assert(v==.2)
''')

    def test_invalid_turn_limit_prevents_all_writes(self):
        self.lua.execute('''
local w=weapon('BP_PW_BLMU_C',.9);w.MaxRotationAngle=0/0
assert(not pcall(M.apply,w));assert(w.HomingForesightAmount==.9 and w.MaxHomingAngle==75)
''')
    def test_second_setter_failure_restores_all_fields(self):
        self.lua.execute('''
local w=weapon('BP_PW_BLMU_C',.9);w.MaxRotationAngle=nil;local angle=40
setmetatable(w,{__index=function(_,k)if k=='MaxRotationAngle'then return angle end end,
 __newindex=function(t,k,x)if k=='MaxRotationAngle'then angle=x;if x==150 then error('turn setter failure')end else rawset(t,k,x)end end})
assert(not pcall(M.apply,w));assert(w.HomingForesightAmount==.9 and angle==40 and w.MaxHomingAngle==75)
''')

class Profiler(unittest.TestCase):
    def load(self,marker=True):
        lua=runtime()
        lua.execute('''
PWMkIRuntimeRoot='test/runtime/';samples={};clock_now=100
io.open=function()return MARKER and{close=function()end}or nil end
package.loadlib=function()return function(op,id,start)
 if op==4 then return 2 end
 if op==2 then clock_now=clock_now+5;return clock_now end
 if op==3 then samples[#samples+1]={id=id,start=start};return end
end end
'''.replace('MARKER','true'if marker else'false'))
        lua.execute('P=(function()\n'+(ROOT/'src/PWRuntime/pw-callback-profile.lua').read_text()+'\nend)()')
        return lua
    def test_optional_without_companion_marker(self):
        lua=self.load(False)
        self.assertIsNone(lua.globals().P.install)
    def test_restore_and_callback_returns_args(self):
        self.load().execute('''
local original=LoopInGameThreadWithDelay
P.install()
local handle=LoopInGameThreadWithDelay(33,function(a,b)return false,nil,a+b end,'registered')
P.restore();assert(LoopInGameThreadWithDelay==original)
assert(handle==1 and loops[1].args[1]=='registered')
local r=table.pack(loops[1].fn(3,4));assert(r.n==3 and r[1]==false and r[2]==nil and r[3]==7)
assert(#samples==1 and samples[1].id==0)
''')
    def test_error_is_measured_and_rethrown(self):
        self.load().execute('''
P.install();LoopInGameThreadAfterFrames(1,function()error('original callback failure')end);P.restore()
local ok,e=pcall(loops[1].fn);assert(not ok and tostring(e):find('original callback failure',1,true))
assert(#samples==1)
''')
    def test_bounded_registration_and_disabled_capture(self):
        self.load().execute('''
P.install()
for i=1,70 do LoopInGameThreadWithDelay(10,function()return true end)end
P.restore();assert(P.next_id==64)
assert(loops[70].fn()==true);assert(#samples==0)
''')

class RadarRetry(unittest.TestCase):
    def test_real_pinned_radar_missing_hud_scans_once_per_second(self):
        spec=importlib.util.spec_from_file_location('rev2',ROOT/'tools/deploy_revision2.py')
        deploy=importlib.util.module_from_spec(spec);spec.loader.exec_module(deploy)
        source=deploy.MODS/deploy.RADAR
        if not source.is_file():raise unittest.SkipTest('Matched local PW cockpit radar is required.')
        original=source.read_bytes()
        # After deployment use the verified original backup, never test a
        # patched copy while claiming it is the original-version fixture.
        record=ROOT/'results/revision2-deployment.json'
        if deploy.d.sha(original)!=deploy.RADAR_SHA and record.exists():
            r=deploy.d.read_json(record)
            item=next(x for x in r['files']if x['relative']==deploy.RADAR)
            original=Path(r['backup_root']).joinpath(item['backup']).read_bytes()
        if deploy.d.sha(original)!=deploy.RADAR_SHA:raise unittest.SkipTest('Original pinned radar backup is unavailable.')
        patched=deploy.patched_radar(original)
        lua=runtime()
        budget=(ROOT/'src/PWRuntime/pw-hud-discovery-budget.lua').read_text()
        lua.execute('B=(function()'+budget+'\nend)()')
        lua.execute('''
PWMkIRuntimeRoot='runtime/';scans=0;t=0
local cls={IsValid=valid}
StaticFindObject=function()return cls end
FName=function(x)return x end
FindAllOf=function()scans=scans+1;return {}end
dofile=function(path)if path:find('discovery%-budget')then return B else return {}end end
local gs={GetTimeSeconds=function()return t end,GetPlayerCameraManager=function()return nil end}
PWActorRegistryV21.static=function()return gs end
plane.CockpitMesh={IsValid=valid,bVisible=true,bHiddenInGame=false}
plane.IsPlayerControlled=function()return true end
plane.GetFullName=function()return 'Plane /test/plane' end
plane.GetAddress=function()return 1234 end
plane.FindComponentByTag=function()return nil end
plane.K2_GetActorLocation=function()return {X=0,Y=0,Z=0}end
''')
        lua.execute(patched.decode())
        lua.execute('''
for _,time in ipairs({0,.25,.5,.75,1,1.25,1.5,1.75,2})do t=time;PWCockpitRadarV74.pulse()end
assert(scans==3)
t=.1;PWCockpitRadarV74.pulse();assert(scans==4) -- world clock rewind
plane.GetAddress=function()return 5678 end
PWCockpitRadarV74.pulse();assert(scans==5) -- new pawn gets immediate attempt
local count=0;for _ in pairs(B.states)do count=count+1 end;assert(count==1)
''')
    def test_budget_invalid_clock_and_prune(self):
        lua=runtime();lua.execute('B=(function()'+(ROOT/'src/PWRuntime/pw-hud-discovery-budget.lua').read_text()+'\nend)()')
        lua.execute("assert(not B.allow('x',0/0));assert(not B.allow('x',math.huge));assert(B.allow('x',5));assert(not B.allow('x',5));B.prune({});assert(next(B.states)==nil)")
    def test_hidden_external_camera_preserves_cockpit_and_unknown_samples(self):
        lua=runtime();lua.execute('B=(function()'+(ROOT/'src/PWRuntime/pw-hud-discovery-budget.lua').read_text()+'\nend)()')
        lua.execute('''
local plane={X=1e8,Y=-2e8,Z=10000}
assert(not B.visible(false,nil,nil))
assert(B.visible(true,nil,plane))
assert(B.visible(true,{X=1e8+677,Y=-2e8,Z=10078},plane))
assert(not B.visible(true,{X=1e8-3600,Y=-2e8,Z=10600},plane))
assert(B.visible(true,{X=0/0,Y=0,Z=0},plane))
''')

if __name__=='__main__':unittest.main()
