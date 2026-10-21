-- FRLG_VOXEL / interiors team: props/Crate.lua -- crates, box stacks and the
-- Sea Cottage paper baskets (wave 4, 2026-10-02; scout INVENTORY "Crates /
-- boxes", PLAN wave 4: supersedes PropFix "crate", "box", "basket").
--
-- THE ART. FRLG draws a cardboard crate like this (metatile 153, the primary
-- tileset, the same picture in every building pair listed below): a 1 px
-- outline row, 8 rows of lid, then 7 rows of front (a highlight row, the
-- front, the bottom outline). Long lines of crates are lid tiles (917: two
-- 8-row lids) ending in a 153; a stack two crates high shows two fronts
-- (914 / the condominiums' 693: 2 x 8 rows). So a column of crate cells reads,
-- top to bottom, as lid bands then front bands: one crate object per
-- lid-then-front run, its crates = its front rows (7 px = one crate,
-- 7 + 16 px = three; height T.CRATE_H each), its footprint = the cells it covers (the
-- collision cells), the lid rows repeated over the hidden depth (Relief).
-- The crate fills its tile edge to edge (outline in columns 0 and 15).
--
-- Taken (pure functions of the map's cells, row-major):
--   * crate cells in a wall run (the mesher's 2.0-tall walls): the whole run
--     when it is all crate art; on the maps PropFix's tile rules already cover
--     (Five Island warehouse, Sea Cottage, Condominiums 3F: PropFix unwalls
--     exactly these cells in the base) any crate block of a run; elsewhere a
--     block that is the BOTTOM of its run with a walkable cell in front and
--     the run above it hidden (wall both sides and behind: the Machine rule) --
--     the core closes the wall left above it;
--   * furniture groups made only of crate cells on one ground;
--   * in a mixed group (T.MIXED pairs: the Cinnabar lab, the fossil machine's
--     group holds a crate) the crate cells whose column block is a complete
--     crate, claimed out of the group (the core re-derives the host's
--     real-life height; group rule: we never change a group we do not own).
-- NOT taken: Silph Co.'s storage floors (4F / 5F / 6F / 10F: crates and the
-- orange cargo containers are one furniture group, and two tiles (915 / 916)
-- hold a container's foot AND a crate's lid; T.SILPH_MIXED, RESULTS.md); the
-- Sea Cottage boxes (5, 3) / (6, 3) inside the Cell Separator's wall drawing;
-- the warehouse / Rocket Hideout orange cargo crates (other art, RESULTS.md).
--
-- How it is drawn: one relief piece per crate object through ts.lib.Relief
-- (method after pokeemerald-3Ds-dualscreen, ZallaxDev, MIT; the licence text
-- is in Relief.lua's header; no code of that project is copied here). Every
-- texel is the player's own ROM-extracted art read through the atlas, 1:1.
-- Equal objects in neighbouring columns are one piece. A face next to
-- something solid that is not ours stands T.INSET inside the cell; next to
-- the map edge / void T.EDGE_INSET (clear of the synthetic walls, 0.06).
-- Mod sandbox: no globals, no debug / package / io; `...` is V (nil in tests).
local V = ...
local _ = V

local T = {
  id = "Crate", version = "crate 0.2 (2026-10-02)",
  walkable = false,
  maxWalkH = 0.56,
  walls = true,        -- most crates are meshed as 2.0-tall wall runs today
  heightAt = false,
  supersedes = { "crate", "box", "basket" },
  budget = 400,        -- per map: +4 (Sea Cottage) .. +108 (Five Island warehouse); RESULTS.md
  sourceMids = nil,
  stretchedAllowed = 0,
  windingExempt = 0,
}

-- ------------------------------------------------------------------ constants
-- user default (scout PLAN Q1): real-life heights, not the art's rows. One
-- crate = 0.60 cell = 0.96 m (PropFix's warehouse crate, which this type
-- supersedes; the interiors suites check it); a stack = its crates (one
-- crate per 8 front rows of art, rounded). Zallax's art-row height would be
-- 7/16 (the 153 front): set T.CRATE_H = nil to take the art's front rows.
T.CRATE_H = 0.60
T.PX_H = 1 / 16       -- (T.CRATE_H = nil) front rows -> cells, 1:1
-- the paper basket (Sea Cottage 688 / 691): 0.30 cell = 0.48 m (PropFix's
-- basket); its body columns c0..c1 (px), foot row (px), back row (px)
T.BASKET = { c0 = 1, c1 = 14, foot = 15, back = 2, h = 0.30 }
-- insets (cells): next to solid non-wall things not ours (wave-1 lesson), and
-- next to the map edge / void (> the synthetic wall inset 0.06)
T.INSET = 1 / 64
T.EDGE_INSET = 0.08
-- mixed furniture groups: crate cells taken out of them per pair. Off: the
-- Cinnabar fossil machine's group (oak_lab) would lose its crate cell and the
-- core re-meshes the host's merged lid outside our cell (G2); RESULTS.md
-- Requests (a joint Machine + Crate rule). true per pair turns it on.
T.MIXED = {}
-- Silph Co. storage floors: crates in the container groups (off: RESULTS.md)
T.SILPH_MIXED = false

-- bands of a tile, top to bottom: { first row, end row (exclusive), kind }
-- "L" lid (outline included), "F" front
local CRATE = { { 0, 9, "L" }, { 9, 16, "F" } }   -- 153: one crate
local LIDS = { { 0, 16, "L" } }                    -- 917: two lids
local FRONTS = { { 0, 16, "F" } }                  -- 914 / 693: two fronts
T.ART = {
  building__rom_082d4ecc = { [153] = CRATE, [917] = LIDS, [914] = FRONTS },   -- Silph, Rocket Hideout, warehouse
  oak_lab = { [153] = CRATE },                                                -- Cinnabar lab
  building__rom_082d4eb4 = { [153] = CRATE, [691] = "basket", [688] = "basket" }, -- Sea Cottage
  building__rom_082d4f8c = { [153] = CRATE, [693] = FRONTS },                 -- Celadon Condominiums
}
-- maps whose PropFix tile rules take every crate cell of a wall run in the
-- base: true = take every crate block of a run (the same cells PropFix
-- unwalls, so the room's runs end up as in the base); false = take no wall
-- cell there. 0.2 (w0r5 base): the shared snapshots treat a PropFix-planned
-- cell a type takes as PropFix's unwall (wallpaper hook, Ceiling.propfixMade),
-- so Sea Cottage and the Condominiums 3F stack are taken too (R1)
T.PROPFIX_MAPS = {
  FR_FIVE_ISLAND_ROCKET_WAREHOUSE = true,
  FR_ROUTE_25_SEA_COTTAGE = true,
  FR_CELADON_CITY_CONDOMINIUMS_3F = true,
}
local SILPH = "building__rom_082d4ecc"

local mabs, mfloor, mmax = math.abs, math.floor, math.max
local function key(x, y) return y * 65536 + x end

local function artOf(pair, c)
  local t = T.ART[pair or ""]
  return t and c and c.mid and t[c.mid] or nil
end

function T.applies(ctx, idx)
  local t = T.ART[idx.pair or ""]
  if not t then return false end
  for mid in pairs(t) do if idx.byMid[mid] then return true end end
  return false
end

local function sameG(a, b) return mabs((a.hgt or 0) - (b.hgt or 0)) < 1e-9 end
local function free(c)
  return c and not c.walkable and c.role ~= "ext" and not c.claimOwner and not c.inWall and not c.pocket
    and not c.exitFrame and not c.isDoor and not c.stair
end

-- a straight wall cell, or off the map (a run's hidden side)
local function hidden(ctx, x, y)
  local q = ctx:at(x, y)
  return q == nil or q.exitFrame or (q.role == "wall" and not q.inWall and not q.pocket)
end

-- column block (cells top..bottom) -> list of objects { top, foot, front }
-- (rows in px from the block's first row); nil when the block is not whole
-- crates (a lid with no front below it, a front with no lid above)
local function parse(pair, cells)
  local objs, cur = {}, nil
  local last = nil
  for i, c in ipairs(cells) do
    local a = artOf(pair, c)
    if type(a) ~= "table" then return nil end
    for _, b in ipairs(a) do
      local r0, r1 = (i - 1) * 16 + b[1], (i - 1) * 16 + b[2]
      if b[3] == "L" then
        if cur == nil or last == "F" then
          if cur and cur.front == 0 then return nil end
          cur = { top = r0, foot = r1, front = 0 }
          objs[#objs + 1] = cur
        end
        cur.foot = r1
      else
        if cur == nil then return nil end
        cur.foot = r1
        cur.front = cur.front + (r1 - r0)
      end
      last = b[3]
    end
  end
  if cur == nil or cur.front == 0 then return nil end
  return objs
end
T._parse = parse -- (tests)

-- the units: lists of column blocks { x, y0, y1, cells } (pure)
local function crateCell(pair, c) return type(artOf(pair, c)) == "table" end

-- a wall block (x, a..b) inside one run may be taken
local function wallBlockOk(ctx, idx, x, a, b)
  local c0 = ctx:at(x, a)
  local ra, rb = c0.runA, c0.runB
  if ra == nil or rb == nil then return false end
  local pf = T.PROPFIX_MAPS[idx.mapId or ""]
  if pf ~= nil then return pf end
  -- a walkable cell in front, on the map (a run on the map's edge row would
  -- move the synthetic edge wall and re-triangulate the ceiling: G2)
  local s = ctx:at(x, b + 1)
  if not (s and s.walkable and not s.exitFrame and sameG(s, c0)) then return false end
  if a == ra and b == rb then return true end
  -- pull out of the bottom of a run
  if b ~= rb then return false end
  if not hidden(ctx, x, ra - 1) then return false end
  for y = ra, a - 1 do
    if not (hidden(ctx, x - 1, y) and hidden(ctx, x + 1, y)) then return false end
  end
  return true
end

local function units(ctx, idx)
  local pair = idx.pair or ctx.pair
  local art = T.ART[pair or ""]
  local blocks = {}       -- { x, y0, y1, cells, kind = "crate" | "basket" }
  if not art then return blocks end
  local seen, okG = {}, {}
  local function groupKind(g)
    if okG[g] ~= nil then return okG[g] end
    local r = false
    if g.cells and not g.pillar and not g.slot then
      local all, g0 = true, nil
      for _, q in ipairs(g.cells) do
        if q.walkable or q.role ~= "furniture" or not crateCell(pair, q) or not free(q) then all = false end
        if g0 == nil then g0 = q.hgt or 0 elseif mabs((q.hgt or 0) - g0) > 1e-9 then r = "mixedGround" end
      end
      if r ~= "mixedGround" then
        if all then r = "pure"
        elseif T.MIXED[pair] or (pair == SILPH and T.SILPH_MIXED) then r = "mixed" end
      end
    end
    if r == "mixedGround" then r = false end
    okG[g] = r
    return r
  end
  for _, c in ipairs(idx.all) do
    local a = art[c.mid]
    if a and not seen[c] and free(c) then
      if a == "basket" then
        seen[c] = true
        local ok = false
        if c.role == "wall" then ok = c.runA ~= nil and wallBlockOk(ctx, idx, c.x, c.y, c.y)
        elseif c.role == "furniture" and c.group and #c.group.cells == 1 and not c.group.pillar then ok = true end
        if ok then blocks[#blocks + 1] = { x = c.x, y0 = c.y, y1 = c.y, cells = { c }, kind = "basket" } end
      elseif c.role == "wall" or c.role == "furniture" then
        -- the column block starting here: same role, same run / group, crate art
        local up = ctx:at(c.x, c.y - 1)
        local function same(q)
          if not (q and free(q) and crateCell(pair, q) and q.role == c.role and sameG(q, c)) then return false end
          if c.role == "wall" then return q.runA == c.runA end
          return q.group == c.group
        end
        if not same(up) then
          local list, y = { c }, c.y
          while same(ctx:at(c.x, y + 1)) do y = y + 1; list[#list + 1] = ctx:at(c.x, y) end
          for _, q in ipairs(list) do seen[q] = true end
          local ok = false
          if parse(pair, list) then
            if c.role == "wall" then
              ok = c.runA ~= nil and wallBlockOk(ctx, idx, c.x, c.y, y)
            elseif c.group then
              local k = groupKind(c.group)
              ok = (k == "pure" or k == "mixed")
            end
          end
          if ok then blocks[#blocks + 1] = { x = c.x, y0 = c.y, y1 = y, cells = list, kind = "crate", group = c.group } end
        end
      end
    end
  end
  -- a pure group is taken whole or not at all (every block must parse)
  local blocksOf, bad = {}, {}
  for _, b in ipairs(blocks) do
    if b.group then blocksOf[b.group] = (blocksOf[b.group] or 0) + #b.cells end
  end
  for g, n in pairs(blocksOf) do
    if okG[g] == "pure" and n ~= #g.cells then bad[g] = true end
  end
  local out = {}
  for _, b in ipairs(blocks) do if not (b.group and bad[b.group]) then out[#out + 1] = b end end
  return out
end
T._units = units -- (tests)

-- PURE: the cells of every unit, row-major
function T.match(ctx, idx)
  local want = {}
  for _, b in ipairs(units(ctx, idx)) do for _, q in ipairs(b.cells) do want[q] = true end end
  local out = {}
  for _, c in ipairs(idx.all) do if want[c] then out[#out + 1] = c end end
  return out
end

-- ------------------------------------------------------------ classify
-- the floor tile beside a unit (pure): the first walkable dry non-wall
-- neighbour on the same ground, S N W E, over the unit's cells in order
local DIRS = { { 0, 1 }, { 0, -1 }, { -1, 0 }, { 1, 0 } }
local function floorMid(ctx, cells)
  for _, c in ipairs(cells) do
    for _, d in ipairs(DIRS) do
      local n = ctx:at(c.x + d[1], c.y + d[2])
      if n and n.walkable and not n.isWater and n.role ~= "wall" and not n.exitFrame and n.mid
          and not n.hasOver and sameG(n, c) then
        return n.mid
      end
    end
  end
  return nil
end

-- granted blocks -> pieces { x0, x1, top, foot, h, g, kind } (cells; top /
-- foot absolute rows in cells); equal crate objects in neighbouring columns
-- merge (row-major order; no pairs())
local function pieces(ctx, pair, blocks)
  local objs = {}
  for _, b in ipairs(blocks) do
    if b.kind == "basket" then
      objs[#objs + 1] = { x0 = b.x, x1 = b.x + 1, top = b.y0, foot = b.y0 + 1, h = T.BASKET.h,
        g = b.cells[1].hgt or 0, kind = "basket" }
    else
      for _, o in ipairs(parse(pair, b.cells) or {}) do
        objs[#objs + 1] = { x0 = b.x, x1 = b.x + 1, top = b.y0 + o.top / 16, foot = b.y0 + o.foot / 16,
          h = T.CRATE_H and T.CRATE_H * mmax(1, mfloor((o.front + 4) / 8)) or o.front * T.PX_H,
          g = b.cells[1].hgt or 0, kind = "crate" }
      end
    end
  end
  table.sort(objs, function(a, b)
    if a.top ~= b.top then return a.top < b.top end
    if a.x0 ~= b.x0 then return a.x0 < b.x0 end
    return a.foot < b.foot
  end)
  local out, last = {}, nil
  for _, o in ipairs(objs) do
    if last and o.kind == "crate" and last.kind == "crate" and o.x0 == last.x1 and o.top == last.top
        and o.foot == last.foot and mabs(o.h - last.h) < 1e-9 and mabs(o.g - last.g) < 1e-9 then
      last.x1 = o.x1
    else
      out[#out + 1] = o
      last = o
    end
  end
  return out
end
T._pieces = pieces -- (tests)

function T.classify(ctx, cells, ts)
  local pair = ctx.pair
  local granted = {}
  for _, c in ipairs(cells) do granted[c] = true end
  -- the units again (pure) over the granted cells (in match order: no grid
  -- scan), kept only when every cell of a unit was granted
  local idx = { all = cells, mapId = ctx.mapId, pair = pair }
  local blocks = {}
  for _, b in ipairs(units(ctx, idx)) do
    local all = true
    for _, q in ipairs(b.cells) do if not granted[q] then all = false end end
    if all then blocks[#blocks + 1] = b end
  end
  local list = pieces(ctx, pair, blocks)
  ts.pieces = list
  -- each cell: the tallest piece over it (the fallback box height)
  local hOf = {}
  for _, p in ipairs(list) do
    for x = p.x0, p.x1 - 1 do
      for y = mfloor(p.top), math.ceil(p.foot) - 1 do
        local k = key(x, y)
        hOf[k] = mmax(hOf[k] or 0, p.h)
      end
    end
  end
  -- claim: wall cells column block by column block (one unwall per block),
  -- the rest one by one
  for _, b in ipairs(blocks) do
    local gm = floorMid(ctx, b.cells)
    for _, q in ipairs(b.cells) do
      ctx:claim(q.x, q.y, gm, hOf[key(q.x, q.y)] or T.BASKET.h)
    end
  end
end

-- ------------------------------------------------------------ props
-- what lies beside a piece along a list of cells:
-- "wall" (every cell a straight wall), "edge" (off-map / void / exit frame),
-- "solid" (something solid that is not a wall and not ours), "own" (ours),
-- "open" (anything else)
local function sideOf(ctx, ts, list)
  local isVoid = ctx.env.atlas and ctx.env.atlas.isVoid
  local allWall, allOwn, solid, edge = true, true, false, false
  for _, xy in ipairs(list) do
    local c = ctx:at(xy[1], xy[2])
    if c == nil or c.exitFrame or c.mid == nil or (isVoid and isVoid(c.mid)) then
      edge = true; allOwn = false
    else
      local dg = ctx.diagOf
      local wall = c.role == "wall" and not (type(dg) == "table" and dg[c])
      if not wall then allWall = false end
      if not ts.cellSet[c] then allOwn = false end
      if not wall and not ts.cellSet[c] and not c.walkable then solid = true end
    end
  end
  if edge then return "edge" end
  if allWall then return "wall" end
  if allOwn then return "own" end
  if solid then return "solid" end
  return "open"
end
T._sideOf = sideOf -- (tests)

function T.props(ctx, ts)
  local R = ts.lib.Relief
  local under, over = ctx:buffer("opaque"), ctx:buffer("over")
  local list = ts.pieces or {}
  -- the tallest piece over each cell, with its rows (an own neighbour hides a
  -- side only when it is at least as tall over the same rows)
  local cover = {}
  for i, p in ipairs(list) do
    for x = p.x0, p.x1 - 1 do
      for y = mfloor(p.top), math.ceil(p.foot) - 1 do
        local k = key(x, y)
        local o = cover[k]
        if not o or list[o].h < p.h then cover[k] = i end
      end
    end
  end
  -- an own side: every cell under a piece of ours at least as tall over the
  -- same span (rows for a flank, columns for the back / front): no face, no
  -- inset; a piece of ours over a different span counts as solid (inset and
  -- drawn: its edges would otherwise end inside our face, G5)
  local function ownSame(cells, p, flank)
    for _, xy in ipairs(cells) do
      local j = cover[key(xy[1], xy[2])]
      if not j then return false end
      local q = list[j]
      if q.h < p.h - 1e-9 then return false end
      if flank and (mabs(q.top - p.top) > 1e-9 or mabs(q.foot - p.foot) > 1e-9) then return false end
      if not flank and (q.x0 ~= p.x0 or q.x1 ~= p.x1) then return false end
    end
    return true
  end
  local function anyOwn(cells)
    for _, xy in ipairs(cells) do if cover[key(xy[1], xy[2])] then return true end end
    return false
  end
  for _, p in ipairs(list) do
    local ya, yb = mfloor(p.top), math.ceil(p.foot) - 1
    local wl, el, bl, fl = {}, {}, {}, {}
    for y = ya, yb do wl[#wl + 1] = { p.x0 - 1, y }; el[#el + 1] = { p.x1, y } end
    for x = p.x0, p.x1 - 1 do bl[#bl + 1] = { x, ya - 1 }; fl[#fl + 1] = { x, yb + 1 } end
    local w, e, b, f = sideOf(ctx, ts, wl), sideOf(ctx, ts, el), sideOf(ctx, ts, bl), sideOf(ctx, ts, fl)
    -- (a side partly ours over another span: inset too, never two flanks on
    -- one plane -- the suites count those as coplanar pairs)
    if (w == "own" and not ownSame(wl, p, true)) or (w == "open" and anyOwn(wl)) then w = "solid" end
    if (e == "own" and not ownSame(el, p, true)) or (e == "open" and anyOwn(el)) then e = "solid" end
    if (b == "own" and not ownSame(bl, p, false)) or (b == "open" and anyOwn(bl)) then b = "solid" end
    if (f == "own" and not ownSame(fl, p, false)) or (f == "open" and anyOwn(fl)) then f = "solid" end
    local x0, x1, z0, z1 = p.x0, p.x1, p.top, p.foot
    local fw, fe, bk = (w ~= "wall" and w ~= "own"), (e ~= "wall" and e ~= "own"), (b ~= "wall" and b ~= "own")
    if w == "edge" then x0 = x0 + T.EDGE_INSET elseif w == "solid" then x0 = x0 + T.INSET end
    if e == "edge" then x1 = x1 - T.EDGE_INSET elseif e == "solid" then x1 = x1 - T.INSET end
    -- against a wall behind: open flanks stand T.INSET in (the core's wall
    -- trim posts reach 0.1 into the row in front of the wall, the warehouse)
    -- (not beside a piece of ours: its edges meet ours on the cell border)
    if b == "wall" then
      if fw and w == "open" then x0 = x0 + T.INSET end
      if fe and e == "open" then x1 = x1 - T.INSET end
    end
    if b == "edge" then z0 = z0 + T.EDGE_INSET elseif b == "solid" then z0 = z0 + T.INSET end
    if f == "edge" then z1 = z1 - T.EDGE_INSET elseif f == "solid" or f == "wall" then z1 = z1 - T.INSET end
    if p.kind == "basket" then
      local s, px = T.BASKET, 1 / 16
      R.piece(ctx, { x0 = p.x0 + s.c0 * px, x1 = p.x0 + s.c1 * px, z0 = p.top + s.back * px,
        z1 = p.top + s.foot * px, h = s.h, g = p.g, first = p.top,
        flanks = { w = true, e = true }, back = true, under = under, over = over, tag = "basket" })
    else
      R.piece(ctx, { x0 = x0, x1 = x1, z0 = z0, z1 = z1, h = p.h, g = p.g, first = p.top,
        -- flanks / back: the 16 px front strip of the piece's own first
        -- column (whole cells: the courses meet the cell borders)
        sideW = 1, sideU = p.x0,
        flanks = { w = fw, e = fe }, back = bk, under = under, over = over, tag = "crate" })
    end
  end
end

return T
