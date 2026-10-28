-- Runs the actual patched main.lua with mock UE4SS/game objects. No game/DLL.
-- Usage: lua test_callback_finish.lua <patched Scripts/main.lua>
local source=assert(io.open(assert(arg[1],'main.lua path'),'rb')):read('*a')
local checks=0
local function check(value,message)checks=checks+1;assert(value,message)end
local function fixture(has_pawn)
 local events,callback={},nil
 local open=false
 local function event(s)events[#events+1]=s end
 local function object(t)t=t or {};t.IsValid=function()return true end;return t end
 local gameplay=object({GetWorldDeltaSeconds=function()return .1 end,GetRealTimeSeconds=function()return 100 end,IsGamePaused=function()return false end})
 local pawn=object({GetAddress=function()return 65536 end,IsA=function()return true end,
  K2_GetActorRotation=function()return {Pitch=0,Yaw=0,Roll=0}end,K2_GetActorLocation=function()return {X=0,Y=0,Z=0}end,
  GetFullName=function()return 'LivePlayerPlane fixture' end,bEnableWingInput=true,bEnableMovmentInput=true})
 local manager=object({GetAddress=function()return 131072 end,GetCameraRotation=function()return {Pitch=0,Yaw=0,Roll=0}end,
  GetFOVAngle=function()return 62 end,GetCameraLocation=function()return {X=-3000,Y=0,Z=600}end})
 local controller=object({Pawn=has_pawn and pawn or nil,PlayerCameraManager=manager,GetAddress=function()return 196608 end,
  GetViewTarget=function()return pawn end})
 local engine=object({GameViewport=object({World=object({OwningGameInstance=object({LocalPlayers={object({PlayerController=controller})}})})})})
 local class=object()
 local view={reset=function()end,optional_bool=function(_,obj,key,default)local v=obj[key];if v==nil then return default end;return v end,
  update=function()return true,false end}
 local modules={
  ['camera.lua']={restore=function()event('restore')end,configure=function()end,update=function()return nil end},
  ['gaze_probe.lua']={end_mission=function()end,update=function()end,request=function()end},
  ['gaze.lua']={reset=function()end,update=function()return false,false,false end},
  ['observation.lua']={identity=function()return 1 end},
  ['view_context.lua']={new=function()return view end},
  ['helmet.lua']={new=function()return {clear=function()end,update=function()end}end},
  ['native_hud.lua']={start=function()end,hide=function()event('hud-hide')end,update=function()event('hud-update')end}
 }
 local fail_helmet=false
 local api={
  ac8_mouseaim_start=function()return 30 end,
  ac8_mouseaim_begin=function(finish)
   if finish==1 then check(open,'finish without matching begin');event('finish');open=false
   else check(not open,'nested callback begin');open=true;event('begin')end
  end,
  ac8_mouseaim_helmet_state=function()if fail_helmet then error('fixture helmet failure')end;return 0 end,
  ac8_mouseaim_frame=function()return 0,0,0 end,
  ac8_mouseaim_context=function()return 1 end,
  ac8_mouseaim_manual_look=function()return 0 end,
  ac8_mouseaim_camera_fov=function()return 62 end,
  ac8_mouseaim_camera=function()event('camera');return 1 end,
  ac8_mouseaim_release=function()event('release')end
 }
 local env=setmetatable({
  dofile=function(path)return assert(modules[path:match('([^/\\]+)$')],path)end,
  package={loadlib=function(_,symbol)return api[symbol]or function()return 1 end end},
  print=function()event('notice')end,Key={F10=121,F6=117,F5=116},RegisterKeyBind=function()end,
  RegisterInitGameStatePreHook=function()end,EngineTickAvailable=true,
  LoopInGameThreadAfterFrames=function(_,fn)callback=fn end,
  StaticFindObject=function(path)return path:find('GameplayStatics',1,true)and gameplay or class end,
  FindFirstOf=function()return engine end,os={time=function()return 100 end}
 },{__index=_G})
 assert(load(source,'@/fixture/Scripts/main.lua','t',env))()
 local function tick()
  for i=#events,1,-1 do events[i]=nil end
  callback()
  check(events[1]=='begin'and events[#events]=='finish','callback did not bracket all work')
  check(not open,'callback left timing open')
  return events
 end
 return tick,function()fail_helmet=true end
end

local tick=fixture(true)
for i=1,6 do tick()end
local e=tick();local camera,hud,finish
for i,v in ipairs(e)do if v=='camera'then camera=i elseif v=='hud-update'then hud=i elseif v=='finish'then finish=i end end
check(camera and hud and finish and camera<hud and hud<finish,'finish ran before HUD update')

local idle=fixture(false);e=idle()
check(table.concat(e,','):find('hud%-hide')~=nil,'no-pawn fixture did not run HUD cleanup')
idle() -- next_search early-return path must still finish.

local failing,fail=fixture(true);fail();e=failing()
local release_index
for i,v in ipairs(e)do if v=='release'then release_index=i end end
check(release_index and release_index<#e,'finish omitted runtime-error recovery')
print('PASS actual main.lua full-callback finish: '..checks..' checks (normal HUD, startup, no pawn, early return, native error)')
