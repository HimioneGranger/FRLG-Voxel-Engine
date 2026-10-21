-- Native geometry adapters provide positions; this pass owns only additive lighting resources.
local V=...
local Flash=V.require('render/LightingUniforms');local Visibility=Flash;local UC=Flash
local ONE3,ZERO3=UC.ONE3,UC.ZERO3
local M={REVISION='native-window-lamp-pass-r1',MAX_POOLS=64,MAX_BUILDINGS=64,MAX_PANE_TRIANGLES=32768,POOL_RES=4}
M.__index=M
M.SHADER=[[
uniform highp vec3 u_fog;uniform highp float u_fogFar;uniform highp vec4 u_radialFog;
#ifdef VERTEX
uniform mat4 u_mvp;
uniform vec2 lightOrigin;
attribute float LightWeight;
attribute vec4 LightColor;
varying vec4 lightColor;
varying float weight;
varying float lightFog;
varying highp vec2 flashWorldXZ;

vec4 position(mat4 t,vec4 p){weight=LightWeight;lightColor=LightColor;flashWorldXZ=p.xz+lightOrigin;vec4 q=u_mvp*p;
highp float fogDistance=q.w;
float f1=clamp((fogDistance-u_fog.x)/max(u_fog.y-u_fog.x,.001),0.,1.);
float f2=clamp((fogDistance-u_fog.y)/max(u_fogFar-u_fog.y,.001),0.,1.)*step(u_fog.y+.001,u_fogFar)*step(.001,u_fog.z);
lightFog=u_fog.z*f1+(1.-u_fog.z)*f2;return q;}
#endif
#ifdef PIXEL
varying vec4 lightColor;
varying float weight;
varying float lightFog;
uniform bool lightBody;
uniform vec3 worldMul;uniform vec3 worldAdd;
]]..Flash.fragmentDeclarations..[[

uniform vec3 rangeFogColor;
highp float fogAmount() {
 if(u_radialFog.z<=0.0)return lightFog;
 highp float d=length(flashWorldXZ-u_radialFog.xy)*u_radialFog.z+u_radialFog.w;
 highp float f1=clamp((d-u_fog.x)/max(u_fog.y-u_fog.x,.001),0.0,1.0);
 highp float f2=clamp((d-u_fog.y)/max(u_fogFar-u_fog.y,.001),0.0,1.0)*step(u_fog.y+.001,u_fogFar)*step(.001,u_fog.z);
 return u_fog.z*f1+(1.0-u_fog.z)*f2;
}

vec4 applyRangeFog(vec4 c){return vec4(mix(c.rgb,rangeFogColor,fogAmount()),c.a);}
vec4 fadeRangeFog(vec4 c){return vec4(c.rgb,c.a*(1.0-fogAmount()));}
vec4 effect(vec4 c,Image t,vec2 uv,vec2 sc){if(lightBody)return applyNativeFlash(applyRangeFog(vec4(clamp(lightColor.rgb*worldMul+worldAdd,0.,1.),1.)));return applyNativeFlash(fadeRangeFog(vec4(lightColor.rgb,clamp(weight*lightColor.a,0.,1.))));}
#endif
]]
local FORMAT={{'VertexPosition','float',3},{'LightWeight','float',1},{'LightColor','float',4}}
local function finite(v)return type(v)=='number'and v==v and v~=math.huge and v~=-math.huge end
local function vertex(v,w)
 assert(finite(v[1])and finite(v[2])and finite(v[3]),'invalid native light position')
 return{v[1]/16,v[2]/16,v[3]/16,w or 1,0,0,0,0}
end
local function destroy(r)
 if r.released then return end;r.released=true
 for _,m in ipairs(r.resources)do local ok=pcall(m.release,m);if not ok then r.releaseErrors=(r.releaseErrors or 0)+1 end end;r.resources={};r.groups={}
end
function M.new(o)
 o=o or{};return setmetatable({policy=assert(o.policy),groups={},frames={},stats={}},M)
