local V=...
local S=V.require("render/Shaders")
local Deform=V.require("grass/GrassDeform")
local VoxelTree=V.require("mesh/FrlgVoxelTree")
local M={VERSION="fr-voxel-trees 1"}

M.NEAR_CELLS=20
M.BUCKET_CELLS=4
M.RESTING_GRASS=2
M.LAYERS={"under","over"}
M.FORMAT={{"VertexPosition","float",3},{"VertexTexCoord","float",2},{"VertexNormal","float",3},
  {"VertexGrassRoot","float",3},{"VertexGrassFlex","float",1},{"VertexGrassShade","float",1}}
M.INSTANCE_FORMAT={{"VertexGrassOffset","float",3}}

local floor,max,min=math.floor,math.max,math.min
local R={};R.__index=R
local generation=0

function M.supported()
  local g=love.graphics
  if not (g and g.drawInstanced and g.getSupported) then return false end
  local ok,features=pcall(g.getSupported)
  return ok and type(features)=="table" and features.instancing==true
end

function M.active() return VoxelTree.enabled end
function M.generation() return generation end

function M.setActive(on)
  local enabled=on==true and M.supported()
  if enabled==VoxelTree.enabled then return false end
  VoxelTree.enabled=enabled
  generation=generation+1
  return true
end

function M.new() return setmetatable({templates={},records={}},R) end

function R:template(pair,key,stamp)
  local id=pair..":"..key
  local template=self.templates[id]
  if template then return template end
  template={tris=stamp.tris,radius=stamp.radius,height=stamp.height,layers={}}
  for _,layer in ipairs(M.LAYERS) do
    if #stamp[layer]>0 then template.layers[layer]=love.graphics.newMesh(M.FORMAT,stamp[layer],"triangles","static") end
  end
  self.templates[id]=template
  return template
end

