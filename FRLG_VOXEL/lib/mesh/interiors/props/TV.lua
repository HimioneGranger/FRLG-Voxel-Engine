-- FRLG_VOXEL / interiors team: props/TV.lua -- the television (behaviour 0x86,
-- MB_TELEVISION) and the game console on the floor in front of it (wave 2,
-- 2026-10-02; scout INVENTORY "TV / game console").
--
-- Where: 27 TV cells on 27 maps, all metatile 53 (the building primary
-- tileset's TV: rows 0-6 its top panel, row 7 the top's front edge, rows 8-15
-- the screen). The TV's stand (the glass-door cabinet) is drawn in the next
-- row down, rows 0-7 of the metatile south of the TV.
--   * 24 lone one-cell TVs against the back wall (generic houses, Player 1F,
--     Rival's house, Copycat 1F, the Fan Club): the stand is in the walkable
--     floor cell in front, which no type may build in;
--   * 2 TVs standing in the room (Player 2F (6,4), Copycat 2F (3,4)) whose
--     furniture group is the TV plus the cell south of it, which holds the
--     stand's doors and the game console (metatiles 654 / 641; the console's
--     foot row and the controller are in the walkable cell after it);
--   * 1 TV in the back-wall bookshelf group of the Lavender Volunteer House
--     (5,1): taken out of the group alone (the group keeps its other cells and
--     the core re-derives its height).
-- 0xA1 (video game) was never seen in the census: not matched.
--
-- How it is drawn: one relief piece per TV on the TV's own cell through
-- ts.lib.Relief, real-life height (user default, scout Q1). TV_H puts the
-- art's own edge between the top panel (lid) and the screen (front), so the
-- screen stands upright at 1:1 and the top panel lies on the lid. The stand's
-- doors stay floor art in the walkable cell in front of a wall TV; on a
-- claimed console cell the ground is the rug beside it (T.CONSOLES.ground),
-- so the doors are not drawn there. The console is a low relief piece on the
-- console cell, its foot on that cell's south edge, its art's own columns.
--
-- Method after pokeemerald-3Ds-dualscreen (ZallaxDev, MIT) through
-- props/Relief.lua (the MIT text is in Relief.lua's header); no code of his is
-- copied here. Every texel is our own ROM-extracted art read through the atlas.
-- Mod sandbox: no globals; the debug, package and io libraries are never used;
-- `...` is V in the game, nil in tests.
local V = ...
local _ = V

local T = {
  id = "TV", version = "tv 0.1 (2026-10-02)",
  walkable = false,
  maxWalkH = 0.56,
  walls = false,
  heightAt = false,
  supersedes = {},    -- (PropFix "pillar holding a known behaviour" un-pillars the 2F TVs: types run first)
  budget = 120,       -- a TV adds 10-18 triangles, a console up to 14 more (one TV per map)
  sourceMids = nil,
  stretchedAllowed = 0,
  windingExempt = 0,
}

-- user default (scout PLAN Q1): real-life heights, 1 cell = 1.6 m.
-- TV on its stand 0.9 m = 9 art rows: the core's table says 0.55 (0.88 m);
-- 9/16 lands the lid / front edge on the art's own edge (rows 0-6 lid, 7-15
-- screen) instead of 0.2 px into the dark edge row. One constant.
T.TV_H = 9 / 16
-- the console: 10 cm (the nearest whole art row to a real 7-11 cm console)
T.CONSOLE_H = 1 / 16
-- wave-1 lesson: a face that would sit flush on a core face steps this far in
T.INSET = 1 / 64

local BEH_TV = 0x86

-- the console metatiles south of a TV, per tileset pair: the console's art
-- columns c0..c1 (px), its first (outline) row r0 (px), and the plain floor
-- metatile the claimed cell's ground is drawn with (the rug / floor beside
-- it; the core's default ground is the room's main floor, not the rug these
-- consoles stand on); reviewed against the atlas (offline pixel dump,
-- RESULTS.md)
T.CONSOLES = {
  player_house = {
    [654] = { c0 = 1, c1 = 15, r0 = 9, ground = 69 },    -- Player 2F (green rug)
    [641] = { c0 = 2, c1 = 14, r0 = 9, ground = 204 },   -- Copycat 2F (orange floor)
  },
}

local function sameGround(a, b) return math.abs((a.hgt or 0) - (b.hgt or 0)) <= 1e-9 end

local function isTV(c)
  return c and c.beh == BEH_TV and c.role == "furniture" and not c.walkable
