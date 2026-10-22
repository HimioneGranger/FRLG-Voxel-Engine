-- Keep a thrown ball's resting attitude tied to its throw, not the viewer.
local M={}
function M.heading(spec)
 local v=spec and spec.velocity
 local x,z=v and tonumber(v[1]),v and tonumber(v[3])
 if not(x and z and x==x and z==z and math.abs(x)<math.huge and math.abs(z)<math.huge and x*x+z*z>1e-8)then return nil end
 return math.atan2(x,z)
end
function M.install(V)
 local found=V.mod and V.mod.find and V.mod.find('FRLG_CATCH')
 local lib=found and found.exports and found.exports.lib
 if not(lib and type(lib.require)=='function')then return nil end
 local FX=lib.require('CaptureFX');local original=FX.begin
 if type(original)~='function'then return nil end
 local wrapped=function(self,spec,...)
  local ok=original(self,spec,...)
  local yaw=ok and M.heading(spec)
  if yaw and self.cap and self.cap.landing then self.cap.landing.yaw=yaw end
  return ok
 end
 FX.begin=wrapped
 return function()if FX.begin==wrapped then FX.begin=original end end
end
return M
