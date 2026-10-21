-- FireRed uses its existing ranges; only align their distance metric and sky color.
local V=...
local Mr=V.require('quest/MrLink')
local M={REVISION='fr-radial-cloud-fog-1'}
function M.clouds(view,color)
 local wh=view.weatherHost;local v3=wh and wh.hostLib and wh.hostLib._modules and wh.hostLib._modules.Voxel3D
 if not v3 then return end
 local f=Mr.s and Mr.s.f;local portal=f and f.portal
 if f and (f.portalFrame or (portal and portal.enabled)) then color=nil end
 local profile
 if color then
  profile=view._frCloudAtmos or {color={}};view._frCloudAtmos=profile
  for i=1,3 do profile.color[i]=color[i] end
  -- Emerald's verified altitude-relative envelope, never terrain draw radius.
  local haze=0
  if type(v3.weatherHazeLevel)=='function' then local ok,h=pcall(v3.weatherHazeLevel);if ok then haze=math.max(0,math.min(1,tonumber(h) or 0)) end end
  profile.startAltitudes=2-.5*haze;profile.runAltitudes=8-3*haze
 end
 v3.nativeCloudAtmos=profile
end
-- Additional camera views may shorten the scene cull radius. Cap only their
-- local environment; the prepared stereo fog remains immutable.
function M.limit(fog,far,radial,cells,scratch)
 if not(radial and fog and fog[3]>0 and type(cells)=='number' and cells>0) then return fog,far end
 local scale,bias=radial[3],radial[4]
 local cap=cells*scale+bias
 if cap>=far then return fog,far end
 local finish=bias+math.max(cells*.5,cells-6)*scale
 local ratio=math.max(0,(finish-bias)/math.max(.001,fog[2]-bias))
 local start=bias+math.max(0,fog[1]-bias)*ratio
 local out=scratch or {}
 out[1],out[2],out[3]=math.min(start,finish-.001),finish,fog[3]
 return out,cap
end
return M
