-- FRLG_VOXEL: outdoor sky -- a 24-sided cylinder plus zenith cap around the
-- eye, textured with a vertical gradient (zenith blue -> pale haze at the
-- horizon). The haze colour is also the fog colour, so distant terrain melts
-- into the horizon. Drawn first, without depth, unlit (zero normals).
--
-- Below the horizon (review R1): the magenta/cyan diagnostic (2026-09-28,
-- captures-r7r/diag, shot 04 rows 345-357 all magenta, no cyan) showed the
-- pale slit under the far tree line is this cylinder's below-horizon band,
-- not the clear colour. The band now grades from the fog colour at the
-- horizon to a dark forest haze within ~1.5 degrees (an extra ring just below
-- horY), and the outdoor clear uses the same forest haze.
--
-- Tour review R2 (2026-09-28): that forest band read as a dark ribbon over
-- the SEA. The band colour is now per direction: each of the 24 segments
-- takes the water share of its horizon sector (Scene:seaView) and blends
-- from the forest haze to a sea haze -- HORIZON down to the band ring (so it
-- meets the fully hazed sea plane seamlessly), then HORIZON mixed with sea
-- blue further down. Vertex colours carry it; the gradient texture's lower
-- half reaches white; band triangles sample only its white endpoint.
--
-- Worker "atmos" (GW-P1, daynight-weather-hook/DESIGN.md 4.6): the four
-- colours below are only the DAY defaults now (identical to before this
-- edit, so a grade-off desktop proof at 12:00 is pixel-identical). Per-frame
-- colours come from render/AtmosSky.lua through Sky.setPalette(pal), called
-- once per frame from View:prepare (a coordinator-anchored edit) only when
-- outdoors. setPalette rebuilds the 64-texel gradient with replacePixels
-- (not a new Image) only when the palette actually changed, and clears
-- bandKey so Sky.setBands' next call re-colours the below-horizon band too
-- (CRITIQUE R-O1: the band was cached by water share alone and stayed
-- day-coloured at night otherwise).
local V = ...
local Mat4 = V.require("render/Mat4")
local Shaders = V.require("render/Shaders")

local FogBackdrop=V.require("render/FogBackdrop")
local Sky = {}
local lastFrac,normalVertexCount
local fogSkyEnv,zeroEye={}, {0,0,0}

Sky.ZENITH = { 0.40, 0.64, 0.93 }
Sky.HORIZON = { 0.80, 0.89, 0.97 }
-- HORIZON * 0.55 pushed halfway toward (0.25, 0.40, 0.28)
Sky.FOREST = {
  (0.80 * 0.55 + 0.25) / 2, (0.89 * 0.55 + 0.40) / 2, (0.97 * 0.55 + 0.28) / 2,
}
Sky.SEA_BLUE = { 0.26, 0.52, 0.86 }
Sky.SEA_HAZE = {
  Sky.HORIZON[1] * 0.6 + 0.26 * 0.4, Sky.HORIZON[2] * 0.6 + 0.52 * 0.4, Sky.HORIZON[3] * 0.6 + 0.86 * 0.4,
}
Sky.RADIUS_M = 90                 -- metres from the eye
Sky.BAND_RING = -0.025            -- unit-cylinder y where the band is fully dark
local SEG = 24
Sky.SEG = SEG

Sky.FORMAT = {
  { "VertexPosition", "float", 3 },
  { "VertexTexCoord", "float", 2 },
  { "VertexNormal", "float", 3 },
  { "VertexColor", "byte", 4 },
}

local mesh, image, gradData
local verts, bandIdx = nil, nil   -- vertex list; band vertex -> {ring, j}
local bandKey = nil
local paletteKey = nil            -- worker "atmos": last colours sent to setPalette

