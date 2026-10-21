-- FRLG_VOXEL / interiors team: props/Relief.lua -- the shared piece builder
-- every furniture type draws with (wave 0, 2026-10-01; scout PLAN.md 2.5).
--
-- Method after pokeemerald-3Ds-dualscreen (ZallaxDev, MIT), commit
-- 4c64da2644223668c60e59c7731347baada7295d: 3ds_port/scripts/voxel_building.py
-- (Relief, Card, Lifted) and gen_voxel_buildings.py (front-first pieces, real
-- depth laid with the piece's own top rows). The column logic below (front
-- rows / top rows / depth courses with the outline row once at the back,
-- flanks and back tiled 1:1, faces clipped on source-cell borders) is ported
-- from our Emerald lab's port of it (teams/interiors/.../rse/zx/ZxRoom.lua),
-- re-expressed for FRLG's runtime atlas: no baked data, no new textures --
-- every texel drawn is the player's own ROM-extracted art, read through the
-- atlas the mesher already holds. The licence below covers ZallaxDev's code
-- and method only; the game's own data and art are NOT relicensed by it.
--
--   Copyright (c) 2026 ZallaxDev and Pokemon Emerald 3Ds Dual Screen contributors
--
--   Permission is hereby granted, free of charge, to any person obtaining a copy
--   of this software and associated documentation files (the "Software"), to deal
--   in the Software without restriction, including without limitation the rights
--   to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
--   copies of the Software, and to permit persons to whom the Software is
--   furnished to do so, subject to the following conditions:
--
--   The above copyright notice and this permission notice shall be included in all
--   copies or substantial portions of the Software.
--
--   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
--   IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
--   FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
--   AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
--   LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
--   OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
--   SOFTWARE.
--
-- THE IDEA. The game draws a room from above at an angle: a point at height Y
-- standing at Z shows in the picture at row V = Z - Y (16 px = 1 cell). So a
-- piece of height h whose foot (front bottom edge) is at row z1 shows its FRONT
-- in the last h rows above the foot and its TOP in the rows above those. Built
-- that way, every texel lands 1:1 where the game drew it. The drawing shows only
-- a few rows of top; the rest of the piece's real depth (its collision
-- footprint) is laid with its own top rows repeated course by course, never
-- stretched, the outline row once at the very back.
--
-- HEIGHTS are a parameter (user default 2026-09-29: real-life heights; scout Q1).
-- Zallax takes the art's own row count instead; with Relief that is one number
-- per type (h = rows / 16), nothing else changes.
--
-- API (cells for positions, the room's own art for every texel):
--   R.piece(ctx, spec) -> stats      a relief block
--     spec.x0, x1   footprint columns (cells; may be fractional: insets)
--     spec.z0, z1   back edge and foot (cells; z1 = the front face's plane)
--     spec.h        height (cells, > 0)
--     spec.g        ground (default: the hgt of the cell at the foot row)
--     spec.first    first drawn row of the art (cells, default z0): the art used is
--                   rows first*16 .. z1*16 of the columns x0*16 .. x1*16
--     spec.lid      { r0, r1 } rows (cells) laid in the hidden depth (default:
--                   the drawn top rows without the outline row)
--     spec.sides    "front" (default: the front rows' edge strip) | "lid" | false
--     spec.sideW    (1.1) width of that source strip (cells; default min(1, x1 - x0)):
--                   a thin piece (a 3 px chair back) may tile its flanks / back
--                   from a wider strip in fewer, longer courses
--     spec.sideU    (1.1) first column of the strip (cells; default x0 for the west
--                   flank, x1 - sideW for the east flank and the back)
--     spec.back     nil = auto (skipped when the cells behind are wall / off-map) | true | false
--     spec.flanks   nil = auto (each flank skipped against wall / off-map) | { w = bool, e = bool }
--     spec.lift     lifted piece (a thing standing on a host at that height):
--                   everything moves up AND south by lift, so the picture is unchanged
--     spec.under    target list for the under art (ctx:buffer("opaque") or a test list)
--     spec.over     target list for the over art (ctx:buffer("over")) or nil = none
--     spec.tag      label in the stats
--     spec.tags     (tests) a list that receives "under:front" ... per triangle
--   R.card(ctx, spec) -> stats       an upright card (plants, tall thin art)
--     spec.x0, x1, z (foot line), r0, r1 (art rows, cells), g, under / over
--   R.wallClose(ctx, list, x0, x1, z, g, y0, y1)
--                                    the room's own wallpaper (ctx:paper) on a
--                                    south-facing plane at z: closes the wall
--                                    behind a machine pulled out of it
-- Every vertex comes from ctx:newVfn() (the mesher's newV: bounds, debug tags).
-- Every triangle: counter-clockwise seen from its stored normal; UVs inside ONE
-- atlas slot (faces are clipped on 16-px source-cell borders, Emerald plan D2);
-- void / missing source cells are never sampled (skipped and counted).
-- No state between calls; no debug / package / io (mod sandbox).
local V = ...
local _ = V

local R = { VERSION = "relief 1.1 (2026-10-02)" }
-- 1.1 (w0r1): R.LIFT 0.003 -> 0.0045 (clear of the 0.004 z-fight band, gate
-- G6, and of the core's own 0.004 decal lift); spec.sideW / spec.sideU.
-- Callers that pass neither and draw no over art get the 1.0 geometry.

local mfloor, mceil, mmax, mmin, mabs = math.floor, math.ceil, math.max, math.min, math.abs

R.PX = 16
R.LIFT = 0.0045      -- cells: over art above the under art on the same face
R.MIN_LID = 4        -- px: the thinnest lid band used for the depth courses

local UP, SOUTH, NORTH, EAST, WEST = { 0, 1, 0 }, { 0, 0, 1 }, { 0, 0, -1 }, { 1, 0, 0 }, { -1, 0, 0 }
R.UP, R.SOUTH, R.NORTH, R.EAST, R.WEST = UP, SOUTH, NORTH, EAST, WEST

-- ------------------------------------------------------------ polygon clip
-- points: { X, Y, Z, U, V } (X / Y / Z / U / V in pixels; Y above the ground)
local function clip(poly, k, bound, greater)
  local out = {}
  local n = #poly
  if n == 0 then return out end
  local a = poly[n]
  local ia
  if greater then ia = a[k] >= bound else ia = a[k] <= bound end
  for i = 1, n do
    local b = poly[i]
    local ib
    if greater then ib = b[k] >= bound else ib = b[k] <= bound end
    if ia ~= ib then
      local t = (bound - a[k]) / (b[k] - a[k])
      local p = {}
      for j = 1, 5 do p[j] = a[j] + t * (b[j] - a[j]) end
      p[k] = bound
      out[#out + 1] = p
    end
    if ib then out[#out + 1] = b end
    a, ia = b, ib
  end
  return out
end
local function area2(poly)
  local s = 0
  for i = 1, #poly do
    local a, b = poly[i], poly[i % #poly + 1]
    s = s + (a[4] * b[5] - b[4] * a[5])
  end
  return s
end

-- ------------------------------------------------------------ emission
-- a build job: the target lists, the room, stats
local function newJob(ctx, spec)
  local env = ctx.env
  return {
    ctx = ctx, env = env, newV = ctx:newVfn(), under = spec.under, over = spec.over,
    g = spec.g or 0, isVoid = env.atlas and env.atlas.isVoid, hasOver = env.midHasOver,
    stats = { tris = 0, under = 0, over = 0, skippedVoid = 0, faces = {}, tag = spec.tag },
    tags = spec.tags, -- (tests: one "layer:face" per triangle, in emission order)
    face = "?",
  }
end

local function fan(job, list, vs, nrm, layer)
  local n = #vs
  for i = 2, n - 1 do
    local a, b, c = vs[1], vs[i], vs[i + 1]
    local e1x, e1y, e1z = b[1] - a[1], b[2] - a[2], b[3] - a[3]
    local e2x, e2y, e2z = c[1] - a[1], c[2] - a[2], c[3] - a[3]
    local gx, gy, gz = e1y * e2z - e1z * e2y, e1z * e2x - e1x * e2z, e1x * e2y - e1y * e2x
    -- counter-clockwise seen from the normal side
    if gx * nrm[1] + gy * nrm[2] + gz * nrm[3] < 0 then b, c = c, b end
    if gx * gx + gy * gy + gz * gz > 1e-18 then
      local m = #list
      list[m + 1], list[m + 2], list[m + 3] = a, b, c
      if job.tags then job.tags[#job.tags + 1] = layer .. ":" .. job.face end
      local s = job.stats
      s.tris = s.tris + 1
      s[layer] = s[layer] + 1
      s.faces[job.face] = (s.faces[job.face] or 0) + 1
    end
  end
end

-- one convex fragment inside source cell (cx, cy) -> the lists
local function fragment(job, frag, cx, cy, nrm, liftY, liftZ)
  local ctx, env = job.ctx, job.env
  local c = ctx:at(cx, cy)
  local mid = c and c.mid
  if mid == nil or (job.isVoid and job.isVoid(mid)) then
    job.stats.skippedVoid = job.stats.skippedVoid + 1
    return
  end
  local ru = env.underRect(mid)
  if not ru then job.stats.skippedVoid = job.stats.skippedVoid + 1; return end
  local PX = R.PX
  local g = job.g
  local function verts(r, lift)
    local vs = {}
    for i = 1, #frag do
      local p = frag[i]
      local u = r[1] + ((p[4] - cx * PX) / PX) * (r[3] - r[1])
      local v = r[2] + ((p[5] - cy * PX) / PX) * (r[4] - r[2])
      vs[i] = job.newV(p[1] / PX + nrm[1] * lift, g + (p[2] + liftY) / PX + nrm[2] * lift,
        (p[3] + liftZ) / PX + nrm[3] * lift, u, v, nrm[1], nrm[2], nrm[3])
    end
    return vs
  end
  if job.under then fan(job, job.under, verts(ru, 0), nrm, "under") end
  if job.over and job.hasOver and job.hasOver(mid) and env.overRect then
    local ro = env.overRect(mid)
    if ro then fan(job, job.over, verts(ro, R.LIFT), nrm, "over") end
  end
end

-- a planar polygon (pixels, carrying its source pixels U / V): clipped on the
-- source-cell borders, one fragment per cell
local function face(job, poly, nrm, lift)
  local minU, maxU, minV, maxV = math.huge, -math.huge, math.huge, -math.huge
  for i = 1, #poly do
    local p = poly[i]
    if p[4] < minU then minU = p[4] end
    if p[4] > maxU then maxU = p[4] end
    if p[5] < minV then minV = p[5] end
    if p[5] > maxV then maxV = p[5] end
  end
  local PX = R.PX
  local cx0, cx1 = mfloor(minU / PX + 1e-9), mceil(maxU / PX - 1e-9) - 1
  local cy0, cy1 = mfloor(minV / PX + 1e-9), mceil(maxV / PX - 1e-9) - 1
  local ly, lz = lift or 0, lift or 0
  for cy = cy0, cy1 do
    for cx = cx0, cx1 do
      local c = clip(clip(clip(clip(poly, 4, cx * PX, true), 4, cx * PX + PX, false), 5, cy * PX, true), 5, cy * PX + PX, false)
      if #c >= 3 and mabs(area2(c)) > 1e-7 then fragment(job, c, cx, cy, nrm, ly, lz) end
    end
  end
end
R._face = face -- (tests)

local function P(X, Y, Z, U, Vv) return { X, Y, Z, U, Vv } end

-- tile source rect src = { u0, v0, u1, v1 } (pixels) 1:1 over a face given by
-- xyz(s, t) -> X, Y, Z (s along the face, t DOWN from its top), extents S x T
local function tiled(job, xyz, S, T, src, nrm, lift)
  local tw, th = src[3] - src[1], src[4] - src[2]
  if tw <= 1e-9 or th <= 1e-9 then return end
  local s = 0
  while s < S - 1e-9 do
    local s1 = mmin(S, s + tw)
    local t = 0
    while t < T - 1e-9 do
      local t1 = mmin(T, t + th)
      local pts = {}
      local corners = { { s, t }, { s1, t }, { s1, t1 }, { s, t1 } }
      for i = 1, 4 do
        local cs, ct = corners[i][1], corners[i][2]
        local X, Y, Z = xyz(cs, ct)
        pts[i] = { X, Y, Z, src[1] + (cs - s), src[2] + (ct - t) }
      end
      face(job, pts, nrm, lift)
      t = t1
    end
    s = s1
  end
end

-- ------------------------------------------------------------ wall tests
-- (a wall cell with a slanted face -- the mesher's diagOf, known from finish
-- on -- does not stand on the cell edge: the face beside it stays)
local function isWallOrOff(ctx, x, y)
  local c = ctx:at(x, y)
  if not c or c.exitFrame then return true end
  if c.role ~= "wall" then return false end
  local d = ctx.diagOf
  if type(d) == "table" and d[c] then return false end
  return true
end
-- every cell along column x, rows ya..yb is wall / off-map
local function colWall(ctx, x, ya, yb)
  for y = ya, yb do if not isWallOrOff(ctx, x, y) then return false end end
  return true
end
local function rowWall(ctx, y, xa, xb)
  for x = xa, xb do if not isWallOrOff(ctx, x, y) then return false end end
  return true
end
local function onBorder(v) return mabs(v - mfloor(v + 0.5)) < 1e-9 end

-- ------------------------------------------------------------ R.piece
function R.piece(ctx, spec)
  assert(type(spec) == "table", "Relief.piece: spec")
  local PX = R.PX
  local x0, x1, z0, z1, h = spec.x0, spec.x1, spec.z0, spec.z1, spec.h
  assert(type(x0) == "number" and type(x1) == "number" and x1 > x0, "Relief.piece: x0 < x1")
  assert(type(z0) == "number" and type(z1) == "number" and z1 > z0, "Relief.piece: z0 < z1")
  assert(type(h) == "number" and h > 0 and h <= (ctx.WH or 2.0), "Relief.piece: height out of range")
  assert(spec.under or spec.over, "Relief.piece: no target list")
  if spec.g == nil then
    local c = ctx:at(mfloor(x0), mfloor(z1 - 1e-6))
    spec = setmetatable({ g = c and c.hgt or 0 }, { __index = spec })
  end
  local job = newJob(ctx, spec)
  local lift = (spec.lift or 0) * PX
  -- pixels
  local X0, X1, Z0, F, H = x0 * PX, x1 * PX, z0 * PX, z1 * PX, h * PX
  local first = (spec.first or z0) * PX
  assert(first < F, "Relief.piece: first drawn row at / below the foot")
  local drawn = F - first                 -- art rows above the foot
  local hasTop = drawn > H + 1e-9         -- some rows lie on the top
  local zd = hasTop and (first + H) or F  -- the drawn top starts here (z)
  -- FRONT: rows F - H .. F at y 0 .. H (V = F - y); art shorter than H: the
  -- front rows again above, course by course (never stretched)
  job.face = "front"
  if hasTop then
    face(job, { P(X0, 0, F, X0, F), P(X1, 0, F, X1, F), P(X1, H, F, X1, F - H), P(X0, H, F, X0, F - H) }, SOUTH, lift)
  else
    face(job, { P(X0, 0, F, X0, F), P(X1, 0, F, X1, F), P(X1, drawn, F, X1, first), P(X0, drawn, F, X0, first) }, SOUTH, lift)
    if H > drawn + 1e-9 then
      job.face = "front~repeat"
      job.stats.repeatFront = true
      tiled(job, function(s, t) return X0 + s, H - t, F end, X1 - X0, H - drawn,
        { X0, first, X1, F }, SOUTH, lift)
    end
  end
  -- TOP (drawn): z zd .. F at y = H shows V = z - H
  if hasTop then
    job.face = "top"
    face(job, { P(X0, H, zd, X0, zd - H), P(X1, H, zd, X1, zd - H), P(X1, H, F, X1, F - H), P(X0, H, F, X0, F - H) }, UP, lift)
  end
  -- TOP (hidden real depth) z Z0 .. zd: the lid rows course by course, the
  -- outline row once at the back
  if zd > Z0 + 1e-9 then
    job.face = "top~depth"
    local l0, l1
    if spec.lid then
      l0, l1 = spec.lid[1] * PX, spec.lid[2] * PX
    elseif hasTop then
      local rows = (F - H) - first
      l0, l1 = (rows >= 2) and first + 1 or first, F - H
    else
      l0, l1 = first, mmin(F, first + R.MIN_LID)
    end
    if l1 - l0 < 1 then l1 = mmin(F, l0 + R.MIN_LID) end
    local course = l1 - l0
    local edge = (not spec.lid and hasTop and (F - H) - first >= 2 and zd - Z0 > 1) and 1 or 0
    local far = zd
    while far > Z0 + edge + 1e-6 do
      local near = far
      far = mmax(Z0 + edge, far - course)
      local va = l1 - (near - far)
      face(job, { P(X0, H, far, X0, va), P(X1, H, far, X1, va), P(X1, H, near, X1, l1), P(X0, H, near, X0, l1) }, UP, lift)
    end
    if edge == 1 then
      face(job, { P(X0, H, Z0, X0, first), P(X1, H, Z0, X1, first), P(X1, H, Z0 + 1, X1, first + 1),
        P(X0, H, Z0 + 1, X0, first + 1) }, UP, lift)
    end
  end
  -- side dressing: the front rows' edge strip (or the lid rows), tiled 1:1
  local sides = spec.sides
  if sides == nil then sides = "front" end
  local function sideSrc(west)
    local w = mmin(PX, X1 - X0)
    if spec.sideW ~= nil then
      assert(type(spec.sideW) == "number" and spec.sideW > 0, "Relief.piece: sideW")
      w = spec.sideW * PX
    end
    local ua = west and X0 or (X1 - w)
    if spec.sideU ~= nil then
      assert(type(spec.sideU) == "number", "Relief.piece: sideU")
      ua = spec.sideU * PX
    end
    if sides == "lid" then
      local l0 = hasTop and first or first
      local l1 = hasTop and (F - H) or mmin(F, first + R.MIN_LID)
      return { ua, l0, ua + w, l1 }
    end
    local v0 = hasTop and (F - H) or first
    return { ua, v0, ua + w, F }
  end
  -- BACK (north face at Z0)
  local back = spec.back
  if back == nil then
    back = not (onBorder(z0) and rowWall(ctx, mfloor(z0 + 0.5) - 1, mfloor(x0), mceil(x1) - 1))
  end
  if back and sides then
    job.face = "back"
    tiled(job, function(s, t) return X1 - s, H - t, Z0 end, X1 - X0, H, sideSrc(false), NORTH, lift)
  end
  -- FLANKS (west at X0, east at X1)
  local fl = spec.flanks or {}
  local zr0, zr1 = mfloor(z0), mceil(z1) - 1
  local fw, fe = fl.w, fl.e
  if fw == nil then fw = not (onBorder(x0) and colWall(ctx, mfloor(x0 + 0.5) - 1, zr0, zr1)) end
  if fe == nil then fe = not (onBorder(x1) and colWall(ctx, mfloor(x1 + 0.5), zr0, zr1)) end
  if sides then
    if fw then
      job.face = "flank"
      tiled(job, function(s, t) return X0, H - t, Z0 + s end, F - Z0, H, sideSrc(true), WEST, lift)
    end
    if fe then
      job.face = "flank"
      tiled(job, function(s, t) return X1, H - t, F - s end, F - Z0, H, sideSrc(false), EAST, lift)
    end
  end
  return job.stats
end

-- ------------------------------------------------------------ R.card
-- an upright card at the foot line z: art rows r0 .. r1 (cells) of columns
-- x0 .. x1 standing from the ground, the bottom row at y = 0, facing south
-- (the mesher's plant cards light with an UP normal; pass spec.normal = R.UP
-- for that look)
function R.card(ctx, spec)
  local PX = R.PX
  local x0, x1, z, r0, r1 = spec.x0, spec.x1, spec.z, spec.r0, spec.r1
  assert(type(x0) == "number" and x1 > x0 and type(z) == "number" and r1 > r0, "Relief.card: spec")
  if spec.g == nil then
    local c = ctx:at(mfloor(x0), mfloor(z - 1e-6))
    spec = setmetatable({ g = c and c.hgt or 0 }, { __index = spec })
  end
  local job = newJob(ctx, spec)
  job.face = "card"
  local X0, X1, Z, V0, V1 = x0 * PX, x1 * PX, z * PX, r0 * PX, r1 * PX
  local Hh = V1 - V0
  local nrm = spec.normal or SOUTH
  -- (the winding follows SOUTH; with an UP shading normal the fan orients by it,
  -- so build with SOUTH and copy the shading normal in)
  local saveNewV = job.newV
  if nrm ~= SOUTH then
    job.newV = function(x, y, zz, u, v) return saveNewV(x, y, zz, u, v, nrm[1], nrm[2], nrm[3]) end
  end
  face(job, { P(X0, 0, Z, X0, V1), P(X1, 0, Z, X1, V1), P(X1, Hh, Z, X1, V0), P(X0, Hh, Z, X0, V0) }, SOUTH, 0)
  return job.stats
end

-- ------------------------------------------------------------ R.wallClose
-- the room's wallpaper on the south-facing plane z (x0 .. x1), heights g + y0 .. g + y1
function R.wallClose(ctx, list, x0, x1, z, g, y0, y1)
  local nx, ny, nz = ctx:shadeN(0, 1)
  ctx:paper(list, x0, z, x1, z, g, g + y0, g + y1, x0, nx, ny, nz)
end

return R
