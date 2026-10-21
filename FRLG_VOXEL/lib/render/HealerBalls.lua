-- FireRed healing presentation. Geometry supplies measured FR artwork anchors.
-- Native healing owns placement, flashes, HP, scripts and sounds; this only reads it.
local V = ...
local M = {}; M.__index = M
local FLASH_LEVELS = {16,12,8,0}
local SHADER = [[
#ifdef VERTEX
uniform highp mat4 u_mvp;
uniform highp vec3 u_center;
uniform highp float u_radius;
attribute vec3 VertexNormal;
varying mediump float v_light;
vec4 position(mat4 transform_projection, vec4 p) {
  v_light = 0.55 + 0.45 * max(dot(VertexNormal, normalize(vec3(-0.4,0.8,0.5))),0.0);
  return u_mvp * vec4(p.xyz*u_radius+u_center,1.0);
}
#endif
#ifdef PIXEL
varying mediump float v_light;
uniform mediump float u_flash;
vec4 effect(vec4 color, Image tex, vec2 uv, vec2 px) {
  mediump float shell = step(0.2, max(max(color.r,color.g),color.b));
  return vec4(mix(color.rgb,vec3(1.0),u_flash*shell)*v_light,color.a);
}
#endif
]]
local FORMAT={{'VertexPosition','float',3},{'VertexNormal','float',3},{'VertexColor','float',4}}
-- Engine references are resolved once by the constructor. Mod chunks have no
-- package global in the native sandbox; require returns the same native modules.
local function engine(name)
  local ok,m=pcall(require,'src.core.game3.'..name)
  if ok and type(m)=='table' then return m end
end
local function call(m,name,...)
  if not m or type(m[name])~='function' then return nil end
  local ok,value=pcall(m[name],...);if ok then return value end
end
local function release(x) if x and x.release then pcall(x.release,x) end end

local function finite(x) return type(x)=='number' and x==x and x>-math.huge and x<math.huge end
function M.new()
  return setmetatable({count=0,slots={},ages={},blocked=setmetatable({},{__mode='k'}),
    finished=setmetatable({},{__mode='k'}),native={heal=engine('pokecenter_heal'),runtime=engine('runtime'),profile=engine('profile'),map=engine('map')}},M)
end
function M:clear(block)
  if block and self.fx then self.blocked[self.fx]=true end
  self.fx,self.binding,self.count,self.flash,self.lastPlaced=nil,nil,0,0,0
  for i=1,6 do self.ages[i]=0 end
end
function M:release()
  self:clear(true);release(self.mesh);release(self.shader);self.mesh,self.shader=nil,nil
end
-- Six record-local centers and radii produced by the exact supported native FR
-- prop. Reject malformed, duplicate, missing or excess anchors, including NaNs.
function M.anchors(rec)
  local h=rec and rec.healerFR
  if type(h)~='table' or h.kind~='frlg-native-healer-v1' or h.released
    or type(h.anchors)~='table' or #h.anchors~=6 then return nil end
  for i=1,6 do
    local a=h.anchors[i]
    if type(a)~='table' or not finite(a[1]) or not finite(a[2]) or not finite(a[3])
      or not finite(a[4]) or a[4]<=0 or a[4]>.5 then return nil end
    for j=1,i-1 do local b=h.anchors[j]
      if a[1]==b[1] and a[2]==b[2] and a[3]==b[3] then return nil end
    end
  end
  return h.anchors
end
function M:context(scene,game)
  local n=self.native;local session=call(n.runtime,'getSession');local id=n.map and n.map.current
  local def=call(n.map,'currentDef');local fx=n.heal and n.heal._fx
  local valid=game and n.runtime and n.runtime._game==game and call(n.runtime,'isActive')==true
    and type(session)=='table' and session.map==id and def
    and call(n.profile,'family',session)=='frlg' and type(id)=='string'
    and (id:match('^FR_') or id=='SEVII_ONE_ISLAND_POKECENTER')
  local changed=self.binding and (self.binding.owner~=game or self.binding.session~=session
    or self.binding.map~=id or self.binding.mapDef~=def)
  if not valid or changed then
    self:clear(true)
    if type(fx)=='table' then self.blocked[fx]=true end
    if not valid then return nil end
  end
  if type(fx)=='table' and self.blocked[fx] then self.count=0;self.flash=0;return nil end
  if type(fx)=='table' and self.fx~=fx then
    self:clear(false);self.fx=fx
    self.binding={owner=game,session=session,map=id,mapDef=def}
  elseif type(fx)~='table' then self:clear(true) end
  if type(fx)=='table' and finite(fx.state) and fx.state>=5 then self.finished[fx]=true end
  if self.lastError or not scene or scene.rootId~=id or call(scene,'ready',scene)~=true then
    self.count=0;self.flash=0;return nil
  end
  local rec=scene.cache and scene.cache[id];local anchors=M.anchors(rec);local place
  for _,p in ipairs(scene.placed or {}) do if not p.border and p.id==id then place=p;break end end
  if not anchors or not place then self.count=0;self.flash=0;return nil end
  local px,pz,rx,rz=place.ox or 0,place.oy or 0,rec.originX or 0,rec.originY or 0
  if not finite(px) or not finite(pz) or not finite(rx) or not finite(rz) then
    self.count=0;self.flash=0;return nil
  end
  local ox,oz=px+rx,pz+rz
  if not finite(ox) or not finite(oz) then self.count=0;self.flash=0;return nil end
  return anchors,ox,oz,fx
