-- FRLG_VOXEL / interiors team: props/Bookshelf.lua -- bookshelves and
-- bookcases (behaviour 0x81, MB_BOOKSHELF), wave 2 "homes" (2026-10-02;
-- scout INVENTORY "Bookshelf / bookcase").
--
-- Today every bookshelf is the core's furniture box (1.2 cells = 1.92 m), the
-- book rows squashed onto its lid and the floor tile in front borrowed for its
-- front face. Here each shelf is a relief piece (props/Relief.lua, method after
-- pokeemerald-3Ds-dualscreen by ZallaxDev, MIT -- the licence text is in
-- Relief.lua's header; no code of his is copied here): the book rows stand on
-- the front at 1:1, the shelf's own top band (the art's top outline and board)
-- lies on the lid, the rest of the real depth is laid with those top rows
-- course by course (never stretched). Every texel is the room's own ROM art
-- read through the atlas; nothing is invented.
--
-- THE ART. FRLG draws a bookshelf 29 px tall: its top outline 5 px up in the
-- wall row behind, the board and both book rows over the 0x81 cell, and its
-- foot 8 px down in the walkable row in front (the "foot overhang"). The shelf
-- collides on the 0x81 cell only, so the piece stands on that cell and the
-- picture moves north by the overhang: the front face (at the cell's south
-- border) shows the art's lowest 1.2 * 16 rows down to the foot -- both book
-- rows and the bottom rail, 1:1 -- and the top band above them lies on the lid.
-- 1.2 cells is both the user's real-life height and the art's own front height
-- (19 px). Where the core already draws the front tile as plain floor (a
-- one-row shelf against the wall: its "borrowed front"), the picture is
-- complete; where it does not (free-standing / two-row shelves: Oak's Lab,
-- Celadon Condominiums, Cinnabar research room), the foot rows also stay
-- painted flat on the floor tile in front (that cell is not ours; RESULTS.md).
--
-- Taken: every bookshelf furniture group made only of 0x81 cells and their
-- "top" cells (a solid behaviour-less cell directly north of a shelf cell of the
-- group: the Condominium / Oak's Lab / Cinnabar two-row cases), on one ground.
-- NOT taken: groups shared with another furniture kind (dresser 0x8B, cabinet
-- 0x89, kitchen 0x8A, TV 0x86): taking the shelf cells out would re-height the
-- other kind's box, which belongs to its own type (RESULTS.md, Requests);
-- groups on mixed ground; pillars.
-- Mod sandbox: no globals, no debug / package / io; `...` is V (nil in tests).
local V = ...
local _ = V

local T = {
  id = "Bookshelf", version = "bookshelf 0.1 (2026-10-02)",
  walkable = false,
  maxWalkH = 0.56,
  walls = true,           -- only a drawing's top cell the core read as wall (Condominiums 3F map edge)
  heightAt = false,
  supersedes = {},
  budget = 400,
  sourceMids = nil,
  stretchedAllowed = 0,
  windingExempt = 0,
}

-- height (cells; 1 cell = 1.6 m). User default: real-life heights. A
-- bookshelf 1.92 m = the core's MB.FURNITURE_H for 0x81, unchanged.
T.SHELF_H = 1.20
-- the art's foot overhang into the walkable row in front (cells): 8 px on
-- every FRLG bookshelf drawn over a non-plain floor tile (scout art survey,
-- 2026-10-02); 0 where the tile in front is the room's plain floor
T.FOOT = 0.5
-- the art's top band (cells): the drawn shelf starts this far above the cell's
-- own top edge moved by the overhang, first row = y + overhang - TOP_BAND, i.e.
-- its top outline 5 px up in the wall row for the usual 8 px overhang (art
-- survey: every 0x81 drawing but Oak's Lab's free-standing rows, which start
-- 2 px higher and lose their outline row to the wall-row art)
T.TOP_BAND = 13 / 16
-- cells: a drawn back / flank next to something solid that is not a wall stands
-- this far inside its cell border (wave-1 lesson: never flush on a core face)
T.INSET = 1 / 64
-- flanks: the shelf's side post (cells): the outer 4 px column of the front
-- rows, tiled 1:1 along the depth. A piece that shows its back (a
-- free-standing, double-sided shelf: Oak's Lab) tiles flanks and back from a
-- whole cell of the book rows instead (BACK_W): the back reads as books, and
-- the strip costs a quarter of the courses (the triangle budget)
T.SIDE_W = 4 / 16
T.BACK_W = 1

local BEH = 0x81
local mabs = math.abs

function T.applies(ctx, idx) return idx.byBeh[BEH] ~= nil end

-- a group cell that is the same drawing: a shelf cell, or a solid
-- behaviour-less non-wall cell directly north of a shelf cell of the group
local function mate(q, g)
  if q.walkable or q.role == "wall" then return false end
  if q.beh == BEH then return true end
  if q.beh and q.beh ~= 0 then return false end
  for _, r in ipairs(g.cells) do
    if r.x == q.x and r.y == q.y + 1 and r.beh == BEH then return true end
  end
  return false
end

-- the group is taken whole or not at all
local function groupOk(g)
  if not (g and g.cells) or g.pillar then return false end
  local g0 = nil
  for _, q in ipairs(g.cells) do
    if not mate(q, g) then return false end
    if g0 == nil then g0 = q.hgt or 0 elseif mabs((q.hgt or 0) - g0) > 1e-9 then return false end
    -- a shelf directly south of another shelf of the group (a stacked pair) is
    -- not a drawing seen in FRLG: leave it to the core
    if q.beh == BEH then
      for _, r in ipairs(g.cells) do
        if r.x == q.x and r.y == q.y + 1 and r.beh == BEH then return false end
      end
    end
  end
  return true
end

-- PURE: the cells of every all-bookshelf furniture group, row-major (idx.all order)
function T.match(ctx, idx)
  local want, okG = {}, {}
  for _, c in ipairs(idx.byBeh[BEH] or {}) do
    local g = c.group
    if not c.walkable and c.role == "furniture" and g then
      if okG[g] == nil then okG[g] = groupOk(g) end
      if okG[g] then for _, q in ipairs(g.cells) do want[q] = true end end
    end
  end
  -- the drawing's top cells may still be a furniture group of their own here
  -- (PropFix joins them later): take such a group whole when every cell of it
  -- is a behaviour-less top cell directly north of a taken shelf cell, on the
  -- same ground. Oak's Lab's top row on the map edge is read as a "gate" run
  -- (no group): a gate cell is taken the same way, one cell at a time.
  local topOk = {}
  for _, c in ipairs(idx.byBeh[BEH] or {}) do
    local n = want[c] and ctx:at(c.x, c.y - 1)
    if n and not want[n] and n.role == "gate" and not n.group and not n.walkable and (n.beh or 0) == 0
      and mabs((n.hgt or 0) - (c.hgt or 0)) < 1e-9 then
      want[n] = true
    end
    local gn = n and not want[n] and n.role == "furniture" and n.group
    if gn and topOk[gn] == nil then
      local ok = (gn.cells and not gn.pillar) and true or false
      for _, q in ipairs(ok and gn.cells or {}) do
        local s = ctx:at(q.x, q.y + 1)
        if q.walkable or (q.beh and q.beh ~= 0) or not (s and s.beh == BEH and want[s])
          or mabs((q.hgt or 0) - (s.hgt or 0)) > 1e-9 then ok = false end
      end
      topOk[gn] = ok
      if ok then for _, q in ipairs(gn.cells) do want[q] = true end end
    end
  end
  -- a top row the core read partly as wall (the drawing's top cell on the map
  -- edge, Celadon Condominiums 3F (0,5)): a behaviour-less wall cell directly
  -- north of a taken shelf cell whose row neighbour is a taken top cell of
  -- the same drawing is the drawing's top cell too (PropFix joins it later)
  for _, c in ipairs(idx.byBeh[BEH] or {}) do
    local n = want[c] and ctx:at(c.x, c.y - 1)
    if n and not want[n] and n.role == "wall" and (n.beh or 0) == 0 and not n.walkable
      and mabs((n.hgt or 0) - (c.hgt or 0)) < 1e-9 then
      for _, dx in ipairs({ -1, 1 }) do
        local m, s = ctx:at(n.x + dx, n.y), ctx:at(n.x + dx, n.y + 1)
        if m and want[m] and m.beh ~= BEH and s and s.beh == BEH and want[s] then want[n] = true end
      end
    end
  end
  local out = {}
  for _, c in ipairs(idx.all) do if want[c] then out[#out + 1] = c end end
  return out
end

-- ------------------------------------------------------------ pieces
-- the foot overhang of shelf cell c: its art's foot lies on the walkable tile
-- in front unless that tile is the room's plain floor
local function overhang(ctx, c)
  local s = ctx:at(c.x, c.y + 1)
  if s and s.walkable and s.mid and s.mid ~= ctx.floorMid then return T.FOOT end
  return 0
end

-- granted cells -> pieces { x0, x1, zb, y, d, ov, g }: one per run of shelf
-- cells in a row with the same depth (d = 1 when the group's top cell stands
-- behind) and the same overhang. Built from the row-major cell list (no pairs()).
local function pieces(ctx, cells)
  local byXY = {}
  for _, p in ipairs(cells) do byXY[p.y * 65536 + p.x] = p end
  local function at(x, y) return byXY[y * 65536 + x] end
  local out, used = {}, {}
  for _, p in ipairs(cells) do
    if p.beh == BEH and not used[p] then
      local function key(q)
        local m = at(q.x, q.y - 1)
        return ((m and m.beh ~= BEH) and 1 or 0), overhang(ctx, q)
      end
      local d, ov = key(p)
      local x = p.x
      used[p] = true
      while true do
        local q = at(x + 1, p.y)
        if not (q and q.beh == BEH and not used[q]) then break end
        local d2, ov2 = key(q)
        if d2 ~= d or ov2 ~= ov then break end
        used[q] = true
        x = x + 1
      end
      out[#out + 1] = { x0 = p.x, x1 = x + 1, zb = p.y - d, y = p.y, d = d, ov = ov, g = p.hgt or 0 }
    end
  end
  return out
end
T._pieces = pieces -- (tests)

function T.classify(ctx, cells, ts)
  ts.pieces = pieces(ctx, cells)
  for _, p in ipairs(cells) do ctx:claim(p.x, p.y, nil, T.SHELF_H) end
end

-- ------------------------------------------------------------ props
local function isWall(ctx, x, y)
  local c = ctx:at(x, y)
  if not c or c.exitFrame then return true end
  if c.role ~= "wall" then return false end
  local dg = ctx.diagOf
  return not (type(dg) == "table" and dg[c])
end
-- a side of the piece: "wall" (every cell a straight wall / off-map: no face),
-- "own" (every cell ours on the same ground, or a straight wall: a neighbouring
-- piece of the same height hides it), "solid" (something solid that is not a
-- wall stands there and none of ours: its face lies on the border, so the
-- drawn face is inset), "open" (drawn on the border). A slanted wall (the
-- mesher's diagOf) does not stand on the border: drawn, not inset. A side
-- shared with one of our pieces is never inset (the fronts must meet).
local function sideKind(ctx, ts, cellsList, g)
  local allWall, allOwnOrWall, solid, own = true, true, false, false
  for _, xy in ipairs(cellsList) do
    local x, y = xy[1], xy[2]
    if not isWall(ctx, x, y) then
      allWall = false
      local c = ctx:at(x, y)
      if ts.cellSet[c] and mabs((c.hgt or 0) - g) < 1e-9 then
        own = true
      else
        allOwnOrWall = false
        if not c.walkable and c.role ~= "wall" then solid = true end
      end
    end
  end
  if allWall then
    -- a flank / back whose cells are all off the map (the room's art runs to
    -- the map edge: Celadon Condominiums 3F, Oak's Lab's top row): draw it so
    -- the piece stays closed (Relief would skip it)
    for _, xy in ipairs(cellsList) do if ctx:at(xy[1], xy[2]) then return "wall" end end
    return "open"
  end
  if allOwnOrWall then return "own" end
  if solid and not own then return "solid" end
  return "open"
end

function T.props(ctx, ts)
  local R = ts.lib.Relief
  local under, over = ctx:buffer("opaque"), ctx:buffer("over")
  local H = T.SHELF_H
  for _, pc in ipairs(ts.pieces or pieces(ctx, ts.cells)) do
    local ov = pc.ov
    local wl, el, bl = {}, {}, {}
    for y = pc.zb, pc.y do wl[#wl + 1] = { pc.x0 - 1, y }; el[#el + 1] = { pc.x1, y } end
    for x = pc.x0, pc.x1 - 1 do bl[#bl + 1] = { x, pc.zb - 1 } end
    local w, e, b = sideKind(ctx, ts, wl, pc.g), sideKind(ctx, ts, el, pc.g), sideKind(ctx, ts, bl, pc.g)
    local x0, x1, zb = pc.x0, pc.x1, pc.zb
    if w == "solid" then x0 = x0 + T.INSET end
    if e == "solid" then x1 = x1 - T.INSET end
    if b == "solid" then zb = zb + T.INSET end
    -- picture coordinates: the piece as the art draws it (foot at y + 1 + ov),
    -- moved north by ov onto its cell (lift -ov: up AND south by -ov; the ground
    -- raised by ov to keep it on the floor)
    R.piece(ctx, {
      x0 = x0, x1 = x1, z0 = zb + ov, z1 = pc.y + 1 + ov, h = H, g = pc.g + ov, lift = -ov,
      first = pc.y + ov - T.TOP_BAND,  -- the shelf's top outline row (the art's top band)
      sides = "front", sideW = (b == "open" or b == "solid") and T.BACK_W or T.SIDE_W,
      back = (b == "open" or b == "solid"),
      flanks = { w = (w == "open" or w == "solid"), e = (e == "open" or e == "solid") },
      under = under, over = over, tag = "bookshelf",
    })
  end
end

return T
