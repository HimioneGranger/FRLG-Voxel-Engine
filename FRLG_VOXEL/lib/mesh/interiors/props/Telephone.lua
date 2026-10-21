-- FRLG_VOXEL / interiors team: props/Telephone.lua -- the telephone
-- (behaviour 0x96, MB_TELEPHONE) (wave 3, 2026-10-02; scout INVENTORY
-- "Telephones").
--
-- Where (offline census of the w3base tree): 39 cells on 18 maps.
--   * 37 WALL phones: one art block (the phone's top 6 rows at the bottom of
--     the wall row above, its body in the top 6 rows of the phone cell; the
--     same pixels in all three tilesets: metatiles 659 (Rocket / Silph
--     tileset and the Celadon Condominiums tileset), 903 and 1014). The phone
--     cell is the bottom row of a 2-row back wall. The core made it a 0.45
--     furniture box (alone, or with the wall cell above it), so today the wall
--     has a notch with the phone lying face up on a low box; 6 more stand in
--     larger boxes the core built from a whole wall segment (Silph 5F / 6F /
--     9F, Five Island warehouse, Silph 11F) -- the probe's "wall phone in a
--     16-cell 0.80 floor box" at Silph 5F (26,8).
--   * 2 DESK phones (Celadon Department Store 1F (11,5), (12,5), metatile
--     759): a phone on a low white cabinet; the cabinet's doors run on into
--     the walkable floor cell in front, which no type may build in.
--
-- How it is drawn (user defaults, scout PLAN Q1 / Q3; one constant each):
--   * wall phone: the phone's column (the phone cell and the wall cell above
--     it when the core put that cell in the same box) is claimed and closed
--     again as WALL, full wall height, its front the cells' own art 1:1 (the
--     game's picture of that wall, phone included), its back and open sides
--     the room's wallpaper like the core's own wall ends. The phone comes out
--     of the wall: where both wall neighbours close the sides, the wall
--     panel stands RECESS behind the wall line and the phone body (its own
--     art, lid = its top rows) stands in front of it, its face on the wall
--     line. It never reaches into the walkable cell in front. The cells
--     beside a phone that the core put in the same box are not this type's
--     (they keep their box; RESULTS.md, Requests).
--   * desk phone: a low cabinet (CAB_H, real-life height on the art's own
--     front edge) with the phone standing on it as a lifted piece (Relief
--     `lift`: up AND south, picture unchanged), its top the art's handset
--     rows; the part of the art in front of the phone body stays on the
--     cabinet's lid.
--
--   * counter phone (0.2, review-w3 finding 2): a wall phone whose box the
--     core built from a whole low wall segment (a desk or counter: Silph 5F
--     (26,8), 6F, 9F, 11F, 5F (23,19), the warehouse (7,8)) is a desk phone on
--     its host: the phone's column is the host's own height (its art 1:1),
--     and the phone stands on it as a lifted piece, picture unchanged. No
--     full-height column stands in a counter.
--
-- 0.2 (review-w3 finding 1): a side counts as closed when every row beside it
-- is a straight wall OR a cell another type claimed (a machine the Machine
-- type pulled out of the wall); against such a cell this type closes the side
-- itself (a 1 px jamb on the wall line, wallpaper on its faces), so those
-- phones keep their 3D body in the merged package (warehouse (24,1), Rocket
-- B1F (7,21)).
--
-- Method after pokeemerald-3Ds-dualscreen (ZallaxDev, MIT) through
-- props/Relief.lua (the MIT text is in Relief.lua's header); no code of his is
-- copied here. Every texel is our own ROM-extracted art read through the atlas.
-- Mod sandbox: no globals; the debug, package and io libraries are never used;
-- `...` is V in the game, nil in tests.
local V = ...
local _ = V

local T = {
  id = "Telephone", version = "telephone 0.2 (2026-10-02)",
  walkable = false,
  maxWalkH = 0.56,
  walls = false,      -- the phone cells and the wall cells above them in the same box are furniture today
  heightAt = false,
  supersedes = {},
  budget = 400,       -- a wall phone adds about 40-60 triangles, the warehouse has 5 phones
  sourceMids = nil,
  stretchedAllowed = 0,
  windingExempt = 0,
}

local PX = 16

-- user defaults (scout PLAN Q1 / Q3), one constant each:
-- wall phones: the wall panel behind the phone stands this far behind the
-- wall line, and the phone's body is that deep (2 px = 20 cm, 1 cell = 1.6 m)
T.RECESS = 2 / 16
-- desk phones: the cabinet's height on the art's own front edge (6 rows =
-- 0.6 m), the phone's front (7 rows) and its depth on the lid (6 rows)
T.CAB_H = 6 / 16
T.DESK_PH_H = 7 / 16
T.DESK_PH_D = 6 / 16
-- wave-1 lesson: a side that would sit flush on a core face steps this far in
T.INSET = 1 / 64
-- the wall-phone column stands WH - TOP_GAP tall (and claims that height,
-- ctx:topAt): just under the room's ceiling (g + 1.98), never at g + 2.0 --
-- a non-wall cell reaching the ceiling is what the core's suites flag (CT,
-- P1), and the Ceiling module keeps a lamp lattice slot on the cell where it
-- was (Ceiling 1.1, coordinator decision (b): lamps keep their places)
T.TOP_GAP = 1 / 32
-- the phone body's back stands this far in front of the panel (no coplanar
-- pair with the panel's face; 0.8 cm)
T.BACK_GAP = 1 / 128
-- (0.2) the jamb that closes the recess beside another type's cell (1 px)
T.JAMB_W = 1 / 16
-- counter phones: the phone's depth on the host's lid (the wall phone's
-- depth), and how far its front stands behind the host's front (never
-- coplanar with it)
T.CTR_PH_D = 2 / 16
T.CTR_IN = 1 / 64
-- its flanks / back (seen from behind the counter): a 3 px strip of its own
-- front columns, tiled 1:1 (fewer courses than the wall phone's 1 px strip)
T.CTR_SIDE_W = 3 / 16
-- it stands this far above the host's lid (its closed underside never
-- coplanar with the lid: the core suites' z-fight test groups planes to
-- 1/500 cell; the wall phone keeps the same gap behind its body)
T.CTR_GAP = 1 / 128
-- a counter phone whose standing body would be shorter than this stays a
-- wall-phone column (a guard: every host seen is 0.75-0.80)
T.CTR_MIN_H = 2 / 16

