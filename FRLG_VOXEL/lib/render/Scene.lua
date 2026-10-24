-- FRLG_VOXEL: world geometry manager. Owns the per-map mesh cache, decides
-- which maps are placed around the current (root) map, feeds the mesher,
-- uploads love Meshes and draws them for one camera.
--
-- World frame: ROOT map cell coordinates. X east, Z south (1 cell = 1.0),
-- Y up (mesher units). Connected maps sit at their Map.computeWorld offsets;
-- meshes are cached per map in that map's own coordinates and positioned by
-- a model translation, so a seamless connection crossing re-places cached
-- maps instead of rebuilding them.
--
-- Building (review items 11/12/16/17): sync() only re-places maps and queues
-- jobs; pump() does the work OUTSIDE the XR frame (main.lua calls it before
-- XR.waitFrame, in panel frames too). A root change builds synchronously only
-- when the new root has no usable geometry; otherwise a stale root keeps
-- drawing its old meshes and every job runs as a coroutine that yields at
-- phase boundaries (input, mesher, each layer upload, shadow-mask rows) under
-- a per-frame millisecond budget. Jobs run nearest-first and skip maps past
-- the draw distance. Border rings have their own 3-slot cache keyed by a
-- signature and are replaced only once their successor is built.
local V = ...
local Mat4 = V.require("render/Mat4")
local Perf = V.require("render/OutdoorPerf") -- Lab 55
local Shaders = V.require("render/Shaders")
local Shrubs = V.require("render/FrShrubView")
local TreeView=V.require("render/FrlgTreeView")
local VoxelTrees=V.require("render/FrlgVoxelTrees")
local Light = V.require("render/Light")
local Solar = V.require("render/SolarShadows")
local Mip = V.require("render/Mip")
-- Lab 57 SIGNS: lettered FireRed sign fronts (render/SignRuntime). Optional: without it every sign stays native.
local okSign, SignRuntime = pcall(V.require, "render/SignRuntime")
if not (okSign and type(SignRuntime) == "table") then SignRuntime = nil end
-- worker "atmos" (GW-P4, DESIGN.md 3.5/4.7): emissive glow masks and warm
-- ground-pool baking. Both degrade to "nothing drawn" on their own (no
-- provider registered, no doors found), so requiring them unconditionally
-- here is safe even before BR/the Gen3 compat layer exist.
local Emissive = V.require("render/Emissive")
local LightPools = V.require("render/LightPools")
-- read-only data table of water behaviours (optional: no MB, no sea logic)
local okMB, MB = pcall(V.require, "mesh/MB")
if not (okMB and type(MB) == "table") then MB = {} end
MB.WATER_DEEP = MB.WATER_DEEP or {}
MB.WATER_SHALLOW = MB.WATER_SHALLOW or {}

local CavePlacement=V.require("cave/CavePlacement")
local CaveAnimation=V.require("cave/CaveAnimation")
local Scene = {}
Scene.__index = Scene

Scene.REACH = 28          -- cells of neighbour-map reach around the root
Scene.BORDER = 12         -- border ring width around the root map
Scene.CACHE_LIMIT = 14    -- cached map geometries kept (LRU beyond this)
Scene.BORDER_LIMIT = 3    -- cached border rings kept
Scene.REBUILD_MIN_GAP = 0.5
Scene.CHUNK = 16          -- cells per mesh chunk side (culling granularity)
Scene.SHADOW_ROWS = 4     -- mask texel rows between deadline checks
Scene.FAR_SLACK = 8       -- cells beyond the draw distance still worth building
-- Lab 55 BUILD SLICING (OutdoorPerf.buildSlice). Approach after ReVoxel
-- UpstreamSceneQueue (fine checkpoints, resident budget); our own code.
Scene.SLICE_TRIS = 1024        -- triangles bucketed / window-flagged between checkpoints
Scene.SLICE_VERTS = 4096       -- vertices per Mesh:setVertices upload slice
Scene.RESIDENT_TRIS = 1200000  -- resident map + border triangles before budget eviction
Scene.EVICT_SLACK = 16         -- cells past far + FAR_SLACK before a placed map may be evicted
-- Lab 55 FAR SHADOWS (OutdoorPerf.farMasks): a map keeps its sun mask when it
-- is the root or its rect lies within MASK_NEAR cells of the root rect (the
-- root's direct neighbours); border rings and every other map are "far".
Scene.MASK_NEAR = 1
Scene.DEFER_HOLD_TRIS = 400000 -- geometry held for deferred masks (tris, all pending jobs)

local function now()
  return (love and love.timer and love.timer.getTime and love.timer.getTime()) or os.clock()
end

-- Lab 58 speed items owned by the sea/layout worker (flags "seaview", "layoutpoll"); nil = absent = Lab 57 paths.
local okS58sv, Speed58sv = pcall(V.require, "perf/Speed58")
if not (okS58sv and type(Speed58sv) == "table") then Speed58sv = nil end
Scene.LAYOUT_POLL_GAP = 0.25 -- seconds between layoutVersion polls of the root map (flag "layoutpoll")

-- Yield only when running inside a build coroutine (LuaJIT: running() is nil
-- on the main thread) AND the frame's build deadline has passed, so a slice
-- ends as close to its budget as the check granularity allows (every chunk
-- upload, every Light.TRIS_PER_YIELD raster triangles, every few mask rows).
-- Synchronous builds (_runNow) set no deadline and never yield.
local deadline = nil
local function yieldPoint()
  if deadline and coroutine.running() and now() >= deadline then coroutine.yield() end
end
Scene._yieldPoint = yieldPoint
-- Lab 59: the same checkpoint, safe to call from anywhere in a build (also inside a table.sort comparator or other
-- C callback, where a yield raises "attempt to yield across C-call boundary": it then returns and tries again later).
local function yieldPointSafe()
  if deadline and coroutine.running() and now() >= deadline then pcall(coroutine.yield) end
end
Scene._yieldPointSafe = yieldPointSafe
-- Lab 59 PRECACHE ON FIRST LOAD seam (lib/perf/FrPrepare.lua): the bulk driver sets the deadline of its own
-- slice here (nil = none) and drives a second Scene instance; the live Scene:pump never calls this.
function Scene._setDeadline(t) deadline = t end
function Scene._hasDeadline() return deadline ~= nil end

-- Lab 55 (build-e): VR PERFORMANCE switches, owned by render/OutdoorPerf.
-- buildSlice (bool) and farMasks ("full" | "defer" | "off") are read live on
-- the build path; a missing module means Lab 52 behaviour (off / "full").
local okBuildPerf, BuildPerf = pcall(V.require, "render/OutdoorPerf")
if not (okBuildPerf and type(BuildPerf) == "table") then BuildPerf = { buildSlice = false, farMasks = "full" } end
Scene._buildPerf = BuildPerf -- test seam
Scene._signRuntime = SignRuntime -- test seam (Lab 57 SIGNS)
local function sliceOn() return BuildPerf.buildSlice == true end
local function farMode()
  local m = BuildPerf.farMasks
  if m == "defer" or m == "off" then return m end
  return "full"
end
-- Lab 57 WORLD CACHE: FireRed's own lib/perf/FrPrecache*.lua; a load failure means no cache.
local okPC, PCmod = pcall(V.require, "perf/FrPrecache")
if not (okPC and type(PCmod) == "table") then PCmod = nil end

local LightingRuntime=V.require('render/FrLightingRuntime')
local LightingBuild=V.require('render/FrLightingBuild')
local LightingPolicy=V.require('lighting/BuildingLightPolicy')
local LightingConfig=V.require('lighting/NativeLightingConfig')
function Scene.new(opts)
  -- Lab 8 P0-1 (fix 1c): WorldSource's first-seen atlas scan yields per mid
  -- through the same deadline check as the mesher and the shadow mask.
  if type(opts.source) == "table" and opts.source.yieldPoint == nil then
    opts.source.yieldPoint = yieldPoint
  end
  if type(opts.source) == "table" and opts.source.yieldSafe == nil then
    opts.source.yieldSafe = yieldPointSafe -- Lab 59
  end
  return setmetatable({
    source = opts.source,
    lighting=LightingRuntime.new(LightingPolicy.new(LightingConfig.policy)),
    retroGrass=opts.retroGrass, inflight={}, voxelTrees=VoxelTrees.new(),
    mesher = opts.mesher,          -- function(input) -> geom, meshName
    log = opts.log or print,
    cache = {},                    -- map id -> record
    borders = {},                  -- border key -> record
    placed = {},                   -- array of { key, id, def, ox, oy, border }
    queue = {},
    active = nil,                  -- { job, co } being built
    rootId = nil,
    rootDef = nil,
    lastRootBuild = 0,
    frameTris = 0,
    shadows = opts.shadows ~= false,
    precache = opts.precache,      -- Lab 57 WORLD CACHE object (lib/perf/FrPrecache) or nil
    isBusy = opts.isBusy,          -- fn() -> true while overrides are transient
    emissive = Emissive.new(),     -- worker "atmos" (GW-P4): per-pair/layer glow masks
  }, Scene)
end

-- ---------------------------------------------------------------- build

local function makeMesh(verts, image)
  if type(verts) ~= "table" or #verts < 3 or not image then return nil end
  local ok, mesh = pcall(love.graphics.newMesh, Shaders.FORMAT, verts, "triangles", "static")
  if not ok or not mesh then return nil, tostring(mesh) end
  mesh:setTexture(image)
  return mesh
end

-- Ground height per cell derived from the geometry itself: the LOWEST
-- up-facing opaque/under triangle whose centroid falls in the cell. Used
-- when the mesher gives no heightAt.
local function deriveHeights(geom, w, h)
  local heights = {}
  for _, list in ipairs({ geom.opaque or {}, geom.cutoutUnder or {} }) do
    for i = 1, #list - 2, 3 do
      local a, b, c = list[i], list[i + 1], list[i + 2]
      local ny = (a[7] or 0) + (b[7] or 0) + (c[7] or 0)
      if ny > 2.1 then
        local cx = math.floor((a[1] + b[1] + c[1]) / 3)
        local cz = math.floor((a[3] + b[3] + c[3]) / 3)
        if cx >= 0 and cz >= 0 and cx < w and cz < h then
          local y = (a[2] + b[2] + c[2]) / 3
          local k = cz * w + cx + 1
          if heights[k] == nil or y < heights[k] then heights[k] = y end
        end
      end
    end
  end
  return heights
end

-- worker "atmos" (coordinator review round 2, w3\CONTRACT_V2.md V2.8): the
-- AO-only mesh format attached (Mesh:attachAttribute) to a chunk's main
-- mesh, never used to CREATE the main mesh itself -- Shaders.FORMAT (and
-- every other consumer of it: Sea.lua, Billboards.lua, Panel.lua,
-- BattlePass.lua) is untouched by this feature.
local AO_FORMAT = { { "VertexAO", "float", 1 } }
-- urgent fix (W3->W8 report, 2026-09-28): same shape as AO_FORMAT, a
-- second small mesh attached as VertexEmit (Shaders.lua's matching
-- comment). Built from windowFlagsFor below, never from W3's mesher
-- directly -- W3's contract only publishes window RECTS (buildingInfo[i].
-- windows), not a per-vertex list, so Scene.lua rasterises them itself.
local EMIT_FORMAT = { { "VertexEmit", "float", 1 } }

-- Window glow gate (W3->W8 report and follow-ups, 2026-09-28; made
-- triangle- and texel-exact 2026-09-28 "glow-precise"). Two halves:
--
-- 1. windowFlagsFor: a 1.0/0.0 flag per list entry from W3's per-building
--    window records (geom.stats.buildingInfo[i].windows = { x, z, band,
--    wx0, wx1, wy0, wy1, wz, face, glass }; w3\CONTRACT_V2.md V2.9 and
--    daynight-weather-hook/W8_NOTES.md "W3 -> W8"). The facade is one quad
--    per CELL per BAND (WALL_ROW_UNIT tall), so a window's area on the wall
--    is its whole cell (x .. x+1) and band (from the building's groundY),
--    on the plane wz, facing `face`. The flag is decided ONCE PER TRIANGLE
--    from its CENTROID (the lists are triangle lists) and written to all
--    three of its vertices. The previous per-vertex test flagged every
--    vertex lying on a window cell's EDGE, so the neighbouring quads that
--    share those vertices got a 0..1 gradient of glow across their whole
--    face (live Pallet build: 75 opaque and 18 cutoutOver triangles outside
--    any window cell had 1-2 flagged vertices). A triangle must also face
--    the window's way (summed vertex normal within 60 degrees): the door
--    recess jambs (+-x) and soffits (-y) whose centroids sit on a window
--    cell's plane are not the window. Returns nil when nothing is flagged
--    (chunked() then attaches nothing; the shader reads 0 = no glow), which
--    keeps interiors and blocks (no buildingInfo windows) at zero glow.
--
-- 2. glassTexels: which ATLAS texels of those window triangles are glass,
--    for render/Emissive.lua's per-atlas mask (the shader glows mask *
--    v_emit, so only glass texels of registered window triangles light up:
--    frames, mullions, sills and siding stay unlit). Per window and atlas
--    tile (the texel rect its triangles' UVs cover), the marked texels are
--    those inside the window's tight glass rect (wx0..wx1 x wy0..wy1,
--    mapped to texels through the triangle's own position -> UV map), not
--    hidden under over art, whose colour is glass: in the window's
--    published colour list when W3 gives one (windows[i].glassColors, or
--    windows[i].glass as a list -- today glass is a texel COUNT), else by
--    the glass definition W3 used to find the window (GLASS_KEYS below), so
--    the marked texels are exactly the ones W3 counted (the unit test
--    checks each window's count). A palette derived from the art alone
--    (colours inside the rect that occur nowhere else in the tile) was
--    tried first and dropped: W3's rect is the bounding box of ALL glass in
--    the cell, and on Viridian tiles with two separate glass blobs it spans
--    the khaki sill strip (206,181,107) and garden art, which then glowed.
--    An over-art layer (window decals) is marked by the same rule; a window
--    with layer = "over" (glass in over art) marks nothing in the under
--    atlas.
local EMIT_EPS_Z = 0.06
local WALL_ROW_UNIT = 1.0 -- must match lib/mesh/Constants.lua's WALL_ROW_UNIT
local FACE_N = { south = { 0, 0, 1 }, north = { 0, 0, -1 } }
local ZQ = 8 -- wall-plane buckets per unit (EMIT_EPS_Z * 2 * ZQ < 1)
-- windowFlagsFor's entries: shared, never mutated (chunked()'s addVertex
-- copies the value into the per-chunk VertexEmit list)
local FLAG_ON, FLAG_OFF = { 1.0 }, { 0.0 }

-- W3's window-glass definition (lib/mesh/FrlgMesher.lua pass 3a, the
-- "night-readiness" windows scan; W8_NOTES.md "W3 -> W8"): one of the three
-- FRLG pane blues within 24 per channel, or a bright blue-dominant texel.
-- Kept identical to W3's so the marked texels match windows[i].glass; if
-- W3 publishes glassColors this is not used.
local GLASS_KEYS = { { 99, 165, 222 }, { 115, 189, 247 }, { 156, 214, 255 } }
local function isGlassColour(v)
  local r, g, b = math.floor(v / 65536) % 256, math.floor(v / 256) % 256, v % 256
  for i = 1, #GLASS_KEYS do
    local k = GLASS_KEYS[i]
    if math.abs(r - k[1]) <= 24 and math.abs(g - k[2]) <= 24 and math.abs(b - k[3]) <= 24 then return true end
  end
  return b >= 170 and b - r >= 60 and g >= r
end

