-- FRLG_VOXEL / interiors team: props/Rail.lua -- railings (wave 4,
-- 2026-10-02; scout INVENTORY "Railings / banisters").
--
-- Where (offline census of all 263 indoor maps on the w4base tree): PropFix
-- draws 390 rail / banister cells on 25 maps today (thin top rail, mid rail
-- and posts in a flat colour). This version takes the 351 harbor railing cells:
-- 39 per map on the 9 Sevii / Birth Island / Navel Rock harbors (pair
-- "harbor", one layout): the quay railing (row 4), the pier's two side rails
-- (columns 6 and 10) and its front rails (row 6), and the long railing along
-- the south edge (row 12). Wall cells and furniture cells alike; none is
-- walkable, so nothing here ever blocks a cell the player walks on.
-- Not taken (PropFix keeps drawing them, unchanged): the 39 stair banister
-- cells (gatehouse 1F / 2F, Celadon Condominiums 1F-3F, Player's / Copycat's
-- house 2F, Pewter Museum 1F). Their art is a diagonal stair side or a
-- stairwell frame, not a straight railing (RESULTS.md, user decision U1).
--
-- How it is drawn: the art's own railing, a thin relief piece per straight
-- run (Relief.piece). Seen from the game's camera an east-west railing shows
-- its top bar (art rows TOP) and below it RAIL_H * 16 rows of front: the
-- bar's lower outline, the posts and pickets, the white mid rail and the
-- foot. So the piece is TOP rows deep (2 px = 0.125 cell), RAIL_H high, its
-- top laid with the bar rows 1:1 and its front with the rows below 1:1. A
-- north-south rail is the same bar seen lengthwise: a piece the bar's two
-- columns wide down the run. Every piece is closed on its own (front, top,
-- back, both flanks) and stands GAP off every other piece and cell border it
-- does not continue across, so no two faces touch and nothing sits on a wall
-- plane (inset 1/64, wave-1 lesson). The cell's ground is the room floor, as
-- PropFix left it.
--
-- Method after pokeemerald-3Ds-dualscreen (ZallaxDev, MIT) through
-- props/Relief.lua (the MIT text is in Relief.lua's header): a fence is a
-- relief piece on the art's own footprint, front rows upright, the rows
-- above on the top. No code of his is copied here. Every texel is our own
-- ROM-extracted art read through the atlas. Mod sandbox: no globals; the
-- debug, package and io libraries are never used; `...` is V in the game,
-- nil in tests. State lives on ts only.
local V = ...
local _ = V

local T = {
  id = "Rail", version = "rail 0.1 (2026-10-02)",
  walkable = false,
  maxWalkH = 0.56,
  walls = true,          -- most harbor railing cells are wall-run cells (as PropFix took them)
  heightAt = false,      -- collision unchanged: the cells stay solid
  supersedes = { "rail" }, -- PropFix's harbor rails (banisters stay PropFix's)
  budget = 400,          -- measured per harbor in RESULTS.md
  sourceMids = nil,      -- only the cells themselves
  stretchedAllowed = 0,
  windingExempt = 0,
}

-- user default (scout PLAN Q1): real-life heights, 1 cell = 1.6 m
T.RAIL_H = 0.65          -- railing 1.04 m (PropFix's rail height): the front's 10.4 rows 1:1
T.TOP = { 1, 3 }         -- art rows (px) of the top bar laid on the piece's top: its depth
T.GAP = 1 / 64           -- every free end / junction kept this far off borders and other pieces
T.ON = true              -- false: take nothing (PropFix's rails as before)

-- per tileset pair and metatile (reviewed against the atlas, RESULTS.md):
--   ew = { a, b }  an east-west railing from column a to b (px, b exclusive)
--   ns = { a, b, end }  a north-south rail in columns a..b; end "below": it
--        starts at this cell's east-west railing (a corner, the run goes
--        south), "above": it ends at this cell's railing (the run comes
--        from the north); nil: through the whole cell
T.TILES = {
  harbor = {
    [653] = { ew = { 0, 16 } },                          -- quay railing
    [677] = { ew = { 0, 16 } },                          -- south-edge railing
    [661] = { ew = { 0, 14 } },                          -- pier front, west part (free east end)
    [669] = { ew = { 2, 16 } },                          -- pier front, east part (free west end)
    [654] = { ew = { 0, 5 }, ns = { 3, 5, "below" } },   -- quay -> pier west rail (corner)
    [662] = { ns = { 3, 5 } },                           -- pier west rail
    [655] = { ew = { 3, 16 }, ns = { 3, 5, "above" } },  -- pier west rail -> front (corner)
    [652] = { ew = { 11, 16 }, ns = { 11, 13, "below" } }, -- quay -> pier east rail (corner)
    [660] = { ns = { 11, 13 } },                         -- pier east rail
    [663] = { ew = { 0, 13 }, ns = { 11, 13, "above" } },  -- pier front -> east rail (corner)
  },
}

local function key(x, y) return y * 65536 + x end

-- a railing cell this type takes (pure): a known tile of the map's pair, a
-- solid wall-run or furniture cell, not yet owned
local function specOf(ctx, c, pair)
  local tab = T.TILES[pair or ""]
  local s = c and tab and tab[c.mid]
  if not s then return nil end
  if c.walkable or c.claimOwner or c.typeOwner then return nil end
  if c.role ~= "wall" and c.role ~= "furniture" then return nil end
  if c.inWall or c.pocket or c.exitFrame or c.isDoor or c.stair then return nil end
  local g = c.group
  if g and (g.pillar or g.slot or g.typeOwner) then return nil end
  return s
end
T._specOf = specOf -- (tests)

