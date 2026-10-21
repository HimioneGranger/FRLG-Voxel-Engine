-- FRLG_VOXEL / interiors team: props/Bin.lua -- trash bins and cans (wave 3,
-- 2026-10-02; scout INVENTORY "Bins").
--
-- Where (offline census of all 263 indoor maps on the w3base tree): 20 cells on
-- 4 maps, each a one-cell furniture group, each bin drawn whole inside its own
-- metatile (no over art, the floor around it is in the same tile):
--   * S.S. Anne (pair general__rom_082d4d94), behaviour 0x9A (trash can):
--     metatile 649, a blue office waste basket (B1F corridor (21,5), Captain's
--     office (5,3)); metatile 650, a grey lidded kitchen can (Kitchen (14,4),
--     (14,6), (14,8)). The core draws them as 0.6-cell boxes.
--   * Vermilion Gym (pair building__rom_082d4d34): metatile 696, behaviour 0x00,
--     the 15 cans of the switch puzzle. The mesher draws them as cylinders
--     (IN.bin, 0.45 cells). Taken only with T.VERMILION_CANS = true (off by
--     default: the interiors suite w3i_tree checks those cylinders, so the
--     relief cans wait for the coordinator's G9 rule and the user's choice;
--     RESULTS.md). Off: 5 bins on 3 maps.
-- Any other 0x9A cell, or one of these metatiles in a larger group, is left to
-- the core (its art rows are not known here).
--
-- How it is drawn: one relief piece per bin through ts.lib.Relief on the art's
-- own footprint (columns c0..c1 of the bin, its foot on the art's bottom
-- outline). The height puts the art's own edge between the rim seen from above
-- (lid) and the body (front), so the body stands upright at 1:1 and the rim /
-- opening lies on the lid. The cell's ground is redrawn with the floor tile
-- beside it (the bin's own tile carries the floor around the bin). Footprint
-- depth = the bin's width (round in plan). The pieces sit 1 px or more inside
-- their cell, so no face is flush with a core face or a wall.
--
-- Method after pokeemerald-3Ds-dualscreen (ZallaxDev, MIT) through
-- props/Relief.lua (the MIT text is in Relief.lua's header); no code of his is
-- copied here. Every texel is our own ROM-extracted art read through the atlas.
-- Mod sandbox: no globals; the debug, package and io libraries are never used;
-- `...` is V in the game, nil in tests.
local V = ...
local _ = V

local T = {
  id = "Bin", version = "bin 0.1 (2026-10-02)",
  walkable = false,
  maxWalkH = 0.56,
  walls = false,
  heightAt = false,
  supersedes = {},    -- (with VERMILION_CANS: replaces the mesher's IN.bin cylinders there; types run first)
  budget = 400,       -- a bin adds 14 triangles; with VERMILION_CANS the gym's 15 cans add 210 (net fewer)
  sourceMids = nil,
  stretchedAllowed = 0,
  windingExempt = 0,
}

-- user default (scout PLAN Q1): real-life heights, 1 cell = 1.6 m. One
-- constant per kind; each lands the lid / front edge on the art's own edge.
T.H = {
  basket = 5 / 16,    -- office waste basket 0.50 m (rim rows 1-9 lid, body rows 10-14 front)
  kitchen = 7 / 16,   -- kitchen can with lid 0.70 m (lid rows 1-7, body rows 8-14)
  can = 7 / 16,       -- Vermilion Gym can 0.70 m (opening rows 0-7, body rows 8-14)
}

-- user decision pending (RESULTS.md): the Vermilion Gym cans as relief pieces
-- (true) or the mesher's round cylinders (false, today's look). One constant.
T.VERMILION_CANS = false

-- per tileset pair and metatile: the bin's columns c0..c1 (px, c1 exclusive),
-- its first (outline) row r0 (px), its foot row (px: the row after its bottom
-- outline) and the kind (T.H); reviewed against the atlas (offline pixel dump,
-- RESULTS.md)
T.BINS = {
  general__rom_082d4d94 = {
    [649] = { c0 = 1, c1 = 15, r0 = 1, foot = 15, kind = "basket" },
    [650] = { c0 = 3, c1 = 13, r0 = 1, foot = 15, kind = "kitchen" },
  },
  building__rom_082d4d34 = {
    [696] = { c0 = 2, c1 = 14, r0 = 0, foot = 15, kind = "can", opt = "VERMILION_CANS" },
  },
}

local DIRS = { { 0, 1 }, { 0, -1 }, { -1, 0 }, { 1, 0 } } -- S, N, W, E (fixed order)

local function sameGround(a, b) return math.abs((a.hgt or 0) - (b.hgt or 0)) <= 1e-9 end

-- the floor tile next to the bin (pure): the first walkable, dry, non-wall
-- neighbour on the same ground, S N W E
local function floorMid(ctx, c)
  for _, d in ipairs(DIRS) do
    local n = ctx:at(c.x + d[1], c.y + d[2])
    if n and n.walkable and not n.isWater and n.role ~= "wall" and not n.exitFrame and n.mid
        and not n.hasOver and sameGround(n, c) then
      return n.mid
    end
  end
  return nil
end

-- a bin cell (pure): a known bin metatile, a one-cell furniture group, solid,
-- with a floor tile beside it -> spec, ground mid
local function binOf(ctx, c, pair)
  local tab = T.BINS[pair or ""]
  local s = c and tab and tab[c.mid]
  if not s then return nil end
  if s.opt and not T[s.opt] then return nil end
  if c.role ~= "furniture" or c.walkable or c.hasOver then return nil end
  local g = c.group
  if not g or #g.cells ~= 1 or g.pillar or g.slot then return nil end
  local fm = floorMid(ctx, c)
  if not fm then return nil end
  return s, fm
end
T._binOf = binOf -- (tests)

function T.applies(ctx, idx)
  local tab = T.BINS[idx.pair or ctx.pair or ""]
  if not tab then return false end
  for mid, s in pairs(tab) do
    if idx.byMid[mid] and not (s.opt and not T[s.opt]) then return true end
  end
  return false
end

-- PURE: the bin cells, row-major (merged in index order over the known mids)
function T.match(ctx, idx)
  local pair = idx.pair or ctx.pair
  local tab = T.BINS[pair or ""]
  local want = {}
  if not tab then return want end
  local mids = {}
  for mid in pairs(tab) do mids[#mids + 1] = mid end
  table.sort(mids)
  for _, mid in ipairs(mids) do
    for _, c in ipairs(idx.byMid[mid] or {}) do
      if binOf(ctx, c, pair) then want[#want + 1] = c end
    end
  end
  table.sort(want, function(a, b) if a.y ~= b.y then return a.y < b.y end return a.x < b.x end)
  return want
end

function T.classify(ctx, cells, ts)
  local list = {}
  for _, c in ipairs(cells) do
    local s, fm = binOf(ctx, c, ctx.pair)
    if s then
      ctx:claim(c.x, c.y, fm, T.H[s.kind])
      list[#list + 1] = { cell = c, spec = s }
    end
  end
  ts.bins = list
end

function T.props(ctx, ts)
  local R = ts.lib.Relief
  local under = ctx:buffer("opaque")
  local px = 1 / (R.PX or 16)
  for _, b in ipairs(ts.bins or {}) do
    local c, s = b.cell, b.spec
    local x, y = c.x, c.y
    local w = (s.c1 - s.c0) * px
    local z1 = y + s.foot * px
    R.piece(ctx, { x0 = x + s.c0 * px, x1 = x + s.c1 * px, z0 = z1 - w, z1 = z1, h = T.H[s.kind],
      g = c.hgt or 0, first = y + s.r0 * px, under = under, tag = "bin" })
  end
end

return T
