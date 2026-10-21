-- FRLG_VOXEL / interiors team: props/Table.lua -- the free-standing 2 x 2
-- tables (wave 1, 2026-10-01; scout INVENTORY "Tables", PLAN.md 2.5).
--
-- What it takes: a 2 x 2 block of metatiles m, m+1, m+8, m+9 whose top-left m
-- is a reviewed table tile of the room's tileset pair (TILES below), all four
-- cells furniture (not walkable, not wall runs) with no behaviour byte. Each
-- top-left was checked against the 2D art (offline contact sheet, Table
-- workspace notes). Larger tables (Silph 11F, Mansion, Condominiums, Cinnabar
-- lab, Fan Club, S.S. Anne cabins with cups) are not 2 x 2 and stay as they
-- are; cups (0x9B) and kitchen tiles (0x8A / 0x8C / 0x90 / 0x99) carry a
-- behaviour byte and are never matched here.
--
-- How it is drawn: one relief piece per table through ts.lib.Relief (method
-- after pokeemerald-3Ds-dualscreen, ZallaxDev, MIT; credit and licence text in
-- Relief.lua). Real-life height (user default, scout Q1): TABLE_H = 0.45 cell
-- (0.72 m). The art's own rows only: front = the apron and legs, drawn top =
-- the table top 1:1, the hidden depth = the top's own rows course by course
-- with the outline row once at the back. Textures are the room's own ROM art
-- read through the atlas; nothing baked, nothing new.
-- No globals, no debug / package / io (mod sandbox); per-build state on ts.
local V = ...
local _ = V

local T = {
  id = "Table", version = "table 0.2 (2026-10-02)",
  walkable = false, maxWalkH = 0.56, walls = false, heightAt = false,
  supersedes = {},       -- (PropFix "table" kind only re-heights groups; it has no tile rule for these)
  budget = 300,          -- triangles per map (3 tables per room at most: about 35 each)
  sourceMids = nil, stretchedAllowed = 0, windingExempt = 0,
}

-- user default (scout PLAN Q1): real-life table height, 1 cell = 1.6 m
T.TABLE_H = 0.45
-- the art's floor margin: the first table row / column inside the 32 x 32 block (px)
T.EDGE_PX = 1
-- cells: a table standing right behind another (Cerulean City house 5) keeps
-- its back face this far inside its row, off the front table's foot plane
T.RECESS = 1 / 64

-- reviewed table tiles: pair -> { [top-left mid] = edge px (nil = T.EDGE_PX) }
-- (mids < 640 are the building primary tileset, shared by these pairs)
T.TILES = {
  house = { [76] = true, [296] = true, [357] = true, [726] = true },
  player_house = { [76] = true, [200] = true, [296] = true },
  oak_lab = { [357] = true, [712] = true },
  network = { [668] = true },                                -- Pokemon Center glass table
  building__rom_082d4c2c = { [296] = true },
  building__rom_082d4e24 = { [357] = true },
  building__rom_082d4ecc = { [835] = true },                 -- Silph Co. lobby glass tables
  building__rom_082d4cec = { [781] = true },                 -- Joyful Game Corner
  building__rom_082d4e6c = { [843] = 0 },                    -- Celadon roof round table (outline on the edge)
  building__rom_082d4f14 = { [747] = true },                 -- Lorelei's house
  building__rom_082d4f44 = { [658] = true },                 -- Celadon hotel
}

local function plainFurniture(c)
  return c and c.role == "furniture" and not c.walkable and (c.beh == nil or c.beh == 0)
end

