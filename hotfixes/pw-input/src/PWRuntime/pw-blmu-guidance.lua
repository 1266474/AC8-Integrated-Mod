-- MSL lead tracking plus QAAM turn limits from Integrated full missile mode.
-- No scripted steering loop; native FCS keeps target, ammo, reload and flight.
if PWBLMUGuidanceHotfix then return PWBLMUGuidanceHotfix end
local M={value=1,changed=0,failures=0}
local policy={{'HomingForesightAmount',1,0,2},{'MaxRotationAngle',150,0,180},{'MaxHomingAngle',160,0,180}}
PWBLMUGuidanceHotfix=M
local registry=assert(PWActorRegistryV21,'PW actor registry unavailable')
local kinds={'BP_PW_BLMU_C','BP_PW_WingmanBLMU_V58_C'}
local allowed={};for _,kind in ipairs(kinds)do allowed[kind]=true end
local function valid(o)return o and o:IsValid()end
local function name(o)return valid(o)and o:GetClass():GetFName():ToString()or''end
local function finite(n)return type(n)=='number'and n==n and math.abs(n)<math.huge end
function M.apply(w)
 if not valid(w)or not allowed[name(w)]then return false end
 local old={};local changed=false
 -- Validate every field before writing any field.
 for i,p in ipairs(policy)do
  local v=w[p[1]];assert(finite(v)and v>=p[3]and v<=p[4],'Unexpected BLMU '..p[1])
  old[i]=v;if math.abs(v-p[2])>=1e-6 then changed=true end
 end
 if not changed then return false end
 local ok,err=pcall(function()
  for _,p in ipairs(policy)do
   if math.abs(w[p[1]]-p[2])>=1e-6 then w[p[1]]=p[2]end
   assert(finite(w[p[1]])and math.abs(w[p[1]]-p[2])<1e-6,'BLMU guidance readback mismatch: '..p[1])
  end
 end)
 if not ok then
  -- A setter may mutate before raising; attempt every owned field on rollback.
  local errors={}
  for i=#policy,1,-1 do
   local key=policy[i][1]
   local restored,why=pcall(function()if w[key]~=old[i]then w[key]=old[i]end;assert(w[key]==old[i])end)
   if not restored then errors[#errors+1]=tostring(why)end
  end
  error(tostring(err)..(#errors==0 and' (restored)'or' (restore failed: '..table.concat(errors,';')..')'))
 end
 M.changed=M.changed+1
 return true
end
local function guarded(fn,...)
 local ok,err=pcall(fn,...)
 if not ok then
  M.failures=M.failures+1
  if M.failures<=3 then print('[PW BLMU guidance] '..tostring(err)..'\n')end
 end
end
function M.refresh()
 -- CDOs are resolved via the current loadout, including after respawn/loadout
 -- changes. No hardcoded asset path and no global stock missile modification.
 for _,a in ipairs(registry.list('BP_PlayerPlane_PW0001_pwmk_C')or{})do
  if valid(a)and not a:IsActorBeingDestroyed()then
   local av=a:GetComponentByClass(registry.static('/Script/Live.LivePlayerWeaponActivator'))
   if valid(av)and valid(av.EquippedWeapons)then
    local configs=av.EquippedWeapons.Configs
    for i=1,configs:GetArrayNum()do M.apply(configs[i].WeaponClassDefaultObject)end
   end
  end
 end
 -- Pools can predate this script or bypass Blueprint OnInitialized. Native
 -- weapon initialization may also refresh the scalar on reuse, so audit at
 -- 1 Hz; callbacks below handle the normal activation boundary immediately.
 for _,kind in ipairs(kinds)do
  for _,w in ipairs(registry.list(kind)or{})do
   if valid(w)and not w:IsActorBeingDestroyed()then M.apply(w)end
  end
 end
end
local function initialized(context)guarded(function()M.apply(context:get())end)end
RegisterHook('/Script/Live.LiveWeaponBase:OnInitialized',initialized)
RegisterHook('/Script/Live.LiveWeaponBase:OnCreateWeapon_BP',initialized)
RegisterBeginPlayPostHook(initialized)
M.loop=LoopInGameThreadWithDelay(1000,function()guarded(M.refresh);return false end)
print('[PW BLMU guidance] MSL lead=1.0; QAAM MaxRotationAngle=150 MaxHomingAngle=160; private SP missiles only\n')
return M
