local WORLD_IDENTITY={1,1,1}
local WORLD_ZERO={0,0,0}
-- VRITK_FRLG_HOST: the Voxel3D stand-in VRITK's Gen2-shaped rendering code
-- draws through (vritk-hook/DESIGN.md 2b "The Voxel3D stand-in"). NOT a
-- copy of BATTLE_ART_VOXEL_GEN2's real Voxel3D.lua -- that module drives
-- its own shader/canvas/shadow pipeline this bridge never touches (it is
-- 1600+ lines of terrain/water/shadow machinery FRLG_VOXEL already owns a
-- different version of). What VRITK's own code actually calls on Voxel3D
-- was checked directly against the fl16 source, not assumed from the
-- design doc:
--   QuestBackpackBackend.lua (the backpack itself): only `.vp`, read once
--     per eye in its own beginEye. It has its own shader and its own
--     push("all")/setShader/setDepthMode -- Voxel3D never draws the bag.
--   QuestHandsRenderer.lua / VRHandAssets.lua (the gloves): `.FACE_CORNERS`,
--     `.pushQuad`, `.newMesh`, `.draw`, `.lighting(on)`, `.seams(on)`,
--     `.glass(on)`.
-- So this shim needs one small shader (not BV's real one, which computes
-- sun/shadow terms this bridge has nothing to feed it) and just enough
-- state to answer both call patterns -- as a PLAIN TABLE of fields and
-- functions, not an object needing colon calls: VRITK calls
-- `Voxel3D.draw(mesh, tex, model)`, `Voxel3D.lighting(false)`, reads
-- `Voxel3D.vp` as a field, all with a dot, never a colon, so a method
-- expecting an implicit self would silently receive `mesh` as self instead
-- and misbehave. `Voxel3DShim.new()` returns exactly that flat table;
-- main.lua constructs ONE instance and holds it as the permanent answer to
-- lib.require("Voxel3D") (see main.lua's V.require).
local V = ...
local _ = V

local Voxel3DShim = {}

Voxel3DShim.FORMAT = {
  { "VertexPosition", "float", 3 },
  { "VertexTexCoord", "float", 2 },
  { "VertexShade", "float", 1 },
}

-- Copied verbatim from BATTLE_ART_VOXEL_GEN2/lib/Voxel3D.lua:479-486 (the
-- quad corner/UV table VRHandAssets' and QuestHandsRenderer's fallback-box
-- builders both read) -- see w4/P2_DECISIONS.md for the fl16 source.
Voxel3DShim.FACE_CORNERS = {
  [1] = { { 1, 0, 0 }, { 1, 0, 1 }, { 1, 1, 1 }, { 1, 1, 0 } },  -- +X
  [2] = { { 0, 0, 1 }, { 0, 0, 0 }, { 0, 1, 0 }, { 0, 1, 1 } },  -- -X
  [3] = { { 0, 1, 0 }, { 1, 1, 0 }, { 1, 1, 1 }, { 0, 1, 1 } },  -- +Y
  [4] = { { 0, 0, 1 }, { 1, 0, 1 }, { 1, 0, 0 }, { 0, 0, 0 } },  -- -Y
  [5] = { { 0, 0, 1 }, { 1, 0, 1 }, { 1, 1, 1 }, { 0, 1, 1 } },  -- +Z
  [6] = { { 1, 0, 0 }, { 0, 0, 0 }, { 0, 1, 0 }, { 1, 1, 0 } },  -- -Z
}

-- Simplified vs BV's real shader (DESIGN.md 2b, P2 scope): no shadow map,
-- no sun-angle term. `pull`/`sunModel` (Voxel3D.draw's other two
-- parameters) are accepted but not applied -- there is no shadow pass to
-- pull away from in this shim. VertexShade still darkens faces so a
-- fallback box (VRHandAssets' failure path) reads as a solid shape, not a
-- flat sticker. GLES rule (memory: LOVE GLES shader precision): never a
-- blanket `precision`, qualify per variable.
local SHADER_SOURCE = [[
varying highp vec2 nativeFlashXZ;
#ifdef PIXEL
uniform mediump vec3 nativeWorldMul;
uniform mediump vec3 nativeWorldAdd;
uniform bool nativeFlashEnabled;
uniform highp vec2 nativeFlashCenter;
uniform highp float nativeFlashRadius;
vec4 maskNativeFlash(vec4 c) {
 float occupied=min(1.0,max(max(c.r,c.g),c.b)*4.0);
 c.rgb=clamp(c.rgb*nativeWorldMul+nativeWorldAdd*occupied,0.0,1.0);
 if (!nativeFlashEnabled) return c;
 float a=nativeFlashRadius<=0.0?1.0:smoothstep(.82*nativeFlashRadius,1.18*nativeFlashRadius,length(nativeFlashXZ-nativeFlashCenter));
 return vec4(c.rgb*(1.0-a),c.a);
}
#endif

varying mediump float v_shade;
varying LOVE_HIGHP_OR_MEDIUMP vec2 v_uv;
#ifdef VERTEX
uniform highp mat4 u_vp;
uniform highp mat4 u_model;
attribute float VertexShade;
vec4 position(mat4 transform_projection, vec4 vertex_position)
{
  v_shade = VertexShade;
  v_uv = VertexTexCoord.xy;
  nativeFlashXZ=(u_model*vertex_position).xz/16.0;
  return u_vp * u_model * vertex_position;
}
#endif
#ifdef PIXEL
vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc)
{
  mediump vec4 c = Texel(tex, v_uv) * color;
  return maskNativeFlash(vec4(c.rgb * mix(0.55, 1.0, v_shade), c.a));
}
#endif
]]
Voxel3DShim.SHADER_SOURCE = SHADER_SOURCE

local IDENTITY = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }

