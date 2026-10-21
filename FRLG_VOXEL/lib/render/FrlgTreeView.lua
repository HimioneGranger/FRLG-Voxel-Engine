-- EM17 point-facing contract port: rig position/body yaw, never tracked head rotation.
-- Static original-art foliage meshes. One basis captured by View.prepare, reused by both eyes.
local V=...
local M={VERSION="fr-native-tree-view 1",TRACK_HEAD=false}
local FORMAT={{"VertexTree","float",3}}
local sendBuf={0,0,0,0}
function M.basis(cam)
  local f
  if cam.mode=="overview" and not cam.seat then
    f={0,0,math.sin(cam.yaw or 0),math.cos(cam.yaw or 0)}
  else
    local x,z
    if cam.eyeWorld then local y;x,y,z=cam:eyeWorld(nil) else x,z=cam.x or 0,cam.z or 0 end
    f={x,z,0,0}
  end
  M.current=f;return f
end
function M.place(x,z,ax,az,f)
  local fx,fz=f[3],f[4]
  if fx==0 and fz==0 then fx,fz=f[1]-ax,f[2]-az end
  local d=math.sqrt(fx*fx+fz*fz)
  if d<1e-6 then fx,fz=0,1 else fx,fz=fx/d,fz/d end
  local ox,oz=x-ax,z-az
  return ax+fz*ox+fx*oz,az-fx*ox+fz*oz
end
function M.source(S)
  if not S.FR_TREE_CUTOUT then
    local src=S.CUTOUT
    local a="attribute vec3 VertexNormal;"
    assert(src:find(a,1,true),"tree shader normal anchor")
    src=src:gsub(a,a.."\nattribute highp vec3 VertexTree;\nuniform highp vec4 u_frTreeFace;",1)
    local b="  v_uv = VertexTexCoord.xy;"
    assert(src:find(b,1,true),"tree shader position anchor")
    local code=[[  if (VertexTree.z > 0.5) {
    highp vec2 f = u_frTreeFace.zw;
    if (dot(f,f) < 0.000001) f = u_frTreeFace.xy - VertexTree.xy;
    highp float d = length(f);
    f = d < 0.000001 ? vec2(0.0,1.0) : f/d;
    highp vec2 o = vertex_position.xz - VertexTree.xy;
    vertex_position.xz = VertexTree.xy + vec2(f.y*o.x+f.x*o.y,-f.x*o.x+f.y*o.y);
  }
]]
    src=src:gsub(b,code..b,1)
    S.FR_TREE_CUTOUT=src
  end
  return S.FR_TREE_CUTOUT
end
function M.shader(S)
  -- BattleCut owns its already assembled tree-capable override and uniforms.
  if S.override and S.override.CUTOUT then return S.override.CUTOUT end
  M.source(S)
  return S.get("FR_TREE_CUTOUT")
end
function M.attach(mesh,verts)
  local any=false
  for _,v in ipairs(verts) do if v.frTree then any=true;break end end
  if not any then return nil end
  local okShader,shader=pcall(M.shader,V.require("render/Shaders"))
  if not okShader or not shader then return nil,shader or "tree shader unavailable" end
  local data={}
  for i,v in ipairs(verts) do local a=v.frTree;data[i]=a and {a[1],a[2],1} or {0,0,0} end
  local ok,a=pcall(love.graphics.newMesh,FORMAT,data,"triangles","static")
  if not ok or not a then return nil,a or "tree attributes unavailable" end
  local attached,err=pcall(mesh.attachAttribute,mesh,"VertexTree",a)
  if not attached then pcall(a.release,a);return nil,err end
  return a
end
function M.send(S,shader,f,ox,oz)
  f=f or M.current or {0,0,0,1}
  sendBuf[1],sendBuf[2],sendBuf[3],sendBuf[4]=f[1]-(ox or 0),f[2]-(oz or 0),f[3],f[4]
  S.send(shader,"u_frTreeFace",sendBuf)
end
return M