-- A published colour list (0xRRGGBB numbers or {r, g, b} 0..255) as a set;
-- nil when `list` is not a non-empty list (e.g. today's glass texel count).
local function publishedPalette(list)
  if type(list) ~= "table" or #list == 0 then return nil end
  local pal, n = {}, 0
  for _, c in ipairs(list) do
    local v
    if type(c) == "number" then v = c
    elseif type(c) == "table" and tonumber(c[1]) and tonumber(c[2]) and tonumber(c[3]) then
      v = math.floor(tonumber(c[1])) * 65536 + math.floor(tonumber(c[2])) * 256 + math.floor(tonumber(c[3]))
    end
    if v then pal[v] = true; n = n + 1 end
  end
  return n > 0 and pal or nil
end

-- Flattened window records of one geom (nil when there are none).
local function windowList(buildingInfo)
  if type(buildingInfo) ~= "table" then return nil end
  local wins, zkeys, native = {}, {}, {}
  for _, b in ipairs(buildingInfo) do
    for _, w in ipairs(type(b) == "table" and b.nativeWindowTriangles or {}) do
      local v = w.vertices
      local pal = publishedPalette(w.glassColors)
      if type(v) == "table" and v[1] and v[2] and v[3] and pal then
        native[v[1]] = native[v[1]] or {}
        table.insert(native[v[1]], {owner=b,vertices=v, palette=pal, layer=w.layer == "over" and "over" or "under", src=w})
      end
    end
    local bw = type(b) == "table" and b.windows
    local groundY = type(b) == "table" and tonumber(b.groundY) or nil
    if type(bw) == "table" and groundY then
      for _, w in ipairs(bw) do
        if type(w) == "table" then
          local x, band, wz = tonumber(w.x), tonumber(w.band), tonumber(w.wz)
          local face = FACE_N[w.face or "south"]
          if x and band and wz and face then
            local y0 = groundY + (band - 1) * WALL_ROW_UNIT
            wins[#wins + 1] = {
              owner=b, x0 = x, x1 = x + 1, y0 = y0, y1 = y0 + WALL_ROW_UNIT, wz = wz, face = face,
              gx0 = tonumber(w.wx0), gx1 = tonumber(w.wx1), gy0 = tonumber(w.wy0), gy1 = tonumber(w.wy1),
              palette = publishedPalette(w.glassColors) or publishedPalette(w.glass),
              layer = w.layer == "over" and "over" or "under", src = w,
            }
            zkeys[math.floor(wz * ZQ)] = true
          end
        end
      end
    end
  end
  if #wins == 0 and not next(native) then return nil end
  wins.native = native
  wins.zkeys = zkeys -- wall planes present (a cheap per-triangle pre-test)
  return wins
end
Scene._windowList = windowList

-- verts: a triangle list (Shaders.FORMAT tuples {x,y,z,u,v,nx,ny,nz}).
-- hits (optional table): receives { win = <windowList record>, tri = i }
-- per flagged triangle (i = its first entry). wins (optional): a prebuilt
-- windowList(buildingInfo), so one build computes it once.
-- every (optional, Lab 55 buildSlice): call yieldPoint() every `every`
-- triangles; nil = no checkpoints (Lab 52).
local function windowFlagsFor(verts, buildingInfo, hits, wins, every)
  if type(verts) ~= "table" or #verts < 3 then return nil end
  wins = wins or windowList(buildingInfo)
  if not wins then return nil end
  local zkeys = wins.zkeys
  local out, any = {}, false
  local n3 = #verts - #verts % 3
  local left = every
  for i = 1, n3, 3 do
    if left then
      left = left - 1
      if left <= 0 then left = every; yieldPoint() end
    end
    local a, b, c = verts[i], verts[i + 1], verts[i + 2]
    local cz = (a[3] + b[3] + c[3]) / 3
    local hit = FLAG_OFF
    local native
    local records = wins.native and wins.native[a]
    if records then
      for _, record in ipairs(records) do
        if record.vertices[2] == b and record.vertices[3] == c then native = record; break end
      end
    end
    if native then
      hit = FLAG_ON; any = true
      if hits then hits[#hits + 1] = {win=native, tri=i} end
    end
    if hit == FLAG_OFF and (not zkeys or zkeys[math.floor((cz - EMIT_EPS_Z) * ZQ)] or zkeys[math.floor((cz + EMIT_EPS_Z) * ZQ)]) then
      local cx = (a[1] + b[1] + c[1]) / 3
      local cy = (a[2] + b[2] + c[2]) / 3
      local nx = (a[6] or 0) + (b[6] or 0) + (c[6] or 0)
      local ny = (a[7] or 0) + (b[7] or 0) + (c[7] or 0)
      local nz = (a[8] or 0) + (b[8] or 0) + (c[8] or 0)
      local nl = math.sqrt(nx * nx + ny * ny + nz * nz)
      for k = 1, #wins do
        local w = wins[k]
        if math.abs(cz - w.wz) <= EMIT_EPS_Z and cx >= w.x0 and cx <= w.x1 and cy >= w.y0 and cy <= w.y1 then
          local f = w.face
          -- a zero summed normal ("unlit" geometry) is not a wall; skip it too
          if nl > 1e-4 and nx * f[1] + ny * f[2] + nz * f[3] >= 0.5 * nl then
            hit = FLAG_ON
            any = true
            if hits then hits[#hits + 1] = { win = w, tri = i } end
            break
          end
        end
      end
    end
    out[i], out[i + 1], out[i + 2] = hit, hit, hit
  end
  for i = n3 + 1, #verts do out[i] = FLAG_OFF end -- a stray partial triangle never glows
  if not any then return nil end
  return out
end
Scene._windowFlagsFor = windowFlagsFor -- worker "atmos": test seam

-- 0xRRGGBB of an atlas texel, nil when transparent (alpha < 0.5).
local function texelColour(data, x, y)
  local r, g, b, a = data:getPixel(x, y)
  if not a or a < 0.5 then return nil end
  return math.floor(r * 255 + 0.5) * 65536 + math.floor(g * 255 + 0.5) * 256 + math.floor(b * 255 + 0.5)
end

-- Texel rect a triangle's UVs cover in a W x H atlas (alphaFn's rounding).
local function triTexRect(a, b, c, W, H)
  local u0, u1 = math.min(a[4], b[4], c[4]), math.max(a[4], b[4], c[4])
  local v0, v1 = math.min(a[5], b[5], c[5]), math.max(a[5], b[5], c[5])
  local x0 = math.max(0, math.min(W - 1, math.floor(u0 * W + 1e-3)))
  local x1 = math.max(x0, math.min(W - 1, math.ceil(u1 * W - 1e-3) - 1))
  local y0 = math.max(0, math.min(H - 1, math.floor(v0 * H + 1e-3)))
  local y1 = math.max(y0, math.min(H - 1, math.ceil(v1 * H - 1e-3) - 1))
  return x0, y0, x1, y1
end

-- The window's tight glass rect in atlas texels (texel centres inside the
-- rect), through triangle abc's affine (x, y) -> (u, v) map; nil when the
-- triangle is degenerate in x/y or the window has no tight rect.
local function glassTexRect(w, a, b, c, W, H)
  if not (w.gx0 and w.gx1 and w.gy0 and w.gy1) then return nil end
  local x1, y1 = b[1] - a[1], b[2] - a[2]
  local x2, y2 = c[1] - a[1], c[2] - a[2]
  local det = x1 * y2 - x2 * y1
  if math.abs(det) < 1e-9 then return nil end
  local tx0, ty0, tx1, ty1 = math.huge, math.huge, -math.huge, -math.huge
  for _, p in ipairs({ { w.gx0, w.gy0 }, { w.gx1, w.gy0 }, { w.gx0, w.gy1 }, { w.gx1, w.gy1 } }) do
    local dx, dy = p[1] - a[1], p[2] - a[2]
    local s = (dx * y2 - x2 * dy) / det
    local t = (x1 * dy - dx * y1) / det
    local tx = (a[4] + s * (b[4] - a[4]) + t * (c[4] - a[4])) * W
    local ty = (a[5] + s * (b[5] - a[5]) + t * (c[5] - a[5])) * H
    if tx < tx0 then tx0 = tx end
    if tx > tx1 then tx1 = tx end
    if ty < ty0 then ty0 = ty end
    if ty > ty1 then ty1 = ty end
  end
  return math.ceil(tx0 - 0.5), math.ceil(ty0 - 0.5), math.floor(tx1 - 0.5), math.floor(ty1 - 0.5)
end

-- layers: array of { key = "under"|"over", verts = <triangle list>,
-- hits = <windowFlagsFor hits> }. atlases: { under = ImageData-like,
-- over = ImageData-like } (only getPixel/getDimensions are used; either may
-- be nil; the over atlas shares the under atlas's texel layout, so an
-- opaque over texel at the same position hides an under texel). Returns
-- { under = { idx, ... }, over = { ... }, underW, underH, overW, overH,
-- tiles = <window tiles with glass> } where idx = y * W + x in that atlas.
local function glassTexels(layers, atlases)
  local res = { under = {}, over = {}, tiles = 0 }
  local dims = {}
  for _, key in ipairs({ "under", "over" }) do
    local d = atlases and atlases[key]
    if d and d.getPixel and d.getDimensions then
      local W, H = d:getDimensions()
      dims[key] = { d, W, H }
      res[key .. "W"], res[key .. "H"] = W, H
    end
  end
  local cover = nil
  if dims.under and dims.over and dims.under[2] == dims.over[2] and dims.under[3] == dims.over[3] then
    cover = dims.over[1]
  end
  local seen = { under = {}, over = {} }
  for _, L in ipairs(layers) do
    local dm = dims[L.key]
    if dm and type(L.hits) == "table" and #L.hits > 0 then
      local data, W, H = dm[1], dm[2], dm[3]
      local hidden = L.key == "under" and cover or nil
      local verts = L.verts
      -- group this layer's hits by (window, tile)
      local groups, order = {}, {}
      for hi, h in ipairs(L.hits) do
        if hi % 128 == 0 then yieldPoint() end -- Lab 59 checkpoint (no-op outside a build slice)
        if not (h.win.layer == "over" and L.key == "under") then
          local a, b, c = verts[h.tri], verts[h.tri + 1], verts[h.tri + 2]
          local x0, y0, x1, y1 = triTexRect(a, b, c, W, H)
          local gk = tostring(h.win) .. ":" .. x0 .. "," .. y0 .. "," .. x1 .. "," .. y1
          local gr = groups[gk]
          if not gr then
            gr = { win = h.win, x0 = x0, y0 = y0, x1 = x1, y1 = y1 }
            groups[gk] = gr
            order[#order + 1] = gk
          end
          if not gr.clipped then
            local gx0, gy0, gx1, gy1 = glassTexRect(h.win, a, b, c, W, H)
            if gx0 then
              -- the tile clipped to the tight glass rect
              gr.x0, gr.y0 = math.max(gr.x0, gx0), math.max(gr.y0, gy0)
              gr.x1, gr.y1 = math.min(gr.x1, gx1), math.min(gr.y1, gy1)
              gr.clipped = true
            end
          end
        end
      end
      for _, gk in ipairs(order) do
        local gr = groups[gk]
        local pal = gr.win.palette
        -- no tight rect and no published palette: nothing to go on
        if gr.clipped or pal then
          local out, mark = res[L.key], seen[L.key]
          local marked = 0
          for y = gr.y0, gr.y1 do
            if (y - gr.y0) % 4 == 3 then yieldPoint() end -- Lab 59 checkpoint
            for x = gr.x0, gr.x1 do
              local v = texelColour(data, x, y)
              if v and (pal and pal[v] or (not pal and isGlassColour(v)))
                  and not (hidden and texelColour(hidden, x, y)) then
                local idx = y * W + x
                if not mark[idx] then mark[idx] = true; out[#out + 1] = idx end
                marked = marked + 1
              end
            end
          end
          if marked > 0 then res.tiles = res.tiles + 1 end
        end
      end
    end
  end
  return res
end
Scene._glassTexels = glassTexels -- test seam

local function addVertex(bk, v, ao, emit)
  local l = bk.list
  l[#l + 1] = v
  if bk.ao then bk.ao[#bk.ao + 1] = { tonumber(ao) or 1 } end
  if bk.emit then
    -- windowFlagsFor's entries are one-item tables ({ 1.0 }), not plain
    -- numbers like geom.ao's; tonumber() of a table is nil, which zeroed
    -- every uploaded VertexEmit value (no window glowed anywhere). Unwrap.
    if type(emit) == "table" then emit = emit[1] end
    bk.emit[#bk.emit + 1] = { tonumber(emit) or 0 }
  end
  local x, y, z = v[1], v[2], v[3]
  if x < bk.x0 then bk.x0 = x end
  if x > bk.x1 then bk.x1 = x end
  if y < bk.y0 then bk.y0 = y end
  if y > bk.y1 then bk.y1 = y end
  if z < bk.z0 then bk.z0 = z end
  if z > bk.z1 then bk.z1 = z end
  if v.frTree then
    local ax,az=v.frTree[1],v.frTree[2]
    local radius=math.sqrt((x-ax)^2+(z-az)^2)
    bk.x0=math.min(bk.x0,ax-radius);bk.x1=math.max(bk.x1,ax+radius)
    bk.z0=math.min(bk.z0,az-radius);bk.z1=math.max(bk.z1,az+radius)
  end
end

-- Split one layer's triangle list into CHUNK x CHUNK cell buckets (by
-- triangle centroid) with world-space bounds, so each eye can skip chunks
-- outside its frustum or past the haze. Yields after each chunk upload.
-- aoList (optional): geom.ao.opaque/cutoutUnder, one number per `verts`
-- entry (w3\CONTRACT_V2.md V2.8, "one light multiplier per list entry").
-- When given, each chunk also gets a small AO-only mesh attached as
-- VertexAO; a chunk's ch.aoMesh is nil whenever aoList is absent (the
-- common AO_BAKE-off case) or building/attaching it failed for that chunk.
-- emitList (optional, urgent fix W3->W8 report): windowFlagsFor's output,
-- one entry per `verts` entry like aoList, but each entry is a one-item
-- table ({ 1.0 } / { 0.0 }) that addVertex unwraps; attached as VertexEmit
-- the same way, ch.emitMesh.
--
-- Lab 55 BUILD SLICING (sliceOn()): a checkpoint every Scene.SLICE_TRIS
-- bucketed triangles, and a chunk with more than Scene.SLICE_VERTS vertices
-- is uploaded as newMesh(format, count) + Mesh:setVertices(slice, start)
-- with a checkpoint between slices. Same vertices, same chunks, same order;
-- if the sliced upload fails for any reason it falls back to the Lab 52
-- one-call upload of that chunk.

-- Upload `list` (a vertex list) into a new mesh in slices. The mesh is handed
-- to own(mesh) BEFORE the first slice so a cancelled build releases it.
-- -> mesh | nil, err
local function slicedMesh(format, list, own)
  local n = #list
  local okM, mesh = pcall(love.graphics.newMesh, format, n, "triangles", "static")
  if not okM or not mesh then return nil, tostring(mesh) end
  own(mesh)
  local step = Scene.SLICE_VERTS
  local part = {}
  for first = 1, n, step do
    local last = math.min(n, first + step - 1)
    local k = 0
    for i = first, last do k = k + 1; part[k] = list[i] end
    for i = #part, k + 1, -1 do part[i] = nil end
    local okS, err = pcall(mesh.setVertices, mesh, part, first)
    if not okS then return nil, tostring(err) end
    if last < n then yieldPoint() end
  end
  return mesh
end

-- Sliced variant of one chunk's upload (main mesh, then AO / emit meshes).
-- The chunk record goes into `out` before any slice; on a failed sliced
-- upload the chunk falls back to makeMesh (Lab 52) in the same slot.
local function uploadSliced(out, bk, image)
  local ch = { mesh = nil, aoMesh = nil, emitMesh = nil, tris = #bk.list / 3,
    x0 = bk.x0, y0 = bk.y0, z0 = bk.z0, x1 = bk.x1, y1 = bk.y1, z1 = bk.z1 }
  local slot = #out + 1
  local placeholder = { release = function() end }
  ch.mesh = placeholder
  out[slot] = ch
  local mesh = slicedMesh(Shaders.FORMAT, bk.list, function(m) ch.mesh = m end)
  if mesh then
    mesh:setTexture(image)
  else
    if ch.mesh ~= placeholder then pcall(ch.mesh.release, ch.mesh) end
    local m2, err = makeMesh(bk.list, image)
    if not m2 then out[slot] = nil; return nil, err end
    mesh = m2
  end
  ch.mesh = mesh
  if bk.ao then
    local am = slicedMesh(AO_FORMAT, bk.ao, function(m) ch.aoMesh = m end)
    if am then
      local okAttach = pcall(mesh.attachAttribute, mesh, "VertexAO", am)
      if not okAttach then pcall(am.release, am); ch.aoMesh = nil end
    elseif ch.aoMesh then
      pcall(ch.aoMesh.release, ch.aoMesh); ch.aoMesh = nil
    end
  end
  if bk.emit then
    local em = slicedMesh(EMIT_FORMAT, bk.emit, function(m) ch.emitMesh = m end)
    if em then
      local okAttach = pcall(mesh.attachAttribute, mesh, "VertexEmit", em)
      if not okAttach then pcall(em.release, em); ch.emitMesh = nil end
    elseif ch.emitMesh then
      pcall(ch.emitMesh.release, ch.emitMesh); ch.emitMesh = nil
    end
  end
  return ch
end

local function chunked(verts, image, size, aoList, emitList, owner, layer)
  local out = {}
  if owner then owner[layer]=out end
  if type(verts) ~= "table" or #verts < 3 or not image then return out end
  local hasAO = type(aoList) == "table" and #aoList >= #verts
  local hasEmit = type(emitList) == "table" and #emitList >= #verts
  local buckets, order = {}, {}
  local every = sliceOn() and Scene.SLICE_TRIS or nil
  local left = every
  for i = 1, #verts - 2, 3 do
    if left then
      left = left - 1
      if left <= 0 then left = every; yieldPoint() end
    end
    local a, b, c = verts[i], verts[i + 1], verts[i + 2]
    local cx = math.floor((a[1] + b[1] + c[1]) / (3 * size))
    local cz = math.floor((a[3] + b[3] + c[3]) / (3 * size))
    local key = cz * 4096 + cx
    local bk = buckets[key]
    if not bk then
      bk = { list = {}, ao = hasAO and {} or nil, emit = hasEmit and {} or nil,
             x0 = math.huge, y0 = math.huge, z0 = math.huge,
             x1 = -math.huge, y1 = -math.huge, z1 = -math.huge }
      buckets[key] = bk
      order[#order + 1] = key
    end
    addVertex(bk, a, hasAO and aoList[i], hasEmit and emitList[i])
    addVertex(bk, b, hasAO and aoList[i + 1], hasEmit and emitList[i + 1])
    addVertex(bk, c, hasAO and aoList[i + 2], hasEmit and emitList[i + 2])
  end
  table.sort(order)
  for _, key in ipairs(order) do
    local bk = buckets[key]
    local sliced = every and #bk.list > Scene.SLICE_VERTS
    local mesh, err
    if sliced then
      local ch
      ch, err = uploadSliced(out, bk, image)
      mesh = ch and ch.mesh
      buckets[key] = nil
    else
      mesh, err = makeMesh(bk.list, image)
    end
    if not mesh then
      for _, ch in ipairs(out) do
        pcall(ch.mesh.release, ch.mesh)
        if ch.aoMesh then pcall(ch.aoMesh.release, ch.aoMesh) end
        if ch.emitMesh then pcall(ch.emitMesh.release, ch.emitMesh) end
        if ch.treeMesh then pcall(ch.treeMesh.release, ch.treeMesh) end
      end
      if owner then owner[layer]=nil end
      return nil, err or "mesh upload failed"
    end
    if not sliced then -- Lab 52 one-call upload (uploadSliced did all of this already)
    local aoMesh = nil
    if bk.ao then
      local okAO, am = pcall(love.graphics.newMesh, AO_FORMAT, bk.ao, "triangles", "static")
      if okAO and am then
        local okAttach = pcall(mesh.attachAttribute, mesh, "VertexAO", am)
        if okAttach then aoMesh = am else pcall(am.release, am) end
      end
    end
    local emitMesh = nil
    if bk.emit then
      local okE, em = pcall(love.graphics.newMesh, EMIT_FORMAT, bk.emit, "triangles", "static")
      if okE and em then
        local okAttach = pcall(mesh.attachAttribute, mesh, "VertexEmit", em)
        if okAttach then emitMesh = em else pcall(em.release, em) end
      end
    end
    out[#out + 1] = { mesh = mesh, aoMesh = aoMesh, emitMesh = emitMesh, tris = #bk.list / 3,
      x0 = bk.x0, y0 = bk.y0, z0 = bk.z0, x1 = bk.x1, y1 = bk.y1, z1 = bk.z1 }
    end -- not sliced
    local ch=out[#out]
    local attr,treeErr=TreeView.attach(ch.mesh,bk.list)
    ch.treeMesh=attr
    if treeErr then error("native tree attachment: "..tostring(treeErr)) end
    yieldPoint()
  end
  return out
end
Scene._chunked = chunked -- worker "atmos": test seam (same pattern as Scene._yieldPoint above)

-- interiors-team (build/integ/RENDER_PATCH.md, contract V2.14): the room
-- shell of an interior (geom.roomShell: the 4th wall, south doors, fillers,
-- ceiling, risers, shafts, lamps) is its own chunk list ("shell"), drawn with
-- the OPAQUE shader right after the opaque layer. Each chunk keeps the shell's
-- visibility groups as vertex ranges; once per frame Scene.shellFrame picks
-- the visible groups for the camera mode and each chunk draws only those
-- ranges (Mesh:setDrawRange). No uniform, no shader text; the shell is not in
-- the shadow casters (Light only reads the four base lists) and gets no AO
-- (drawLayer's layer-name gate sends u_aoOn = 0 for it: a missing VertexAO
-- would read 0 = black).
local SHELL_WALL = { wall = true, filler = true, door = true, sill = true }
Scene.SHELL_WALL = SHELL_WALL
Scene.ROOM_MARGIN = 0.02 -- cells (FrlgInteriors M.MARGIN)
-- (repair2) the shell's own bucket size: a room's shell is a few hundred
-- triangles (584 at most), so one chunk per 64 x 64 cells -- every interior
-- but the longest tunnels is ONE chunk: first person draws it in one call per
-- eye (CHUNK = 16 made up to 9: the Power Plant, Mansion 1F), third person in
-- one per visible range. Culling a chunk that surrounds the eye saves nothing.
Scene.SHELL_CHUNK = 64
-- (repair2, V2) is the ROOT map an open-air interior (the core's roomShell
-- .openAir: the 9 harbors, the 3 roofs, the S.S. Anne deck and exterior)?
-- View then draws the sky there instead of the black indoor clear.
function Scene:rootOpenAir()
  local rec = self.rootId and self.cache and self.cache[self.rootId]
  return (rec and rec.openAir == true) or false
end

-- Bucket the shell's triangles like chunked() (CHUNK x CHUNK cells by
-- centroid, input order kept), recording per chunk the flat range list
-- rg = { gid, firstVertex, vertexCount, ... }: the shell's groups are
-- contiguous triangle runs, so each group is one run per chunk. -> chunks |
-- nil, err (every mesh already made is released on failure).
local function shellChunks(shell, image, size, owner)
  local verts, groups = shell.verts, shell.groups
  if type(verts) ~= "table" or type(groups) ~= "table" or not image then return nil, "no shell" end
  -- (repair1, skeptic-render D2) validate every group at upload: an id, and
  -- a triangle range inside the vertex list -- a malformed shell is not
  -- drawn at all (the record stays), never a per-frame error later
  local gidOf = {}
  local nTri = math.floor(#verts / 3)
  for _, g in ipairs(groups) do
    if type(g) ~= "table" then return nil, "bad shell group" end
    local first, count = g.first, g.count
    if g.id == nil or g.id ~= g.id or type(first) ~= "number" or type(count) ~= "number"
        or first < 1 or count < 0 or first % 1 ~= 0 or count % 1 ~= 0 or first + count - 1 > nTri then
      return nil, "bad shell group " .. tostring(g.id)
    end
    for t = first, first + count - 1 do gidOf[t] = g.id end
  end
  local buckets, order = {}, {}
  for t = 1, math.floor(#verts / 3) do
    local gid = gidOf[t]
    if gid ~= nil then
      local i = (t - 1) * 3 + 1
      local a, b, c = verts[i], verts[i + 1], verts[i + 2]
      local cx = math.floor((a[1] + b[1] + c[1]) / (3 * size))
      local cz = math.floor((a[3] + b[3] + c[3]) / (3 * size))
      local key = cz * 4096 + cx
      local bk = buckets[key]
      if not bk then
        bk = { list = {}, rg = {}, x0 = math.huge, y0 = math.huge, z0 = math.huge,
               x1 = -math.huge, y1 = -math.huge, z1 = -math.huge }
        buckets[key] = bk
        order[#order + 1] = key
      end
      local n = #bk.list
      addVertex(bk, a)
      addVertex(bk, b)
      addVertex(bk, c)
      local rg = bk.rg
      local m = #rg
      if m > 0 and rg[m - 2] == gid and rg[m - 1] + rg[m] == n + 1 then
        rg[m] = rg[m] + 3
      else
        rg[m + 1], rg[m + 2], rg[m + 3] = gid, n + 1, 3
      end
    end
  end
  table.sort(order)
  local out = {}
  if owner then owner.shell=out end
  for _, key in ipairs(order) do
    local bk = buckets[key]
    local mesh, err = makeMesh(bk.list, image)
    if not mesh then
      for _, ch in ipairs(out) do pcall(ch.mesh.release, ch.mesh) end
      if owner then owner.shell=nil end
      return nil, err or "shell upload failed"
    end
    out[#out + 1] = { mesh = mesh, tris = #bk.list / 3, nverts = #bk.list, rg = bk.rg, vr = {}, nvr = 0,
      x0 = bk.x0, y0 = bk.y0, z0 = bk.z0, x1 = bk.x1, y1 = bk.y1, z1 = bk.z1 }
    yieldPoint()
  end
  return out
end
Scene._shellChunks = shellChunks -- test seam

-- Is map-local point (lx, lz) over a cell of the room? The mesher's heightAt
-- answers every map cell and nil for void / off-map (rec.heightFn); without
-- it the shell's ceiling heights (ceilY) decide; with neither: unknown (nil).
function Scene.roomInside(rec, lx, lz)
  local cx, cz = math.floor(lx), math.floor(lz)
  if rec.heightFn then
    local ok, v = pcall(rec.heightFn, cx, cz)
    return ok and type(v) == "number"
  end
  local info = rec.shellInfo
  if info and info.ceilY and info.W and info.H then
    if cx < 0 or cz < 0 or cx >= info.W or cz >= info.H then return false end
    return info.ceilY[cz * info.W + cx + 1] and true or false
  end
  return nil
end

-- Visibility of one shell group for an eye at map-local (ex, ey, ez).
-- mode: "first" (first person: everything), "third" (wall kinds while the
-- camera is inside the room -- `inside` ~= false -- and on the room side of
-- the plane, and the trainer (fx, fz; optional) too: a wall with the camera
-- on one side and the trainer on the other -- the trainer in an alcove or
-- door niche beyond that wall -- would stand between them; ceiling kinds
-- never), "halfspace" (the battle seat: exactly
-- FrlgInteriors M.roomVisible -- wall kinds by their plane, ceiling kinds
-- while the eye is below the ceiling over its OWN cell, shell.ceilY, else
-- the group's y0), anything else ("dollhouse": 3/4 view, table view, or no
-- mode given): nothing.
function Scene.roomVisible(group, ex, ey, ez, mode, shell, inside, fx, fz)
  if mode == "first" then return true end
  if mode ~= "third" and mode ~= "halfspace" then return false end
  local m = Scene.ROOM_MARGIN
  if SHELL_WALL[group.kind] then
    local nx, nz, d = group.nx or 0, group.nz or 0, group.d or 0
    if mode == "third" then
      if inside == false then return false end
      if fx and fz and nx * fx + nz * fz + d <= 0 then return false end
    end
    return nx * ex + nz * ez + d > m
  end
  if mode == "third" then return false end
  local y0 = group.y0
  if shell and shell.ceilY and shell.W then
    local cx, cz = math.floor(ex), math.floor(ez)
    if cx >= 0 and cz >= 0 and cx < shell.W and (not shell.H or cz < shell.H) then
      local cy = shell.ceilY[cz * shell.W + cx + 1]
      if cy then y0 = cy end
    end
  end
  if type(y0) ~= "number" then return false end
  return ey < y0 - m
end

-- Once per frame (Scene:prepareFrame): the visible groups of one record for
-- the eye (ROOT cells, { x, y, z }), mode and (third person) the trainer
-- (focus, ROOT cells, optional); fills rec.shellDraw with the chunks that
-- have something to draw, each with its merged visible vertex ranges (ch.vr,
-- ch.nvr). No eye / no mode: nothing drawn. -> #rec.shellDraw
function Scene.shellFrame(rec, eye, mode, focus)
  local draw = rec.shellDraw
  if not draw then draw = {}; rec.shellDraw = draw end
  for i = #draw, 1, -1 do draw[i] = nil end
  local info, chunks = rec.shellInfo, rec.shell
  if not (info and chunks and type(eye) == "table") or mode == nil or mode == "dollhouse" then
    for _, ch in ipairs(chunks or {}) do ch.nvr, ch.shellRanges = 0, nil end
    return 0
  end
  local ex, ey, ez = (eye[1] or 0) - (rec.ox or 0), eye[2] or 0, (eye[3] or 0) - (rec.oz or 0)
  local inside, fx, fz = nil, nil, nil
  if mode == "third" then
    inside = Scene.roomInside(rec, ex, ez)
    if type(focus) == "table" and focus[1] and focus[3] then fx, fz = focus[1] - (rec.ox or 0), focus[3] - (rec.oz or 0) end
  end
  local vis = info.vis
  for _, g in ipairs(info.groups) do
    vis[g.id] = Scene.roomVisible(g, ex, ey, ez, mode, info, inside, fx, fz) and true or false
  end
  for _, ch in ipairs(chunks) do
    local rg, vr, n = ch.rg, ch.vr, 0
    for k = 1, #rg, 3 do
      if vis[rg[k]] then
        local first, count = rg[k + 1], rg[k + 2]
        if n > 0 and vr[2 * n - 1] + vr[2 * n] == first then
          vr[2 * n] = vr[2 * n] + count
        else
          n = n + 1
          vr[2 * n - 1], vr[2 * n] = first, count
        end
      end
    end
    ch.nvr = n
    if n > 0 then
      ch.shellRanges = vr
      draw[#draw + 1] = ch
    else
      ch.shellRanges = nil
    end
  end
  return #draw
end

-- (repair1, skeptic-render D2) the per-frame pass under pcall: an error
-- drops THIS record's shell for good (its meshes released, one log line) and
-- the frame goes on -- it never reaches the frame's own pcall (which on
-- Quest turns the whole 3D view off for the session).
function Scene.shellFrameSafe(rec, eye, mode, focus, log)
  local ok, n = pcall(Scene.shellFrame, rec, eye, mode, focus)
  if ok then return n end
  for _, ch in ipairs(rec.shell or {}) do
    if ch.mesh and ch.mesh.release then pcall(ch.mesh.release, ch.mesh) end
  end
  rec.shell, rec.shellInfo, rec.shellDraw = nil, nil, nil
  if type(log) == "function" then pcall(log, "room shell dropped for " .. tostring(rec.key) .. ": " .. tostring(n)) end
  return 0
end

-- drawLayer's draw for a shell chunk: its visible ranges, one call each.
local function shellDrawRanges(ch, counters)
  local vr, mesh = ch.vr, ch.mesh
  for k = 1, ch.nvr or 0 do
    local first, count = vr[2 * k - 1], vr[2 * k]
    mesh:setDrawRange(first, count)
    love.graphics.draw(mesh)
    counters.calls = counters.calls + 1
    counters.tris = counters.tris + count / 3
  end
end

local function releaseRecord(rec)
  if not rec then return end
  Shrubs.release(rec)
  if rec.compiledCaveImage then rec.compiledCaveImage:release();rec.compiledCaveImage=nil end
  if rec.healerFR then rec.healerFR.released = true end
  if rec.buildOwner then rec.buildOwner.inflight[rec]=nil;rec.buildOwner=nil end
  if rec.signRuntime then -- Lab 57 SIGNS: sign quads and shared textures go with the record (idempotent)
    if SignRuntime then SignRuntime.release(rec.signRuntime) end
    rec.signRuntime = nil
  end
  if rec.retroOwner then rec.retroOwner:releaseRecord(rec) end
  if rec.frVoxelOwner then rec.frVoxelOwner:releaseRecord(rec) end
  rec.shellDraw = nil -- interiors-team (S2)
  rec.pcInfo = nil -- Lab 57: a record released before its cache write is dropped from the queue
  for _, key in ipairs({ "opaque", "under", "over", "keyed", "shell" }) do -- interiors-team (S2): + the room shell
    for _, ch in ipairs(rec[key] or {}) do
      if ch.mesh and ch.mesh.release then pcall(ch.mesh.release, ch.mesh) end
      -- worker "atmos" (coordinator review round 2): the attached AO-only
      -- mesh (chunked()'s aoMesh) is a separate GPU buffer, released too.
      if ch.aoMesh and ch.aoMesh.release then pcall(ch.aoMesh.release, ch.aoMesh) end
      -- urgent fix (W3->W8 report): same for the attached window-flag mesh.
      if ch.emitMesh and ch.emitMesh.release then pcall(ch.emitMesh.release, ch.emitMesh) end
      if ch.treeMesh and ch.treeMesh.release then pcall(ch.treeMesh.release, ch.treeMesh) end
    end
    rec[key] = nil
  end
  if rec.shadow and rec.shadow.release then pcall(rec.shadow.release, rec.shadow) end
  Solar.unreserve(rec.solarOwner,rec)
  if rec.solarInitialData and rec.solarInitialData.release then pcall(rec.solarInitialData.release,rec.solarInitialData) end
  rec.solarInitialData=nil
  if rec.solarInitialImage and rec.solarInitialImage.release then pcall(rec.solarInitialImage.release,rec.solarInitialImage) end
  rec.solarInitialImage=nil
  rec.shadow = nil
  if rec.solarField and rec.solarField.release then pcall(rec.solarField.release, rec.solarField) end
  rec.solarField = nil
  rec.shadowData = nil
  if rec.poolsOnly and rec.poolsOnly.release then pcall(rec.poolsOnly.release,rec.poolsOnly) end
  rec.poolsOnly=nil
  if rec.lightRecord then rec.lightRecord:release();rec.lightRecord=nil end
end
Scene.releaseRecord = releaseRecord
function Scene:_releaseInflight(co)
  local list={};for rec in pairs(self.inflight)do if not co or rec.buildCoroutine==co then list[#list+1]=rec end end
  for _,rec in ipairs(list)do releaseRecord(rec)end
end

-- Six planes of a (row-major) view-projection, for AABB culling.
local function frustumPlanes(m)
  local r1 = { m[1], m[2], m[3], m[4] }
  local r2 = { m[5], m[6], m[7], m[8] }
  local r3 = { m[9], m[10], m[11], m[12] }
  local r4 = { m[13], m[14], m[15], m[16] }
  local planes = {}
  local function add(s, r)
    planes[#planes + 1] = { r4[1] + s * r[1], r4[2] + s * r[2], r4[3] + s * r[3], r4[4] + s * r[4] }
  end
  add(1, r1); add(-1, r1); add(1, r2); add(-1, r2); add(1, r3); add(-1, r3)
  return planes
end
Scene.frustumPlanes = frustumPlanes

-- Lab 55 EYE SCRATCH (OutdoorPerf.scratch): the same six planes, written into
-- caller-owned tables with the same arithmetic (approach after ReVoxel's
-- NativeVisibility: the caller owns the scratch; our code).
local function putPlane(planes, i, m, s, a, b, c, d)
  local p = planes[i]
  if not p then p = {}; planes[i] = p end
  p[1], p[2], p[3], p[4] = m[13] + s * a, m[14] + s * b, m[15] + s * c, m[16] + s * d
end
local function planesInto(planes, m)
  putPlane(planes, 1, m, 1, m[1], m[2], m[3], m[4]); putPlane(planes, 2, m, -1, m[1], m[2], m[3], m[4])
  putPlane(planes, 3, m, 1, m[5], m[6], m[7], m[8]); putPlane(planes, 4, m, -1, m[5], m[6], m[7], m[8])
  putPlane(planes, 5, m, 1, m[9], m[10], m[11], m[12]); putPlane(planes, 6, m, -1, m[9], m[10], m[11], m[12])
  return planes
end
-- emissive memo field names per layer key (no string building per draw)
local EMIT_FIELDS = { under = { "under", "underLive", "underSet" }, over = { "over", "overLive", "overSet" } }
Scene._planesInto = planesInto
-- r = a * b (Mat4.mul's exact expression), into r
local function mulInto(r, a, b)
  for i = 0, 3 do
    local a1, a2, a3, a4 = a[i * 4 + 1], a[i * 4 + 2], a[i * 4 + 3], a[i * 4 + 4]
    for j = 1, 4 do
      r[i * 4 + j] = a1 * b[j] + a2 * b[4 + j] + a3 * b[8 + j] + a4 * b[12 + j]
    end
  end
  return r
end
Scene._mulInto = mulInto

local function boxVisible(planes, x0, y0, z0, x1, y1, z1)
  for i = 1, #planes do
    local p = planes[i]
    local a, b, c = p[1], p[2], p[3]
    local px = a >= 0 and x1 or x0
    local py = b >= 0 and y1 or y0
    local pz = c >= 0 and z1 or z0
    if a * px + b * py + c * pz + p[4] < 0 then return false end
  end
  return true
end
Scene.boxVisible = boxVisible

-- Indoor maps and caves have no sun (tour review R4).
local function sunless(input)
  return input.kind == "indoor" or input.kind == "cave"
end
Scene.sunless = sunless

-- Tour review R4: what a cutout triangle SHOWS, from the CPU copies of the
-- atlases (tileset_native keeps imageData / overImageData for palette
-- animation). Per atlas and texel rect: the first and last rows with a
-- visible texel (alpha >= 0.5, and not a key colour for the keyed list), or
-- false when nothing in the rect shows.
local rectCache = setmetatable({}, { __mode = "k" })
local function visibleRows(data, keyed, x0, y0, x1, y1)
  local store = rectCache[data]
  if not store then store = {}; rectCache[data] = store end
  local key = (keyed and "k" or "a") .. x0 .. "," .. y0 .. "," .. x1 .. "," .. y1
  local hit = store[key]
  if hit ~= nil then
    if hit == false then return false end
    return hit[1], hit[2]
  end
  local top, bottom
  for y = y0, y1 do
    for x = x0, x1 do
      local r, g, b, a = data:getPixel(x, y)
      if a and a >= 0.5 and not (keyed and Mip.isKey(r, g, b)) then
        if top == nil then top = y end
        bottom = y
        break
      end
    end
  end
  if top == nil then store[key] = false; return false end
  store[key] = { top, bottom }
  return top, bottom
end
Scene._visibleRows = visibleRows

-- Lab 59 v4: the CPU atlas copies the glass scan and the shadow alpha read. While WorldSource.paintFree (VRITK active) they
-- are the CANONICAL art (WorldSource:canonicalImages: night paint undone, engine-animated tiles at frame 0), so a record
-- does not depend on the time of day or the animation frame. Safety net (the Lab 57 taint rule is retired): a painted
-- tileset with no pre-paint list to undo the paint (RTC bridge missing / not registered yet) flags the build so
-- _pcFinish refuses to save it.
local function cleanAtlases(self, pair)
  local ok, NT = pcall(require, "src.core.game3.tileset_native")
  local ts = ok and type(NT) == "table" and NT._pairs and NT._pairs[pair]
  if not ts then return nil end
  local src = self.source
  if not (src and src.canonicalImages) then return ts.imageData, ts.overImageData end
  local prov = src._originalsProvider
  local dn = ts._dnNight
  if type(dn) == "table" and next(dn) ~= nil then
    local okO, list = false, nil
    if type(prov) == "function" then okO, list = pcall(prov, pair) end
    if not (okO and type(list) == "table" and #list > 0) then self._pcPainted = true else
      self._paintLogged = self._paintLogged or {}
      if self._paintLogged[pair] ~= #list and self.log then
        self._paintLogged[pair] = #list
        self.log(("night paint ACTIVE on %s: %d painted texels; classification reads the canonical art (pre-paint, animation frame 0)"):format(tostring(pair), #list))
      end
    end
  end
  return src:canonicalImages(ts, pair)
end

local function pairAtlases(pair)
  local ok, NT = pcall(require, "src.core.game3.tileset_native")
  local ts = ok and type(NT) == "table" and NT._pairs and NT._pairs[pair]
  if not ts then return nil end
  return ts.imageData, ts.overImageData
end

-- opts.alpha for Light: false = nothing visible (skip); for vertical cards
-- the world heights of the top and bottom visible rows; nil = no information.
function Scene.alphaFn(underData, overData)
  if not (underData or overData) then return nil end
  return function(name, a, b, c, vertical)
    local data = name == "cutoutOver" and overData or underData
    if not (data and data.getPixel and data.getDimensions) then return nil end
    local W, H = data:getDimensions()
    local u0, u1 = math.min(a[4], b[4], c[4]), math.max(a[4], b[4], c[4])
    local v0, v1 = math.min(a[5], b[5], c[5]), math.max(a[5], b[5], c[5])
    local x0 = math.max(0, math.min(W - 1, math.floor(u0 * W + 1e-3)))
    local x1 = math.max(x0, math.min(W - 1, math.ceil(u1 * W - 1e-3) - 1))
    local y0 = math.max(0, math.min(H - 1, math.floor(v0 * H + 1e-3)))
    local y1 = math.max(y0, math.min(H - 1, math.ceil(v1 * H - 1e-3) - 1))
    local top, bottom = visibleRows(data, name == "cutoutKeyed", x0, y0, x1, y1)
    if top == false then return false end
    if not vertical then return nil end
    -- world heights of the visible rows' outer edges along the card (y is
    -- linear in v)
    local p, q, best = nil, nil, 0
    for _, pr in ipairs({ { a, b }, { a, c }, { b, c } }) do
      local d = math.abs(pr[1][5] - pr[2][5])
      if d > best then best, p, q = d, pr[1], pr[2] end
    end
    if not p or best < 1e-6 then return nil end
    local ylo, yhi = math.min(a[2], b[2], c[2]), math.max(a[2], b[2], c[2])
    local function yAt(v)
      local y = p[2] + (v - p[5]) * (q[2] - p[2]) / (q[5] - p[5])
      return math.max(ylo, math.min(yhi, y))
    end
    local y1v, y2v = yAt(top / H), yAt((bottom + 1) / H)
    return math.max(y1v, y2v), math.min(y1v, y2v)
  end
end

-- Lab 55 seam: the ONE place a record's shadow mask is produced (a live
-- build's inline mask and a deferred mask job both come here; a precache
-- would hook in here). Writes rec.shadow / shadowData / shadowXf /
-- shadowKind (+ solarField / solarBucket for sun records) and pools.
function Scene:_mask(rec, geom, input)
  local t1 = now()
  local want
  if input.isBorder then
    -- only ring texels are ever sampled by border geometry
    local cellAt = input.cellAt
    want = function(cx, cz) return cellAt(cx, cz) ~= nil end
  end
  local okU, underData, overData = pcall(self._atlasData, self, input.pair) -- Lab 59 (was pairAtlases)
  local alpha = okU and Scene.alphaFn(underData, overData) or nil
  local hidden, capped = 0, 0
  if alpha then
    local inner = alpha
    alpha = function(...)
      local r = inner(...)
      if r == false then hidden = hidden + 1 elseif r then capped = capped + 1 end
      return r
    end
  end
  local opts = {
    want = want, rowsPerYield = Scene.SHADOW_ROWS, yield = yieldPoint, alpha = alpha,
  }
  local okS, mask, maxHeight, field
  if sunless(input) then
    okS, mask = pcall(Light.contactMask, geom, input.width, input.height, opts)
    rec.shadowKind = "contact"
  elseif Solar.mode() == "fixed" then
    -- Lab 55 SUN SHADOWS "fixed": the displayed mask, marched once in
    -- Solar.FIXED and tagged with its bucket; no height field is retained
    -- (Solar never re-marches it), so the record is complete as built.
    opts.direction = Solar.FIXED
    opts.ownData = function(d) rec.solarInitialData=d end
    okS, mask, maxHeight = pcall(Light.shadowMask, geom, input.width, input.height, opts)
    if not okS and rec.solarInitialData then rec.solarInitialData:release();rec.solarInitialData=nil end
    rec.solarWant = want
    rec.solarBucket = (okS and mask) and Solar.FIXED.bucket or nil
    rec.shadowKind = "sun"
  else
    opts.retain = Solar.reserve(self,rec,input.width*input.height*Light.RES*Light.RES*16)
    opts.ownField = function(f) rec.solarField=f end
    opts.ownData = function(d) rec.solarInitialData=d end
    -- Lab 55 (buildSlice): the default-direction march is never displayed
    -- for a sun record (drawLayer/shadowAt wait for Solar.pump's re-march
    -- from the field), so build only the field and the pools channel.
    if sliceOn() then opts.fieldOnly = true end
    okS, mask, maxHeight, field = pcall(Light.shadowMask, geom, input.width, input.height, opts)
    if not okS then
      if rec.solarField then rec.solarField:release() end
      if rec.solarInitialData then rec.solarInitialData:release();rec.solarInitialData=nil end
      Solar.unreserve(self,rec)
    end
    rec.solarField, rec.solarWant = field, want
    rec.solarFieldAttempted = true
    rec.shadowKind = "sun"
  end
  if okS and mask then rec.shadowRes = Light.RES end
  -- worker "atmos" (GW-P4, DESIGN.md 4.7): bake warm door-front ground
  -- pools into the mask's free B channel, static per map. Never on indoor/
  -- cave maps (contactMask has no sun-facing "door front" concept).
  if okS and mask and not sunless(input) then
    local okP, grid, gw, gh = pcall(LightPools.bake, geom, input, MB, { want = want })
    if okP and grid then LightPools.writeIntoMask(mask, grid, gw, gh) end
  end
  rec.shadowAlpha = alpha and { hidden = hidden, capped = capped } or false
  if okS and mask then
    local okI, img = pcall(love.graphics.newImage, mask)
    if okI and img then
      rec.solarInitialImage=img -- owned before any throwing filter/wrap operation
      img:setFilter("linear", "linear")
      pcall(img.setWrap, img, "clamp", "clamp")
      rec.shadow = img
      rec.solarInitialImage=nil
      rec.shadowData = mask
      rec.solarInitialData=nil -- ownership transferred to committed shadowData
      rec.shadowXf = { 1 / input.width, 1 / input.height, 0, 0 }
    end
  elseif not okS then
    self.log("shadow mask failed for " .. tostring(rec.key) .. ": " .. tostring(mask))
  end
  rec.shadowMs = (now() - t1) * 1000
end

-- Tour review R2: per 4x4-cell block, how many cells exist and how many are
-- water (deep/surfable behaviour, the water collision, or shallow water at
-- elevation 1 -- the mesher's own tests); the most common water mid and its
-- atlas texel slot, and the median water surface height (geom.heightAt).
Scene.WATER_BLOCK = 4
function Scene.waterSummary(input, geom)
  local w, h, B = input.width, input.height, Scene.WATER_BLOCK
  local cellAt = input.cellAt
  local blocks, total, waterCells = {}, 0, 0
  local mids, heights = {}, {}
  local heightAt = type(geom) == "table" and type(geom.heightAt) == "function" and geom.heightAt or nil
  for bz = 0, h - 1, B do
    for bx = 0, w - 1, B do
      local n, nw = 0, 0
      for z = bz, math.min(h, bz + B) - 1 do
        for x = bx, math.min(w, bx + B) - 1 do
          local c = cellAt(x, z)
          if c then
            n = n + 1
            local beh = c.behavior
            local wet = (beh ~= nil and MB.WATER_DEEP[beh]) or c.collision == MB.COLL_WATER
              or (beh ~= nil and MB.WATER_SHALLOW[beh] and c.elevation == 1)
            if wet then
              nw = nw + 1
              mids[c.mid] = (mids[c.mid] or 0) + 1
              if heightAt then
                local okH, y = pcall(heightAt, x, z)
                if okH and type(y) == "number" then heights[#heights + 1] = y end
              end
            end
          end
        end
      end
      if n > 0 then
        local cw, ch = math.min(B, w - bx), math.min(B, h - bz)
        blocks[#blocks + 1] = bx + cw / 2
        blocks[#blocks + 1] = bz + ch / 2
        blocks[#blocks + 1] = n
        blocks[#blocks + 1] = nw
        total, waterCells = total + n, waterCells + nw
      end
    end
  end
  local seaMid, best = nil, 0
  for mid, k in pairs(mids) do
    if k > best or (k == best and seaMid and mid < seaMid) then seaMid, best = mid, k end
  end
  local seaY
  if #heights > 0 then
    table.sort(heights)
    seaY = heights[math.floor((#heights + 1) / 2)]
  end
  local seaPx
  local atlas = input.atlas
  if seaMid and atlas and atlas.underRect and atlas.w and atlas.h then
    local u0, v0 = atlas.underRect(seaMid)
    if u0 then seaPx = { math.floor(u0 * atlas.w + 0.5), math.floor(v0 * atlas.h + 0.5) } end
  end
  return { blocks = blocks, total = total, waterCells = waterCells, seaMid = seaMid,
           seaY = seaY, seaPx = seaPx }
end

function Scene:_build(key, input)
  local solarBuild = Solar.available(self) and not sunless(input)
  local t0 = now()
  -- Lab 57 SIGNS: sign textures are prepared HERE, in the build coroutine and before the mesher, which drops
  -- the native front of exactly the signs whose texture exists (input.signLabelsReady). A temporary owner in
  -- scene.inflight lets a cancelled / failed build release them (Scene:_releaseInflight).
  local signOwner, signState
  if SignRuntime and input.signCompat and input.signLabels then
    signOwner = { buildOwner = self, buildCoroutine = coroutine.running() }
    self.inflight[signOwner] = true
    signState = SignRuntime.prepare(input, yieldPoint, signOwner)
  end
  self._pcPainted = false
  local pcCtx = input.kind~="cave" and self:_pcBegin(key, input, signState) or nil -- accepted cave resources are never restored from older persistent geometry -- Lab 57: nil when the world cache is off / bypassed
  if pcCtx and pcCtx.rec then
    local hit = pcCtx.rec
    if signOwner then -- the cache load uploaded the sign faces: the hit record owns the prepared sign resources
      signOwner.signRuntime = nil
      self.inflight[signOwner] = nil; signOwner.buildOwner = nil
      if not self.retroGrass then self.inflight[hit] = true; hit.buildOwner = self; hit.buildCoroutine = coroutine.running() end
    end
    return hit
  end
  local hostT = self._pcHostT
  if signOwner and hostT and hostT.signConsumed then -- a hit failed after using the sign state: prepare it again for the live build
    hostT.signConsumed = false
    signState = SignRuntime.prepare(input, yieldPoint, signOwner)
  end
  local geom, mesherName, err = self.mesher(input)
  if not geom then
    if signOwner then releaseRecord(signOwner) end
    return nil, err or "mesher returned nothing"
  end
  -- Own a compiled atlas before the first cancellable post-mesher yield.
  local caveOwner
  if geom.compiledCaveImage then
    caveOwner={compiledCaveImage=geom.compiledCaveImage,buildOwner=self,buildCoroutine=coroutine.running()}
    self.inflight[caveOwner]=true
  end
  local tMesh = (now() - t0) * 1000
  yieldPoint()
  local atlas = input.atlas
  local rec = {
    key = key, pair = input.pair, w = input.width, h = input.height,
    originX = input.originX or 0, originY = input.originY or 0,
    layoutVersion = input.layoutVersion, mesher = mesherName, sig = input.sig,
    isBorder = input.isBorder or nil,
  }
  rec.compiledCaveImage=geom.compiledCaveImage
  rec.compiledCaveQuery=geom.compiledCaveQuery
  rec.compiledCaveAnimation=geom.compiledCaveAnimation
  if caveOwner then
    caveOwner.compiledCaveImage=nil
    self.inflight[caveOwner]=nil;caveOwner.buildOwner=nil
    self.inflight[rec]=true;rec.buildOwner=self;rec.buildCoroutine=coroutine.running()
  end
  rec.healerFR = geom.roomShell and geom.roomShell.healerFR or nil
  if signOwner then -- the record now owns the sign resources
    rec.signRuntime, signOwner.signRuntime = signState, nil
    self.inflight[signOwner] = nil; signOwner.buildOwner = nil
    if not self.retroGrass then self.inflight[rec] = true; rec.buildOwner = self; rec.buildCoroutine = coroutine.running() end
  end
  if pcCtx then rec.pcInfo = pcCtx end -- Lab 57: what the record will not keep (bytes, glass lists, key)
  -- worker "atmos" (coordinator review round 2, w3\CONTRACT_V2.md V2.8):
  -- ground-contact AO, opaque and cutoutUnder only (over/keyed have none in
  -- W3's contract). rec.aoOpaque/aoUnder tell drawLayer whether to send
  -- Shaders.ao(shader, true) for this rec's chunks (a rec-level flag, not
  -- per-chunk: AO is baked for the whole list or not at all in practice).
  if self.retroGrass then self.inflight[rec]=true;rec.buildOwner=self;rec.buildCoroutine=coroutine.running() end
  if geom.shrubCards then self.inflight[rec]=true;rec.buildOwner=self;rec.buildCoroutine=coroutine.running();Shrubs.upload(rec,geom.shrubCards,Shaders)end
  local ao = geom.ao
  rec.aoOpaque = type(ao) == "table" and type(ao.opaque) == "table" and #ao.opaque > 0
  rec.aoUnder = type(ao) == "table" and type(ao.cutoutUnder) == "table" and #ao.cutoutUnder > 0
  -- Window glow gate (see windowFlagsFor/glassTexels above): per-triangle
  -- flags for opaque, cutoutUnder and cutoutOver (over = window decals such
  -- as Oak's Lab's round panes, lifted 0.004 off the wall plane, inside
  -- EMIT_EPS_Z); keyed (fences/grass/signs) never. nil on any map with no
  -- buildingInfo windows (every interior, every block), so chunked()
  -- attaches nothing and the shader's missing-attribute default (0.0) means
  -- no glow -- no rec-level on/off flag needed, unlike rec.aoOpaque/aoUnder.
  local buildingInfo = geom.stats and geom.stats.buildingInfo
  local wins = windowList(buildingInfo)
  local hitsOpaque, hitsUnder, hitsOver = {}, {}, {}
  local sliceEvery = sliceOn() and Scene.SLICE_TRIS or nil -- Lab 59: window flags are checkpointed too (output-neutral)
  local emitOpaqueList = wins and windowFlagsFor(geom.opaque, nil, hitsOpaque, wins, sliceEvery) or nil
  local e1, e2, e3
  rec.opaque, e1 = chunked(geom.opaque, geom.compiledCaveImage or atlas.image, Scene.CHUNK, rec.aoOpaque and ao.opaque or nil, emitOpaqueList,rec.buildOwner and rec,"opaque")
  if rec.opaque then
    local emitUnderList = wins and windowFlagsFor(geom.cutoutUnder, nil, hitsUnder, wins, sliceEvery) or nil
    rec.under, e2 = chunked(geom.cutoutUnder, atlas.image, Scene.CHUNK, rec.aoUnder and ao.cutoutUnder or nil, emitUnderList,rec.buildOwner and rec,"under")
  end
  if rec.under then
    local emitOverList = wins and windowFlagsFor(geom.cutoutOver, nil, hitsOver, wins, sliceEvery) or nil
    rec.over, e3 = chunked(geom.cutoutOver, atlas.overImage or atlas.image, Scene.CHUNK, nil, emitOverList,rec.buildOwner and rec,"over")
  end
  -- The glass texels of those window triangles, from the CPU atlas copies,
  -- into this pair's emissive masks (Emissive:addGlass; unioned across every
  -- map built with the pair). Failure here only means no glow.
  if wins and rec.over and input.pair and (#hitsOpaque + #hitsUnder + #hitsOver) > 0 then
    local okA, underData, overData = pcall(self._atlasData, self, input.pair) -- Lab 59 (was pairAtlases)
    if okA and (underData or overData) then
      local okG, glass = pcall(glassTexels, {
        { key = "under", verts = geom.opaque, hits = hitsOpaque },
        { key = "under", verts = geom.cutoutUnder, hits = hitsUnder },
        { key = "over", verts = geom.cutoutOver, hits = hitsOver },
      }, { under = underData, over = overData })
      if okG and glass then
        if glass.underW and #glass.under > 0 then
          self.emissive:addGlass(input.pair, "under", glass.underW, glass.underH, glass.under)
        end
        if glass.overW and #glass.over > 0 then
          self.emissive:addGlass(input.pair, "over", glass.overW, glass.overH, glass.over)
        end
        rec.glass = { under = #glass.under, over = #glass.over, tiles = glass.tiles,
          tris = #hitsOpaque + #hitsUnder + #hitsOver }
        if pcCtx then
          pcCtx.glassData = { underW = glass.underW, underH = glass.underH, under = glass.under,
            overW = glass.overW, overH = glass.overH, over = glass.over }
        end
      elseif not okG then
        self.log("window glass scan failed for " .. tostring(key) .. ": " .. tostring(glass))
      end
    end
  end
  local e4
  if rec.over then
    -- review R2: optional list drawn with the colour-keyed under atlas
    rec.keyed, e4 = chunked(geom.cutoutKeyed, atlas.image, Scene.CHUNK,nil,nil,rec.buildOwner and rec,"keyed")
  end
  if not (rec.opaque and rec.under and rec.over and rec.keyed) then
    releaseRecord(rec)
    return nil, "mesh upload failed: " .. tostring(e1 or e2 or e3 or e4)
  end
  if signState or (geom.signFaces and #geom.signFaces > 0) then -- Lab 57 SIGNS: one static quad per emitted face
    local okU, signErr = false, "sign runtime missing"
    if SignRuntime then okU, signErr = SignRuntime.upload(signState, geom.signFaces, Shaders.FORMAT) end
    if not okU then
      releaseRecord(rec)
      -- A failed secondary upload must never leave a hole where a native front was removed: rebuild native.
      local labels = input.signLabels; input.signLabels = {}
      local native, nativeErr = self:_build(key, input); input.signLabels = labels
      return native, nativeErr or signErr
    end
  end
  -- interiors-team (S1, contract V2.14): the room shell, never a reason to
  -- fail the record
  local rs = geom.roomShell
  rec.openAir = (type(rs) == "table" and rs.openAir == true and not input.isBorder) or nil -- (repair2, V2: the sky)
  if type(rs) == "table" and not rs.debugInlined and not input.isBorder
      and type(rs.verts) == "table" and #rs.verts >= 3 and type(rs.groups) == "table" then
    local okS, sh, errS = pcall(shellChunks, rs, atlas.image, Scene.SHELL_CHUNK or Scene.CHUNK,rec.buildOwner and rec) -- (repair2: SHELL_CHUNK)
    if okS and sh then
      rec.shell = sh
      rec.shellTris = math.floor(#rs.verts / 3)
      rec.shellInfo = { groups = rs.groups, ceilY = rs.ceilY, W = rs.W, H = rs.H, openAir = rs.openAir, vis = {} }
    else
      self.log("room shell not drawn for " .. tostring(key) .. ": " .. tostring(okS and errS or sh))
    end
  end
  rec.tris = math.floor((#(geom.opaque or {}) + #(geom.cutoutUnder or {})
    + #(geom.cutoutOver or {}) + #(geom.cutoutKeyed or {})) / 3)
  if rec.shrubCards then rec.tris=rec.tris+#rec.shrubCards*4 end
  if signState then rec.tris = rec.tris + (signState.tris or 0) end -- Lab 57 SIGNS
  if pcCtx and signState then pcCtx.signFaces = geom.signFaces or {} end -- Lab 57 WORLD CACHE: the faces a hit re-uploads
  if not input.isBorder then
    -- review R7M item 16: the mesher's heightAt answers every cell; derive
    -- heights from the triangles only for meshers without it (no geom is
    -- kept alive for a lazy fallback)
    if type(geom.heightAt) == "function" then
      rec.heightFn = geom.heightAt
      rec.supportRamps = geom.supportRamps
    else
      rec.heights = deriveHeights(geom, input.width, input.height)
    end
    -- W6 r2 (battle cutaway, lib/battle/BattleOccluders.lua): what stands on
    -- this map, map-local cells; plain tables the mesher already built
    rec.occluders = { trees = geom.treeOccluders,
      buildings = geom.stats and geom.stats.buildingInfo or nil,
      blocks = geom.stats and geom.stats.blockInfo or nil }
  end
  -- tour review R2: where the water is, for the horizon band and sea plane
  if not sunless(input) then
    local okW, water = pcall(Scene.waterSummary, input, geom)
    if okW then rec.water = water end
  end
  rec.meshMs = tMesh
  rec.shadowMs = 0
  -- Lab 55: "now" = Lab 52 (mask inline); far maps / border rings under
  -- FAR SHADOWS and every outdoor map under SUN SHADOWS "off" take the
  -- pools-only branch below instead ("skip"), or that branch now and their
  -- mask later from a low-priority job ("defer", see Scene:_commit).
  local plan = self.shadows and self:_maskPlan(key, input) or nil
  if plan == "defer" and self:_heldTris() + (rec.tris or 0) > Scene.DEFER_HOLD_TRIS then
    plan = "deferDropped" -- too much geometry already held: this one stays maskless
  end
  -- sun shadow mask (render/Light.lua); skipped while shadows are off
  if self.shadows and plan == "now" then
    self:_mask(rec, geom, input)
  elseif not sunless(input) then
    if plan then rec.maskPlan = plan end
    if plan == "defer" then rec._deferGeom, rec._deferInput = geom, input end
    -- worker "atmos" (GW-P4, DESIGN.md 3.4 "Pools without shadows"):
    -- shadows are off, but an outdoor map can still show warm door-front
    -- pools through the shader's pools-only branch (u_poolOn, no shadow
    -- maths).
    local okP, poolsData, gw, gh = pcall(LightPools.buildStandaloneMask, geom, input, MB, {})
    if okP and poolsData then
      local okI, img = pcall(love.graphics.newImage, poolsData)
      if okI and img then
        img:setFilter("linear", "linear")
        pcall(img.setWrap, img, "clamp", "clamp")
        rec.poolsOnly = img
        rec.shadowXf = { 1 / input.width, 1 / input.height, 0, 0 }
        if pcCtx then
          pcCtx.poolsBytes = poolsData:getString()
          pcCtx.poolsW, pcCtx.poolsH = poolsData:getDimensions()
        end
      end
    end
  end
  if pcCtx then self:_pcAfterMask(pcCtx, rec, input) end -- Lab 57
  if self.retroGrass then
    local tGrass=now()
    self.retroGrass:build(rec,geom.retroGrassCells or {},yieldPoint)
    rec.retroGrassCells=geom.retroGrassCells or {};rec.baseTris=rec.tris;rec.grassTris=0
    for _,ch in ipairs(rec.retroChunks or {})do rec.grassTris=rec.grassTris+ch.tris end
    rec.tris=rec.baseTris+rec.grassTris;rec.grassBuildMs=(now()-tGrass)*1000
  end
  if pcCtx then pcCtx.voxelTrees=geom.frVoxelTrees end -- CPU-only capture input; no GPU records
  if self.voxelTrees and geom.frVoxelTrees then
    local treeTris=self.voxelTrees:build(rec,geom.frVoxelTrees)
    rec.tris=rec.tris+treeTris
    if pcCtx then pcCtx.voxelTreeTris=treeTris end
  end
  if self.lighting and not sunless(input) and not input.isBorder then
    rec.lightRecord=LightingBuild.build(Scene,self,geom,input,key,yieldPoint,function(light)
      rec.lightRecord=light;self.inflight[rec]=true;rec.buildOwner=self;rec.buildCoroutine=coroutine.running()
    end)
    rec.tris=rec.tris+rec.lightRecord.vertexCount/3
  end
  rec.buildMs = (now() - t0) * 1000
  if solarBuild then Solar.initialBuild(rec.buildMs) end -- elapsed including coroutine waits, not CPU benchmark
  rec.used = now()
  local sa = rec.shadowAlpha
  self.log(("built %s (%s) %dx%d tris=%d in %.1f ms (mesher %.1f, %s mask %.1f%s)"):format(
    tostring(key), tostring(mesherName), rec.w, rec.h, rec.tris, rec.buildMs,
    rec.meshMs, tostring(rec.shadowKind or "shadow"), rec.shadowMs,
    sa and ("; cutout casters hidden %d, capped %d"):format(sa.hidden, sa.capped)
      or (sa == false and "; no atlas pixels" or "")))
  if pcCtx then self:_pcFinish(pcCtx, rec, input, plan) end -- Lab 57: queue a clean record for the idle-frame write
  return rec
end

-- ---------------------------------------------------------------- Lab 57 WORLD CACHE seams
-- (lib/perf/FrPrecache*.lua). Reached only when the cache is ON and usable;
-- with WORLD CACHE OFF (or no mod.cache) _build runs exactly the Lab 56
-- statements. A hit returns a finished record from the disk cache; a miss
-- builds live and, after a clean build, queues the record for an idle-frame
-- write (PC:pump, from Scene:pump).
local function pcLive(self)
  local pc = self.precache
  if PCmod and pc and BuildPerf.worldCache ~= false and pc:enabled() then return pc end
  return nil
end

-- Lab 59: the atlas copies glass and shadow alpha are read from: unpainted while the world cache is live (the record
-- must not depend on the time of day), the live painted ones otherwise (WORLD CACHE OFF is exactly Lab 56).
function Scene:_atlasData(pair)
  local src = self.source
  if src and src.paintFree and src.paintFree() then return cleanAtlases(self, pair) end -- Lab 59 v4: VRITK gate, cache on OR off
  return pairAtlases(pair)
end

function Scene:_pcHost()
  local h = self._pcHostT
  if not h then
    h = { yield = yieldPoint, releaseRecord = releaseRecord, now = now }
    self._pcHostT = h
  end
  return h
end

-- Settings that change the bytes of a record (the cheap part of its key).
function Scene:_pcSettings(input, plan)
  local sl = sunless(input)
  local sun, slice = "-", "-"
  if not sl then
    sun = Solar.mode()
    slice = sun == "moving" and (sliceOn() and "1" or "0") or "-"
  end
  return ("sh=%d;sun=%s;sl=%s;rg=%d;plan=%s;sg=%d"):format(self.shadows and 1 or 0, sun, slice,
    self.retroGrass and 1 or 0, tostring(plan), input.signCompat and 1 or 0) -- Lab 57 SIGNS: the sign gate changes sign geometry
    .. ";sd=" .. self:_pcSignDigest(input) .. ";vt=" .. (VoxelTrees.active() and "1" or "0")
end

-- Top of _build. -> nil (cache off / bypassed) | ctx; ctx.rec is a finished record on a hit.
-- Lab 57 SIGNS: the sign inputs (labels from the map events / connections and which textures could be made) are
-- part of the key; "-" when the sign gate is off or the map has no labels.
function Scene:_pcSignDigest(input)
  if not (input.signCompat and input.signLabels and next(input.signLabels)) then return "-" end
  local d = input._pcSignDigest
  if d then return d end
  d = self.precache and self.precache:valueDigest({ labels = input.signLabels, ready = input.signLabelsReady or {} })
  d = d and d:sub(1, 16) or "unhashable"
  input._pcSignDigest = d
  return d
end

function Scene:_pcBegin(key, input, signState)
  local pc = pcLive(self)
  if not pc then return nil end
  local treeGeneration=VoxelTrees.generation()
  local voxelTreeMode=VoxelTrees.active()==true
  local t0 = now()
  local ok, ctx = pcall(function()
    if type(input.grid) ~= "table" then pc:bypass("no grid"); return nil end
    if input.signCompat and input._pcSignDigest == "unhashable" then pc:bypass("sign labels not plain data"); return nil end
    local plan = self.shadows and self:_maskPlan(key, input) or nil
    if plan ~= nil and plan ~= "now" and plan ~= "skip" then pc:bypass("plan " .. tostring(plan)); return nil end
    local settings = self:_pcSettings(input, plan)
    local base, edgeD, paint = pc:baseKey(key, input, yieldPoint)
    if not base then pc:bypass(tostring(edgeD or "key")); return nil end
    local rk, full = pc:recordKey(base, settings)
    local c = { rk = rk, full = full, settings = settings, plan = plan, edgeD = edgeD, paint = paint, treeGeneration=treeGeneration, voxelTreeMode=voxelTreeMode,
      busy = (self.isBusy and self.isBusy()) and true or false, retro = self.retroGrass ~= nil,
      maskPlan = (plan ~= nil and plan ~= "now") and plan or nil,
      sunMode = (not sunless(input)) and Solar.mode() or nil }
    local host = self:_pcHost()
    host.signState, host.signConsumed = signState, false
    host.voxelTreeMode=voxelTreeMode
    if SignRuntime then host.signUpload, host.signRelease = SignRuntime.upload, SignRuntime.release end
    local rec = pc:tryLoad(self, rk, full, input, plan, host)
    host.signState = nil
    if treeGeneration~=VoxelTrees.generation() or voxelTreeMode~=(VoxelTrees.active()==true) then
      if rec then releaseRecord(rec) end
      pc:bypass("tree mode changed while loading")
      return nil
    end
    if rec then
      rec.buildMs = (now() - t0) * 1000
      rec.used = now()
      self.log(("built %s (%s) %dx%d tris=%d in %.1f ms (world cache hit, %s mask)"):format(
        tostring(key), tostring(rec.mesher), rec.w, rec.h, rec.tris, rec.buildMs,
        tostring(rec.shadowKind or "shadow")))
      c.rec = rec
    end
    return c
  end)
  if not ok then
    pc:bypass("error")
    self.log("world cache skipped for " .. tostring(key) .. ": " .. tostring(ctx))
    return nil
  end
  return ctx
end

-- After the mask section of a live build: copy what the record will not keep.
function Scene:_pcAfterMask(ctx, rec, input)
  local sd = rec.shadowData
  if rec.shadow and sd then
    ctx.maskBytes = sd:getString()
    ctx.maskW, ctx.maskH = sd:getDimensions()
  end
  local sa = rec.shadowAlpha
  if sa == false then ctx.alphaState = 1
  elseif type(sa) == "table" then ctx.alphaState, ctx.alphaHidden, ctx.alphaCapped = 2, sa.hidden, sa.capped
  else ctx.alphaState = 0 end
end

-- End of a live build: is it clean enough to save? Queue it, or count why not.
function Scene:_pcFinish(ctx, rec, input, plan)
  local pc = self.precache
  local PCM = PCmod.M
  local why
  if ctx.treeGeneration~=VoxelTrees.generation() or ctx.voxelTreeMode~=(VoxelTrees.active()==true) then why = "tree mode changed"
  elseif not ctx.voxelTreeMode and (rec.frVoxelTrees or ctx.voxelTrees) then why = "unexpected voxel trees"
  elseif rec.mesher ~= "FrlgMesher" then why = "mesher " .. tostring(rec.mesher)
  elseif rec.healerFR then pc:bypass("healer rig"); rec.pcInfo = nil; return
  elseif plan ~= ctx.plan then why = "plan changed"
  elseif self:_pcSettings(input, plan) ~= ctx.settings then why = "settings changed"
  elseif self._pcPainted then why = "painted atlas without pre-paint pixels"
  elseif ctx.busy or (self.isBusy and self.isBusy()) then why = "overrides busy"
  elseif pc:paintToken(input.pair) ~= ctx.paint then why = "atlas repainted"
  elseif (function() pc:samplePaint(true); return pc:pairTainted(input.pair) end)() then
    why = "atlas paint changed this session"
  elseif (input.outsideMidAt or input.edgeWaterBank) and pc:edgeDigest(input, yieldPoint) ~= ctx.edgeD then
    why = "neighbour changed"
  end
  if not why then
    local sl = sunless(input)
    if rec.shadow and ctx.maskBytes then
      if sl then ctx.maskKind = PCM.CONTACT
      elseif ctx.sunMode == "fixed" then ctx.maskKind = PCM.FIXED
      elseif ctx.sunMode == "moving" then
        if rec.solarField then ctx.maskKind = PCM.MOVING else why = "no height field" end
      else why = "sun mode " .. tostring(ctx.sunMode) end
    elseif rec.poolsOnly and ctx.poolsBytes then
      ctx.maskKind, ctx.maskBytes, ctx.maskW, ctx.maskH = PCM.POOLS, ctx.poolsBytes, ctx.poolsW, ctx.poolsH
    elseif plan == "now" then
      why = "mask missing"
    else
      ctx.maskBytes, ctx.maskKind = nil, PCM.NONE
    end
  end
  ctx.poolsBytes = nil
  if why then
    pc:unclean(why) -- Lab 59: counts like the Lab 57 line it replaces (stats.unclean + 1) and remembers why
    rec.pcInfo = nil
    return
  end
  pc:submit(self, rec)
end

function Scene:_buildJob(job, game)
  local input, err
  if job.border then
    input, err = self.source:borderInput(job.rootId, job.rootDef, Scene.BORDER, job.covered)
    if not input then
      local old = self.borders[job.key]
      self.borders[job.key] = { key = job.key, empty = true, used = now(), sig = job.sig }
      if old and old ~= self.borders[job.key] then releaseRecord(old) end
      return true
    end
    input.sig = job.sig
  else
    local maps = game and game.data and game.data.maps
    local def = maps and maps[job.id]
    input, err = self.source:mapInput(job.id, def)
    if not input then return nil, err end
  end
  yieldPoint()
  local rec, berr = self:_build(job.key, input)
  if not rec then return nil, berr end
  self:_commit(job, rec)
  return true
end

-- Lab 55 seam: the ONE place a finished record enters the cache (a precache
-- would hook in here). Same statements, same order as Lab 52's _buildJob
-- tail; then a deferred mask job (FAR SHADOWS "defer") when one is due.
function Scene:_commit(job, rec)
  local store = job.border and self.borders or self.cache
  local old = store[job.key]
  store[job.key] = rec
  if rec.buildOwner then self.inflight[rec]=nil;rec.buildOwner=nil end
  Solar.unreserve(self,rec) -- now counted in committed cache, not reservation
  if old then releaseRecord(old) end   -- only after its successor exists
  self._residentDirty = true
  local geom, input = rec._deferGeom, rec._deferInput
  rec._deferGeom, rec._deferInput = nil, nil
  if geom then
    local mj = { key = job.key, id = job.id, border = job.border, maskOnly = true, rec = rec,
      heldTris = rec.tris or 0, geom = geom, input = input }
    mj.run = function(scene) return scene:_deferredMask(mj) end
    self.queue[#self.queue + 1] = mj
  end
end

-- Triangles of geometry held by queued / running deferred mask jobs.
function Scene:_heldTris()
  local n = 0
  for _, j in ipairs(self.queue) do if j.maskOnly and j.geom then n = n + (j.heldTris or 0) end end
  local a = self.active and self.active.job
  if a and a.maskOnly and a.geom then n = n + (a.heldTris or 0) end
  return n
end

-- Release only a record's mask resources (the record itself stays).
local function releaseMask(rec)
  if rec.shadow and rec.shadow.release then pcall(rec.shadow.release, rec.shadow) end
  Solar.unreserve(rec.solarOwner, rec)
  for _, k in ipairs({ "solarInitialData", "solarInitialImage", "solarField" }) do
    local x = rec[k]
    if x and x.release then pcall(x.release, x) end
    rec[k] = nil
  end
  rec.shadow, rec.shadowData = nil, nil
end

-- FAR SHADOWS "defer": the mask of an already committed (and drawn,
-- pools-only) record, built from the geometry its build left behind.
function Scene:_deferredMask(job)
  local store = job.border and self.borders or self.cache
  local rec, geom, input = job.rec, job.geom, job.input
  job.geom, job.input = nil, nil -- the held geometry goes with this job either way
  if store[job.key] ~= rec or rec.shadow or not self.shadows or not geom then return true end
  if self:_maskPlan(job.key, input) == "skip" then return true end -- switched to off meanwhile
  yieldPoint()
  self:_mask(rec, geom, input)
  if store[job.key] ~= rec then
    releaseMask(rec) -- replaced or evicted while rastering: drop what was made
    return true
  end
  Solar.unreserve(self, rec)
  if rec.shadow then
    rec.maskPlan = nil
    if rec.poolsOnly then pcall(rec.poolsOnly.release, rec.poolsOnly); rec.poolsOnly = nil end
  end
  return true
end

-- FAR SHADOWS / SUN SHADOWS policy for one record. -> "now" (Lab 52: mask
-- inline) | "defer" | "skip". Indoor/cave contact masks are always "now".
function Scene:_maskPlan(key, input)
  if sunless(input) then return "now" end
  return self:_maskPlanFor(key, input.isBorder == true)
end
function Scene:_maskPlanFor(key, isBorder)
  if Solar.mode() == "off" then return "skip" end
  local m = farMode()
  if m == "full" then return "now" end
  if not isBorder and self:_nearMap(key) then return "now" end
  return m == "defer" and "defer" or "skip"
end

-- Near = the root, or a placed map whose rect lies within MASK_NEAR cells
-- of the root rect (its direct neighbours).
function Scene:_nearMap(key)
  if key == self.rootId then return true end
  local L = self.rootDef and self.rootDef.midLayout
  local rw, rh = L and L.width or 0, L and L.height or 0
  for _, p in ipairs(self.placed) do
    if p.key == key and not p.border then
      local pl = p.def and p.def.midLayout
      local w, h = pl and pl.width or 0, pl and pl.height or 0
      local gx = math.max(p.ox - rw, 0, -(p.ox + w))
      local gz = math.max(p.oy - rh, 0, -(p.oy + h))
      return math.max(gx, gz) <= Scene.MASK_NEAR
    end
  end
  return false
end

local function coveredRects(placed, rootId)
  local rects = {}
  for _, p in ipairs(placed) do
    if not p.border and p.key ~= rootId then
      local L = p.def and p.def.midLayout
      if L then rects[#rects + 1] = { p.ox, p.oy, p.ox + (L.width or 0), p.oy + (L.height or 0) } end
    end
  end
  table.sort(rects, function(a, b)
    if a[1] ~= b[1] then return a[1] < b[1] end
    if a[2] ~= b[2] then return a[2] < b[2] end
    if a[3] ~= b[3] then return a[3] < b[3] end
    return a[4] < b[4]
  end)
  return rects
end

local function coveredFn(rects)
  return function(x, y)
    for i = 1, #rects do
      local r = rects[i]
      if x >= r[1] and y >= r[2] and x < r[3] and y < r[4] then return true end
    end
    return false
  end
end

function Scene:_borderSig(rootDef, rects)
  local parts = { self.source.layoutVersion(rootDef and rootDef.midLayout),
    tostring(rootDef and (rootDef.pair or (rootDef.midLayout and rootDef.midLayout.pair))) }
  for _, r in ipairs(rects) do parts[#parts + 1] = table.concat(r, ",") end
  return table.concat(parts, "|")
end

function Scene:_borderJob()
  local rects = coveredRects(self.placed, self.rootId)
  local sig = self:_borderSig(self.rootDef, rects)
  return { key = tostring(self.rootId) .. "#border", border = true, rootId = self.rootId,
           rootDef = self.rootDef, covered = coveredFn(rects), sig = sig, ox = 0, oy = 0 }
end

local function queued(queue, key)
  for i, j in ipairs(queue) do if j.key == key and not j.retroShape and not j.maskOnly then return i end end
  return nil
end
local function maskQueued(queue, key)
  for _, j in ipairs(queue) do if j.key == key and j.maskOnly then return true end end
  return false
end

-- ---------------------------------------------------------------- sync

-- Placement only (cheap). Returns dx, dz when the root changed seamlessly
-- (the old root's offset inside the new world) and `rootChanged`.
function Scene:sync(game)
  local WS = self.source
  local rootId = WS.currentMapId(game)
  if not rootId then return nil end
  if rootId ~= self.rootId then
    local entries, rootDef = WS:worldEntries(game, rootId, Scene.REACH)
    if not entries then return nil end
    local shiftX, shiftZ
    for _, e in ipairs(entries) do
      if e.id == self.rootId then shiftX, shiftZ = e.ox, e.oy end
    end
    self.rootId, self.rootDef = rootId, rootDef
    self.placed = {}
    -- Lab 55: deferred mask jobs survive a root change (their records stay
    -- cached); there are none unless FAR SHADOWS is "defer"
    local keptMasks = {}
    for _, j in ipairs(self.queue) do if j.maskOnly then keptMasks[#keptMasks + 1] = j end end
    self._maskDirty = true
    self.queue = {}
    for i, e in ipairs(entries) do
      self.placed[#self.placed + 1] = { key = e.id, id = e.id, def = e.def, ox = e.ox, oy = e.oy }
      local rec = self.cache[e.id]
      local stale = rec and not rec.failed and i == 1
        and rec.layoutVersion ~= WS.layoutVersion(e.def.midLayout)
      if not rec or rec.failed or stale then
        local L = e.def.midLayout or {}
        -- a stale (but drawable) root keeps its old meshes and rebuilds last
        self.queue[#self.queue + 1] = { key = e.id, id = e.id, ox = e.ox, oy = e.oy,
          w = L.width or 0, h = L.height or 0, root = i == 1, staleRoot = stale or nil }
      end
    end
    local bjob = self:_borderJob()
    self.placed[#self.placed + 1] = { key = bjob.key, border = true, ox = 0, oy = 0 }
    local brec = self.borders[bjob.key]
    if not (brec and not brec.failed and brec.sig == bjob.sig) then
      -- right after the root (the root job, when queued, is first)
      local at = (self.queue[1] and self.queue[1].root and not self.queue[1].staleRoot) and 2 or 1
      table.insert(self.queue, math.min(at, #self.queue + 1), bjob)
    end
    for _, j in ipairs(keptMasks) do self.queue[#self.queue + 1] = j end
    self:_evict()
    return shiftX, shiftZ, true
  end
  -- a script swapped metatiles in the root map (setmetatile, switches);
  -- skipped while an escalator / special field animation owns the overrides
  local rec = self.cache[rootId]
  local t = now()
  if rec and not rec.failed and t - self.lastRootBuild > Scene.REBUILD_MIN_GAP
      and not (self.isBusy and self.isBusy()) then
    -- Lab 58 #13 (flag "layoutpoll"): the version (a string built from every override) is read at most every
    -- LAYOUT_POLL_GAP seconds, and at once when the root record changed; a script swap is seen <= 250 ms later.
    local poll = true
    if Speed58sv and Speed58sv.on("layoutpoll") then
      local at = self._lvPollAt
      if rec == self._lvPollRec and at and t >= at and t - at < Scene.LAYOUT_POLL_GAP then
        poll = false
      else
        self._lvPollRec, self._lvPollAt = rec, t
      end
    end
    local v = poll and WS.layoutVersion(self.rootDef and self.rootDef.midLayout) or rec.layoutVersion
    if v ~= rec.layoutVersion and not queued(self.queue, rootId) then
      self.lastRootBuild = t
      local L = self.rootDef.midLayout
      table.insert(self.queue, 1, { key = rootId, id = rootId, ox = 0, oy = 0,
        w = L.width or 0, h = L.height or 0, root = true })
      local bjob = self:_borderJob()
      if not queued(self.queue, bjob.key) then table.insert(self.queue, 2, bjob) end
    end
  end
  return nil, nil, false
end

-- Nearest queued job within reach of `focus` (root cells); nil if none.
function Scene:_nextJob(focus, far)
  if #self.queue == 0 then return nil end
  local best, bestD
  local fx, fz = focus and focus.x or 0, focus and focus.z or 0
  local limit = (far or 1e9) + Scene.FAR_SLACK
  for i, j in ipairs(self.queue) do
    local d = 0
    if j.staleRoot or j.maskOnly or j.lowPri then -- Lab 55: deferred masks / look-switch rebuilds last
      d = limit
    elseif not j.root and not j.border and j.w then
      local dx = math.max(j.ox - fx, 0, fx - (j.ox + j.w))
      local dz = math.max(j.oy - fz, 0, fz - (j.oy + j.h))
      d = math.sqrt(dx * dx + dz * dz)
    elseif j.border then
      d = 0.5
    end
    if d <= limit and (bestD == nil or d < bestD) then best, bestD = i, d end
  end
  if not best then return nil end
  return table.remove(self.queue, best)
end

function Scene:_finish(job, ok, done, err, co)
  if not ok or not done then
    self:_releaseInflight(co)
    Solar.cancelReservations(self,co)
    local reason = tostring(ok and err or done)
    self.log("build failed for " .. tostring(job.key) .. ": " .. reason)
    local store = job.border and self.borders or self.cache
    local old=store[job.key]
    if old and old.solarRecoveryQueued then
      old.solarRecoveryQueued=false;old.solarRecoveryRetryAt=now()+.5
      old.solarRecoveryError=reason;Solar.recovery('Failures')
    end
    if not store[job.key] then
      store[job.key] = { key = job.key, failed = true, reason = reason, used = now(), sig = job.sig }
    end
  end
  if job.key == self.rootId then self.lastRootBuild = now() end
end

function Scene:_resume(a)
  local ok, done, err = coroutine.resume(a.co)
  if not ok or coroutine.status(a.co) == "dead" then
    self.active = nil
    self:_finish(a.job, ok, done, err, a.co)
  end
end

function Scene:_start(job, game)
  local a = { job = job }
  a.co = coroutine.create(function() if job.run then return job.run(self,game) end return self:_buildJob(job, game) end)
  self.active = a
  return a
end

-- Build a job to completion now (a new root with nothing to draw).
function Scene:_runNow(job, game)
  local a = { job = job }
  a.co = coroutine.create(function() if job.run then return job.run(self,game) end return self:_buildJob(job, game) end)
  local guard = 0
  while coroutine.status(a.co) ~= "dead" and guard < 100000 do
    guard = guard + 1
    local ok, done, err = coroutine.resume(a.co)
    if not ok or coroutine.status(a.co) == "dead" then
      self:_finish(job, ok, done, err, a.co)
      return
    end
  end
end

-- Once per frame, outside the XR frame. opts = { budgetMs, focus = {x,z},
-- far (cells) }. Returns dx, dz, rootChanged from sync.
function Scene:pump(game, opts)
  opts = opts or {}
  Solar.poll(self) -- cheap native gate even while geometry jobs consume budget
  if self.precache and PCmod then pcall(self.precache.samplePaint, self.precache) end -- Lab 57: watch the RTC atlas repaint
  local sx, sz, changed = self:sync(game)
  self:_reconcileRetroPlaced()
  -- A native clock arriving after a legacy pre-bake load needs ONE normal
  -- bounded build to capture a trustworthy height field, never one per bucket.
  -- (Lab 55: only the moving sun needs fields; fixed masks carry none.)
  if Solar.available(self) and self.shadows and Solar.mode() == "moving" then
    for _, p in ipairs(self.placed) do
      local r = p.border and self.borders[p.key] or self.cache[p.key]
      if r and r.shadowKind == "sun" and not r.solarFieldAttempted and not r.solarRecoveryQueued
        and (r.solarRecoveryTries or 0)<2 and now()>=(r.solarRecoveryRetryAt or 0) then
        r.solarRecoveryQueued = true
        r.solarRecoveryTries=(r.solarRecoveryTries or 0)+1;Solar.recovery('Queued')
        if not queued(self.queue,p.key) then
          if p.border then self.queue[#self.queue+1]=self:_borderJob()
          else self.queue[#self.queue+1]={key=p.key,id=p.id,ox=p.ox,oy=p.oy,w=r.w,h=r.h,root=p.key==self.rootId} end
        end
      end
    end
  end
  if changed then
    local rec = self.cache[self.rootId]
    if not rec and opts.deferRoot and sx == nil then -- a hard re-root only: a seamless shift (walking over a connection) is never deferred
      -- Lab 60 (main.lua sets it only while the Loading screen is on): the root job stays queued, first, and is built
      -- sliced from the next frame on, so a Loading frame is submitted BEFORE the long build (the synchronous build below
      -- blocked the frame for 0.2-1.1 s). Nothing draws a root without geometry (View:prepare answers "building").
      if not queued(self.queue, self.rootId) then
        table.insert(self.queue, 1, { key = self.rootId, id = self.rootId, root = true })
      end
      self.rootDeferrals = (self.rootDeferrals or 0) + 1
    elseif not rec or rec.failed then
      local i = queued(self.queue, self.rootId)
      local job = i and table.remove(self.queue, i)
        or { key = self.rootId, id = self.rootId, root = true }
      self:_runNow(job, game)
      self:_evict()
    end
    -- nothing else this frame: the root step and the queue pump never share one
    if self.precache and PCmod then pcall(self.precache.sampleNew, self.precache) end -- Lab 57 R1d
    return sx, sz, changed
  end
  -- Lab 55: react to FAR SHADOWS / SUN SHADOWS changes (main.lua also calls
  -- outdoorPerfChanged) and to root changes: queue the masks now wanted.
  local perfSig = farMode() .. "/" .. Solar.mode()
  if perfSig ~= self._perfSig then
    if self._perfSig ~= nil then self._maskDirty = true end
    self._perfSig = perfSig
  end
  if self._maskDirty then self:_maskUpgrade() end
  local budget = (opts.budgetMs or 6) / 1000
  local stop = now() + budget
  deadline = stop
  local guard = 0
  local ok, err = pcall(function()
    repeat
      guard = guard + 1
      local a = self.active
      if not a then
        local job = self:_nextJob(opts.focus, opts.far)
        if not job then
          Solar.pump(self, yieldPoint)
          -- Lab 57: cache writes (and deletes) run only in frames with no build job, one write per frame
          if self.precache and PCmod then pcall(self.precache.pump, self.precache, self, stop) end
          break
        end
        a = self:_start(job, game)
      end
      self:_resume(a)
    until now() >= stop or guard > 256
  end)
  deadline = nil
  if not ok then error(err, 0) end
  if sliceOn() and self._residentDirty then self:_evictBudget(opts.focus, opts.far) end -- Lab 55
  if self.precache and PCmod then pcall(self.precache.sampleNew, self.precache) end -- Lab 57 R1d: before draw
  return sx, sz, changed
end

local function evictStore(store, limit, keep)
  local list, count = {}, 0
  for key, rec in pairs(store) do
    count = count + 1
    if not keep[key] then list[#list + 1] = rec end
  end
  table.sort(list, function(a, b) return (a.used or 0) < (b.used or 0) end)
  local i = 1
  while count > limit and list[i] do
    releaseRecord(list[i])
    store[list[i].key] = nil
    count = count - 1
    i = i + 1
  end
end

function Scene:_evict()
  local keep = {}
  for _, p in ipairs(self.placed) do keep[p.key] = true end
  if self.active then keep[self.active.job.key] = true end
  evictStore(self.cache, Scene.CACHE_LIMIT, keep)
  evictStore(self.borders, Scene.BORDER_LIMIT, keep)
  self._residentDirty = true
end

-- Lab 55 BUILD SLICING: resident-geometry budget beside CACHE_LIMIT /
-- BORDER_LIMIT. Over Scene.RESIDENT_TRIS, release least-recently-used
-- records that are not the root, not drawn last frame (self.visible), not
-- being built, not the current border ring, and -- when placed -- farther
-- than far + FAR_SLACK + EVICT_SLACK cells from the focus; an evicted placed
-- map is re-queued and rebuilt once it is back within build range.
-- -> number of records evicted
function Scene:_evictBudget(focus, far)
  self._residentDirty = nil
  local total = 0
  for _, store in ipairs({ self.cache, self.borders }) do
    for _, r in pairs(store) do
      if not r.failed and not r.empty then total = total + (r.tris or 0) end
    end
  end
  self.residentTris = total
  if total <= Scene.RESIDENT_TRIS then return 0 end
  local vis = {}
  for _, r in ipairs(self.visible or {}) do vis[r] = true end
  local placedAt = {}
  for _, p in ipairs(self.placed) do placedAt[p.key] = p end
  local activeKey = self.active and self.active.job.key
  local limit = (far or 1e9) + Scene.FAR_SLACK + Scene.EVICT_SLACK
  local cand = {}
  for _, store in ipairs({ self.cache, self.borders }) do
    for key, r in pairs(store) do
      if not r.failed and not r.empty and key ~= self.rootId and not vis[r] and key ~= activeKey then
        local p = placedAt[key]
        local ok = true
        if p then
          if p.border or not focus then
            ok = false
          else
            local dx = math.max(p.ox - focus.x, 0, focus.x - (p.ox + (r.w or 0)))
            local dz = math.max(p.oy - focus.z, 0, focus.z - (p.oy + (r.h or 0)))
            ok = math.sqrt(dx * dx + dz * dz) > limit
          end
        end
        if ok then cand[#cand + 1] = { store = store, key = key, rec = r, placed = p } end
      end
    end
  end
  table.sort(cand, function(a, b) return (a.rec.used or 0) < (b.rec.used or 0) end)
  local n = 0
  for _, c in ipairs(cand) do
    if total <= Scene.RESIDENT_TRIS then break end
    releaseRecord(c.rec)
    c.store[c.key] = nil
    total = total - (c.rec.tris or 0)
    n = n + 1
    local p = c.placed
    if p and not queued(self.queue, p.key) then
      local L = p.def and p.def.midLayout
      self.queue[#self.queue + 1] = { key = p.key, id = p.id, ox = p.ox, oy = p.oy,
        w = L and L.width or 0, h = L and L.height or 0 }
    end
  end
  self.residentTris = total
  self.budgetEvictions = (self.budgetEvictions or 0) + n
  return n
end

-- Lab 55: main.lua calls this on every OutdoorPerf option change (field =
-- the OutdoorPerf field name). FAR SHADOWS / SUN SHADOWS: queue the masks
-- the new setting wants on the next pump (Scene:_maskUpgrade); existing
-- masks are kept. BUILD SLICING: re-check the resident budget.
function Scene:outdoorPerfChanged(field)
  if field == nil or field == "farMasks" or field == "sunShadows" then self._maskDirty = true end
  if field == nil or field == "buildSlice" then self._residentDirty = true end
end

-- Placed records that lack the mask the current FAR SHADOWS / SUN SHADOWS
-- setting wants get a rebuild queued, the way Scene:setShadows does
-- (geometry and mask; the old record keeps drawing until it is replaced).
-- Records built for the moving sun that carry a height field are instead
-- re-marched for the fixed sun by Solar.pump, without a rebuild.
function Scene:_maskUpgrade()
  self._maskDirty = nil
  if not self.shadows then return end
  local sunMode = Solar.mode()
  local activeKey = self.active and self.active.job.key
  for _, p in ipairs(self.placed) do
    local rec = p.border and self.borders[p.key] or self.cache[p.key]
    if rec and not rec.failed and not rec.empty and rec.shadowKind ~= "contact"
        and not queued(self.queue, p.key) and not maskQueued(self.queue, p.key) and p.key ~= activeKey then
      local want = self:_maskPlanFor(p.key, p.border == true)
      local need, low = false, false
      if rec.maskPlan and not rec.shadow then
        -- built pools-only by policy ("skip" / "defer" / "deferDropped")
        if want == "now" then need = true
        elseif want == "defer" and rec.maskPlan == "skip" then need, low = true, true end
      elseif sunMode == "fixed" and rec.shadowKind == "sun" and rec.shadow
          and rec.solarBucket ~= Solar.FIXED.bucket and not rec.solarField then
        need = true -- a moving-sun mask without a field cannot be re-marched
      end
      if need then
        local job
        if p.border then
          job = self:_borderJob()
        else
          local L = p.def and p.def.midLayout
          job = { key = p.key, id = p.id, ox = p.ox, oy = p.oy,
            w = L and L.width or 0, h = L and L.height or 0, root = p.key == self.rootId }
        end
        job.lowPri = low or nil
        self.queue[#self.queue + 1] = job
      end
    end
  end
end

-- Shadows toggled at runtime: remember it, and when they come back on,
-- queue rebuilds for placed maps that were built without a mask.
function Scene:setShadows(on)
  on = on ~= false
  if on == self.shadows then return end
  self.shadows = on
  if not on then return end
  for _, p in ipairs(self.placed) do
    local rec = p.border and self.borders[p.key] or self.cache[p.key]
    if rec and not rec.failed and not rec.empty and not rec.shadow
        and not queued(self.queue, p.key) then
      if p.border then
        self.queue[#self.queue + 1] = self:_borderJob()
      else
        local L = p.def and p.def.midLayout
        self.queue[#self.queue + 1] = { key = p.key, id = p.id, ox = p.ox, oy = p.oy,
          w = L and L.width or 0, h = L and L.height or 0, root = p.key == self.rootId }
      end
    end
  end
end

function Scene:setVoxelTrees(on)
  if not VoxelTrees.setActive(on) then return end
  local placedKeys={}
  for _,p in ipairs(self.placed) do placedKeys[(p.border and "b:" or "m:")..p.key]=true end
  for _,store in ipairs({{self.cache,"m:"},{self.borders,"b:"}}) do
    for key,rec in pairs(store[1]) do
      if not placedKeys[store[2]..key] then releaseRecord(rec);store[1][key]=nil end
    end
  end
  for _,p in ipairs(self.placed) do
    if not queued(self.queue,p.key) then
      if p.border then
        self.queue[#self.queue+1]=self:_borderJob()
      else
        local L=p.def and p.def.midLayout
        self.queue[#self.queue+1]={key=p.key,id=p.id,ox=p.ox,oy=p.oy,w=L and L.width or 0,h=L and L.height or 0,
          root=p.key==self.rootId}
      end
    end
  end
end

function Scene:_queueRetroShape(rec,key,border)
  if not self.retroGrass or not rec or rec.failed or rec.empty or not rec.retroGrassCells
      or rec.retroShape==self.retroGrass.shape then return false end
  local active=self.active and self.active.job
  if active and active.key==key and (active.border==true)==(border==true) then return false end
  for _,job in ipairs(self.queue)do if job.key==key and (job.border==true)==(border==true) then return false end end
  local selected,target,base=self.retroGrass.shape,rec,border and self.borders or self.cache
  self.queue[#self.queue+1]={key=key,border=border,retroShape=true,run=function(scene)
    local tmp={buildOwner=scene};scene.inflight[tmp]=true;tmp.buildCoroutine=coroutine.running()
    local t0=now();scene.retroGrass:build(tmp,target.retroGrassCells,yieldPoint,selected)
    if base[key]~=target or scene.retroGrass.shape~=selected then releaseRecord(tmp);return true end
    local tris=0;for _,ch in ipairs(tmp.retroChunks or {})do tris=tris+ch.tris end
    scene.retroGrass:adopt(target,tmp)
    scene.inflight[tmp]=nil;tmp.buildOwner=nil
    target.baseTris=target.baseTris or ((target.tris or 0)-(target.grassTris or 0))
    target.grassTris=tris;target.tris=target.baseTris+tris;target.grassBuildMs=(now()-t0)*1000
    return true
  end}
  return true
end

function Scene:_reconcileRetroPlaced()
  if not self.retroGrass then return end
  for _,p in ipairs(self.placed)do self:_queueRetroShape(p.border and self.borders[p.key] or self.cache[p.key],p.key,p.border==true) end
end

function Scene:setRetroShape(shape)
  if not self.retroGrass or not self.retroGrass:setShape(shape) then return false end
  -- Cancel only grass candidates; native map and Solar jobs keep ownership.
  local active=self.active
  if active and active.job.retroShape then
    self.active=nil;self:_releaseInflight(active.co)
  end
  local pending={};for _,job in ipairs(self.queue)do if not job.retroShape then pending[#pending+1]=job end end
  self.queue=pending
  for _,store in ipairs({self.cache,self.borders})do for key,rec in pairs(store)do
    self:_queueRetroShape(rec,key,store==self.borders)
  end end
  return true
end

-- Lab 57 LOADING SCREEN: build jobs still due near `focus` (the _nextJob distance rule), without deferred
-- masks, low-priority rebuilds and stale-root rebuilds; the running job counts. -> number
function Scene:buildsDue(focus, far)
  local fx, fz = focus and focus.x or 0, focus and focus.z or 0
  local limit = (far or 1e9) + Scene.FAR_SLACK
  local n = 0
  for _, j in ipairs(self.queue) do
    if not (j.staleRoot or j.maskOnly or j.lowPri) then
      local d = 0
      if not j.root and not j.border and j.w then
        local dx = math.max(j.ox - fx, 0, fx - (j.ox + j.w))
        local dz = math.max(j.oy - fz, 0, fz - (j.oy + j.h))
        d = math.sqrt(dx * dx + dz * dz)
      elseif j.border then
        d = 0.5
      end
      if d <= limit then n = n + 1 end
    end
  end
  local a = self.active
  if a and a.job and not a.job.maskOnly then n = n + 1 end
  return n
end

function Scene:ready()
  local rec = self.rootId and self.cache[self.rootId]
  return rec ~= nil and not rec.failed and not rec.empty
end

function Scene:rootFailure()
  local rec = self.rootId and self.cache[self.rootId]
  return rec and rec.failed and rec.reason or nil
end

function Scene:pending()
  return #self.queue + (self.active and 1 or 0)
end

function Scene:record(key)
  return self.cache[key] or self.borders[key]
end

-- The visible record whose shadow mask covers a ROOT-space point (review R5),
-- with its mask transform for root-space vertices: suv = xz * xf.xy + xf.zw.
-- Maps win over border rings (their masks see their own occluders).
function Scene:shadowCurrent(rec)
  return rec.shadowKind~="sun" or (Solar.casts(self) and rec.solarBucket==self._solarDirection.bucket)
end

-- Lab 58 (#2, switch actormemo): memo helpers for shadowAt/heightAt and the per-frame probe epoch the billboard
-- sample memo keys on. One file-level local on purpose (the chunk is close to the local-variable limit).
local ProbeMemo = {}
do
  local okSpeed, Speed58 = pcall(V.require, "perf/Speed58")
  function ProbeMemo.on() return okSpeed and Speed58.on("actormemo") == true end
  -- the mask transform {1/w, 1/h, -ox/w, -oz/h} of a record, kept on the record while w, h, ox, oz are unchanged
  function ProbeMemo.xf(rec)
    local w, h, ox, oz = rec.w, rec.h, rec.ox, rec.oz
    local xf = rec._pxf
    if xf and rec._pxW == w and rec._pxH == h and rec._pxOx == ox and rec._pxOz == oz then return xf end
    xf = { 1 / w, 1 / h, -ox / w, -oz / h }
    rec._pxf, rec._pxW, rec._pxH, rec._pxOx, rec._pxOz = xf, w, h, ox, oz
    return xf
  end
  function ProbeMemo.put(sig, k, v)
    if sig[k] ~= v then sig[k] = v; return true end
    return false
  end
end

-- Lab 58 (#2): a number that changes whenever anything shadowAt / heightAt read can have changed: the visible set
-- and each visible record's mask resources and placement, the placed list and each placed record's height source,
-- and the sun state (casting, direction bucket). Compared field by field against the last call's snapshot, which is
-- rewritten in place (no per-call allocation). Rebuilds, drops, RTC repaints (a repaint rebuilds the record), sun
-- mode changes and mask re-marches all change at least one of these (a new record, a new shadowData/shadow image,
-- a new bucket). Nothing in this tree mutates a committed shadowData in place (SolarShadows builds a new ImageData
-- and swaps it in), so identity is the version.
function Scene:probeEpoch()
  local sig = self._probeSig
  if not sig then sig = {}; self._probeSig = sig; self._probeEpochN = 0 end
  local put = ProbeMemo.put
  local ch, k = false, 1
  local vis = self.visible
  local nv = vis and #vis or 0
  ch = put(sig, k, nv) or ch
  for i = 1, nv do
    local rec = vis[i]
    ch = put(sig, k + 1, rec) or ch
    ch = put(sig, k + 2, rec.ox) or ch
    ch = put(sig, k + 3, rec.oz) or ch
    ch = put(sig, k + 4, rec.w) or ch
    ch = put(sig, k + 5, rec.h) or ch
    ch = put(sig, k + 6, rec.shadow) or ch
    ch = put(sig, k + 7, rec.shadowData) or ch
    ch = put(sig, k + 8, rec.shadowKind) or ch
    ch = put(sig, k + 9, rec.solarBucket) or ch
    ch = put(sig, k + 10, rec.isBorder) or ch
    k = k + 10
  end
  k = k + 1
  local placed = self.placed
  local np = placed and #placed or 0
  ch = put(sig, k, np) or ch
  for i = 1, np do
    local p = placed[i]
    local rec = self.cache[p.key]
    ch = put(sig, k + 1, p.key) or ch
    ch = put(sig, k + 2, p.ox) or ch
    ch = put(sig, k + 3, p.oy) or ch
    ch = put(sig, k + 4, p.border) or ch
    ch = put(sig, k + 5, rec) or ch
    if rec then
      ch = put(sig, k + 6, rec.failed) or ch
      ch = put(sig, k + 7, rec.empty) or ch
      ch = put(sig, k + 8, rec.w) or ch
      ch = put(sig, k + 9, rec.h) or ch
      ch = put(sig, k + 10, rec.heights) or ch
      ch = put(sig, k + 11, rec.heightFn) or ch
    end
    k = k + 11
  end
  k = k + 1
  ch = put(sig, k, Solar.casts(self) and true or false) or ch
  local sd = self._solarDirection
  ch = put(sig, k + 1, sd and sd.bucket or false) or ch
  if ch then self._probeEpochN = self._probeEpochN + 1 end
  return self._probeEpochN
end

function Scene:shadowAt(wx, wz)
  local best
  for _, rec in ipairs(self.visible or {}) do
    if rec.shadow and rec.ox then
      local lx, lz = wx - rec.ox, wz - rec.oz
      if lx >= 0 and lz >= 0 and lx < rec.w and lz < rec.h then
        best = rec
        if not rec.isBorder then break end
      end
    end
  end
  if not best then return nil end
  local xf
  if ProbeMemo.on() then xf = ProbeMemo.xf(best) -- Lab 58 (#2): one table per record, not one per call
  else xf = { 1 / best.w, 1 / best.h, -best.ox / best.w, -best.oz / best.h } end
  if best.shadowKind == "sun" and (not Solar.casts(self) or
    best.solarBucket ~= self._solarDirection.bucket) then return nil end
  local s, lo = 0, nil
  if best.shadowData then
    s, lo = Light.sampleMask(best.shadowData, best.w, best.h, wx - best.ox, wz - best.oz)
  end
  return best, xf, s, lo
end

-- Tour review R2: how much of each of `seg` horizon sectors around the eye
-- (sector i spans angles [i-1, i) * 2pi/seg, x = cos, z = sin -- the sky
-- cylinder's segments) is water, from the visible records' water blocks.
-- Far blocks weigh more (the horizon is what lies farthest). Returns
-- { frac[1..seg], overall, seaY, pair, px } or nil when nothing is water.
-- Lab 58 #3 (flag "seaview", Speed58): the answer only changes when the visible set or the eye cell does, so a
-- hit returns the same table with no work and no allocation. The signature is the visible records (identity,
-- origin, water summary) and the eye cell; a miss runs the unchanged function below at the CURRENT eye position,
-- so the first result in a cell is identical to the uncached one and later frames in that cell reuse it (the
-- Sky quantises the share to 1/32 anyway). Consumers (Sky.setBands, Sea.sectors/draw, View) only read it.
local seaViewCompute

function Scene:seaView(ex, ez, seg)
  if not (Speed58sv and Speed58sv.on("seaview")) then return seaViewCompute(self, ex, ez, seg) end
  local c = self._seaViewCache
  if not c then
    c = { n = -1, recs = {}, ox = {}, oz = {}, water = {}, valid = false }
    self._seaViewCache = c
  end
  local vis = self.visible
  local n = vis and #vis or 0
  local cx, cz = math.floor(ex), math.floor(ez)
  local same = c.valid and c.n == n and c.cx == cx and c.cz == cz and c.seg == seg
  if same then
    for i = 1, n do
      local rec = vis[i]
      if c.recs[i] ~= rec or c.ox[i] ~= rec.ox or c.oz[i] ~= rec.oz or c.water[i] ~= rec.water then
        same = false
        break
      end
    end
  end
  if same then return c.result end
  local result = seaViewCompute(self, ex, ez, seg)
  for i = n + 1, #c.recs do c.recs[i], c.ox[i], c.oz[i], c.water[i] = nil, nil, nil, nil end
  for i = 1, n do
    local rec = vis[i]
    c.recs[i], c.ox[i], c.oz[i], c.water[i] = rec, rec.ox, rec.oz, rec.water
  end
  c.n, c.cx, c.cz, c.seg, c.result, c.valid = n, cx, cz, seg, result, true
  return result
end

seaViewCompute = function(self, ex, ez, seg)
  local tw, ww = {}, {}
  for i = 1, seg do tw[i], ww[i] = 0, 0 end
  local T, Wt = 0, 0
  local best, bestN, seaY = nil, 0, nil
  local twoPi = 2 * math.pi
  for _, rec in ipairs(self.visible or {}) do
    local W = rec.water
    if W and W.total > 0 and rec.ox then
      local b = W.blocks
      for k = 1, #b, 4 do
        local dx, dz = rec.ox + b[k] - ex, rec.oz + b[k + 1] - ez
        local d = math.sqrt(dx * dx + dz * dz)
        if d > 2 then
          local ang = math.atan2(dz, dx)
          if ang < 0 then ang = ang + twoPi end
          local i = math.floor(ang / twoPi * seg) % seg + 1
          local n, nw = b[k + 2] * d, b[k + 3] * d
          tw[i], ww[i] = tw[i] + n, ww[i] + nw
          T, Wt = T + n, Wt + nw
        end
      end
      if W.waterCells > bestN and W.seaPx then best, bestN = rec, W.waterCells end
      if W.waterCells > 0 and W.seaY and (seaY == nil or W.seaY < seaY) then seaY = W.seaY end
    end
  end
  if Wt <= 0 then return nil end
  local overall = Wt / T
  local frac = {}
  for i = 1, seg do frac[i] = tw[i] > 0 and ww[i] / tw[i] or false end
  -- empty sectors take their nearest filled neighbour, else the overall mix
  local out = {}
  for i = 1, seg do
    local v = frac[i]
    if v == false then
      v = nil
      for r = 1, math.floor(seg / 2) do
        local a2, b2 = frac[(i - 1 - r) % seg + 1], frac[(i - 1 + r) % seg + 1]
        if a2 then v = a2 break end
        if b2 then v = b2 break end
      end
    end
    out[i] = v or overall
  end
  return { frac = out, overall = overall, seaY = seaY,
           pair = best and best.pair, px = best and best.water.seaPx }
end

-- Ground height at a ROOT-space point (cells), or nil off every placed map.
function Scene:nativeHeightAt(wx, wz)
  local cx, cz = math.floor(wx), math.floor(wz)
  for _, p in ipairs(self.placed) do
    if not p.border then
      local rec = self.cache[p.key]
      if rec and not rec.failed and not rec.empty then
        local lx, lz = cx - p.ox, cz - p.oy
        if lx >= 0 and lz >= 0 and lx < rec.w and lz < rec.h then
          if rec.heightFn then
            local ok, v = pcall(rec.heightFn, wx - p.ox, wz - p.oy)
            if ok and type(v) == "number" then return v end
          end
          local v = rec.heights and rec.heights[lz * rec.w + lx + 1]
          if v then return v end
          return nil
        end
      end
    end
  end
  return nil
end

function Scene:heightAt(x,z)return CavePlacement.heightAt(self,x,z)end
function Scene:nativeToWorld(x,z)return CavePlacement.nativeToWorld(self,x,z)end
function Scene:worldToNative(x,z)return CavePlacement.worldToNative(self,x,z)end

-- ---------------------------------------------------------------- draw

local NativeTileset, TilesetAnim
local function modules()
  if not NativeTileset then
    local okNT, NT = pcall(require, "src.core.game3.tileset_native")
    if okNT and type(NT) == "table" then NativeTileset = NT end
  end
  if not TilesetAnim then
    local okA, TA = pcall(require, "src.core.game3.tileset_anim")
    if okA and type(TA) == "table" then TilesetAnim = TA end
  end
  return NativeTileset, TilesetAnim
end

local function liveImage(pair, fallback, over)
  local NT = modules()
  local ts = NT and NT._pairs and NT._pairs[pair]
  if not ts then return fallback end
  if over then return ts.overImage or fallback end
  return ts.image or fallback
end

-- Water / flowers on a neighbour whose pair the flat view is not showing:
-- NativeTileset.get re-binds the pair's animation (TilesetAnim.bindPair marks
-- it visible and applies the current frame). Only pairs already loaded and
-- known to have animation banks.
local function animatePairs(pairs_)
  local NT, TA = modules()
  if not (NT and NT.get and NT._pairs) then return end
  for pair in pairs(pairs_) do
    local entry = TA and TA._pairs and TA._pairs[pair]
    if NT._pairs[pair] and entry ~= false and (entry == nil or type(entry) == "table") then
      pcall(NT.get, pair)
    end
  end
end

-- Once per frame, before any eye renders: pick the maps in range and bind
-- their live (and mipmapped) atlases. env = { camX, camZ, far, frame, mips }
function Scene:prepareFrame(env)
  local visible = self.visible or {}
  for i = #visible, 1, -1 do visible[i] = nil end
  local t = now()
  local pairSet = {}
  for _, p in ipairs(self.placed) do
    local rec = p.border and self.borders[p.key] or self.cache[p.key]
    if rec and not rec.failed and not rec.empty then
      local ox, oz = p.ox + (rec.originX or 0), p.oy + (rec.originY or 0)
      local mx0,mz0,mx1,mz1=0,0,rec.w,rec.h
      if rec.compiledCaveQuery then mx0,mz0,mx1,mz1=rec.compiledCaveQuery.worldBounds()end
      local dx = math.max(ox+mx0-env.camX,0,env.camX-(ox+mx1))
      local dz = math.max(oz+mz0-env.camZ,0,env.camZ-(oz+mz1))
      if dx * dx + dz * dz <= env.far * env.far then
        rec.used = t
        rec.ox, rec.oz = ox, oz
        if rec.pair then pairSet[rec.pair] = true end
        visible[#visible + 1] = rec
      end
    end
  end
  animatePairs(pairSet)
  local caveNT,caveTA=modules()
  for _,rec in ipairs(visible)do
    if rec.compiledCaveAnimation and caveNT and caveNT._pairs then
      local ok,changed,why=pcall(CaveAnimation.refresh,rec,caveNT._pairs[rec.pair],
        caveTA and caveTA._pairs and caveTA._pairs[rec.pair],env.frame)
      if (not ok or why) and not rec.compiledCaveAnimation.errorLogged then
        rec.compiledCaveAnimation.errorLogged=true
        self.log("cave native animation retained previous verified frame: "..tostring(ok and why or changed))
      end
    end
  end
  -- interiors-team (S3): room-shell visibility, once per frame from the head centre
  for _, rec in ipairs(visible) do
    if rec.shell then Scene.shellFrameSafe(rec, env.eye, env.roomMode, env.roomFocus, self.log) end -- (repair1, D2: guarded)
  end
  local frame = env.frame or 0
  for _, rec in ipairs(visible) do
    local img = rec.compiledCaveImage or liveImage(rec.pair, nil, false)
    if img then
      rec.liveTex = img
      rec.opaqueTex = not rec.compiledCaveImage and env.mips and Mip.get(img, frame) or img
      if rec.keyed and #rec.keyed > 0 then
        rec.keyedTex = Mip.keyed(img, frame, env.mips) or img
      end
    end
    local over = liveImage(rec.pair, nil, true)
    rec.liveOverTex = over -- worker "atmos" (GW-P4): raw atlas image, for Emissive mask sizing
    rec.overTex = (over and env.mips) and Mip.get(over, frame) or over
  end
  self.visible = visible
  return #visible
end

-- One eye. env = { vp, light = {sun, fill, terms, hscale}, fog = {start,
-- end, max} (metres), fogColor, shadows = bool, camX, camZ, far (cells) }
-- Chunks are culled against this eye's frustum and the far (haze) radius.
local function drawLayer(self, shader, layer, tex, env, planes, counters, sizes)
  local lastTex = nil
  for _, rec in ipairs(self.visible or {}) do
    local chunks = rec[layer]
    if chunks and #chunks > 0 then
      local sent = false
      local ox, oz = rec.ox, rec.oz
      for _, ch in ipairs(chunks) do
        local x0, z0, x1, z1 = ch.x0 + ox, ch.z0 + oz, ch.x1 + ox, ch.z1 + oz
        local dx = math.max(x0 - env.camX, 0, env.camX - x1)
        local dz = math.max(z0 - env.camZ, 0, env.camZ - z1)
        if dx * dx + dz * dz <= env.far * env.far
            and boxVisible(planes, x0, ch.y0, z0, x1, ch.y1, z1) then
          if not sent then
            sent = true
            Shaders.send(shader, "u_mvp", "row", rec.mvp)
            TreeView.send(Shaders,shader,self.treeFace,ox,oz)
            Shaders.dark(shader,env,rec)
            if env.shadows and rec.shadow and (rec.shadowKind ~= "sun" or
              (Solar.casts(self) and rec.solarBucket == self._solarDirection.bucket)) then
              if rec.shadowKind == "sun" then Solar.noteMask(env.vp) end
              Shaders.shadow(shader, rec.shadow, rec.shadowXf[1], rec.shadowXf[2])
            elseif rec.poolsOnly then
              -- worker "atmos" (GW-P4): shadows off, pools-only mask present
              Shaders.shadow(shader, rec.poolsOnly, rec.shadowXf[1], rec.shadowXf[2], nil, nil, true)
            else
              Shaders.shadow(shader, nil)
            end
            -- worker "atmos" (GW-P4, DESIGN.md 3.5; glow-precise
            -- 2026-09-28): the emissive mask for THIS layer (under atlas for
            -- opaque/under/keyed, over atlas for over) = the glass texels
            -- _build registered for this pair (Emissive:addGlass) plus
            -- whatever an emissive provider (RTC, nil-safe) painted. The
            -- shader multiplies it by v_emit (per-triangle window flags from
            -- windowFlagsFor, attached to opaque/under/over chunks), so only
            -- glass texels of registered window triangles glow: not the
            -- Cerulean Gym pool or the Viridian Mart awning (no window
            -- there), not a window's frame or the wall around it. "keyed"
            -- chunks never get VertexEmit, so they read v_emit=0.
            local emitImg
            if rec.pair then
              local liveImg = (layer == "over") and rec.liveOverTex or rec.liveTex
              local layerKey = (layer == "over") and "over" or "under"
              -- Lab 55 EYE SCRATCH: one maskFor per frame per map layer (its
              -- inputs are per frame; the second eye reuses the first's answer)
              local frameId = Perf.scratch and env.frame or nil
              local memo = frameId and rec._emitMemo
              local f = EMIT_FIELDS[layerKey]
              if memo and memo.frame == frameId and memo.provider == env.emissiveProvider
                  and memo[f[2]] == liveImg and memo[f[3]] then
                emitImg = memo[f[1]]
              else
                local okE, m = pcall(self.emissive.maskFor, self.emissive, rec.pair, layerKey, liveImg, env.emissiveProvider)
                if okE then emitImg = m end
                if frameId then
                  if not memo then memo = {}; rec._emitMemo = memo end
                  if memo.frame ~= frameId or memo.provider ~= env.emissiveProvider then
                    memo.frame, memo.provider, memo.underSet, memo.overSet = frameId, env.emissiveProvider, false, false
                  end
                  memo[f[1]], memo[f[2]], memo[f[3]] = emitImg, liveImg, true
                end
              end
            end
            Shaders.emissive(shader, emitImg)
            -- worker "atmos" (coordinator review round 2, w3\CONTRACT_V2.md
            -- V2.8): AO only exists for opaque/cutoutUnder (rec.aoOpaque/
            -- aoUnder, set in _build from geom.ao); every other layer (over,
            -- keyed) and every rec built before AO_BAKE was ever on reads
            -- false here, which is exactly "ignore VertexAO" (Shaders.ao).
            local aoOn = (layer == "opaque" and rec.aoOpaque)
              or (layer == "under" and rec.aoUnder) or false
            Shaders.ao(shader, aoOn)
          end
          local t = tex(rec)
          if t and ch.mesh:getTexture() ~= t then ch.mesh:setTexture(t) end
          if sizes and t ~= lastTex then
            lastTex = t
            Shaders.texSize(shader, t)
          end
          if ch.shellRanges then -- interiors-team (S4): a room-shell chunk, its visible groups only
            shellDrawRanges(ch, counters)
          else
            love.graphics.draw(ch.mesh)
            counters.calls = counters.calls + 1
            counters.tris = counters.tris + ch.tris
          end
        end
      end
    end
  end
end

-- Lab 57 SIGNS: the same map-level state drawLayer binds (u_mvp, then the sun / pools shadow), for the sign pass.
local function bindSignMap(self, shader, rec, env)
  Shaders.send(shader, "u_mvp", "row", rec.mvp)
            Shaders.dark(shader,env,rec)
  if env.shadows and rec.shadow and (rec.shadowKind ~= "sun" or
    (Solar.casts(self) and rec.solarBucket == self._solarDirection.bucket)) then
    if rec.shadowKind == "sun" then Solar.noteMask(env.vp) end
    Shaders.shadow(shader, rec.shadow, rec.shadowXf[1], rec.shadowXf[2])
  elseif rec.poolsOnly then
    Shaders.shadow(shader, rec.poolsOnly, rec.shadowXf[1], rec.shadowXf[2], nil, nil, true)
  else
    Shaders.shadow(shader, nil)
  end
end

-- review R3: cutout-under and over sample mipmapped mirrors too
local function opaqueTex(rec) return rec.opaqueTex or rec.liveTex end
local function underTex(rec) return rec.opaqueTex or rec.liveTex end
local function overTex(rec) return rec.overTex end
local function keyedTex(rec) return rec.keyedTex or rec.liveTex end

function Scene:draw(env)
  local g = love.graphics
  local opaque = Shaders.get("OPAQUE")
  local cutout = TreeView.shader(Shaders)
  if not (opaque and cutout) then return false, "shader unavailable" end
  local planes, counters
  if Perf.scratch then
    -- Lab 55 EYE SCRATCH: caller-owned planes, per-record MVP and counters.
    -- rec.mvp is rewritten at the start of every eye (as in Lab 52), so a
    -- reused table never carries the other eye's matrix into a draw.
    planes = planesInto(self._drawPlanes or {}, env.vp)
    self._drawPlanes = planes
    local tr = self._drawTranslate
    if not tr then tr = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }; self._drawTranslate = tr end
    for _, rec in ipairs(self.visible or {}) do
      tr[4], tr[8], tr[12] = rec.ox, 0, rec.oz
      local m = rec._mvpScratch
      if not m then m = {}; rec._mvpScratch = m end
      rec.mvp = mulInto(m, env.vp, tr)
    end
    counters = self._drawCounters
    if not counters then counters = {}; self._drawCounters = counters end
    counters.calls, counters.tris, counters.motionTris = 0, 0, nil
  else
    planes = frustumPlanes(env.vp)
    for _, rec in ipairs(self.visible or {}) do
      rec.mvp = Mat4.mul(env.vp, Mat4.translate(rec.ox, 0, rec.oz))
    end
    counters = { calls = 0, tris = 0 }
  end
  g.setShader(opaque)
  Shaders.frame(opaque, env)
  drawLayer(self, opaque, "opaque", opaqueTex, env, planes, counters, true)
  drawLayer(self, opaque, "shellDraw", opaqueTex, env, planes, counters, true) -- interiors-team (S4): the room shell
  g.setShader(cutout)
  Shaders.frame(cutout, env, 0.5)
  drawLayer(self, cutout, "under", underTex, env, planes, counters, true)
  drawLayer(self, cutout, "over", overTex, env, planes, counters, true)
  drawLayer(self, cutout, "keyed", keyedTex, env, planes, counters, true)
  if self.voxelTrees then self.voxelTrees:draw(self, env, planes, boxVisible, cutout, counters) end
  if SignRuntime then SignRuntime.draw(self, cutout, Shaders, env, planes, boxVisible, counters, bindSignMap) end -- Lab 57 SIGNS
  Shrubs.draw(self,Shaders,env,counters,bindSignMap)
  if self.retroGrass then
    local pt = self._pacerPass -- Lab 55 (G0): FramePacer.PASS.grass = 4
    local t0 = pt and pt.clock()
    self.retroGrass:draw(self,env,planes,boxVisible,opaque,cutout,counters)
    if t0 then pt.sample(4, t0) end
  end
  if self.lighting then
    for _,rec in ipairs(self.visible or{})do
      if rec.lightRecord then local calls,tris=self.lighting:draw(rec,env);counters.calls=counters.calls+calls;counters.tris=counters.tris+tris end
    end
  end
  g.setShader()
  self.frameTris = counters.tris
  self.frameCalls = counters.calls
  self.grassMotionTris=counters.motionTris or 0
  return true
end

function Scene:stats()
  local n, tris = 0, 0
  for _, store in ipairs({ self.cache, self.borders }) do
    for _, rec in pairs(store) do
      if not rec.failed and not rec.empty then
        n = n + 1
        tris = tris + (rec.tris or 0)
      end
    end
  end
  return { maps = n, tris = tris, pending = self:pending(), root = self.rootId,
           drawnTris = self.frameTris, drawCalls = self.frameCalls,
           visibleMaps = self.visible and #self.visible or 0, mip = Mip.status(),
           key = Mip.keyStatus() }
end

function Scene:release()
  if self.precache then pcall(self.precache.flush, self.precache) end -- Lab 57
  self.active=nil;self:_releaseInflight()
  if self.retroGrass then self.retroGrass:release() end
  if self.voxelTrees then self.voxelTrees:release() end
  if self.lighting then self.lighting:release() end
  Solar.invalidate(self)
  Mip.release()
  self.active = nil
  for _, store in ipairs({ self.cache, self.borders }) do
    for key, rec in pairs(store) do
      releaseRecord(rec)
      store[key] = nil
    end
  end
  if SignRuntime then SignRuntime.shutdown() end -- Lab 57 SIGNS: idle shared textures and fonts
  self.placed, self.queue, self.rootId, self.rootDef, self.visible = {}, {}, nil, nil, {}
end

return Scene