-- Returns the flat Voxel3D-shaped table. `log` is optional, fun(msg).
function Voxel3DShim.new(opts)
  opts = opts or {}
  local log = opts.log or function() end
  local state = { shader = nil, shaderFailed = false, active = false }

  local M = {}
  M.FORMAT = Voxel3DShim.FORMAT
  M.FACE_CORNERS = Voxel3DShim.FACE_CORNERS
  -- fields VRITK reads directly (never through a function call)
  M.vp = nil
  M.eye = nil
  -- gloss intentionally omitted: VRDeviceAssets.lua guards with
  -- `if Voxel3D.gloss then ... end` before use (DESIGN.md 2b).

  local function getShader()
    if state.shader then return state.shader end
    if state.shaderFailed then return nil end
    local ok, sh = pcall(love.graphics.newShader, SHADER_SOURCE)
    if ok and sh then state.shader = sh; return sh end
    state.shaderFailed = true
    log("[VRITK_FRLG_HOST] Voxel3D shim shader compile failed: " .. tostring(sh))
    return nil
  end

  function M.pushQuad(map, n)
    local b = n * 4
    map[#map + 1] = b + 1
    map[#map + 1] = b + 2
    map[#map + 1] = b + 3
    map[#map + 1] = b + 1
    map[#map + 1] = b + 3
    map[#map + 1] = b + 4
  end

  function M.newMesh(verts, map)
    if type(verts) ~= "table" or #verts == 0 then return nil end
    local ok, mesh = pcall(love.graphics.newMesh, M.FORMAT, verts, "triangles", "static")
    if not ok then return nil end
    if map and #map > 0 then pcall(mesh.setVertexMap, mesh, map) end
    return mesh
  end

  -- Called once per eye, before HandProps.draw / StereoLayers.draw /
  -- QuestHandsRenderer.draw (CRITIQUE #6's per-eye order). vp = the
  -- px-frame view-projection for this eye (PxContext.eyeVpPx); eyePosPx =
  -- {x,y,z} world px (PxContext.eyePosPx). FRLG_VOXEL's View.lua has
  -- already set depth/blend mode correctly for this slot (still inside its
  -- own push("all")), so beginEye only touches state this shim owns: its
  -- own shader and the u_vp uniform.
  function M.beginEye(vp, eyePosPx, nativeFlash, worldLighting)
    M.vp, M.eye, M.nativeFlash, M.worldLighting = vp, eyePosPx, nativeFlash, worldLighting
    local sh = getShader()
    if not sh then state.active = false; return false end
    love.graphics.setShader(sh)
    local ok = pcall(sh.send, sh, "u_vp", "row", vp)
local wl=M.worldLighting
    sh:send('nativeWorldMul',wl and wl.mul or WORLD_IDENTITY)
    sh:send('nativeWorldAdd',wl and wl.add or WORLD_ZERO)
    local nf=M.nativeFlash or {enabled=false}
    sh:send('nativeFlashEnabled',nf.enabled==true)
    if nf.enabled then sh:send('nativeFlashCenter',nf.center);sh:send('nativeFlashRadius',nf.radiusTiles)end
    state.active = ok
    return ok
  end

  -- Only host hands/HUD call this; world effect paths always keep the mask.
  function M.flashExempt(on)
    if state.active and state.shader then
      state.shader:send("nativeFlashEnabled",not on and M.nativeFlash~=nil and M.nativeFlash.enabled==true)
      local wl=not on and M.worldLighting
      state.shader:send('nativeWorldMul',wl and wl.mul or WORLD_IDENTITY)
      state.shader:send('nativeWorldAdd',wl and wl.add or WORLD_ZERO)
    end
  end

  function M.drawExempt(mesh,texture,model)
    M.flashExempt(true)
    local ok,err=pcall(M.draw,mesh,texture,model)
    M.flashExempt(false)
    if not ok then error(err,0)end
  end

  function M.endEye()
    state.active = false
    pcall(love.graphics.setShader)
  end

  -- Voxel3D.draw(mesh, texture, model, pull, sunModel).
  function M.draw(mesh, texture, model, _pull, _sunModel)
    if not (state.active and mesh) then return end
    local sh = state.shader
    if not sh then return end
    if texture then pcall(mesh.setTexture, mesh, texture) end
    pcall(sh.send, sh, "u_model", "row", model or IDENTITY)
    love.graphics.draw(mesh)
  end

  -- No-ops (DESIGN.md 2b): the shim has no shadow mask, seam mask or glass
  -- pass to toggle. QuestHandsRenderer.lua calls all three unconditionally
  -- around its per-hand draw loop.
  function M.lighting(_on) end
  function M.seams(_on) end
  function M.glass(_on) end

  function M.release()
    if state.shader then pcall(state.shader.release, state.shader); state.shader = nil end
  end

  return M
end

return Voxel3DShim
