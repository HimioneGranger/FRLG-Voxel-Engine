-- One directional colour field for the sky and completely hazed scenery.
-- Retains the authored palettes and 24 forest/sea sectors. The tiny strip is
-- updated only when their quantised colours change; no eye framebuffer copy.
local M={VERSION='fr-fog-backdrop-3-soft-horizon',SEG=24,TERMINAL_CELLS=2}
local image,data,zenith,horizon
local paletteValues,fractions={},{}
M.GLSL=[[
#ifdef PIXEL
uniform mediump float u_fogSkyOn;
uniform mediump float u_fogSkyPass;
uniform highp vec3 u_fogSkyEye;
uniform mediump vec3 u_fogSkyZenith;
uniform mediump vec3 u_fogSkyHorizon;
uniform Image u_fogSkyBands;
uniform highp vec3 u_fogTerminal;
mediump float fogBayer2(mediump vec2 p) {
  return 2.0*p.x+3.0*p.y-4.0*p.x*p.y;
}
void fogTerminalCoverage(highp float amount,highp vec2 screen) {
  // No colour or depth survives the end. Before the short terminal band,
  // retain the ordinary opaque/cutout result without coverage arithmetic.
  if(amount>=u_fogTerminal.y)discard;
  if(amount<=u_fogTerminal.x)return;
  highp vec2 p=floor(screen);
  mediump float threshold=(4.0*fogBayer2(mod(p,2.0))
    +fogBayer2(mod(floor(p/2.0),2.0))+0.5)/16.0;
  if(threshold<smoothstep(u_fogTerminal.x,u_fogTerminal.y,amount))discard;
}
vec3 fogBackdropColor(highp vec3 point,vec3 fallback) {
  if(u_fogSkyOn<0.5)return fallback;
  highp vec3 ray=point-u_fogSkyEye;
  highp float slope=ray.y/max(length(ray.xz),0.0001);
  if(slope>=0.0) {
    // Same horizon/upper-ring/cap shape as the existing sky gradient.
    highp float t=slope<=0.55 ? 1.0-slope*(0.65/0.55) : 0.35/(slope+0.45);
    return mix(u_fogSkyZenith,u_fogSkyHorizon,t*t);
  }
  highp float x=ray.x+step(dot(ray.xz,ray.xz),0.00000001)*0.0001;
  highp float u=atan(ray.z,x)*0.15915494309189535+0.5/24.0;
  vec3 low=Texel(u_fogSkyBands,vec2(u,0.75)).rgb;
  // The former 1.4-degree fall to FOREST made a uniform green ribbon.
  // Atmospheric distance stays close to the sky's horizon colour. Retain
  // only a subtle, desaturated directional land/sea tint well below it.
  highp float tint=0.16*smoothstep(0.0,0.5,-slope);
  mediump float luminance=dot(low,vec3(0.2126,0.7152,0.0722));
  low=mix(vec3(luminance),low,0.25);
  return mix(u_fogSkyHorizon,low,tint);
}
#endif
]]
local function replace(source,needle,value)
 local a,b=source:find(needle,1,true)
 assert(a and not source:find(needle,b+1,true),'fog backdrop seam missing/ambiguous: '..needle)
 return source:sub(1,a-1)..value..source:sub(b+1)
end
function M.decorate(source)
 local point='vec3(v_darkXZ.x,v_y,v_darkXZ.y)'
 source=replace(source,'vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc)\n{',
   'vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc)\n{\n  if(u_fogSkyPass>0.5)return vec4(fogBackdropColor('..point..',u_fogColor.rgb),1.0);\n'
   ..'  highp float frFogAmount=fogAmount();\n  if(u_fogTerminal.z>0.5)fogTerminalCoverage(frFogAmount,sc);')
 local tail=assert(source:match('  return applyCaveDark%(vec4%(mix%(graded,[^\n]+'),'fog return missing')
 local result=tail:gsub('u_fogColor%.rgb','frFogColor',1):gsub('fogAmount%(%)','frFogAmount',1)
 source=replace(source,tail,'  vec3 frFogColor=u_fogColor.rgb;\n'
   ..'  if(frFogAmount>0.0)frFogColor=fogBackdropColor('..point..',frFogColor);\n'..result)
 return M.GLSL..source
