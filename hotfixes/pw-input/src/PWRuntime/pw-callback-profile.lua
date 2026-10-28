-- Temporarily wrap only PW's registrations while main.lua loads its modules.
-- Native QPC timing avoids os.clock (whole-process CPU time on Windows).
local M={entries={},next_id=0}
local path=PWMkIRuntimeRoot..'../../../AC8MouseAim/Scripts/ac8_mouse_aim_010.dll'
local marker=io.open(path..'.pw-profile-v2','rb')
if not marker then return M end
marker:close()
local clock=package.loadlib(path,'ac8_mouseaim_perf')
if not clock or clock(4)~=2 then return M end
local saved={}
function M.install()
 for _,name in ipairs({'LoopInGameThreadWithDelay','LoopInGameThreadAfterFrames'})do
  local register=_G[name]
  if type(register)=='function'then
   saved[name]=register
   _G[name]=function(interval,callback,...)
    local id=M.next_id
    if id>=64 or type(callback)~='function'then return register(interval,callback,...)end
    M.next_id=id+1
    local info=debug.getinfo(callback,'S')or{}
    local source=(info.source or'?'):gsub('\\','/'):match('([^/]+)$')or'?'
    M.entries[id]={source=source,line=info.linedefined or 0,interval=interval}
    print(string.format('[PW PROFILE MAP] id=%d file=%s line=%d %s=%s\n',id,source,info.linedefined or 0,name,tostring(interval)))
    return register(interval,function(...)
     local start=clock(2)
     local result=table.pack(pcall(callback,...))
     if start and start>0 then clock(3,id,start)end
     if not result[1]then error(result[2],0)end
     return table.unpack(result,2,result.n)
    end,...)
   end
  end
 end
end
function M.restore()
 for name,register in pairs(saved)do _G[name]=register end
 saved={}
end
return M
