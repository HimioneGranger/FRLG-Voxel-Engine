-- A single explicit native/world crossing; engine collision remains native.
local M={}
local function records(scene)
 local out={}
 for _,p in ipairs(scene.placed or {})do
  local r=not p.border and scene.cache[p.key]
  if r and not r.failed and r.compiledCaveQuery then out[#out+1]={p,r.compiledCaveQuery}end
 end
 return out
end
function M.nativeToWorld(scene,x,z)
 for _,v in ipairs(records(scene))do
  local p,q=v[1],v[2];local lx,lz=x-p.ox,z-p.oy
  if q.contains(lx,lz)then
   local wx,y,wz=q.project(lx,lz)
   if wx then return wx+p.ox,y,wz+p.oy end
  end
 end
 return x,scene:nativeHeightAt(x,z),z
end
function M.worldToNative(scene,x,z)
 for _,v in ipairs(records(scene))do
  local p,q=v[1],v[2];local nx,nz=q.unproject(x-p.ox,z-p.oy)
  if nx then return nx+p.ox,nz+p.oy end
 end
 return x,z
end
function M.heightAt(scene,x,z)
 for _,v in ipairs(records(scene))do
  local p,q=v[1],v[2];local nx,nz=q.unproject(x-p.ox,z-p.oy)
  if nx then return q.liftAt(nx,nz)end
 end
 return scene:nativeHeightAt(x,z)
end
function M.actors(scene,actors)
 if #records(scene)==0 then return actors end
 local out={}
 for i,a in ipairs(actors)do
  local copy={};for k,v in pairs(a)do copy[k]=v end
  if type(a.x)=='number'and type(a.z)=='number'then copy.x,copy._caveGround,copy.z=M.nativeToWorld(scene,a.x,a.z)end
  out[i]=copy
 end
 return out
end
return M
