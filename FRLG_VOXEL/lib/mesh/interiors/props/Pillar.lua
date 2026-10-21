-- FRLG_VOXEL / interiors team: props/Pillar.lua -- indoor pillars and columns
-- (the mesher's pillar groups: role "furniture", group.pillar, no furniture
-- behaviour) (wave 4, 2026-10-02; scout INVENTORY "Pillars / columns").
--
-- Where (offline census on the w4base tree): 22 pillars, 50 cells, on 4 maps
-- -- Pokemon Mansion 1F (four 2-row and six 3-row columns), Lorelei's room
-- (ice block stacks), Bruno's room (boulder stacks) and Agatha's room (glass
-- lamp tubes), four 2-row pillars in each Elite Four room. Each is one cell
-- wide; its art stands on the bottom cell, its rows painted up the cells
-- above, its top (the capital) in the over art of the walkable cell above
-- the group. Today: a column on the bottom cell with every art row squashed
-- into an equal slice (PILLAR_ROW_H 0.55 a row, PropFix caps the 3-row ones
-- at 1.65 as "pedestals").
--
-- What this version draws, per pillar: ONE Relief piece on the bottom cell
-- (inset T.INSET), PILLAR_H high -- 1.65 (2.64 m): the core's rule that no
-- non-wall piece reaches the ceiling (PropFix PEDESTAL_GAP 0.35 under the
-- room's 2.0), today's column height. Its front is the last PILLAR_H * 16 art rows above
-- the foot, 1:1 (never squashed); its top is the art rows just above those
-- at 1:1 over exactly the piece's depth (spec.first = z1 - h - depth: no
-- hidden-depth courses); flanks and back repeat the front rows 1:1. The other
-- cells of the group keep the mesher's ground (they were floor under the
-- art's upper rows already) and stay solid: collision is unchanged. At
-- 1.65 the top lands on the art's own top: the Mansion's pink capital and
-- the Elite Four domes (seen from above only). Every drawn pillar is counted
-- in env.stats.pillarsDrawn, as the mesher and PropFix's pedestals do.
-- Not taken: Lance's room (its "pillars" are dragon horns standing on a
-- plinth, painted over floor texels: a column would paint the floor onto a
-- 3 m slab -- T.SKIP_MAPS, a user question in RESULTS.md); pillar groups
-- holding a furniture behaviour (the Player / Copycat 2F TV: the TV type);
-- groups on mixed ground; anything another type already owns.
--
-- Method after pokeemerald-3Ds-dualscreen (ZallaxDev, MIT) through
-- props/Relief.lua (the MIT text is in Relief.lua's header): a column is a
-- relief piece standing where the picture puts its foot, its art 1:1 by the
-- rule V = Z - Y. No code of his is copied here. Every texel is our own
-- ROM-extracted art read through the atlas. Mod sandbox: no globals; debug /
-- package / io never used; `...` is V in the game, nil in tests. State lives
-- on ts only.
local V = ...
local _ = V

local T = {
  id = "Pillar", version = "pillar 0.1 (2026-10-02)",
  walkable = false,
  maxWalkH = 0.56,
  walls = false,
  heightAt = false,      -- collision unchanged: every cell of the group stays solid
  supersedes = { "pedestal" }, -- PropFix's capped pedestal columns (the 3-row ones)
  budget = 400,          -- Mansion 1F: ten pillars; measured net per map in RESULTS.md
  sourceMids = nil,      -- the group's cells and the capital cell above (ring 1)
  stretchedAllowed = 0,
  windingExempt = 0,
}

-- user defaults (scout PLAN Q1: real-life heights, 1 cell = 1.6 m), one constant each
T.PILLAR_H = 1.65        -- 2.64 m: 0.35 under the 2.0 ceiling (PropFix PEDESTAL_GAP); capped at WH
T.INSET = 1 / 64         -- every face kept off the cell border (wave-1 lesson)
T.SKIP_MAPS = { FR_POKEMON_LEAGUE_LANCES_ROOM = true } -- dragon horns, not columns
T.ON = true              -- false: take nothing (today's mesher pillars)

-- a pillar group this type takes (every cell of it, or none): the mesher's
-- pillar, no furniture behaviour in it, nobody's yet, one ground for the
-- group and its capital cell
local function groupOk(ctx, g)
  if not (g and g.pillar and g.cells and #g.cells >= 2) then return false end
  if g.typeOwner or g.slot then return false end
  local cap = g.pillar.cap
  if not (cap and cap.walkable and cap.hasOver) then return false end
  local h0 = cap.hgt or 0
  for _, q in ipairs(g.cells) do
    if q.role ~= "furniture" or q.group ~= g then return false end
    if q.claimOwner or q.typeOwner then return false end
    if q.beh and q.beh ~= 0 then return false end
    if (q.hgt or 0) ~= h0 then return false end   -- mixed ground: skip
  end
  return true
end
T._groupOk = groupOk -- (tests)

function T.applies(ctx, idx)
  return T.ON and not T.SKIP_MAPS[idx.mapId or ctx.mapId or ""] and idx.byRole.furniture ~= nil
end

-- PURE: every cell of every pillar group taken, row-major (the index order)
function T.match(ctx, idx)
  local out = {}
  for _, c in ipairs(idx.byRole.furniture or {}) do
    if c.group and c.group.pillar and groupOk(ctx, c.group) then out[#out + 1] = c end
  end
  return out
end

function T.classify(ctx, cells, ts)
  local set = ts.cellSet
  if not set then
    set = {}
    for _, p in ipairs(cells) do set[p] = true end
  end
  -- whole pillars only (a group the dispatcher cut short is left to the core)
  local units, seen = {}, {}
  for _, p in ipairs(cells) do
    local g = p.group
    if g and not seen[g] then
      seen[g] = true
      local whole = groupOk(ctx, g)
      for _, q in ipairs(g.cells) do if not set[q] then whole = false end end
      if whole then
        local list = {}
        for i, q in ipairs(g.cells) do list[i] = q end
        units[#units + 1] = { x = p.x, minY = g.minY, maxY = g.maxY, g = p.hgt or 0, cells = list }
      end
    end
  end
  local H = math.min(T.PILLAR_H, ctx.WH or 2.0)
  for _, u in ipairs(units) do
    table.sort(u.cells, function(a, b) return a.y < b.y end)
    for _, q in ipairs(u.cells) do ctx:claim(q.x, q.y, nil, H) end
  end
  ts.units = units
end

function T.props(ctx, ts)
  local R = ts.lib.Relief
  local under, over = ctx:buffer("opaque"), ctx:buffer("over")
  local I = T.INSET
  local H = math.min(T.PILLAR_H, ctx.WH or 2.0)
  ts.pieces = {}
  for _, u in ipairs(ts.units or {}) do
    local x0, x1, z0, z1 = u.x + I, u.x + 1 - I, u.maxY + I, u.maxY + 1 - I
    -- the top shows the rows just above the front, 1:1 over the piece's
    -- depth; never above the capital's row (ring 1)
    local first = math.max(z1 - H - (z1 - z0), u.minY - 1)
    local st = R.piece(ctx, { x0 = x0, x1 = x1, z0 = z0, z1 = z1, h = H, g = u.g, first = first,
      under = under, over = over, tag = "pillar" })
    ts.pieces[#ts.pieces + 1] = { x = u.x, minY = u.minY, maxY = u.maxY, h = H, first = first, tris = st and st.tris or 0 }
    -- (the mesher counts the pillars it draws; these are drawn here)
    local stats = ctx.env.stats
    if type(stats) == "table" then stats.pillarsDrawn = (stats.pillarsDrawn or 0) + 1 end
  end
end

return T