end
-- records={{building=policyIdentity,triangles={native pixel triangles},pools={...}}}
-- pool={x,z,rx,rz} in logical native cells. project and admit must use authoritative native layout.
function M:build(records,project,admit,checkpoint,onResource)
 assert(not self.released);assert(type(project)=='function'and type(admit)=='function')
 local r={groups={},resources={},released=false,truncated={buildings=0,panes=0,pools=0,bodies=0}};function r:release()destroy(self)end
 if onResource then onResource(r)end -- register before allocations/yields
 local function alive()assert(not r.released and not self.released,"lighting build cancelled")end
 alive()
 local pools,triangles=0,0;local panes,poolAll,bodies={},{},{}
 local function mesh(v)
  alive();if #v==0 then return nil end
  local obj=love.graphics.newMesh(FORMAT,v,'triangles','dynamic');r.resources[#r.resources+1]=obj
  if checkpoint then checkpoint('light-mesh',#v)end;alive()
  return obj
 end
 local ok,err=pcall(function()
  for i,record in ipairs(records or{})do
   alive();if i>M.MAX_BUILDINGS then r.truncated.buildings=#records-M.MAX_BUILDINGS;break end
   local pane={};for _,t in ipairs(record.triangles or{})do
    if triangles>=M.MAX_PANE_TRIANGLES then r.truncated.panes=r.truncated.panes+1;break end;triangles=triangles+1
    for j=1,3 do pane[#pane+1]=vertex(t[j],t.weight or 1)end
   end
   local poolVerts,slots={},{}
   for _,t in ipairs(record.bodyTriangles or{})do
    if #bodies>=5400*3 then r.truncated.bodies=r.truncated.bodies+1;break end
    for j=1,3 do local v=vertex(t[j],1);local rgb=assert(t.color);v[5],v[6],v[7],v[8]=rgb[1],rgb[2],rgb[3],1;bodies[#bodies+1]=v end
   end
   for _,p in ipairs(record.pools or{})do
    if pools>=M.MAX_POOLS then r.truncated.pools=r.truncated.pools+1;break end;pools=pools+1;local slotStart=#poolVerts+1
    assert(finite(p.x)and finite(p.z)and finite(p.rx)and finite(p.rz)and p.rx>0 and p.rz>0 and p.rx<=2 and p.rz<=2,'pool bounds')
    local R=M.POOL_RES
    for j=math.floor((p.z-p.rz)*R),math.ceil((p.z+p.rz)*R)-1 do
     if j%4==0 and checkpoint then checkpoint('light-pool-row',j);alive()end
     for k=math.floor((p.x-p.rx)*R),math.ceil((p.x+p.rx)*R)-1 do
      local x,z=k/R,j/R
      if admit(math.floor(x+.125),math.floor(z+.125))then
       local corners={};for _,off in ipairs{{0,0},{1/R,0},{1/R,1/R},{0,1/R}}do
        local px,pz=x+off[1],z+off[2];local q=1-((px-p.x)/p.rx)^2-((pz-p.z)/p.rz)^2
        local xx,yy,zz=project(px,pz);assert(finite(xx)and finite(yy)and finite(zz),'pool requires exact terrain projection')
        corners[#corners+1]={xx,yy+.002,zz,q>0 and math.sqrt(q)or 0,0,0,0,0}
       end
       if corners[1][4]+corners[2][4]+corners[3][4]+corners[4][4]>0 then
        for _,n in ipairs{1,2,3,1,3,4}do poolVerts[#poolVerts+1]=corners[n]end
       end
      end
     end
    end
    slots[#slots+1]={first=slotStart,last=#poolVerts}
   end
   local ps,gs=#panes+1,#poolAll+1
   for _,v in ipairs(pane)do panes[#panes+1]=v end;for _,v in ipairs(poolVerts)do poolAll[#poolAll+1]=v end
   for _,slot in ipairs(slots)do slot.first=slot.first+gs-1;slot.last=slot.last+gs-1 end
   r.groups[#r.groups+1]={slots=slots,building=record.building,kind=record.kind or'building',paneStart=ps,paneEnd=#panes,poolStart=gs,poolEnd=#poolAll}
  end
  r.buffers={body=bodies,pane=panes,pool=poolAll};r.vertexCount=#bodies+#panes+#poolAll;r.body=mesh(bodies);r.bodyTriangles=#bodies/3;r.pane=mesh(panes);r.pool=mesh(poolAll);r.poolTriangles=#poolAll/3
 end)
 if not ok then destroy(r);error(err,0)end
 r.poolCount=pools;r.paneTriangles=triangles;return r
end
-- Called once per frame, never per eye. Stable IDs coordinate every pane of a building.
function M:prepare(records,clock,enabled)
 self.frames={};self.enabled=enabled==true;local poolAllowance=M.MAX_POOLS
 for _,rec in ipairs(records or{})do if not rec.released then
  rec.litGroups=0;rec.poolDrawEnd=0
  for _,group in ipairs(rec.groups)do
   local b=assert(group.building);local key=assert(b.id)
   if self.enabled and not self.frames[key]then self.frames[key]=group.kind=='streetlamp'and self.policy:evaluateStreetlamp(clock)or self.policy:evaluate(b,clock)end
   local f=self.frames[key]or{level=0,rgb={0,0,0}};local level=math.max(0,math.min(1,tonumber(f.level)or 0));local rgb=assert(f.rgb)
   local allowed=math.min(#group.slots,poolAllowance);poolAllowance=poolAllowance-allowed
   if level>0 and allowed>0 then rec.poolDrawEnd=group.slots[allowed].last end
   local stamp=table.concat({level,rgb[1],rgb[2],rgb[3],allowed},'/')
   if stamp~=group.lastStamp then
    for i=group.paneStart,group.paneEnd do rec.pane:setVertexAttribute(i,3,rgb[1],rgb[2],rgb[3],level*.92)end
    for n,slot in ipairs(group.slots)do for i=slot.first,slot.last do rec.pool:setVertexAttribute(i,3,rgb[1],rgb[2],rgb[3],n<=allowed and level*.22 or 0)end end
    group.lastStamp=stamp
   end
   if level>0 then rec.litGroups=rec.litGroups+1 end
  end
 end end
end
-- Lab 51: no closure; per-map sends go through the per-eye uniform mirror; a record with nothing to draw
-- (no body, no pane, empty pool range) returns before any GL state change.
local function lightDraw(self,g,sh,rec)
 local calls,tris=0,0
 g.setShader(sh);g.setDepthMode('lequal',false);g.setMeshCullMode('none');g.setColor(1,1,1,1)
 sh:send('lightBody',true);if rec.body then g.setBlendMode('alpha','alphamultiply');g.setDepthMode('lequal',true);g.draw(rec.body);calls=calls+1;tris=tris+rec.bodyTriangles;g.setDepthMode('lequal',false)end;sh:send('lightBody',false)
 if rec.pane and rec.litGroups>0 then g.setBlendMode('alpha','alphamultiply');g.draw(rec.pane);calls=calls+1;tris=tris+rec.paneTriangles end
 if rec.pool and rec.poolDrawEnd>0 then rec.pool:setDrawRange(1,rec.poolDrawEnd);g.setBlendMode('add','alphamultiply');g.draw(rec.pool);calls=calls+1;tris=tris+rec.poolDrawEnd/3 end
 return calls,tris
end
function M:draw(rec,env,originX,originZ,mvp)
 if not(self.enabled and rec and not rec.released and (rec.body or(rec.litGroups and rec.litGroups>0)))or(env.nativeFlash and env.nativeFlash.enabled)then return 0,0 end
 if not rec.body and not rec.pane and not(rec.pool and rec.poolDrawEnd and rec.poolDrawEnd>0)then return 0,0 end
 local g=love.graphics;self.shader=self.shader or g.newShader(M.SHADER)
 originX,originZ=originX or 0,originZ or 0
 local sh=self.shader;UC.rangeFog(sh,env)
 self._mvp=self._mvp or{};self._orig=self._orig or{0,0}
 sh:send('u_mvp','row',mvp or Visibility.translateMVP(env.vp,originX,originZ,self._mvp))
 local wl=env.worldLighting;UC.sendV(sh,'worldMul',wl and wl.mul or ONE3);UC.sendV(sh,'worldAdd',wl and wl.add or ZERO3)
 local o=self._orig;o[1],o[2]=originX,originZ;sh:send('lightOrigin',o);UC.flash(sh,env.nativeFlash)
 g.push('all')
 local ok,calls,tris=pcall(lightDraw,self,g,sh,rec)
 g.pop();if not ok then error(calls,0)end;return calls,tris
end
function M:release()if self.released then return end;self.released=true;if self.shader then self.shader:release();self.shader=nil end;self.frames={}end
-- Persist already projected geometry; cache restores never rerun placement predicates.
function M:restore(data,register,onResource)
 assert(data.schema==1 and type(data.buffers)=='table','lighting buffers schema')
 local caps={body=16200,pane=98304,pool=120000};local total=0
 for k,cap in pairs(caps)do
  local vs=data.buffers[k];assert(type(vs)=='table'and #vs<=cap and #vs%3==0,'lighting buffer bounds')
  total=total+#vs
  for _,v in ipairs(vs)do
   assert(type(v)=='table'and #v==8,'lighting vertex format')
   for i=1,8 do assert(finite(v[i])and math.abs(v[i])<=1e8,'lighting nonfinite vertex')end
  end
 end
 assert(total==data.vertexCount and data.bodyTriangles==#data.buffers.body/3 and data.paneTriangles==#data.buffers.pane/3 and data.poolTriangles==#data.buffers.pool/3,'lighting counts')
 assert(type(data.groups)=='table'and #data.groups<=M.MAX_BUILDINGS,'lighting group cap')
 local function range(a,b,n)assert(finite(a)and finite(b)and a%1==0 and b%1==0 and a>=1 and b>=a-1 and b<=n,'lighting group range')end
 local slots=0
 for _,g in ipairs(data.groups)do
  assert(type(g.building)=='table'and type(g.building.id)=='string','lighting building identity')
  range(g.paneStart,g.paneEnd,#data.buffers.pane);range(g.poolStart,g.poolEnd,#data.buffers.pool)
  assert(type(g.slots)=='table'and #g.slots<=M.MAX_POOLS,'lighting slot cap')
  for _,s in ipairs(g.slots)do range(s.first,s.last,#data.buffers.pool);slots=slots+1 end
 end
 assert(slots<=M.MAX_POOLS and data.poolCount==slots,'lighting pool count')
 local r={resources={},groups={},buffers=data.buffers,released=false}
 function r:release()destroy(self)end
 if onResource then onResource(r)end
 local ok,err=pcall(function()
  for _,k in ipairs{'body','pane','pool'}do
   local verts=data.buffers[k]
   if verts and #verts>0 then r[k]=love.graphics.newMesh(FORMAT,verts,'triangles','dynamic');r.resources[#r.resources+1]=r[k]end
  end
  for _,src in ipairs(data.groups)do
   local g={};for k,v in pairs(src)do g[k]=v end
   g.building=g.kind=='streetlamp'and g.building or register(g.building)
   g.lastStamp=nil;r.groups[#r.groups+1]=g
  end
  for _,k in ipairs{'vertexCount','bodyTriangles','paneTriangles','poolTriangles','poolCount','truncated'}do r[k]=data[k]end
 end)
 if not ok then destroy(r);error(err,0)end
 return r
end
return M