end
local function q(v)return math.floor(v*255+.5)end
function M.palette(z,h,forest,sea,frac)
 local dirty=not image
 -- Fixed scalar scratch: repeated stereo/auxiliary calls allocate nothing.
 for i=1,4 do local c=i==1 and z or i==2 and h or i==3 and forest or sea
  for k=1,3 do local n=(i-1)*3+k;local v=q(c[k]);if paletteValues[n]~=v then dirty=true;paletteValues[n]=v end end
 end
 for j=0,M.SEG-1 do
  local f=frac and ((frac[(j-1)%M.SEG+1] or 0)+(frac[j%M.SEG+1] or 0))*.5 or 0
  f=math.floor(math.max(0,math.min(1,f))*32+.5)/32
  if fractions[j]~=f then dirty=true;fractions[j]=f end
 end
 if not dirty then return false end
 data=data or love.image.newImageData(M.SEG,2,'rgba8')
 for j=0,M.SEG-1 do local f=fractions[j]
  for row=0,1 do local c=row==0 and h or sea
   data:setPixel(j,row,forest[1]+(c[1]-forest[1])*f,forest[2]+(c[2]-forest[2])*f,forest[3]+(c[3]-forest[3])*f,1)
  end
 end
 if image then image:replacePixels(data)else image=love.graphics.newImage(data);image:setFilter('linear','linear');image:setWrap('repeat','clamp')end
 zenith,horizon=z,h
 return true
end
function M.environment(eye,pass,out)
 if not image then return nil end
 out=out or {};out.eye=out.eye or {}
 for i=1,3 do out.eye[i]=eye[i]end
 out.pass=pass==true;out.image=image;out.zenith=zenith;out.horizon=horizon
 return out
end
local eye={0,0,0}
local terminal={0,0,0}
local cache=setmetatable({},{__mode='k'})
local function send(shader,c,name,v)
 if type(v)=='table' then
  local old=c[name]
  if old and old[1]==v[1] and old[2]==v[2] and old[3]==v[3]then return end
  c[name]=old or {};for i=1,3 do c[name][i]=v[i]end
 elseif c[name]==v then return else c[name]=v end
 shader:send(name,v)
end
-- Called at every frame and map-record bind, including non-world passes, so
-- a UI/cave/portal draw cannot inherit the previous world's background.
function M.send(shader,env,rec)
 if not shader:hasUniform('u_fogSkyOn')then return end
 local c=cache[shader];if not c then c={};cache[shader]=c end
 local b=env and env.fogBackdrop
 send(shader,c,'u_fogSkyOn',b and 1 or 0);send(shader,c,'u_fogSkyPass',b and b.pass and 1 or 0)
 local r,f=env and env.radialFog,env and env.fog
 local active=b and not b.pass and not env.dark and r and r[3]>0 and f and f[3]>.9 and f[2]>f[1]
 terminal[1],terminal[2],terminal[3]=0,0,0
 if active then
  -- Express the final two-cell interval in the existing fog amount, so the
  -- pixel shader computes radial distance only once for colour and coverage.
  local run=f[2]-f[1]
  terminal[2]=f[3]
  terminal[1]=f[3]*(1-math.min(M.TERMINAL_CELLS*r[3],run*.2)/run)
  terminal[3]=1
 end
 send(shader,c,'u_fogTerminal',terminal)
 if not b then return end
 eye[1],eye[2],eye[3]=b.eye[1]-(rec and rec.ox or 0),b.eye[2],b.eye[3]-(rec and rec.oz or 0)
 send(shader,c,'u_fogSkyEye',eye);send(shader,c,'u_fogSkyZenith',b.zenith)
 send(shader,c,'u_fogSkyHorizon',b.horizon);send(shader,c,'u_fogSkyBands',b.image)
end
function M.release()
 if image then image:release()end;if data then data:release()end
 image,data,zenith,horizon=nil,nil,nil,nil
end
return M