-- a block standing on two grounds, or inside a furniture group that does
-- (Silph Co. 8F), is levelled by the core after the types (levelGroups: every
-- cell gets the group's highest ground, which moves heightAt); this type never
-- moves the ground (heightAt = false), so such a block stays the core's
local function oneGround(cells)
  local h0 = cells[1].hgt or 0
  local function same(p) return math.abs((p.hgt or 0) - h0) <= 1e-9 end
  for _, c in ipairs(cells) do
    if not same(c) then return false end
    local g = c.group
    if g and g.cells then
      for _, p in ipairs(g.cells) do if not same(p) then return false end end
    end
  end
  return true
end

-- the table blocks of the room: { { x, y, edge, cells = { 4 cells } } } (pure)
local function blocks(ctx, idx)
  local tiles = T.TILES[idx.pair or ctx.pair or ""]
  if not tiles then return {} end
  local out = {}
  -- deterministic: every top-left in the room in row-major order
  for _, c in ipairs(idx.all) do
    local e = c.mid and tiles[c.mid]
    if e and plainFurniture(c) then
      local m, x, y = c.mid, c.x, c.y
      local b, d, f = ctx:at(x + 1, y), ctx:at(x, y + 1), ctx:at(x + 1, y + 1)
      if b and d and f and b.mid == m + 1 and d.mid == m + 8 and f.mid == m + 9
          and plainFurniture(b) and plainFurniture(d) and plainFurniture(f)
          and oneGround({ c, b, d, f }) then
        out[#out + 1] = { x = x, y = y, edge = (e == true) and T.EDGE_PX or e, cells = { c, b, d, f } }
      end
    end
  end
  return out
end
T._blocks = blocks -- (tests)

function T.applies(ctx, idx)
  return T.TILES[idx.pair or ctx.pair or ""] ~= nil
end

function T.match(ctx, idx)
  local want = {}
  for _, bl in ipairs(blocks(ctx, idx)) do
    for _, c in ipairs(bl.cells) do want[#want + 1] = c end
  end
  return want
end

function T.classify(ctx, cells, ts)
  -- whole blocks only: a block the dispatcher cut short is left to the core
  local set = ts.cellSet
  local idx = { pair = ctx.pair, all = cells }
  local list = {}
  for _, bl in ipairs(blocks(ctx, idx)) do
    local ok = true
    for _, c in ipairs(bl.cells) do if not set[c] then ok = false end end
    if ok then
      for _, c in ipairs(bl.cells) do ctx:claim(c.x, c.y, nil, T.TABLE_H) end
      list[#list + 1] = { x = bl.x, y = bl.y, edge = bl.edge, g = bl.cells[3].hgt or 0 }
    end
  end
  ts.tables = list
end

-- a side touches a wall run / the map edge: the piece goes flush there (Relief
-- skips that face); elsewhere it stands EDGE px in from the art's floor margin
local function wallish(ctx, x, y)
  local c = ctx:at(x, y)
  return (not c) or c.exitFrame or c.role == "wall"
end

function T.props(ctx, ts)
  local R = ts.lib.Relief
  local under, over = ctx:buffer("opaque"), ctx:buffer("over")
  local mine = {}
  for _, t in ipairs(ts.tables or {}) do
    for dy = 0, 1 do for dx = 0, 1 do mine[(t.x + dx) .. "," .. (t.y + dy)] = true end end
  end
  for _, t in ipairs(ts.tables or {}) do
    local x, y, e = t.x, t.y, (t.edge or 0) / R.PX
    local wW = wallish(ctx, x - 1, y) and wallish(ctx, x - 1, y + 1)
    local wE = wallish(ctx, x + 2, y) and wallish(ctx, x + 2, y + 1)
    -- another table's foot right behind: the back face steps RECESS inside
    local behind = mine[x .. "," .. (y - 1)] or mine[(x + 1) .. "," .. (y - 1)]
    local z0 = y + (behind and T.RECESS or 0)
    R.piece(ctx, {
      x0 = x + (wW and 0 or e), x1 = x + 2 - (wE and 0 or e),
      z0 = z0, z1 = y + 2, h = T.TABLE_H, g = t.g,
      first = math.max(y + e, z0), -- the table's outline row (row 0 is the floor around it)
      under = under, over = over, tag = "table",
    })
  end
end

return T