local BEH_PHONE = 0x96
local OWN = "type:" .. T.id

-- the wall phone's pixels, the same in every tileset (offline pixel dump,
-- RESULTS.md): columns 2..13 (outline to outline), rows -6..5 of the phone
-- cell (the top 6 rows are the wall row above)
T.WALL_ART = { c0 = 2, c1 = 14, r0 = -6, r1 = 6 }
-- the phone metatiles, per tileset pair
T.WALL_MIDS = {
  ["building__rom_082d4ecc"] = { [659] = true, [903] = true, [1014] = true },
  ["building__rom_082d4f8c"] = { [659] = true },
}
T.DESK_MIDS = {
  ["building__rom_082d4e6c"] = { [759] = true },
}

-- a counter phone on a host H tall: the height of its standing front and its
-- picture foot (relative to the phone cell's top edge, cells). The phone's
-- front stands CTR_IN behind the host's front; lifted by H + CTR_GAP (up AND
-- south), so its picture foot is that line minus the lift; its lid is
-- CTR_PH_D deep; its art starts at the phone's top outline (WALL_ART.r0).
function T._counterH(H)
  local foot = 1 - T.CTR_IN - (H + T.CTR_GAP)
  return foot - T.CTR_PH_D - T.WALL_ART.r0 / 16, foot
end

local function sameGround(a, b) return math.abs((a.hgt or 0) - (b.hgt or 0)) <= 1e-9 end

local function isPhone(c)
  return c and c.beh == BEH_PHONE and c.role == "furniture" and not c.walkable and c.group ~= nil
end

