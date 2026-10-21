-- FRLG_VOXEL / interiors team: props/Grave.lua -- the Pokemon Tower graves
-- (wave 4, 2026-10-02; scout INVENTORY "Graves"). Supersedes PropFix's kind
-- "grave" (PropFix 1.1 never targets a cell a type was granted).
--
-- Where: Pokemon Tower 2F-7F (pair building__rom_082d4efc), metatiles 657
-- (purple headstone), 649 (gold headstone) and their wall-shadowed variants
-- 732 / 733 -- the four tiles PropFix's tower rule names. Each headstone is
-- drawn whole inside its own 16 x 16 metatile: rows 0-5 the cap seen from
-- above (outline, white top, purple / gold cap face), row 6 a white ledge,
-- rows 7-13 the body with its name plate, row 14 the grey plinth, row 15 the
-- bottom outline on the floor; columns 0-15 from row 8 down (neighbouring
-- headstones touch), the cap narrower with floor in its corners. Today:
-- PropFix boxes 0.45 high, one per run along a row, the art stretched.
--
-- How it is drawn: one relief piece per headstone through ts.lib.Relief,
-- STONE_H high. STONE_H = 10/16 puts the art's own break -- the white ledge
-- (row 6) -- on the top edge: the ledge, name plate and plinth (rows 6-15)
-- stand upright on the front at 1:1, the cap (rows 0-5) lies on the top. The
-- stone is as deep as its drawn top (6 px, 0.6 m) and stands at the south of
-- its cell (where the picture puts it); the rest of the cell is floor, drawn
-- by the mesher with the floor tile beside the grave (the headstone tile has
-- floor in its corners only). Headstones side by side in a row with the same
-- ground share their side edges (no inner flanks): one row reads as one
-- block, as in the art; flanks only at the ends of a run. Every face is
-- kept INSET off the cell border except those shared edges.
--
-- Not taken: grave tiles the dispatcher would refuse (stair art, in-wall,
-- walkable cells) and grave cells in a furniture group that mixes ground
-- heights; PropFix keeps those as before.
--
-- Method after pokeemerald-3Ds-dualscreen (ZallaxDev, MIT) through
-- props/Relief.lua (the MIT text is in Relief.lua's header); no code of his is
-- copied here. Every texel is our own ROM-extracted art read through the
-- atlas. Mod sandbox: no globals; the debug, package and io libraries are
-- never used; `...` is V in the game, nil in tests. State lives on ts only.
local V = ...
local _ = V

local T = {
  id = "Grave", version = "grave 0.1 (2026-10-02)",
  walkable = false,
  maxWalkH = 0.56,
  walls = true,          -- the graves are 2.0 wall runs in the mesher (PropFix takeover)
  heightAt = false,      -- collision unchanged: the cells stay solid
  supersedes = { "grave" },
  budget = 400,          -- 6 triangles per headstone, as PropFix's rows; measured net in RESULTS.md
  sourceMids = nil,      -- only the granted cells themselves
  stretchedAllowed = 0,
  windingExempt = 0,
}

-- user default (scout PLAN Q1: real-life heights, 1 cell = 1.6 m), one constant
T.STONE_H = 10 / 16      -- headstone 1.0 m: the art's ledge row on the top edge (PropFix: 0.45)
T.INSET = 1 / 64         -- faces kept off the cell border (wave-1 lesson)
T.ON = true              -- false: take nothing (PropFix's boxes, today's look)

T.MAPS = "^FR_POKEMON_TOWER_%dF$"
T.PAIR = "building__rom_082d4efc"
T.TILES = { 649, 657, 732, 733 }  -- fixed order (match is row-major anyway)
local IS_TILE = {}
for _, m in ipairs(T.TILES) do IS_TILE[m] = true end

local function sameGround(a, b) return math.abs((a.hgt or 0) - (b.hgt or 0)) <= 1e-9 end

-- a furniture group whose cells stand on different grounds: skip it whole
local function mixedGroup(c)
  local g = c.role == "furniture" and c.group or nil
  if not g then return false end
  for _, q in ipairs(g.cells or {}) do if not sameGround(q, c) then return true end end
  return false
end

-- a grave cell this type takes (pure): one of the tiles, a solid wall or
-- furniture cell the dispatcher would grant, unowned, not a pillar / slot
local function takes(ctx, c)
  if not (c and IS_TILE[c.mid]) then return false end
  if c.walkable or c.claimOwner or c.typeOwner then return false end
  if c.role ~= "wall" and c.role ~= "furniture" then return false end
  if c.exitFrame or c.isDoor or c.inWall or c.pocket or c.stair then return false end
  if c.role == "furniture" and c.group and (c.group.pillar or c.group.slot) then return false end
  if mixedGroup(c) then return false end
  return true
end
T.takes = takes

function T.applies(ctx, idx)
  if not T.ON or idx.pair ~= T.PAIR or type(idx.mapId) ~= "string" or not idx.mapId:match(T.MAPS) then return false end
  for _, m in ipairs(T.TILES) do if idx.byMid[m] then return true end end
  return false
end

-- a solid grave-tile cell (one of PropFix's grave targets, taken or not)
local function graveArt(c) return c ~= nil and IS_TILE[c.mid] and not c.walkable end

-- Units (no cascade outside our cells): grave cells are linked along a row
-- (PropFix's grave unit: one box per run of grave tiles along a row) and
-- through a furniture group they share. A unit is taken only if every cell of
-- it is a grave this type takes and every group it touches holds graves only.
-- Otherwise the whole unit stays PropFix's, exactly as today: a split run
-- would re-shape PropFix's box over the rest (stair-art graves the dispatcher
-- refuses), and a grave claimed out of a group holding other furniture would
-- make the core re-derive that host's height.
local function units(ctx, cands)
  local id, parent = {}, {}
  local function find(i) while parent[i] ~= i do parent[i] = parent[parent[i]]; i = parent[i] end return i end
  local function union(a, b) a, b = find(a), find(b); if a ~= b then if a < b then parent[b] = a else parent[a] = b end end end
  local cells = {}
  for i, c in ipairs(cands) do id[c] = i; parent[i] = i; cells[i] = c end
  local bad = {}
  for i, c in ipairs(cands) do
    if not takes(ctx, c) then bad[i] = true end
    local e = ctx:at(c.x + 1, c.y)
    if e and id[e] then union(i, id[e]) end
    local g = c.role == "furniture" and c.group or nil
    if g then
      for _, q in ipairs(g.cells or {}) do
        if id[q] then union(i, id[q]) else bad[i] = true end   -- a non-grave cell in the group
      end
    end
  end
  local badRoot = {}
  for i in pairs(bad) do badRoot[find(i)] = true end
  local ok = {}
  for i, c in ipairs(cells) do ok[c] = not badRoot[find(i)] end
  return ok
end
T._units = units -- (tests)

-- PURE: the grave cells, row-major
function T.match(ctx, idx)
  local out = {}
  if not T.applies(ctx, idx) then return out end
  local cands = {}
  for _, m in ipairs(T.TILES) do
    for _, c in ipairs(idx.byMid[m] or {}) do if graveArt(c) then cands[#cands + 1] = c end end
  end
  table.sort(cands, function(a, b) if a.y ~= b.y then return a.y < b.y end return a.x < b.x end)
  local ok = units(ctx, cands)
  for _, c in ipairs(cands) do if ok[c] then out[#out + 1] = c end end
  return out
end

-- the floor beside a grave (pure): the first plain walkable neighbour (N, W,
-- E, S) with the same ground and no over art; else the room's floor
local DIRS = { { 0, -1 }, { -1, 0 }, { 1, 0 }, { 0, 1 } }
local function groundOf(ctx, p)
  local env = ctx.env
  for _, d in ipairs(DIRS) do
    local q = ctx:at(p.x + d[1], p.y + d[2])
    if q and q.walkable and q.role == nil and q.mid and not IS_TILE[q.mid] and sameGround(p, q)
        and not q.isDoor and not q.stair and not q.exitFrame and not q.hasOver
        and not (env.midHasOver and env.midHasOver(q.mid)) then
      return q.mid
    end
  end
  return ctx.floorMid
end
T._groundOf = groundOf -- (tests)

function T.classify(ctx, cells, ts)
  for _, p in ipairs(cells) do ctx:claim(p.x, p.y, groundOf(ctx, p), T.STONE_H) end
end

function T.props(ctx, ts)
  local R = ts.lib.Relief
  local under = ctx:buffer("opaque")
  local I, H = T.INSET, T.STONE_H
  local mine = ts.cellSet or {}
  local function joined(p, dx)
    local q = ctx:at(p.x + dx, p.y)
    return q ~= nil and mine[q] and sameGround(p, q)
  end
  -- one piece per headstone (front, top, back: 6 triangles, as PropFix's
  -- rows); neighbours in a row on one ground share their side edges, so
  -- flanks only at the ends of a run. The back and flanks tile the
  -- headstone's own front rows (its own cell).
  for _, p in ipairs(ts.cells) do
    local jw, je = joined(p, -1), joined(p, 1)
    local x0 = jw and p.x or p.x + I
    local x1 = je and p.x + 1 or p.x + 1 - I
    R.piece(ctx, { x0 = x0, x1 = x1, z0 = p.y + H, z1 = p.y + 1 - I, h = H, g = p.hgt or 0, first = p.y,
      back = true, flanks = { w = not jw, e = not je },
      under = under, tag = "grave" })
  end
end

return T
