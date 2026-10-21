-- FireRed adapter for the accepted Emerald batched lighting pass.
local V=...
local Shaders=V.require('render/Shaders')
local M={ONE3={1,1,1},ZERO3={0,0,0},ZERO2={0,0}}
M.fragmentDeclarations=[[
varying highp vec2 flashWorldXZ;
uniform bool flashEnabled;
uniform highp vec2 flashCenterXZ;
uniform highp float flashRadiusTiles;
vec4 applyNativeFlash(vec4 color) {
 if (!flashEnabled) return color;
 float d=length(flashWorldXZ-flashCenterXZ);
 float a=flashRadiusTiles<=0.0?1.0:smoothstep(.82*flashRadiusTiles,1.18*flashRadiusTiles,d);
 return vec4(color.rgb*(1.0-a),color.a);
}
]]
function M.sendV(sh,k,v) Shaders.send(sh,k,v) end
function M.flash(sh,f)
 Shaders.send(sh,'flashEnabled',f and f.enabled==true or false)
 Shaders.send(sh,'flashCenterXZ',f and f.center or M.ZERO2)
 Shaders.send(sh,'flashRadiusTiles',f and f.radiusTiles or 0)
end
local fogColor={0,0,0}
local NO_RADIAL={0,0,0,0}
function M.rangeFog(sh,f)
 Shaders.send(sh,"u_radialFog",f.radialFog or NO_RADIAL)
 Shaders.send(sh,'u_fog',f.fog or M.ZERO3)
 Shaders.send(sh,'u_fogFar',f.fogFar or 0)
 local color=f.fogColor or M.ZERO3
 fogColor[1],fogColor[2],fogColor[3]=color[1],color[2],color[3]
 Shaders.send(sh,'rangeFogColor',fogColor)
end
function M.translateMVP(a,x,z,o)
 for i=1,16 do o[i]=a[i] end
 for row=0,3 do local k=row*4;o[k+4]=a[k+1]*x+a[k+3]*z+a[k+4] end
 return o
end
return M
