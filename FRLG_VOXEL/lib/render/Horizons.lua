-- Preview-only Kanto horizon cards. One fixed world placement shared by maps.
-- Source art is never tiled, cropped, mirrored or stretched to repair a join.
local V=...
local H={stats={}}
local shader,items,positions,sourceRoot
local format={{'VertexPosition','float',3},{'VertexTexCoord','float',2}}
local code=[[
uniform mat4 u_vp;
uniform vec3 u_offset;
uniform vec3 u_eye;
uniform vec3 u_fog;
uniform vec3 u_mul;
uniform vec3 u_add;
uniform float u_m;
varying vec3 v_world;
#ifdef VERTEX
vec4 position(mat4 unused, vec4 p){
 v_world=p.xyz-u_offset;
 vec4 clip=u_vp*vec4(v_world,1.0);
 clip.z=min(clip.z,clip.w*0.99999);
 return clip;
}
#endif
#ifdef PIXEL
vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc){
 vec4 art=Texel(tex,tc);
 if(art.a<0.01)discard;
 float distanceM=length(v_world.xz-u_eye.xz)*u_m;
 // Sky scenery has a height-thinning atmosphere. Terrain keeps the exact
 // current3254 cutoff; this pass reads its live range/color, never overrides it.
 float altitude=max(v_world.y-0.75,0.0)*u_m;
 float opticalDistance=distanceM/pow(1.0+altitude/12.8,2.0);
 float amount=clamp((opticalDistance-u_fog.x)/max(u_fog.y-u_fog.x,0.001),0.0,1.0);
 // Fully fogged ground matches the current directional sky, including at night.
 vec3 backdrop=fogBackdropColor(v_world,u_fogSkyHorizon);
 vec3 lit=clamp(art.rgb*u_mul+u_add,0.0,1.0);
 return vec4(mix(lit,backdrop,amount),art.a);
}
#endif
]]
local function init()
 local config=assert(load(assert(V.mod:read('assets/horizons/placements.lua')), '@horizon-placements'))()
 positions=config.positions
 local Fog=V.require('render/FogBackdrop')
 shader=love.graphics.newShader(Fog.GLSL..code)
 items={}
 for _,c in ipairs(config.cards)do
  local bytes=assert(V.mod:read('assets/horizons/'..c.asset))
  local data=love.filesystem.newFileData(bytes,c.asset)
  local image=love.graphics.newImage(data);image:setFilter('linear','linear');image:setWrap('clamp','clamp');data:release()
  local w,h=image:getDimensions();local span=math.sqrt((c.x2-c.x1)^2+(c.z2-c.z1)^2)
  local height=span*h/w;local base=c.base or .75
  local top=base+height*c.groundUV;local bottom=top-height
  local a={c.x1,top,c.z1,0,0};local b={c.x2,top,c.z2,1,0}
  local cc={c.x2,bottom,c.z2,1,1};local dd={c.x1,bottom,c.z1,0,1}
  local mesh=love.graphics.newMesh(format,{a,b,cc,a,cc,dd},'triangles','static');mesh:setTexture(image)
  items[#items+1]={mesh=mesh,image=image,config=c}
 end
 H.Fog=Fog
end
local function draw(vp,eye,m,env,mapId)
 local offset=positions[mapId];local g=love.graphics
 g.setShader(shader);g.setDepthMode();g.setMeshCullMode('none');g.setColor(1,1,1,1);g.setBlendMode('alpha')
 shader:send('u_vp','row',vp);shader:send('u_offset',{offset[1],0,offset[2]});shader:send('u_eye',eye)
 shader:send('u_fog',env.fog);shader:send('u_m',m)
 local grade=env.grade or {};shader:send('u_mul',grade.mul or {1,1,1});shader:send('u_add',grade.add or {0,0,0})
 local b=env.fogBackdrop
 if b then
  shader:send('u_fogSkyOn',1);shader:send('u_fogSkyEye',eye)
  shader:send('u_fogSkyZenith',b.zenith);shader:send('u_fogSkyHorizon',b.horizon);shader:send('u_fogSkyBands',b.image)
 else
  shader:send('u_fogSkyOn',0);shader:send('u_fogSkyHorizon',{env.fogColor[1],env.fogColor[2],env.fogColor[3]})
 end
 local worldX,worldZ=eye[1]+offset[1],eye[3]+offset[2]
 for _,item in ipairs(items)do
  local c=item.config;local dx,dz=(c.x1+c.x2)*.5-worldX,(c.z1+c.z2)*.5-worldZ
  item.distance2=dx*dx+dz*dz
 end
 table.sort(items,function(a,b)return a.distance2>b.distance2 end)
 for _,item in ipairs(items)do g.draw(item.mesh)end
 H.stats={map=mapId,fog=env.fog,fogColor=env.fogColor,grade=grade,eye=eye,offset=offset,cards=#items,
  atmosphere='Live3254 range/palette; separate height-thinning background atmosphere, 12.8m scale height; native terrain unchanged'}
 return #items
end
function H.release()
 for _,item in ipairs(items or {}) do item.mesh:release();item.image:release() end
 if shader then shader:release() end
 shader,items,positions=nil,nil,nil
 H.stats={};H.failed=nil
end
function H.active(mapId,outdoor)
 if not outdoor or H.failed then return false end
 if V.mod.options:get('contextual_horizons')==false then return false end
 if not positions then
  local ok,why=pcall(init)
  if not ok then H.release();H.failed=tostring(why);print('[Horizons] disabled: '..H.failed);return false end
 end
 return positions[mapId]~=nil
end
function H.draw(vp,eye,m,env,mapId,outdoor)
 if not H.active(mapId,outdoor) then H.stats={active=false,map=mapId};return 0 end
 love.graphics.push('all')
 local ok,result=pcall(draw,vp,eye,m,env,mapId)
 love.graphics.pop()
 if not ok then H.failed=tostring(result);H.stats={active=false,error=H.failed};print('[Horizons] disabled: '..H.failed);return 0 end
 H.stats.active=true
 return result
end
return H