-- 64 rows: v 0..0.5 = zenith -> horizon (sky), v 0.5..1 = horizon -> white
-- (the band's colour comes from the vertex colours). Writes into `data`
-- (reused across calls by setPalette, below) from the CURRENT Sky.ZENITH/
-- Sky.HORIZON so a palette change only touches 64 texels, never allocates.
local function fillGradientData(data)
  local n = 64
  for y = 0, n - 1 do
    local v = (y + 0.5) / n
    local r, g, b
    if v <= 0.5 then
      local k = (v / 0.5) ^ 2
      r = Sky.ZENITH[1] + (Sky.HORIZON[1] - Sky.ZENITH[1]) * k
      g = Sky.ZENITH[2] + (Sky.HORIZON[2] - Sky.ZENITH[2]) * k
      b = Sky.ZENITH[3] + (Sky.HORIZON[3] - Sky.ZENITH[3]) * k
    else
      local k = math.min(1, (v - 0.5) / 0.5)
      r = Sky.HORIZON[1] + (1 - Sky.HORIZON[1]) * k
      g = Sky.HORIZON[2] + (1 - Sky.HORIZON[2]) * k
      b = Sky.HORIZON[3] + (1 - Sky.HORIZON[3]) * k
    end
    -- Band triangles use the exact white endpoint and interpolate only
    -- vertex colours, avoiding a bright product of two dark-endpoint fades.
    if y == n - 1 then r, g, b = 1, 1, 1 end
    data:setPixel(0, y, r, g, b, 1)
  end
  return data
end

local function gradient()
  if image then return image end
  gradData = gradData or love.image.newImageData(1, 64, "rgba8")
  local okG = pcall(fillGradientData, gradData)
  if not okG then return nil end
  image = love.graphics.newImage(gradData)
  image:setFilter("linear", "linear")
  pcall(image.setWrap, image, "clamp", "clamp")
  return image
end

-- Worker "atmos" (GW-P1): pal = { zenith, horizon, forest, seaHaze }, the
-- exact shape render/AtmosSky.lua's AtmosSky.at() returns. Called once per
-- frame, outdoors only (View:prepare, coordinator-anchored). A no-op when
-- the colours have not actually changed (quantised so float jitter from the
-- caller's own interpolation never triggers a rebuild every frame).
local function paletteQuantKey(pal)
  local function q3(c) return math.floor(c[1] * 255 + 0.5), math.floor(c[2] * 255 + 0.5), math.floor(c[3] * 255 + 0.5) end
  local zr, zg, zb = q3(pal.zenith)
  local hr, hg, hb = q3(pal.horizon)
  local fr, fg, fb = q3(pal.forest)
  local sr, sg, sb = q3(pal.seaHaze)
  return table.concat({ zr, zg, zb, hr, hg, hb, fr, fg, fb, sr, sg, sb }, ",")
end

function Sky.setPalette(pal)
  if not (pal and pal.zenith and pal.horizon and pal.forest and pal.seaHaze) then return false end
  local okK, key = pcall(paletteQuantKey, pal)
  if not okK then return false end
  if key == paletteKey then return false end
  paletteKey = key
  Sky.ZENITH, Sky.HORIZON, Sky.FOREST, Sky.SEA_HAZE = pal.zenith, pal.horizon, pal.forest, pal.seaHaze
  if image and gradData then
    local okB = pcall(fillGradientData, gradData)
    if okB then pcall(image.replacePixels, image, gradData) end
  end
  -- CRITIQUE R-O1: the below-horizon band was cached by water share alone
  -- (Sky.setBands' bandKey) and would stay day-coloured through the night
  -- otherwise; force the next setBands call to re-run.
  bandKey = nil
  return true
end

-- Band colours of ring vertex j (angle j / SEG * 2pi) for a water share f:
-- the band ring and the low ring.
local function mix(a, b, f)
  return { a[1] + (b[1] - a[1]) * f, a[2] + (b[2] - a[2]) * f, a[3] + (b[3] - a[3]) * f }
end
function Sky.bandColours(f)
  f = math.max(0, math.min(1, f or 0))
  return mix(Sky.FOREST, Sky.HORIZON, f), mix(Sky.FOREST, Sky.SEA_HAZE, f)
end

local function build()
  if mesh then return mesh end
  local okG, grad = pcall(gradient)
  if not okG or not grad then return nil end
  verts, bandIdx = {}, {}
  local function v(x, y, z, vv, ring, j)
    verts[#verts + 1] = { x, y, z, 0.5, vv, 0, 0, 0, 1, 1, 1, 1 }
    if ring then bandIdx[#verts] = { ring, j % SEG } end
  end
  local lowY, bandY, horY, topY = -0.6, Sky.BAND_RING, 0.0, 0.55
  local H, VB, VT, VZ = 0.5, 1.0, 0.175, 0.0   -- v at horizon, band, top ring, zenith
  for i = 0, SEG - 1 do
    local a0, a1 = i / SEG * 2 * math.pi, (i + 1) / SEG * 2 * math.pi
    local x0, z0, x1, z1 = math.cos(a0), math.sin(a0), math.cos(a1), math.sin(a1)
    -- deep band: band ring colour -> low ring colour (vertex colours)
    v(x0, lowY, z0, VB, "low", i); v(x1, lowY, z1, VB, "low", i + 1); v(x1, bandY, z1, VB, "band", i + 1)
    v(x0, lowY, z0, VB, "low", i); v(x1, bandY, z1, VB, "band", i + 1); v(x0, bandY, z0, VB, "band", i)
    -- just below the horizon: fog colour -> band ring colour
    v(x0, bandY, z0, VB, "band", i); v(x1, bandY, z1, VB, "band", i + 1); v(x1, horY, z1, VB, "horizon", i + 1)
    v(x0, bandY, z0, VB, "band", i); v(x1, horY, z1, VB, "horizon", i + 1); v(x0, horY, z0, VB, "horizon", i)
    -- horizon -> upper wall
    v(x0, horY, z0, H); v(x1, horY, z1, H); v(x1, topY, z1, VT)
    v(x0, horY, z0, H); v(x1, topY, z1, VT); v(x0, topY, z0, VT)
    -- cap to the zenith
    v(x0, topY, z0, VT); v(x1, topY, z1, VT); v(0, 1, 0, VZ)
  end
  normalVertexCount=#verts
  -- Complete the lower hemisphere only for the shared haze field. The
  -- original fogless sky draw range excludes these triangles.
  for i=0,SEG-1 do
    local a0,a1=i/SEG*2*math.pi,(i+1)/SEG*2*math.pi
    v(math.cos(a1),lowY,math.sin(a1),VB)
    v(math.cos(a0),lowY,math.sin(a0),VB)
    v(0,-1,0,VB)
  end
  bandKey = nil
  Sky.setBands(lastFrac)
  local ok, m = pcall(love.graphics.newMesh, Sky.FORMAT, verts, "triangles", "dynamic")
  if not ok then return nil end
  m:setTexture(grad)
  mesh = m
  return mesh
end

-- frac[1..SEG] = water share per horizon sector (sector i = segment i-1),
-- or nil for all forest. Ring vertex j takes the mean of its two segments.
-- Updates the mesh only when the (quantised) shares change.
function Sky.setBands(frac)
  lastFrac=frac
  if not verts then return false end
  local q = {}
  for j = 0, SEG - 1 do
    local f = 0
    if frac then f = ((frac[(j - 1) % SEG + 1] or 0) + (frac[j % SEG + 1] or 0)) / 2 end
    q[j] = math.floor(math.max(0, math.min(1, f)) * 32 + 0.5) / 32
  end
  local key = table.concat(q, ",", 0, SEG - 1)
  if key == bandKey then return false end
  bandKey = key
  for idx, bj in pairs(bandIdx) do
    local band, low = Sky.bandColours(q[bj[2]])
    local c = bj[1] == "horizon" and Sky.HORIZON or (bj[1] == "band" and band or low)
    local vtx = verts[idx]
    vtx[9], vtx[10], vtx[11] = c[1], c[2], c[3]
  end
  if mesh then pcall(mesh.setVertices, mesh, verts) end
  return true
end

-- Lab 55 FRAME HOIST (OutdoorPerf.hoist): the sky's env and its model-view-
-- projection go into reused tables, with Mat4.chain's exact arithmetic
-- (vp * translate(eye) * scale(r)). Same uniforms, same draw.
local Perf = V.require("render/OutdoorPerf")
local SKY_FOG = { 1000, 2000, 0 }
local skyEnv = { fog = SKY_FOG }
local skyT = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }
local skyS = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }
local skyTmp, skyMvp = {}, {}
local function mulInto(r, a, b)
  for i = 0, 3 do
    local a1, a2, a3, a4 = a[i * 4 + 1], a[i * 4 + 2], a[i * 4 + 3], a[i * 4 + 4]
    for j = 1, 4 do
      r[i * 4 + j] = a1 * b[j] + a2 * b[4 + j] + a3 * b[8 + j] + a4 * b[12 + j]
    end
  end
  return r
end

-- vp = view-projection, eye = world position (cells), m = metres per cell
function Sky.draw(vp, eye, m, env)
  if Perf.hoist then return Sky._drawHoist(vp, eye, m, env) end
  local sm = build()
  local shader = Shaders.get("OPAQUE")
  if not (sm and shader) then return 0 end
  sm:setDrawRange(1,env.fogBackdrop and #verts or normalVertexCount)
  local r = Sky.RADIUS_M / m
  local g = love.graphics
  g.setDepthMode()
  g.setShader(shader)
  Shaders.frame(shader, { light = env.light, fog = { 1000, 2000, 0 }, fogColor = env.fogColor,
    fogBackdrop=env.fogBackdrop and FogBackdrop.environment(zeroEye,true,fogSkyEnv) or nil })
  Shaders.shadow(shader, nil)
  Shaders.texSize(shader, nil)   -- no atlas tile clamp on the gradient
  Shaders.send(shader, "u_mvp", "row", Mat4.chain(vp, Mat4.translate(eye[1], eye[2], eye[3]), Mat4.scale(r)))
  g.draw(sm)
  g.setShader()
  return 1
end

function Sky._drawHoist(vp, eye, m, env)
  local sm = build()
  local shader = Shaders.get("OPAQUE")
  if not (sm and shader) then return 0 end
  sm:setDrawRange(1,env.fogBackdrop and #verts or normalVertexCount)
  local r = Sky.RADIUS_M / m
  local g = love.graphics
  g.setDepthMode()
  g.setShader(shader)
  skyEnv.light, skyEnv.fogColor = env.light, env.fogColor
  skyEnv.fogBackdrop=env.fogBackdrop and FogBackdrop.environment(zeroEye,true,fogSkyEnv) or nil
  Shaders.frame(shader, skyEnv)
  Shaders.shadow(shader, nil)
  Shaders.texSize(shader, nil)   -- no atlas tile clamp on the gradient
  skyT[4], skyT[8], skyT[12] = eye[1], eye[2], eye[3]
  skyS[1], skyS[6], skyS[11] = r, r, r
  Shaders.send(shader, "u_mvp", "row", mulInto(skyMvp, mulInto(skyTmp, vp, skyT), skyS))
  g.draw(sm)
  g.setShader()
  return 1
end

function Sky.fogBackdrop(eye,out)
  FogBackdrop.palette(Sky.ZENITH,Sky.HORIZON,Sky.FOREST,Sky.SEA_HAZE,lastFrac)
  return FogBackdrop.environment(eye,false,out)
end

function Sky.fogColor()
  return { Sky.HORIZON[1], Sky.HORIZON[2], Sky.HORIZON[3], 1 }
end

-- Outdoor clear: whatever the sky cylinder does not cover is below it
-- (`sea` = overall water share of the horizon, 0 = forest haze).
function Sky.clearColor(sea)
  local _, c = Sky.bandColours(sea or 0)
  return { c[1], c[2], c[3], 1 }
end

function Sky.release()
  FogBackdrop.release()
  lastFrac=nil
  if mesh then pcall(mesh.release, mesh) end
  if image then pcall(image.release, image) end
  mesh, image, verts, bandIdx, bandKey = nil, nil, nil, nil, nil
  gradData, paletteKey = nil, nil -- worker "atmos": rebuilt fresh by the next gradient()/setPalette()
end

return Sky
