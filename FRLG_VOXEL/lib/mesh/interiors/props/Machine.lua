-- FRLG_VOXEL / interiors team: props/Machine.lua -- lab and power machines
-- (behaviours 0x95 and 0x9E), wave 3 (2026-10-02; scout INVENTORY "Lab / power
-- machines": Cinnabar lab, Oak's Lab, Power Plant, Silph Co., Rocket Hideout,
-- Five Island warehouse, Pokemon Mansion, Sea Cottage).
--
-- Today most of these machines (96 of 157 cells) are pictures on the 2.0-tall
-- back-wall block; the rest are the core's furniture boxes (1.2 cells) with the
-- art stretched over the lid. Here every machine is a relief piece built with
-- the shared builder (props/Relief.lua: method after pokeemerald-3Ds-dualscreen,
-- ZallaxDev, MIT -- the licence text is in Relief.lua's header; no code or data
-- of that project is copied here). Every texel is the player's own
-- ROM-extracted art read through the atlas; nothing is invented.
--
-- THE ART. FRLG draws these machines like its bookshelves: the machine collides
-- on its own cell(s), its top outline a few px up in the row behind (or inside
-- its own cell for the short consoles), its foot 8 px down in the walkable row
-- in front. The art differs per drawing, so each known machine metatile carries
-- its own measured extents (ART below: px of the art's top relative to the
-- cell's top edge, px of the foot below the cell). Only metatiles in ART are
-- taken: an unknown drawing is left to the core (it never gets a guessed shape).
-- The piece stands on the collision cell(s); the picture moves north by the
-- foot overhang (as the Bookshelf type does), so the front face shows the art's
-- lowest H * 16 rows down to its foot, 1:1, and the rows above lie on the lid.
-- The foot rows also stay painted on the floor tile in front (not our cell).
--
-- Taken:
--   * a machine cell in a wall run (role wall) that is the BOTTOM row of its
--     column run with a walkable cell in front on the same ground: pulled out
--     of the wall (user default: machines come out of the wall); the core
--     closes the run left above it with the room's wallpaper;
--   * a furniture group made only of known machine cells, on one ground, not a
--     pillar, each column 1 or 2 rows deep: taken whole.
-- NOT taken: groups shared with other kinds (the Cinnabar fossil machine is
-- one group with a crate; Silph's wall-art groups hold phones and wall trim;
-- the warehouse desk), groups on mixed ground, the Vermilion Gym generator
-- (part of the gym's wall drawing). RESULTS.md lists them.
-- Mod sandbox: no globals, no debug / package / io; `...` is V (nil in tests).
local V = ...
local _ = V

local T = {
  id = "Machine", version = "machine 0.1 (2026-10-02)",
  walkable = false,
  maxWalkH = 0.56,
  walls = true,           -- most machines are drawn in the back wall's bottom row
  heightAt = false,
  supersedes = {},
  budget = 400,           -- per map today: +25 (Sea Cottage) .. +243 (Mansion B1F, 14 cells); RESULTS.md
  sourceMids = nil,
  stretchedAllowed = 0,
  windingExempt = 0,
}

-- ------------------------------------------------------------------ constants
-- height (cells; 1 cell = 1.6 m). User default: real-life heights. A machine
-- cabinet 1.92 m = the core's MB.FURNITURE_H for machines, unchanged.
-- (Zallax's art-row height would be 1.4-1.6 for most of these drawings.)
T.H = 1.20
-- false = leave the wall machines painted on the wall (groups are still taken)
T.PULL_OUT = true
-- false = only machines whose wall run shows no side / back face (see wallOk);
-- true would also pull them out of thin walls (G2 then reports the core's
-- re-textured back faces: the coordinator's call, RESULTS.md)
T.THIN_WALLS = false
-- cells: a drawn back / flank next to something solid that is not a wall
-- stands this far inside its cell border (wave-1 lesson: never flush on a
-- core face)
T.INSET = 1 / 64
-- flanks / back: a strip of the machine's own front rows, SIDE_W wide,
-- starting SIDE_IN inside the piece's west edge (clear of the 1-2 px of wall
-- the drawings leave beside the cabinet), tiled 1:1 along the depth
T.SIDE_W = 4 / 16
T.SIDE_IN = 2 / 16
-- the measured art per metatile (pair -> mid -> { top px, foot px }):
-- top < 0: the art's top outline lies that many px up in the row behind;
-- foot: px of the art's foot below the cell (on the walkable row in front).
-- For a two-row drawing the north cell's top and the south cell's foot count.
-- Measured from the atlas offline (OUT/probe/col_*.png, 2026-10-02).
T.ART = {
  oak_lab = {
    [800] = { -4, 8 }, [801] = { -4, 8 }, [802] = { -3, 8 },   -- Cinnabar lab row of machines
    [795] = { -4, 8 },                                         -- Cinnabar lab terminal (wall)
    [685] = { -4, 8 }, [678] = { 2, 8 },                       -- Oak's Lab consoles (wall)
    [683] = { -7, 0 }, [684] = { -7, 0 }, [691] = { -7, 0 }, [692] = { -7, 0 }, -- Oak's Lab 2 x 2 machine
  },
  building__rom_082d4ecc = {                                   -- Silph Co., Rocket Hideout, warehouse
    [773] = { 2, 8 }, [774] = { 2, 8 }, [775] = { -4, 8 },
    [891] = { 2, 8 }, [892] = { 2, 8 }, [901] = { -4, 8 },
    [701] = { -19, 0 }, [702] = { -19, 0 },                    -- the Rocket machine (two cells)
  },
  building__rom_082d4f2c = {                                   -- Pokemon Mansion
    [797] = { 0, 8 }, [798] = { 0, 8 }, [799] = { -4, 8 },
  },
  building__rom_082d4e9c = {                                   -- Power Plant
    [750] = { 2, 8 }, [751] = { 2, 8 }, [784] = { -6, 8 },
    [752] = { -8, 8 }, [753] = { -8, 8 }, [754] = { -8, 8 },   -- generators, 3 x 2
    [755] = { -8, 8 }, [756] = { -8, 8 }, [757] = { -8, 8 },
    [760] = { -8, 8 }, [761] = { -8, 8 }, [762] = { -8, 8 },
    [763] = { -8, 8 }, [764] = { -8, 8 }, [765] = { -8, 8 },
  },
  building__rom_082d4eb4 = {                                   -- Sea Cottage
    [672] = { -4, 8 },
  },
}
local BEH = { [0x95] = true, [0x9E] = true }
local mabs = math.abs
local function key(x, y) return y * 65536 + x end

local function artOf(idx, c)
  local t = T.ART[idx.pair]
  return t and c.mid and t[c.mid] or nil
end

function T.applies(ctx, idx)
  return T.ART[idx.pair] ~= nil and (idx.byBeh[0x95] ~= nil or idx.byBeh[0x9E] ~= nil)
end

-- a straight wall cell, or off the map (a run's hidden side)
local function hidden(ctx, x, y)
  local q = ctx:at(x, y)
  return q == nil or q.exitFrame or (q.role == "wall" and not q.inWall and not q.pocket)
end
-- a wall machine standing in the bottom row of its wall run, open in front.
-- The core textures a run's side and back faces from the run itself, so
-- taking the bottom row out of a run that shows a side or back face (a thin
-- wall with a room behind it, a run beside an opening) re-textures faces
-- outside our cells: such machines stay painted on the wall unless
-- T.THIN_WALLS (RESULTS.md, Requests).
local function wallOk(ctx, idx, c)
  if not T.PULL_OUT or c.role ~= "wall" or not artOf(idx, c) then return false end
  if c.runB ~= c.y or c.inWall or c.pocket then return false end
  local s = ctx:at(c.x, c.y + 1)
  if not (s ~= nil and s.walkable and not s.exitFrame and mabs((s.hgt or 0) - (c.hgt or 0)) < 1e-9) then return false end
  if not T.THIN_WALLS and c.runA and c.runA < c.y then
    if not hidden(ctx, c.x, c.runA - 1) then return false end
    for y = c.runA, c.y - 1 do
      if not (hidden(ctx, c.x - 1, y) and hidden(ctx, c.x + 1, y)) then return false end
    end
  end
  return true
end

-- a furniture group made only of known machine cells, one ground, columns 1-2 deep
local function groupOk(ctx, idx, g)
  if not (g and g.cells) or g.pillar or g.slot then return false end
  local g0, inG = nil, {}
  for _, q in ipairs(g.cells) do
    if q.walkable or q.role ~= "furniture" or not (q.beh and BEH[q.beh]) or not artOf(idx, q) then return false end
    if g0 == nil then g0 = q.hgt or 0 elseif mabs((q.hgt or 0) - g0) > 1e-9 then return false end
    inG[q] = true
  end
  for _, q in ipairs(g.cells) do
    local n, s = ctx:at(q.x, q.y - 1), ctx:at(q.x, q.y + 1)
    if inG[n or false] and inG[s or false] then return false end      -- 3 rows deep: not a drawing seen here
  end
  return true
end

-- PURE: the wall machines and the all-machine groups, row-major (idx.all order)
function T.match(ctx, idx)
  local want, okG = {}, {}
  for _, b in ipairs({ 0x95, 0x9E }) do
    for _, c in ipairs(idx.byBeh[b] or {}) do
      if c.role == "wall" then
        if wallOk(ctx, idx, c) then want[c] = true end
      elseif c.role == "furniture" and c.group and not c.walkable then
        local g = c.group
        if okG[g] == nil then okG[g] = groupOk(ctx, idx, g) end
        if okG[g] then for _, q in ipairs(g.cells) do want[q] = true end end
      end
    end
  end
  local out = {}
  for _, c in ipairs(idx.all) do if want[c] then out[#out + 1] = c end end
  return out
end

-- ------------------------------------------------------------ pieces
-- granted cells -> pieces { x0, x1, zb, yf, top, ov, g }: per column the
-- drawing's back row zb and foot row yf; a run of columns in a row with the
-- same zb / yf / art top / overhang / ground is one piece. Built from the
-- row-major cell list (no pairs()).
local function pieces(ctx, pair, cells)
  local art = T.ART[pair] or {}
  local set = {}
  for _, p in ipairs(cells) do set[key(p.x, p.y)] = p end
  local function at(x, y) return set[key(x, y)] end
  local cols = {}
  for _, p in ipairs(cells) do
    if not at(p.x, p.y - 1) then
      local yf = p.y
      while at(p.x, yf + 1) do yf = yf + 1 end
      local a, f = art[p.mid], art[at(p.x, yf).mid]
      local s = ctx:at(p.x, yf + 1)
      local ov = (s and s.walkable and f and f[2] > 0) and f[2] / 16 or 0
      cols[#cols + 1] = { x = p.x, zb = p.y, yf = yf, top = a and a[1] or 0, ov = ov, g = p.hgt or 0 }
    end
  end
  -- cols are in row-major order of their head cells: merge east neighbours
  local out, last = {}, nil
  for _, c in ipairs(cols) do
    if last and c.x == last.x1 and c.zb == last.zb and c.yf == last.yf and c.top == last.top
      and c.ov == last.ov and mabs(c.g - last.g) < 1e-9 then
      last.x1 = c.x + 1
    else
      last = { x0 = c.x, x1 = c.x + 1, zb = c.zb, yf = c.yf, top = c.top, ov = c.ov, g = c.g }
      out[#out + 1] = last
    end
  end
  return out
end
T._pieces = pieces -- (tests)

function T.classify(ctx, cells, ts)
  ts.pieces = pieces(ctx, ctx.pair, cells)
  for _, p in ipairs(cells) do ctx:claim(p.x, p.y, nil, T.H) end
end

-- ------------------------------------------------------------ props
local function isWall(ctx, x, y)
  local c = ctx:at(x, y)
  if not c or c.exitFrame then return true end
  if c.role ~= "wall" then return false end
  local dg = ctx.diagOf
  return not (type(dg) == "table" and dg[c])
end
-- a side of the piece: "wall" (every cell a straight wall / off-map: no face),
-- "own" (every cell ours on the same ground, or a straight wall: a neighbouring
-- piece of the same height hides it), "solid" (something solid that is not a
-- wall and none of ours: the drawn face is inset), "open" (drawn on the border)
local function sideKind(ctx, ts, list, g)
  local allWall, allOwnOrWall, solid, own = true, true, false, false
  for _, xy in ipairs(list) do
    local x, y = xy[1], xy[2]
    if not isWall(ctx, x, y) then
      allWall = false
      local c = ctx:at(x, y)
      if ts.cellSet[c] and mabs((c.hgt or 0) - g) < 1e-9 then
        own = true
      else
        allOwnOrWall = false
        if not c.walkable and c.role ~= "wall" then solid = true end
      end
    end
  end
  if allWall then
    -- a side whose cells are all off the map (a drawing at the map edge,
    -- Oak's Lab (0, 1)): drawn so the piece stays closed
    for _, xy in ipairs(list) do if ctx:at(xy[1], xy[2]) then return "wall" end end
    return "open"
  end
  if allOwnOrWall then return "own" end
  if solid and not own then return "solid" end
  return "open"
end
T._sideKind = sideKind -- (tests)

function T.props(ctx, ts)
  local R = ts.lib.Relief
  local under, over = ctx:buffer("opaque"), ctx:buffer("over")
  local H = T.H
  local list = ts.pieces or pieces(ctx, ctx.pair, ts.cells)
  -- pass 1: the sides of every piece, its (inset) back edge, the piece per cell
  local byCell, info = {}, {}
  for i, pc in ipairs(list) do
    local wl, el, bl = {}, {}, {}
    for y = pc.zb, pc.yf do wl[#wl + 1] = { pc.x0 - 1, y }; el[#el + 1] = { pc.x1, y } end
    for x = pc.x0, pc.x1 - 1 do bl[#bl + 1] = { x, pc.zb - 1 } end
    local w, e, b = sideKind(ctx, ts, wl, pc.g), sideKind(ctx, ts, el, pc.g), sideKind(ctx, ts, bl, pc.g)
    info[i] = { w = w, e = e, b = b, zb = pc.zb + ((b == "solid") and T.INSET or 0) }
    for y = pc.zb, pc.yf do for x = pc.x0, pc.x1 - 1 do byCell[key(x, y)] = i end end
  end
  -- a side against our own piece is hidden by it, unless that piece does not
  -- cover this side's rows or its back edge lies further north (an inset back
  -- next to a piece standing flush on the wall: this piece's back face would
  -- end in the open, so its flank is drawn)
  local function ownOpen(i, x, pc)
    for y = pc.zb, pc.yf do
      local j = byCell[key(x, y)]
      if not j or info[j].zb < info[i].zb - 1e-9 or list[j].zb > pc.zb or list[j].yf < pc.yf then return true end
    end
    return false
  end
  for i, pc in ipairs(list) do
    local ov = pc.ov
    local w, e, b = info[i].w, info[i].e, info[i].b
    local fw = (w == "open" or w == "solid") or (w == "own" and ownOpen(i, pc.x0 - 1, pc))
    local fe = (e == "open" or e == "solid") or (e == "own" and ownOpen(i, pc.x1, pc))
    local x0, x1, zb = pc.x0, pc.x1, pc.zb
    if w == "solid" then x0 = x0 + T.INSET end
    if e == "solid" then x1 = x1 - T.INSET end
    if b == "solid" then zb = zb + T.INSET end
    -- picture coordinates: the drawing as the art has it (foot at yf + 1 + ov),
    -- moved north by ov onto its cells (lift -ov: up AND south by -ov; the
    -- ground raised by ov keeps it on the floor). The art's top never lies
    -- further back than the piece's back edge allows (tall drawings over one
    -- row: their highest rows stay painted on the wall behind).
    local z0, z1 = zb + ov, pc.yf + 1 + ov
    -- (and never above the row behind the piece: art is read from our cells
    -- and their ring only)
    local first = pc.zb + pc.top / 16
    if first < z0 - H then first = z0 - H end
    if first < pc.zb - 1 then first = pc.zb - 1 end
    R.piece(ctx, {
      x0 = x0, x1 = x1, z0 = z0, z1 = z1, h = H, g = pc.g + ov, lift = -ov,
      first = first,
      sides = "front", sideW = T.SIDE_W, sideU = pc.x0 + T.SIDE_IN,
      back = (b == "open" or b == "solid"),
      flanks = { w = fw, e = fe },
      under = under, over = over, tag = "machine",
    })
  end
end

return T
