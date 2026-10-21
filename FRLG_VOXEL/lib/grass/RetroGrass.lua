-- FireRed dedicated retro geometry; native flora and encounter classification preserved.
local V=...
local M={VERSION='retro-grass-native-2-instanced'}
local Data=V.require('grass/RetroGrassData')
local Motion=V.require('grass/GrassMotion')
local NativeGround=V.require('grass/NativeGround')
M.groundStyle=function()return 'native'end
local Deform=V.require('grass/GrassDeform')
local S=V.require('render/Shaders')
local Perf=V.require('render/OutdoorPerf') -- Lab 55 GRASS STATE
local R={};R.__index=R
M.FORMAT={{'VertexPosition','float',3},{'VertexTexCoord','float',2},{'VertexNormal','float',3},
 {'VertexGrassRoot','float',3},{'VertexGrassFlex','float',1},{'VertexGrassShade','float',1}}
local function shape(s) return s=='layered' and 'layered' or 'upright' end
M.INSTANCE_FORMAT={{'VertexGrassOffset','float',3}}
function M.new(o)
 local g=love.graphics
 local ok,supported=false,nil
 if g.getSupported then ok,supported=pcall(g.getSupported) end
 local instanced=not (o and o.forceExpanded) and g.drawInstanced~=nil and ok
   and type(supported)=='table' and supported.instancing==true
 return setmetatable({shape=shape(o and o.shape),ground="native",motion=Motion.new(),textures={},records={},
   templates={},instanced=instanced},R)
