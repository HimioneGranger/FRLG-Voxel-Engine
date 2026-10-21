-- FRLG_VOXEL / interiors team: props/MartShelf.lua -- Mart shelves (0x82,
-- MB_POKEMART_SHELF) and tool racks (0x9F, "neatly lined-up tools"), wave 1
-- (2026-10-01; scout INVENTORY "Mart shelves" + "Tool racks / back shelves").
--
-- Today every shelf is the core's furniture box (1.2 for 0x82, 1.0 for 0x9F,
-- back shelves and tool racks merged into one group) with the shelf art
-- squashed onto its lid. Here each shelf is a relief piece (props/Relief.lua,
-- method after pokeemerald-3Ds-dualscreen by ZallaxDev, MIT -- see Relief.lua
-- for the licence text): the art's own rows at 1:1 stand on the front, the
-- art's top rows lie on the lid, the hidden depth is laid with those top rows
-- course by course. Every texel is the room's own ROM art read through the
-- atlas; nothing is invented, nothing stretched.
--
-- A piece = a rectangle of granted cells of ONE behaviour (4-connected; a
-- non-rectangular blob is cut into row runs). Three kinds, by where it stands:
--   wall      the cells behind it (row z0 - 1) touch the back wall / map edge:
--             the back-wall shelves, tool racks, prize shelves, lab cabinets.
--             The front reads the art from the wall row down to the foot
--             (first = foot - h, never above the wall row), so the cabinet
--             stands up as drawn. Height: WALL_H / RACK_H.
--   gondola   free-standing, two or more rows deep: the Mart / Dept gondolas
--             and glass fridges. Front = the end cap as drawn (the art's last
--             rows), lid = the drawn top, and the two long sides (the aisles)
--             carry the art's own goods column ("lid" side dressing, 1:1).
--             Height: GONDOLA_H.
--   case      free-standing, one row deep: low glass show cases (Dept 2F / 4F,
--             Mart 0x9F case, Prize Room, Condominiums). Height: CASE_H.
-- Heights: user default "real-life heights" (scout Q1); each is one constant.
-- Zallax's Mart builds the gondolas 14 px (0.875) tall; GONDOLA_H = 0.875
-- gives that reading (the goods top then shows from standing eye height).
--
-- Not drawn here: things on top (none on these tiles), the art rows that
-- the game paints on the walkable cell in front of / behind a shelf (its
-- foot or cap): those cells belong to the floor.
-- Mod sandbox: no globals, no debug / package / io; `...` is V (nil in tests).
local V = ...
local _ = V

local T = {
  id = "MartShelf", version = "martshelf 0.2 (2026-10-02)",
  walkable = false,
  maxWalkH = 0.56,
  walls = false,
  heightAt = false,
  supersedes = { "shelfbox" }, -- PropFix's Game Corner / Prize Room prize shelves (it skips role ext)
  budget = 400,
  sourceMids = nil,
  stretchedAllowed = 0,
  windingExempt = 0,
}

