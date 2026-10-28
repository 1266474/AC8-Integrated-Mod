-- Bound failed HUD discovery without retaining any UObject or changing the
-- accepted radar render rate. Each new actor gets an immediate first attempt.
local M={interval=1,states={}}
function M.visible(mesh_visible,camera,plane)
 if not mesh_visible then return false end
 -- The far-follow mod camera can leave native CockpitMesh visibility true.
 -- Keep a conservative 12m sphere around the aircraft for cockpit/HMD views;
 -- the configured far-follow rig is 36m away. Unknown samples keep stock
 -- visibility rather than hiding a cockpit display on a failed camera read.
 if not camera or not plane then return true end
 local d=0
 for _,k in ipairs({'X','Y','Z'})do
  local a,b=camera[k],plane[k]
  if type(a)~='number'or type(b)~='number'or a~=a or b~=b or math.abs(a)==math.huge or math.abs(b)==math.huge then return true end
  d=d+(a-b)^2
 end
 return d<=1200^2
end
function M.allow(id,now)
 if type(now)~='number'or now~=now or math.abs(now)==math.huge then return false end
 local s=M.states[id]
 if s and now>=s.time and now<s.next then s.time=now;return false end
 M.states[id]={time=now,next=now+M.interval};return true
end
function M.prune(seen)
 for id in pairs(M.states)do if not seen[id]then M.states[id]=nil end end
end
return M