end
function R:setShape(s) s=shape(s);if s==self.shape then return false end;self.shape=s;self.motion:clear();return true end
function R:update(dt,x,y,z,key) return self.motion:update(dt,x,y,z,key,true) end
function R:wrap(base)
 local W={};for k,v in pairs(base) do W[k]=v end
 function W.new(env)
  local c,e=base.new(env);if not c then return c,e end
  c.retroGrassCells={}
  c.groundKeys=c.groundKeys or base.KEY
  function c:nativeGroundUv(cell,mid)
   local ground=NativeGround.resolve(self,cell,mid)
   assert(ground.uv,ground.reason)
   self.stats.nativeGroundDonors=self.stats.nativeGroundDonors or {}
   local key=ground.mid or ground.mode
   self.stats.nativeGroundDonors[key]=(self.stats.nativeGroundDonors[key] or 0)+1
   if ground.mode~="native-tile"then self.stats.nativeGroundFallbacks=(self.stats.nativeGroundFallbacks or 0)+1;self.stats.nativeGroundFallbackReason=ground.reason end
   return ground.uv
  end
  function c:grass(x,z,gy,uv,mid)
   -- Native groundY is shared by fixed leaf roots and the sole turf surface.
   self.retroGrassCells[#self.retroGrassCells+1]={x=x,z=z,y=gy,kind='tall'}
   self.stats.grassCells=self.stats.grassCells+1
   return true,0
  end
  return c
 end
 return W
end
local function image(tex,tiled)
 -- Lossless RGBA8 upload; bounded packing avoids a native call per texel.
 local unpack=unpack or table.unpack;local packed={}
 for i=1,#tex.rgba,1024 do packed[#packed+1]=string.char(unpack(tex.rgba,i,math.min(i+1023,#tex.rgba))) end
 local d=love.image.newImageData(tex.width,tex.height,'rgba8',table.concat(packed))
 local im
 local ok,err=pcall(function()
  if tiled then
   im=love.graphics.newImage(d,{mipmaps=true});im:setFilter('linear','nearest')
   im:setMipmapFilter('linear');im:setWrap('repeat','repeat')
  else im=love.graphics.newImage(d);im:setFilter('nearest','nearest');im:setWrap('clamp','clamp') end
 end)
 if d.release then d:release() end
 if not ok then if im and im.release then im:release() end;error(err,0) end
 return im
end
function R:texture(kind,selected)
 selected=selected or self.shape
 local key=selected..':'..kind
 if not self.textures[key] then self.textures[key]=image(Data.variants[selected][kind].texture) end
 return self.textures[key]
end
local function bounds(b,x,y,z)
 b.x0=math.min(b.x0,x-.20);b.x1=math.max(b.x1,x+.20)
 b.z0=math.min(b.z0,z-.20);b.z1=math.max(b.z1,z+.20)
 b.y0=math.min(b.y0,y);b.y1=math.max(b.y1,y)
end
-- Templates belong to the renderer, never to an individual record. Keep both
-- shapes resident: visible old records may outlive a shape change/in-flight job.
-- Fuller upright and layered foliage is baked once into shared templates. Ground
-- and plant anchors remain at native height; no added plants or triangles.
function R:vertices(kind,selected)
 local source=Data.variants[selected][kind].vertices
 local key=selected..':'..kind
 self.shapedVertices=self.shapedVertices or {}
 if self.shapedVertices[key] then return self.shapedVertices[key] end
 local vertices={};local spread,rise=1.30,1.18
 if selected=='upright' then spread,rise=1.28,1.08 end
 for i,v in ipairs(source) do
  local q={unpack(v)}
  q[1],q[2],q[3]=v[1]*spread,v[2]*rise,v[3]*spread
  q[9],q[10],q[11]=v[9]*spread,v[10]*rise,v[11]*spread
  local nx,ny,nz=v[6]/spread,v[7]/rise,v[8]/spread
  local length=math.sqrt(nx*nx+ny*ny+nz*nz)
  if length>0 then q[6],q[7],q[8]=nx/length,ny/length,nz/length end
  vertices[i]=q
 end
 self.shapedVertices[key]=vertices;return vertices
end
function R:template(kind,selected)
 local key=selected..':'..kind;local t=self.templates[key]
 if t then return t end
 local vertices=self:vertices(kind,selected)
 local mesh=love.graphics.newMesh(M.FORMAT,vertices,'triangles','static')
 t={mesh=mesh,tris=#vertices/3,x0=math.huge,y0=math.huge,z0=math.huge,
   x1=-math.huge,y1=-math.huge,z1=-math.huge}
 self.templates[key]=t -- track before texture/upload can fail
 local ok,err=pcall(function() mesh:setTexture(self:texture(kind,selected)) end)
 if not ok then self.templates[key]=nil;mesh:release();error(err,0) end
 for _,v in ipairs(vertices) do
  t.x0=math.min(t.x0,v[1]);t.x1=math.max(t.x1,v[1])
  t.y0=math.min(t.y0,v[2]);t.y1=math.max(t.y1,v[2])
  t.z0=math.min(t.z0,v[3]);t.z1=math.max(t.z1,v[3])
 end
 return t
end
-- Probe the documented per-instance attachment API before choosing a build
-- path. Capability/API absence (including unsupported custom offset buffers)
-- falls back before any cells or yields, never halfway through a record.
function R:canInstance(kind,selected)
 if not self.instanced then return false end
 if self.instanceChecked then return true end
 local t=self:template(kind,selected)
 if not t.mesh.attachAttribute or not t.mesh.detachAttribute then
  self.instanced=false;return false
 end
 local probe
 local ok=pcall(function()
  probe=love.graphics.newMesh(M.INSTANCE_FORMAT,{{0,0,0}},'points','static')
  self.instanceProbe=probe;t.bound=probe
  t.mesh:attachAttribute('VertexGrassOffset',probe,'perinstance')
  t.mesh:detachAttribute('VertexGrassOffset');t.bound=nil
 end)
 -- Detach a potentially partially installed binding before buffer destruction.
 if t.bound then
  local detached=pcall(t.mesh.detachAttribute,t.mesh,'VertexGrassOffset')
  t.bound=nil
  if not detached then
   -- Destroying the failed probe template drops its attachment reference first.
   self.templates[selected..':'..kind]=nil;t.mesh:release()
  end
 end
 if probe then probe:release() end;self.instanceProbe=nil
 self.instanced=ok;self.instanceChecked=ok
 return ok
end
function R:build(rec,cells,yield,selected)
 selected=shape(selected or self.shape);rec.retroShape=selected
 rec.retroOwner=self;rec.retroChunks={};self.records[rec]=true
 local useInstances=#cells>0 and self:canInstance(cells[1].kind,selected)
 local buckets,order={},{}
 local function bucket(cell,kind)
  local key=math.floor(cell.x/4)..':'..math.floor(cell.z/4)..':'..kind
  local b=buckets[key]
  if not b then
   b={verts={},offsets={},kind=kind,x0=math.huge,z0=math.huge,y0=math.huge,
     x1=-math.huge,z1=-math.huge,y1=-math.huge}
   buckets[key]=b;order[#order+1]=b;rec.retroChunks[#rec.retroChunks+1]=b
  end
  return b
 end
 local n=0
 local templates,vertices={},{}
 for _,c in ipairs(cells) do
  local b=bucket(c,c.kind)
  if useInstances then
   local t=templates[c.kind]
   if not t then t=self:template(c.kind,selected);templates[c.kind]=t end
   b.template=t;b.offsets[#b.offsets+1]={c.x+.5,c.y,c.z+.5}
   bounds(b,t.x0+c.x+.5,t.y0+c.y,t.z0+c.z+.5)
   bounds(b,t.x1+c.x+.5,t.y1+c.y,t.z1+c.z+.5)
  else
   local source=vertices[c.kind]
   if not source then source=self:vertices(c.kind,selected);vertices[c.kind]=source end
   for _,v in ipairs(source) do
    local q={v[1]+c.x+.5,v[2]+c.y,v[3]+c.z+.5,v[4],v[5],v[6],v[7],v[8],v[9]+c.x+.5,v[10]+c.y,v[11]+c.z+.5,v[12],v[13]}
    b.verts[#b.verts+1]=q;bounds(b,q[1],q[2],q[3]);n=n+1
    if n%1024==0 and yield then yield() end
   end
  end
  -- Instance preparation also cooperates with shape-change/cancellation jobs.
  if useInstances then n=n+1;if n%64==0 and yield then yield() end end
 end
 for _,b in ipairs(order) do
  local floor=b.kind=='floor'
  if b.template then
   b.instances=love.graphics.newMesh(M.INSTANCE_FORMAT,b.offsets,'points','static')
   b.instanceCount=#b.offsets;b.tris=b.template.tris*b.instanceCount
  else
   b.mesh=love.graphics.newMesh(floor and S.FORMAT or M.FORMAT,b.verts,'triangles','static')
   b.tris=#b.verts/3
   b.mesh:setTexture(self:texture(b.kind,selected))
  end
  b.verts=nil;b.offsets=nil;if yield then yield() end
 end
end
-- Lab 55 GRASS STATE (OutdoorPerf.grass): the same chunks in the same order
-- with the same uniform values at every draw, minus the redundant state work
-- Lab 52 repeated per 4x4-cell bucket: setShader when that shader is already
-- bound, the u_grassOn 0 -> 2 / 0 -> 1 flip-flop around every draw, the full
-- deform upload when this shader already holds this record's deform data,
-- and the instance attach/detach pair when the template already carries this
-- chunk's offsets. Chunks are NOT re-sorted by shader: cutout leaves blend
-- (alpha 0.5..1 edges), so draw order is part of the picture. Each shader is
-- left with u_grassOn 0 and every template detached, as Lab 52 left them.
function R:_drawState(scene,env,planes,visible,opaque,cutout,counters)
 local g=love.graphics
 local configured=self._gsCfg
 if not configured then configured={};self._gsCfg=configured end
 for k in pairs(configured) do configured[k]=nil end
 local pool=self._gsPool
 if not pool then pool=setmetatable({},{__mode='k'});self._gsPool=pool end
 local bound=self._gsBound
 if not bound then bound={};self._gsBound=bound end
 -- review A3: a pass that raised mid-way left templates attached; detach them first
 for i=#bound,1,-1 do
  local t=bound[i];bound[i]=nil
  if t.bound~=nil then t.mesh:detachAttribute('VertexGrassOffset');t.bound=nil end
 end
 local nb=0
 local current=nil
 local callsBefore=counters.calls
 local u=nil
 for _,rec in ipairs(scene.visible or {}) do for _,ch in ipairs(rec.retroChunks or {}) do
  local x0,z0,x1,z1=ch.x0+rec.ox,ch.z0+rec.oz,ch.x1+rec.ox,ch.z1+rec.oz
  local dx=math.max(x0-env.camX,0,env.camX-x1);local dz=math.max(z0-env.camZ,0,env.camZ-z1)
  if dx*dx+dz*dz<=env.far*env.far and visible(planes,x0,ch.y0,z0,x1,ch.y1,z1) then
   local floor=ch.kind=='floor';local shader=floor and opaque or cutout
   if current~=shader then g.setShader(shader);current=shader end
   local state=configured[shader]
   if not state then
    S.frame(shader,env,floor and nil or .5)
    state=pool[shader]
    if not state then state={};pool[shader]=state end
    state.leafAlpha=not floor;state.rec=nil;state.tex=nil;state.on=0;state.dRec=nil
    configured[shader]=state
   elseif not floor and not state.leafAlpha then
    S.send(shader,'u_alphaCut',.5);state.leafAlpha=true
   end
   if state.rec~=rec then
    S.send(shader,'u_mvp','row',rec.mvp);S.dark(shader,env,rec);S.ao(shader,false);S.emissive(shader,nil)
    if env.shadows and rec.shadow and (not scene.shadowCurrent or scene:shadowCurrent(rec)) then S.shadow(shader,rec.shadow,rec.shadowXf[1],rec.shadowXf[2]) elseif rec.poolsOnly then S.shadow(shader,rec.poolsOnly,rec.shadowXf[1],rec.shadowXf[2],nil,nil,true) else S.shadow(shader,nil) end
    state.rec=rec
   end
   local mesh=ch.template and ch.template.mesh or ch.mesh
   local tex=mesh:getTexture()
   if state.tex~=tex then S.texSize(shader,tex);state.tex=tex end
   if not floor then
    u=u or self.motion:uniforms()
    local active=Deform.affects(u,x0,ch.y0,z0,x1,ch.y1,z1)
    if active then
     if state.dRec~=rec then Deform.send(shader,u,rec.ox,rec.oz,true);state.dRec=rec;state.on=1
     elseif state.on~=1 then shader:send("u_grassOn",1);state.on=1 end
     counters.motionTris=(counters.motionTris or 0)+ch.tris
    elseif state.on~=2 then
     shader:send("u_grassOn",2);state.on=2
    end
   elseif state.on~=0 then
    Deform.disable(shader);state.on=0
   end
   if ch.template then
    local t=ch.template
    if t.bound~=ch.instances then
     mesh:attachAttribute('VertexGrassOffset',ch.instances,'perinstance')
     nb=nb+1;bound[nb]=t
     t.bound=ch.instances
    end
    g.drawInstanced(mesh,ch.instanceCount)
   else g.draw(mesh) end
   counters.calls=counters.calls+1;counters.tris=counters.tris+ch.tris
  end
 end end
 for i=1,nb do
  local t=bound[i];bound[i]=nil
  if t.bound~=nil then t.mesh:detachAttribute('VertexGrassOffset');t.bound=nil end
 end
 for shader,state in pairs(configured) do
  if state.on~=0 then Deform.disable(shader);state.on=0 end
 end
 scene.grassDrawCalls=counters.calls-callsBefore
end
function R:draw(scene,env,planes,visible,opaque,cutout,counters)
 if Perf.grass then return self:_drawState(scene,env,planes,visible,opaque,cutout,counters) end
 local g=love.graphics
 -- Invocation-local state: another eye, portal/tree pass, or ordinary draw may
 -- reuse these shaders and change every uniform before our next invocation.
 local configured={}
 local callsBefore=counters.calls
 for _,rec in ipairs(scene.visible or {}) do for _,ch in ipairs(rec.retroChunks or {}) do
  local x0,z0,x1,z1=ch.x0+rec.ox,ch.z0+rec.oz,ch.x1+rec.ox,ch.z1+rec.oz
  local dx=math.max(x0-env.camX,0,env.camX-x1);local dz=math.max(z0-env.camZ,0,env.camZ-z1)
  if dx*dx+dz*dz<=env.far*env.far and visible(planes,x0,ch.y0,z0,x1,ch.y1,z1) then
   local floor=ch.kind=='floor';local shader=floor and opaque or cutout
   g.setShader(shader)
   local state=configured[shader]
   if not state then
    S.frame(shader,env,floor and nil or .5)
    state={leafAlpha=not floor};configured[shader]=state
   elseif not floor and not state.leafAlpha then
    -- Also support callers passing the same shader for opaque and cutout.
    S.send(shader,'u_alphaCut',.5);state.leafAlpha=true
   end
   if state.rec~=rec then
    S.send(shader,'u_mvp','row',rec.mvp);S.dark(shader,env,rec);S.ao(shader,false);S.emissive(shader,nil)
    if env.shadows and rec.shadow and (not scene.shadowCurrent or scene:shadowCurrent(rec)) then S.shadow(shader,rec.shadow,rec.shadowXf[1],rec.shadowXf[2]) elseif rec.poolsOnly then S.shadow(shader,rec.poolsOnly,rec.shadowXf[1],rec.shadowXf[2],nil,nil,true) else S.shadow(shader,nil) end
    state.rec=rec
   end
   local mesh=ch.template and ch.template.mesh or ch.mesh
   local tex=mesh:getTexture()
   if state.tex~=tex then S.texSize(shader,tex);state.tex=tex end
   if not floor then
    local u=self.motion:uniforms()
    local active=Deform.affects(u,x0,ch.y0,z0,x1,ch.y1,z1)
    Deform.send(shader,u,rec.ox,rec.oz,active)
    if active then counters.motionTris=(counters.motionTris or 0)+ch.tris end
   end
   if ch.template then
    -- A template can serve many records; bind the current chunk immediately
    -- before drawing. Detach after each draw so no instance buffer stays owned
    -- implicitly by a shared mesh, including when a later record is cancelled.
    local t=ch.template;t.bound=ch.instances
    mesh:attachAttribute('VertexGrassOffset',ch.instances,'perinstance')
    g.drawInstanced(mesh,ch.instanceCount)
    mesh:detachAttribute('VertexGrassOffset');t.bound=nil
   else g.draw(mesh) end
   Deform.disable(shader)
   counters.calls=counters.calls+1;counters.tris=counters.tris+ch.tris
  end
 end end
 scene.grassDrawCalls=counters.calls-callsBefore
end
function R:adopt(rec,tmp)
 self:releaseRecord(rec)
 rec.retroChunks=tmp.retroChunks;rec.retroShape=tmp.retroShape;rec.retroOwner=self
 tmp.retroChunks=nil;tmp.retroOwner=nil;self.records[tmp]=nil;self.records[rec]=true
end
function R:releaseRecord(rec)
 for _,c in ipairs(rec.retroChunks or {}) do
  if c.template and c.template.bound==c.instances and c.instances then
   c.template.mesh:detachAttribute('VertexGrassOffset');c.template.bound=nil
  end
  if c.instances then c.instances:release();c.instances=nil end
  if c.mesh then c.mesh:release();c.mesh=nil end
 end
 rec.retroChunks=nil;rec.retroOwner=nil;self.records[rec]=nil
end
function R:release()
 local list={};for rec in pairs(self.records) do list[#list+1]=rec end;for _,rec in ipairs(list) do self:releaseRecord(rec) end
 for k,t in pairs(self.templates) do
  if t.bound then t.mesh:detachAttribute('VertexGrassOffset');t.bound=nil end
  t.mesh:release();self.templates[k]=nil
 end
 if self.instanceProbe then self.instanceProbe:release();self.instanceProbe=nil end
 for k,t in pairs(self.textures) do t:release();self.textures[k]=nil end
 self.shapedVertices=nil
 self.motion:clear()
end
return M



