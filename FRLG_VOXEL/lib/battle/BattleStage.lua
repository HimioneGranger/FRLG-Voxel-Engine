-- FRLG_VOXEL (W6, battle phase P-B1): where a battle is staged, and the seat.
--
-- A battle is staged in the voxel world the player is standing in. The
-- player's game cell never changes; only the camera moves to a seat. User
-- rule (2026-09-28): a FireRed battle never shows the flat 2D battle panel.
-- So staging always succeeds:
--   1. the CLOSEST appropriate spot by walking distance from the player
--      (searched up to FAR_RADIUS cells along walkable ground), trying a 3x6
--      "wide" patch first (preferred within NEAR_RADIUS), then 1xN corridor
--      shapes with the battlers along the corridor, down to 2 cells apart;
--   2. constraints are relaxed in order when nothing fits: tall grass
--      allowed, then water (battlers on the water surface), then the far
--      cells may be non-walkable but visually open (ledges, signs, small
--      props; never trees, cliffs or buildings);
--   3. last resort: a synthetic compact stage at the player's own position
--      (a flat platform, the two battlers 2 cells apart, the seat behind);
--      the renderer cuts away world geometry around it (BattleCut.lua).
-- A blocked sight line never rejects a spot: the seat variant with a clear
-- line is preferred, otherwise the renderer cuts the geometry in between.
-- Numbers follow the Crystal VR battle's design values (battle-hook
-- DESIGN.md section 2), written fresh for this mod: slots 3 cells (4.8 m)
-- apart, seat 5.65 m back, 3.1 m to the side, 1.48 m up = 6.6 m from the
-- midpoint, ~28 degrees off the arena axis.
--
-- Pure Lua: no love, no engine requires at load time. The world is read
-- through a query table `q` (BattleStage.worldQuery builds the live one):
--   q.cell(x, z)   -> { walk, water, grass, warp, low } or nil (unknown)
--   q.height(x, z) -> ground height (cells) of integer cell (x, z), or nil
--   q.sight(ax, ay, az, bx, by, bz) -> false when terrain blocks the line
-- Units: world = root map cells, X east, Z south, Y up (cells).
local V = ...
local BattleOccluders = V.require("battle/BattleOccluders")

local BattleStage = {}

-- ------------------------------------------------------------ tunables
BattleStage.METRES_PER_CELL = 1.6
BattleStage.NEAR_RADIUS = 8    -- walking distance inside which a wide patch is preferred
BattleStage.FAR_RADIUS = 24    -- walking distance searched for the closest spot
-- User question 6 (DESIGN 6): default is Crystal's rule, battles move to open
-- ground instead of standing in tall grass (relaxed only when nothing fits).
BattleStage.AVOID_TALL_GRASS = true
BattleStage.MAX_STEP = 0.6     -- max ground-height spread inside a patch (cells)
-- Patch shapes, tried in order. width = cells across the axis, length =
-- cells along it, own = axis index of the player's battler, gap = cells
-- between the two battlers.
-- cost = extra walking cells a spot with this shape must save to win over
-- a roomier shape (the separation shrinks only when it buys closeness).
BattleStage.SHAPES = {
  { name = "wide", width = 3, length = 6, own = 1, gap = 3, cost = 0 },
  { name = "narrow", width = 1, length = 4, own = 0, gap = 3, cost = 1 },
  { name = "corridor", width = 1, length = 3, own = 0, gap = 2, cost = 3 },
}
-- Constraint relaxation, in order (user rule 2026-09-28).
BattleStage.PASSES = {
  { name = "strict", grass = false, water = "surf", low = false },
  { name = "grass", grass = true, water = "surf", low = false },
  { name = "water", grass = true, water = "any", low = false },
  { name = "open-props", grass = true, water = "any", low = true },
}
-- Synthetic compact stage (last resort, always succeeds).
BattleStage.SYNTH_GAP = 2
BattleStage.SYNTH_RADIUS = 1.9     -- platform radius (cells) around the focus
-- User question 1 (DESIGN 6): "shoulder" = Crystal's over-the-shoulder seat
-- (default); "standing" = the eye stays at the player's own cell.
BattleStage.SEAT_STYLE = "shoulder"
-- Seat variants in metres from the focus (the floor midpoint between the two
-- battlers): back along the axis, side to the right of it, up above the floor.
-- The first one whose sight lines are clear wins; if none is clear the first
-- is used and the renderer cuts the geometry in between. Positive side = the
-- GBA layout (your Pokemon lower left, the foe upper right).
BattleStage.SEATS = {
  { name = "shoulder", back = 5.65, side = 3.1, up = 1.48 },
  { name = "shoulder-mirror", back = 5.65, side = -3.1, up = 1.48 },
  { name = "behind", back = 6.4, side = 0, up = 1.48 },
  { name = "close", back = 4.0, side = 0, up = 1.48 },
}
BattleStage.STANDING_EYE = 0.95    -- cells above ground (Camera.EYE_HEIGHT)
BattleStage.CARD_MID = 0.5         -- sight-line target height above ground (cells)
-- Doubles (P-B2 target, mapped now): partners sit this many cells to the
-- side of their slot.
BattleStage.PARTNER_OFFSET = 0.75

