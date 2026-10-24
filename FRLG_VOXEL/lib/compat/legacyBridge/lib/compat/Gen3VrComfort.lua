-- Engine-owned VRITK adapters. No changes to upstream wearable/Catch modules on disk.
local HostV=...
local M={}
local function option(key,fallback)
 local options=HostV and HostV.mod and HostV.mod.options
 if options and type(options.get)=='function' then
  local ok,value=pcall(options.get,options,key);if ok and value~=nil then return value end
 end
 return fallback
end
local function valid(v)
 if type(v)~='table'then return false end
 for i=1,3 do if type(v[i])~='number'or v[i]~=v[i]or math.abs(v[i])==math.huge then return false end end
 return true
end
-- Bounded release-only gain; drops and vertical juggling keep their original trajectory.
function M.boost(v,strength)
 if strength~='assisted'or not valid(v)then return v,1 end
 local h=math.sqrt(v[1]^2+v[3]^2);local speed=math.sqrt(h*h+v[2]^2)
 if h<.8 or h<math.abs(v[2])*.75 or v[2]<-.35*speed or speed>=12 then return v,1 end
 local gain=math.min(1.25,12/speed)
 return {v[1]*gain,v[2]*gain,v[3]*gain},gain
end
-- Waist reference forward is OpenXR room -Z, including after native recenter.
-- Preserve room translation, seated height and authored equipment offsets.
function M.lockRoot(fallback)
 if type(fallback)~='table'then return fallback end
 return {1,0,0,fallback[4],0,1,0,fallback[8],0,0,1,fallback[12],0,0,0,1}
end
function M.install(V,deps)
 if M.undo and M.owner==V then return true end
 if M.undo then M.uninstall()end
 deps=deps or {};local enabled=deps.enabled or function()return true end
 local Layout=V.require('UtilityBeltLayout');local Loft=V.require('ThrowLoft')
 if type(Layout)~='table'or type(Layout.root)~='function'or type(Loft)~='table'or type(Loft.velocity)~='function'then return false,'unsupported-wearable-api'end
 M.owner=V
 local root,velocity=Layout.root,Loft.velocity
 local cache=setmetatable({},{__mode='k'})
 local rootWrapper=function(fallback)
  if not enabled()or option('belt_locked',true)==false or (Layout.mounted and Layout.mounted())then return root(fallback)end
  if type(fallback)~='table'then return root(fallback)end
  local locked=cache[fallback]
  if not locked then locked=M.lockRoot(fallback);cache[fallback]=locked end
  -- Body matrices may be reused across ticks; translation is always live.
  locked[4],locked[8],locked[12]=fallback[4],fallback[8],fallback[12]
  return locked
 end
 local velocityWrapper=function(v,...)
  local out,lift=velocity(v,...)
  if enabled()then out=M.boost(out,option('throw_strength','assisted'))end
  return out,lift
 end
 Layout.root=rootWrapper;Loft.velocity=velocityWrapper
 M.undo=function()
  if Layout.root==rootWrapper then Layout.root=root end
  if Loft.velocity==velocityWrapper then Loft.velocity=velocity end
  M.undo=nil;M.owner=nil
 end
 return true
end
function M.uninstall()if M.undo then M.undo()end end
return M
