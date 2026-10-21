-- FRLG_VOXEL / interiors team: props/Bed.lua -- beds (wave 2: homes,
-- 2026-10-02; scout INVENTORY "Beds", PLAN.md 5).
--
-- Today: the player's bed (Player 2F) is flat floor art with pot and leaf
-- cards on its foot (the mesher reads the foot as a plant); the S.S. Anne
-- 1F cabin beds are 0.45 boxes with the art smeared over the lid; the
-- S.S. Anne 2F / B1F cabin beds stand in the back wall run as 2.0-high
-- wall pillars; Lorelei's bed (Four Island) is a box under flat head art.
--
-- This type builds a bed on one ground as a LOW piece (user default, scout Q2:
-- beds are low pieces the player walks through): a mattress block BED_H high
-- and a thin headboard HEAD_H high at its back, both with the shared relief
-- builder (props/Relief.lua: method after pokeemerald-3Ds-dualscreen,
-- ZallaxDev, MIT; the licence text is in Relief.lua's header). No code or data
-- of that project is copied here; every texel is the room's own ROM art read
-- through the atlas (under and over layers), 1:1, nothing stretched.
-- The two pieces re-project the art exactly (a point at height Y standing at
-- row Z shows at row Z - Y): the headboard's front shows HEAD_H art rows from
-- the frame's first full-width row, the mattress lid the rows below them
-- (pillow, blanket), the mattress front the last BED_H rows above the art's
-- foot. So the pieces stand a little south of where the flat art began; the
-- floor they uncover (the art's head rows) gets the room's plain floor from the
-- same column further south, every other cell keeps its own tile under the piece.
-- A bed whose cells stand on two grounds (the game's elevation bytes give the
-- player's and Lorelei's beds phantom steps; wave-1 lesson: skip furniture on
-- mixed ground) gets no piece: only a foot the mesher read as a potted plant is
-- given back to the flat bed art (Player 2F (2,6)).
--
-- Cells are found by METATILE (pair + the bed's own column of tiles), never by
-- behaviour: the player's bed carries the 0x33 / 0x32 "impassable" bytes,
-- which also sit on seats and on floor cells (Seat skips them the same way).
-- A bed is taken whole or not at all: every cell its art touches (the bed's
-- column and the floor columns beside it where the art spills over), nothing
-- off-map. The S.S. Anne 2F / B1F beds are back-wall cells
-- (walls = true): taken out of the run, the core closes the wall above them.
-- No globals, no debug / package / io (mod sandbox); per-build state on ts.
local V = ...
local _ = V

local T = {
  id = "Bed", version = "bed 0.1 (2026-10-02)",
  walkable = true,       -- the art spills onto walkable floor beside / above the bed
  maxWalkH = 0.56,       -- G4: the headboard top (0.5) + over-art lift
  walls = true,          -- S.S. Anne 2F / B1F: the bed stands in the back wall run
  heightAt = false,
  supersedes = {},       -- (PropFix has no bed kind)
  budget = 250,          -- triangles per map (one bed per room, about 100)
  sourceMids = nil,
  stretchedAllowed = 0,
  windingExempt = 0,
}

-- user defaults (scout PLAN Q1 / Q2), one constant each (1 cell = 1.6 m)
T.BED_H = 5 / 16         -- mattress top over the floor (0.5 m)
T.HEAD_H = 8 / 16        -- headboard top over the floor (0.8 m; G4 walkable limit 0.56)
T.HEAD_T = 2 / 16        -- headboard thickness (cells)
T.FLAT = false           -- true: leave every bed as today (type off)
local INSET = 1 / 64     -- cells: the mattress flanks stay inside the headboard's flank planes

-- reviewed beds: pair -> list of { col = { mids of the bed's column, top down },
--   x0, x1 = the art's outline columns (px from the bed column's left edge),
--   top = the art's first row, foot = the row below its bottom outline,
--   hx0, hx1, htop = the headboard frame's columns and its first full-width row
--   (px from the first bed cell's top-left) }. Measured offline on the atlases
--   (OUT/v2d/blk_*.png; the rows above htop -- the frame's rounded top -- are
--   covered by plain floor).
local PLAYER = { x0 = -4, x1 = 20, top = 14, foot = 46, hx0 = -3, hx1 = 19, htop = 16 } -- player's bed
local CABIN = { x0 = -2, x1 = 18, top = 3, foot = 30, hx0 = -1, hx1 = 17, htop = 6 }    -- S.S. Anne cabin bed
local WHITE = { x0 = -4, x1 = 20, top = 0, foot = 30, hx0 = -3, hx1 = 19, htop = 2 }    -- Lorelei's bed
local function bed(col, g)
  return { col = col, x0 = g.x0, x1 = g.x1, top = g.top, foot = g.foot, hx0 = g.hx0, hx1 = g.hx1, htop = g.htop }
end
T.BEDS = {
  player_house = { bed({ 644, 652, 660 }, PLAYER) },                      -- Player 2F
  general__rom_082d4d94 = { bed({ 809, 817 }, CABIN),                      -- S.S. Anne 1F rooms
                            bed({ 777, 785 }, CABIN) },                    -- S.S. Anne 2F / B1F rooms (wall run)
  building__rom_082d4f14 = { bed({ 745, 753 }, WHITE) },                  -- Four Island, Lorelei's house
}

local PX = 16
local floor, ceil = math.floor, math.ceil

-- the cells a bed's art touches: { cells (row-major), x0, x1, z0, z1 (cells) }
local function footprint(ctx, b, ax, ay)
  local x0, x1 = ax + b.x0 / PX, ax + b.x1 / PX
  local z0, z1 = ay + b.top / PX, ay + b.foot / PX
  local out = {}
  for y = floor(z0), ceil(z1) - 1 do
    for x = floor(x0), ceil(x1) - 1 do
      out[#out + 1] = ctx:at(x, y) or false
    end
  end
  return out, x0, x1, z0, z1
end

-- a cell a bed may take: on the map, the bed's own column (any role: floor,
-- furniture, plant, wall) or plain floor / furniture beside it
local function usable(c, own)
  if not c or c.exitFrame then return false end
  if own then return true end
  return c.role == nil or c.role == "furniture"
end

-- the beds of the room (pure): { { b, ax, ay, cells, foot } }, row-major by
-- anchor. A bed whose cells stand on two grounds (the game's elevation bytes
-- make phantom steps round the player's and Lorelei's beds; wave-1 lesson:
-- skip furniture on mixed ground) gets no piece: only its foot is mended when
-- the mesher read it as a potted plant (foot = { the plant cells and the
-- walkable cells whose over art they carried })
local function beds(ctx, idx)
  local list = T.BEDS[idx.pair or ctx.pair or ""]
  if not list then return {} end
  local out = {}
  for _, b in ipairs(list) do
    for _, a in ipairs(idx.byMid[b.col[1]] or {}) do
      local ok = true
      for i = 2, #b.col do
        local q = ctx:at(a.x, a.y + i - 1)
        if not q or q.mid ~= b.col[i] then ok = false end
      end
      local cells = ok and footprint(ctx, b, a.x, a.y) or {}
      local mixed = false
      if ok then
        local g = a.hgt or 0
        for _, c in ipairs(cells) do
          if not usable(c, c and c.x == a.x) then ok = false
          elseif math.abs((c.hgt or 0) - g) > 1e-9 then mixed = true end
        end
      end
      if ok and mixed then
        local foot = {}
        for i = 1, #b.col do
          local q = ctx:at(a.x, a.y + i - 1)
          local t = q.role == "plant" and q.plantTop
          if t then foot[#foot + 1] = t; foot[#foot + 1] = q end
        end
        if #foot > 0 then out[#out + 1] = { b = b, ax = a.x, ay = a.y, cells = foot, foot = true } end
        ok = false
      end
      if ok then
        -- a bed in a furniture group with cells outside it (never seen) is the core's
        for _, c in ipairs(cells) do
          local grp = c and c.group
          if ok and grp and grp.cells then
            local mine = {}
            for _, q in ipairs(cells) do mine[q] = true end
            for _, q in ipairs(grp.cells) do if not mine[q] then ok = false end end
          end
        end
        if ok then out[#out + 1] = { b = b, ax = a.x, ay = a.y, cells = cells } end
      end
    end
  end
  table.sort(out, function(p, q) if p.ay ~= q.ay then return p.ay < q.ay end return p.ax < q.ax end)
  return out
end
T._beds = beds -- (tests)

function T.applies(ctx, idx)
  if T.FLAT then return false end
  local list = T.BEDS[idx.pair or ctx.pair or ""]
  if not list then return false end
  for _, b in ipairs(list) do if idx.byMid[b.col[1]] then return true end end
  return false
end

-- PURE: every cell of every whole bed, bed by bed, row-major inside a bed
function T.match(ctx, idx)
  local want = {}
  for _, bd in ipairs(beds(ctx, idx)) do
    for _, c in ipairs(bd.cells) do want[#want + 1] = c end
  end
  return want
end

-- the room's plain floor for a cell whose art row the pieces uncover: the first
-- walkable, role-free cell further south in the same column (then north), same
-- ground, not part of the bed
local function plainBelow(ctx, c, set, ybot, ytop)
  local g = c.hgt or 0
  local function ok(q)
    return q and not set[q] and q.walkable and q.role == nil and not q.exitFrame
      and math.abs((q.hgt or 0) - g) <= 1e-9 and q.mid ~= nil
  end
  for y = ybot + 1, ybot + 4 do
    local q = ctx:at(c.x, y)
    if ok(q) then return q.mid end
  end
  for y = ytop - 1, ytop - 4, -1 do
    local q = ctx:at(c.x, y)
    if ok(q) then return q.mid end
  end
  return nil
end

function T.classify(ctx, cells, ts)
  local set = ts.cellSet
  local list = {}
  -- whole beds only: a bed the dispatcher cut short is left to the core.
  -- The anchors (first tile of a bed column) are found from the granted cells:
  -- a granted cell holding the i-th tile of a bed column names its anchor.
  local idx = { pair = ctx.pair, byMid = {} }
  local seen = {}
  for _, b in ipairs(T.BEDS[ctx.pair or ""] or {}) do
    for _, c in ipairs(cells) do
      for i, m in ipairs(b.col) do
        local a = (c.mid == m) and ctx:at(c.x, c.y - i + 1)
        if a and a.mid == b.col[1] and not seen[a] then
          seen[a] = true
          local l = idx.byMid[a.mid] or {}
          l[#l + 1] = a
          idx.byMid[a.mid] = l
        end
      end
    end
  end
  for _, l in pairs(idx.byMid) do
    table.sort(l, function(p, q) if p.y ~= q.y then return p.y < q.y end return p.x < q.x end)
  end
  for _, bd in ipairs(beds(ctx, idx)) do
    local whole = true
    for _, c in ipairs(bd.cells) do if not set[c] then whole = false end end
    if whole and bd.foot then
      -- mixed ground: no piece; the bed's foot is no potted plant (its art
      -- stays flat on the floor, as the rest of the bed)
      for _, c in ipairs(bd.cells) do
        if c.role == "plant" then ctx:plant(c.x, c.y, false) end
      end
    elseif whole then
      local b = bd.b
      local headBack = bd.ay + (b.htop / PX) + T.HEAD_H - T.HEAD_T
      local ytop = bd.cells[1].y
      local ybot = bd.cells[#bd.cells].y
      for _, c in ipairs(bd.cells) do
        -- the rows above the headboard's back lose their art (it now stands
        -- on the headboard): plain floor there; every other cell keeps its tile
        local ground = c.mid
        if c.y < headBack and (c.y + 1) > bd.ay + b.top / PX then
          ground = plainBelow(ctx, c, set, ybot, ytop) or c.mid
        end
        if c.role == "plant" then ctx:plant(c.x, c.y, false) end
        ctx:claim(c.x, c.y, ground, T.BED_H)
      end
      list[#list + 1] = { ax = bd.ax, ay = bd.ay, b = b, g = bd.cells[1].hgt or 0 }
    end
  end
  ts.beds = list
end

function T.props(ctx, ts)
  local R = ts.lib.Relief
  local under, over = ctx:buffer("opaque"), ctx:buffer("over")
  for _, k in ipairs(ts.beds or {}) do
    local b = k.b
    local x0, x1 = k.ax + b.x0 / PX, k.ax + b.x1 / PX
    local foot = k.ay + b.foot / PX
    local htop = k.ay + b.htop / PX
    local hz = htop + T.HEAD_H             -- the headboard's front plane
    local hx0, hx1 = k.ax + b.hx0 / PX, k.ax + b.hx1 / PX
    -- headboard (the frame's columns), in two courses so that every edge meets
    -- an edge (gate G5): the part above the mattress is a lifted piece (up AND
    -- south by BED_H, so the picture is unchanged) whose front shows the art's
    -- rows from the frame's first full-width row and whose top shows the
    -- outline rows; the part below (hidden in front by the mattress) shows the
    -- frame's rows on its back and flanks
    local hw = hx1 - hx0
    R.piece(ctx, { x0 = hx0, x1 = hx1, z0 = hz - T.HEAD_T - T.BED_H, z1 = hz - T.BED_H,
      h = T.HEAD_H - T.BED_H, lift = T.BED_H, g = k.g,
      first = htop, lid = { htop, htop + T.HEAD_T }, sideW = hw,
      under = under, over = over, tag = "head" })
    R.piece(ctx, { x0 = hx0, x1 = hx1, z0 = hz - T.HEAD_T, z1 = hz, h = T.BED_H, g = k.g,
      first = hz - T.HEAD_T - T.BED_H, sides = "lid", sideW = hw,
      under = under, over = over, tag = "head~low" })
    -- mattress: its lid the rows below (pillow, blanket), its front the foot rows.
    -- Built as up to three strips side by side: the middle one (the headboard's
    -- columns) has no back face -- it stands against the headboard's front, and
    -- a back face there would be a coplanar pair with it -- the outer strips
    -- (where the mattress is wider than the headboard) close their own backs.
    -- The flanks tile the whole front band (sideW), as one piece would.
    local mx0, mx1 = x0 + INSET, x1 - INSET
    local sw = mx1 - mx0
    local a, b2 = math.max(mx0, hx0), math.min(mx1, hx1)
    local parts = {}
    if a > mx0 + 1e-9 then parts[#parts + 1] = { mx0, a, true, { w = true, e = false } } end
    parts[#parts + 1] = { a, b2, false, { w = a <= mx0 + 1e-9, e = b2 >= mx1 - 1e-9 } }
    if b2 < mx1 - 1e-9 then parts[#parts + 1] = { b2, mx1, true, { w = false, e = true } } end
    for _, p in ipairs(parts) do
      R.piece(ctx, { x0 = p[1], x1 = p[2], z0 = hz, z1 = foot, h = T.BED_H, g = k.g,
        first = hz - T.BED_H, back = p[3], flanks = p[4], sideW = sw,
        sideU = (p[1] <= mx0 + 1e-9) and mx0 or nil,
        under = under, over = over, tag = "bed" })
    end
  end
end

return T
