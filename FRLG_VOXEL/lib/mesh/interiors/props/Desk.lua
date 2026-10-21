-- FRLG_VOXEL / interiors team: props/Desk.lua -- computer desks, office desks
-- and lab tables (wave 3, 2026-10-02; scout INVENTORY "Computers / office
-- desks": behaviour 0x97 MB_COMPUTER, 0x93 MB_BLUEPRINT, plus the Silph Co. /
-- Rocket office desks that carry no behaviour).
--
-- What it takes: whole furniture groups, all on one ground, made only of
-- reviewed desk tiles of the room's tileset pair (T.TILES, each checked
-- against the 2D art; workspace notes):
--   * building__rom_082d4ecc (Silph Co. 2F-10F, Rocket Hideout B1F / B4F, the
--     Five Island warehouse): the white office desks and the grey blueprint
--     desks, with or without a computer / blueprint behaviour on them;
--   * oak_lab (Oak's lab, the Cinnabar lab rooms): the computer desk, the lab
--     bench with its computers, the lab tables with microscope and cup (the
--     cup, 0x9B, belongs to its host desk, PLAN 2.6) -- only groups holding a
--     0x97 / 0x93 cell;
--   * building__rom_082d4c2c (Pewter Museum 1F) and building__rom_082d4f14
--     (Safari Zone secret house): the computer desks, likewise.
-- Left to others on purpose: the Silph Co. 1F / 7F reception counters with a
-- terminal (0x80 counter cells: the Counter type's host), the Sea Cottage
-- blueprint (a wall picture, role wall), a group on two grounds (the core
-- levels such groups after the types; wave-2 lesson), any group a type
-- earlier in the registry took part of (whole groups only).
--
-- How it is drawn: one relief piece per column block of the group (the
-- group's columns grouped where they cover the same rows; every front then
-- faces open floor) through ts.lib.Relief. Real-life height (user default,
-- scout Q1): DESK_H = 0.45 cell (0.72 m), one constant, also for the lab
-- tables. FRLG draws these desks with their top over the desk's own cells and
-- the front band and legs in the walkable row in front (T.TILES kind "B"):
-- the piece then samples the art DESK_H further south (Relief `lift` with the
-- ground raised by the same amount; geometry stays on the cells, every texel
-- 1:1): the top is the art as drawn, the front band is on the front face
-- (the floor art in front is unchanged; G2). Desks whose front band is drawn
-- inside their own row (kind "I": the lab bench, the Safari / Oak computer
-- desks) use Relief as it is, unless the mesher borrowed the front tile
-- (frontMid: a one-row desk against the wall, the floor in front then drawn
-- plain), where the piece shows the borrowed rows as well.
-- Faces that would sit flush on a core face or another type's piece (a seat
-- beside the desk) step T.INSET = 1/64 cell in (wave-1 / wave-2 lesson).
--
-- Method after pokeemerald-3Ds-dualscreen (ZallaxDev, MIT) through
-- props/Relief.lua (the MIT text is in Relief.lua's header); no code of his is
-- copied here. Every texel is our own ROM-extracted art read through the atlas.
-- Mod sandbox: no globals; the debug, package and io libraries are never used;
-- `...` is V in the game, nil in tests.
local V = ...
local _ = V

local mabs, mfloor = math.abs, math.floor

local T = {
  id = "Desk", version = "desk 0.1 (2026-10-02)",
  walkable = false,
  maxWalkH = 0.56,
  walls = false,
  heightAt = false,
  supersedes = {},      -- (PropFix's EXTRA_H[0x97] / "desk" re-heights never reach type-owned groups)
  budget = 400,         -- the largest room (Rocket Hideout B1F, 3 desk groups) adds about 300
  sourceMids = nil,
  stretchedAllowed = 0,
  windingExempt = 0,
}

-- user default (scout PLAN Q1): real-life heights, 1 cell = 1.6 m.
-- desk / lab table 0.72 m (PropFix's own desk height); the art's front band
-- is 7-8 px, so the front face shows the band 1:1
T.DESK_H = 0.45
-- wave-1 lesson: a face that would sit flush on a core face steps this far in
T.INSET = 1 / 64

local BEH_COMPUTER, BEH_BLUEPRINT, BEH_CUP = 0x97, 0x93, 0x9B

-- reviewed desk tiles: pair -> { [mid] = kind }; "B" = front band drawn in the
-- row in front of the desk, "I" = inside the desk's own row.
-- need = true: a group must hold a 0x97 / 0x93 cell (the pair's tiles are not
-- desk-only elsewhere); false: any group of these tiles is a desk
T.TILES = {
  building__rom_082d4ecc = { need = false, mids = {
    -- white office desks (Silph Co., Rocket Hideout, warehouse): 699 / 707 the
    -- terminal, 708 the monitor, 919 / 920 the joints of Silph 5F's desk run
    [696] = "B", [697] = "B", [698] = "B", [699] = "B", [707] = "B", [708] = "B", [919] = "B", [920] = "B",
    -- grey desks and blueprint tables (Silph Co. 2F-10F, Rocket Hideout B1F)
    [877] = "B", [878] = "B", [879] = "B", [796] = "B", [797] = "B", [803] = "B", [804] = "B", [805] = "B",
    [904] = "B", [905] = "B", [913] = "B", [787] = "B", [788] = "B", [789] = "B", [790] = "B", [791] = "B",
    [795] = "B", [798] = "B", [799] = "B", [806] = "B", [807] = "B", [814] = "B", [815] = "B",
  } },
  oak_lab = { need = true, mids = {
    [781] = "I", [782] = "I", [783] = "I",          -- the lab bench with its computers
    [117] = "I",                                      -- Oak's / the research room's computer desk
    [111] = "B", [143] = "B", [119] = "B", [768] = "B", [127] = "B", [776] = "B", -- lab tables
  } },
  building__rom_082d4c2c = { need = true, mids = { [716] = "B", [724] = "B" } },   -- Pewter Museum 1F
  building__rom_082d4f14 = { need = true, mids = { [708] = "I", [709] = "I" } },   -- Safari Zone secret house
}

-- the machines standing on a desk (kind "B" desks only): pair -> { [mid] =
-- { u0, u1 = art columns (px), top = first art row (px from the cell's top;
-- negative = the row above, which must be this desk), foot = the row the
-- machine stands on (px) } }; measured on the 2D art (workspace notes).
-- Each is a small relief piece on the desk top, real-life height MON_H.
T.MON_H = 5 / 16      -- 0.5 m: a monitor on its stand (one constant; 0 = flat on the top)
-- the machine stands this far above the desk top: its underside (which
-- closes it, gate G5) is then not on the top's plane (test_core ZF, gate G6)
T.MON_LIFT = 1 / 128
T.THINGS = {
  building__rom_082d4ecc = {
    [708] = { u0 = 1, u1 = 13, top = 1, foot = 15 },   -- the monitor turned to the room
    [913] = { u0 = 3, u1 = 16, top = 0, foot = 16 },   -- the grey desks' monitor
    [707] = { u0 = 2, u1 = 15, top = -7, foot = 13 },  -- the terminal (its top drawn in the row above)
  },
}

local function sameGround(a, b) return mabs((a.hgt or 0) - (b.hgt or 0)) <= 1e-9 end

-- the desks of the room (pure): a desk = whole furniture groups of desk
-- tiles that touch (at the types' turn the core has not yet joined a desk's
-- rows into one group: PropFix does that later, Pewter Museum 1F)
-- -> { { cells = cells, kind = "B" | "I" } }, in row-major order of the seed
local DIRS = { { 0, -1 }, { -1, 0 }, { 1, 0 }, { 0, 1 } }
local function desks(ctx, idx)
  local P = T.TILES[idx.pair or ctx.pair or ""]
  if not P then return {} end
  local function deskCell(q, g0)
    return q and q.group and q.role == "furniture" and not q.walkable and P.mids[q.mid] ~= nil and sameGround(q, g0)
  end
  local out, seen = {}, {}
  for _, c in ipairs(idx.solid or idx.all or {}) do
    if deskCell(c, c) and not seen[c.group] then
      local queue, qi, cells = { c.group }, 1, {}
      seen[c.group] = true
      local ok, kind, has = true, nil, false
      while queue[qi] do
        local g = queue[qi]
        qi = qi + 1
        if g.pillar or g.slot then ok = false end
        for _, q in ipairs(g.cells) do
          cells[#cells + 1] = q
          local k = P.mids[q.mid]
          if not deskCell(q, c)
              or (q.beh and q.beh ~= 0 and q.beh ~= BEH_COMPUTER and q.beh ~= BEH_BLUEPRINT and q.beh ~= BEH_CUP) then
            ok = false
          else
            if kind == nil then kind = k elseif kind ~= k then ok = false end
            if q.beh == BEH_COMPUTER or q.beh == BEH_BLUEPRINT then has = true end
            for _, d in ipairs(DIRS) do
              local n = ctx:at(q.x + d[1], q.y + d[2])
              if deskCell(n, c) and not seen[n.group] then
                seen[n.group] = true
                queue[#queue + 1] = n.group
              elseif n and n.role == "wall" and P.mids[n.mid] then
                -- the desk goes on in a wall run (Pewter Museum 1F, the map's
                -- east edge: PropFix turns that cell into furniture later);
                -- taking it needs walls = true: left to the core (RESULTS.md)
                ok = false
              end
            end
          end
        end
      end
      if ok and (has or not P.need) then out[#out + 1] = { cells = cells, kind = kind } end
    end
  end
  return out
end
T._desks = desks -- (tests)

function T.applies(ctx, idx) return T.TILES[idx.pair or ctx.pair or ""] ~= nil end

-- PURE: the cells of every desk group, row-major inside each group
local function rowMajor(cells)
  local l = {}
  for i, q in ipairs(cells) do l[i] = q end
  table.sort(l, function(a, b) if a.y ~= b.y then return a.y < b.y end return a.x < b.x end)
  return l
end
function T.match(ctx, idx)
  local want = {}
  for _, d in ipairs(desks(ctx, idx)) do
    for _, c in ipairs(rowMajor(d.cells)) do want[#want + 1] = c end
  end
  return want
end

-- the column blocks of a desk (pure): columns of the group with their row
-- runs; neighbouring columns with the same runs make one block
local function blocks(cells)
  local set, cols, xs = {}, {}, {}
  for _, q in ipairs(cells) do
    set[q.y * 65536 + q.x] = q
    if not cols[q.x] then cols[q.x] = {}; xs[#xs + 1] = q.x end
    local l = cols[q.x]
    l[#l + 1] = q.y
  end
  table.sort(xs)
  local runsOf = {}
  for _, x in ipairs(xs) do
    local ys = cols[x]
    table.sort(ys)
    local runs, a, b = {}, ys[1], ys[1]
    for i = 2, #ys do
      if ys[i] == b + 1 then b = ys[i] else runs[#runs + 1] = { a, b }; a, b = ys[i], ys[i] end
    end
    runs[#runs + 1] = { a, b }
    runsOf[x] = runs
  end
  local out = {}
  for i, x in ipairs(xs) do
    for _, r in ipairs(runsOf[x]) do
      local prev = (i > 1 and xs[i - 1] == x - 1) and runsOf[x - 1] or nil
      local merged = false
      if prev then
        for _, pr in ipairs(prev) do
          if pr[1] == r[1] and pr[2] == r[2] then merged = true end
        end
      end
      if merged then
        for _, bl in ipairs(out) do
          if bl.x1 == x and bl.y0 == r[1] and bl.y1 == r[2] + 1 then bl.x1 = x + 1 end
        end
      else
        out[#out + 1] = { x0 = x, x1 = x + 1, y0 = r[1], y1 = r[2] + 1 }
      end
    end
  end
  return out, set
end
T._blocks = blocks -- (tests)

-- the column blocks cut into segments whose west and east sides each meet
-- this desk all along or nowhere (a staggered desk, Silph Co. 10F): a side
-- is then drawn or not as a whole, never two flanks back to back (test_core
-- ZF); an inner segment border has the south segment's back left out
local function segments(bl, set)
  local out = {}
  for _, b in ipairs(bl) do
    local cur, key
    for y = b.y0, b.y1 - 1 do
      local k = tostring(set[y * 65536 + b.x0 - 1] ~= nil) .. tostring(set[y * 65536 + b.x1] ~= nil)
      if k ~= key then
        cur = { x0 = b.x0, x1 = b.x1, y0 = y, y1 = y + 1, col = b }
        out[#out + 1] = cur
        key = k
      else
        cur.y1 = y + 1
      end
    end
  end
  return out
end
T._segments = segments -- (tests)

function T.classify(ctx, cells, ts)
  -- whole groups only: a group the dispatcher cut short is left to the core
  local set = ts.cellSet
  local list = {}
  for _, d in ipairs(desks(ctx, { pair = ctx.pair, solid = cells })) do
    local whole = true
    for _, c in ipairs(d.cells) do if not set[c] then whole = false end end
    if whole then list[#list + 1] = { cells = rowMajor(d.cells), kind = d.kind } end
  end
  for _, d in ipairs(list) do
    d.g = d.cells[1].hgt or 0
    local bl, cellAt = blocks(d.cells)
    d.at = cellAt
    -- the borrowed front tiles (read before the claims)
    for _, b in ipairs(bl) do
      local all = true
      for x = b.x0, b.x1 - 1 do
        local c = cellAt[(b.y1 - 1) * 65536 + x]
        if not (c and c.frontMid) then all = false end
      end
      b.borrowed = all
    end
    d.segs = segments(bl, cellAt)
    for _, c in ipairs(d.cells) do ctx:claim(c.x, c.y, nil, T.DESK_H) end
  end
  ts.desks = list
end

-- what stands at (x, y): "wall" (a straight wall run, off-map, exit frame),
-- "mine" (this desk), "floor" (walkable), "solid" (anything else: a core
-- box, a slanted wall corner, another type's piece)
local function what(ctx, at, x, y)
  if at[y * 65536 + x] then return "mine" end
  local c = ctx:at(x, y)
  if not c or c.exitFrame then return "wall" end
  if c.role == "wall" then
    local dg = ctx.diagOf
    if type(dg) == "table" and dg[c] then return "solid" end
    return "wall"
  end
  if c.walkable then return "floor" end
  return "solid"
end

-- a side (list of neighbour cells): "wall" when every one is wall; "mine"
-- when every one is this desk; else "open" with inset = any solid / wall
local function side(ctx, at, pts)
  local nWall, nMine, solid = 0, 0, false
  for _, p in ipairs(pts) do
    local w = what(ctx, at, p[1], p[2])
    if w == "wall" then nWall = nWall + 1; solid = true
    elseif w == "mine" then nMine = nMine + 1
    elseif w == "solid" then solid = true end
  end
  if nWall == #pts then return "wall", false end
  if nMine == #pts then return "mine", false end
  -- (never inset a side that also meets this desk: the tops would part)
  return "open", solid and nMine == 0
end

-- the art row in front can carry the front band (present, not void, not the
-- room's plain floor)
local function frontArt(ctx, b)
  local env = ctx.env
  local isVoid = env and env.atlas and env.atlas.isVoid
  for x = b.x0, b.x1 - 1 do
    local c = ctx:at(x, b.y1)
    if not c or c.exitFrame or not c.mid or c.mid == ctx.floorMid or (isVoid and isVoid(c.mid)) then return false end
  end
  return true
end

-- the underside of a machine on the desk top (its footprint, facing down,
-- the art of the cells it stands in, 1:1): closes the machine on the desk
local function underside(ctx, list, x0, x1, z0, z1, y)
  local rect = ctx.env and ctx.env.underRect
  if not rect then return end
  local cx = math.floor(x0)
  local za = z0
  while za < z1 - 1e-9 do
    local cy = math.floor(za + 1e-9)
    local zb = math.min(z1, cy + 1)
    local c = ctx:at(cx, cy)
    local r = c and c.mid and rect(c.mid)
    if r then
      local function u(x) return r[1] + (x - cx) * (r[3] - r[1]) end
      local function v(z) return r[2] + (z - cy) * (r[4] - r[2]) end
      ctx:hquad(list, x0, za, x1, zb, y, { u(x0), v(za), u(x1), v(zb) }, 0, -1, 0)
    end
    za = zb
  end
end

function T.props(ctx, ts)
  local R = ts.lib.Relief
  local under, over = ctx:buffer("opaque"), ctx:buffer("over")
  local H, I = T.DESK_H, T.INSET
  for _, d in ipairs(ts.desks or {}) do
    local at = d.at
    local shift = {}
    for _, b in ipairs(d.segs) do
      local col = b.col
      -- the picture shift, once per column block: front band in the row in
      -- front (kind "B") or a borrowed front tile; only where that row
      -- holds real art
      if shift[col] == nil then
        shift[col] = ((d.kind == "B" or col.borrowed) and frontArt(ctx, col)) and H or 0
      end
      local s = shift[col]
      local x0, x1, z0, z1 = b.x0, b.x1, b.y0, b.y1
      local wPts, ePts, nPts = {}, {}, {}
      for y = b.y0, b.y1 - 1 do wPts[#wPts + 1] = { b.x0 - 1, y }; ePts[#ePts + 1] = { b.x1, y } end
      for x = b.x0, b.x1 - 1 do nPts[#nPts + 1] = { x, b.y0 - 1 } end
      local wK, wIn = side(ctx, at, wPts)
      local eK, eIn = side(ctx, at, ePts)
      local nK, nIn = side(ctx, at, nPts)
      if wIn then x0 = x0 + I end
      if eIn then x1 = x1 - I end
      if nIn then z0 = z0 + I end
      R.piece(ctx, {
        x0 = x0, x1 = x1, z0 = z0 + s, z1 = z1 + s, h = H, g = d.g + s, lift = -s,
        first = z0, -- the top shows the art from the segment's first row (s = H: as drawn, no depth fill)
        back = (nK == "open"), flanks = { w = (wK == "open"), e = (eK == "open") },
        under = under, over = over, tag = "desk",
      })
      b.s = s
    end
    -- the machines on the desk top (only where the top is drawn as the art
    -- shows it, s = DESK_H: the top's rows are the picture's rows)
    local TH = T.THINGS[ctx.pair or ""]
    if TH and T.MON_H > 0 then
      local px = 1 / (R.PX or 16)
      local function segOf(x, y)
        for _, b in ipairs(d.segs) do
          if x >= b.x0 and x < b.x1 and y >= b.y0 and y < b.y1 then return b end
        end
      end
      for _, c in ipairs(d.cells) do
        local m = TH[c.mid]
        local top = m and m.top or 0
        local sg = m and segOf(c.x, c.y)
        local up = (top >= 0) or segOf(c.x, c.y - 1)
        if m and sg and sg.s == H and up and (up == true or up.s == H) then
          local first, foot = c.y + top * px, c.y + m.foot * px
          local mh = T.MON_H
          local x0, x1 = c.x + m.u0 * px, c.x + m.u1 * px
          if foot - first > mh then
            R.piece(ctx, {
              x0 = x0, x1 = x1, z0 = first, z1 = foot, h = mh, g = d.g + H + T.MON_LIFT,
              first = first, back = true, flanks = { w = true, e = true },
              under = under, over = over, tag = "monitor",
            })
            underside(ctx, under, x0, x1, first, foot, d.g + H + T.MON_LIFT)
          end
        end
      end
    end
  end
end

return T
