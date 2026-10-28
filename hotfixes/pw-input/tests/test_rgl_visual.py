from pathlib import Path
import importlib.util,unittest,os,json
try:from lupa import LuaRuntime
except ImportError:LuaRuntime=None
ROOT=Path(__file__).resolve().parents[1]
s=importlib.util.spec_from_file_location('visual_patch',ROOT/'tools/patch_rgl_visual.py');p=importlib.util.module_from_spec(s);s.loader.exec_module(p)
@unittest.skipIf(LuaRuntime is None,'Optional Lua runtime required')
class Visual(unittest.TestCase):
 def setUp(self):
  self.l=LuaRuntime();self.l.execute('''
print=function()end;t=0;activations=0;deactivations=0;audioEvents={}
function valid()return true end
function FName(x)return x end
plane={IsValid=valid,IsActorBeingDestroyed=function()return false end,IsPlayerControlled=valid,IsLocallyControlled=valid,IsWeaponSystemDisabled=function()return false end,GetFullName=function()return 'Plane /test' end,GetAddress=function()return 1 end}
local c={IsValid=valid,Activate=function()activations=activations+1 end,Deactivate=function()deactivations=deactivations+1 end}
plane.FindComponentByTag=function()return c end
gun={IsValid=valid,FCSActivationTime=-900010,GetClass=function()return {GetFName=function()return {ToString=function()return 'BP_PW_RGL_C'end}end}end,GetFullName=function()return 'Weapon /gun'end}
configs={[1]={},[2]={WeaponClassDefaultObject=gun},GetArrayNum=function()return 2 end}
av={IsValid=valid,EquippedWeapons={IsValid=valid,Configs=configs},PWSelectedWeaponSlotV19=0,GetWeaponCount=function()return 1 end}
plane.GetComponentByClass=function()return av end
PWActorRegistryV21={static=function()return {GetTimeSeconds=function()return t end}end,list=function()return {plane}end}
RegisterCustomProperty=function()end;PropertyTypes={IntProperty=1};RegisterHook=function()end;RegisterBeginPlayPostHook=function()end
LoopInGameThreadWithDelay=function()return 1 end
PWMkIRuntimeRoot='runtime/'
''')
  self.l.execute('V=(function()\n'+(ROOT/'src/PWRuntime/pw-rgl-shot-visual.lua').read_text(encoding='utf-8')+'\nend)()')
 def test_selection_never_arms(self):self.l.execute("assert(V.phase(plane,true,0)=='off');t=10;assert(V.phase(plane,true,t)=='off')")
 def test_actual_shot_visible_then_expires(self):self.l.execute("V.arm(plane);assert(V.phase(plane,true,0)=='charging');assert(V.phase(plane,true,.99)=='charging');assert(V.phase(plane,true,1)=='off')")
 def test_switch_cancel_does_not_replay_on_reselect(self):self.l.execute("V.arm(plane);assert(V.phase(plane,false,0)=='off');assert(V.phase(plane,true,.1)=='off')")
 def test_clock_rewind_respawn_and_prune(self):self.l.execute("t=10;V.arm(plane);assert(V.phase(plane,true,9)=='off');V.arm(plane);V.prune({});assert(next(V.states)==nil)")
 def test_real_rgl_pulse_preserves_gate_without_selection_fx(self):
  mods=Path(os.environ['LOCALAPPDATA'])/'Programs/AC8 Integrated/data/ue4ss-mods'
  source=mods/p.RGL
  if not source.exists():self.skipTest('Matched PW local fixture required')
  data=source.read_bytes()
  if __import__('hashlib').sha256(data).hexdigest().upper()!=p.HASHES[p.RGL]:
   rec=ROOT/'results/rgl-visual-deployment.json'
   if not rec.exists():self.skipTest('Original pinned fixture unavailable')
   r=json.loads(rec.read_text());data=(Path(r['backup_root'])/p.RGL).read_bytes()
  self.l.execute('''
dofile=function(path)
 if path:find('shot%-visual')then return V end
 if path:find('targets')then return {list=function()return {}end}end
 if path:find('native%-selection')then return {ensure=function()end,release=function()end}end
 if path:find('audio')then return {charge=function(a,phase)audioEvents[#audioEvents+1]=phase end}end
 return {}
end
''')
  self.l.execute(p.patch(p.RGL,data).decode())
  self.l.execute('''
PWRGLV20Pulse();assert(activations==0 and #audioEvents==0)
t=1.1;PWRGLV20Pulse();assert(gun.bFCSUseBaseLockOn==true and activations==0)
V.arm(plane);PWRGLV20Pulse();assert(activations==1 and audioEvents[1]=='charging')
t=2.2;PWRGLV20Pulse();assert(deactivations==1 and audioEvents[2]=='off')
assert(gun.bFCSUseBaseLockOn==true) -- visual expiry never closes firing gate
''')
