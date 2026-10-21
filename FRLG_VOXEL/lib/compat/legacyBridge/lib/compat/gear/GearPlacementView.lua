-- Temporary adjustment handles, not physical belt geometry.
local V=...;local Mat=V.require('Mat4');local M={};M.__index=M
local colors={center={.15,1,.6,1},width={1,.7,.12,1},depth={.2,.65,1,1},
 party={.9,.4,1,1},partyLeft={.9,.4,1,1},partyRight={.9,.4,1,1},pouch={1,.5,.2,1}}
function M.new(backend)
 local vertices,indices={},{}
 local points={{0,.035,0},{.035,0,0},{0,0,.035},{-.035,0,0},{0,0,-.035},{0,-.035,0}}
 for _,face in ipairs({{1,2,3},{1,3,4},{1,4,5},{1,5,2},{6,3,2},{6,4,3},{6,5,4},{6,2,5}})do
  for _,i in ipairs(face)do local p=points[i];vertices[#vertices+1]={p[1],p[2],p[3],0,0,1};indices[#indices+1]=#vertices end
 end
 return setmetatable({backend=backend,mesh=backend.mesh(vertices,indices)},M)
end
function M:packets(handles,world,error)
 local out={}
 for _,h in ipairs(handles or {})do
  local p=h.position
  out[#out+1]={mesh=self.mesh,material={color=error and {1,.1,.1,1} or colors[h.id] or {1,1,1,1}},
   model=Mat.mul(world,Mat.translate(p[1],p[2],p[3]))}
 end
 return out
end
function M:dispose()if self.mesh then self.backend.release(self.mesh);self.mesh=nil end end
return M
