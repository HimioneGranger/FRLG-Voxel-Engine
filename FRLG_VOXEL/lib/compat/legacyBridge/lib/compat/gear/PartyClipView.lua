-- Small independent party clip; never a belt wrapped around the player.
local V=...;local Mat=V.require('Mat4');local Hip=V.require('HipRig')
local Layout=V.require('UtilityBeltLayout');local Waist=V.require('WaistLayout')
local M={};M.__index=M
function M.geometry(value)
 local vertices,indices={},{}
 local function quad(a,b,c,d)
  local n=#vertices
  for _,p in ipairs({a,b,c,d})do vertices[#vertices+1]={p[1],p[2],p[3],0,0,1}end
  for _,i in ipairs({1,2,3,1,3,4})do indices[#indices+1]=n+i end
 end
 local function section(t)
  local p,yaw=Hip.party(value,t);local nx,nz=math.sin(yaw)*.004,math.cos(yaw)*.004
  return {{p[1]-nx,p[2]-.021,p[3]-nz},{p[1]+nx,p[2]-.021,p[3]+nz},
          {p[1]+nx,p[2]-.046,p[3]+nz},{p[1]-nx,p[2]-.046,p[3]-nz}}
 end
 local prior=section(-1.07);quad(prior[4],prior[3],prior[2],prior[1])
 for i=1,32 do
  local nextSection=section(-1.07+2.14*i/32)
  for j=1,4 do local k=j%4+1;quad(prior[j],prior[k],nextSection[k],nextSection[j])end
  prior=nextSection
 end
 quad(prior[1],prior[2],prior[3],prior[4])
 return vertices,indices
end
function M.new(backend)
 return setmetatable({backend=backend},M)
end
function M:packets(context,scene)
 local p=Layout.partyClip();if not p then return {} end
 local h=p.hip;local key=table.concat({h.x,h.y,h.z,h.rx,h.rz,p.party.angle,p.party.spread},':')
 if key~=self.key then
  local v,i=M.geometry(p);local mesh=self.backend.mesh(v,i)
  if self.mesh then self.backend.release(self.mesh)end
  self.mesh=mesh;self.key=key
 end
 local root=Layout.root(Waist.pose(scene.gearPose or scene.bodyPose,V.mod.options))
 local model=Mat.mul(context.worldFromLocal,root)
 return {{mesh=self.mesh,model=model,material={color={.18,.22,.27,1}}}}
end
function M:dispose()if self.mesh then self.backend.release(self.mesh);self.mesh=nil end end
return M
