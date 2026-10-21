-- FRLG_VOXEL / interiors team: props/GameCorner.lua -- the Celadon Game
-- Corner's slot-machine banks and the prize counters of the Game Corner and
-- its Prize Room, wave 4 (2026-10-02; scout INVENTORY "Slot machines + Game
-- Corner furniture").
--
-- Today the slot banks are the core's slot boxes (1.2 cells) with the art
-- stretched over the lid, and the two prize counters (a U round the prize
-- shelves) are PropFix map rules. Here every piece is a relief piece built
-- with the shared builder (props/Relief.lua: method after
-- pokeemerald-3Ds-dualscreen, ZallaxDev, MIT -- the licence text is in
-- Relief.lua's header; no code or data of that project is copied here).
-- Every texel is the player's own ROM-extracted art read through the atlas;
-- nothing is invented.
--
-- THE ART. A slot bank is drawn as one block per group: back-to-back pairs of
-- machines (columns 5-6 and 11-12) and two single columns at the side edges
-- (0 and 17: the other half of their pair lies off the map), five machines
-- deep (rows 6-10). The drawing's top outline lies 2 px down in the floor row
-- behind (rows 5: over art), its foot on the bank's last row (the base band
-- ends on the cell border; row 11 is only floor shadow). The piece stands on
-- the collision cells, so the picture is not moved: the front shows the art's
-- last H * 16 rows (the last machine and its base), the rows above lie on the
-- lid, and the flanks the players sit beside wear the front rows' edge strip
-- (each course one cell: one machine side with its base band), tiled 1:1.
--
-- The prize counter is the Counter type's drawing (green top, white rim):
-- cut into rectangles (vertical runs first, then runs merged sideways) and
-- each rectangle is one Relief piece at the counter's real-life height.
--
-- Taken:
--   * every slot group (the core's g.slot) made only of the slot drawings
--     (pair building__rom_082d4cec, 696 697 704 705), a full rectangle on one
--     ground;
--   * on the Game Corner and the Prize Room only: the furniture group holding
--     a counter cell (0x80) whose free cells are all 0x80 or behaviour-less
--     (the corner / end pieces), on one ground. The prize shelves inside the
--     U (0x82) are the MartShelf type's and are never claimed here.
-- NOT taken: the chairs (the Seat type's), the Two Island Joyful Game Corner
-- (its counters / tables / chairs are the Counter / Table / Seat types'; it
-- has no slot machines), the purple rail in front of the Game Corner stairs
-- (no counter / slot behaviour; the Rail type's wave).
-- Mod sandbox: no globals, no debug / package / io; `...` is V (nil in tests).
local V = ...
local _ = V

local T = {
  id = "GameCorner", version = "gamecorner 0.1 (2026-10-02)",
  walkable = false,
  maxWalkH = 0.56,
  walls = true,           -- the Prize Room counter's two end cells are 1-cell side walls (PropFix joins them)
  heightAt = false,
  supersedes = { "counter" }, -- PropFix's prize-counter map rules (Game Corner, Prize Room)
  budget = 400,
  sourceMids = nil,
  stretchedAllowed = 0,
  windingExempt = 0,
}

-- ------------------------------------------------------------------ constants
-- heights (cells above the cell's ground; 1 cell = 1.6 m). User default:
-- real-life heights. A pachislot cabinet with its top sign stands 1.8-1.95 m:
-- the core's slot box height 1.2 (1.92 m), unchanged (the interiors suites
-- check that top). (Zallax's art-row height would be 0.875: the drawing rises
-- 14 px above the bank's back row.)
T.SLOT_H = 1.20
-- the prize counter: the Counter type's real-life counter height (1.04 m)
T.COUNTER_H = 0.65
-- the slot drawing's top outline: px below the top of the row behind the bank
T.SLOT_TOP = 2
-- cells: a drawn side next to something solid that is not a wall or ours
-- stands this far inside its cell border (never flush on another piece's face)
T.INSET = 1 / 64
-- the slot drawings per pair and the maps with a prize counter
T.SLOT_MIDS = { building__rom_082d4cec = { [696] = true, [697] = true, [704] = true, [705] = true } }
T.PRIZE_MAPS = { FR_CELADON_CITY_GAME_CORNER = true, FR_CELADON_CITY_GAME_CORNER_PRIZE_ROOM = true }
local COUNTER_BEH = { [0x80] = true, [0] = true }
-- the counter's end pieces the mesher made 1-cell side walls (the Prize Room
-- (0,3) / (8,3): PropFix's "counter end" joins, taken over here), beside a
-- counter cell taken here
T.COUNTER_ENDS = { 667, 675 }
local N4 = { { -1, 0 }, { 1, 0 }, { 0, -1 }, { 0, 1 } }

local mabs = math.abs
local function key(x, y) return y * 65536 + x end

function T.applies(ctx, idx)
  return T.SLOT_MIDS[idx.pair] ~= nil and (idx.byMid[696] ~= nil or idx.byMid[697] ~= nil
    or (T.PRIZE_MAPS[idx.mapId or ""] and idx.byBeh[0x80] ~= nil))
end

-- a cell still free for this type (not claimed by an earlier type)
local function free(c) return c and c.claimOwner == nil and c.role ~= "ext" end

-- the free cells of a group (in its own order)
local function freeCells(g)
  local out = {}
  for _, q in ipairs(g.cells) do if free(q) then out[#out + 1] = q end end
  return out
end

local function oneGround(cells)
  local g0 = cells[1] and (cells[1].hgt or 0)
  for _, q in ipairs(cells) do if mabs((q.hgt or 0) - g0) > 1e-9 then return false end end
  return true
end

-- a slot group: only slot drawings, a full rectangle, one ground
local function slotOk(idx, g)
  if not (g and g.cells and g.slot) or g.pillar then return false end
  local mids = T.SLOT_MIDS[idx.pair]
  local cells = g.cells
  if #cells == 0 then return false end
  local x0, x1, y0, y1 = math.huge, -math.huge, math.huge, -math.huge
  for _, q in ipairs(cells) do
    if not free(q) or q.walkable or q.role ~= "furniture" or not mids[q.mid] then return false end
    if q.x < x0 then x0 = q.x end
    if q.x > x1 then x1 = q.x end
    if q.y < y0 then y0 = q.y end
    if q.y > y1 then y1 = q.y end
  end
  if (x1 - x0 + 1) * (y1 - y0 + 1) ~= #cells then return false end
  return oneGround(cells)
end

-- a prize counter group: its free cells all counter / behaviour-less, one
-- ground, at least one counter cell
local function counterOk(g)
  if not (g and g.cells) or g.slot or g.pillar then return false end
  local cells = freeCells(g)
  if #cells == 0 then return false end
  local has = false
  for _, q in ipairs(cells) do
    if q.walkable or q.role ~= "furniture" or not COUNTER_BEH[q.beh or 0] then return false end
    if q.beh == 0x80 then has = true end
  end
  return has and oneGround(cells)
end

local function isSlotMid(pair, c) local m = T.SLOT_MIDS[pair]; return m and m[c.mid] and true or false end

-- PURE: the slot groups and the prize counters, row-major (idx.all order)
function T.match(ctx, idx)
  local want, seen = {}, {}
  local mids = T.SLOT_MIDS[idx.pair]
  if not mids then return {} end
  for _, mid in ipairs({ 696, 697, 704, 705 }) do
    for _, c in ipairs(idx.byMid[mid] or {}) do
      local g = c.role == "furniture" and c.group or nil
      if g and seen[g] == nil then
        seen[g] = slotOk(idx, g)
        if seen[g] then for _, q in ipairs(g.cells) do want[q] = true end end
      end
    end
  end
  if T.PRIZE_MAPS[idx.mapId or ""] then
    for _, c in ipairs(idx.byBeh[0x80] or {}) do
      local g = c.role == "furniture" and free(c) and c.group or nil
      if g and seen[g] == nil then
        seen[g] = counterOk(g)
        if seen[g] then for _, q in ipairs(freeCells(g)) do want[q] = true end end
      end
    end
    -- the counter's end cells the mesher made side walls
    for _, mid in ipairs(T.COUNTER_ENDS) do
      for _, c in ipairs(idx.byMid[mid] or {}) do
        if c.role == "wall" and free(c) and not c.walkable and not c.inWall and not c.pocket then
          for _, d in ipairs(N4) do
            local q = ctx:at(c.x + d[1], c.y + d[2])
            if q and want[q] and not isSlotMid(idx.pair, q) and mabs((q.hgt or 0) - (c.hgt or 0)) < 1e-9 then
              want[c] = true; break
            end
          end
        end
      end
    end
  end
  local out = {}
  for _, c in ipairs(idx.all) do if want[c] then out[#out + 1] = c end end
  return out
end

-- ------------------------------------------------------------ classify
local isSlot = isSlotMid

function T.classify(ctx, cells, ts)
  for _, p in ipairs(cells) do
    ctx:claim(p.x, p.y, nil, isSlot(ctx.pair, p) and T.SLOT_H or T.COUNTER_H)
  end
end

-- ------------------------------------------------------------ pieces
-- slot banks: each column run of slot cells -> runs merged sideways with the
-- same rows (a pair of columns is one block)
local function slotBanks(pair, cells)
  local set = {}
  for _, p in ipairs(cells) do if isSlot(pair, p) then set[key(p.x, p.y)] = p end end
  local function at(x, y) return set[key(x, y)] end
  local cols = {}
  for _, p in ipairs(cells) do
    if at(p.x, p.y) and not at(p.x, p.y - 1) then
      local y1 = p.y
      while at(p.x, y1 + 1) do y1 = y1 + 1 end
      cols[#cols + 1] = { x0 = p.x, x1 = p.x + 1, z0 = p.y, z1 = y1 + 1, g = p.hgt or 0 }
    end
  end
  -- cols come in row-major order of their head cells: merge east neighbours
  local out, last = {}, nil
  for _, c in ipairs(cols) do
    if last and c.x0 == last.x1 and c.z0 == last.z0 and c.z1 == last.z1 and mabs(c.g - last.g) < 1e-9 then
      last.x1 = c.x1
    else
      last = { x0 = c.x0, x1 = c.x1, z0 = c.z0, z1 = c.z1, g = c.g }
      out[#out + 1] = last
    end
  end
  return out
end
T._slotBanks = slotBanks -- (tests)

-- what stands beside a cell: "m" ours, "w" a straight wall, "o" the room's
-- open edge (off-map / void / exit frame), "s" something solid that is not a
-- wall (another type's piece, a core box), "f" open floor
local function sideFn(ctx, mine)
  local isVoid = ctx.env.atlas and ctx.env.atlas.isVoid
  local diag = type(ctx.diagOf) == "table" and ctx.diagOf or nil
  return function(x, y)
    local c = ctx:at(x, y)
    if not c or c.exitFrame or c.mid == nil or (isVoid and isVoid(c.mid)) then return "o" end
    if mine[c] then return "m" end
    if c.role == "wall" and not (diag and diag[c]) then return "w" end
    if c.walkable then return "f" end
    return "s"
  end
end
T._sideFn = sideFn -- (tests)

-- counter cells -> rectangles { x0, x1, y0, y1 (exclusive ends), g }:
-- vertical runs first, broken where the ground changes or a side passes
-- between ours / a straight wall / anything else, then runs with the same rows and the same class behind merged
-- sideways (the Counter type's cut). Deterministic: sorted input / output.
local function rects(cells, side)
  local set = {}
  for _, p in ipairs(cells) do set[key(p.x, p.y)] = p end
  local function at(x, y) return set[key(x, y)] end
  -- (runs split between ours / a straight wall / anything else: a side
  -- never runs partly along a wall face -- it would lie on the wall's plane;
  -- whether it is inset is decided per piece)
  local function cls(x, y)
    local k = side(x, y)
    if k == "m" or k == "w" then return k end
    return "x"
  end
  local function sideKey(x, y)
    if not side then return "" end
    return cls(x - 1, y) .. "|" .. cls(x + 1, y)
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
      local g, k = p.hgt or 0, sideKey(p.x, p.y)
      local y1 = p.y
      while true do
        local q = at(p.x, y1 + 1)
        if q and not done[q] and mabs((q.hgt or 0) - g) < 1e-9 and sideKey(p.x, y1 + 1) == k then
          y1 = y1 + 1
        else break end
      end
      for y = p.y, y1 do done[at(p.x, y)] = true end
      local r = { x0 = p.x, x1 = p.x + 1, y0 = p.y, y1 = y1 + 1, g = g, back = side and cls(p.x, p.y - 1) or "" }
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
      local cur = { x0 = r.x0, x1 = r.x1, y0 = r.y0, y1 = r.y1, g = r.g, back = r.back }
      while true do
        local nxt
        for _, s in ipairs(colRuns[cur.x1] or {}) do
          if not used[s] and s.y0 == cur.y0 and s.y1 == cur.y1 and mabs(s.g - cur.g) < 1e-9 and s.back == cur.back then
            nxt = s; break
          end
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
  return out
end
T._rects = rects -- (tests)

-- ------------------------------------------------------------ props
function T.props(ctx, ts)
  local R = ts.lib.Relief
  local under, over = ctx:buffer("opaque"), ctx:buffer("over")
  local mine = ts.cellSet or {}
  local side = sideFn(ctx, mine)
  local function all(cls, xa, xb, ya, yb)
    for y = ya, yb do for x = xa, xb do if side(x, y) ~= cls then return false end end end
    return true
  end
  local function any(cls, xa, xb, ya, yb)
    for y = ya, yb do for x = xa, xb do if side(x, y) == cls then return true end end end
    return false
  end
  -- a side: false (wholly ours or wholly a straight wall: hidden), true
  -- (drawn) and whether it stands inset: only when the whole side is solid
  -- (another piece / a core box, or walls), so the inset face never leaves
  -- a neighbouring piece of ours with an edge in the open
  local function sideOf(xa, xb, ya, yb)
    if all("m", xa, xb, ya, yb) then return false, false end
    if all("w", xa, xb, ya, yb) then return false, false end
    if any("o", xa, xb, ya, yb) or any("f", xa, xb, ya, yb) or any("m", xa, xb, ya, yb) then return true, false end
    return true, true
  end
  local pair = ctx.pair
  ts.stats = {} -- (tests) Relief stats per piece
  -- slot banks
  local slotCells = {}
  for _, p in ipairs(ts.cells) do if isSlot(pair, p) then slotCells[#slotCells + 1] = p end end
  for _, b in ipairs(slotBanks(pair, slotCells)) do
    local fw, iw = sideOf(b.x0 - 1, b.x0 - 1, b.z0, b.z1 - 1)
    local fe, ie = sideOf(b.x1, b.x1, b.z0, b.z1 - 1)
    local bk, ib = sideOf(b.x0, b.x1 - 1, b.z0 - 1, b.z0 - 1)
    local x0, x1, z0 = b.x0, b.x1, b.z0
    if iw then x0 = x0 + T.INSET end
    if ie then x1 = x1 - T.INSET end
    if ib then z0 = z0 + T.INSET end
    local first = b.z0 - 1 + T.SLOT_TOP / 16
    if first < b.z0 - T.SLOT_H then first = b.z0 - T.SLOT_H end
    local st = R.piece(ctx, { x0 = x0, x1 = x1, z0 = z0, z1 = b.z1, h = T.SLOT_H, g = b.g, first = first,
      sides = "front", back = bk, flanks = { w = fw, e = fe }, under = under, over = over, tag = "slots" })
    ts.stats[#ts.stats + 1] = st
  end
  -- prize counters
  local cc = {}
  for _, p in ipairs(ts.cells) do if not isSlot(pair, p) then cc[#cc + 1] = p end end
  for _, r in ipairs(rects(cc, side)) do
    local fw, iw = sideOf(r.x0 - 1, r.x0 - 1, r.y0, r.y1 - 1)
    local fe, ie = sideOf(r.x1, r.x1, r.y0, r.y1 - 1)
    local bk, ib = sideOf(r.x0, r.x1 - 1, r.y0 - 1, r.y0 - 1)
    -- a piece standing behind another piece (the U's arm): its own bottom
    -- rows are lid, not the counter's front, so its sides wear the lid rows;
    -- its sides against ours are drawn so that its inner front's edges rest
    -- on a face
    local inner = all("m", r.x0, r.x1 - 1, r.y1, r.y1)
    local sides = inner and "lid" or nil
    if inner then
      if all("m", r.x0 - 1, r.x0 - 1, r.y0, r.y1 - 1) then fw = true end
      if all("m", r.x1, r.x1, r.y0, r.y1 - 1) then fe = true end
    end
    -- (no inset here: the counter's pieces meet each other on cell borders,
    -- an inset side would leave its neighbour's edge in the open; the solid
    -- neighbours here, the prize shelves, inset their own faces)
    local _ = iw or ie or ib
    local st = R.piece(ctx, { x0 = r.x0, x1 = r.x1, z0 = r.y0, z1 = r.y1, h = T.COUNTER_H, g = r.g,
      flanks = { w = fw, e = fe }, back = bk, sides = sides, under = under, over = over, tag = "prizecounter" })
    ts.stats[#ts.stats + 1] = st
  end
end

return T