local DIRS = { up = { 0, -1 }, down = { 0, 1 }, left = { -1, 0 }, right = { 1, 0 } }
BattleStage.DIRS = DIRS
local ORDER = {
  up = { "up", "right", "left", "down" },
  down = { "down", "left", "right", "up" },
  left = { "left", "up", "down", "right" },
  right = { "right", "down", "up", "left" },
}

local sqrt, atan2, floor = math.sqrt, math.atan2, math.floor

-- Yaw (Camera.lua convention: Ry(yaw) maps LOCAL -Z to world (-sin, 0, -cos))
-- that looks along world direction (dx, dz).
function BattleStage.yawToward(dx, dz)
  return atan2(-dx, -dz)
end

-- Right-hand side for a viewer looking along (ax, az) (X east, Z south).
local function rightOf(ax, az) return -az, ax end
BattleStage.rightOf = rightOf

-- Cells of a shape placed with its own-battler cell at (ox, oz), axis (ax, az).
function BattleStage.footprint(shape, ox, oz, ax, az)
  local rx, rz = rightOf(ax, az)
  local half = (shape.width - 1) / 2
  local cells = {}
  for k = -shape.own, shape.length - 1 - shape.own do
    for s = -half, half do
      cells[#cells + 1] = { ox + ax * k + rx * s, oz + az * k + rz * s }
    end
  end
  return cells
end

local function memo(q)
  local cellCache, heightCache = {}, {}
  local m = {}
  function m.cell(x, z)
    local key = x * 65536 + z
    local v = cellCache[key]
    if v == nil then
      local ok, r = pcall(q.cell, x, z)
      v = (ok and type(r) == "table") and r or false
      cellCache[key] = v
    end
    return v or nil
  end
  function m.height(x, z)
    if not q.height then return nil end
    local key = x * 65536 + z
    local v = heightCache[key]
    if v == nil then
      local ok, r = pcall(q.height, x, z)
      v = (ok and type(r) == "number") and r or false
      heightCache[key] = v
    end
    return v or nil
  end
  m.sight = q.sight
  return m
end

-- May a battler stand on this cell in this pass?
function BattleStage.standable(pass, info, surfing, isOwn)
  if not info or info.warp then return false end
  local ok
  if pass.water == "any" then
    ok = info.walk or info.water
  elseif surfing then
    ok = info.water
  else
    ok = info.walk and not info.water
  end
  if ok and info.grass and not pass.grass and BattleStage.AVOID_TALL_GRASS then ok = false end
  if not ok and pass.low and not isOwn and info.low and not info.water then ok = true end
  return ok and true or false
end

-- Walking-distance search from the player's cell (4-neighbour BFS over
-- cells a battler could reach on foot, or on the water while surfing / in
-- the water pass). Returns an array of { x, z, d } nearest first; ties go
-- toward the facing direction.
function BattleStage.walkOrder(m, px, pz, facing, pass, surfing, radius)
  local order = { { x = px, z = pz, d = 0 } }
  local seen = { [px * 65536 + pz] = true }
  local dirs = ORDER[facing] or ORDER.down
  local head = 1
  while head <= #order do
    local c = order[head]
    head = head + 1
    if c.d < radius then
      for _, dn in ipairs(dirs) do
        local d = DIRS[dn]
        local nx, nz = c.x + d[1], c.z + d[2]
        local key = nx * 65536 + nz
        if not seen[key] then
          seen[key] = true
          local info = m.cell(nx, nz)
          local pass_ = info and not info.warp and (info.walk
            or (info.water and (surfing or pass.water == "any")))
          if pass_ then order[#order + 1] = { x = nx, z = nz, d = c.d + 1 } end
        end
      end
    end
  end
  return order
end

local function fits(m, pass, surfing, shape, ox, oz, ax, az)
  local lo, hi
  for i, c in ipairs(BattleStage.footprint(shape, ox, oz, ax, az)) do
    local isOwn = (c[1] == ox and c[2] == oz)
    if not BattleStage.standable(pass, m.cell(c[1], c[2]), surfing, isOwn) then return false end
    local h = m.height(c[1], c[2])
    if h then
      lo = (lo == nil or h < lo) and h or lo
      hi = (hi == nil or h > hi) and h or hi
    end
    local _ = i
  end
  if lo and hi and hi - lo > BattleStage.MAX_STEP then return false end
  return true
end

-- Seat for a stage core {own, foe, axis}; variant = one BattleStage.SEATS row
-- (or the "standing" style with player = {x, z}). Returns the seat table.
function BattleStage.seatFor(core, variant, player)
  local mpc = BattleStage.METRES_PER_CELL
  local f = core.focus
  local ax, az = core.axis[1], core.axis[2]
  local rx, rz = rightOf(ax, az)
  local floorY = math.max(core.own.ground or 0, core.foe.ground or 0)
  local ex, ey, ez
  if variant.name == "standing" and player then
    ex, ez = player.x, player.z
    ey = (player.ground or floorY) + BattleStage.STANDING_EYE
  else
    ex = f.x - ax * variant.back / mpc + rx * variant.side / mpc
    ez = f.z - az * variant.back / mpc + rz * variant.side / mpc
    ey = floorY + variant.up / mpc
  end
  local dx, dy, dz = f.x - ex, f.y - ey, f.z - ez
  local horiz = sqrt(dx * dx + dz * dz)
  return {
    name = variant.name, x = ex, y = ey, z = ez,
    yaw = BattleStage.yawToward(dx, dz),
    pitch = atan2(dy, math.max(horiz, 1e-6)),
    dist = sqrt(dx * dx + dy * dy + dz * dz) * mpc,   -- metres, eye to focus
  }
end

-- Stage core from the own cell, the axis and the gap.
local function core(m, ox, oz, ax, az, gap, shapeName, dirName, flatGround)
  local fx, fz = ox + ax * gap, oz + az * gap
  local og = m.height(ox, oz) or flatGround or 0
  local fg = flatGround or m.height(fx, fz) or og
  if flatGround then og = flatGround end
  local c = {
    shape = shapeName, dir = dirName, gap = gap,
    axis = { ax, az }, right = { rightOf(ax, az) },
    own = { cellX = ox, cellZ = oz, x = ox + 0.5, z = oz + 0.5, ground = og },
    foe = { cellX = fx, cellZ = fz, x = fx + 0.5, z = fz + 0.5, ground = fg },
  }
  c.focus = { x = (c.own.x + c.foe.x) / 2, y = (og + fg) / 2, z = (c.own.z + c.foe.z) / 2 }
  c.cullX, c.cullZ = c.focus.x, c.focus.z
  return c
end

local function sightClear(m, seat, c)
  if not m.sight then return true end
  local mid = BattleStage.CARD_MID
  local targets = {
    { c.own.x, c.own.ground + mid, c.own.z },
    { c.foe.x, c.foe.ground + mid, c.foe.z },
  }
  for _, t in ipairs(targets) do
    local ok, clear = pcall(m.sight, seat.x, seat.y, seat.z, t[1], t[2], t[3])
    if ok and clear == false then return false end
  end
  return true
end

local function seatVariants(style)
  if style == "standing" then return { { name = "standing" } } end
  return BattleStage.SEATS
end

-- First seat variant with a clear view; otherwise the first variant, marked
-- sightBlocked (the renderer's cutaway clears the view).
local function chooseSeat(m, c, style, player)
  local variants = seatVariants(style)
  for _, variant in ipairs(variants) do
    local seat = BattleStage.seatFor(c, variant, player)
    if sightClear(m, seat, c) then return seat, false end
  end
  return BattleStage.seatFor(c, variants[1], player), true
end

-- Direction order: the foe's side when known, otherwise the facing first,
-- then the two sides, then behind.
local function dirOrder(input)
  local first = input.facing
  if input.foeCell and input.cellX and input.cellZ then
    local dx, dz = input.foeCell.x - input.cellX, input.foeCell.z - input.cellZ
    if math.abs(dx) >= math.abs(dz) and dx ~= 0 then
      first = dx > 0 and "right" or "left"
    elseif dz ~= 0 then
      first = dz > 0 and "down" or "up"
    end
  end
  return ORDER[first] or ORDER.down
end

-- The synthetic compact stage at the player's own position: always
-- succeeds (needs only the player's cell). Flat floor at the player's
-- ground; the renderer draws a platform and cuts the world around it.
function BattleStage.synthetic(input, q)
  input = input or {}
  local m = q and memo(q) or { height = function() return nil end }
  local px, pz = floor(tonumber(input.cellX) or 0), floor(tonumber(input.cellZ) or 0)
  local d = DIRS[input.facing] or DIRS.down
  local ground = tonumber(input.ground) or m.height(px, pz) or 0
  local c = core(m, px, pz, d[1], d[2], BattleStage.SYNTH_GAP, "synthetic", input.facing or "down", ground)
  c.synthetic = true
  c.pass = "synthetic"
  c.walk = 0
  c.platform = { x = c.focus.x, z = c.focus.z, y = ground, radius = BattleStage.SYNTH_RADIUS }
  local player = { x = px + 0.5, z = pz + 0.5, ground = ground }
  c.seat, c.sightBlocked = chooseSeat(m, c, input.seatStyle or BattleStage.SEAT_STYLE, player)
  if not q then c.sightBlocked = true end
  return c
end

-- input = { cellX, cellZ (player's integer world cell), facing, ground,
--           surfing, foeCell = {x, z} (optional), seatStyle,
--           synthetic = true (skip the search), passes, shapes, near, far }
-- Returns a stage (never nil for a valid player cell) and nil, or nil and a
-- reason when the input itself is unusable.
function BattleStage.find(q, input)
  input = input or {}
  local px, pz = tonumber(input.cellX), tonumber(input.cellZ)
  if not (px and pz) then return nil, "no player cell" end
  px, pz = floor(px), floor(pz)
  if input.synthetic or type(q) ~= "table" or type(q.cell) ~= "function" then
    return BattleStage.synthetic(input, type(q) == "table" and q or nil)
  end
  local m = memo(q)
  local order = dirOrder(input)
  local shapes = input.shapes or BattleStage.SHAPES
  local passes = input.passes or BattleStage.PASSES
  local near = input.near or BattleStage.NEAR_RADIUS
  local far = input.far or BattleStage.FAR_RADIUS
  local surfing = input.surfing == true
  local style = input.seatStyle or BattleStage.SEAT_STYLE
  local player = { x = px + 0.5, z = pz + 0.5, ground = input.ground or m.height(px, pz) }
  local tried = 0
  local function try(pass, cand, shape)
    for _, dn in ipairs(order) do
      local d = DIRS[dn]
      tried = tried + 1
      if fits(m, pass, surfing, shape, cand.x, cand.z, d[1], d[2]) then
        local c = core(m, cand.x, cand.z, d[1], d[2], shape.gap, shape.name, dn)
        c.pass, c.walk, c.tried = pass.name, cand.d, tried
        c.relocated = (cand.x ~= px or cand.z ~= pz)
        c.seat, c.sightBlocked = chooseSeat(m, c, style, player)
        return c
      end
    end
    return nil
  end
  for _, pass in ipairs(passes) do
    local walk = BattleStage.walkOrder(m, px, pz, input.facing, pass, surfing, far)
    -- the preferred wide patch, if one is near
    for _, cand in ipairs(walk) do
      if cand.d > near then break end
      local c = try(pass, cand, shapes[1])
      if c then return c end
    end
    -- otherwise the closest spot of any shape: each shape's nearest fit,
    -- weighed by walking distance + the shape's cost (ties: roomier shape)
    local best, bestScore
    for _, shape in ipairs(shapes) do
      for _, cand in ipairs(walk) do
        if bestScore and cand.d + (shape.cost or 0) >= bestScore then break end
        local c = try(pass, cand, shape)
        if c then
          best, bestScore = c, cand.d + (shape.cost or 0)
          break
        end
      end
    end
    if best then return best end
  end
  local c = BattleStage.synthetic(input, q)
  c.tried = tried
  return c
end

-- World position of battler id (0/2 = the player's side, 1/3 = the foe's) on a
-- stage. Singles use the two slot cells; doubles put partners
-- PARTNER_OFFSET cells to each side. The screen layout decides left/right:
-- from the seat, id 0 is left of id 2 and id 3 is left of id 1.
-- Returns x, z (cells), ground, lateral offset (cells, + = right).
function BattleStage.slotPosition(stage, id, double)
  local own = (id % 2 == 0)
  local s = own and stage.own or stage.foe
  local lat = 0
  if double then
    local o = BattleStage.PARTNER_OFFSET
    if id == 0 then lat = -o elseif id == 2 then lat = o
    elseif id == 1 then lat = o elseif id == 3 then lat = -o end
  end
  local rx, rz = stage.right[1], stage.right[2]
  return s.x + rx * lat, s.z + rz * lat, s.ground, lat
end

-- ------------------------------------------------------------ live world query
-- The query over FRLG_VOXEL's vrHost (HostApi instance `host`) and the
-- engine's collision modules. isWalkable only answers on the engine's
-- current (root) map (HostApi.lua), so cells on neighbouring maps count as
-- unknown (nil).
-- opts = { engine = fn(name) -> module }
BattleStage.MB_TALL_GRASS = 0x02
BattleStage.MB_CYCLING_ROAD_PULL_DOWN_GRASS = 0xD1
-- Engine metatile categories (src/core/game3/scripting/collision.lua
-- Collision.classify) a battler may stand on in the "open-props" pass:
-- low, see-through things. Trees, cliffs, buildings, counters and generic
-- BLOCKED cells (rocks, fences, shrubs) are never used.
BattleStage.LOW_CATEGORIES = {
  LEDGE = true, SIGN = true, SHORT_GRASS = true, TALL_GRASS = true, SAND = true,
  PATH = true, TOWN_PATH = true, PIER = true, ROCK_DECK = true,
}
-- pret small-prop behaviours (the engine's interaction_scripts flavour set).
BattleStage.SMALL_PROP_BEH = {
  [0x81] = true, [0x82] = true, [0x84] = true, [0x86] = true, [0x87] = true, [0x88] = true,
  [0x89] = true, [0x8A] = true, [0x8B] = true, [0x8C] = true, [0x90] = true, [0x93] = true,
  [0x94] = true, [0x95] = true, [0x96] = true, [0x97] = true, [0x98] = true, [0x99] = true,
  [0x9A] = true, [0x9B] = true, [0x9C] = true, [0x9D] = true, [0x9E] = true, [0x9F] = true,
  [0xA1] = true, [0xA2] = true,
}
BattleStage.SIGHT_STEP = 0.25
BattleStage.SIGHT_MARGIN = 0.05

local function defaultEngine(name)
  local ok, m = pcall(require, name)
  if ok and type(m) == "table" then return m end
  return nil
end

local INDOOR_TYPES = { [8] = true, [9] = true }
local function mapKind(def)
  if type(def) ~= "table" then return "route" end
  local mt = tonumber(def.mapType) or 0
  if INDOOR_TYPES[mt] then return "indoor" end
  if mt == 4 then return "cave" end
  return def.kind or "route"
end

BattleStage.OCCLUDER_RADIUS = 16 -- cells around the player searched for trees/buildings (sight test)

function BattleStage.worldQuery(host, opts)
  opts = opts or {}
  local engine = opts.engine or defaultEngine
  local Collision = engine("src.core.game3.collision")
  local Classify = engine("src.core.game3.scripting.collision")
  local rootId = host.rootId and host:rootId() or nil
  local function lowCell(def, lx, lz, beh)
    if beh and BattleStage.SMALL_PROP_BEH[beh] then return true end
    local layout = type(def) == "table" and def.midLayout
    if not (layout and Classify and Classify.classify) then return false end
    local okM, mid = pcall(layout.midAt, layout, lx, lz)
    local okC, coll = pcall(layout.collAt, layout, lx, lz)
    if not (okM and okC) then return false end
    local okK, cat = pcall(Classify.classify, mid or 0, coll or 0, beh, mapKind(def))
    return okK and BattleStage.LOW_CATEGORIES[cat] == true
  end
  local q = {}
  function q.cell(x, z)
    local wx, wz = x + 0.5, z + 0.5
    local mapId, lx, lz, def = host:locate(wx, wz)
    if not mapId or (rootId ~= nil and mapId ~= rootId) then return nil end
    local beh = host:behavior(wx, wz)
    local warp = false
    if Collision and Collision.warpAt then
      local okW, w = pcall(Collision.warpAt, lx, lz)
      if okW and w ~= nil then warp = true end
    end
    if not warp and Collision and Collision.isWarpMetatileBehavior then
      local okB, isWarp = pcall(Collision.isWarpMetatileBehavior, beh)
      if okB and isWarp then warp = true end
    end
    local info = {
      warp = warp,
      water = host:isWater(wx, wz) == true,
      walk = host:isWalkable(wx, wz) == true,
      grass = beh == BattleStage.MB_TALL_GRASS or beh == BattleStage.MB_CYCLING_ROAD_PULL_DOWN_GRASS,
    }
    info.low = (not info.walk) and lowCell(def, lx, lz, beh) or false
    return info
  end
  function q.height(x, z)
    return host:heightAt(x + 0.5, z + 0.5)
  end
  -- Round 2: trees and buildings (the mesher's tree units and building
  -- boxes, else the engine's cell classification), around the player
  local occ
  function q.occluders()
    if occ == nil and opts.center then
      local r = BattleStage.OCCLUDER_RADIUS
      local c = opts.center
      local ok, list = pcall(BattleOccluders.collect, host, c.x - r, c.z - r, c.x + r, c.z + r,
        { engine = engine })
      occ = ok and list or false
    end
    return occ or nil
  end
  -- Heightfield march (hills, cliffs, cave walls: the mesher's heightfield
  -- is the walking surface), then the occluder volumes (trees, buildings).
  function q.sight(ax, ay, az, bx, by, bz)
    local dx, dy, dz = bx - ax, by - ay, bz - az
    local len = sqrt(dx * dx + dz * dz)
    local n = math.max(1, math.ceil(len / BattleStage.SIGHT_STEP))
    for i = 0, n - 1 do
      local t = i / n
      local h = host:heightAt(ax + dx * t, az + dz * t)
      if h and h > ay + dy * t - BattleStage.SIGHT_MARGIN then return false end
    end
    local list = q.occluders()
    if list and BattleOccluders.segmentBlocked(list, ax, ay, az, bx, by, bz) then return false end
    return true
  end
  return q
end

return BattleStage
