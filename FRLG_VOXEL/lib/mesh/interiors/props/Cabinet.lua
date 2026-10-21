-- FRLG_VOXEL / interiors team: props/Cabinet.lua -- the glass-door cupboards
-- (behaviour 0x89) and the dressers (0x8B) of the homes (wave 2, 2026-10-02;
-- scout INVENTORY "Cabinet / cupboard" and "Dresser", PLAN.md 2.5).
--
-- What it takes: every 0x89 / 0x8B cell whose tile is a reviewed cupboard or
-- dresser tile of its tileset pair (T.PIECES; each checked against the 2D art,
-- workspace notes): a cupboard is the two cells m, m + 1 side by side, a
-- dresser one cell. Left to the core on purpose:
--   * a piece whose furniture group stands on two grounds (the core levels
--     such groups after the types, which moves heightAt; lesson of wave 1);
--   * a piece whose furniture group would change height when the piece
--     leaves it: the kitchen worktops the cupboard is merged with in most
--     homes (the group is 0.75 because of the cupboard; alone it is a 0.55
--     kitchen), the Celadon restaurant counter. That re-height is the
--     kitchen's / counter's own business (the scope gate counts it against
--     this type); once the Kitchen type has taken its cells the group holds
--     only the cupboard and this type takes it (RESULTS.md).
--
-- How it is drawn: one relief piece per cupboard / dresser through
-- ts.lib.Relief (method after pokeemerald-3Ds-dualscreen, ZallaxDev, MIT; the
-- licence text is in Relief.lua's header, no code of his is copied here), on
-- the art's own outline (the cupboard is 23 px wide), plus, beside the
-- cupboard, the small white bin the art draws next to it as its own piece
-- (Zallax's one-piece-per-object approach). Real-life heights (user default,
-- scout Q1): CAB_H = DRESSER_H = 0.75 cell (1.2 m), one constant each.
-- FRLG draws these pieces half a cell south of their cell: the drawers and
-- feet lie in the walkable row in front, and the mesher already borrows that
-- tile for the box front and draws the floor there plainly (frontMid). When
-- it did, the piece samples the art that much further south (Relief `lift`
-- with the ground raised by the same amount: the geometry stays on the cell,
-- every texel still 1:1, the picture rows shifted): the drawers are on the
-- front face, not lost. Where the front tile was not borrowed (Fan Club) the
-- picture continues on the floor in front and the piece samples its own rows.
-- Faces that would sit flush on a core face (a bookshelf box beside a dresser,
-- a partition box behind the Fan Club pieces) are inset T.INSET = 1/64 cell.
-- Every texel is the room's own ROM art read through the atlas.
-- No globals, no debug / package / io (mod sandbox); per-build state on ts.
local V = ...
local _ = V

local mabs, mmax, mmin = math.abs, math.max, math.min

local T = {
  id = "Cabinet", version = "cabinet 0.1 (2026-10-02)",
  walkable = false, maxWalkH = 0.56, walls = false, heightAt = false,
  supersedes = {},       -- (PropFix has no cupboard / dresser kind)
  budget = 200,          -- triangles per map (one or two pieces per room, about 30-60 each)
  sourceMids = nil, stretchedAllowed = 0, windingExempt = 0,
}

-- user defaults (scout PLAN Q1): real-life heights, 1 cell = 1.6 m
T.CAB_H = 0.75      -- glass-door cupboard 1.2 m
T.DRESSER_H = 0.75  -- dresser 1.2 m
T.BIN_H = 0.5       -- the bin beside the cupboard, at the art's own proportion (0.8 m)
T.BIN_DEPTH = 7     -- px: the bin's footprint depth (its drawn top)
-- cells: a face that would sit on a core box face (or on another piece of
-- this type) stays this far off it (wave-1 lesson)
T.INSET = 1 / 64

-- layouts, px: columns from the piece's west cell edge, rows from the top of
-- its own row (negative = the row above); foot = the art's bottom row + 1
local GLASS = { kind = "cabinet", w = 2, u0 = 1, u1 = 24, top = -4, foot = 24,
  bin = { u0 = 24, u1 = 31, top = 9, foot = 24 } }
local GLASS_TALL = { kind = "cabinet", w = 2, u0 = 1, u1 = 24, top = -12, foot = 16 } -- lid in the row above
local DRESSER = { kind = "dresser", w = 1, u0 = 0, u1 = 16, top = 2, foot = 24 }
T.LAYOUT = { GLASS = GLASS, GLASS_TALL = GLASS_TALL, DRESSER = DRESSER }

-- reviewed tiles: pair -> { [west cell mid] = layout } (2D art, workspace notes)
T.PIECES = {
  house = { [54] = GLASS, [180] = GLASS, [276] = GLASS, [179] = DRESSER },
  player_house = { [54] = GLASS, [180] = GLASS, [48] = DRESSER, [179] = DRESSER },
  building__rom_082d4c2c = { [180] = GLASS },                      -- Fuchsia City house 2
  building__rom_082d4f14 = { [276] = GLASS, [275] = DRESSER },     -- Lorelei's house
  -- (Trainer Fan Club, building__rom_082d4f74 709 cupboard / 692 dressers: left
  -- to the core. They stand in a partition group at the map's east edge, the
  -- front tile is not borrowed, and the suite check "each cabinet block is one
  -- box" plus an open map-edge flank fail when they leave the group; RESULTS.md)
  building__rom_082d4f44 = { [710] = GLASS_TALL },                 -- Celadon restaurant (0x8B)
}
local BEHS = { 0x89, 0x8B }

local function plain(c, beh)
  return c and c.role == "furniture" and not c.walkable and c.beh == beh
end

-- the pieces of the room (pure): { x, y, L, cells, beh } in row-major order
local function pieces(ctx, idx)
  local tiles = T.PIECES[idx.pair or ctx.pair or ""]
  if not tiles then return {} end
  local list = {}
  for _, b in ipairs(BEHS) do
    for _, c in ipairs(idx.byBeh[b] or {}) do list[#list + 1] = c end
  end
  table.sort(list, function(a, b) if a.y ~= b.y then return a.y < b.y end return a.x < b.x end)
  local out, used = {}, {}
  for _, c in ipairs(list) do
    local L = tiles[c.mid]
    if L and not used[c] and plain(c, c.beh) then
      local cells = { c }
      if L.w == 2 then
        local r = ctx:at(c.x + 1, c.y)
        if r and r.mid == c.mid + 1 and plain(r, c.beh) and r.group == c.group and not used[r] then
          cells[2] = r
        else
          cells = nil
        end
      end
      if cells and c.group and not c.group.pillar then
        for _, p in ipairs(cells) do used[p] = true end
        out[#out + 1] = { x = c.x, y = c.y, L = L, cells = cells, beh = c.beh }
      end
    end
  end
  -- per furniture group: one ground, and the rest of the group keeps its height
  local byG, order = {}, {}
  for _, pc in ipairs(out) do
    local g = pc.cells[1].group
    if not byG[g] then byG[g] = {}; order[#order + 1] = g end
    local t = byG[g]
    t[#t + 1] = pc
  end
  local ok = {}
  for _, g in ipairs(order) do
    local mine = {}
    for _, pc in ipairs(byG[g]) do for _, p in ipairs(pc.cells) do mine[p] = true end end
    local h0 = g.cells[1].hgt or 0
    local good = true
    local rest = {}
    for _, p in ipairs(g.cells) do
      if mabs((p.hgt or 0) - h0) > 1e-9 then good = false end
      if not mine[p] then rest[#rest + 1] = p end
    end
    if good and #rest > 0 and not g.fixedH then
      local h = ctx:realHeightOf({ cells = rest })
      if h ~= nil and mabs(h - (g.h or 0)) > 1e-9 then good = false end
    end
    if good then ok[g] = true end
  end
  local res = {}
  for _, pc in ipairs(out) do
    if ok[pc.cells[1].group] then res[#res + 1] = pc end
  end
  return res
end
T._pieces = pieces -- (tests)

function T.applies(ctx, idx)
  return T.PIECES[idx.pair or ctx.pair or ""] ~= nil and (idx.byBeh[0x89] ~= nil or idx.byBeh[0x8B] ~= nil)
end

function T.match(ctx, idx)
  local want = {}
  for _, pc in ipairs(pieces(ctx, idx)) do
    for _, c in ipairs(pc.cells) do want[#want + 1] = c end
  end
  return want
end

function T.classify(ctx, cells, ts)
  -- whole pieces only: a piece the dispatcher cut short is left to the core
  local set = ts.cellSet
  local byBeh = {}
  for _, c in ipairs(cells) do
    local t = byBeh[c.beh]
    if not t then t = {}; byBeh[c.beh] = t end
    t[#t + 1] = c
  end
  local list = {}
  for _, pc in ipairs(pieces(ctx, { pair = ctx.pair, byBeh = byBeh })) do
    local whole = true
    for _, c in ipairs(pc.cells) do if not set[c] then whole = false end end
    if whole then
      local L = pc.L
      local h = (L.kind == "dresser") and T.DRESSER_H or T.CAB_H
      -- the mesher borrowed the front tile (drawn as plain floor there): the
      -- piece's front shows it
      local borrowed = true
      for _, c in ipairs(pc.cells) do if c.frontMid == nil then borrowed = false end end
      for _, c in ipairs(pc.cells) do ctx:claim(c.x, c.y, nil, h) end
      list[#list + 1] = { x = pc.x, y = pc.y, L = L, h = h, g = pc.cells[1].hgt or 0, borrowed = borrowed }
    end
  end
  ts.pieces = list
end

-- what stands beside: "wall" (wall run / off-map / exit frame), "floor"
-- (walkable), "piece" (anything solid: a core box, another piece)
local function beside(ctx, x, y)
  local c = ctx:at(x, y)
  if not c or c.exitFrame or c.role == "wall" then return "wall" end
  if c.walkable then return "floor" end
  return "piece"
end

function T.props(ctx, ts)
  local R = ts.lib.Relief
  local PX = R.PX
  local under, over = ctx:buffer("opaque"), ctx:buffer("over")
  local I = T.INSET
  for _, p in ipairs(ts.pieces or {}) do
    local L, x, y = p.L, p.x, p.y
    local w = L.w
    -- the picture shift: the art's foot below the cell edge when the front
    -- tile was borrowed (cells)
    local s = p.borrowed and mmax(0, (L.foot - PX) / PX) or 0
    local wK, eK, nK = beside(ctx, x - 1, y), beside(ctx, x + w, y), beside(ctx, x, y - 1)
    if w == 2 and nK == "wall" and beside(ctx, x + 1, y - 1) ~= "wall" then nK = "piece" end
    local x0, x1 = x + L.u0 / PX, x + L.u1 / PX
    local flankW, flankE = true, true
    if L.u0 == 0 then
      if wK == "wall" then flankW = false elseif wK == "piece" then x0 = x0 + I end
    end
    if L.u1 == w * PX then
      if eK == "wall" then flankE = false elseif eK == "piece" then x1 = x1 - I end
    end
    local z0 = y
    local back = false
    if nK == "piece" then z0 = y + I; back = true elseif nK == "floor" then back = true end
    local first = y + L.top / PX
    -- the drawn top never reaches behind the back face
    if first + p.h < z0 + s then first = z0 + s - p.h end
    R.piece(ctx, {
      x0 = x0, x1 = x1, z0 = z0 + s, z1 = y + 1 + s, h = p.h, g = p.g + s, lift = -s,
      first = first, back = back, flanks = { w = flankW, e = flankE },
      under = under, over = over, tag = L.kind,
    })
    local B = L.bin
    if B then
      local F = y + 1 + s                                  -- the foot row in picture rows
      local bfirst = y + B.top / PX
      local bh = mmin(T.BIN_H, F - bfirst)
      local bz0 = mmin(F - T.BIN_DEPTH / PX, bfirst + bh)  -- the drawn top fits the footprint
      local bx1 = x + B.u1 / PX
      local bflankE = true
      if B.u1 == w * PX and eK == "wall" then bflankE = false end
      if bh > 0 and bz0 - s >= y then
        R.piece(ctx, {
          x0 = x + B.u0 / PX + I, x1 = bx1, z0 = bz0, z1 = F, h = bh, g = p.g + s, lift = -s,
          first = bfirst, back = true, flanks = { w = true, e = bflankE },
          under = under, over = over, tag = "bin",
        })
      end
    end
  end
end

return T
