-- FRLG_VOXEL / interiors team: props/Kitchen.lua -- kitchen worktops (sink /
-- stove, behaviour 0x8A MB_KITCHEN), the home fridge (behaviour 0x90
-- MB_FOOD on the fridge art) and the S.S. Anne kitchen islands with the food
-- standing on them (0x99) (wave 2, 2026-10-02; scout INVENTORY "Kitchen").
--
-- What it takes:
--   * home worktops: the sink / stove pair against the back wall of almost
--     every house (one art, KIND "sink"), and the fridge beside it in the
--     houses that have one (KIND "fridge"). Today they are 4-connected with
--     the cupboard (0x89, the Cabinet type's) or the fridge, so the whole
--     group is one box at its tallest member (Player 1F: 4 cells at 0.75).
--     This type claims ONLY its own cells; the core re-derives the rest of
--     the host group's real-life height (the cupboard keeps 0.75).
--   * S.S. Anne kitchen islands: a whole furniture group whose every cell is
--     island art (sinks 0x8A, plates 0x99, plain top); the plates stay where
--     the game paints them on the island's top.
-- Left out (RESULTS.md): the Celadon restaurant's sink (it splits the
-- restaurant's L-counter group in two), the plate on that counter and the
-- plate on the restaurant table (hosts not taken), the S.S. Anne stoves and
-- plates in the strip along the south wall (pieces set into wall cells).
-- Cups (0x9B) belong to their host type; none stands on a kitchen piece.
--
-- How it draws: one relief piece per run of cells of the same kind through
-- ts.lib.Relief (method after pokeemerald-3Ds-dualscreen, ZallaxDev, MIT; the
-- licence text is in Relief.lua's header; no code of his is copied here):
-- the art's last rows on the front, the rows above on the top, the hidden
-- depth laid with a plain band of the piece's own top rows, never stretched.
-- The game draws these pieces with their foot BELOW the cell (the sink's
-- drawers and the fridge's lower door sit in the walkable tile in front,
-- which the core already draws as plain floor): the picture is taken as if
-- the foot were FOOT px further south and the finished piece is moved back
-- north by the same amount, so the footprint stays the cell and every texel
-- keeps 1:1. Every texel is the room's own ROM art read through the atlas.
--
-- User defaults (scout PLAN Q1, template section 3): real-life heights, one
-- constant each (1 cell = 1.6 m): SINK_H 0.55 (0.88 m, the core's kitchen
-- height), FRIDGE_H 1.10 (1.76 m; the art's own fridge is 26 rows = 2.6 m),
-- ISLAND_H 0.55. Faces that would sit flush on a face the core draws (a
-- cupboard beside the sink) stand INSET = 1/64 cell back from it.
-- No globals, no debug / package / io (mod sandbox); per-build state on ts.
local V = ...
local _ = V

local mabs, mfloor = math.abs, math.floor

local T = {
  id = "Kitchen", version = "kitchen 0.1 (2026-10-02)",
  walkable = false,
  maxWalkH = 0.56,
  walls = false,
  heightAt = false,
  supersedes = {},
  budget = 400,          -- a home kitchen adds about 60 triangles, the S.S. Anne kitchen about 250
  sourceMids = nil,
  stretchedAllowed = 0,
  windingExempt = 0,
}

-- user defaults: real-life heights (cells above the cell's ground)
T.SINK_H = 0.55
T.FRIDGE_H = 1.10
T.ISLAND_H = 0.55
-- cells: a face that would sit on a face of the core (or of another type)
-- steps back this far
T.INSET = 1 / 64

-- the art of each kind (px of a 16 px cell):
--   top  = first drawn row, relative to the piece's first cell row (may be < 0: the row above)
--   foot = the art's foot row, relative to the row south of the piece (the
--          picture shift: < 0 = inside the piece's last row)
--   lid  = { r0, r1 } rows (relative to the first cell row) laid in the hidden depth
--   noTop = the front alone shows the art (the fridge: its door art never lies on the top)
T.KINDS = {
  sink = { h = "SINK_H", top = 4, foot = 7, lid = { 14, 15 } },
  fridge = { h = "FRIDGE_H", foot = 8, noTop = true, lid = { -3, 0 } },
  island = { h = "ISLAND_H", top = 0, foot = -1, lid = { 0, 2 } },
}

-- tiles: the primary tileset (mids < 640, shared by every house pair) and
-- per-pair secondary tiles. Each was checked against the art (offline tile
-- sheets, RESULTS.md 3).
local SINK_PRIMARY = { [49] = true, [50] = true, [224] = true, [225] = true, [320] = true, [321] = true }
local FRIDGE_PRIMARY = { [183] = true, [279] = true }
local SINK_PAIR = {
  building__rom_082d4f74 = { [723] = true, [724] = true }, -- Lavender Volunteer House
}
local ISLAND_PAIR = {
  general__rom_082d4d94 = { [720] = true, [721] = true, [722] = true, [723] = true, [724] = true,
    [728] = true, [729] = true, [730] = true, [731] = true }, -- S.S. Anne kitchen
}
local BEH_KITCHEN, BEH_FOOD, BEH_TASTY = 0x8A, 0x90, 0x99

local function homeKind(c, pair)
  local m, b = c.mid, c.beh
  if b == BEH_KITCHEN and m then
    if m < 640 and SINK_PRIMARY[m] then return "sink" end
    local s = SINK_PAIR[pair or ""]
    if s and s[m] then return "sink" end
  elseif b == BEH_FOOD and m and m < 640 and FRIDGE_PRIMARY[m] then
    return "fridge"
  end
  return nil
end

-- a group standing on two grounds is levelled by the core after the types
-- (heightAt moves); this type never moves the ground, so it stays the core's
local function oneGround(g)
  local h0 = g.cells[1] and (g.cells[1].hgt or 0)
  for _, p in ipairs(g.cells) do
    if mabs((p.hgt or 0) - h0) > 1e-9 then return false end
  end
  return true
end

local function plainGroup(c)
  local g = c.role == "furniture" and c.group or nil
  if not g or not g.cells or g.pillar or g.slot or g.fixedH then return nil end
  return g
end

-- a home piece cell: against the back wall, the front tile walkable
local function homeCell(ctx, c, pair)
  local k = homeKind(c, pair)
  if not k then return nil end
  local g = plainGroup(c)
  if not g or not oneGround(g) then return nil end
  local n, s = ctx:at(c.x, c.y - 1), ctx:at(c.x, c.y + 1)
  if not (n and n.role == "wall" and s and s.walkable) then return nil end
  return k
end

-- an island group: every cell island art, a full rectangle, one ground
local function islandGroup(c, pair)
  local mids = ISLAND_PAIR[pair or ""]
  if not mids then return nil end
  local g = plainGroup(c)
  if not g or not oneGround(g) then return nil end
  local x0, x1, y0, y1 = math.huge, -math.huge, math.huge, -math.huge
  for _, p in ipairs(g.cells) do
    local b = p.beh
    if not mids[p.mid] or not (b == nil or b == 0 or b == BEH_KITCHEN or b == BEH_TASTY) then return nil end
    if p.x < x0 then x0 = p.x end
    if p.x > x1 then x1 = p.x end
    if p.y < y0 then y0 = p.y end
    if p.y > y1 then y1 = p.y end
  end
  if (x1 - x0 + 1) * (y1 - y0 + 1) ~= #g.cells then return nil end
  return g, x0, x1, y0, y1
end

local function rowMajor(a, b)
  if a.y ~= b.y then return a.y < b.y end
  return a.x < b.x
end

function T.applies(ctx, idx)
  return idx.byBeh[BEH_KITCHEN] ~= nil or idx.byBeh[BEH_FOOD] ~= nil
end

-- PURE: the cells wanted, row-major
function T.match(ctx, idx)
  local want, seen = {}, {}
  local pair = idx.pair or ctx.pair
  for _, beh in ipairs({ BEH_KITCHEN, BEH_FOOD }) do
    for _, c in ipairs(idx.byBeh[beh] or {}) do
      if not seen[c] and homeCell(ctx, c, pair) then seen[c] = true; want[#want + 1] = c end
    end
  end
  local groups = {}
  for _, beh in ipairs({ BEH_KITCHEN, BEH_TASTY }) do
    for _, c in ipairs(idx.byBeh[beh] or {}) do
      local g = c.group
      if g and not groups[g] then
        groups[g] = true
        if islandGroup(c, pair) then
          for _, p in ipairs(g.cells) do
            if not seen[p] then seen[p] = true; want[#want + 1] = p end
          end
        end
      end
    end
  end
  table.sort(want, rowMajor)
  return want
end

-- the pieces of a build: { kind, x0, x1, y0, y1 (exclusive ends), g, h }
-- (classify decides them on the granted cells, before the claims change
-- the groups; props draws them)
function T.classify(ctx, cells, ts)
  local pair = ctx.pair
  local granted = ts.cellSet or {}
  local pieces, used = {}, {}
  -- islands: whole groups only (a group the dispatcher cut short stays the core's)
  for _, c in ipairs(cells) do
    if not used[c] and c.group then
      local g, x0, x1, y0, y1 = islandGroup(c, pair)
      if g then
        local all = true
        for _, p in ipairs(g.cells) do if not granted[p] then all = false end end
        if all then
          for _, p in ipairs(g.cells) do used[p] = true end
          pieces[#pieces + 1] = { kind = "island", x0 = x0, x1 = x1 + 1, y0 = y0, y1 = y1 + 1,
            g = c.hgt or 0, h = T[T.KINDS.island.h], cells = g.cells }
        end
      end
    end
  end
  -- home pieces: runs of the same kind along a row
  for _, c in ipairs(cells) do
    if not used[c] then
      local k = homeCell(ctx, c, pair)
      if k then
        local run = { c }
        used[c] = true
        local x = c.x + 1
        while true do
          local q = ctx:at(x, c.y)
          if q and granted[q] and not used[q] and homeCell(ctx, q, pair) == k
              and mabs((q.hgt or 0) - (c.hgt or 0)) < 1e-9 then
            run[#run + 1] = q
            used[q] = true
            x = x + 1
          else break end
        end
        pieces[#pieces + 1] = { kind = k, x0 = c.x, x1 = x, y0 = c.y, y1 = c.y + 1,
          g = c.hgt or 0, h = T[T.KINDS[k].h], cells = run }
      end
    end
  end
  table.sort(pieces, function(a, b)
    if a.y0 ~= b.y0 then return a.y0 < b.y0 end
    return a.x0 < b.x0
  end)
  -- claim (heights first: claiming takes a cell out of its group). The
  -- ground keeps the cell's own tile unless it has over art (the mesher
  -- would lay that over art on the hidden ground too).
  local list = {}
  for _, pc in ipairs(pieces) do
    for _, p in ipairs(pc.cells) do
      local gm = p.groundMid
      if gm == nil and not p.hasOver then gm = p.mid end
      list[#list + 1] = { p = p, gm = gm, h = pc.h }
    end
  end
  for _, e in ipairs(list) do ctx:claim(e.p.x, e.p.y, e.gm, e.h) end
  local out = {}
  for _, pc in ipairs(pieces) do
    out[#out + 1] = { kind = pc.kind, x0 = pc.x0, x1 = pc.x1, y0 = pc.y0, y1 = pc.y1, g = pc.g, h = pc.h }
  end
  ts.pieces = out
end

-- what stands beside a cell: "m" a piece of this type (with its height),
-- "w" a straight wall, "o" the room's open edge (off-map / void / exit
-- frame), "f" anything else that stands (core furniture, another type's
-- piece, a plant ...), "." the open floor
local function sideFn(ctx, mineH)
  local isVoid = ctx.env.atlas and ctx.env.atlas.isVoid
  local diag = type(ctx.diagOf) == "table" and ctx.diagOf or nil
  return function(x, y)
    local c = ctx:at(x, y)
    if not c or c.exitFrame or c.mid == nil or (isVoid and isVoid(c.mid)) then return "o" end
    local h = mineH[y * 65536 + x]
    if h then return "m", h end
    if c.role == "wall" and not (diag and diag[c]) then return "w" end
    if c.role == nil and c.walkable then return "." end
    if c.role == "flat" then return "." end
    return "f"
  end
end
T._sideFn = sideFn -- (tests)

-- a side of a piece (cells xa..xb, ya..yb beside it): draw?, inset?
-- (against a lower piece of this type: drawn; against a taller one: drawn,
-- INSET back from it (the gate's edge rule wants every top edge on an edge
-- of this type, not across the taller piece's side); against one as tall:
-- not drawn; wholly against a straight wall: not drawn, the wall closes it;
-- toward the open edge: drawn; against anything else that stands: drawn,
-- INSET back from it)
local function sideRule(side, h, xa, xb, ya, yb)
  local allM, allW, anyO, anyF = true, true, false, false
  local drawM, taller = false, false
  for y = ya, yb do
    for x = xa, xb do
      local k, hh = side(x, y)
      if k ~= "m" then allM = false end
      if k ~= "w" then allW = false end
      if k == "o" then anyO = true end
      if k == "f" then anyF = true end
      if k == "m" and hh < h - 1e-9 then drawM = true end
      if k == "m" and hh > h + 1e-9 then taller = true end
    end
  end
  if allM then
    if taller then return true, true end
    return drawM, false
  end
  if allW then return false, false end
  if anyO then return true, false end
  return true, anyF
end

function T.props(ctx, ts)
  local R = ts.lib.Relief
  local PX = R.PX
  local under, over = ctx:buffer("opaque"), ctx:buffer("over")
  local pieces = ts.pieces or {}
  local mineH = {}
  for _, pc in ipairs(pieces) do
    for y = pc.y0, pc.y1 - 1 do for x = pc.x0, pc.x1 - 1 do mineH[y * 65536 + x] = pc.h end end
  end
  local side = sideFn(ctx, mineH)
  local newV = ctx:newVfn()
  local I = T.INSET
  for _, pc in ipairs(pieces) do
    local K = T.KINDS[pc.kind]
    local h = pc.h
    local s = K.foot / PX                     -- picture shift (cells)
    local fw, iw = sideRule(side, h, pc.x0 - 1, pc.x0 - 1, pc.y0, pc.y1 - 1)
    local fe, ie = sideRule(side, h, pc.x1, pc.x1, pc.y0, pc.y1 - 1)
    local bk, ib = sideRule(side, h, pc.x0, pc.x1 - 1, pc.y0 - 1, pc.y0 - 1)
    local x0, x1 = pc.x0 + (iw and I or 0), pc.x1 - (ie and I or 0)
    local z0 = pc.y0 + (ib and I or 0)
    local z1 = pc.y1
    -- the picture as if the foot stood s further south ...
    local spec = {
      x0 = x0, x1 = x1, z0 = z0 + s, z1 = z1 + s, h = h, g = pc.g,
      lid = { pc.y0 + K.lid[1] / PX, pc.y0 + K.lid[2] / PX },
      back = bk, flanks = { w = fw, e = fe },
      under = {}, over = {}, tag = "kitchen:" .. pc.kind,
    }
    if K.noTop then
      spec.first = z1 + s - h                 -- the front alone carries the art
    else
      spec.first = pc.y0 + K.top / PX
    end
    R.piece(ctx, spec)
    -- ... moved back north by s: the footprint is the cells, 1:1 kept
    for _, pair in ipairs({ { spec.under, under }, { spec.over, over } }) do
      local src, dst = pair[1], pair[2]
      for i = 1, #src do
        local v = src[i]
        dst[#dst + 1] = newV(v[1], v[2], v[3] - s, v[4], v[5], v[6], v[7], v[8])
      end
    end
  end
end

return T