-- heights (cells; 1 cell = 1.6 m). User default: real-life heights.
local WALL_H = 1.20    -- back-wall shelf / cabinet 1.92 m (the core's MB height for 0x82, unchanged)
local RACK_H = 1.00    -- wall tool rack 1.6 m (the core's MB height for 0x9F, unchanged)
local GONDOLA_H = 1.20 -- free-standing gondola / glass fridge 1.92 m (today's height)
local CASE_H = 0.65    -- low glass show case 1.04 m (= the counter height)
T.H = { wall = WALL_H, rack = RACK_H, gondola = GONDOLA_H, case = CASE_H } -- (tests)
-- cells: a drawn back / flank beside something solid stands this far inside
-- its cell border, off the neighbour's face plane (G6 / test_core ZF > 0.004)
local INSET = 1 / 64

local BEH = { [0x82] = true, [0x9F] = true }
local mmax, mhuge = math.max, math.huge

function T.applies(ctx, idx) return idx.byBeh[0x82] ~= nil or idx.byBeh[0x9F] ~= nil end

-- a shelf's furniture-group mate that is the same drawing (its cap / top
-- cells): a shelf cell itself, or a solid non-wall cell without behaviour
-- standing directly BEHIND (north of) a shelf cell of the group
local function mate(q, g)
  if q.walkable or q.role == "wall" then return false end
  if q.beh and BEH[q.beh] then return true end
  if q.beh and q.beh ~= 0 then return false end
  for _, r in ipairs(g.cells) do
    if r.x == q.x and r.y == q.y + 1 and r.beh and BEH[r.beh] then return true end
  end
  return false
end
-- the shelf behaviour a cell stands for: its own, else its group's first shelf cell's
local function hostBeh(c)
  if c.beh and BEH[c.beh] then return c.beh end
  local g = c.group
  if g and g.cells then
    for _, q in ipairs(g.cells) do if q.beh and BEH[q.beh] then return q.beh end end
  end
  return nil
end

-- PURE: every non-walkable shelf / rack cell, plus the rest of its furniture
-- group when EVERY other cell of that group is part of the same drawing (so a
-- group is taken whole or not at all); row-major (idx.all order)
function T.match(ctx, idx)
  local want = {}
  local function take(list)
    for _, c in ipairs(list or {}) do
      if not c.walkable then
        want[c] = true
        local g = c.group
        if g and g.cells and not g.pillar then
          local all = true
          for _, q in ipairs(g.cells) do if not mate(q, g) then all = false end end
          if all then for _, q in ipairs(g.cells) do want[q] = true end end
        end
      end
    end
  end
  take(idx.byBeh[0x82])
  take(idx.byBeh[0x9F])
  local out = {}
  for _, c in ipairs(idx.all) do if want[c] then out[#out + 1] = c end end
  return out
end

-- ------------------------------------------------------------ pieces
local function wallOrOff(ctx, x, y)
  local c = ctx:at(x, y)
  return (not c) or c.role == "wall" or (c.exitFrame and true) or false
end

-- the granted cells -> pieces { x0, x1, z0, z1, beh, g, kind, h } (deterministic:
-- built from ts.cells in their row-major order, no pairs())
local function pieces(ctx, ts)
  local cells = ts.cells
  local byXY, hb = {}, {}
  for _, p in ipairs(cells) do byXY[p.y * 65536 + p.x] = p; hb[p] = hostBeh(p) or 0x82 end
  local function at(x, y) return byXY[y * 65536 + x] end
  local seen, out = {}, {}
  local D = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }
  for _, p in ipairs(cells) do
    if not seen[p] then
      local comp, stack = {}, { p }
      seen[p] = true
      while #stack > 0 do
        local q = stack[#stack]
        stack[#stack] = nil
        comp[#comp + 1] = q
        for k = 1, 4 do
          local r = at(q.x + D[k][1], q.y + D[k][2])
          if r and not seen[r] and hb[r] == hb[p] then seen[r] = true; stack[#stack + 1] = r end
        end
      end
      local x0, x1, y0, y1 = mhuge, -mhuge, mhuge, -mhuge
      for _, q in ipairs(comp) do
        if q.x < x0 then x0 = q.x end
        if q.x > x1 then x1 = q.x end
        if q.y < y0 then y0 = q.y end
        if q.y > y1 then y1 = q.y end
      end
      local inComp = {}
      for _, q in ipairs(comp) do inComp[q] = true end
      local rects = {}
      if #comp == (x1 - x0 + 1) * (y1 - y0 + 1) then
        rects[1] = { x0, x1, y0, y1 }
      else
        for y = y0, y1 do
          local x = x0
          while x <= x1 do
            local q = at(x, y)
            if q and inComp[q] then
              local xe = x
              while at(xe + 1, y) and inComp[at(xe + 1, y)] do xe = xe + 1 end
              rects[#rects + 1] = { x, xe, y, y }
              x = xe + 1
            else
              x = x + 1
            end
          end
        end
      end
      -- one kind for the whole component: against the back wall (a cell
      -- behind it is wall / off-map, or it stands in a wall line: walls both
      -- sides of its back row) > two or more rows deep > one row
      local back, deep = false, (y1 > y0)
      for _, r in ipairs(rects) do
        for x = r[1], r[2] do if wallOrOff(ctx, x, r[3] - 1) then back = true end end
        if wallOrOff(ctx, r[1] - 1, r[3]) and wallOrOff(ctx, r[2] + 1, r[3]) then back = true end
      end
      local beh = hb[p]
      local kind
      if back then kind = (beh == 0x9F) and "rack" or "wall"
      elseif deep then kind = "gondola"
      else kind = "case" end
      local g = -mhuge
      for _, q in ipairs(comp) do g = mmax(g, q.hgt or 0) end
      for _, r in ipairs(rects) do
        out[#out + 1] = { x0 = r[1], x1 = r[2] + 1, z0 = r[3], z1 = r[4] + 1, beh = beh, g = g, kind = kind,
          h = T.H[kind], wallKind = back }
      end
    end
  end
  table.sort(out, function(a, b)
    if a.z0 ~= b.z0 then return a.z0 < b.z0 end
    return a.x0 < b.x0
  end)
  return out
end
T._pieces = pieces -- (tests)

-- the piece's cell height for the claim (fallback box, topAt)
function T.classify(ctx, cells, ts)
  local ps = pieces(ctx, { cells = cells })
  ts.pieces = ps -- (classify sees the rooms' roles before PropFix: the kinds are fixed here)
  local hOf = {}
  for _, pc in ipairs(ps) do
    for y = pc.z0, pc.z1 - 1 do for x = pc.x0, pc.x1 - 1 do hOf[y * 65536 + x] = pc.h end end
  end
  for _, p in ipairs(cells) do ctx:claim(p.x, p.y, nil, hOf[p.y * 65536 + p.x] or WALL_H) end
end

-- a neighbour piece covering the whole flank at least as tall: that flank is hidden
local function flankHidden(ctx, ts, pc, x, h)
  for y = pc.z0, pc.z1 - 1 do
    local c = ctx:at(x, y)
    if not (c and ts.cellSet[c] and (c.claimH or 0) >= h - 1e-9 and math.abs((c.hgt or 0) - pc.g) < 1e-9) then
      return false
    end
  end
  return true
end

-- the column beside a piece is off the map (the room's art runs to the map
-- edge): Relief would skip that flank; draw it so the piece stays closed
local function offCol(ctx, pc, x)
  for y = pc.z0, pc.z1 - 1 do if ctx:at(x, y) then return false end end
  return true
end

-- Relief's own wall test (a slanted wall -- ctx.diagOf -- does not hide a face)
local function reliefWall(ctx, x, y)
  local c = ctx:at(x, y)
  if not c or c.exitFrame then return true end
  if c.role ~= "wall" then return false end
  local d = ctx.diagOf
  return not (type(d) == "table" and d[c])
end
-- the cells along a drawn back / flank: is any of them something solid (a box,
-- a counter, another piece, a wall) whose own face lies in that cell-border plane?
local function solidRow(ctx, y, xa, xb)
  for x = xa, xb do local c = ctx:at(x, y); if c and not c.walkable then return true end end
  return false
end
-- (a flank: a neighbour piece of ours on the same ground draws no flank toward a
-- taller piece -- flankHidden -- and the shorter piece's top edge rests on the
-- taller one's flank, so that flank stays on the border)
local function solidCol(ctx, ts, pc, x, ya, yb)
  for y = ya, yb do
    local c = ctx:at(x, y)
    if c and not c.walkable and not (ts.cellSet[c] and math.abs((c.hgt or 0) - pc.g) < 1e-9) then return true end
  end
  return false
end
local function allWallRow(ctx, y, xa, xb)
  for x = xa, xb do if not reliefWall(ctx, x, y) then return false end end
  return true
end
local function allWallCol(ctx, x, ya, yb)
  for y = ya, yb do if not reliefWall(ctx, x, y) then return false end end
  return true
end

function T.props(ctx, ts)
  local R = ts.lib.Relief
  local under, over = ctx:buffer("opaque"), ctx:buffer("over")
  for _, pc in ipairs(ts.pieces or pieces(ctx, ts)) do
    local h = pc.h
    local first, sides = pc.z0, "front"
    if pc.wallKind then
      first = mmax(pc.z0 - 1, pc.z1 - h)        -- the cabinet's own top from the wall row
    elseif pc.kind == "gondola" then
      sides = "lid"                             -- the aisles see the goods column
    end
    local fl = {}
    if flankHidden(ctx, ts, pc, pc.x0 - 1, h) then fl.w = false elseif offCol(ctx, pc, pc.x0 - 1) then fl.w = true end
    if flankHidden(ctx, ts, pc, pc.x1, h) then fl.e = false elseif offCol(ctx, pc, pc.x1) then fl.e = true end
    -- a drawn back / flank on a cell border shared with something solid would
    -- lie flush with that neighbour's own face (an opposite-facing coplanar
    -- pair): keep it INSET inside the piece instead (as Seat does)
    local x0, x1, z0 = pc.x0, pc.x1, pc.z0
    local zr1 = pc.z1 - 1
    if not allWallRow(ctx, pc.z0 - 1, pc.x0, pc.x1 - 1) and solidRow(ctx, pc.z0 - 1, pc.x0, pc.x1 - 1) then
      z0 = z0 + INSET
    end
    local fw = fl.w
    if fw == nil then fw = not allWallCol(ctx, pc.x0 - 1, pc.z0, zr1) end
    if fw and solidCol(ctx, ts, pc, pc.x0 - 1, pc.z0, zr1) then x0 = x0 + INSET; fl.w = true end
    local fe = fl.e
    if fe == nil then fe = not allWallCol(ctx, pc.x1, pc.z0, zr1) end
    if fe and solidCol(ctx, ts, pc, pc.x1, pc.z0, zr1) then x1 = x1 - INSET; fl.e = true end
    R.piece(ctx, { x0 = x0, x1 = x1, z0 = z0, z1 = pc.z1, h = h, g = pc.g, first = first, sides = sides,
      flanks = (fl.w ~= nil or fl.e ~= nil) and fl or nil, under = under, over = over, tag = "martshelf:" .. pc.kind })
  end
end

return T