function T.applies(ctx, idx)
  if not T.ON then return false end
  local tab = T.TILES[idx.pair or ctx.pair or ""]
  if not tab then return false end
  for mid in pairs(tab) do if idx.byMid[mid] then return true end end
  return false
end

-- PURE: the railing cells, row-major
function T.match(ctx, idx)
  local want = {}
  if not T.ON then return want end
  local pair = idx.pair or ctx.pair
  local tab = T.TILES[pair or ""]
  if not tab then return want end
  local mids = {}
  for mid in pairs(tab) do mids[#mids + 1] = mid end
  table.sort(mids)
  for _, mid in ipairs(mids) do
    for _, c in ipairs(idx.byMid[mid] or {}) do
      if specOf(ctx, c, pair) then want[#want + 1] = c end
    end
  end
  table.sort(want, function(a, b) if a.y ~= b.y then return a.y < b.y end return a.x < b.x end)
  return want
end

function T.classify(ctx, cells, ts)
  -- role ext: the mesher draws the room floor there, props() the railing;
  -- the claim height is the railing's (topAt, fallback box)
  for _, c in ipairs(cells) do ctx:claim(c.x, c.y, nil, T.RAIL_H) end
end

-- the runs (pure on the granted cells and the map): straight pieces in cells
--   { x0, x1, z0, z1, first, g }
local function runs(ctx, ts)
  local pair = ctx.pair
  local tab = T.TILES[pair or ""] or {}
  local PX = 16
  local GAP = T.GAP
  local ins = (type(ctx.ins) == "number" and ctx.ins) or 0.06
  local D = (T.TOP[2] - T.TOP[1]) / PX            -- piece depth (the bar rows)
  local at = {}
  for _, c in ipairs(ts.cells) do at[key(c.x, c.y)] = c end
  local function spec(x, y) local c = at[key(x, y)]; return c and tab[c.mid], c end
  local function sameG(a, b) return math.abs((a.hgt or 0) - (b.hgt or 0)) <= 1e-9 end
  -- the foot line (z) of an east-west railing in row y, and its back
  local function foot(y) return y + T.TOP[1] / PX + D + T.RAIL_H end
  -- how far a run end at a cell border stays off it: the room's edge (off
  -- map / exit frame / void): the synthetic wall's inset plane, else GAP
  local function stop(x, y)
    local q = ctx:at(x, y)
    local isVoid = ctx.env and ctx.env.atlas and ctx.env.atlas.isVoid
    if not q or q.exitFrame or q.mid == nil or (isVoid and isVoid(q.mid)) then return ins + GAP end
    return GAP
  end
  local out = {}
  local cells = {}
  for _, c in ipairs(ts.cells) do cells[#cells + 1] = c end
  table.sort(cells, function(a, b) if a.y ~= b.y then return a.y < b.y end return a.x < b.x end)
  -- east-west runs (row-major)
  local doneE = {}
  for _, c in ipairs(cells) do
    local s = tab[c.mid]
    if s and s.ew and not doneE[c] then
      local last = c
      doneE[c] = true
      while true do
        local ls = tab[last.mid]
        local ns, n = spec(last.x + 1, last.y)
        if ls.ew[2] == PX and ns and ns.ew and ns.ew[1] == 0 and sameG(n, c) then
          doneE[n] = true
          last = n
        else break end
      end
      local a, b = s.ew[1], tab[last.mid].ew[2]
      local x0 = c.x + a / PX
      local x1 = last.x + b / PX
      if a == 0 then x0 = c.x + stop(c.x - 1, c.y) end
      if b == PX then x1 = last.x + 1 - stop(last.x + 1, last.y) end
      local z1 = foot(c.y)
      out[#out + 1] = { x0 = x0, x1 = x1, z0 = z1 - D, z1 = z1, first = c.y + T.TOP[1] / PX, g = c.hgt or 0 }
    end
  end
  -- north-south runs (column-major: x, then y)
  local byCol = {}
  for _, c in ipairs(cells) do byCol[#byCol + 1] = c end
  table.sort(byCol, function(a, b) if a.x ~= b.x then return a.x < b.x end return a.y < b.y end)
  local doneN = {}
  for _, c in ipairs(byCol) do
    local s = tab[c.mid]
    if s and s.ns and not doneN[c] then
      local last = c
      doneN[c] = true
      while tab[last.mid].ns[3] ~= "above" do
        local ns, n = spec(last.x, last.y + 1)
        if ns and ns.ns and ns.ns[1] == s.ns[1] and ns.ns[2] == s.ns[2] and ns.ns[3] ~= "below" and sameG(n, c) then
          doneN[n] = true
          last = n
        else break end
      end
      local z0, z1
      if s.ns[3] == "below" then z0 = foot(c.y) + GAP else z0 = c.y + stop(c.x, c.y - 1) end
      local le = tab[last.mid].ns[3]
      if le == "above" then z1 = foot(last.y) - D - GAP else z1 = last.y + 1 - stop(last.x, last.y + 1) end
      if z1 - z0 > 2 / PX then
        out[#out + 1] = { x0 = c.x + s.ns[1] / PX, x1 = c.x + s.ns[2] / PX, z0 = z0, z1 = z1, first = z0, g = c.hgt or 0 }
      end
    end
  end
  return out
end
T._runs = runs -- (tests)

function T.props(ctx, ts)
  local R = ts.lib.Relief
  local under = ctx:buffer("opaque")
  for _, r in ipairs(runs(ctx, ts)) do
    R.piece(ctx, { x0 = r.x0, x1 = r.x1, z0 = r.z0, z1 = r.z1, h = T.RAIL_H, g = r.g, first = r.first,
      back = true, flanks = { w = true, e = true }, under = under, tag = "rail" })
  end
end

return T