-- every cell of the group stands on the ground of c (wave-1 lesson: skip
-- groups on mixed ground)
local function flatGroup(c)
  for _, q in ipairs(c.group.cells) do if not sameGround(q, c) then return false end end
  return true
end

-- the units of the room (pure), in index order:
--   { kind = "wall", phone = cell, cells = { [north,] phone } }
--   { kind = "desk", phone = cell, cells = { phone } }
local function units(ctx, list, pair)
  local out = {}
  local wm, dm = T.WALL_MIDS[pair or ""], T.DESK_MIDS[pair or ""]
  for _, c in ipairs(list) do
    if isPhone(c) and flatGroup(c) then
      if wm and wm[c.mid] then
        local cells = { c }
        local n = ctx:at(c.x, c.y - 1)
        if n and n.group == c.group and n.role == "furniture" and (n.beh or 0) == 0 and not n.walkable then
          cells = { n, c }
        end
        -- the box holds more than the phone's column: a desk / counter the
        -- core built from a low wall segment -> a desk phone on that host
        local host = nil
        local grp = c.group
        if #grp.cells > #cells and not grp.pillar and type(grp.h) == "number" and grp.h > 0
            and T._counterH(grp.h) >= T.CTR_MIN_H then
          host = grp.h
        end
        out[#out + 1] = { kind = host and "counter" or "wall", phone = c, cells = cells, host = host }
      elseif dm and dm[c.mid] then
        -- a desk phone only in a group of desk phones (the cabinet is part of
        -- the phone's own art)
        local ok = true
        for _, q in ipairs(c.group.cells) do if not (q.beh == BEH_PHONE and dm[q.mid]) then ok = false end end
        if ok then out[#out + 1] = { kind = "desk", phone = c, cells = { c } } end
      end
    end
  end
  return out
end
T._units = units -- (tests)

function T.applies(ctx, idx) return idx.byBeh[BEH_PHONE] ~= nil end

-- PURE: the phone cells (and the wall cells above wall phones in the same box)
function T.match(ctx, idx)
  local want = {}
  local all = units(ctx, idx.byBeh[BEH_PHONE] or {}, idx.pair or ctx.pair)
  -- row-major (the index order): north cells first
  local rows = {}
  for _, u in ipairs(all) do for _, c in ipairs(u.cells) do rows[#rows + 1] = c end end
  table.sort(rows, function(a, b) if a.y ~= b.y then return a.y < b.y end return a.x < b.x end)
  for _, c in ipairs(rows) do want[#want + 1] = c end
  return want
end

function T.classify(ctx, cells, ts)
  local set = ts.cellSet or {}
  if not ts.cellSet then for _, p in ipairs(cells) do set[p] = true end end
  local list = {}
  for _, u in ipairs(units(ctx, cells, ctx.pair)) do
    local whole = true
    for _, c in ipairs(u.cells) do if not set[c] then whole = false end end
    if whole then list[#list + 1] = u end
  end
  local WH = ctx.WH or 2.0
  for _, u in ipairs(list) do
    for _, c in ipairs(u.cells) do
      if u.kind == "wall" then ctx:claim(c.x, c.y, nil, WH - T.TOP_GAP)
      elseif u.kind == "counter" then ctx:claim(c.x, c.y, nil, u.host + T.CTR_GAP + T._counterH(u.host))
      else ctx:claim(c.x, c.y, nil, T.CAB_H + T.DESK_PH_H) end
    end
  end
  ts.units = list
end

-- a straight wall run beside the cell (a wall cell with a slanted face -- the
-- mesher's diagOf -- does not close the side: its face cuts the corner)
local function wallRun(ctx, x, y)
  local c = ctx:at(x, y)
  if c == nil or c.role ~= "wall" then return false end
  local d = ctx.diagOf
  if type(d) == "table" and d[c] then return false end
  return true
end
-- a neighbour a side would sit flush on: a solid core face (a furniture box ...)
local function flushSolid(ctx, x, y)
  local c = ctx:at(x, y)
  return c ~= nil and not c.exitFrame and not c.walkable and c.role ~= "wall" and c.role ~= nil
    and c.role ~= "flat"
end
-- a cell another type claimed and draws as a solid (a machine the Machine
-- type pulled out of the wall); not walkable, not ours
local function foreignSolid(ctx, x, y)
  local c = ctx:at(x, y)
  return c ~= nil and c.role == "ext" and not c.walkable and not c.exitFrame
    and type(c.claimOwner) == "string" and c.claimOwner:sub(1, 5) == "type:" and c.claimOwner ~= OWN
end
-- a side of the phone column (column x, rows ya..yb): "wall" (a straight wall
-- run on every row: the core's faces close it), "foreign" (every row a
-- straight wall or another type's solid, at least one of those: closed, but
-- this type draws the side faces), "open"
local function sideState(ctx, x, ya, yb)
  local st = "wall"
  for yy = ya, yb do
    if not wallRun(ctx, x, yy) then
      if foreignSolid(ctx, x, yy) then st = "foreign" else return "open" end
    end
  end
  return st
end
T._sideState = sideState -- (tests)

-- the room's wallpaper on a vertical plane, like the core's own wall ends
-- (Ctx:returnFace, world-anchored): a = the left end seen from the room side.
-- The stored normal is the face's own (gate G8; Relief's faces do the same),
-- not the core's wall-shade normal.
local function paperFace(ctx, list, ax, az, bx, bz, g, h, nx, nz)
  local s0
  if nz < -0.5 then s0 = -ax elseif nz > 0.5 then s0 = ax elseif nx > 0.5 then s0 = -az else s0 = az end
  ctx:paper(list, ax, az, bx, bz, g, g, g + h, s0, nx, 0, nz)
end

-- a phone body's underside (x px0..px1, z za..zEnd at height yb): the phone's
-- bottom outline row, one course per pixel (1:1)
local function underside(ctx, under, mid, px0, px1, yb, za, zEnd)
  local A = T.WALL_ART
  local env = ctx.env
  local r = env.underRect and env.underRect(mid)
  if not r then return end
  local u0 = r[1] + (A.c0 / PX) * (r[3] - r[1])
  local u1 = r[1] + (A.c1 / PX) * (r[3] - r[1])
  local row = A.r1 - 1
  local v0 = r[2] + (row / PX) * (r[4] - r[2])
  local v1 = r[2] + ((row + 1) / PX) * (r[4] - r[2])
  while za < zEnd - 1e-9 do
    local zc = math.min(zEnd, za + 1 / PX)
    local vc = v0 + (v1 - v0) * ((zc - za) * PX)
    -- counter-clockwise seen from below (normal DOWN)
    ctx:quadV(under, px0, yb, za, u0, v0, px1, yb, za, u1, v0, px1, yb, zc, u1, vc, px0, yb, zc, u0, vc, 0, -1, 0)
    za = zc
  end
end

-- the wall phone: the wall column + the phone body
local function wallPhone(ctx, ts, u, under, over)
  local R = ts.lib.Relief
  local p = u.phone
  local x, y, g = p.x, p.y, p.hgt or 0
  local zb = u.cells[1].y
  local CH = (ctx.WH or 2.0) - T.TOP_GAP -- the column height
  -- the sides: closed by a wall run on every row (the core's faces close the
  -- recess), else this type draws them in wallpaper
  -- (a side or back this type closes itself steps T.INSET into the column:
  -- never flush on a core face, never on the walkable cell beside it)
  local sW, sE = sideState(ctx, x - 1, zb, y), sideState(ctx, x + 1, zb, y)
  local wW, wE = sW == "wall", sE == "wall"
  local north = ctx:at(x, zb - 1)
  local wN = north == nil or north.exitFrame or wallRun(ctx, x, zb - 1)
  local rec = (sW ~= "open" and sE ~= "open") and T.RECESS or 0
  local x0 = x + (wW and 0 or T.INSET)
  local x1 = x + 1 - (wE and 0 or T.INSET)
  local z0 = zb + (wN and 0 or T.INSET)
  local zf = y + 1 - rec
  -- the column: front = the two wall rows' art 1:1, on the same heights as
  -- the wallpaper beside it: set back `rec` with a negative lift (down AND
  -- north by rec, the ground raised by rec: the panel stands on g)
  local first = y + 1 - CH
  -- (0.2) a side closed by another type's cell (a pulled-out machine) while
  -- the panel is set back: no core wall face closes the recess there, so a
  -- JAMB_W jamb on the wall line does (the column's own art 1:1 in front,
  -- wallpaper on its outer face and on its face into the recess)
  local jW = (rec > 0 and sW == "foreign") and T.JAMB_W or 0
  local jE = (rec > 0 and sE == "foreign") and T.JAMB_W or 0
  R.piece(ctx, { x0 = x0 + jW, x1 = x1 - jE, z0 = z0 + rec, z1 = y + 1, h = CH, g = g + rec, lift = -rec, first = first,
    lid = { first, first + 1 }, back = false, flanks = { w = false, e = false },
    under = under, over = over, tag = "wall" })
  local function jamb(ja, jb)
    R.piece(ctx, { x0 = ja, x1 = jb, z0 = z0, z1 = y + 1, h = CH, g = g, first = first,
      lid = { first, first + 1 }, back = false, flanks = { w = false, e = false },
      under = under, over = over, tag = "jamb" })
  end
  if jW > 0 then
    jamb(x0, x0 + jW)
    paperFace(ctx, under, x0, z0, x0, y + 1, g, CH, -1, 0)
    paperFace(ctx, under, x0 + jW, y + 1, x0 + jW, zf, g, CH, 1, 0)
  end
  if jE > 0 then
    jamb(x1 - jE, x1)
    paperFace(ctx, under, x1, y + 1, x1, z0, g, CH, 1, 0)
    paperFace(ctx, under, x1 - jE, zf, x1 - jE, y + 1, g, CH, -1, 0)
  end
  -- back and open sides: the room's wallpaper (as the core closes its runs)
  if not wN then paperFace(ctx, under, x1, z0, x0, z0, g, CH, 0, -1) end
  if not wW and jW == 0 then paperFace(ctx, under, x0, z0, x0, zf, g, CH, -1, 0) end
  if not wE and jE == 0 then paperFace(ctx, under, x1, zf, x1, z0, g, CH, 1, 0) end
  if rec <= 0 then return end
  -- the phone body: a lifted relief piece whose face is on the wall line and
  -- whose back is on the panel; its lid = the phone's top rows
  local A = T.WALL_ART
  local zs = zf + T.BACK_GAP
  local D = rec - T.BACK_GAP
  local z1p = y + A.r1 / PX
  local z0p = z1p - D
  local lift = zs - z0p
  local px0, px1 = x + A.c0 / PX, x + A.c1 / PX
  R.piece(ctx, { x0 = px0, x1 = px1, z0 = z0p, z1 = z1p, h = (A.r1 - A.r0) / PX - D, g = g,
    first = y + A.r0 / PX, lift = lift, back = true, flanks = { w = true, e = true }, sideW = 1 / PX,
    under = under, over = over, tag = "phone" })
  -- its underside
  underside(ctx, under, p.mid, px0, px1, g + lift, zs, y + 1)
end

-- the desk phone: cabinet (two pieces, split under the phone's front so every
-- edge of the phone meets an edge) and the phone on it
local function deskPhone(ctx, ts, u, under, over, mine)
  local R = ts.lib.Relief
  local p = u.phone
  local x, y, g = p.x, p.y, p.hgt or 0
  local function side(dx)
    local n = ctx:at(x + dx, y)
    if n and mine[n] then return false end
    return not wallRun(ctx, x + dx, y)
  end
  local fl = { w = side(-1), e = side(1) }
  local iw = (fl.w and flushSolid(ctx, x - 1, y)) and T.INSET or 0
  local ie = (fl.e and flushSolid(ctx, x + 1, y)) and T.INSET or 0
  local x0, x1 = x + iw, x + 1 - ie
  local H, PD, PH = T.CAB_H, T.DESK_PH_D, T.DESK_PH_H
  R.piece(ctx, { x0 = x0, x1 = x1, z0 = y, z1 = y + PD, h = H, g = g, first = y, flanks = fl,
    under = under, over = over, tag = "cabinet~back" })
  R.piece(ctx, { x0 = x0, x1 = x1, z0 = y + PD, z1 = y + 1, h = H, g = g, first = y, back = false, flanks = fl,
    under = under, over = over, tag = "cabinet" })
  -- the phone: stands on the lid from the wall to y + PD; front PH, lid PD
  local z0p, z1p = y - H, y + PD - H
  R.piece(ctx, { x0 = x0, x1 = x1, z0 = z0p, z1 = z1p, h = PH, g = g, first = z1p - PH - PD, lift = H,
    back = false, flanks = fl, under = under, over = over, tag = "deskphone" })
end

-- the counter phone (0.2): the phone's column at its host's height (the
-- column's art 1:1), the phone standing on it as a lifted piece
local function counterPhone(ctx, ts, u, under, over)
  local R = ts.lib.Relief
  local p = u.phone
  local x, y, g = p.x, p.y, p.hgt or 0
  local zb = u.cells[1].y
  local H = u.host
  -- a side is hidden by the host's own box (same height, same ground) or a
  -- straight wall on every row; else drawn, stepped in when flush on a solid
  local function side(dx)
    local hidden, solid = true, false
    for yy = zb, y do
      local n = ctx:at(x + dx, yy)
      local box = n ~= nil and n.role == "furniture" and n.group ~= nil and not n.group.pillar
        and not n.walkable and sameGround(n, p) and math.abs((n.group.h or 0) - H) <= 1e-9
      if not (box or wallRun(ctx, x + dx, yy)) then
        hidden = false
        if flushSolid(ctx, x + dx, yy) or foreignSolid(ctx, x + dx, yy) then solid = true end
      end
    end
    return not hidden, solid
  end
  local fw, iw = side(-1)
  local fe, ie = side(1)
  local north = ctx:at(x, zb - 1)
  local bN = not (north == nil or north.exitFrame or wallRun(ctx, x, zb - 1))
  local inN = bN and (flushSolid(ctx, x, zb - 1) or foreignSolid(ctx, x, zb - 1))
  local x0, x1 = x + (iw and T.INSET or 0), x + 1 - (ie and T.INSET or 0)
  local z0 = zb + (inN and T.INSET or 0)
  R.piece(ctx, { x0 = x0, x1 = x1, z0 = z0, z1 = y + 1, h = H, g = g, first = zb, back = bN,
    flanks = { w = fw, e = fe }, under = under, over = over, tag = "counter" })
  -- the phone: its front CTR_IN behind the host's front, CTR_PH_D deep
  local A = T.WALL_ART
  local ph, foot = T._counterH(H)
  local z1p = y + foot
  local lift = H + T.CTR_GAP
  local px0, px1 = x + A.c0 / PX, x + A.c1 / PX
  R.piece(ctx, { x0 = px0, x1 = px1, z0 = z1p - T.CTR_PH_D, z1 = z1p, h = ph, g = g,
    first = y + A.r0 / PX, lift = lift, back = true, flanks = { w = true, e = true }, sideW = T.CTR_SIDE_W,
    under = under, over = over, tag = "phone" })
  -- its underside, CTR_GAP over the host's lid (closes the body's bottom edges)
  underside(ctx, under, p.mid, px0, px1, g + lift, z1p + lift - T.CTR_PH_D, z1p + lift)
end

function T.props(ctx, ts)
  local under, over = ctx:buffer("opaque"), ctx:buffer("over")
  local mine = {}
  for _, u in ipairs(ts.units or {}) do for _, c in ipairs(u.cells) do mine[c] = true end end
  for _, u in ipairs(ts.units or {}) do
    if u.kind == "wall" then wallPhone(ctx, ts, u, under, over)
    elseif u.kind == "counter" then counterPhone(ctx, ts, u, under, over)
    else deskPhone(ctx, ts, u, under, over, mine) end
  end
end

return T