function R:build(rec,out)
  self:releaseRecord(rec)
  if not out or #out.trees==0 then return 0 end
  local buckets,order,groups,byTemplate={},{},{},{}
  local function group(template)
    local g=byTemplate[template]
    if not g then g={template=template,capacity=0,rows={},count=0};byTemplate[template]=g;groups[#groups+1]=g end
    return g
  end
  for _,tree in ipairs(out.trees) do
    local key=floor(tree.x/M.BUCKET_CELLS)..":"..floor(tree.z/M.BUCKET_CELLS)..":"..tree.near..":"..tree.far
    local bucket=buckets[key]
    if not bucket then
      bucket={near=self:template(out.pair,tree.near,out.stamps[tree.near]),
        far=self:template(out.pair,tree.far,out.stamps[tree.far]),offsets={},
        x0=math.huge,y0=math.huge,z0=math.huge,x1=-math.huge,y1=-math.huge,z1=-math.huge}
      buckets[key],order[#order+1]=bucket,bucket
    end
    bucket.offsets[#bucket.offsets+1]={tree.x,tree.y,tree.z}
    local radius=max(bucket.near.radius,bucket.far.radius)
    local height=max(bucket.near.height,bucket.far.height)
    bucket.x0,bucket.x1=min(bucket.x0,tree.x-radius),max(bucket.x1,tree.x+radius)
    bucket.z0,bucket.z1=min(bucket.z0,tree.z-radius),max(bucket.z1,tree.z+radius)
    bucket.y0,bucket.y1=min(bucket.y0,tree.y),max(bucket.y1,tree.y+height)
  end
  local tris=0
  for _,bucket in ipairs(order) do
    bucket.count=#bucket.offsets
    bucket.nearGroup,bucket.farGroup=group(bucket.near),group(bucket.far)
    bucket.nearGroup.capacity=bucket.nearGroup.capacity+bucket.count
    if bucket.farGroup~=bucket.nearGroup then bucket.farGroup.capacity=bucket.farGroup.capacity+bucket.count end
    tris=tris+bucket.far.tris*bucket.count
  end
  for _,g in ipairs(groups) do
    -- Retain bounded reusable CPU rows and GPU capacity for either eye's culling.
    for i=1,g.capacity do g.rows[i]={0,0,0} end
    g.instances=love.graphics.newMesh(M.INSTANCE_FORMAT,g.capacity,"points","stream")
  end
  rec.frVoxelTrees,rec.frVoxelTreeGroups,rec.frVoxelOwner=order,groups,self
  self.records[rec]=true
  return tris
end

local function bindRecord(scene,env,shader,rec)
  S.send(shader,"u_mvp","row",rec.mvp)
  S.dark(shader,env,rec)
  S.ao(shader,false)
  S.emissive(shader,nil)
  if env.shadows and rec.shadow and (not scene.shadowCurrent or scene:shadowCurrent(rec)) then
    S.shadow(shader,rec.shadow,rec.shadowXf[1],rec.shadowXf[2])
  elseif rec.poolsOnly then
    S.shadow(shader,rec.poolsOnly,rec.shadowXf[1],rec.shadowXf[2],nil,nil,true)
  else
    S.shadow(shader,nil)
  end
end

local function drawInstances(mesh,bucket,texture,shader,state)
  if mesh:getTexture()~=texture then mesh:setTexture(texture) end
  if state.texture~=texture then S.texSize(shader,texture);state.texture=texture end
  mesh:attachAttribute("VertexGrassOffset",bucket.instances,"perinstance")
  love.graphics.drawInstanced(mesh,bucket.count)
  mesh:detachAttribute("VertexGrassOffset")
end

function R:draw(scene,env,planes,visible,shader,counters)
  local state=self.drawState or {};self.drawState=state;state.texture=nil;state.rec=nil
  local resting=false
  local nearSquared=M.NEAR_CELLS*M.NEAR_CELLS
  for _,rec in ipairs(scene.visible or {}) do
    local groups=rec.frVoxelTreeGroups
    if groups then
      for _,g in ipairs(groups) do g.count=0 end
      -- Rebuild for every eye; retain the exact original bucket bounds and LOD test.
      for _,bucket in ipairs(rec.frVoxelTrees or {}) do
        local x0,z0,x1,z1=bucket.x0+rec.ox,bucket.z0+rec.oz,bucket.x1+rec.ox,bucket.z1+rec.oz
        local dx=max(x0-env.camX,0,env.camX-x1)
        local dz=max(z0-env.camZ,0,env.camZ-z1)
        local distanceSquared=dx*dx+dz*dz
        if distanceSquared<=env.far*env.far and visible(planes,x0,bucket.y0,z0,x1,bucket.y1,z1) then
          local g=distanceSquared<=nearSquared and bucket.nearGroup or bucket.farGroup
          for i=1,bucket.count do g.count=g.count+1;g.rows[g.count]=bucket.offsets[i] end
          counters.tris=counters.tris+g.template.tris*bucket.count
        end
      end
      for _,g in ipairs(groups) do
        if g.count>0 then
          if not resting then S.send(shader,"u_grassOn",M.RESTING_GRASS);resting=true end
          if state.rec~=rec then bindRecord(scene,env,shader,rec);state.rec=rec end
          g.instances:setVertices(g.rows,1,g.count)
          for _,layer in ipairs(M.LAYERS) do
            local mesh=g.template.layers[layer]
            local texture
            if layer=="under" then texture=rec.liveTex else texture=rec.liveOverTex end
            if mesh and texture then drawInstances(mesh,g,texture,shader,state);counters.calls=counters.calls+1 end
          end
        end
      end
    end
  end
  if resting then Deform.disable(shader) end
end

function R:releaseRecord(rec)
  for _,g in ipairs(rec.frVoxelTreeGroups or {}) do
    if g.instances then g.instances:release();g.instances=nil end
  end
  rec.frVoxelTrees,rec.frVoxelTreeGroups,rec.frVoxelOwner=nil,nil,nil
  self.records[rec]=nil
end

function R:release()
  local records={}
  for rec in pairs(self.records) do records[#records+1]=rec end
  for _,rec in ipairs(records) do self:releaseRecord(rec) end
  for id,template in pairs(self.templates) do
    for _,mesh in pairs(template.layers) do mesh:release() end
    self.templates[id]=nil
  end
end

return M
