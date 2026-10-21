-- FRLG_VOXEL / interiors team: props/Statue.lua -- the gym statues (the
-- mesher's role "statue": a sign cell, MB 0x84, under a walkable cell whose
-- over art is the figure) (wave 3, 2026-10-02; scout INVENTORY "Gym statues").
--
-- Where (offline census of all 263 indoor maps on the w3base tree): 18 cells
-- on 9 maps, two each in the eight Kanto gyms and the Saffron Dojo. Every one
-- uses the same plinth art (16 x 16): row 0 the figure's feet, rows 1-3 the
-- plinth's lid, rows 4-15 its front with the name plaque. Today: a 0.55 box
-- with the plinth tile squashed onto it and two crossed figure cards.
--
-- What this version draws, per statue cell:
--   * the plinth as a Relief piece PLINTH_H high. PLINTH_H = 0.75 cells
--     (1.2 m) puts the art's 12 front rows (the whole plaque) on the front
--     1:1 and its lid rows on the top; the hidden depth is laid with the lid
--     rows 1-3 (spec.lid), never stretched.
--   * the figure (the over art of the cell above) as one closed slab FIG_T
--     thin standing on the lid at z = y + PLINTH_H: there a point of the
--     figure lands in the picture exactly where the game paints it (row
--     V = Z - Y), its feet on the lid's back row. Optionally (FIG_CROSS) a
--     second slab across it, north-south, so the figure does not vanish from
--     the side (today's crossed-card look, closed).
-- Not taken: the other 0x84 cells (wall signs and notice boards, a sign on
-- the Celadon Dept 1F counter, the Celadon Condos' boards); Lance's dragon
-- statues (wall cells PropFix owns; the OneOff type, wave 4); the Pokemon
-- Mansion statues (the Plant type draws them, same method).
--
-- Method after pokeemerald-3Ds-dualscreen (ZallaxDev, MIT) through
-- props/Relief.lua (the MIT text is in Relief.lua's header): his gym statue
-- is a relief pedestal at the art's own height with the thing on top as its
-- own piece; the closed figure slab follows our Plant type. No code of his is
-- copied here. Every texel is our own ROM-extracted art read through the
-- atlas. Mod sandbox: no globals; debug / package / io never used; `...` is V
-- in the game, nil in tests. State lives on ts only.
local V = ...
local _ = V

local T = {
  id = "Statue", version = "statue 0.1 (2026-10-02)",
  walkable = false,
  maxWalkH = 0.56,
  walls = false,
  heightAt = false,      -- collision unchanged: the cells stay solid
  supersedes = {},
  budget = 200,          -- two statues per map; measured net per map in RESULTS.md
  sourceMids = nil,      -- only the cell and the figure cell above (ring 1)
  stretchedAllowed = 0,
  windingExempt = 0,
}

-- user defaults (scout PLAN Q1: real-life heights, 1 cell = 1.6 m), one constant each
T.PLINTH_H = 0.75        -- the plinth (1.2 m): the art's whole front (12 rows) 1:1
T.LID = { 1, 4 }         -- art rows (px) of the plinth's lid laid in the hidden depth
T.SIDE = { 12, 14 }      -- art columns (px) of the plain plinth body tiled on flanks and back
T.FIG_H = 1.0           -- the figure: one cell of over art at 1:1 (1.6 m)
T.FIG_T = 1 / 64         -- the figure slab's thickness
T.FIG_CROSS = true       -- a second figure slab north-south (seen from the side)
T.CROSS_DY = 1 / 128     -- the cross slab stands this much higher: its top / bottom rims
                         -- are never coplanar with the first slab's (gate G6)
T.INSET = 1 / 64         -- every face kept off the cell border (wave-1 lesson)
T.ON = true              -- false: take nothing (today's card statues)

local BEH_SIGN = 0x84

-- a statue cell this type takes: the mesher's statue role, still unowned, its
-- figure cell above walkable with over art, and one ground height for both
local function takes(ctx, c)
  if c.role ~= "statue" or c.claimOwner or c.typeOwner or c.beh ~= BEH_SIGN then return false end
  local f = ctx:at(c.x, c.y - 1)
  if not (f and f.walkable and f.hasOver) then return false end
  if (f.hgt or 0) ~= (c.hgt or 0) then return false end   -- mixed ground: skip
  return true
end
T.takes = takes

function T.applies(ctx, idx) return T.ON and idx.byRole.statue ~= nil end

-- PURE: the statue cells, row-major (the index order)
function T.match(ctx, idx)
  local out = {}
  for _, c in ipairs(idx.byRole.statue or {}) do
    if takes(ctx, c) then out[#out + 1] = c end
  end
  return out
end

function T.classify(ctx, cells, ts)
  -- claim: role ext (the mesher draws only the ground); the figure cell's
  -- decal stays suppressed (we draw the figure)
  for _, p in ipairs(cells) do ctx:claim(p.x, p.y, nil, T.PLINTH_H) end
end

-- the figure: the over art of cell (cx, cy) at 1:1 (16 px = 1 cell) as a
-- closed slab FIG_T thick. axis "x": the art across x0..x1 on the plane
-- z = zc (art facing south, its mirror north); axis "z": the art across
-- z0..z1 on the plane x = xc (art facing east, its mirror west). Heights
-- y0 .. y0 + FIG_H. The art's edge rows / columns (FIG_T * 16 px, still 1:1)
-- close the rims, so every edge is shared (gate G5) and the two faces are
-- FIG_T apart (no coplanar pair: G6).
local function slab(ctx, list, cx, cy, axis, a0, a1, plane, y0)
  local env = ctx.env
  local c = ctx:at(cx, cy)
  if not (c and c.mid and env.midHasOver and env.midHasOver(c.mid) and env.overRect) then return 0 end
  if env.atlas and env.atlas.isVoid and env.atlas.isVoid(c.mid) then return 0 end
  local r = env.overRect(c.mid)
  if not r then return 0 end
  local newV = ctx:newVfn()
  local du, dv = r[3] - r[1], r[4] - r[2]          -- one cell of art in UV
  local t = T.FIG_T
  local yb, yt = y0, y0 + T.FIG_H
  local vt, vb = r[2], r[4]
  local eu, ev = t * du, t * dv                     -- the rim strips' width in UV (1:1)
  local n = 0
  -- point in (along, y, across) -> world; along = the art's u axis
  local P
  local ua, ub, sa, sb, nA, nB, nLo, nHi
  if axis == "x" then
    -- along x (west -> east = art left -> right), across z
    local base = cx
    ua, ub = r[1] + (a0 - base) * du, r[1] + (a1 - base) * du
    P = function(al, y, ac) return al, y, ac end
    sa, sb = plane + t / 2, plane - t / 2            -- front (art) / back (mirror) planes
    nA, nB = { 0, 0, 1 }, { 0, 0, -1 }
    nLo, nHi = { -1, 0, 0 }, { 1, 0, 0 }
  else
    -- along z: seen from the east (facing west) the art's left is south, so
    -- u runs from z1 (south) to z0 (north)
    local base = cy + 2                             -- the plinth row's south edge (art left)
    ua, ub = r[1] + (base - a1) * du, r[1] + (base - a0) * du
    P = function(al, y, ac) return ac, y, al end
    sa, sb = plane + t / 2, plane - t / 2
    nA, nB = { 1, 0, 0 }, { -1, 0, 0 }
    nLo, nHi = { 0, 0, -1 }, { 0, 0, 1 }
  end
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
  -- the along-axis ends: lo = a0, hi = a1; for axis "z" a0 (north) carries ub
  local uLo, uHi = ua, ub
  if axis == "z" then uLo, uHi = ub, ua end
  -- front (the art) and back (its mirror)
  quad({ W(a0, yb, sa, uLo, vb), W(a1, yb, sa, uHi, vb), W(a1, yt, sa, uHi, vt), W(a0, yt, sa, uLo, vt) }, nA)
  quad({ W(a1, yb, sb, uHi, vb), W(a0, yb, sb, uLo, vb), W(a0, yt, sb, uLo, vt), W(a1, yt, sb, uHi, vt) }, nB)
  -- rims: the art's top row, bottom row, and its two edge columns
  quad({ W(a0, yt, sa, uLo, vt), W(a1, yt, sa, uHi, vt), W(a1, yt, sb, uHi, vt + ev), W(a0, yt, sb, uLo, vt + ev) }, { 0, 1, 0 })
  quad({ W(a0, yb, sa, uLo, vb), W(a1, yb, sa, uHi, vb), W(a1, yb, sb, uHi, vb - ev), W(a0, yb, sb, uLo, vb - ev) }, { 0, -1, 0 })
  local dLo = (uLo < uHi) and eu or -eu
  quad({ W(a0, yb, sa, uLo, vb), W(a0, yt, sa, uLo, vt), W(a0, yt, sb, uLo + dLo, vt), W(a0, yb, sb, uLo + dLo, vb) }, nLo)
  quad({ W(a1, yb, sa, uHi, vb), W(a1, yt, sa, uHi, vt), W(a1, yt, sb, uHi - dLo, vt), W(a1, yb, sb, uHi - dLo, vb) }, nHi)
  return n
end
T._slab = slab -- (tests)

function T.props(ctx, ts)
  local R = ts.lib.Relief
  local under, over = ctx:buffer("opaque"), ctx:buffer("over")
  local I, H, PX = T.INSET, T.PLINTH_H, 16
  for _, p in ipairs(ts.cells) do
    local g = p.hgt or 0
    local x0, x1, z0, z1 = p.x + I, p.x + 1 - I, p.y + I, p.y + 1 - I
    R.piece(ctx, { x0 = x0, x1 = x1, z0 = z0, z1 = z1, h = H, g = g, first = p.y,
      lid = { p.y + T.LID[1] / PX, p.y + T.LID[2] / PX },
      -- flanks and back: the plinth's plain grey body (front columns
      -- SIDE[1] .. SIDE[2]), not the plaque again
      sideW = (T.SIDE[2] - T.SIDE[1]) / PX, sideU = p.x + T.SIDE[1] / PX,
      under = under, over = over, tag = "statue:plinth" })
    -- the figure stands FIG_T over the lid (no coplanar pair with it), its
    -- plane where the picture puts the figure's feet: z = y + PLINTH_H
    local y0 = g + H + T.FIG_T
    local zc = math.min(math.max(p.y + H, z0 + T.FIG_T), z1 - T.FIG_T)
    slab(ctx, over, p.x, p.y - 1, "x", x0, x1, zc, y0)
    if T.FIG_CROSS then
      slab(ctx, over, p.x, p.y - 1, "z", z0, z1, p.x + 0.5, y0 + T.CROSS_DY)
    end
  end
end

return T