end
-- Routing must be truthful before prepare: lazily verify the shared GPU pair.
-- Allocation errors restore the caller's native flat route without starting FX.
function M:supported(scene,game)
  return self:context(scene,game)~=nil and self:resources()
end
function M.flash(fx)
  if type(fx)~='table' or (fx.state~=2 and fx.state~=3) or not finite(fx.counter) then return 0 end
  return FLASH_LEVELS[math.floor(fx.counter)%4+1]/16*.35
end
function M.vertices()
  local out={};local red={.82,.035,.04,1};local white={.91,.91,.88,1};local black={.055,.06,.065,1}
  local rings={-1,-.9239,-.7071,-.3827,-.065,.065,.3827,.7071,.9239,1}
  local function point(y,a) local r=math.sqrt(math.max(0,1-y*y));return {r*math.cos(a),y,r*math.sin(a)} end
  local function vertex(p,n,c) out[#out+1]={p[1],p[2],p[3],n[1],n[2],n[3],c[1],c[2],c[3],c[4]} end
  local function tri(a,b,c,col) vertex(a,a,col);vertex(b,b,col);vertex(c,c,col) end
  for j=1,#rings-1 do
    local col=j==5 and black or (rings[j]<0 and white or red)
    for k=0,11 do
      local a,b=k*math.pi/6,(k+1)*math.pi/6
      local p,q,r,s=point(rings[j],a),point(rings[j],b),point(rings[j+1],b),point(rings[j+1],a)
      if j>1 then tri(p,q,r,col) end;if j<#rings-1 then tri(p,r,s,col) end
    end
  end
  -- A real front-facing raised rim/button; same world facing for both eyes.
  for _,disc in ipairs({{.23,1.005,black},{.15,1.025,white}}) do
    for k=0,11 do
      local a,b=k*math.pi/6,(k+1)*math.pi/6;local n={0,0,1}
      vertex({0,0,disc[2]},n,disc[3]);vertex({disc[1]*math.cos(a),disc[1]*math.sin(a),disc[2]},n,disc[3]);vertex({disc[1]*math.cos(b),disc[1]*math.sin(b),disc[2]},n,disc[3])
    end
  end
  return out
end
function M:resources()
  if self.mesh and self.shader then return true end
  local g=love and love.graphics;if not g then return false end
  local ok,err=pcall(function()
    self.shader=g.newShader(SHADER)
    self.mesh=g.newMesh(FORMAT,M.vertices(),'triangles','static')
    self.meshAllocations=(self.meshAllocations or 0)+1
  end)
  if not ok then release(self.mesh);release(self.shader);self.mesh,self.shader=nil,nil;self.lastError=tostring(err) end
  return ok
end

-- Caller prepares once per logical frame before either eye. Drawing is read-only.
function M:prepare(scene,game,dt,enabled)
  self.preparedGeneration=(self.preparedGeneration or 0)+1
  self.count,self.flash=0,0
  local anchors,ox,oz,fx=self:context(scene,game)
  if not anchors or type(fx)~='table' or self.finished[fx] then return false end
  if not finite(fx.state) or fx.state<0 or fx.state>=5 or not finite(fx.placed) then return false end
  if enabled==false then return false end
  local count=math.max(0,math.min(6,math.floor(fx.placed)))
  dt=finite(dt) and math.max(0,math.min(dt,.05)) or 0
  self.flash=M.flash(fx)
  for i=1,count do
    local a=anchors[i];local s=self.slots[i] or {center={}};self.slots[i]=s
    if i>self.lastPlaced then self.ages[i]=0 else self.ages[i]=math.min(.18,(self.ages[i] or 0)+dt) end
    local t=self.ages[i]/.18;local ease=1-(1-t)^3
    -- Radius-relative rise leaves small FR dock balls proportionate to the art.
    s[1],s[2],s[3],s[4]=a[1]+ox,a[2]-a[4]*1.5*(1-ease),a[3]+oz,a[4]
    s.center[1],s.center[2],s.center[3]=s[1],s[2],s[3]
  end
  self.lastPlaced=count
  if count>0 and self:resources() then self.count=count end
  return self.count>0
end
function M:status()
  local slots={};for i=1,self.count do local s=self.slots[i];slots[i]={s[1],s[2],s[3],s[4]} end
  return {count=self.count,flash=self.flash or 0,slots=slots,map=self.binding and self.binding.map,
    error=self.lastError,meshAllocations=self.meshAllocations or 0,draws=self.draws or 0,
    preparedGeneration=self.preparedGeneration or 0}
end
function M:draw(env)
  if self.count==0 or not self.mesh or not self.shader then return 0 end
  local g=love.graphics;g.push('all')
  local ok,err=pcall(function()
    g.setDepthMode('lequal',true);g.setMeshCullMode('none');g.setBlendMode('alpha');g.setColor(1,1,1,1);g.setShader(self.shader)
    self.shader:send('u_mvp','row',env.vp)
    self.shader:send('u_flash',self.flash or 0)
    for i=1,self.count do local s=self.slots[i];self.shader:send('u_center',s.center);self.shader:send('u_radius',s[4]);g.draw(self.mesh) end
  end)
  g.pop();if not ok then self.lastError=tostring(err);return 0 end
  self.draws=(self.draws or 0)+1
  return self.count
end
return M
