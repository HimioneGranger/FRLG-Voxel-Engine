-- FRLG_VOXEL / interiors team: props/OneOff.lua -- one-off set pieces (wave 4,
-- 2026-10-02; scout INVENTORY "One-offs").
--
-- What this version takes (most visible first; the rest is listed in
-- RESULTS.md and left to the core / PropFix as today):
--   * the Silph Co. 1F fountain (FR_SILPH_CO_1F; offline census of all 263
--     indoor maps on the w4base tree: behaviour 0x16 occurs only there, 88
--     cells, plus the 4 cells of its two water jets, one furniture group of
--     92 cells). Today: one 92-cell box 0.45 high with the pool art on its lid.
--   * Lance's two dragon statues (FR_POKEMON_LEAGUE_LANCES_ROOM, plinths
--     (21,13) and (25,13) in the south wall row, figures in the over art of
--     the walkable cells above). Today: PropFix's 0.45 plinth box with the
--     dragon painted flat on the floor in front of it. Drawn below (T.DRAGONS).
--
-- How the fountain is drawn, through ts.lib.Relief (the picture rule: a point
-- at height Y standing at row Z shows at picture row V = Z - Y):
--   * the basin: one relief piece per column strip (adjacent columns whose
--     fountain cells span the same rows; r5: was one piece per row run), all
--     FOUNTAIN_H high (real-life fountain rim height). Each strip starts its
--     art at its north row and lays the north curb's own rows in the hidden
--     depth (spec.lid, never stretched), so the whole pool top shows the
--     picture once, continuously, shifted north by H, with one fragment per
--     source cell. Fronts, backs and flanks show the curb's own front rows 1:1
--     (the south curb's vertical band). A flank is drawn when any cell beside the
--     strip is not fountain; its other rows stand inside the neighbour strip,
--     under that strip's top (hidden, closed; no front faces inside the basin).
--   * the two water jets: each one relief piece standing in the basin on the
--     jet column's own footprint (art columns JET_C0 .. JET_C1), JET_H above
--     the water. Its foot goes FOUNTAIN_H further south and down to the floor,
--     so above the water the jet shows the picture exactly as a piece lifted
--     onto the water would (Relief's lift rule), and its bottom edges rest on
--     the floor (no open edge inside the basin). Front: the column, top: the
--     spray crown, flanks / back: the column's own middle strip.
-- Faces stand on the cell border (no inset): every cell around the fountain is
-- open floor; a face next to a solid cell would step in by INSET (wave-1
-- lesson), which the Silph fountain never needs.
-- Collision is unchanged (heightAt = false): the cells stay solid.
--
-- Method after pokeemerald-3Ds-dualscreen (ZallaxDev, MIT) through
-- props/Relief.lua (the MIT text is in Relief.lua's header): front-first relief
-- pieces at the art's own picture rows, real depth laid with the piece's own
-- rows. No code of his is copied here. Every texel is our own ROM-extracted art
-- read through the atlas. Mod sandbox: no globals; the debug, package and io
-- libraries are never used; `...` is V in the game, nil in tests. State lives
-- on ts only.
local V = ...
local _ = V

local T = {
  id = "OneOff", version = "oneoff 0.2 (2026-10-02)",
  walkable = true,       -- only for the dragons' figure cells (walkable floor whose decal we hide; nothing drawn there)
  maxWalkH = 0.05,       -- nothing of ours stands in a walkable cell
  walls = true,          -- Lance's dragon plinths stand in the south wall row (the fountain never touches a wall)
  heightAt = false,      -- collision unchanged: the fountain cells stay solid
  supersedes = { "statue" }, -- PropFix's two Lance's-room plinth entries (map rule, kind "statue"); the fountain was the core's box
  budget = 800,          -- hero piece: the fountain is one 92-cell set piece (r5: +460 net on Silph 1F, RESULTS.md)
  sourceMids = nil,      -- only the fountain's own cells and their ring
  stretchedAllowed = 0,
  windingExempt = 0,
}

-- user defaults (scout PLAN Q1: real-life heights, 1 cell = 1.6 m), one constant each
T.FOUNTAIN_H = 0.30      -- the basin rim and its water (0.48 m, a lobby fountain's seat-high rim)
T.JET_H = 1.00           -- a water jet above the water (1.6 m; its crown 2.1 m over the floor)
T.JETS = true            -- false: the jets stay painted on the water
T.INSET = 1 / 64         -- a face next to a solid cell steps in by this much (wave-1 lesson)
T.FOUNTAIN = true        -- false: take nothing (today's 0.45 box)

-- the jet's art (px, reviewed against the atlas: offline texel dump, RESULTS.md):
-- the column cell (south) carries the falling water in columns 3..12, its foot
-- after row 12; the crown cell (north) carries the spray from row 3 on.
T.JET_C0, T.JET_C1 = 3, 13      -- columns (c1 exclusive)
T.JET_TOP = 3                   -- first crown row (px, in the crown cell)
T.JET_FOOT = 13                 -- the row after the column's bottom (px, in the column cell)
T.JET_SIDE = { 6, 10 }          -- the column's plain middle strip for flanks and back (px)

-- Lance's dragon statues (FR_POKEMON_LEAGUE_LANCES_ROOM): the plinth is a
-- wall cell of the south wall row (PropFix makes it a 0.45 box), the dragon
-- the over art of the walkable cell above it (today a decal flat on the
-- floor). Drawn the gym-statue way (the Statue type's method): a relief
-- plinth PLINTH_H high with the art's 12 front rows 1:1, the dragon as a
-- closed slab of its own over art standing on the lid where the picture puts
-- its feet, a second slab across it. The plinth art is laid out like the gym
-- plinth (row 0 the dragon's feet, rows 1-3 the lid, rows 4-15 the front).
T.DRAGONS = { FR_POKEMON_LEAGUE_LANCES_ROOM = { { 21, 13 }, { 25, 13 } } }
T.PLINTH_H = 0.75        -- the plinth (1.2 m): the art's whole front (12 rows) 1:1
T.LID = { 1, 4 }         -- art rows (px) of the plinth's lid laid in the hidden depth
T.SIDE = { 12, 14 }      -- art columns (px) of the plain plinth body tiled on flanks and back
T.FIG_H = 1.0            -- the dragon: one cell of over art at 1:1 (1.6 m)
T.FIG_T = 1 / 64         -- the figure slab's thickness
T.FIG_CROSS = true       -- a second figure slab north-south (seen from the side)
T.CROSS_DY = 1 / 128     -- the cross slab stands this much higher (no coplanar rims, G6)
T.DRAGON = true          -- false: leave the dragons to PropFix (today's look)

local BEH_FOUNTAIN = 0x16
local PX = 16

local function sameGround(a, b) return math.abs((a.hgt or 0) - (b.hgt or 0)) <= 1e-9 end

-- the fountain group of cell c (pure): every cell of it unowned, solid, on one
-- ground, each a fountain cell (0x16) or a jet cell (behaviour 0); nil otherwise
local function fountainGroup(c)
  local g = c.group
  if not g or g.pillar or g.slot or not g.cells or #g.cells == 0 then return nil end
  for _, p in ipairs(g.cells) do
    if p.walkable or p.claimOwner or p.typeOwner or p.role ~= "furniture" then return nil end
    if not sameGround(p, c) then return nil end          -- mixed ground: skip (wave-2 lesson)
    if p.beh ~= BEH_FOUNTAIN and (p.beh or 0) ~= 0 then return nil end
  end
  return g
end
T._fountainGroup = fountainGroup -- (tests)

-- a dragon plinth this type takes (pure): listed for the map, still a wall
-- cell nobody owns, its figure cell above walkable with over art, one ground
local function dragonAt(ctx, mapId, x, y)
  local list = T.DRAGON and mapId and T.DRAGONS[mapId]
  if not list then return false end
  for _, d in ipairs(list) do
    if d[1] == x and d[2] == y then
      local c, f = ctx:at(x, y), ctx:at(x, y - 1)
      if not (c and f) or c.role ~= "wall" or c.claimOwner or c.typeOwner or c.inWall or c.pocket then return false end
      if not (f.walkable and f.hasOver) or f.suppressDecal then return false end
      return sameGround(c, f)
    end
  end
  return false
end
T._dragonAt = dragonAt -- (tests)

function T.applies(ctx, idx)
  return (T.FOUNTAIN and idx.byBeh[BEH_FOUNTAIN] ~= nil) or (T.DRAGON and T.DRAGONS[idx.mapId or ""] ~= nil)
end

-- PURE: every cell of each fountain group and the dragon plinths, row-major
function T.match(ctx, idx)
  local out, seen, groups = {}, {}, {}
  for _, d in ipairs((T.DRAGON and T.DRAGONS[idx.mapId or ""]) or {}) do
    if dragonAt(ctx, idx.mapId, d[1], d[2]) then
      out[#out + 1] = ctx:at(d[1], d[2] - 1)     -- the figure cell (walkable: its decal is hidden)
      out[#out + 1] = ctx:at(d[1], d[2])         -- the plinth
    end
  end
  for _, c in ipairs((T.FOUNTAIN and idx.byBeh[BEH_FOUNTAIN]) or {}) do
    local g = c.group
    if g and not seen[g] then
      seen[g] = true
      if fountainGroup(c) then groups[#groups + 1] = g end
    end
  end
  for _, g in ipairs(groups) do
    for _, p in ipairs(g.cells) do out[#out + 1] = p end
  end
  table.sort(out, function(a, b) if a.y ~= b.y then return a.y < b.y end return a.x < b.x end)
  return out
end

function T.classify(ctx, cells, ts)
  -- (r5) the core regroups the fountain's group once for the whole step
  -- (PropTypes 1.4 deferred regroup): claim in match order
  for _, p in ipairs(cells) do
    if p.walkable then
      -- a dragon's figure cell: stays walkable floor; ctx:plant below hides its decal
    elseif p.beh ~= BEH_FOUNTAIN and dragonAt(ctx, ctx.mapId, p.x, p.y) then
      -- the dragon: the core's plant helper takes the plinth out of the wall
      -- run and hides the figure cell's floor decal (its documented side
      -- write); the claim then makes it role ext (we draw plinth and figure)
      ctx:plant(p.x, p.y, true)
      ctx:claim(p.x, p.y, nil, T.PLINTH_H)
    else
      -- the fountain: role ext (the mesher draws only the ground)
      ctx:claim(p.x, p.y, nil, T.FOUNTAIN_H)
    end
  end
end

-- a cell next to the fountain that is solid (a face beside it steps in)
local function solid(ctx, x, y)
  local c = ctx:at(x, y)
  if not c or c.exitFrame then return true end
  return not c.walkable
end

-- a granted cell that is a listed dragon plinth (after classify: by the list)
local function isDragon(ctx, p)
  for _, d in ipairs((T.DRAGON and T.DRAGONS[ctx.mapId or ""]) or {}) do
    if d[1] == p.x and d[2] == p.y then return true end
  end
  return false
end

-- the basin: relief pieces per column strip (see the header)
local function basin(ctx, ts, R, under)
  local H, I = T.FOUNTAIN_H, T.INSET
  local set = {}
  for _, p in ipairs(ts.cells) do if not isDragon(ctx, p) and not p.walkable then set[p] = true end end
  local function mine(x, y) local c = ctx:at(x, y); return c ~= nil and set[c] == true end
  -- vertical runs per column: key "ya:yb" -> { columns }, then strips of
  -- adjacent columns sharing one run
  local cols, xs = {}, {}
  for _, p in ipairs(ts.cells) do
    if set[p] then
      if not cols[p.x] then cols[p.x] = {}; xs[#xs + 1] = p.x end
      cols[p.x][p.y] = true
    end
  end
  table.sort(xs)
  local runs = {}          -- list of { x, ya, yb }, column-major
  for _, x in ipairs(xs) do
    local ys = {}
    for y in pairs(cols[x]) do ys[#ys + 1] = y end
    table.sort(ys)
    local i = 1
    while i <= #ys do
      local j = i
      while j < #ys and ys[j + 1] == ys[j] + 1 do j = j + 1 end
      runs[#runs + 1] = { x = x, ya = ys[i], yb = ys[j] }
      i = j + 1
    end
  end
  local used, n = {}, 0
  for k, r in ipairs(runs) do
    if not used[k] then
      used[k] = true
      local xa, xb = r.x, r.x
      for k2 = k + 1, #runs do
        local q = runs[k2]
        if q.x == xb + 1 and q.ya == r.ya and q.yb == r.yb and not used[k2] then
          used[k2] = true; xb = q.x
        elseif q.x > xb + 1 then break end
      end
      local ya, yb = r.ya, r.yb
      -- a flank where any cell beside the strip is not ours (the rest of it is
      -- inside the neighbour strip, under its top)
      local fw, fe = false, false
      for y = ya, yb do
        if not mine(xa - 1, y) then fw = true end
        if not mine(xb + 1, y) then fe = true end
      end
      local function solidCol(x) for y = ya, yb do if not mine(x, y) and solid(ctx, x, y) then return true end end return false end
      local function solidRow(y) for x = xa, xb do if solid(ctx, x, y) then return true end end return false end
      local x0 = xa + (solidCol(xa - 1) and I or 0)
      local x1 = xb + 1 - (solidCol(xb + 1) and I or 0)
      local z0 = ya + (solidRow(ya - 1) and I or 0)
      local z1 = yb + 1 - (solidRow(yb + 1) and I or 0)
      -- north curb's own rows in the hidden depth; the top shows the picture
      -- shifted north by H, continuous along the strip; front, back and
      -- flanks = the south curb's front rows 1:1
      R.piece(ctx, { x0 = x0, x1 = x1, z0 = z0, z1 = z1, h = H, g = ctx:at(xa, yb).hgt or 0,
        flanks = { w = fw, e = fe }, back = true, sides = "front",
        first = z0, lid = { z0, z0 + H },
        under = under, tag = "oneoff:basin" })
      n = n + 1
    end
  end
  return n
end

-- the water jets: a non-fountain (jet) cell of the group with another below it
local function jets(ctx, ts, R, under)
  local set = ts.cellSet
  local H = T.FOUNTAIN_H
  local n = 0
  for _, p in ipairs(ts.cells) do
    local q = ctx:at(p.x, p.y + 1)
    if (p.beh or 0) ~= BEH_FOUNTAIN and q and set[q] and (q.beh or 0) ~= BEH_FOUNTAIN
        and not isDragon(ctx, p) and not isDragon(ctx, q) then
      -- p = the crown cell, q = the column cell
      local F = q.y + T.JET_FOOT / PX          -- the column's foot in the picture
      local first = p.y + T.JET_TOP / PX
      local h = H + T.JET_H
      local z1 = F + H                          -- the foot H further south, on the floor
      local z0 = first + h                      -- the drawn top exactly (no hidden depth)
      if z0 < z1 - 1e-9 then
        R.piece(ctx, { x0 = p.x + T.JET_C0 / PX, x1 = p.x + T.JET_C1 / PX, z0 = z0, z1 = z1,
          h = h, g = q.hgt or 0, first = first,
          sideW = (T.JET_SIDE[2] - T.JET_SIDE[1]) / PX, sideU = p.x + T.JET_SIDE[1] / PX,
          back = true, flanks = { w = true, e = true },
          under = under, tag = "oneoff:jet" })
        n = n + 1
      end
    end
  end
  return n
end
T._jets = jets -- (tests)

-- the dragon figure: the over art of cell (cx, cy) at 1:1 (16 px = 1 cell)
-- as a closed slab FIG_T thick (the Statue type's figure slab, same rule).
-- axis "x": the art across x0..x1 on the plane z = plane (art facing south,
-- its mirror north); axis "z": the art across z0..z1 on the plane x = plane
-- (art facing east, its mirror west). Heights y0 .. y0 + FIG_H. The art's
-- edge rows / columns (FIG_T * 16 px, still 1:1) close the rims, so every
-- edge is shared (G5) and the two faces are FIG_T apart (G6).
local function slab(ctx, list, cx, cy, axis, a0, a1, plane, y0)
  local env = ctx.env
  local c = ctx:at(cx, cy)
  if not (c and c.mid and env.midHasOver and env.midHasOver(c.mid) and env.overRect) then return 0 end
  if env.atlas and env.atlas.isVoid and env.atlas.isVoid(c.mid) then return 0 end
  local r = env.overRect(c.mid)
  if not r then return 0 end
  local newV = ctx:newVfn()
  local du, dv = r[3] - r[1], r[4] - r[2]
  local t = T.FIG_T
  local yb, yt = y0, y0 + T.FIG_H
  local vt, vb = r[2], r[4]
  local eu, ev = t * du, t * dv
  local n = 0
  local P, ua, ub, sa, sb, nA, nB, nLo, nHi
  if axis == "x" then
    ua, ub = r[1] + (a0 - cx) * du, r[1] + (a1 - cx) * du
    P = function(al, y, ac) return al, y, ac end
    nA, nB, nLo, nHi = { 0, 0, 1 }, { 0, 0, -1 }, { -1, 0, 0 }, { 1, 0, 0 }
  else
    -- seen from the east the art's left is south: u runs from z1 to z0
    local base = cy + 2
    ua, ub = r[1] + (base - a1) * du, r[1] + (base - a0) * du
    P = function(al, y, ac) return ac, y, al end
    nA, nB, nLo, nHi = { 1, 0, 0 }, { -1, 0, 0 }, { 0, 0, -1 }, { 0, 0, 1 }
  end
  sa, sb = plane + t / 2, plane - t / 2
  local function quad(p, nrm)
    local a, b, cc = p[1], p[2], p[3]
    local e1x, e1y, e1z = b[1] - a[1], b[2] - a[2], b[3] - a[3]
    local e2x, e2y, e2z = cc[1] - a[1], cc[2] - a[2], cc[3] - a[3]
    local gx, gy, gz = e1y * e2z - e1z * e2y, e1z * e2x - e1x * e2z, e1x * e2y - e1y * e2x
    if gx * nrm[1] + gy * nrm[2] + gz * nrm[3] < 0 then p = { p[1], p[4], p[3], p[2] } end
    local vs = {}
    for i = 1, 4 do local q = p[i]; vs[i] = newV(q[1], q[2], q[3], q[4], q[5], nrm[1], nrm[2], nrm[3]) end
    local m = #list
    list[m + 1], list[m + 2], list[m + 3] = vs[1], vs[2], vs[3]
    list[m + 4], list[m + 5], list[m + 6] = vs[1], vs[3], vs[4]
    n = n + 2
  end
  local function W(al, y, ac, u, v) local X, Y, Z = P(al, y, ac); return { X, Y, Z, u, v } end
  local uLo, uHi = ua, ub
  if axis == "z" then uLo, uHi = ub, ua end
  quad({ W(a0, yb, sa, uLo, vb), W(a1, yb, sa, uHi, vb), W(a1, yt, sa, uHi, vt), W(a0, yt, sa, uLo, vt) }, nA)
  quad({ W(a1, yb, sb, uHi, vb), W(a0, yb, sb, uLo, vb), W(a0, yt, sb, uLo, vt), W(a1, yt, sb, uHi, vt) }, nB)
  quad({ W(a0, yt, sa, uLo, vt), W(a1, yt, sa, uHi, vt), W(a1, yt, sb, uHi, vt + ev), W(a0, yt, sb, uLo, vt + ev) }, { 0, 1, 0 })
  quad({ W(a0, yb, sa, uLo, vb), W(a1, yb, sa, uHi, vb), W(a1, yb, sb, uHi, vb - ev), W(a0, yb, sb, uLo, vb - ev) }, { 0, -1, 0 })
  local dLo = (uLo < uHi) and eu or -eu
  quad({ W(a0, yb, sa, uLo, vb), W(a0, yt, sa, uLo, vt), W(a0, yt, sb, uLo + dLo, vt), W(a0, yb, sb, uLo + dLo, vb) }, nLo)
  quad({ W(a1, yb, sa, uHi, vb), W(a1, yt, sa, uHi, vt), W(a1, yt, sb, uHi - dLo, vt), W(a1, yb, sb, uHi - dLo, vb) }, nHi)
  return n
end

-- the dragon statues: plinth relief piece + the figure slab(s) on its lid
local function dragons(ctx, ts, R, under, over)
  local I, H = T.INSET, T.PLINTH_H
  local n = 0
  for _, p in ipairs(ts.cells) do
    if isDragon(ctx, p) then
      local g = p.hgt or 0
      local x0, x1, z0, z1 = p.x + I, p.x + 1 - I, p.y + I, p.y + 1 - I
      R.piece(ctx, { x0 = x0, x1 = x1, z0 = z0, z1 = z1, h = H, g = g, first = p.y,
        lid = { p.y + T.LID[1] / PX, p.y + T.LID[2] / PX },
        sideW = (T.SIDE[2] - T.SIDE[1]) / PX, sideU = p.x + T.SIDE[1] / PX,
        under = under, over = over, tag = "oneoff:plinth" })
      local y0 = g + H + T.FIG_T
      local zc = math.min(math.max(p.y + H, z0 + T.FIG_T), z1 - T.FIG_T)
      slab(ctx, over, p.x, p.y - 1, "x", x0, x1, zc, y0)
      if T.FIG_CROSS then slab(ctx, over, p.x, p.y - 1, "z", z0, z1, p.x + 0.5, y0 + T.CROSS_DY) end
      n = n + 1
    end
  end
  return n
end

function T.props(ctx, ts)
  local R = ts.lib.Relief
  local under, over = ctx:buffer("opaque"), ctx:buffer("over")
  basin(ctx, ts, R, under)
  if T.JETS then jets(ctx, ts, R, under) end
  dragons(ctx, ts, R, under, over)
end

return T
