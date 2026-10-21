-- FRLG_VOXEL / interiors-team CEILING: Ceiling.lua
--
-- The ceilings of the indoor maps, built by the interiors core in finish()
-- step 5 (Ceiling.build(ctx), inside ctx:runModule: an error here drops only
-- this module's groups; the room keeps its walls). API: build/core/API.md
-- (frozen v1.0) sections 3, 4, 5b, 9. Never called on open-air maps.
--
--   * cells: every floor-level cell (ctx:ceilingCells(): not void, not a
--     wall run, not an exit frame), trimmed by the synthetic-wall inset on
--     open sides; plus the floor part of the mesher's slanted north walls
--     (ctx.diagOf) and the floor fills of the slanted 4th wall (ctx.fills)
--   * height: "at wall height". FLAT (default): one height per room = the
--     room's modal ground + 2.0 -- phantom +0.25 steps and the Cerulean pool
--     (0.25) keep the deck's ceiling (DESIGN 1.5 "pool cells use the deck
--     height"); a cell more than INTERIORS_CEIL_FLAT_TOL off gets its own
--     g + 2.0. INTERIORS_CEIL_FLAT = false: every cell its own g + 2.0.
--   * never coplanar (VERIFY_arch 7, "tops at g+2.0"): every horizontal face
--     already lying at a ceiling height (2.0 furniture / gate / pillar tops,
--     the synthetic slabs' caps where they run SYNTH_WALL_INSET into a
--     concave corner, door heads) is cut out of the ceiling -- its own top
--     closes the hole. A top above the ceiling simply passes through it.
--   * risers: wherever a neighbour's closure (its ceiling, its wall top, the
--     cell's own synthetic wall top) is lower than this cell's ceiling, a
--     vertical face closes the step (ceiling colour toward a lower ceiling,
--     the room's wallpaper over a wall top).
--   * stairwells: no ceiling over walkable stair / escalator / ladder warps
--     and the stair-art cells beside them (B1: the tunnels' unwalkable 0x6E
--     wall tiles are wall runs now, no shafts there); a 1.0-tall shaft in the
--     room's wallpaper with a dark cap instead.
--   * colour from the room's own art: the rim colour, else the main
--     wallpaper colour when the rim is darker than luma 150 (DESIGN 1.5),
--     else the lightest wallpaper colour; one solid texel (mip-safe block).
--   * shading (user decision 3, both built for the captures): "lit" / "grey"
--     = normal down (ambient only, 0.58 x colour); "unlit" / "colour" = zero
--     normal (the shader's unlit path, full texel colour); "wall" = the
--     walls' C5 shading normal (0.73, the same brightness as the walls).
--   * lamps: one light panel per 4 x 4 cells (VERIFY_arch 5a), 8 x 8 texels,
--     unlit, the lightest room colour, 0.02 below the ceiling.
--   * outside the shadow casters: everything goes into roomShell groups
--     (kinds ceiling / riser / shaft / lamp), never into a base list.
--   * publishes ctx.ceilY[y * W + x + 1] = the ceiling height over every
--     covered cell (the renderer's eye-cell rule, VERIFY_arch 3c).
--   * (repair1, skeptic-visual FAIL 2: 1-pixel cracks) WATERTIGHT: the
--     ceiling hangs INTERIORS_CEIL_DROP (0.02) below its nominal height g +
--     2.0, so every wall, door head, box side and riser that reaches the
--     nominal height passes through it -- a crease between the ceiling and a
--     wall top is covered on the wall's side and can never open onto the
--     background (it used to abut the walls' caps exactly, 9,264 coplanar
--     T-junctions); risers and shaft walls reach 2 x DROP below a lowered
--     neighbour ceiling, a shaft's dark cap sits DROP below the shaft walls'
--     tops; and the ceiling pieces of one height (rects, the slanted walls'
--     floor fronts, the 4th wall's fills) share every vertex on a common
--     edge (T-junction vertices inserted, strip / ear-clip triangulated), so no
--     crack opens between them either (1,371 were left). ceilY and the
--     groups' y0 are the drawn heights.
-- Section hint (API 7): sec.ceiling(ctx, x, y) -> { skip =, shaft =,
-- colour = 0xRRGGBB | uv rect, lamp = } per cell.
-- No debug / package / io (mod sandbox); `...` is unused.
local V = ...
local _ = V

local Ceiling = { VERSION = "ceiling 1.1 (2026-10-02)" }
-- 1.1 (interiors team w0r2, coordinator decision (b)): the lamps keep their
-- pre-type places. The core calls Ceiling.snapshot(ctx) just before the
-- per-type furniture step (PropTypes classify) and it records the wall
-- cells. A cell a furniture type pulled out of a wall (a wall before the
-- types, floor-level now, typeOwner set) is not a lamp input: it never takes
-- a lamp, never moves the lattice bounds, and a lattice slot on it falls back
-- to a neighbour as the wall did. Without such a cell nothing changes (G0).
-- (w0r5) except the cells PropFix's own plan unwalls (Ceiling.propfixMade).
local PRE = setmetatable({}, { __mode = "k" }) -- ctx -> { [y * W + x + 1] = true } (walls before the types)
function Ceiling.snapshot(ctx)
  local W, H, grid = ctx.W, ctx.H, ctx.grid
  if not (W and H and grid) then return end
  local walls = {}
  for y = 0, H - 1 do
    local row = grid[y]
    if row then
      for x = 0, W - 1 do
        local c = row[x]
        if c and c.role == "wall" then walls[y * W + x + 1] = true end
      end
    end
  end
  PRE[ctx] = walls
end
-- (interiors team w0r5; VERSION kept: it is published in ctx.ceiling) a cell
-- a furniture type took that PropFix's own plan unwalls (a Pokemon Tower
-- grave, a Sea Cottage basket ...) is, for the lamps, what PropFix makes of
-- it in a tree without that type: an ordinary cell, not a wall before the
-- types. PropTypes 1.4 calls this after the type's step succeeded.
Ceiling.REVISION = "ceiling 1.1 + w0r5 propfixMade (2026-10-02)"
function Ceiling.propfixMade(ctx, cells)
  local pre, W = PRE[ctx], ctx.W
  if not (pre and W) then return end
  for _, c in ipairs(cells) do pre[c.y * W + c.x + 1] = nil end
end

-- options: ctx.C[name] (deps.Constants) overrides these defaults
local DEF = {
  INTERIORS_CEIL_SHADE = "lit",      -- "lit" | "grey" (normal down: 0.58) or "unlit" | "colour" (zero normal: 1.0); "wall" (the walls' C5 shade: 0.73)
  INTERIORS_CEIL_FLAT = true,        -- one height per room (modal ground + 2.0)
  INTERIORS_CEIL_FLAT_TOL = 0.5,     -- cells further off the modal ground get their own g + 2.0
  INTERIORS_CEIL_COLOUR = "design",  -- "design" (rim >= luma 150, else main, else light) | "rim" | "main" | "light"
  INTERIORS_CEIL_OPENINGS = "all",   -- stairwell openings: "all" (DESIGN 1.5: up and down) | "up" | "none"
  INTERIORS_CEIL_SHAFT_H = 1.0,      -- stairwell shaft height above the ceiling
  INTERIORS_CEIL_LAMPS = true,
  INTERIORS_CEIL_LAMP_BLOCK = 4,     -- one lamp per BLOCK x BLOCK cells
  INTERIORS_CEIL_LAMP_SIZE = 0.5,    -- 8 x 8 texels
  INTERIORS_CEIL_LAMP_DROP = 0.02,   -- below the ceiling (never coplanar)
  INTERIORS_CEIL_LUMA_MIN = 150,     -- DESIGN 1.5: the rim / main colour must be at least this light
  INTERIORS_CEIL_DROP = 0.02,        -- repair1: the ceiling this far below g + 2.0 (walls pass through it: no crease cracks)
  INTERIORS_CEIL_STITCH = true,      -- repair1: share T-junction vertices between ceiling pieces of one height
  INTERIORS_CEIL_BLOCKER_SCAN = false, -- repair2: with a DROP the blocker scan only kept lamps off cells; a lamp cell's own top (ctx:topAt) does that (the scan was 30 % of the module's JIT-off time)
}
Ceiling.DEF = DEF

local mfloor, mabs, mmax, mmin = math.floor, math.abs, math.max, math.min
local function now() if os and os.clock then return os.clock() end return 0 end

local function opt(ctx, name)
  local C = ctx.C
  local v = C and C[name]
  if v == nil then v = DEF[name] end
  return v
end
Ceiling.opt = opt

-- stair / escalator warps by direction (FRLG metatile behaviours); ladders
-- (0x61) have no direction: openings only in the "all" mode
local UP_WARP = { [0x6A] = true, [0x6C] = true, [0x6D] = true }
local STAIRS = { [0x61] = true, [0x6A] = true, [0x6B] = true, [0x6C] = true, [0x6D] = true, [0x6E] = true, [0x6F] = true }
Ceiling.UP_WARP, Ceiling.STAIRS = UP_WARP, STAIRS

-- Recognized lateral house flights already end below the room ceiling and
-- transition through native warps. Their old projected-art warp is beside
-- the flight, not a physical upward shaft. Retain legacy openings everywhere
-- else, and retain explicit section shaft/skip hints below.
function Ceiling.nativeHouseClosure(ctx)
  local closed = {}
  local IN = ctx.env and ctx.env.IN
  if ctx.pair ~= 'player_house' or not IN then return closed end
  local signatures = {
    house_up={anchor=29,beh=0x6C,ox=1,oy=-1,h=3,down=false,mids={{22,23},{30,31},{38,39}}},
    house_down={anchor=7,beh=0x6F,ox=-2,oy=0,h=2,down=true,mids={{5,6},{13,14}}},
  }
  for _,a in ipairs(IN.stairs or {}) do
    local p=a.profile or {};local s=signatures[p.name]
    if s and p.pair=='player_house' and p.w==2 and p.h==s.h and p.ox==s.ox and p.oy==s.oy
        and p.anchor==s.anchor and p.beh==s.beh and p.kind=='stairs' and p.high=='east'
        and p.rise==1.35 and p.down==s.down then
      local ax,ay=a.x-s.ox,a.y-s.oy
      local anchor=ctx.grid[ay] and ctx.grid[ay][ax]
      local ok=anchor==a.anchor and anchor and anchor.mid==s.anchor and anchor.beh==s.beh
      local cells={}
      for dy=0,s.h-1 do for dx=0,1 do
        local c=ctx.grid[a.y+dy] and ctx.grid[a.y+dy][a.x+dx]
        if not c or c.mid~=s.mids[dy+1][dx+1] or c.role~='nativeStair' or c.stairAssembly~=a then ok=false end
        cells[#cells+1]=c
      end end
      if ok then
        closed[ay*ctx.W+ax+1]=true
        for _,c in ipairs(cells)do closed[c.y*ctx.W+c.x+1]=true end
      end
    end
  end
  return closed
end


local function luma(c)
  if type(c) ~= "number" or c < 0 then return -1 end
  local r, g, b = mfloor(c / 65536) % 256, mfloor(c / 256) % 256, c % 256
  return 0.299 * r + 0.587 * g + 0.114 * b
end
Ceiling.luma = luma

-- ---------------------------------------------------------------- colours
-- the rim colour: the mesher's IN.rimUv point mapped back to its texel
-- (the tile whose under rect holds it: the rim cache first, else wall mids)
local function rimColour(ctx)
  local IN = ctx.env.IN
  local r = IN and IN.rimUv
  if type(r) ~= "table" or r.over then return nil, nil end
  local underRect = ctx.env.underRect
  local u, v = r[1], r[2]
  local function probe(mid)
    local rr = underRect(mid)
    if rr and u >= rr[1] - 1e-9 and u <= rr[3] + 1e-9 and v >= rr[2] - 1e-9 and v <= rr[4] + 1e-9 then
      local t = ctx:tex(mid)
      if t then
        local col = mmin(15, mmax(0, mfloor((u - rr[1]) / (rr[3] - rr[1]) * 16)))
        local row = mmin(15, mmax(0, mfloor((v - rr[2]) / (rr[4] - rr[2]) * 16)))
        return t[row * 16 + col + 1] or false
      end
      return false
    end
    return nil
  end
  if type(IN.rimCache) == "table" then
    for mid, e in pairs(IN.rimCache) do
      if type(mid) == "number" and type(e) == "table" then
        local c = probe(mid)
        if c ~= nil then return r, c or nil end
      end
    end
  end
  local seen, grid = {}, ctx.grid
  for y = 0, ctx.H - 1 do
    local row = grid[y]
    for x = 0, ctx.W - 1 do
      local q = row[x]
      if q and q.role == "wall" and q.mid and not seen[q.mid] then
        seen[q.mid] = true
        local c = probe(q.mid)
        if c ~= nil then return r, c or nil end
      end
    end
  end
  return r, nil
end

-- the ceiling colour { uv (single texel), rgb, from } per the option
local function pickColour(ctx, pal, rimUv, rimC)
  local mode = opt(ctx, "INTERIORS_CEIL_COLOUR")
  local minL = opt(ctx, "INTERIORS_CEIL_LUMA_MIN")
  if rimUv == nil then rimUv, rimC = rimColour(ctx) end
  local rim = rimUv and { uv = rimUv, rgb = rimC, from = "rim" } or nil
  local main = pal.main and pal.main.rgb and { uv = pal.main, rgb = pal.main.rgb, from = "main" } or nil
  local light = pal.light and pal.light.rgb and { uv = pal.light, rgb = pal.light.rgb, from = "light" } or nil
  if mode == "rim" then return rim or main or light end
  if mode == "main" then return main or rim or light end
  if mode == "light" then return light or rim or main end
  if rim and luma(rim.rgb) >= minL then return rim end
  if main and luma(main.rgb) >= minL then return main end
  return light or rim or main
end
Ceiling.pickColour = pickColour

-- the room's look: ceiling colour, lamp colour. A light rim (170 of the
-- 249 rooms with a ceiling) needs no palette: the lamp is the same
-- colour drawn unlit (1.0 against the lit ceiling's 0.58). Otherwise the
-- Kit palette (shared with the Doors module in one build), and the pick is
-- kept per atlas + wallpaper signature (weak-keyed: it goes with the atlas)
-- -- a rebuild (tile swap, re-entry) and every room with the same wallpaper
-- skip the texel scans.
local lookCache = setmetatable({}, { __mode = "k" })
function Ceiling.clearCaches() lookCache = setmetatable({}, { __mode = "k" }) end
local function lookOf(ctx, Kit)
  local mode = opt(ctx, "INTERIORS_CEIL_COLOUR")
  local rimUv, rimC = rimColour(ctx)
  if rimUv and rimC and (mode == "rim" or (mode == "design" and luma(rimC) >= opt(ctx, "INTERIORS_CEIL_LUMA_MIN"))) then
    local base = { uv = rimUv, rgb = rimC, from = "rim" }
    return base, base
  end
  local env = ctx.env
  local atlas = env.atlas
  local IN = env.IN or {}
  local P = ctx.wp or {}
  local sig = table.concat({ tostring(mode), tostring(opt(ctx, "INTERIORS_CEIL_LUMA_MIN")), tostring(P.tier), tostring(P.lo),
    tostring(P.up), tostring(P.col), tostring(ctx.floorMid), tostring(IN.wallLower), tostring(IN.wallUpper), tostring(rimC),
    tostring(rimUv and rimUv[1]), tostring(rimUv and rimUv[2]) }, "|")
  local byAtlas = type(atlas) == "table" and lookCache[atlas] or nil
  local hit = byAtlas and byAtlas[sig]
  if hit then return hit[1], hit[2] end
  local pal = Kit and Kit.palette(ctx) or {}
  local base = pickColour(ctx, pal, rimUv or false, rimC)
  local lamp = pal.light and pal.light.rgb and { uv = pal.light, rgb = pal.light.rgb } or base
  if type(atlas) == "table" and base then
    if not byAtlas then byAtlas = {}; lookCache[atlas] = byAtlas end
    byAtlas[sig] = { base, lamp }
  end
  return base, lamp
end
Ceiling.lookOf = lookOf

-- a hint colour: an rgb number -> a mip-safe texel of that colour in the
-- room's tiles (Kit.colourUv), or a UV rect as given
local function hintColour(ctx, Kit, c)
  if type(c) == "table" and c[1] then return { uv = c, rgb = c.rgb } end
  if type(c) == "number" and Kit and Kit.colourUv then
    local r = Kit.colourUv(ctx, c)
    if r then return { uv = r, rgb = c } end
  end
  return nil
end

-- ---------------------------------------------------------------- geometry
-- a horizontal quad, one UV rect (u0 v0 at the north-west corner): the
-- core's ctx:hquad vertex order (a b c / a c d) with the vertex constructor
-- fetched once per build (ctx:newVfn(); no per-quad method dispatch)
local function hquadFn(ctx)
  local newV = ctx:newVfn()
  return function(list, x0, z0, x1, z1, y, r, nx, ny, nz)
    local u0, v0, u1, v1 = r[1], r[2], r[3], r[4]
    local a = newV(x0, y, z0, u0, v0, nx, ny, nz)
    local b = newV(x1, y, z0, u1, v0, nx, ny, nz)
    local c = newV(x1, y, z1, u1, v1, nx, ny, nz)
    local d = newV(x0, y, z1, u0, v1, nx, ny, nz)
    local n = #list
    list[n + 1], list[n + 2], list[n + 3], list[n + 4], list[n + 5], list[n + 6] = a, b, c, a, c, d
  end
end
local function solidHQuad(ctx, list, x0, z0, x1, z1, y, uv, n)
  ctx:hquad(list, x0, z0, x1, z1, y, uv, n[1], n[2], n[3])
end
local function solidFan(ctx, list, poly, y, uv, n)
  local newV = ctx:newVfn()
  local u, v = (uv[1] + uv[3]) * 0.5, (uv[2] + uv[4]) * 0.5
  local vs = {}
  for i, p in ipairs(poly) do vs[i] = newV(p[1], y, p[2], u, v, n[1], n[2], n[3]) end
  for i = 2, #vs - 1 do ctx:tri(list, vs[1], vs[i], vs[i + 1]) end
  return #vs - 2
end

-- the inward-facing edge of a trimmed cell rect on `side`: a (left, seen
-- from inside the cell) -> b, the inward normal, the wallpaper coordinate
local function edgeOf(side, X0, Z0, X1, Z1)
  if side == "up" then return X0, Z0, X1, Z0, 0, 1, X0 end
  if side == "down" then return X1, Z1, X0, Z1, 0, -1, -X1 end
  if side == "left" then return X0, Z1, X0, Z0, 1, 0, -Z1 end
  return X1, Z0, X1, Z1, -1, 0, Z0
end
Ceiling.edgeOf = edgeOf

-- rect minus rect -> up to 4 rects (axis-aligned, {x0, z0, x1, z1})
local EPS = 1e-6
local function subtract(rects, b)
  local out = {}
  for i = 1, #rects do
    local r = rects[i]
    local ix0, iz0 = mmax(r[1], b[1]), mmax(r[2], b[2])
    local ix1, iz1 = mmin(r[3], b[3]), mmin(r[4], b[4])
    if ix1 - ix0 > EPS and iz1 - iz0 > EPS then
      if iz0 - r[2] > EPS then out[#out + 1] = { r[1], r[2], r[3], iz0 } end
      if r[4] - iz1 > EPS then out[#out + 1] = { r[1], iz1, r[3], r[4] } end
      if ix0 - r[1] > EPS then out[#out + 1] = { r[1], iz0, ix0, iz1 } end
      if r[3] - ix1 > EPS then out[#out + 1] = { ix1, iz0, r[3], iz1 } end
    else
      out[#out + 1] = r
    end
  end
  return out
end
Ceiling.subtract = subtract


-- ---------------------------------------------------------------- cells
-- (walk returns the ground counts of the WALKABLE ceiling cells -- the
-- floor people stand on: the Cerulean pool's 128 water cells outnumber its
-- 122 deck cells -- or of every ceiling cell when none is walkable)
-- Per-cell state lives in DENSE arrays indexed k = y * W + x + 1 over the
-- whole map, filled in grid order (the array part: the JIT-off interpreter
-- pays ~5x more for hash inserts). CC[k] = the mesher's cell or false;
-- TM[k] = the trim mask of a ceiling cell: SYNTH_WALL_INSET on the sides
-- whose neighbour is void / off-map / an exit frame (1 up, 2 down, 4 left,
-- 8 right), cleared on stair-step edges absorbed into a slanted 4th wall --
-- exactly ctx:ceilingCells() (test_ceiling_units.lua asserts it on every map).
local SBIT = { 1, 2, 4, 8 }                      -- up, down, left, right
local SNAME = { "up", "down", "left", "right" }
local DXS, DYS = { 0, 0, -1, 1 }, { -1, 1, 0, 0 }
local function has(m, b) return m % (b + b) >= b end
Ceiling.has = has

local function walk(ctx, A)
  local W, H = ctx.W, ctx.H
  local grid = ctx.grid
  local absSouth, fin = ctx.absSouth or {}, ctx.fin or {}
  local CC, TM, list, stairs = A.CC, A.TM, A.list, A.stairs
  local CH = A.CH
  local cnt, cntW = {}, {}
  local minWall = 1e9 -- the lowest wall run (a wall top under the ceiling needs a riser)
  local n, ns = 0, 0
  local minX, maxX, minY, maxY = W, -1, H, -1
  local k = 0
  for y = 0, H - 1 do
    local row, rowU, rowD = grid[y], grid[y - 1], grid[y + 1]
    for x = 0, W - 1 do
      k = k + 1
      local c = row[x]
      if c and c.role ~= "wall" and not c.exitFrame then
        local m = 0
        local q = rowU and rowU[x]
        if (not q) or q.exitFrame then m = 1 end
        q = rowD and rowD[x]
        if (not q) or q.exitFrame then m = m + 2 end
        q = x > 0 and row[x - 1] or nil
        if (not q) or q.exitFrame then m = m + 4 end
        q = x < W - 1 and row[x + 1] or nil
        if (not q) or q.exitFrame then m = m + 8 end
        if m > 0 then
          local kk = y * 65536 + x
          if absSouth[kk] and has(m, 2) then m = m - 2 end
          if fin[kk * 4 + 1] and has(m, 4) then m = m - 4 end
          if fin[kk * 4 + 2] and has(m, 8) then m = m - 8 end
        end
        CC[k], TM[k], CH[k] = c, m, false
        local g = c.hgt or 0
        cnt[g] = (cnt[g] or 0) + 1
        if c.walkable then cntW[g] = (cntW[g] or 0) + 1 end
        n = n + 1
        list[n] = k
        if x < minX then minX = x end
        if x > maxX then maxX = x end
        if y < minY then minY = y end
        if y > maxY then maxY = y end
        local b = c.beh
        if b and STAIRS[b] and c.walkable then ns = ns + 1; stairs[ns] = k end
      else
        CC[k], TM[k], CH[k] = false, 0, false
        if c and c.role == "wall" and (c.hgt or 0) < minWall then minWall = c.hgt or 0 end
      end
    end
  end
  return next(cntW) and cntW or cnt, minX, maxX, minY, maxY, minWall
end
Ceiling.walk = walk

-- horizontal faces already lying at a ceiling height (hset[y] = true):
-- axis-aligned rectangle halves only (a slanted cap never overlaps a
-- ceiling cell) whose centroid lies over a floor-level cell (a wall run's
-- own top never reaches over a ceiling cell -- the quick reject), kept for
-- the ceiling cells (CH[k] = its height, not an opening) whose trimmed
-- rect they overlap at that height -> blk[k] = { { x0, z0, x1, z1, y } }
local function scanBlockers(ctx, hset, A)
  local env = ctx.env
  local W, H, ins = ctx.W, ctx.H, A.ins
  local CC, CH, OK, TM = A.CC, A.CH, A.OK, A.TM
  local blk, n = {}, 0
  local function consider(a, b, c)
    local ay = a[2]
    local ax, az, bx, bz, cx_, cz_ = a[1], a[3], b[1], b[3], c[1], c[3]
    local x0, x1 = mmin(ax, bx, cx_), mmax(ax, bx, cx_)
    local z0, z1 = mmin(az, bz, cz_), mmax(az, bz, cz_)
    if x1 - x0 < EPS or z1 - z0 < EPS then return end
    -- every corner on the bounding box's corners (an axis-aligned rect half)
    if not ((mabs(ax - x0) < EPS or mabs(ax - x1) < EPS) and (mabs(az - z0) < EPS or mabs(az - z1) < EPS)) then return end
    if not ((mabs(bx - x0) < EPS or mabs(bx - x1) < EPS) and (mabs(bz - z0) < EPS or mabs(bz - z1) < EPS)) then return end
    if not ((mabs(cx_ - x0) < EPS or mabs(cx_ - x1) < EPS) and (mabs(cz_ - z0) < EPS or mabs(cz_ - z1) < EPS)) then return end
    local rect
    for cz = mmax(0, mfloor(z0 + EPS)), mmin(H - 1, math.ceil(z1 - EPS) - 1) do
      for cx = mmax(0, mfloor(x0 + EPS)), mmin(W - 1, math.ceil(x1 - EPS) - 1) do
        local k = cz * W + cx + 1
        if CH[k] == ay and not OK[k] then
          local m = TM[k]
          local rx0 = cx + (has(m, 4) and ins or 0)
          local rx1 = cx + 1 - (m >= 8 and ins or 0)
          local rz0 = cz + (m % 2 >= 1 and ins or 0)
          local rz1 = cz + 1 - (m % 4 >= 2 and ins or 0)
          if mmin(x1, rx1) - mmax(x0, rx0) > EPS and mmin(z1, rz1) - mmax(z0, rz0) > EPS then
            rect = rect or { x0, z0, x1, z1, ay }
            local l = blk[k]
            if not l then l = {}; blk[k] = l end
            l[#l + 1] = rect
          end
        end
      end
    end
    if rect then n = n + 1 end
  end
  local lists = { env.opaque, env.over, env.under, env.keyed }
  for _, g in ipairs(ctx.groups or {}) do lists[#lists + 1] = g.list end
  local third = 1 / 3
  for li = 1, #lists do
    local L = lists[li]
    if type(L) == "table" then
      for i = 1, #L - 2, 3 do
        local a = L[i]
        local ay = a[2]
        if hset[ay] then
          local b, c = L[i + 1], L[i + 2]
          if b[2] == ay and c[2] == ay then
            local mx = (a[1] + b[1] + c[1]) * third
            local mz = (a[3] + b[3] + c[3]) * third
            if mx >= 0 and mz >= 0 and mx < W and mz < H and CC[(mz - mz % 1) * W + (mx - mx % 1) + 1] then consider(a, b, c) end
          end
        end
      end
    end
  end
  return blk, n
end

-- ---------------------------------------------------------------- stitch
-- (repair1, skeptic-visual FAIL 2) the ceiling pieces of each height --
-- rects { x0, z0, x1, z1, h, ci } and convex polygons { poly, h } -- emitted
-- WITHOUT T-junctions: every vertex another piece of that height has on a
-- piece's edge splits that edge, so both sides of a seam rasterise the same
-- segments (a T-junction leaves 1-pixel cracks onto the black background:
-- the Rival's house z = 8 seam). A rect split on its N / S edges only is
-- strip-triangulated between them (its W / E edges likewise), otherwise fanned
-- from its centre; a polygon with inserted vertices is fanned from its
-- centroid. Geometric winding as ctx:hquad (normal down); UVs bilinear over a
-- rect exactly as ctx:hquad maps them. Drawn at h - drop.
-- -> the number of inserted vertices
local function qk(v) return mfloor(v * 1e5 + 0.5) end
function Ceiling.emitPieces(ctx, grp, rects, nr, polys, colours, baseUv, n, drop, stitch, hq)
  local nx, ny, nz = n[1], n[2], n[3]
  local newV = ctx:newVfn()
  local EP = 1e-6
  -- the points of every height: byZ[h][kz] = { x ... }, byX[h][kx] = { z ... }, all[h]
  local IX = {}
  local function add(h, x, z)
    local e = IX[h]
    if not e then e = { byZ = {}, byX = {}, all = {} }; IX[h] = e end
    local kz, kx = qk(z), qk(x)
    local l = e.byZ[kz]; if not l then l = {}; e.byZ[kz] = l end; l[#l + 1] = x
    l = e.byX[kx]; if not l then l = {}; e.byX[kx] = l end; l[#l + 1] = z
    e.all[#e.all + 1] = { x, z }
  end
  if stitch then
    for i = 1, nr do
      local r = rects[i]
      add(r[5], r[1], r[2]); add(r[5], r[3], r[2]); add(r[5], r[3], r[4]); add(r[5], r[1], r[4])
    end
    for _, pp in ipairs(polys) do
      for _, p in ipairs(pp[1]) do add(pp[2], p[1], p[2]) end
    end
  end
  -- sorted unique values of list strictly inside (a, b)
  local function inside(list, a, b)
    if not list then return nil end
    local out
    for i = 1, #list do
      local v = list[i]
      if v > a + EP and v < b - EP then out = out or {}; out[#out + 1] = v end
    end
    if not out then return nil end
    table.sort(out)
    local u = { out[1] }
    for i = 2, #out do if out[i] - u[#u] > EP then u[#u + 1] = out[i] end end
    return u
  end
  local inserted = 0
  local function tri(L, a, b, c)
    -- winding: geometric normal down (as ctx:hquad)
    local cy = (b[3] - a[3]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[3] - a[3])
    if cy > 0 then b, c = c, b end
    ctx:tri(L, a, b, c)
  end
  -- a convex ring (collinear points on its edges allowed) -> #ring - 2
  -- triangles, none degenerate: an ear is clipped at a true corner, and only
  -- when no other vertex of the ring lies in its triangle or on its new
  -- diagonal (a diagonal along a collinear run would skip those vertices:
  -- the T-junction again). Coincident consecutive vertices (clip output)
  -- are merged first.
  local function earclip(L, ring0)
    local ring = {}
    for k = 1, #ring0 do
      local v, w = ring0[k], ring[#ring]
      if not (w and mabs(v[1] - w[1]) < 1e-9 and mabs(v[3] - w[3]) < 1e-9) then ring[#ring + 1] = v end
    end
    while #ring > 1 and mabs(ring[1][1] - ring[#ring][1]) < 1e-9 and mabs(ring[1][3] - ring[#ring][3]) < 1e-9 do ring[#ring] = nil end
    local function blocked(ia, ib, ic, idx)
      local a, b, c = ring[ia], ring[ib], ring[ic]
      local d0 = (b[1] - a[1]) * (c[3] - a[3]) - (b[3] - a[3]) * (c[1] - a[1])
      local s = d0 > 0 and 1 or -1
      for _, j in ipairs(idx) do
        if j ~= ia and j ~= ib and j ~= ic then
          local p = ring[j]
          local d1 = (b[1] - a[1]) * (p[3] - a[3]) - (b[3] - a[3]) * (p[1] - a[1])
          local d2 = (c[1] - b[1]) * (p[3] - b[3]) - (c[3] - b[3]) * (p[1] - b[1])
          local d3 = (a[1] - c[1]) * (p[3] - c[3]) - (a[3] - c[3]) * (p[1] - c[1])
          if d1 * s >= -1e-12 and d2 * s >= -1e-12 and d3 * s >= -1e-12 then return true end
        end
      end
      return false
    end
    local idx = {}
    for k = 1, #ring do idx[k] = k end
    local i, guard, lim = 1, 0, 4 * #ring * #ring + 8
    while #idx > 3 and guard < lim do
      guard = guard + 1
      local m = #idx
      local ia, ib, ic = idx[(i - 2) % m + 1], idx[i], idx[i % m + 1]
      local a, b, c = ring[ia], ring[ib], ring[ic]
      local ar = (b[1] - a[1]) * (c[3] - a[3]) - (b[3] - a[3]) * (c[1] - a[1])
      if (ar > 1e-12 or ar < -1e-12) and not blocked(ia, ib, ic, idx) then
        tri(L, a, b, c)
        table.remove(idx, i)
        if i > #idx then i = 1 end
      else
        i = i % m + 1
      end
    end
    if #idx == 3 then tri(L, ring[idx[1]], ring[idx[2]], ring[idx[3]]) end
  end
  for i = 1, nr do
    local r = rects[i]
    local h = r[5]
    local y = h - drop
    local uv = colours[r[6]].uv
    local L = grp("ceiling", y)
    local x0, z0, x1, z1 = r[1], r[2], r[3], r[4]
    local e = stitch and IX[h]
    local top = e and inside(e.byZ[qk(z0)], x0, x1)
    local bot = e and inside(e.byZ[qk(z1)], x0, x1)
    local lft = e and inside(e.byX[qk(x0)], z0, z1)
    local rgt = e and inside(e.byX[qk(x1)], z0, z1)
    if not (top or bot or lft or rgt) then
      hq(L, x0, z0, x1, z1, y, uv, nx, ny, nz)
    else
      local du, dv = (uv[3] - uv[1]) / (x1 - x0), (uv[4] - uv[2]) / (z1 - z0)
      local function V(x, z) return newV(x, y, z, uv[1] + du * (x - x0), uv[2] + dv * (z - z0), nx, ny, nz) end
      local function line(a, b, mids, fixed, alongX)
        local t = { alongX and V(a, fixed) or V(fixed, a) }
        for _, m in ipairs(mids or {}) do t[#t + 1] = alongX and V(m, fixed) or V(fixed, m) end
        t[#t + 1] = alongX and V(b, fixed) or V(fixed, b)
        return t
      end
      inserted = inserted + (top and #top or 0) + (bot and #bot or 0) + (lft and #lft or 0) + (rgt and #rgt or 0)
      local function strip(A, B, key)
        -- A, B: polylines along the same axis (index key: 1 = x, 3 = z)
        local i, j = 1, 1
        while i < #A or j < #B do
          if j == #B or (i < #A and A[i + 1][key] <= B[j + 1][key]) then
            tri(L, A[i], A[i + 1], B[j]); i = i + 1
          else
            tri(L, A[i], B[j + 1], B[j]); j = j + 1
          end
        end
      end
      if not (lft or rgt) then
        strip(line(x0, x1, top, z0, true), line(x0, x1, bot, z1, true), 1)
      elseif not (top or bot) then
        strip(line(z0, z1, lft, x0, false), line(z0, z1, rgt, x1, false), 3)
      else
        -- the boundary (N edge W -> E, E edge N -> S, S edge E -> W, W edge S -> N), ear-clipped
        local ring = { V(x0, z0) }
        for _, m in ipairs(top or {}) do ring[#ring + 1] = V(m, z0) end
        ring[#ring + 1] = V(x1, z0)
        for _, m in ipairs(rgt or {}) do ring[#ring + 1] = V(x1, m) end
        ring[#ring + 1] = V(x1, z1)
        if bot then for k = #bot, 1, -1 do ring[#ring + 1] = V(bot[k], z1) end end
        ring[#ring + 1] = V(x0, z1)
        if lft then for k = #lft, 1, -1 do ring[#ring + 1] = V(x0, lft[k]) end end
        earclip(L, ring)
      end
    end
  end
  local cu, cv = (baseUv[1] + baseUv[3]) * 0.5, (baseUv[2] + baseUv[4]) * 0.5
  for _, pp in ipairs(polys) do
    local poly, h = pp[1], pp[2]
    local y = h - drop
    local L = grp("ceiling", y)
    local e = stitch and IX[h]
    local ring, extra = {}, 0
    for k = 1, #poly do
      local p, q = poly[k], poly[k % #poly + 1]
      ring[#ring + 1] = p
      if e then
        -- the other pieces' points on edge p -> q (strictly inside it)
        local ex, ez = q[1] - p[1], q[2] - p[2]
        local L2 = ex * ex + ez * ez
        if L2 > EP * EP then
          local mids
          local bx0, bx1 = mmin(p[1], q[1]) - EP, mmax(p[1], q[1]) + EP
          local bz0, bz1 = mmin(p[2], q[2]) - EP, mmax(p[2], q[2]) + EP
          for _, s in ipairs(e.all) do
            if s[1] >= bx0 and s[1] <= bx1 and s[2] >= bz0 and s[2] <= bz1 then
              local t = ((s[1] - p[1]) * ex + (s[2] - p[2]) * ez) / L2
              if t > 1e-6 and t < 1 - 1e-6 then
                local dx, dz = s[1] - p[1] - t * ex, s[2] - p[2] - t * ez
                if dx * dx + dz * dz < 1e-12 then mids = mids or {}; mids[#mids + 1] = t end
              end
            end
          end
          if mids then
            table.sort(mids)
            local last = -1
            for _, t in ipairs(mids) do
              if t - last > 1e-6 then ring[#ring + 1] = { p[1] + ex * t, p[2] + ez * t }; extra = extra + 1; last = t end
            end
          end
        end
      end
    end
    local vs = {}
    for k, p in ipairs(ring) do vs[k] = newV(p[1], y, p[2], cu, cv, nx, ny, nz) end
    -- (ear-clipped even without inserted points: the clip leaves coincident
    -- and collinear vertices a plain fan would bridge)
    earclip(L, vs)
    inserted = inserted + extra
  end
  return inserted
end

-- ---------------------------------------------------------------- build
function Ceiling.build(ctx)
  local t0 = now()
  if ctx.openAir then return end -- (the core never calls us there)
  -- (dev: Ceiling.profile = {} collects os.clock per phase)
  local PROF
  if Ceiling.profile then
    local P, tp = Ceiling.profile, now()
    PROF = function(name) local t = now(); P[name] = (P[name] or 0) + t - tp; tp = t end
  end
  local env = ctx.env
  local W, H, WH = ctx.W, ctx.H, ctx.WH or 2.0
  local ins = ctx.ins or 0.06
  local st = ctx.stats
  -- (repair1) drawn heights: DROP below nominal (see the header)
  local drop = opt(ctx, "INTERIORS_CEIL_DROP") or 0
  local Kit = type(env.require) == "function" and env.require("mesh/interiors/Kit") or nil
  if type(Kit) ~= "table" then Kit = nil end

  -- ---- look ----
  local shade = opt(ctx, "INTERIORS_CEIL_SHADE")
  local unlit = shade == "unlit" or shade == "colour"
  local ceilN = unlit and { 0, 0, 0 } or { 0, -1, 0 }
  if shade == "wall" then local a, b, c = ctx:shadeN(0, 1); ceilN = { a, b, c } end
  local base, lampC = lookOf(ctx, Kit)
  local darkUv = ctx.darkUv
  if not base then base = darkUv and { uv = darkUv, from = "dark" } or nil end
  if not base then error("no ceiling colour (no rim, palette or dark texel)") end
  lampC = lampC or base
  if PROF then PROF("look") end

  -- ---- cells ----
  local A = { ins = ins, W = W, H = H, CC = {}, TM = {}, GM = {}, list = {}, stairs = {},
    CH = {}, OK = {}, CI = {} }
  local cnt, minX, maxX, minY, maxY, minWall = walk(ctx, A)
  local CC, TM, GM, list = A.CC, A.TM, A.GM, A.list
  local CH, OK, CI = A.CH, A.OK, A.CI
  -- an exit slot's or a fall hole's side has no wall slab: the ceiling runs
  -- out to the cell edge over it (a door head the Doors module builds there
  -- at the ceiling height is cut out below, like any such face).
  -- (repair1) a LOWERED ceiling stops at the door plane over an exit, like
  -- beside it: the door head's face rises past it there, and the row stays
  -- one rect (the slot cell no longer splits it: no T-junctions)
  -- (repair2, skeptic-visual-r2 N2) a hole keeps the room's wall now
  -- (INTERIORS_HOLE_WALLS): trimmed like any walled side
  local holeOpen = not (ctx.opt and ctx:opt("INTERIORS_HOLE_WALLS") == true)
  for _, gp in ipairs(ctx.gaps or {}) do
    if (gp.kind == "hole" and holeOpen) or (gp.kind == "exit" and drop == 0) then
      local k = gp.y * W + gp.x + 1
      local b = gp.d == "up" and 1 or gp.d == "down" and 2 or gp.d == "left" and 4 or 8
      if CC[k] and has(TM[k], b) then
        TM[k] = TM[k] - b
        GM[k] = (GM[k] or 0) + b
      end
    end
  end
  local modal, best = nil, -1
  for gv, n in pairs(cnt) do
    if n > best or (n == best and gv < modal) then modal, best = gv, n end
  end
  modal = modal or 0
  local flat, tol = opt(ctx, "INTERIORS_CEIL_FLAT"), opt(ctx, "INTERIORS_CEIL_FLAT_TOL") + 1e-9
  local baseH = modal + WH
  local function hOf(g)
    if flat and mabs(g - modal) <= tol then return baseH end
    return g + WH
  end
  if PROF then PROF("cells") end

  -- section hints (one pcall for the whole map: a failing hook -> no hints)
  local sec = ctx.sec
  local HINT
  if sec and type(sec.ceiling) == "function" then
    local okH, errH = pcall(function()
      HINT = {}
      for i = 1, #list do
        local k = list[i]
        local c = CC[k]
        local hv = sec.ceiling(ctx, c.x, c.y)
        if type(hv) == "table" then HINT[k] = hv end
      end
    end)
    if not okH then HINT = nil; ctx:note("Ceiling section hint", errH) end
  end
  A.HINT = HINT

  -- openings: walkable stair / escalator / ladder warps + the stair art
  -- (c.stair) in their 8-neighbourhood
  local openMode = opt(ctx, "INTERIORS_CEIL_OPENINGS")
  local OPEN = {}
  local nativeClosed = Ceiling.nativeHouseClosure(ctx)
  if openMode ~= "none" then
    for _, k in ipairs(A.stairs) do
      local c = CC[k]
      if not nativeClosed[k] and (openMode == "all" or UP_WARP[c.beh]) then
        OPEN[k] = true
        local x, y = c.x, c.y
        for dy = -1, 1 do
          for dx = -1, 1 do
            local xx, yy = x + dx, y + dy
            if xx >= 0 and xx < W and yy >= 0 and yy < H then
              local k2 = yy * W + xx + 1
              local c2 = CC[k2]
              if c2 and c2.stair and not nativeClosed[k2] then OPEN[k2] = true end
            end
          end
        end
      end
    end
  end

  -- per cell (dense): CH[k] = the ceiling height (false: none; this is
  -- the published ceilY), OK[k] = an opening (a stairwell shaft);
  -- the riser candidates (openings, lowered cells, cells beside a lower
  -- wall top, every cell when not flat)
  local shaftH = opt(ctx, "INTERIORS_CEIL_SHAFT_H")
  local colours, colIdx = { base }, {}
  colIdx[base.uv] = 1
  local hset, nH, nOpen, nCells = {}, 0, 0, 0
  local ceilY = CH
  local cand, nc, candS = {}, 0, {}
  for i = 1, #list do
    local k = list[i]
    local c = CC[k]
    local kind = 0
    local h = 0
    do
      local hint = HINT and HINT[k]
      kind = 1
      if hint and hint.skip then kind = 0
      elseif (OPEN[k] and not (hint and hint.shaft == false)) or (hint and hint.shaft) then kind = 2 end
      if kind > 0 then
        local g = c.hgt or 0
        local dg = g - modal
        if flat and dg <= tol and dg >= -tol then h = baseH else h = g + WH end
        if not hset[h] then hset[h] = true; nH = nH + 1 end
        nCells = nCells + 1
        if kind == 2 then nOpen = nOpen + 1 end
        if kind == 2 or not flat or g + WH < h - 1e-6 then nc = nc + 1; cand[nc] = k; candS[k] = true end
        if hint and hint.colour ~= nil then
          local hc = hintColour(ctx, Kit, hint.colour)
          if hc then
            local ci = colIdx[hc.uv]
            if not ci then colours[#colours + 1] = hc; ci = #colours; colIdx[hc.uv] = ci end
            CI[k] = ci
          end
        end
      end
    end
    if kind > 0 then CH[k] = h; if kind == 2 then OK[k] = true end end
  end
  -- (a section's skip leaves a cell uncovered: its neighbours close
  -- nothing toward it)
  -- a wall run whose top stays under the ceiling next to it (a raised
  -- ceiling, a lowered wall): its ceiling-cell neighbours are candidates
  if minWall + WH < baseH - 1e-6 or not flat then
    local grid = ctx.grid
    for y = 0, H - 1 do
      local row = grid[y]
      for x = 0, W - 1 do
        local q = row[x]
        if q and q.role == "wall" then
          local top = (q.hgt or 0) + WH
          for s = 1, 4 do
            local xx, yy = x + DXS[s], y + DYS[s]
            if xx >= 0 and xx < W and yy >= 0 and yy < H then
              local k2 = yy * W + xx + 1
              if CH[k2] and top < CH[k2] - 1e-6 and not candS[k2] then nc = nc + 1; cand[nc] = k2; candS[k2] = true end
            end
          end
        end
      end
    end
  end
  if PROF then PROF("kinds") end
  ctx:yield()

  -- ---- faces already at a ceiling height: cut out of the ceiling ----
  -- (repair2) only needed to cut them (DROP = 0) -- with the lowered ceiling
  -- they pass through it and blk only kept lamps off their cells: a lamp
  -- cell's own top reaching the ceiling (a 2.0 box / pillar / gate, ctx:topAt)
  -- says the same without a pass over every list (edge faces -- a concave
  -- corner's cap, a door head -- lie outside a centred lamp anyway)
  local blk, nBlk
  if drop == 0 or opt(ctx, "INTERIORS_CEIL_BLOCKER_SCAN") then
    blk, nBlk = scanBlockers(ctx, hset, A)
  else
    blk, nBlk = setmetatable({}, { __index = function(t, k)
      local c = CC[k]
      local v = false
      if c and CH[k] then
        local top = ctx:topAt(c.x, c.y)
        v = (top and top >= CH[k] - 1e-6) and true or false
      end
      rawset(t, k, v)
      return v
    end }), 0
  end
  if PROF then PROF("blockers") end
  ctx:yield()

  -- ---- groups (one per kind and height) ----
  local groups = {}
  local function grp(kind, y0)
    local gk = groups[kind]
    if not gk then gk = {}; groups[kind] = gk end
    local g = gk[y0]
    if not g then g = ctx:group(kind, { y0 = y0 }); gk[y0] = g end
    return g.list
  end

  -- ---- ceiling rectangles: row runs, merged down the rows ----
  -- (repair1) drawn heights: DROP below nominal (see the header). A lowered
  -- ceiling is never coplanar with a face at the nominal height, and every
  -- such face (a 2.0 box / pillar / gate top, a slab cap in a concave
  -- corner, a door head) is the top of sides that reach that height: the
  -- ceiling passes through them unseen -- no cut-outs (they split rows into
  -- more rects and T-junctions); blk still keeps lamps off those cells
  local cutBlk = drop == 0
  local nCut = 0
  local rects, nr = {}, 0 -- every merged rect { x0, z0, x1, z1, h, ci }
  local open = {}         -- key (x0, x1) -> a rect whose bottom edge is this row's top edge
  for y = 0, H - 1 do
    if y % 16 == 15 then ctx:yield() end
    local nextOpen = {}
    local rowK = y * W + 1
    local x = 0
    while x < W do
      local k = rowK + x
      local h = CH[k]
      if h and not OK[k] then
        local ci, m = CI[k] or 1, TM[k]
        if cutBlk and blk[k] then
          -- a cell holding faces at its ceiling height: its rect minus them
          local parts = { { x + (has(m, 4) and ins or 0), y + (m % 2 >= 1 and ins or 0),
            x + 1 - (m >= 8 and ins or 0), y + 1 - (m % 4 >= 2 and ins or 0) } }
          for _, b in ipairs(blk[k]) do parts = subtract(parts, b) end
          for _, r in ipairs(parts) do nr = nr + 1; rects[nr] = { r[1], r[2], r[3], r[4], h, ci } end
          nCut = nCut + 1
          x = x + 1
        else
          local ud = m % 4
          local x1 = x
          while x1 + 1 < W do
            local k2 = k + (x1 - x) + 1
            local m2 = TM[k2]
            if not (CH[k2] == h and not OK[k2] and not (cutBlk and blk[k2]) and (CI[k2] or 1) == ci
                and m2 % 4 == ud and not has(m2, 4) and TM[k2 - 1] < 8) then break end
            x1 = x1 + 1
          end
          local mr = TM[k + (x1 - x)]
          local rx0, rx1 = x + (has(m, 4) and ins or 0), x1 + 1 - (mr >= 8 and ins or 0)
          local rz0, rz1 = y + (ud % 2 >= 1 and ins or 0), y + 1 - (ud >= 2 and ins or 0)
          local key = mfloor(rx0 * 100 + 0.5) * 100000 + mfloor(rx1 * 100 + 0.5)
          local r = open[key]
          if r and rz0 == y and r[5] == h and r[6] == ci then
            r[4] = rz1
            open[key] = nil
          else
            r = { rx0, rz0, rx1, rz1, h, ci }
            nr = nr + 1
            rects[nr] = r
          end
          if rz1 == y + 1 then nextOpen[key] = r end
          x = x1 + 1
        end
      else
        x = x + 1
      end
    end
    open = nextOpen
  end
  local hq = hquadFn(ctx)
  local cnx, cny, cnz = ceilN[1], ceilN[2], ceilN[3]
  local stitch = opt(ctx, "INTERIORS_CEIL_STITCH")
  if PROF then PROF("rects") end
  ctx:yield()

  -- ---- the floor parts beyond the cells: the slanted north walls' fronts
  -- (ctx.diagOf) and the slanted 4th wall's fills (ctx.fills) ----
  local nPoly = 0
  local polys = {} -- (repair1: collected first, emitted with the rects) { poly, h }
  local function clip(poly, f)
    local out = {}
    for i = 1, #poly do
      local p, q = poly[i], poly[i % #poly + 1]
      local fp, fq = f(p), f(q)
      if fp >= 0 then out[#out + 1] = p end
      if (fp >= 0) ~= (fq >= 0) then
        local tt = fp / (fp - fq)
        out[#out + 1] = { p[1] + (q[1] - p[1]) * tt, p[2] + (q[2] - p[2]) * tt }
      end
    end
    return out
  end
  local diagOf = ctx.diagOf
  if type(diagOf) == "table" then
    -- (grid order: pairs() over cell tables is not deterministic)
    local dl = {}
    for c, dg in pairs(diagOf) do
      if type(c) == "table" and type(dg) == "table" and dg[5] and c.x then dl[#dl + 1] = c end
    end
    table.sort(dl, function(p, q) if p.y ~= q.y then return p.y < q.y end return p.x < q.x end)
    for _, c in ipairs(dl) do
      local dg = diagOf[c]
      do
        local nn = dg[5]
        local px, pz = dg[6], dg[7]
        local x0, z0, x1, z1 = c.x + 0.0, c.y + 0.0, c.x + 1.0, c.y + 1.0
        local front = clip({ { x0, z0 }, { x1, z0 }, { x1, z1 }, { x0, z1 } },
          function(p) return (p[1] - px) * nn[1] + (p[2] - pz) * nn[3] end)
        if #front >= 3 then
          polys[#polys + 1] = { front, hOf(c.hgt or 0) }
          nPoly = nPoly + 1
        end
      end
    end
  end
  for _, f in ipairs(ctx.fills or {}) do
    local gp = f.group
    local poly = f.poly
    if gp and gp.nx then poly = clip(poly, function(p) return gp.nx * p[1] + gp.nz * p[2] + gp.d end) end
    if poly and #poly >= 3 then
      polys[#polys + 1] = { poly, hOf(f.g or 0) }
      nPoly = nPoly + 1
    end
  end
  -- ---- emit rects and polygons, T-junction free per height (repair1) ----
  local stitched = Ceiling.emitPieces(ctx, grp, rects, nr, polys, colours, base.uv, ceilN, drop, stitch, hq)
  if PROF then PROF("polys") end

  -- ---- risers and stairwell shafts: every candidate cell's edge whose
  -- neighbour closes lower than the cell's top ----
  local shadeCache = {}
  local function shadeFor(nx, nz)
    local key = nx * 3 + nz
    local s = shadeCache[key]
    if not s then local a, b, c = ctx:shadeN(nx, nz); s = { a, b, c }; shadeCache[key] = s end
    return s
  end
  local grid = ctx.grid
  local nRise, nShaftFaces, nCaps = 0, 0, 0
  local ceilDrop = drop
  local h2face = {}
  for i = 1, nc do
    local k = cand[i]
    local kind = OK[k] and 2 or 1
    local c = CC[k]
    local x, y = c.x, c.y
    local g, h = c.hgt or 0, CH[k]
    local T = kind == 2 and h + shaftH or h
    local m, gm = TM[k], GM[k] or 0
    local X0 = x + (has(m, 4) and ins or 0)
    local X1 = x + 1 - (m >= 8 and ins or 0)
    local Z0 = y + (m % 2 >= 1 and ins or 0)
    local Z1 = y + 1 - (m % 4 >= 2 and ins or 0)
    for s = 1, 4 do
      local b = SBIT[s]
      local N, anchor, ceilFace
      h2face[s] = false
      if has(m, b) or has(gm, b) then
        N, anchor = g + WH, g -- the cell's own synthetic wall / 4th wall / door slot
      else
        local nx_, ny_ = x + DXS[s], y + DYS[s]
        N = T
        if nx_ >= 0 and nx_ < W and ny_ >= 0 and ny_ < H then
          local k2 = ny_ * W + nx_ + 1
          local h2 = CH[k2]
          if h2 then
            N, anchor, ceilFace = h2 + (OK[k2] and shaftH or 0), g, kind == 1
            h2face[s] = not OK[k2] -- (repair1) a lowered ceiling beyond this edge
          else
            local nb = grid[ny_][nx_]
            if nb and nb.role == "wall" then
              N, anchor = (nb.hgt or 0) + WH, nb.hgt or 0
              if diagOf and diagOf[nb] then N = mmin(N, hOf(nb.hgt or 0)) end
            end
            -- (else: a floor-level cell a section left uncovered, or void
            -- behind an absorbed stair-step edge -- the slanted wall and its
            -- fill close it: nothing to add from here)
          end
        end
      end
      if N < T - 1e-6 then
        local ax, az, bx, bz, nx, nz, s0 = edgeOf(SNAME[s], X0, Z0, X1, Z1)
        -- (repair1) toward a neighbouring CEILING (drawn DROP below its
        -- nominal N) the face reaches 2 x DROP below N: it passes that
        -- ceiling's edge instead of meeting it; its top stays at the nominal
        -- T, DROP above this cell's own lowered ceiling
        local Nd = N
        if h2face[s] then Nd = N - 2 * ceilDrop end
        if kind == 2 then
          local sn = shadeFor(nx, nz)
          local L = grp("shaft", h - ceilDrop)
          local n0 = #L
          ctx:paper(L, ax, az, bx, bz, anchor, N, T, s0, sn[1], sn[2], sn[3])
          -- (the reach below N: the bottom row of vertices moved down, the
          -- band's texels stretched 4 % -- no second, sliver band)
          if Nd < N then
            for q = n0 + 1, #L do local v = L[q]; if mabs(v[2] - N) < 1e-9 then v[2] = Nd end end
          end
          nShaftFaces = nShaftFaces + 1
        else
          local L = grp("riser", T)
          if ceilFace then
            local uv = colours[CI[k] or 1].uv
            ctx:vquad(L, ax, az, bx, bz, Nd, T, uv[1], uv[1], uv[2], uv[2], ceilN[1], ceilN[2], ceilN[3])
          else
            local sn = shadeFor(nx, nz)
            local n0 = #L
            ctx:paper(L, ax, az, bx, bz, anchor, N, T, s0, sn[1], sn[2], sn[3])
            if Nd < N then
              for q = n0 + 1, #L do local v = L[q]; if mabs(v[2] - N) < 1e-9 then v[2] = Nd end end
            end
          end
          nRise = nRise + 1
        end
      end
    end
    if kind == 2 then
      -- (repair1) the dark cap DROP below the shaft walls' tops
      solidHQuad(ctx, grp("shaft", h - ceilDrop), X0, Z0, X1, Z1, T - ceilDrop, darkUv or base.uv, ceilN)
      nCaps = nCaps + 1
    end
  end
  if PROF then PROF("risers") end
  ctx:yield()

  -- ---- lamps: one per BLOCK x BLOCK cells, on a lattice centred in the
  -- floor's bounds ----
  local nLamps, nSlots = 0, 0
  if opt(ctx, "INTERIORS_CEIL_LAMPS") and minX <= maxX then
    local B = opt(ctx, "INTERIORS_CEIL_LAMP_BLOCK")
    local half = opt(ctx, "INTERIORS_CEIL_LAMP_SIZE") * 0.5
    local drop = opt(ctx, "INTERIORS_CEIL_LAMP_DROP")
    local trimOk = ins <= 0.5 - half - 1e-6
    -- (1.1) cells a furniture type pulled out of a wall: no lamp input
    local pre, typeMade = PRE[ctx], nil
    local lx0, lx1, ly0, ly1 = minX, maxX, minY, maxY
    if pre then
      for i = 1, #list do
        local k = list[i]
        local c = CC[k]
        if pre[k] and c and c.typeOwner ~= nil then typeMade = typeMade or {}; typeMade[k] = true end
      end
    end
    if typeMade then
      lx0, lx1, ly0, ly1 = W, -1, H, -1
      for i = 1, #list do
        local k = list[i]
        if not typeMade[k] then
          local c = CC[k]
          if c.x < lx0 then lx0 = c.x end
          if c.x > lx1 then lx1 = c.x end
          if c.y < ly0 then ly0 = c.y end
          if c.y > ly1 then ly1 = c.y end
        end
      end
    end
    local function lattice(a, b)
      local span = b - a + 1
      local n = mmax(1, mfloor(span / B))
      local start = a + mfloor((span - 1 - B * (n - 1)) / 2)
      local out = {}
      for i = 0, n - 1 do out[#out + 1] = start + B * i end
      return out
    end
    -- a lamp cell: a full ceiling cell (no cut), trims within the lamp's
    -- margin, no stairwell in its 8-neighbourhood
    local function lampOk(x, y)
      if x < 0 or y < 0 or x >= W or y >= H then return nil end
      local k = y * W + x + 1
      if not CH[k] or OK[k] or blk[k] then return nil end
      if typeMade and typeMade[k] then return nil end
      if not trimOk and TM[k] ~= 0 then return nil end
      local hint = HINT and HINT[k]
      if hint and hint.lamp == false then return nil end
      if nOpen > 0 then
        for dy = -1, 1 do
          for dx = -1, 1 do
            local xx, yy = x + dx, y + dy
            if xx >= 0 and xx < W and yy >= 0 and yy < H and OK[yy * W + xx + 1] then return nil end
          end
        end
      end
      return k
    end
    local lampUv = lampC.uv
    -- unlit ceilings: a lamp that does not stand out from the ceiling gets
    -- a 1-texel frame in the ceiling's own colour shaded like a lit ceiling
    -- (normal down: 0.58) -- a grey rim, no new colour
    local frameUv
    if unlit and mabs(luma(lampC.rgb) - luma(base.rgb)) < 24 then frameUv = base.uv end
    local placed = {}
    local function lamp(k)
      local c = CC[k]
      local cx, cz = c.x + 0.5, c.y + 0.5
      local h = CH[k] - ceilDrop -- (repair1) under the lowered ceiling
      local L = grp("lamp", h)
      if frameUv then
        local f = half + 1 / 16
        hq(L, cx - f, cz - f, cx + f, cz + f, h - drop * 0.5, frameUv, 0, -1, 0)
      end
      hq(L, cx - half, cz - half, cx + half, cz + half, h - drop, lampUv, 0, 0, 0)
      placed[k] = true
      nLamps = nLamps + 1
    end
    local xs, ys = {}, {}
    if lx0 <= lx1 then xs, ys = lattice(lx0, lx1), lattice(ly0, ly1) end
    nSlots = #xs * #ys
    for _, ly in ipairs(ys) do
      for _, lx in ipairs(xs) do
        -- the lattice cell, else (only when that cell has no ceiling at
        -- all: a wall / void) a good cell one step away
        local k = lampOk(lx, ly)
        local sk = ly * W + lx + 1
        if not k and (not CH[sk] or (typeMade and typeMade[sk])) then
          k = lampOk(lx + 1, ly) or lampOk(lx, ly + 1) or lampOk(lx - 1, ly) or lampOk(lx, ly - 1)
        end
        if k and not placed[k] then lamp(k) end
      end
    end
    -- section-forced lamps (grid order)
    if HINT then
      for i = 1, #list do
        local k = list[i]
        local hv = HINT[k]
        if hv and hv.lamp == true and not placed[k] and CH[k] and not OK[k] and not blk[k]
            and not (typeMade and typeMade[k]) then lamp(k); nSlots = nSlots + 1 end
      end
    end
  end
  if PROF then PROF("lamps") end

  -- ---- publish ----
  -- (repair1) the DRAWN heights (nominal - DROP); A.CH keeps the nominal ones
  if ceilDrop ~= 0 then
    local pub = {}
    for k = 1, W * H do local v = CH[k]; pub[k] = v and (v - ceilDrop) or false end
    ceilY = pub
  end
  ctx.ceilY = ceilY -- dense: the ceiling height, or false (no ceiling)
  A.blk, A.shaftH, A.drop = blk, shaftH, ceilDrop
  st.ceilStitched = stitched
  ctx.ceiling = { arrays = A, blk = blk, base = modal, baseH = baseH, colour = base, lamp = lampC,
    shade = unlit and "unlit" or (shade == "wall" and "wall" or "lit"), version = Ceiling.VERSION }
  st.ceilCells, st.ceilRects, st.ceilCut, st.ceilPolys, st.ceilBlockers = nCells, nr, nCut, nPoly, nBlk
  st.ceilOpenings, st.ceilShaftFaces, st.ceilCaps, st.ceilRisers = nOpen, nShaftFaces, nCaps, nRise
  st.lamps, st.lampSlots, st.ceilHeights, st.ceilColour = nLamps, nSlots, nH, base.from
  st.ceilMs = (now() - t0) * 1000
end

return Ceiling
