-- FRLG_VOXEL / interiors-team PROPS: PropFix.lua -- prop heights and
-- real-life furniture (VERIFY_coverage C1; user decision 2026-09-29:
-- counters and tables at real-life heights).
--
-- Owner: the props worker (build/props/). Runs through the core
-- (FrlgInteriors, build/core/API.md) on every indoor build:
--   classify(ctx)  one journaled core step (after the core's own B1 / B2 /
--                  heights, before the section): props wrongly meshed as
--                  2.0-tall wall runs (Pokemon Tower graves, harbor
--                  railings, bike-shop bikes, banisters, the Day Care /
--                  Volunteer lamps, the Fan Club and Day Care edge cases,
--                  gatehouse counters ...) become claimed cells this module
--                  draws at a real-life height, or furniture groups the
--                  mesher draws (counters / shelves / desks joining the
--                  furniture they end); pillars that would reach the ceiling
--                  are capped; counter groups holding a PC and computer
--                  desks get counter / desk height.
--   props(ctx)     the drawn props: boxes inset inside their cells (graves
--                  as rows of headstones, cases, crates, bikes, planters ...),
--                  thin railings / banisters, floor lamps, capped pedestal
--                  columns -- into base-list buffers: ordinary geometry,
--                  always drawn, shadow casters like any furniture.
-- It changes cells ONLY through the core's journaled helpers (unwall,
-- furnish, claim, plant, setGroupHeight, unPillar, leaveGroup) and ctx:set
-- for the two group operations the helpers lack (dissolving a furniture
-- group into another, keeping a pillar's capital decal hidden); an error
-- rolls the whole step back (the room is then exactly as without this
-- module) and props() then draws nothing (its cells are no longer claimed).
--
-- Scale: 1 cell = 1.6 m; the first-person eye is 0.95 cells (1.52 m) above
-- the floor; a waist-high counter is 0.65 (1.04 m), a table 0.45 (0.72 m).
-- Rules are pure functions of the map id and its tiles (runtime tile swaps
-- rebuild the map: same tiles, same result).
-- No debug / package / io (mod sandbox).
local V = ...
local _ = V

local P = { VERSION = "propfix 1.1 (2026-10-02)" }
-- 1.1 (interiors team w0r1, coordinator-approved minimal change): one owner
-- per cell -- a cell granted to a furniture type (PropTypes sets typeOwner on
-- it and on any group holding it) is never a PropFix target, plant entries
-- included; such groups are never re-heighted, unpillared or joined.

local mfloor, mmin, mmax, mabs = math.floor, math.min, math.max, math.abs
local function key(x, y) return y * 65536 + x end
P.key = key

-- ---------------------------------------------------------------------------
-- kinds: height in cells above the cell's ground, how it is drawn
--   draw nil      = a furniture group (the mesher draws its box)
--   draw "box"    = claimed; a box this module draws inset inside the cells
--                   (an entry / kind with join = true: a furniture group)
--   draw "rail"   = claimed; a thin railing (top rail, mid rail, posts)
--   draw "lamp"   = claimed; a floor lamp (base, pole, shade) on the lowest cell
--   draw "plant"  = the mesher's plant (pot cards + leaf cards)
-- ---------------------------------------------------------------------------
P.KIND = {
  -- drawn boxes (claimed cells; inset = { w, e, n, s } inside the cells)
  grave     = { h = 0.45, draw = "box", rows = true, inset = { 0.08, 0.08, 0.14, 0.08 } }, -- headstone 0.72 m, rows
  bike      = { h = 0.60, draw = "box" },  -- bicycle, handlebars 0.96 m
  case      = { h = 0.75, draw = "box" },  -- display cabinet 1.2 m (the core's cabinet height)
  cabinet   = { h = 0.75, draw = "box" },  -- cabinet block 1.2 m (entries with join: a furniture group)
  sidetable = { h = 0.45, draw = "box" },  -- side table 0.72 m
  box       = { h = 0.45, draw = "box" },  -- box / book stack 0.72 m
  basket    = { h = 0.30, draw = "box" },  -- basket 0.48 m
  pot       = { h = 0.45, draw = "box" },  -- planter whose leaves are painted on the wall above
  crate     = { h = 0.60, draw = "box" },  -- warehouse crate 0.96 m
  shelfbox  = { h = 1.20, draw = "box" },  -- a shelf standing in a counter group (drawn apart from the counter)
  statue    = { h = 0.45, draw = "box" },  -- statue plinth, as the room's other statue boxes
  -- furniture groups (the mesher's boxes; they join the furniture they end)
  counter   = { h = 0.65 },            -- waist-high counter 1.04 m
  table     = { h = 0.45 },            -- table 0.72 m (a 2 x 2 top stays one box)
  barrier   = { h = 0.65 },            -- museum rope / board barrier 1.04 m
  shelf     = { h = 1.20, join = true }, -- shelving 1.92 m (the mesher bookshelf height)
  desk      = { h = 0.45, join = true }, -- desk 0.72 m
  -- drawn props
  rail      = { h = 0.65, draw = "rail", colour = "sat", posts = 1.0 },     -- railing 1.04 m
  banister  = { h = 0.60, draw = "rail", colour = "light", posts = 0.5 },   -- stair banister 0.96 m
  lamp      = { h = 1.10, draw = "lamp" },                                   -- floor lamp 1.76 m
  plant     = { draw = "plant" },
}
-- (every inset > SYNTH_WALL_INSET 0.06: a drawn box stands clear of the
-- synthetic walls at the room's edges, never on their plane)
P.BOX_INSET = { 0.08, 0.08, 0.08, 0.08 }
-- a pillar group reaching the ceiling (INDOOR_WALL_H) is capped this far below it
P.PEDESTAL_GAP = 0.35
-- behaviour heights (mirror of the core's M.FURNITURE_H / ON_TOP / FURN_DEFAULT,
-- build/core/API.md section 6) plus this module's additions
P.CORE_H = { [0x80] = 0.65, [0x83] = 0.75, [0x86] = 0.55, [0x89] = 0.75, [0x8A] = 0.55, [0x8B] = 0.75 }
P.ON_TOP = { [0x8C] = true, [0x90] = true, [0x96] = true, [0x99] = true, [0x9B] = true }
P.FURN_DEFAULT = 0.45
P.EXTRA_H = { [0x97] = 0.75 } -- computer desk (was 1.0: a box above the eye line at 0.95)
-- a PC standing on a counter is ON the counter (the PC 2F link counters)
P.PC_ON_COUNTER = true

-- ---------------------------------------------------------------------------
-- tile rules: in the maps they cover, every wall-run / furniture cell showing
-- one of these tiles is that prop (reviewed per tile against the 2D art,
-- build/props/views/)
-- ---------------------------------------------------------------------------
P.TILES = {
  { -- Pokemon Tower: purple / gold graves and their wall-shadowed variants
    maps = "^FR_POKEMON_TOWER_%dF$", pair = "building__rom_082d4efc",
    tiles = { [657] = "grave", [649] = "grave", [732] = "grave", [733] = "grave" },
    cutBelow = { [657] = true, [649] = true, [732] = true, [733] = true },
    stairArt = true }, -- (graves beside a stair were flattened as stair art)
  { -- the 9 Sevii / Vermilion-style harbors: quay, pier and front railings
    pair = "harbor",
    tiles = { [653] = "rail", [654] = "rail", [662] = "rail", [655] = "rail", [652] = "rail",
      [660] = "rail", [663] = "rail", [661] = "rail", [669] = "rail", [677] = "rail" } },
  { -- Cerulean bike shop: display bikes (the free-standing and edge ones were 2.0 walls)
    maps = "^FR_CERULEAN_CITY_BIKE_SHOP$",
    tiles = { [642] = "bike", [644] = "bike", [651] = "bike", [648] = "box" } },
  { -- Day Cares, Fan Clubs, Volunteer house: glass display cases and side tables at the edges
    pair = "building__rom_082d4f74",
    tiles = { [782] = "case", [783] = "case", [784] = "case", [737] = "case", [745] = "case",
      [764] = "sidetable", [757] = "sidetable" },
    cutBelow = { [745] = true } },
  { -- Bill's Sea Cottage: boxes, baskets and cabinets along both side edges
    maps = "^FR_ROUTE_25_SEA_COTTAGE$",
    tiles = { [153] = "box", [691] = "basket", [688] = "basket", [668] = "cabinet", [676] = "cabinet",
      [687] = "cabinet" },
    cutBelow = { [676] = true, [687] = true } },
  { -- gatehouses (pair "house", the route entrances and the Route 2 east building):
    -- reception counters (no behaviour byte: the core's table default 0.45)
    -- with their end cells made side walls, stair banisters, and planters
    -- whose leaves are painted on the wall row above
    maps = "^FR_ROUTE_%d+_.*ENTRANCE", pair = "house",
    tiles = { [653] = "counter", [661] = "counter", [662] = "counter", [668] = "counter", [676] = "counter",
      [677] = "counter", [678] = "counter", [687] = "banister", [695] = "banister", [703] = "banister",
      [682] = "banister", [690] = "banister", [698] = "banister", [753] = "pot" } },
  { maps = "^FR_ROUTE_2_EAST_BUILDING$", pair = "house", tiles = { [753] = "pot" } },
  { -- Celadon Condominiums 1F-3F: planters in front of the walls, the ends of a
    -- bookshelf / desks made side walls, a drawer cabinet, the stair banisters
    maps = "^FR_CELADON_CITY_CONDOMINIUMS_%dF$", pair = "building__rom_082d4f8c", wallsOnly = true,
    tiles = { [721] = "pot", [749] = "shelf", [669] = "desk", [153] = "cabinet", [693] = "cabinet",
      [674] = "banister", [682] = "banister", [695] = "banister", [703] = "banister",
      [776] = "banister", [784] = "banister", [781] = "banister", [789] = "banister" } },
  { -- Five Island Rocket Warehouse: crate lines (the long ones were 2.0 wall runs)
    maps = "^FR_FIVE_ISLAND_ROCKET_WAREHOUSE$", pair = "building__rom_082d4ecc",
    tiles = { [917] = "crate", [153] = "crate" } },
}

-- ---------------------------------------------------------------------------
-- per-map rules: explicit cells (x, y | y0..y1) -> kind; optional
--   line = rail offset in the cell (N-S rails: x offset; E-W: z offset)
--   axis = "ns" | "ew" for a rail cell with no rail neighbour
-- ---------------------------------------------------------------------------
P.MAPS = {
  FR_ROUTE_5_POKEMON_DAY_CARE = {
    { x = 4, y0 = 2, y1 = 3, kind = "lamp", why = "floor lamp (HO-5), rows 2-3 were a 2.0 column" },
  },
  FR_LAVENDER_TOWN_VOLUNTEER_POKEMON_HOUSE = {
    { x = 8, y0 = 2, y1 = 3, kind = "lamp", why = "floor lamp (HO-5)" },
  },
  FR_PLAYERS_HOUSE_2F = {
    { x = 8, y0 = 2, y1 = 3, kind = "banister", line = 0.2, axis = "ns", why = "stair banister (HO-3)" },
  },
  FR_SAFFRON_CITY_COPYCATS_HOUSE_2F = {
    { x = 8, y0 = 2, y1 = 3, kind = "banister", line = 0.2, axis = "ns", why = "stair banister (HO-3)" },
  },
  FR_PEWTER_CITY_MUSEUM_1F = {
    { x = 10, y0 = 7, y1 = 9, kind = "banister", line = 0.5, axis = "ns", why = "stair side rail (B6)" },
    { x = 11, y0 = 8, y1 = 9, kind = "barrier", join = true, why = "barrier post, joins the barrier (11,5-7)" },
    { x = 27, y = 4, kind = "case", join = true, why = "display case front, joins its top (27,3)" },
    { x = 27, y = 7, kind = "case", join = true, why = "display case front, joins its top (27,6)" },
  },
  FR_VERMILION_CITY_POKEMON_FAN_CLUB = {
    { x = 0, y = 4, kind = "plant", why = "potted plant at the edge (HO-4)" },
    { x = 11, y = 4, kind = "plant", why = "potted plant at the edge (HO-4)" },
  },
  FR_SAFFRON_CITY_POKEMON_TRAINER_FAN_CLUB = {
    { x = 0, y = 8, kind = "cabinet", join = true, why = "bar cabinet block (0-2,8-9) (HO-4)" },
    { x = 2, y0 = 8, y1 = 9, kind = "cabinet", join = true, why = "bar cabinet block (0-2,8-9)" },
    { x = 8, y0 = 8, y1 = 9, kind = "cabinet", join = true, why = "cabinet block (8-10,8-9)" },
    { x = 10, y = 8, kind = "cabinet", join = true, why = "cabinet block (8-10,8-9)" },
  },
  FR_OAKS_LAB = {
    { x = 0, y0 = 3, y1 = 4, kind = "box", why = "book / box stack at the west edge (HO-4)" },
  },
  FR_CELADON_CITY_DEPARTMENT_STORE_4F = {
    { x = 7, y = 14, kind = "counter", join = true, why = "the L-counter's foot was a 2.0 block (PM-7)" },
  },
  -- Game Corner / Prize Room: the prize counter (0x80) and the shelves (0x82)
  -- inside its U were ONE group at the shelf height 1.2 (1.92 m): the shelves
  -- are drawn apart, the counter is waist high; the Prize Room counter ends
  -- at the side edges were 2.0 side walls
  FR_CELADON_CITY_GAME_CORNER = {
    { x = 2, y = 1, x1 = 3, kind = "shelfbox", why = "prize shelf inside the counter U" },
    { x = 7, y = 1, x1 = 8, kind = "shelfbox", why = "prize shelf inside the counter U" },
    { x = 1, y0 = 1, y1 = 3, kind = "counter", why = "prize counter arm (was 1.2 with the shelves)" },
    { x = 9, y0 = 1, y1 = 3, kind = "counter", why = "prize counter arm" },
    { x = 2, y = 3, x1 = 8, kind = "counter", why = "prize counter front" },
  },
  FR_CELADON_CITY_GAME_CORNER_PRIZE_ROOM = {
    { x = 1, y = 1, x1 = 2, kind = "shelfbox", why = "prize shelf beside the counter arm" },
    { x = 6, y = 1, x1 = 7, kind = "shelfbox", why = "prize shelf beside the counter arm" },
    { x = 0, y0 = 1, y1 = 2, kind = "counter", why = "prize counter arm (was 1.2 with the shelves)" },
    { x = 8, y0 = 1, y1 = 2, kind = "counter", why = "prize counter arm" },
    { x = 0, y = 3, kind = "counter", join = true, why = "counter end (was a 2.0 side wall)" },
    { x = 8, y = 3, kind = "counter", join = true, why = "counter end (was a 2.0 side wall)" },
  },
  FR_FUCHSIA_CITY_WARDENS_HOUSE = {
    { x = 0, x1 = 1, y0 = 4, y1 = 5, kind = "table", why = "glass-top table at the west edge (HO-4)" },
    { x = 12, y = 5, kind = "counter", join = true, why = "the table / counter's east end (HO-4)" },
  },
  FR_FOUR_ISLAND_LORELEIS_HOUSE = {
    { x = 9, x1 = 10, y0 = 3, y1 = 4, kind = "table", why = "table at the east edge (HO-4)" },
  },
  FR_POKEMON_LEAGUE_LANCES_ROOM = {
    { x = 21, y = 13, kind = "statue", why = "dragon statue plinth was a 2.0 fin (GY-8)" },
    { x = 25, y = 13, kind = "statue", why = "dragon statue plinth was a 2.0 fin (GY-8)" },
  },
}
-- Oak's lab: the bookshelf tops (9..12, 0) were gates (HO-6); they join the
-- shelves below them
P.MAPS.FR_OAKS_LAB[#P.MAPS.FR_OAKS_LAB + 1] =
  { x = 9, y = 0, x1 = 12, kind = "shelf", join = true, why = "bookshelf top meshed as a gate (HO-6)" }

-- ---------------------------------------------------------------------------
-- module state per context (weak keys: nothing is written on ctx itself)
-- ---------------------------------------------------------------------------
local STATE = setmetatable({}, { __mode = "k" })
function P.state(ctx) return STATE[ctx] end

-- ---------------------------------------------------------------------------
-- small helpers
-- ---------------------------------------------------------------------------
local function behH(ctx, p, hasCounter)
  local b = p.beh
  if not b then return nil end
  if P.PC_ON_COUNTER and hasCounter and (b == 0x83 or b == 0x97) then return false end
  local v = P.EXTRA_H[b]
  if v then return v end
  v = P.CORE_H[b]
  if v then return v end
  if P.ON_TOP[b] then return false end
  local MB = ctx.env.MB or {}
  v = MB.FURNITURE_H and MB.FURNITURE_H[b]
  if v then return v end
  return nil
end
-- the real-life height of a furniture group from its cells' behaviours
-- (the core's rule plus EXTRA_H / PC_ON_COUNTER); nil when unknown
local function groupBehH(ctx, g)
  local hasCounter = false
  for _, p in ipairs(g.cells) do if p.beh == 0x80 then hasCounter = true end end
  local props = ctx.env.IN and ctx.env.IN.props or nil
  local h, known = nil, false
  for _, p in ipairs(g.cells) do
    local v = behH(ctx, p, hasCounter)
    if v == nil then local pr = props and props[p.mid]; v = pr and pr.h or nil end
    if v then known = true; if h == nil or v > h then h = v end end
  end
  if not known then return nil end
  return h
end
P.groupBehH = groupBehH

local function mapRules(ctx)
  local id, pair = ctx.mapId or "", ctx.pair
  local tiles, cuts, wallsOnly, stairArt = {}, {}, {}, {}
  local any = false
  for _, r in ipairs(P.TILES) do
    if (r.pair == nil or r.pair == pair) and (r.maps == nil or id:find(r.maps)) then
      for mid, kind in pairs(r.tiles) do
        tiles[mid] = kind
        any = true
        if r.wallsOnly then wallsOnly[mid] = true end
        if r.stairArt then stairArt[mid] = true end
      end
      for mid in pairs(r.cutBelow or {}) do cuts[mid] = true end
    end
  end
  return any and tiles or nil, P.MAPS[id], cuts, wallsOnly, stairArt
end

-- ---------------------------------------------------------------------------
-- PLAN (pure: reads the grid, writes nothing) -> {
--   targets = { [key] = { cell, kind, entry } },
--   heights = { { group, h, why } },          -- behaviour re-heights
--   unpillar = { { group, h } },               -- pillars that are furniture
--   pedestals = { { group } },                 -- pillars reaching the ceiling
--   skipped = { msg ... } }
-- ---------------------------------------------------------------------------
function P.plan(ctx)
  local plan = { targets = {}, order = {}, heights = {}, unpillar = {}, pedestals = {}, skipped = {} }
  local WH = ctx.WH or 2.0
  local C = ctx.C
  local groups = ctx.env.groups or {}
  -- 1. pillars: a pillar holding a known furniture behaviour is that furniture
  -- (Mart shelves 0x82, the Player / Copycat 2F TV 0x86); a pillar whose
  -- column would reach the ceiling becomes a capped pedestal
  for _, g in ipairs(groups) do
    if g.typeOwner then -- (1.1) a furniture type's group: not PropFix's
    elseif g.pillar then
      local h = groupBehH(ctx, g)
      if h then
        plan.unpillar[#plan.unpillar + 1] = { group = g, h = mmin(h, WH - P.PEDESTAL_GAP) }
      else
        local rows = (g.maxY - g.minY + 2)
        local ht = mmin(WH, rows * (C.PILLAR_ROW_H or 0.55))
        if ht >= WH - 1e-6 then plan.pedestals[#plan.pedestals + 1] = { group = g, rows = rows } end
      end
    elseif not g.slot and not g.fixedH then
      -- 2. counters holding a PC, computer desks
      local special = false
      local hasCounter = false
      for _, p in ipairs(g.cells) do
        if p.beh == 0x80 then hasCounter = true end
        if p.beh and P.EXTRA_H[p.beh] then special = true end
      end
      if hasCounter then for _, p in ipairs(g.cells) do if p.beh == 0x83 then special = true end end end
      if special then
        local h = groupBehH(ctx, g) or P.FURN_DEFAULT
        if mabs(h - (g.h or 0)) > 1e-9 then plan.heights[#plan.heights + 1] = { group = g, h = h } end
      end
    end
  end
  -- 3. tile rules and per-map cells
  local tiles, cells, cuts, wallsOnly, stairArt = mapRules(ctx)
  local function add(p, kind, entry, why)
    local k = key(p.x, p.y)
    if plan.targets[k] then return end
    -- (1.1) one owner per cell: a furniture type's cell (or group) is never a
    -- target, whatever the kind (plant included)
    local owner = p.typeOwner or (p.group and p.group.typeOwner)
    if owner then
      plan.skipped[#plan.skipped + 1] = string.format("(%d,%d) %s: owned by %s", p.x, p.y, kind, tostring(owner))
      return
    end
    local ok, reason = true, nil
    if p.role == "wall" and (p.inWall or p.pocket) then ok, reason = false, "in-wall door / sign or pocket" end
    if p.role == "furniture" and p.group and (p.group.pillar or p.group.slot) then ok, reason = false, "pillar / slot group" end
    if p.exitFrame or (p.isDoor and p.walkable) then ok, reason = false, "door / exit cell" end
    local kd = P.KIND[kind]
    if p.role and p.role ~= "wall" and p.role ~= "furniture" and not (kind == "plant")
        and not ((p.role == "gate" or (p.role == "flat" and p.stair)) and kd and (kd.draw == nil or kd.draw == "box")) then
      ok, reason = false, "role " .. tostring(p.role)
    end
    if p.walkable then ok, reason = false, "walkable" end
    if kind == "plant" then
      local top = ctx:at(p.x, p.y - 1)
      if not (top and top.walkable and top.hasOver) then ok, reason = false, "plant: no leaves above" end
    end
    if not ok then
      plan.skipped[#plan.skipped + 1] = string.format("(%d,%d) %s: %s", p.x, p.y, kind, reason)
      return
    end
    plan.targets[k] = { cell = p, kind = kind, entry = entry, why = why, cut = (entry and entry.cut) or cuts[p.mid] or nil }
    plan.order[#plan.order + 1] = k
  end
  if tiles then
    for y = 0, ctx.H - 1 do
      for x = 0, ctx.W - 1 do
        local p = ctx:at(x, y)
        if p and (p.role == "wall" or ((p.role == "furniture" or p.role == "gate") and not wallsOnly[p.mid])
            or (p.role == "flat" and p.stair and stairArt[p.mid])) then
          local kind = tiles[p.mid]
          if kind then add(p, kind, nil, "tile " .. p.mid) end
        end
      end
    end
  end
  if cells then
    for _, e in ipairs(cells) do
      local y0, y1 = e.y0 or e.y, e.y1 or e.y
      for x = e.x, e.x1 or e.x do
        for y = y0, y1 do
          local p = ctx:at(x, y)
          if p then
            -- a plain floor cell in an explicit entry is left alone (rails / lamps
            -- only claim solid cells)
            if p.role or not p.walkable then add(p, e.kind, e, e.why) end
          else
            plan.skipped[#plan.skipped + 1] = string.format("(%d,%d) %s: no cell", x, y, e.kind)
          end
        end
      end
    end
  end
  return plan
end

-- ---------------------------------------------------------------------------
-- CLASSIFY (the core's journaled step "propfix")
-- ---------------------------------------------------------------------------
-- empty a furniture group and drop it from the shared list (journaled);
-- returns its former cells (still role "furniture", group = the old one)
local function dissolve(ctx, g)
  local cells = {}
  for _, q in ipairs(g.cells) do cells[#cells + 1] = q end
  ctx:set(g, "cells", {})
  local groups = ctx.env.groups
  local keep = {}
  for _, q in ipairs(groups) do if q ~= g then keep[#keep + 1] = q end end
  for i = 1, mmax(#groups, #keep) do ctx:set(groups, i, keep[i]) end
  return cells
end

-- wall cells -> plain cells (role nil), one unwall per column segment of a run
local function unwallCells(ctx, list)
  table.sort(list, function(a, b) if a.x ~= b.x then return a.x < b.x end return a.y < b.y end)
  local i = 1
  while i <= #list do
    local a = list[i]
    local j = i
    while j + 1 <= #list and list[j + 1].x == a.x and list[j + 1].y == list[j].y + 1
        and list[j + 1].runA == a.runA do j = j + 1 end
    -- (re-read: an earlier unwall in this column may have split the run)
    ctx:unwall(a.x, a.y, list[j].y, { as = "floor" })
    i = j + 1
  end
end

local DIRS4 = { { 0, -1 }, { 0, 1 }, { -1, 0 }, { 1, 0 } }

function P.classify(ctx)
  local st = { props = {}, log = {}, plan = nil, version = P.VERSION }
  STATE[ctx] = st
  local plan = P.plan(ctx)
  st.plan = plan
  local function log(fmt, ...) st.log[#st.log + 1] = string.format(fmt, ...) end
  for _, s in ipairs(plan.skipped) do log("skip %s", s) end
  -- 1. behaviour re-heights (counters holding a PC, computer desks)
  for _, a in ipairs(plan.heights) do
    local c1 = a.group.cells[1]
    log("height (%d,%d) %d cells %.2f -> %.2f", c1.x, c1.y, #a.group.cells, a.group.h or -1, a.h)
    ctx:setGroupHeight(a.group, a.h)
  end
  -- 2. pillars that are furniture: a plain box, the capital decal stays hidden
  for _, a in ipairs(plan.unpillar) do
    local g = a.group
    local cap = g.pillar and g.pillar.cap
    local c1 = g.cells[1]
    log("unpillar (%d,%d) %d rows -> box %.2f", c1.x, c1.y, g.maxY - g.minY + 1, a.h)
    ctx:unPillar(g, a.h)
    if cap then ctx:set(cap, "suppressDecal", true) end
  end
  -- 3. pedestals: the pillar's cells claimed; props() draws a capped column
  for _, a in ipairs(plan.pedestals) do
    local g = a.group
    local cells = {}
    for _, q in ipairs(g.cells) do cells[#cells + 1] = q end
    table.sort(cells, function(p, q) return p.y < q.y end)
    local cap = g.pillar.cap
    local n = a.rows
    local ht = mmin(ctx.WH - P.PEDESTAL_GAP, n * (ctx.C.PILLAR_ROW_H or 0.55))
    for _, q in ipairs(cells) do ctx:claim(q.x, q.y, nil, ht) end
    st.props[#st.props + 1] = { type = "pedestal", cells = cells, cap = cap, n = n, ht = ht }
    log("pedestal (%d,%d) %d rows, column %.2f", cells[#cells].x, cells[#cells].y, n - 1, ht)
  end
  -- 4. the tile / map targets
  local drawn, boxes, plants = {}, {}, {}
  for _, k in ipairs(plan.order) do
    local t = plan.targets[k]
    local kd = P.KIND[t.kind]
    local joins = (t.entry and t.entry.join) or (kd and kd.join)
    if kd and (kd.draw == "rail" or kd.draw == "lamp" or (kd.draw == "box" and not joins)) then drawn[#drawn + 1] = t
    elseif kd and kd.draw == "plant" then plants[#plants + 1] = t
    elseif kd then boxes[#boxes + 1] = t end
  end
  -- 4a. drawn props: claim the cells (wall runs split, furniture groups left)
  -- units: rails (all rail cells), lamps (one per map entry), boxes (graves:
  -- one per run along a row; others: one per run down a column, a tile
  -- marked cutBelow ending its unit)
  local railCells, lamps = {}, {}
  local isD = {}
  for _, t in ipairs(drawn) do isD[key(t.cell.x, t.cell.y)] = t end
  local function hOf(t) return (t.entry and t.entry.h) or P.KIND[t.kind].h end
  -- wall cells: one unwall (as claim) per column segment of one run and one
  -- height; the others one claim each
  do
    local ws = {}
    for _, t in ipairs(drawn) do if t.cell.role == "wall" then ws[#ws + 1] = t end end
    table.sort(ws, function(a, b) if a.cell.x ~= b.cell.x then return a.cell.x < b.cell.x end return a.cell.y < b.cell.y end)
    local i = 1
    while i <= #ws do
      local a = ws[i]
      local j = i
      while j + 1 <= #ws and ws[j + 1].cell.x == a.cell.x and ws[j + 1].cell.y == ws[j].cell.y + 1
          and ws[j + 1].cell.runA == a.cell.runA and hOf(ws[j + 1]) == hOf(a) do j = j + 1 end
      ctx:unwall(a.cell.x, a.cell.y, ws[j].cell.y, { as = "claim", h = hOf(a) })
      i = j + 1
    end
  end
  for _, t in ipairs(drawn) do
    local p, kd = t.cell, P.KIND[t.kind]
    log("claim (%d,%d) %s %s [%s]", p.x, p.y, t.kind, tostring(p.role == "ext" and "wall" or p.role), tostring(t.why))
    if p.role ~= "ext" then ctx:claim(p.x, p.y, nil, hOf(t)) end
    if kd.draw == "rail" then railCells[#railCells + 1] = t
    else
      local e = t.entry
      local id
      if kd.draw == "box" then
        local function same(x, y) local q = isD[key(x, y)]; return q and q.kind == t.kind and q or nil end
        if kd.rows then
          local x0 = p.x
          while same(x0 - 1, p.y) do x0 = x0 - 1 end
          id = string.format("r%04d:%04d", p.y, x0)
        else
          local y0 = p.y
          while true do
            local q = same(p.x, y0 - 1)
            if not q or q.cut then break end
            y0 = y0 - 1
          end
          id = string.format("c%04d:%04d", p.x, y0)
        end
      else
        id = e and (e.x .. ":" .. (e.y0 or e.y)) or ("t" .. p.mid)
      end
      lamps[id] = lamps[id] or { type = kd.draw, cells = {}, kind = t.kind, rows = kd.rows, h = (e and e.h) or kd.h }
      table.insert(lamps[id].cells, p)
    end
  end
  if #railCells > 0 then st.props[#st.props + 1] = { type = "rail", cells = railCells } end
  local lampIds = {}
  for id in pairs(lamps) do lampIds[#lampIds + 1] = id end
  table.sort(lampIds)
  for _, id in ipairs(lampIds) do st.props[#st.props + 1] = lamps[id] end
  -- 4b. boxes: wall cells out of their runs, then one furniture group per
  -- 4-connected component of same-kind targets (a tile marked cutBelow ends
  -- its unit: stacked graves / cases stay separate boxes); an entry with
  -- join = true also absorbs the furniture it touches. Different groups side
  -- by side draw their shared faces back to back, enclosed by both boxes.
  if #boxes > 0 then
    local isT = {}
    for _, t in ipairs(boxes) do isT[t.cell] = t end
    local walls = {}
    for _, t in ipairs(boxes) do if t.cell.role == "wall" then walls[#walls + 1] = t.cell end end
    unwallCells(ctx, walls)
    local function link(p, q)
      local a, b = isT[p], isT[q]
      if not (a and b) or a.kind ~= b.kind then return false end
      if q.y == p.y + 1 and a.cut then return false end
      if q.y == p.y - 1 and b.cut then return false end
      return true
    end
    local seen = {}
    for _, t in ipairs(boxes) do
      if not seen[t.cell] then
        local comp, stack, join = {}, { t.cell }, false
        seen[t.cell] = true
        while #stack > 0 do
          local p = stack[#stack]
          stack[#stack] = nil
          comp[#comp + 1] = p
          local e = isT[p].entry
          if (e and e.join) or P.KIND[isT[p].kind].join then join = true end
          for _, d in ipairs(DIRS4) do
            local q = ctx:at(p.x + d[1], p.y + d[2])
            if q and not seen[q] and link(p, q) then seen[q] = true; stack[#stack + 1] = q end
          end
        end
        table.sort(comp, function(a, b) if a.y ~= b.y then return a.y < b.y end return a.x < b.x end)
        local inComp = {}
        for _, p in ipairs(comp) do inComp[p] = true end
        local h = 0
        for _, p in ipairs(comp) do
          local tt = isT[p]
          h = mmax(h, (tt.entry and tt.entry.h) or P.KIND[tt.kind].h)
        end
        -- existing groups: a group lying wholly inside the component is kept
        -- (the first as the result, the others merged into it); target cells
        -- of a group reaching outside leave it
        local whole, wholeList, A = {}, {}, nil
        for _, p in ipairs(comp) do
          local G = p.role == "furniture" and p.group or nil
          if G and whole[G] == nil then
            local all = true
            for _, q in ipairs(G.cells) do if not inComp[q] then all = false end end
            whole[G] = all
            if all then
              if A then wholeList[#wholeList + 1] = G else A = G end
            end
          end
        end
        local add = {}
        for _, p in ipairs(comp) do
          local G = p.role == "furniture" and p.group or nil
          if G == nil then add[#add + 1] = p
          elseif not whole[G] then ctx:leaveGroup(p); add[#add + 1] = p end
        end
        for _, G in ipairs(wholeList) do
          for _, q in ipairs(dissolve(ctx, G)) do add[#add + 1] = q end
        end
        -- join: the furniture groups the component touches
        local nJoin = 0
        if join then
          local done = {}
          for _, p in ipairs(comp) do
            for _, d in ipairs(DIRS4) do
              local q = ctx:at(p.x + d[1], p.y + d[2])
              local G = q and not inComp[q] and q.role == "furniture" and q.group or nil
              if G and G ~= A and not done[G] and not G.pillar and not G.slot and whole[G] == nil
                  and not G.typeOwner then -- (1.1)
                done[G] = true
                nJoin = nJoin + 1
                h = mmax(h, G.h or 0)
                for _, c2 in ipairs(dissolve(ctx, G)) do add[#add + 1] = c2 end
              end
            end
          end
        end
        local g = ctx:furnish(add, h, A)
        ctx:setGroupHeight(g, h)
        local c1 = comp[1]
        log("box (%d,%d) %s %d cells%s%s %.2f", c1.x, c1.y, isT[c1].kind, #g.cells, A and " (kept a group)" or "",
          nJoin > 0 and (" (joined " .. nJoin .. ")") or "", h)
      end
    end
  end
  -- 4c. plants: the mesher's plant (pot + leaves)
  for _, t in ipairs(plants) do
    log("plant (%d,%d)", t.cell.x, t.cell.y)
    ctx:plant(t.cell.x, t.cell.y, true)
  end
  st.changed = #plan.heights + #plan.unpillar + #plan.pedestals + #plan.order
end

-- ---------------------------------------------------------------------------
-- colours from a tile's own texels (single-texel UV rects, mip-safe when a
-- 3 x 3 block of the colour exists)
-- ---------------------------------------------------------------------------
local function rgbOf(c) return mfloor(c / 65536) % 256, mfloor(c / 256) % 256, c % 256 end
local function luma(c) local r, g, b = rgbOf(c); return 0.299 * r + 0.587 * g + 0.114 * b end
local function sat(c) local r, g, b = rgbOf(c); return mmax(r, g, b) - mmin(r, g, b) end
P.luma, P.sat = luma, sat

-- the room's floor colours (>= 16 texels of the floor tile)
local function floorSet(ctx)
  local t = ctx.floorMid and ctx:tex(ctx.floorMid)
  local set = {}
  if t then
    local cnt = {}
    for i = 1, 256 do cnt[t[i]] = (cnt[t[i]] or 0) + 1 end
    for v, n in pairs(cnt) do if n >= 16 then set[v] = true end end
  end
  return set
end
-- pick a colour from tiles `mids`: mode "sat" (most saturated), "light"
-- (lightest), "grey" (most common low-saturation mid tone), "dark"
function P.pickColour(ctx, mids, mode, exclude)
  local cnt = {}
  for _, m in ipairs(mids) do
    local t = ctx:tex(m)
    if t then for i = 1, 256 do local v = t[i]; if v and v >= 0 then cnt[v] = (cnt[v] or 0) + 1 end end end
  end
  local best, bs = nil, nil
  for v, n in pairs(cnt) do
    if n >= 8 and not (exclude and exclude[v]) then
      local s
      if mode == "sat" then s = sat(v) * 1000 + n
      elseif mode == "light" then s = luma(v) * 1000 + n
      elseif mode == "dark" then s = (255 - luma(v)) * 1000 + n
      else s = (sat(v) < 24 and luma(v) > 60 and luma(v) < 210) and (100000 + n) or n end
      if bs == nil or s > bs or (s == bs and v < best) then best, bs = v, s end
    end
  end
  return best
end
-- a UV rect sampling colour rgb from one of `mids`
function P.texelUv(ctx, mids, rgb)
  if not rgb then return nil end
  local env = ctx.env
  local fallback
  for _, m in ipairs(mids) do
    local t, r = ctx:tex(m), env.underRect(m)
    if t and r then
      for row = 1, 14 do
        for col = 1, 14 do
          local ok = t[row * 16 + col + 1] == rgb
          if ok then
            for dy = -1, 1 do
              for dx = -1, 1 do if t[(row + dy) * 16 + col + dx + 1] ~= rgb then ok = false; break end end
              if not ok then break end
            end
          end
          if ok then
            local f0, f1 = (col + 0.5) / 16, (row + 0.5) / 16
            return env.subRect(r, f0, f1, f0, f1)
          end
        end
      end
      if not fallback then
        for i = 1, 256 do
          if t[i] == rgb then
            local col, row = (i - 1) % 16, mfloor((i - 1) / 16)
            local f0, f1 = (col + 0.5) / 16, (row + 0.5) / 16
            fallback = env.subRect(r, f0, f1, f0, f1)
            break
          end
        end
      end
    end
  end
  return fallback
end

-- the UV of the colour picked from tiles `mids` by `mode` (floor colours
-- excluded), cached per atlas: the texel scans run once per session and
-- tile set, not on every rebuild -> rect | false
local uvCacheA = setmetatable({}, { __mode = "k" })
function P.pickUv(ctx, mids, mode, exclude)
  local atlas = ctx.env.atlas
  local k = table.concat(mids, ",") .. "|" .. mode .. "|" .. tostring(ctx.floorMid)
  local byA = atlas and uvCacheA[atlas]
  if byA and byA[k] ~= nil then return byA[k] or nil end
  local uv = P.texelUv(ctx, mids, P.pickColour(ctx, mids, mode, exclude)) or false
  if atlas then
    if not byA then byA = {}; uvCacheA[atlas] = byA end
    byA[k] = uv
  end
  return uv or nil
end

-- ---------------------------------------------------------------------------
-- PROPS (drawn geometry, base lists)
-- ---------------------------------------------------------------------------
local Kit
local function kit(ctx)
  if Kit == nil then
    local ok, m = pcall(ctx.env.require, "mesh/interiors/Kit")
    Kit = (ok and type(m) == "table") and m or false
  end
  return Kit or nil
end
P.setKit = function(k) Kit = k end -- tests

-- a fallback box of a claimed cell's own art (same as the core's claimFallback)
local function fallbackBox(ctx, list, p, h)
  local r = ctx.env.underRect(p.mid)
  if not r then return end
  local g = p.hgt or 0
  local x0, z0, x1, z1 = p.x + 0.0, p.y + 0.0, p.x + 1.0, p.y + 1.0
  ctx:hquad(list, x0, z0, x1, z1, g + h, r)
  ctx:vquad(list, x0, z1, x1, z1, g, g + h, r[1], r[3], r[2], r[4], 0, 0, 1)
  ctx:vquad(list, x1, z0, x0, z0, g, g + h, r[1], r[3], r[2], r[4], 0, 0, -1)
  ctx:vquad(list, x0, z0, x0, z1, g, g + h, r[1], r[3], r[2], r[4], -1, 0, 0)
  ctx:vquad(list, x1, z1, x1, z0, g, g + h, r[1], r[3], r[2], r[4], 1, 0, 0)
end

-- the boundary a rail may run up to on side (dx, dy) of cell p: the room's
-- edge wall face (void / off-map / exit frame: the synthetic wall's inset
-- plane; a wall run: the cell edge) or nil (anything else: a free end)
local function railStop(ctx, p, dx, dy)
  local q = ctx:at(p.x + dx, p.y + dy)
  if not q or q.exitFrame then return ctx.ins end
  if q.role == "wall" then return 0 end
  return nil
end

-- railings over the claimed rail cells: nodes at the cells' rail lines,
-- straight runs (E-W runs own the junction squares; N-S runs stop at them),
-- a top rail, a mid rail and posts
local function drawRails(ctx, pr, list)
  local K = kit(ctx)
  if not K then error("Kit missing") end
  local T, TM, PW = 0.08, 0.04, 0.07
  local node = {}
  for _, t in ipairs(pr.cells) do node[key(t.cell.x, t.cell.y)] = t end
  local function at(x, y) return node[key(x, y)] end
  local fl = floorSet(ctx)
  local uvCache = {}
  local function uvs(t)
    local p = t.cell
    local kd = P.KIND[t.kind]
    local ck = p.mid .. ":" .. t.kind
    local u = uvCache[ck]
    if not u then
      local pal = K.palette(ctx)
      u = { rail = P.pickUv(ctx, { p.mid }, kd.colour or "sat", fl) or pal.light or ctx.darkUv,
            post = P.pickUv(ctx, { p.mid }, kd.colour == "light" and "grey" or "dark", fl) or pal.trim or ctx.darkUv }
      uvCache[ck] = u
    end
    return u
  end
  -- the rail line in the cell: entry.line applies to the entry's own axis
  local function lineOf(t, axis)
    local e = t.entry
    local l = (e and e.line and (e.axis or "ew") == axis) and e.line or 0.5
    if axis == "ns" then return t.cell.x + l end
    return t.cell.y + l
  end
  local function hasEW(t) local p = t.cell; return at(p.x - 1, p.y) ~= nil or at(p.x + 1, p.y) ~= nil end
  local function hasNS(t) local p = t.cell; return at(p.x, p.y - 1) ~= nil or at(p.x, p.y + 1) ~= nil end
  local posts = {}
  local function post(x, z, g, h, uv)
    for _, q in ipairs(posts) do if mabs(q[1] - x) < 0.2 and mabs(q[2] - z) < 0.2 then return end end
    posts[#posts + 1] = { x, z }
    K.box(ctx, list, x - PW / 2, z - PW / 2, x + PW / 2, z + PW / 2, g, g + h - T, { side = uv }, { noTop = true })
  end
  local runs = {}
  local done = { ew = {}, ns = {} }
  for _, t in ipairs(pr.cells) do
    local p = t.cell
    local axisDefault = (t.entry and t.entry.axis) or "ew"
    for _, axis in ipairs({ "ew", "ns" }) do
      local mine = axis == "ew" and hasEW(t) or (axis == "ns" and hasNS(t))
      local lone = not hasEW(t) and not hasNS(t) and axis == axisDefault
      if (mine or lone) and not done[axis][t] then
        -- walk to the run's start, then collect it
        local dx, dy = (axis == "ew") and 1 or 0, (axis == "ns") and 1 or 0
        local s = t
        while at(s.cell.x - dx, s.cell.y - dy) do s = at(s.cell.x - dx, s.cell.y - dy) end
        local seq = { s }
        done[axis][s] = true
        while at(seq[#seq].cell.x + dx, seq[#seq].cell.y + dy) do
          local n = at(seq[#seq].cell.x + dx, seq[#seq].cell.y + dy)
          seq[#seq + 1] = n
          done[axis][n] = true
        end
        runs[#runs + 1] = { axis = axis, seq = seq }
      end
    end
  end
  for _, run in ipairs(runs) do
    local seq, axis = run.seq, run.axis
    local first, last = seq[1], seq[#seq]
    local u = uvs(first)
    local kd = P.KIND[first.kind]
    local g = first.cell.hgt or 0
    local h = (first.entry and first.entry.h) or kd.h
    local line = lineOf(first, axis)
    -- run span along its axis (cell units): node centres, then the ends
    local a, b, skipA, skipB
    local function ends(t, sgn)
      local p = t.cell
      local cross
      if axis == "ew" then cross = hasNS(t) else cross = hasEW(t) end
      if cross and axis == "ns" then
        return lineOf(t, "ew") - sgn * (T / 2), true -- stop at the E-W run's face
      elseif cross and axis == "ew" then
        -- own the junction: to the far side of the N-S rail's line
        local l = lineOf(t, "ns")
        return l + sgn * (T / 2), false
      end
      local dx, dy = (axis == "ew") and sgn or 0, (axis == "ns") and sgn or 0
      local stop = railStop(ctx, p, dx, dy)
      local edge = (axis == "ew") and (sgn > 0 and p.x + 1 or p.x) or (sgn > 0 and p.y + 1 or p.y)
      if stop then return edge - sgn * stop, true end
      return edge - sgn * 0.1, false -- a free end, just short of the cell edge
    end
    a, skipA = ends(first, -1)
    b, skipB = ends(last, 1)
    if b > a + 1e-6 then
      local yTop = g + h
      local ym = g + h * 0.45
      if axis == "ew" then
        local sk = { w = skipA, e = skipB }
        K.box(ctx, list, a, line - T / 2, b, line + T / 2, yTop - T, yTop, { top = u.rail, side = u.rail }, { skip = sk })
        K.box(ctx, list, a, line - TM / 2, b, line + TM / 2, ym - TM / 2, ym + TM / 2, { top = u.rail, side = u.rail }, { skip = sk })
      else
        local sk = { n = skipA, s = skipB }
        K.box(ctx, list, line - T / 2, a, line + T / 2, b, yTop - T, yTop, { top = u.rail, side = u.rail }, { skip = sk })
        K.box(ctx, list, line - TM / 2, a, line + TM / 2, b, ym - TM / 2, ym + TM / 2, { top = u.rail, side = u.rail }, { skip = sk })
      end
      -- posts: both ends (inset) and every <= kd.posts between
      local pa, pb = a + PW / 2 + 0.02, b - PW / 2 - 0.02
      local n = mmax(1, math.ceil((pb - pa) / (kd.posts or 1.0) - 1e-6))
      for i = 0, n do
        local s = pa + (pb - pa) * i / n
        if axis == "ew" then post(s, line, g, h, u.post) else post(line, s, g, h, u.post) end
      end
    end
  end
end

-- a floor lamp on the lowest claimed cell: base disc, pole, shade
local function drawLamp(ctx, pr, list)
  local K = kit(ctx)
  if not K then error("Kit missing") end
  local cells = pr.cells
  table.sort(cells, function(p, q) return p.y < q.y end)
  local base = cells[#cells]
  local g = base.hgt or 0
  local h = P.KIND[pr.kind].h
  local mids = {}
  for _, p in ipairs(cells) do mids[#mids + 1] = p.mid end
  local fl = floorSet(ctx)
  local pal = K.palette(ctx)
  local uPole = P.pickUv(ctx, mids, "grey", fl) or pal.trim or ctx.darkUv
  local uShade = P.pickUv(ctx, mids, "light", fl) or pal.light or uPole
  local cx, cz = base.x + 0.5, base.y + 0.5
  K.cylinder(ctx, list, cx, cz, 0.16, g, g + 0.04, 8, uPole, uPole)
  K.cylinder(ctx, list, cx, cz, 0.03, g + 0.04, g + h - 0.2, 6, uPole, nil)
  K.cylinder(ctx, list, cx, cz, 0.18, g + h - 0.22, g + h, 8, uShade, uShade)
end

-- a box drawn by this module over a unit of claimed cells, inset inside
-- them (no face on another box's plane). rows: one box along a row, every
-- cell's own art on its stretch of the top and the front, the art's top strip
-- behind, edge strips at the ends. columns: the mesher's furniture look (the
-- north rows' art stretched over the top, the south row's art in front,
-- edge strips on the sides)
local function drawBox(ctx, pr, list)
  local env = ctx.env
  local kd = P.KIND[pr.kind]
  local ins = kd.inset or P.BOX_INSET
  local iw, ie, inn, is = ins[1], ins[2], ins[3], ins[4]
  local h = pr.h or kd.h
  local ST = (ctx.C.WALL_STRIP_TEXELS or 3) / 16
  local cells = pr.cells
  local sub = env.subRect
  local function R(p) local r = env.underRect(p.mid); if not r then error("no art " .. tostring(p.mid)) end; return r end
  if pr.rows then
    table.sort(cells, function(a, b) return a.x < b.x end)
    local y = cells[1].y
    local g = cells[1].hgt or 0
    local x0, x1 = cells[1].x + iw, cells[#cells].x + 1 - ie
    local z0, z1 = y + inn, y + 1 - is
    for i, p in ipairs(cells) do
      local r = R(p)
      local a = (i == 1) and x0 or p.x
      local b = (i == #cells) and x1 or p.x + 1
      local fa, fb = a - p.x, b - p.x
      ctx:hquad(list, a, z0, b, z1, g + h, sub(r, fa, inn, fb, 1 - is))
      local sr = sub(r, fa, 0, fb, 1)
      ctx:vquad(list, a, z1, b, z1, g, g + h, sr[1], sr[3], sr[2], sr[4], 0, 0, 1)
      local nr = sub(r, fa, 0, fb, ST)
      ctx:vquad(list, b, z0, a, z0, g, g + h, nr[3], nr[1], nr[2], nr[4], 0, 0, -1)
    end
    local wr = sub(R(cells[1]), 0, 0, ST, 1)
    ctx:vquad(list, x0, z0, x0, z1, g, g + h, wr[1], wr[3], wr[2], wr[4], -1, 0, 0)
    local er = sub(R(cells[#cells]), 1 - ST, 0, 1, 1)
    ctx:vquad(list, x1, z1, x1, z0, g, g + h, er[1], er[3], er[2], er[4], 1, 0, 0)
    return
  end
  table.sort(cells, function(a, b) return a.y < b.y end)
  local top, bot = cells[1], cells[#cells]
  local g = bot.hgt or 0
  local x = top.x
  local x0, x1 = x + iw, x + 1 - ie
  local z0, z1 = top.y + inn, bot.y + 1 - is
  local n = #cells
  if n == 1 then
    ctx:hquad(list, x0, z0, x1, z1, g + h, sub(R(top), iw, inn, 1 - ie, 1 - is))
  else
    for k = 1, n - 1 do
      local za = z0 + (z1 - z0) * (k - 1) / (n - 1)
      local zb = z0 + (z1 - z0) * k / (n - 1)
      ctx:hquad(list, x0, za, x1, zb, g + h, sub(R(cells[k]), iw, 0, 1 - ie, 1))
    end
  end
  local sr = sub(R(bot), iw, 0, 1 - ie, 1)
  ctx:vquad(list, x0, z1, x1, z1, g, g + h, sr[1], sr[3], sr[2], sr[4], 0, 0, 1)
  local nr = sub(R(top), iw, 0, 1 - ie, ST)
  ctx:vquad(list, x1, z0, x0, z0, g, g + h, nr[3], nr[1], nr[2], nr[4], 0, 0, -1)
  for k, p in ipairs(cells) do
    local za = (k == 1) and z0 or p.y
    local zb = (k == n) and z1 or p.y + 1
    local r = R(p)
    local wr = sub(r, 0, 0, ST, 1)
    ctx:vquad(list, x0, za, x0, zb, g, g + h, wr[1], wr[3], wr[2], wr[4], -1, 0, 0)
    local er = sub(r, 1 - ST, 0, 1, 1)
    ctx:vquad(list, x1, zb, x1, za, g, g + h, er[1], er[3], er[2], er[4], 1, 0, 0)
  end
end

-- a capped pedestal column (the mesher's pillar, PEDESTAL_GAP below the ceiling)
local function drawPedestal(ctx, pr, opaque, over)
  local env, C = ctx.env, ctx.C
  local ST = (C.WALL_STRIP_TEXELS or 3) / 16
  local cells = pr.cells
  local bottom = cells[#cells]
  local g = bottom.hgt or 0
  local col = { pr.cap }
  for _, q in ipairs(cells) do col[#col + 1] = q end
  local n = #col
  local Ht = pr.ht
  local ins = C.PILLAR_INSET or 0.12
  local x0, x1, z0, z1 = bottom.x + ins, bottom.x + 1 - ins, bottom.y + ins, bottom.y + 1 - ins
  local lift = C.FACADE_OVER_LIFT or 0.004
  for k = 1, n do
    local q = col[n - k + 1]
    local ya, yb = g + Ht * (k - 1) / n, g + Ht * k / n
    local list, rr, lf = opaque, env.underRect(q.mid), 0
    if q == pr.cap then
      local ov = env.overRect(q.mid)
      if ov then
        list, rr, lf = over, ov, lift
        local r2 = env.underRect(col[2].mid)
        if r2 then
          for _, dn in ipairs({ "down", "left", "right", "up" }) do
            env.faceQuad(opaque, dn, x0, x1, z0, z1, ya, yb, env.subRect(r2, 0, 0, 1, 0.1))
          end
        end
      end
    end
    if rr then
      env.faceQuad(list, "down", x0, x1, z0, z1 + lf, ya, yb, rr)
      env.faceQuad(list, "left", x0 - lf, x1, z0, z1, ya, yb, env.subRect(rr, 0, 0, ST, 1))
      env.faceQuad(list, "right", x0, x1 + lf, z0, z1, ya, yb, env.subRect(rr, 1 - ST, 0, 1, 1))
      env.faceQuad(list, "up", x0, x1, z0 - lf, z1, ya, yb, env.subRect(rr, 0, 0, 1, ST))
    end
  end
  local tr = env.underRect(col[mmin(2, n)].mid)
  if tr then env.hQuad(opaque, x0, z0, x1, z1, g + Ht, env.subRect(tr, 0, 0, 1, ST)) end
  -- (the mesher counts the pillars it draws; this one is drawn here, capped)
  local stats = env.stats
  if type(stats) == "table" then stats.pillarsDrawn = (stats.pillarsDrawn or 0) + 1 end
end

-- a prop's cells are still this module's claims (else its classify step was
-- rolled back: nothing to draw)
local function stillClaimed(pr)
  for _, c in ipairs(pr.cells) do
    local p = c.cell or c
    if p.role ~= "ext" then return false end
  end
  return true
end

function P.props(ctx)
  local st = STATE[ctx]
  if not st or #st.props == 0 then return end
  local live = {}
  for _, pr in ipairs(st.props) do if stillClaimed(pr) then live[#live + 1] = pr end end
  if #live == 0 then st.props = {}; return end
  st.props = live
  local opaque = ctx:buffer("opaque")
  local over = ctx:buffer("over")
  st.drawn, st.failed = 0, 0
  for _, pr in ipairs(st.props) do
    local n0, v0 = #opaque, #over
    local ok, err = pcall(function()
      if pr.type == "rail" then drawRails(ctx, pr, opaque)
      elseif pr.type == "lamp" then drawLamp(ctx, pr, opaque)
      elseif pr.type == "pedestal" then drawPedestal(ctx, pr, opaque, over)
      elseif pr.type == "box" then drawBox(ctx, pr, opaque) end
    end)
    if ok then
      st.drawn = st.drawn + 1
    else
      -- this prop only: drop what it emitted, draw its cells as boxes
      for i = #opaque, n0 + 1, -1 do opaque[i] = nil end
      for i = #over, v0 + 1, -1 do over[i] = nil end
      st.failed = st.failed + 1
      st.log[#st.log + 1] = "prop " .. tostring(pr.type) .. " failed: " .. tostring(err)
      local cells = pr.cells
      for _, c in ipairs(cells) do
        local p = c.cell or c
        fallbackBox(ctx, opaque, p, p.claimH or 0.7)
      end
    end
  end
end

return P
