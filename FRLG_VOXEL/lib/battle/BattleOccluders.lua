-- FRLG_VOXEL (W6, battle round 2): what stands between the battle seat and
-- the Pokemon.
--
-- The heightfield sight test sees hills and cave walls but not trees or
-- buildings (the mesher's heightfield is the walking surface). This module
-- gives the battle presenter the real occluders:
--   1. the mesher's own tree units (geom.treeOccluders: x, z, y0, y1, r) and
--      building boxes (geom.stats.buildingInfo / blockInfo), kept per map by
--      Scene (w6/SCENE_PATCH_battle_occluders.md, one line: rec.occluders);
--   2. where a map has none (older Scene, stub mesher), the engine's own
--      cell classification (scripting/collision.lua Collision.classify, the
--      classifier the mesher itself uses): TREE cells as tree units,
--      BUILDING / CLIFF cells as boxes, other solid cells (fences, rocks,
--      signs) as low boxes near the seat only.
-- Uses: the seat's sight test (BattleStage) and the cutaway (BattleCut),
-- which cuts every chosen occluder's volume from the terrain draw.
-- Units: world = root map cells, X east, Z south, Y up (cells).
local V = ...
local _ = V

local BO = {}

BO.MAX_CUT = 8                 -- occluder volumes the cutaway takes per frame (BattleCut.OCC)
BO.FOREGROUND_DEG = 35         -- half-angle of the view wedge for foreground clutter
BO.SAMPLES = { 0.15, 0.5, 0.95 } -- heights on a card (fraction of its height) for sight lines
-- fallback sizes (cells above the cell's ground)
BO.TREE = { r = 0.62, y0 = 0.35, y1 = 2.7 }
BO.BUILDING_H = 3.2
BO.CLIFF_H = 1.6
BO.LOW_H = 1.0
BO.LOW_RADIUS = 3.5            -- low solid cells only this close to the seat
-- Round 3: tall grass around the seat (the mesher's crossed grass cards) is
-- cut too, as one box per row run; cut only, never a sight blocker.
BO.GRASS_H = 0.9
BO.GRASS_Y0 = 0.06
BO.ROOF_RISE = 1.5             -- roof above the wall top (mesher ROOF/GABLE_RISE_MAX)
BO.BLOCK_ROW = 1.0             -- cells per block row (mesher blocks)
BO.TALL_CATS = { TREE = "tree", BUILDING = "building", CLIFF = "cliff" }
BO.LOW_CATS = { BLOCKED = true, SIGN = true, COUNTER = true, PC = true, LEDGE = false }

local sqrt, abs, huge = math.sqrt, math.abs, math.huge

-- ------------------------------------------------------------ shapes
-- Occluder = { kind = "tree", x, z, y0, y1, r } | { kind = "box", x0, z0, x1, z1, y0, y1 }
function BO.aabb(o)
  if o.kind == "tree" then
    return o.x - o.r, o.y0, o.z - o.r, o.x + o.r, o.y1, o.z + o.r
  end
  return o.x0, o.y0, o.z0, o.x1, o.y1, o.z1
end

function BO.corners(o)
  local x0, y0, z0, x1, y1, z1 = BO.aabb(o)
  return {
    { x0, y0, z0 }, { x1, y0, z0 }, { x0, y0, z1 }, { x1, y0, z1 },
    { x0, y1, z0 }, { x1, y1, z0 }, { x0, y1, z1 }, { x1, y1, z1 },
  }
end

function BO.center(o)
  local x0, y0, z0, x1, y1, z1 = BO.aabb(o)
  return (x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2
end

-- Segment a->b against an AABB (slab test). Returns entry t in [0,1] or nil.
local function slab(ax, ay, az, bx, by, bz, x0, y0, z0, x1, y1, z1)
  local t0, t1 = 0, 1
  for _, s in ipairs({ { ax, bx, x0, x1 }, { ay, by, y0, y1 }, { az, bz, z0, z1 } }) do
    local a, b, lo, hi = s[1], s[2], s[3], s[4]
    local d = b - a
    if abs(d) < 1e-12 then
      if a < lo or a > hi then return nil end
    else
      local u0, u1 = (lo - a) / d, (hi - a) / d
      if u0 > u1 then u0, u1 = u1, u0 end
      if u0 > t0 then t0 = u0 end
      if u1 < t1 then t1 = u1 end
      if t0 > t1 then return nil end
    end
  end
  return t0
end

-- Segment a->b against an occluder: box = AABB; tree = vertical cylinder of
-- radius r between y0 and y1. Returns the entry t or nil.
function BO.segmentHit(o, ax, ay, az, bx, by, bz)
  if o.kind ~= "tree" then
    return slab(ax, ay, az, bx, by, bz, o.x0, o.y0, o.z0, o.x1, o.y1, o.z1)
  end
  -- cylinder: solve |(p - c)_xz| = r on the segment, clip to y0..y1
  local dx, dz = bx - ax, bz - az
  local fx, fz = ax - o.x, az - o.z
  local A = dx * dx + dz * dz
  local B = 2 * (fx * dx + fz * dz)
  local C = fx * fx + fz * fz - o.r * o.r
  local t0, t1
  if A < 1e-12 then
    if C > 0 then return nil end
    t0, t1 = 0, 1
  else
    local D = B * B - 4 * A * C
    if D < 0 then return nil end
    local sq = sqrt(D)
    t0, t1 = (-B - sq) / (2 * A), (-B + sq) / (2 * A)
  end
  t0, t1 = math.max(0, t0), math.min(1, t1)
  if t0 > t1 then return nil end
  local dy = by - ay
  if abs(dy) < 1e-12 then
    if ay < o.y0 or ay > o.y1 then return nil end
    return t0
  end
  local u0, u1 = (o.y0 - ay) / dy, (o.y1 - ay) / dy
  if u0 > u1 then u0, u1 = u1, u0 end
  local s0, s1 = math.max(t0, u0), math.min(t1, u1)
  if s0 > s1 then return nil end
  return s0
end

function BO.segmentBlocked(list, ax, ay, az, bx, by, bz)
  for _, o in ipairs(list or {}) do
    local t = (not o.cutOnly) and BO.segmentHit(o, ax, ay, az, bx, by, bz) or nil
    if t and t < 0.97 then return true, o end
  end
  return false
end

-- ------------------------------------------------------------ collection
local function inBox(x, z, x0, z0, x1, z1) return x >= x0 and x <= x1 and z >= z0 and z <= z1 end

-- The mesher's occluders from Scene (rec.occluders, map-local cells) in the
-- root frame. Returns list, mapsWithData, mapsSeen.
function BO.fromScene(scene, x0, z0, x1, z1)
  local out, withData, seen = {}, 0, 0
  if type(scene) ~= "table" or type(scene.placed) ~= "table" then return out, 0, 0 end
  for _, p in ipairs(scene.placed) do
    local rec = scene.cache and scene.cache[p.key]
    if rec and not rec.failed and not rec.empty and rec.w and rec.h then
      local ox, oz = tonumber(p.ox) or 0, tonumber(p.oy) or 0
      if not (ox > x1 or oz > z1 or ox + rec.w < x0 or oz + rec.h < z0) then
        seen = seen + 1
        local occ = rec.occluders
        if type(occ) == "table" then
          withData = withData + 1
          for _, t in ipairs(occ.trees or {}) do
            local tx, tz = (tonumber(t.x or t[1]) or 0) + ox, (tonumber(t.z or t[2]) or 0) + oz
            if inBox(tx, tz, x0, z0, x1, z1) then
              out[#out + 1] = { kind = "tree", x = tx, z = tz, y0 = tonumber(t.y0 or t[3]) or 0,
                y1 = tonumber(t.y1 or t[4]) or 2, r = tonumber(t.r or t[5]) or 0.6, source = "mesher" }
            end
          end
          for _, b in ipairs(occ.buildings or {}) do
            local e = type(b.eave) == "table" and b.eave or nil
            local bx0 = (e and tonumber(e.x0)) or (tonumber(b.minX) or 0)
            local bx1 = (e and tonumber(e.x1)) or ((tonumber(b.maxX) or 0) + 1)
            local bz0 = (e and tonumber(e.z0)) or (tonumber(b.minY) or 0)
            local bz1 = (e and tonumber(e.z1)) or ((tonumber(b.maxY) or 0) + 1)
            local gy = tonumber(b.groundY) or 0
            local top = (tonumber(b.wallTopY) or (gy + 2)) + BO.ROOF_RISE
            local o = { kind = "box", x0 = bx0 + ox, z0 = bz0 + oz, x1 = bx1 + ox, z1 = bz1 + oz,
              y0 = gy, y1 = top, source = "mesher-building" }
            if not (o.x0 > x1 or o.z0 > z1 or o.x1 < x0 or o.z1 < z0) then out[#out + 1] = o end
          end
          for _, b in ipairs(occ.blocks or {}) do
            local bx0, bz0 = (tonumber(b.minX) or 0) + ox, (tonumber(b.minY) or 0) + oz
            local bx1, bz1 = (tonumber(b.maxX) or 0) + 1 + ox, (tonumber(b.maxY) or 0) + 1 + oz
            if not (bx0 > x1 or bz0 > z1 or bx1 < x0 or bz1 < z0) then
              local gy = 0
              if scene.heightAt then
                local okH, h = pcall(scene.heightAt, scene, (bx0 + bx1) / 2, bz1 + 0.5)
                if okH and type(h) == "number" then gy = h end
              end
              out[#out + 1] = { kind = "box", x0 = bx0, z0 = bz0, x1 = bx1, z1 = bz1, y0 = gy,
                y1 = gy + (tonumber(b.maxRows) or 2) * BO.BLOCK_ROW + 1, source = "mesher-block" }
            end
          end
        end
      end
    end
  end
  return out, withData, seen
end

local INDOOR_TYPES = { [8] = true, [9] = true }
local function mapKind(def)
  if type(def) ~= "table" then return "route" end
  local mt = tonumber(def.mapType) or 0
  if INDOOR_TYPES[mt] then return "indoor" end
  if mt == 4 then return "cave" end
  return def.kind or "route"
end

-- Fallback: the engine's cell classification. host = HostApi instance (locate,
-- behavior, heightAt); classify = scripting/collision.lua Collision.classify.
-- near = { x, z } (the seat): low solid cells only within LOW_RADIUS of it.
function BO.fromCells(host, classify, x0, z0, x1, z1, near, lowRadius)
  local out = {}
  if not (host and classify) then return out end
  local grassRows = {} -- z -> { {x, g}, ... } tall grass near the seat
  local lowR = tonumber(lowRadius) or BO.LOW_RADIUS -- battle-move: wider when the player can walk about
  for cz = math.floor(z0), math.floor(z1) do
    for cx = math.floor(x0), math.floor(x1) do
      local wx, wz = cx + 0.5, cz + 0.5
      local okL, mapId, lx, lz, def = pcall(host.locate, host, wx, wz)
      local layout = okL and mapId and type(def) == "table" and def.midLayout or nil
      if layout then
        local okM, mid = pcall(layout.midAt, layout, lx, lz)
        local okC, coll = pcall(layout.collAt, layout, lx, lz)
        local okB, beh = pcall(host.behavior, host, wx, wz)
        if okM and okC then
          local okK, cat = pcall(classify, mid or 0, coll or 0, okB and beh or nil, mapKind(def))
          cat = okK and cat or nil
          local okH, g = pcall(host.heightAt, host, wx, wz)
          g = (okH and type(g) == "number") and g or 0
          local tall = BO.TALL_CATS[cat]
          if tall == "tree" then
            out[#out + 1] = { kind = "tree", x = wx, z = wz, y0 = g + BO.TREE.y0, y1 = g + BO.TREE.y1,
              r = BO.TREE.r, source = "cells" }
          elseif tall then
            out[#out + 1] = { kind = "box", x0 = cx, z0 = cz, x1 = cx + 1, z1 = cz + 1, y0 = g,
              y1 = g + (tall == "building" and BO.BUILDING_H or BO.CLIFF_H), source = "cells" }
          elseif cat == "TALL_GRASS" and near then
            local dx, dz = wx - near.x, wz - near.z
            if dx * dx + dz * dz <= lowR * lowR then
              local row = grassRows[cz]
              if not row then row = {}; grassRows[cz] = row end
              row[#row + 1] = { cx, g }
            end
          elseif cat and BO.LOW_CATS[cat] and near then
            local dx, dz = wx - near.x, wz - near.z
            if dx * dx + dz * dz <= lowR * lowR then
              out[#out + 1] = { kind = "box", x0 = cx, z0 = cz, x1 = cx + 1, z1 = cz + 1, y0 = g,
                y1 = g + BO.LOW_H, source = "cells-low" }
            end
          end
        end
      end
    end
  end
  -- grass row runs -> boxes (cut only)
  local zs = {}
  for z in pairs(grassRows) do zs[#zs + 1] = z end
  table.sort(zs)
  for _, z in ipairs(zs) do
    local row = grassRows[z]
    table.sort(row, function(p, q) return p[1] < q[1] end)
    local i = 1
    while i <= #row do
      local j = i
      local lo, hi = row[i][2], row[i][2]
      while j < #row and row[j + 1][1] == row[j][1] + 1 do
        j = j + 1
        lo, hi = math.min(lo, row[j][2]), math.max(hi, row[j][2])
      end
      out[#out + 1] = { kind = "box", x0 = row[i][1], z0 = z, x1 = row[j][1] + 1, z1 = z + 1,
        y0 = lo + BO.GRASS_Y0, y1 = hi + BO.GRASS_H, source = "cells-grass", cutOnly = true }
      i = j + 1
    end
  end
  return out
end

-- Occluders in the box around the seat and the arena: the mesher's when the
-- maps have them, else the cell classification. opts = { engine, near }.
function BO.collect(host, x0, z0, x1, z1, opts)
  opts = opts or {}
  local scene = host and host.scene
  local list, withData, seen = BO.fromScene(scene, x0, z0, x1, z1)
  local source = (withData > 0) and "mesher" or "none"
  local engine = opts.engine or function(name)
    local ok, m = pcall(require, name)
    return ok and type(m) == "table" and m or nil
  end
  local C = engine("src.core.game3.scripting.collision")
  if not (C and C.classify) then return list, source end
  -- the engine's classification: every tall cell no mesher occluder covers
  -- (maps without data, forest trees the mesher builds as walls, not tree
  -- units), plus low clutter (fences, rocks, signs) near the seat
  local covered = {}
  for _, o in ipairs(list) do covered[#covered + 1] = { BO.aabb(o) } end
  local function isCovered(cx, cz)
    for _, b in ipairs(covered) do
      if cx >= b[1] and cx <= b[4] and cz >= b[3] and cz <= b[6] then return true end
    end
    return false
  end
  local added = 0
  for _, o in ipairs(BO.fromCells(host, C.classify, x0, z0, x1, z1, opts.near, opts.lowRadius)) do
    local cx, _, cz = BO.center(o)
    if o.source == "cells-low" or o.source == "cells-grass" or not isCovered(cx, cz) then
      list[#list + 1] = o
      added = added + 1
    end
  end
  if added > 0 then source = (withData > 0) and "mixed" or "cells" end
  local _ = seen
  return list, source
end

-- ------------------------------------------------------------ choosing what to cut
-- eye = {x, y, z}; cards = { {x, z, base, h}, ... } (battler cards); focus =
-- {x, z}; floorY. Returns up to MAX_CUT occluders, nearest first: every one
-- a sight line from the eye to a card crosses, plus foreground clutter in
-- the view wedge nearer than the nearest card.
function BO.forView(list, eye, cards, focus, floorY)
  local chosen, seen = {}, {}
  local nearest = huge
  for _, c in ipairs(cards or {}) do
    local d = sqrt((c.x - eye.x) ^ 2 + (c.z - eye.z) ^ 2)
    if d < nearest then nearest = d end
  end
  local function take(o, d)
    if seen[o] then return end
    seen[o] = true
    chosen[#chosen + 1] = { o = o, d = d }
  end
  for _, o in ipairs(list or {}) do
    local _, _, _, _, y1 = BO.aabb(o)
    if y1 > (floorY or -huge) + 0.1 then
      local hit = false
      for _, c in ipairs(cards or {}) do
        for _, f in ipairs(BO.SAMPLES) do
          local t = BO.segmentHit(o, eye.x, eye.y, eye.z, c.x, c.base + c.h * f, c.z)
          if t and t < 0.97 then hit = true; break end
        end
        if hit then break end
      end
      local cx, _, cz = BO.center(o)
      local d = sqrt((cx - eye.x) ^ 2 + (cz - eye.z) ^ 2)
      if hit then
        take(o, d)
      elseif focus and d < nearest then
        local fx, fz = focus.x - eye.x, focus.z - eye.z
        local fl = sqrt(fx * fx + fz * fz)
        if fl > 1e-6 and d > 1e-6 then
          local cosA = ((cx - eye.x) * fx + (cz - eye.z) * fz) / (d * fl)
          if cosA > math.cos(math.rad(BO.FOREGROUND_DEG)) then take(o, d) end
        end
      end
    end
  end
  table.sort(chosen, function(a, b) return a.d < b.d end)
  local out = {}
  for i = 1, math.min(#chosen, BO.MAX_CUT) do out[i] = chosen[i].o end
  return out, #chosen
end

return BO