end

-- the units of the room (pure): { tv = cell, console = cell or nil }
-- * a group of the TV alone, or of the TV and its console cell right south:
--   the whole group;
-- * a TV in a larger group (the Volunteer House bookshelf): the TV alone,
--   provided the rest of the group is not on another ground (wave-1 lesson:
--   skip groups that stand on mixed ground);
-- * anything else (two TVs in one group, a group south of the TV that is not
--   a known console): left to the core.
local function units(ctx, list, pair)
  local out = {}
  local cons = T.CONSOLES[pair or ""] or {}
  for _, c in ipairs(list) do
    if isTV(c) then
      local g = c.group
      local cells = g and g.cells or { c }
      local mixed, tvs, south, other = false, 0, nil, 0
      for _, q in ipairs(cells) do
        if not sameGround(q, c) then mixed = true end
        if q.beh == BEH_TV then tvs = tvs + 1
        elseif q.x == c.x and q.y == c.y + 1 and cons[q.mid] then south = q
        else other = other + 1 end
      end
      if not mixed and tvs == 1 then
        if other == 0 then
          out[#out + 1] = { tv = c, console = south, spec = south and cons[south.mid] or nil }
        elseif not south then
          out[#out + 1] = { tv = c }
        end
      end
    end
  end
  return out
end
T._units = units -- (tests)

function T.applies(ctx, idx) return idx.byBeh[BEH_TV] ~= nil end

-- PURE: the TV cells (and their console cells), in index order
function T.match(ctx, idx)
  local want = {}
  for _, u in ipairs(units(ctx, idx.byBeh[BEH_TV] or {}, idx.pair or ctx.pair)) do
    want[#want + 1] = u.tv
    if u.console then want[#want + 1] = u.console end
  end
  return want
end

function T.classify(ctx, cells, ts)
  local set = ts.cellSet or {}
  if not ts.cellSet then for _, p in ipairs(cells) do set[p] = true end end
  local list = {}
  for _, u in ipairs(units(ctx, cells, ctx.pair)) do
    -- whole units only: a unit the dispatcher cut short is left to the core
    if set[u.tv] and (u.console == nil or set[u.console]) then
      list[#list + 1] = u
    end
  end
  for _, u in ipairs(list) do
    ctx:claim(u.tv.x, u.tv.y, nil, T.TV_H)
    if u.console then ctx:claim(u.console.x, u.console.y, u.spec.ground, T.CONSOLE_H) end
  end
  ts.units = list
end

-- a neighbour the piece's side would sit flush on: a solid core face (a
-- furniture box, a pillar ...), not a wall run (Relief skips that face) and
-- not open floor
local function flushSolid(ctx, x, y)
  local c = ctx:at(x, y)
  return c ~= nil and not c.exitFrame and not c.walkable and c.role ~= "wall"
end

local function wallRun(ctx, x, y)
  local c = ctx:at(x, y)
  return c ~= nil and c.role == "wall"
end

function T.props(ctx, ts)
  local R = ts.lib.Relief
  local under, over = ctx:buffer("opaque"), ctx:buffer("over")
  local px = 1 / (R.PX or 16)
  for _, u in ipairs(ts.units or {}) do
    local c = u.tv
    local x, y, g = c.x, c.y, c.hgt or 0
    local iw = flushSolid(ctx, x - 1, y) and T.INSET or 0
    local ie = flushSolid(ctx, x + 1, y) and T.INSET or 0
    local ib = flushSolid(ctx, x, y - 1) and T.INSET or 0
    -- flanks: skipped only against a wall run; at the map's edge (the Fan
    -- Club TV, x = W - 1) nothing closes the side, so it is drawn
    local fl = { w = not wallRun(ctx, x - 1, y), e = not wallRun(ctx, x + 1, y) }
    R.piece(ctx, { x0 = x + iw, x1 = x + 1 - ie, z0 = y + ib, z1 = y + 1, h = T.TV_H, g = g,
      first = y + ib, flanks = fl, under = under, over = over, tag = "tv" })
    if u.console then
      local k, s = u.console, u.spec
      local z0 = k.y + s.r0 * px
      R.piece(ctx, { x0 = k.x + s.c0 * px, x1 = k.x + s.c1 * px, z0 = z0, z1 = k.y + 1,
        h = T.CONSOLE_H, g = k.hgt or 0, first = z0, under = under, over = over, tag = "console" })
    end
  end
end

return T
