-- FRLG_VOXEL / interiors team: props/Counter.lua -- service counters
-- (wave 1, 2026-10-01; scout INVENTORY "Service counter", PLAN.md 2.5).
--
-- What it takes: every furniture group holding a counter cell (behaviour
-- 0x80 MB_COUNTER) whose cells are all counter cells: 0x80, the Mart
-- questionnaire / till 0x8F standing on it (the host draws what stands on
-- it), or no behaviour (end caps and corner pieces, machines painted on a
-- counter top as in the Celadon Dept. Store 3F). A group that still holds
-- another behaviour (a PC 0x83, a computer desk 0x97, Game Corner shelves
-- 0x82, kitchen pieces 0x8A / 0x8B / 0x99) is left alone: the PC type takes
-- its PC first when present, and the group comes free here; otherwise the
-- core and PropFix keep drawing it as today. Plus the counter ends PropFix
-- would otherwise unwall (the "takeovers", supersedes PropFix kind
-- "counter"): the gatehouse end cells that the mesher made 1-cell side
-- walls (pair "house", tiles 653 661 662 668 676 677 678 beside a counter
-- taken here) and the Celadon Dept. Store 4F L-counter foot (7,14).
-- Left out on purpose (not service counters, or bound to a PropFix join):
-- Record Corner's link machine island, the Fuchsia Warden's U-desk, the
-- Pewter Museum rope barriers (1F (11,5-7), 2F (8,5-7)), the Prize Room counter (PropFix joins
-- its ends to the prize-shelf arms), and a group standing on two grounds
-- (One Island: the core levels it after the types, which moves heightAt).
--
-- How it draws: the claimed cells are cut into rectangles (vertical runs
-- first, broken where what stands beside them changes, then runs with the
-- same rows merged sideways) and each rectangle is one Relief piece at the
-- counter's real-life height: the art's last rows on the front, the rows
-- above on the top, the hidden depth laid with the lid rows (Relief.lua:
-- method after pokeemerald-3Ds-dualscreen, ZallaxDev, MIT; the licence text
-- is in Relief.lua's header -- no code or data of his is copied here). A
-- side against another piece, or wholly against a straight wall, is not
-- drawn. Every texel is the room's own art.
--
-- User defaults (scout PLAN Q1, template section 3): real-life height
-- T.H = 0.65 cells (1.04 m), one constant below (with the core option
-- INTERIORS_REAL_HEIGHTS off: the group's own height instead).
-- No globals, no debug / package / io (mod sandbox).
local V = ...
local _ = V

local mabs = math.abs

local T = {
  id = "Counter", version = "counter 0.1 (2026-10-01)",
  walkable = false,
  maxWalkH = 0.56,
  walls = true,         -- the gatehouse / Dept 4F counter ends the mesher made walls (PropFix takeovers)
  heightAt = false,
  supersedes = { "counter" }, -- PropFix kind "counter" on the cells taken here (gatehouse ends, Dept 4F foot)
  budget = 400,
  sourceMids = nil,
  stretchedAllowed = 0,
  windingExempt = 0,
}

-- the real-life counter height (cells above the cell's ground; 1 cell = 1.6 m)
T.H = 0.65
-- the game's over art on the pieces (the gatehouse counter lids are drawn
-- only in that layer); false = under art only
T.OVER_ART = true
-- extra lift of the over art off its face (cells) on top of Relief's R.LIFT
T.OVER_EXTRA_LIFT = 0.0015

-- behaviours a counter group may hold (anything else: not ours)
local OK_BEH = { [0x80] = true, [0x8F] = true }
-- gatehouse counter tiles (pair "house"; PropFix's tile rule) and maps
local GATE_MAPS = "^FR_ROUTE_%d+_.*ENTRANCE"
local GATE_TILES = { 653, 661, 662, 668, 676, 677, 678 }
-- extra counter cells per map (PropFix joins taken over): { x, y }
local EXTRA = {
  FR_CELADON_CITY_DEPARTMENT_STORE_4F = { { 7, 14 } }, -- the L-counter's foot (was a 2.0 block)
}
-- groups left alone: map -> true (every group) or a list of "x,y" (the group holding that cell)
local SKIP = {
  FR_RECORD_CORNER = true,               -- the link machine island (not a service counter)
  FR_FUCHSIA_CITY_WARDENS_HOUSE = true,  -- a U-desk; PropFix joins its east end (12,5)
  FR_PEWTER_CITY_MUSEUM_1F = { "11,5" }, -- the rope barrier; PropFix joins (11,8-9) to it
  FR_PEWTER_CITY_MUSEUM_2F = { "8,5" },  -- the same rope barrier art, in front of an exhibit pillar
  FR_CELADON_CITY_GAME_CORNER_PRIZE_ROOM = true, -- PropFix joins the counter ends (0,3) (8,3) to its arms
}
local N4 = { { -1, 0 }, { 1, 0 }, { 0, -1 }, { 0, 1 } }

local function counterGroup(g)
  if type(g) ~= "table" or not g.cells or g.pillar or g.slot then return false end
  local has = false
  for _, p in ipairs(g.cells) do
    local b = p.beh
    if b and b ~= 0 then
      if not OK_BEH[b] then return false end
      if b == 0x80 then has = true end
    end
  end
  return has
end

local function skipped(mapId, g)
  local s = SKIP[mapId or ""]
  if s == true then return true end
  if type(s) == "table" then
    for _, p in ipairs(g.cells) do
      local k = p.x .. "," .. p.y
      for _, w in ipairs(s) do if w == k then return true end end
    end
  end
  return false
end

-- a group standing on two grounds (One Island's counter over a raised plate)
-- is levelled by the core after the types (levelGroups: every cell gets the
-- group's highest ground, which moves heightAt); this type never moves the
-- ground (heightAt = false), so such a group stays the core's
local function oneGround(g)
  local h0 = g.cells[1] and (g.cells[1].hgt or 0)
  for _, p in ipairs(g.cells) do
    if mabs((p.hgt or 0) - h0) > 1e-9 then return false end
  end
  return true
end

local function rowMajor(a, b)
  if a.y ~= b.y then return a.y < b.y end
  return a.x < b.x
end

function T.applies(ctx, idx) return idx.byBeh[0x80] ~= nil end

-- PURE: the cells wanted, row-major
function T.match(ctx, idx)
  local want, seen, groupsSeen = {}, {}, {}
  for _, c in ipairs(idx.byBeh[0x80] or {}) do
    local g = c.role == "furniture" and c.group or nil
    if g and not groupsSeen[g] then
      groupsSeen[g] = true
      if counterGroup(g) and not skipped(idx.mapId, g) and oneGround(g) then
        for _, p in ipairs(g.cells) do
          if not seen[p] then seen[p] = true; want[#want + 1] = p end
        end
      end
    end
  end
  if #want == 0 then return want end
  -- gatehouse ends the mesher made 1-cell walls, beside a counter taken here
  if idx.pair == "house" and (idx.mapId or ""):find(GATE_MAPS) then
    local ends = {}
    for _, mid in ipairs(GATE_TILES) do
      for _, c in ipairs(idx.byMid[mid] or {}) do
        if c.role == "wall" and not seen[c] then
          for _, d in ipairs(N4) do
            local q = ctx:at(c.x + d[1], c.y + d[2])
            if q and seen[q] then ends[#ends + 1] = c; break end
          end
        end
      end
    end
    for _, c in ipairs(ends) do if not seen[c] then seen[c] = true; want[#want + 1] = c end end
  end
  for _, e in ipairs(EXTRA[idx.mapId or ""] or {}) do
    local c = ctx:at(e[1], e[2])
    if c and not seen[c] then seen[c] = true; want[#want + 1] = c end
  end
  table.sort(want, rowMajor)
  return want
end

-- the piece height of a cell: the real-life T.H, or with the core's
-- INTERIORS_REAL_HEIGHTS off the group's own (the mesher's) height
local function heightOf(ctx, p)
  if ctx:opt("INTERIORS_REAL_HEIGHTS") then return T.H end
  local g = p.group
  if g and type(g.h) == "number" and g.h > 0 then return g.h end
  return T.H
end

function T.classify(ctx, cells, ts)
  -- (heights first: claiming a cell takes it out of its group)
  local hs = {}
  for i, p in ipairs(cells) do hs[i] = heightOf(ctx, p) end
  -- the ground under the piece keeps the cell's own tile: the mesher reads a
  -- neighbour's ground tile for the floor in front of a slanted wall
  -- (FrlgMesher: s.groundMid or s.mid), so the room round the counter stays
  -- as it was. A tile with over art keeps the default ground (the room's
  -- floor): the mesher would lay its over art on the hidden ground too.
  for i, p in ipairs(cells) do
    local gm = p.groundMid
    if gm == nil and not p.hasOver then gm = p.mid end
    ctx:claim(p.x, p.y, gm, hs[i])
  end
end

-- the claimed cells -> rectangles { x0, x1, y0, y1 (exclusive ends), g, h }:
-- vertical runs first, then runs with identical rows merged sideways. A run
-- breaks where the ground, the height or what stands beside it changes
-- (side(x, y) -> a class: another cell of this type, a straight wall, the
-- open edge, or anything else), and only runs with the same class behind
-- them merge, so every flank and back of a piece is either wholly against a
-- wall (not drawn: the wall closes it), wholly against another piece (not
-- drawn) or drawn whole; a front never meets another piece's drawn back (no
-- two faces of this type, and none against a wall, share a plane).
-- side = nil (tests): runs break on ground / height only.
-- Deterministic: sorted input, sorted output.
local function rects(cells, side)
  local set = {}
  for _, p in ipairs(cells) do set[p.y * 65536 + p.x] = p end
  local function at(x, y) return set[y * 65536 + x] end
  local function hOf(p) return p.claimH or T.H end
  local function sideKey(x, y)
    if not side then return "" end
    return side(x - 1, y) .. "|" .. side(x + 1, y)
  end
  local byCol = {}
  for _, p in ipairs(cells) do byCol[#byCol + 1] = p end
  table.sort(byCol, function(a, b)
    if a.x ~= b.x then return a.x < b.x end
    return a.y < b.y
  end)
  local runs, colRuns, done = {}, {}, {}
  for _, p in ipairs(byCol) do
    if not done[p] then
      local g, h, k = p.hgt or 0, hOf(p), sideKey(p.x, p.y)
      local y1 = p.y
      while true do
        local q = at(p.x, y1 + 1)
        if q and not done[q] and mabs((q.hgt or 0) - g) < 1e-9 and mabs(hOf(q) - h) < 1e-9
            and sideKey(p.x, y1 + 1) == k then
          y1 = y1 + 1
        else break end
      end
      for y = p.y, y1 do done[at(p.x, y)] = true end
      local r = { x0 = p.x, x1 = p.x + 1, y0 = p.y, y1 = y1 + 1, g = g, h = h,
        back = side and side(p.x, p.y - 1) or "" }
      runs[#runs + 1] = r
      local l = colRuns[p.x]
      if not l then l = {}; colRuns[p.x] = l end
      l[#l + 1] = r
    end
  end
  local out, used = {}, {}
  for _, r in ipairs(runs) do
    if not used[r] then
      used[r] = true
      local cur = { x0 = r.x0, x1 = r.x1, y0 = r.y0, y1 = r.y1, g = r.g, h = r.h, back = r.back }
      while true do
        local nxt
        for _, s in ipairs(colRuns[cur.x1] or {}) do
          if not used[s] and s.y0 == cur.y0 and s.y1 == cur.y1 and mabs(s.g - cur.g) < 1e-9
              and mabs(s.h - cur.h) < 1e-9 and s.back == cur.back then nxt = s; break end
        end
        if not nxt then break end
        used[nxt] = true
        cur.x1 = nxt.x1
      end
      out[#out + 1] = cur
    end
  end
  table.sort(out, function(a, b)
    if a.y0 ~= b.y0 then return a.y0 < b.y0 end
    return a.x0 < b.x0
  end)
  return out, at
end
T._rects = rects -- (tests)

-- what stands beside a cell's side: "m" another cell of this type, "w" a
-- straight wall (Relief skips a side wholly against it), "o" the room's
-- open edge (off-map / void / exit frame: the synthetic wall stands
-- SYNTH_WALL_INSET inside, not on the side), "f" anything else
local function sideFn(ctx, mine)
  local isVoid = ctx.env.atlas and ctx.env.atlas.isVoid
  local diag = type(ctx.diagOf) == "table" and ctx.diagOf or nil
  return function(x, y)
    local c = ctx:at(x, y)
    if not c or c.exitFrame or c.mid == nil or (isVoid and isVoid(c.mid)) then return "o" end
    if mine[c] then return "m" end
    if c.role == "wall" and not (diag and diag[c]) then return "w" end
    return "f"
  end
end
T._sideFn = sideFn -- (tests)

function T.props(ctx, ts)
  local R = ts.lib.Relief
  local under, over = ctx:buffer("opaque"), ctx:buffer("over")
  local mine = ts.cellSet or {}
  local side = sideFn(ctx, mine)
  local list = rects(ts.cells, side)
  local tmp = {} -- Relief's over art, re-emitted below
  local function all(cls, xa, xb, ya, yb)
    for y = ya, yb do for x = xa, xb do if side(x, y) ~= cls then return false end end end
    return true
  end
  local function any(cls, xa, xb, ya, yb)
    for y = ya, yb do for x = xa, xb do if side(x, y) == cls then return true end end end
    return false
  end
  for _, r in ipairs(list) do
    local fl, back = {}, nil
    -- sides: against another piece: not drawn; toward the open edge: drawn
    -- (closes the piece behind the synthetic wall); else Relief's auto
    -- (skipped wholly against a straight wall)
    if all("m", r.x0 - 1, r.x0 - 1, r.y0, r.y1 - 1) then fl.w = false
    elseif any("o", r.x0 - 1, r.x0 - 1, r.y0, r.y1 - 1) then fl.w = true end
    if all("m", r.x1, r.x1, r.y0, r.y1 - 1) then fl.e = false
    elseif any("o", r.x1, r.x1, r.y0, r.y1 - 1) then fl.e = true end
    if all("m", r.x0, r.x1 - 1, r.y0 - 1, r.y0 - 1) then back = false
    elseif any("o", r.x0, r.x1 - 1, r.y0 - 1, r.y0 - 1) then back = true end
    -- a piece standing behind another piece (a U-counter's arm): its own
    -- bottom art rows are lid (flowers, the till ...), not the counter's
    -- front, so its sides wear the lid rows
    local inner = all("m", r.x0, r.x1 - 1, r.y1, r.y1)
    local sides = inner and "lid" or nil
    -- its front then stands inside the counter; a side of it against
    -- another piece is drawn so that front's edges rest on a face (the
    -- neighbour's side there is never drawn: it is wholly against this type)
    if inner then
      if fl.w == false then fl.w = true end
      if fl.e == false then fl.e = true end
    end
    R.piece(ctx, { x0 = r.x0, x1 = r.x1, z0 = r.y0, z1 = r.y1, h = r.h, g = r.g, flanks = fl, back = back,
      sides = sides, under = under, over = T.OVER_ART and tmp or nil, tag = "counter" })
  end
  local at = function(x, y) local c = ctx:at(x, y); return c and mine[c] end
  -- over art (the game's top layer: the gatehouse counter lids live there):
  -- lifted OVER_EXTRA_LIFT further off its face (Relief's 0.003 + this =
  -- clear of the 0.004 coplanar tolerance, like the core's own 0.004 decals),
  -- and kept only where it stays over this type's own cells (a decal on a
  -- side facing out of the counter would stand a few mm outside them)
  local newV = ctx:newVfn()
  local L = T.OVER_EXTRA_LIFT
  local E = 1e-6
  local function inCells(x, z)
    for _, dx in ipairs({ -E, E }) do
      for _, dz in ipairs({ -E, E }) do
        if at(math.floor(x + dx), math.floor(z + dz)) then return true end
      end
    end
    return false
  end
  for i = 1, #tmp - 2, 3 do
    local vs = {}
    local inside = true
    for k = 0, 2 do
      local v = tmp[i + k]
      local nx, ny, nz = v[6] or 0, v[7] or 0, v[8] or 0
      vs[k + 1] = { v[1] + nx * L, v[2] + ny * L, v[3] + nz * L, v[4], v[5], nx, ny, nz }
    end
    local a, b, c = vs[1], vs[2], vs[3]
    for _, p in ipairs({ a, b, c,
        { (a[1] + b[1] + c[1]) / 3, 0, (a[3] + b[3] + c[3]) / 3 },
        { (a[1] + b[1]) / 2, 0, (a[3] + b[3]) / 2 }, { (b[1] + c[1]) / 2, 0, (b[3] + c[3]) / 2 },
        { (c[1] + a[1]) / 2, 0, (c[3] + a[3]) / 2 } }) do
      if not inCells(p[1], p[3]) then inside = false; break end
    end
    if inside then
      for k = 1, 3 do
        local q = vs[k]
        over[#over + 1] = newV(q[1], q[2], q[3], q[4], q[5], q[6], q[7], q[8])
      end
    else
      ts.overDropped = (ts.overDropped or 0) + 1
    end
  end
end

return T
