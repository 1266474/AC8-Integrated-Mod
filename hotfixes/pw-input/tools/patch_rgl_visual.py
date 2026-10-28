"""Version-pinned visual-only RGL patch; no third-party payload distributed."""
from pathlib import Path
import hashlib
RGL='PWMkI/Scripts/runtime/runtime-pw-rgl-v54.lua'
LAUNCH='PWMkI/Scripts/runtime/runtime-pw-projectile-launch-v54.lua'
HASHES={RGL:'106F5FA243766FFB57C8B10112AFED3AD116D490221A1D155F2F243B8FD71490',LAUNCH:'0B7B9700032292A2A2D52250D2F049AAD4BB8F0691F0406FB883998730D902F4'}
def patch(rel,data):
 if hashlib.sha256(data).hexdigest().upper()!=HASHES[rel]:raise ValueError('Unsupported RGL visual baseline: '+rel)
 s=data.decode('utf-8').replace('\r\n','\n')
 if rel==LAUNCH:
  edits={'if launch(w,a)then':'if launch(w,a)then\n      PWRGLShotVisual.arm(a)'}
 else:
  old="""    if phase~=s.phase then
     audio.charge(a,phase,s.phase)
     if valid(c)then if phase=='charging'or phase=='ready'then
       if s.phase~='charging'and s.phase~='ready'then c:Activate(true)end
      else c:Deactivate()end end
"""
  new="""    if visualPhase~=(s.visualPhase or'off')then
     audio.charge(a,visualPhase,s.visualPhase or'off')
     if valid(c)then if visualPhase=='charging'then c:Activate(true)else c:Deactivate()end end
     s.visualPhase=visualPhase
    end
    if phase~=s.phase then
"""
  edits={"local states={};local errors=0":"local states={};local errors=0\nlocal shotVisual=dofile(root..'pw-rgl-shot-visual.lua')",'    if cancharge and not valid(c)then':"    local visualPhase=shotVisual.phase(a,active,now)\n    if visualPhase=='charging'and not valid(c)then",old:new,' for k,s in pairs(states)do if not seen[k]then':' shotVisual.prune(seen)\n for k,s in pairs(states)do if not seen[k]then'}
 for before,after in edits.items():
  if s.count(before)!=1:raise ValueError('Ambiguous patch anchor')
  s=s.replace(before,after)
 return s.encode('utf-8')
