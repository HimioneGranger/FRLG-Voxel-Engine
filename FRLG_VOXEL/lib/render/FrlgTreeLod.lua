-- Presentation-only transition between the two existing tree meshes.
-- One distance per tree root, shared by both eyes. No geometry/cache inputs.
local M={VERSION='fr-tree-lod 1'}
local ZERO={0,0,0,0}
local prefix=[[
uniform mediump vec4 u_treeLod;
varying mediump float v_treeLodDistance;
#ifdef VERTEX
uniform highp vec2 u_treeLodCamera;
#endif
#ifdef PIXEL
// Fixed 4x4 ordered coverage, with complementary near/far masks. No temporal
// randomness or alpha blending, so the transition retains ordinary depth.
mediump float treeBayer2(mediump vec2 p) {
  return 2.0*p.x + 3.0*p.y - 4.0*p.x*p.y;
}
mediump float treeThreshold(highp vec2 screen) {
  highp vec2 p=floor(screen);
  return (4.0*treeBayer2(mod(p,2.0))
       + treeBayer2(mod(floor(p/2.0),2.0)) + 0.5)/16.0;
}
void treeLodCoverage(highp vec2 screen) {
  if (abs(u_treeLod.x)>0.5) {
    mediump float f=smoothstep(u_treeLod.y,u_treeLod.z,v_treeLodDistance);
    mediump float t=treeThreshold(screen);
    if ((u_treeLod.x>0.5 && t<f) || (u_treeLod.x< -0.5 && t>=f)) discard;
  }
}
#endif
]]
local function replaceOnce(source,needle,replacement)
  local first,last=source:find(needle,1,true)
  assert(first and not source:find(needle,last+1,true),'tree LOD shader seam changed: '..needle)
  return source:sub(1,first-1)..replacement..source:sub(last+1)
end
function M.decorate(source)
  assert(source:find('attribute vec3 VertexGrassOffset;',1,true),'tree LOD requires GrassDeform first')
  source=replaceOnce(source,'  v_uv = VertexTexCoord.xy;',[[
  v_treeLodDistance=0.0;
  if (abs(u_treeLod.x)>0.5)
    v_treeLodDistance=length(VertexGrassOffset.xz-u_treeLodCamera);
  v_uv = VertexTexCoord.xy;]])
  source=replaceOnce(source,'vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc)\n{',[[vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc)
{
  treeLodCoverage(sc);]])
  return prefix..source
end
function M.disable(shader)
  if shader and shader.hasUniform and shader:hasUniform('u_treeLod') then
    shader:send('u_treeLod',ZERO)
  end
end
return M
