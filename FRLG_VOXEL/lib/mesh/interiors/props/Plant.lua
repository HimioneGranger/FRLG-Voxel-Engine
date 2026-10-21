-- FRLG_VOXEL / interiors team: props/Plant.lua -- the mesher's "plant" cells
-- (role p: a solid cell under a walkable over-art cell whose over art is
-- >= 15% green) (wave 2, 2026-10-02; scout INVENTORY "Potted plants").
--
-- What this version does. The offline census of all 263 indoor maps on the
-- wave-1 base finds 422 plant cells in 69 (tileset, pot tile, leaf tile)
-- combinations (contact sheet: OUT\census\plant_sheet.png). 416 of them are
-- real potted plants, bushes and planters; the mesher's crossed pot + leaf
-- cards already read well there, so those cells are NOT taken: they keep
-- today's look exactly (and PropFix keeps its plant entries).
-- The other 6 are the mesher's misfires, taken and redrawn here:
--   * the player's bed foot (FR_PLAYERS_HOUSE_2F (2,6), player_house 660,
--     leaves = 652, the green blanket): today a crossed pair of bed-picture
--     cards standing on the bed. Drawn as a low footboard block (BED_H) with
--     the Relief builder: the bed's own front rows on the front, its top rows
--     on the lid.
--   * the Pokemon Mansion statues (building__rom_082d4f2c 796 under 788 and
--     812 under 790; Mansion 1F / 2F / 3F / B1F, 5 cells): a green plinth
--     with a figure on it, today a crossed pair of plinth cards and a crossed
--     pair of figure cards. Drawn as a statue: a relief plinth (PLINTH_H) and
--     the figure as ONE upright card standing on it at 1:1 (16 px = 1 cell):
--     a closed slab 1/64 cell thin (the art facing south, its mirror north,
--     the art's edge pixels on the rims) so every edge is shared (gate G5)
--     and no two faces are coplanar (G6, suite ZF / R3).
-- A cell is only asked for while it still has the plant role and no owner,
-- so a type earlier in Registry.lua that takes it (Bed for the bed foot, a
-- later Statue type for the Mansion statues) gets it without an overlap.
--
-- Method after pokeemerald-3Ds-dualscreen (ZallaxDev, MIT) through
-- props/Relief.lua (the MIT text is in Relief.lua's header): relief piece for
-- the block parts, an upright card for the thin figure. No code of his is
-- copied here. Every texel is our own ROM-extracted art read through the
-- atlas. Mod sandbox: no globals; debug / package / io never used; `...` is V
-- in the game, nil in tests. State lives on ts only.
local V = ...
local _ = V

local T = {
  id = "Plant", version = "plant 0.1 (2026-10-02)",
  walkable = false,
  maxWalkH = 0.56,
  walls = false,
  heightAt = false,      -- collision unchanged: the cells stay solid
  supersedes = {},
  budget = 120,          -- per map today: +6 (bed foot) .. +32 (two statues) net (RESULTS.md)
  sourceMids = nil,      -- only the cell and the leaf cell above (ring 1)
  stretchedAllowed = 0,
  windingExempt = 0,
}

-- user defaults (scout PLAN Q1: real-life heights, 1 cell = 1.6 m), one constant each
T.BED_H = 0.28           -- the bed foot block (0.45 m; the Seat type's seat height)
T.PLINTH_H = 0.55        -- the statue plinth (0.88 m; the core's STATUE_PLINTH_H)
T.FIG_Z = 0.5            -- the figure card's plane inside the cell (cells from its north edge)
T.INSET = 1 / 64         -- every face kept off the cell border (wave-1 lesson)
T.FIX = true             -- false: take nothing (today's look for the 6 misfires too)

-- the misfires: pair -> pot mid -> { leaf mid, kind }
local MISFIRE = {
  player_house = { [660] = { 652, "bed" } },
  building__rom_082d4f2c = { [796] = { 788, "statue" }, [812] = { 790, "statue" } },
}
T.MISFIRE = MISFIRE

local function kindOf(ctx, c)
  local byPair = MISFIRE[ctx.pair]
  local e = byPair and byPair[c.mid]
  if not e then return nil end
  local top = ctx:at(c.x, c.y - 1)
  if not (top and top.mid == e[1]) then return nil end
  return e[2]
end
T.kindOf = kindOf

function T.applies(ctx, idx)
  return T.FIX and MISFIRE[idx.pair] ~= nil and idx.byRole.plant ~= nil
end

-- PURE: the misfired plant cells still holding the plant role, row-major
function T.match(ctx, idx)
  local out = {}
  for _, c in ipairs(idx.byRole.plant or {}) do
    if c.role == "plant" and not c.claimOwner and not c.typeOwner and kindOf(ctx, c) then
      out[#out + 1] = c
    end
  end
  return out
end

function T.classify(ctx, cells, ts)
  for _, p in ipairs(cells) do
    local k = kindOf(ctx, p)
    -- claim: role ext (the mesher draws only the ground); the leaf cell's
    -- decal stays suppressed (the bed's blanket / the figure: see RESULTS.md)
    ctx:claim(p.x, p.y, nil, k == "bed" and T.BED_H or T.PLINTH_H)
  end
end

-- the figure: the over art of cell (cx, cy) at 1:1 (16 px = 1 cell) as a
-- thin closed slab FIG_T thick centred on plane z, x0..x1, from height y0:
-- the art on the south face, its mirror on the north face, and the art's
-- edge rows / columns (FIG_T * 16 px wide, still 1:1) on the four rims, so
-- every edge is shared (gate G5) and the two faces are FIG_T apart (no
-- coplanar pair: gate G6, suite ZF / R3)
T.FIG_T = 1 / 64
local function figureSlab(ctx, list, cx, cy, x0, x1, z, y0)
  local env = ctx.env
  local c = ctx:at(cx, cy)
  if not (c and c.mid and env.midHasOver and env.midHasOver(c.mid) and env.overRect) then return 0 end
  if env.atlas and env.atlas.isVoid and env.atlas.isVoid(c.mid) then return 0 end
  local r = env.overRect(c.mid)
  if not r then return 0 end
  local newV = ctx:newVfn()
  local du, dv = r[3] - r[1], r[4] - r[2]          -- one cell of art in UV
  local function u(x) return r[1] + (x - cx) * du end
  local t = T.FIG_T
  local zs, zn = z + t / 2, z - t / 2
  local yb, yt = y0, y0 + 1.0
  local vt, vb = r[2], r[4]
  local n = 0
  -- quad p1..p4 (each { x, y, z, u, v }) with normal nrm, wound counter-clockwise from nrm
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
  local ua, ub = u(x0), u(x1)
  local eu, ev = t * du, t * dv                     -- the rim strips' width in UV (1:1)
  -- south (the art) and north (its mirror)
  quad({ { x0, yb, zs, ua, vb }, { x1, yb, zs, ub, vb }, { x1, yt, zs, ub, vt }, { x0, yt, zs, ua, vt } }, { 0, 0, 1 })
  quad({ { x1, yb, zn, ub, vb }, { x0, yb, zn, ua, vb }, { x0, yt, zn, ua, vt }, { x1, yt, zn, ub, vt } }, { 0, 0, -1 })
  -- rims: top row, bottom row, west column, east column of the art
  quad({ { x0, yt, zs, ua, vt }, { x1, yt, zs, ub, vt }, { x1, yt, zn, ub, vt + ev }, { x0, yt, zn, ua, vt + ev } }, { 0, 1, 0 })
  quad({ { x0, yb, zs, ua, vb }, { x1, yb, zs, ub, vb }, { x1, yb, zn, ub, vb - ev }, { x0, yb, zn, ua, vb - ev } }, { 0, -1, 0 })
  quad({ { x0, yb, zs, ua, vb }, { x0, yt, zs, ua, vt }, { x0, yt, zn, ua + eu, vt }, { x0, yb, zn, ua + eu, vb } }, { -1, 0, 0 })
  quad({ { x1, yb, zs, ub, vb }, { x1, yt, zs, ub, vt }, { x1, yt, zn, ub - eu, vt }, { x1, yb, zn, ub - eu, vb } }, { 1, 0, 0 })
  return n
end
T._figure = figureSlab -- (tests)

function T.props(ctx, ts)
  local R = ts.lib.Relief
  local under, over = ctx:buffer("opaque"), ctx:buffer("over")
  local I = T.INSET
  for _, p in ipairs(ts.cells) do
    local k = kindOf(ctx, p)
    local g = p.hgt or 0
    local x0, x1, z0, z1 = p.x + I, p.x + 1 - I, p.y + I, p.y + 1 - I
    if k == "bed" then
      R.piece(ctx, { x0 = x0, x1 = x1, z0 = z0, z1 = z1, h = T.BED_H, g = g, first = p.y,
        under = under, over = over, tag = "plant:bed" })
    elseif k == "statue" then
      R.piece(ctx, { x0 = x0, x1 = x1, z0 = z0, z1 = z1, h = T.PLINTH_H, g = g, first = p.y,
        under = under, over = over, tag = "plant:plinth" })
      -- the figure stands FIG_T over the plinth lid (no coplanar pair with it)
      figureSlab(ctx, over, p.x, p.y - 1, x0, x1, p.y + T.FIG_Z, g + T.PLINTH_H + T.FIG_T)
    end
  end
end

return T
