-- Visual timing is separate from the native charge/ammo gate. Only a
-- confirmed pooled-projectile launch arms the one-second muzzle charge FX.
if PWRGLShotVisual then return PWRGLShotVisual end
local M={states={},duration=1}
local function key(a)return a:GetFullName()..':'..tostring(a:GetAddress())end
local function finite(n)return type(n)=='number'and n==n and math.abs(n)<math.huge end
function M.arm(a)
 local now=PWActorRegistryV21.static('/Script/Engine.Default__GameplayStatics'):GetTimeSeconds(a)
 if not finite(now)then return end
 M.states[key(a)]={start=now,expires=now+M.duration}
end
function M.phase(a,active,now)
 local id=key(a);local s=M.states[id]
 if not active or not s or not finite(now)or now<s.start or now>=s.expires then M.states[id]=nil;return'off'end
 return'charging'
end
function M.prune(seen)
 for id in pairs(M.states)do if not seen[id]then M.states[id]=nil end end
end
PWRGLShotVisual=M;return M
