-- FRLG_VOXEL / interiors-team DOORS: lib/mesh/interiors/Doors.lua
--
-- Wallpaper exit doors for every interior exit (user decision 2026-09-29:
-- "exit doors = WALLPAPER doors: a frame + a leaf in the room's own
-- wallpaper; sliding doors for shops / offices / gatehouses"). Called by the
-- interiors core (FrlgInteriors finish step 4) as Doors.build(ctx) inside
-- ctx:runModule("Doors", ...): an error here drops only the doors (the
-- core's fallback jambs keep the openings), never the map build.
--
-- What it builds (build/core/API.md sections 4, 5, 8):
--   * GAP doors (ctx.doors kind "gap"): the exit cell's open side. The slot
--     owns the whole span from the floor g to g + 2.0: casing (trim colour,
--     1 texel proud), the opening (12 x 20 texels per cell, 1.2 x 2.0 m),
--     the leaf recessed to 0.005 before the cell edge (S: z = y + 0.995),
--     the room's wallpaper above the head and the head's cap. South slots go
--     into a shell group "door" (hidden in the 3/4 / table view and from a
--     third-person camera outside the room); W / E / N slots into opaque.
--   * FACE doors (kind "face": an arrow warp facing a wall run, the S.S.
--     Anne 1F cabins): the same assembly FACE_LIFT in front of the wall face,
--     in opaque. (repair2) Open-air maps too: the one there, the Dept Store
--     roof's stair hut, is plain brick (its art shows no door).
--   * INSET doors: in-wall doors (mesher role rule 5) whose art is a dark
--     doorway (behaviour 0x60 family: gatehouse north doors, house back
--     doors, harbors, Cinnabar lab ...) get the same assembly in front of the
--     wall face (the mesher's recess and dark art stay behind the leaf).
--     Doors with real art (PC 2F link doors, elevators, S.S. Anne cabins,
--     Sea Cottage pods) keep it.
--   * Wide exits (Record Corner, Colosseum 4P: 4 cells): bays of at most
--     BAY_MAX cells, each its own opening; openings wider than DOUBLE_MIN
--     get two leaves.
-- Colours: every casing / knob / outline / panel colour is a SOLID single
-- texel of the room's own wallpaper, floor or wall tiles (Doors.solids: 3 x 3
-- blocks, mip-safe); the outline is the void patch (darkUv). No Kit
-- dependency. Options (deps.Constants): INTERIORS_DOORS (false = off),
-- INTERIORS_DOOR_STYLE (force), INTERIORS_DOOR_INSETS (false = no inset doors).
-- Leaf styles: "wallpaper" (default; the room's wallpaper 1:1, world-
-- anchored, a 1-texel dark outline and a knob), "sliding" (two wallpaper
-- leaves, centre seam, kick band, pull bars), "panel" (casing-colour leaf,
-- two main-colour panels). Style: the section's doorStyle(ctx, slot) if it
-- returns one, else SLIDING map patterns (shops / offices / gatehouses),
-- else "wallpaper". Option INTERIORS_DOOR_STYLE forces one style.
-- Nothing enters the walkable part of a warp cell: every door vertex lies
-- within PROUD + inset of the exit edge. Coplanar faces never overlap.
-- No debug / package / io (mod sandbox).
local V = ...
local _ = V

local Doors = { VERSION = "doors 1.0 (2026-09-29)" }

local TX = 1 / 16
Doors.TX = TX
Doors.OPEN_W = 12 * TX        -- opening per cell of bay width minus 2 casings (16w - 4 texels)
Doors.OPEN_H = 20 * TX        -- opening height 1.25 cells (2.0 m)
Doors.HEAD_T = 22 * TX        -- casing head top
Doors.CAS = 2 * TX            -- casing width
Doors.PROUD = TX              -- casing proud of the wall plane
Doors.LEAF_BACK = 0.005       -- gap doors: the leaf this far before the cell edge
Doors.FACE_LIFT = 0.008       -- face / inset doors: the leaf this far in front of the wall face
                              -- (over art on a wall face sits 0.004 in front: FACADE_OVER_LIFT)
Doors.BAY_MAX = 2             -- wide exits: at most this many cells per opening
Doors.DOUBLE_MIN = 1.2        -- an opening wider than this gets two leaves
Doors.KNOB_OUT = 0.025        -- knob / pull bar projection
Doors.INSET_DARK = 0.5        -- in-wall door art at least this dark (share of texels) gets a leaf
Doors.DARK_LUMA = 100
Doors.CONTRAST = 28           -- casing: minimum luma difference from the wallpaper's main colour
Doors.STYLES = { wallpaper = true, sliding = true, panel = true }
-- shops / offices / gatehouses (user decision): sliding doors. Lua patterns
-- on the map id; a section's doorStyle() overrides.
Doors.SLIDING = {
  "POKEMON_CENTER", "POKECENTER", "_MART$", "DEPARTMENT_STORE", "GAME_CORNER", "SILPH_CO",
  "ELEVATOR", "_ENTRANCE", "_EAST_BUILDING", "HARBOR", "POKEMON_LAB", "MUSEUM", "BIKE_SHOP",
  "TRAINER_TOWER", "RESTAURANT", "HOTEL", "UNION_ROOM", "TRADE_CENTER", "COLOSSEUM",
  "RECORD_CORNER", "SAFARI_ZONE_OFFICE",
}

local mfloor, mabs, mmax, mmin, mceil = math.floor, math.abs, math.max, math.min, math.ceil

local function opt(ctx, name, def)
  local v = ctx:opt(name)
  if v == nil then return def end
  return v
end

local function luma(rgb)
  if not rgb then return nil end
  local r, g, b = mfloor(rgb / 65536) % 256, mfloor(rgb / 256) % 256, rgb % 256
  return 0.299 * r + 0.587 * g + 0.114 * b
end
Doors.luma = luma

-- ---------------------------------------------------------------- style
function Doors.defaultStyle(mapId)
  if type(mapId) ~= "string" then return "wallpaper" end
  for _, p in ipairs(Doors.SLIDING) do
    if mapId:find(p) then return "sliding" end
  end
  return "wallpaper"
end
-- the section's doorStyle (when it answers with a known style), else the
-- map default; INTERIORS_DOOR_STYLE forces one (captures / tests)
function Doors.styleFor(ctx, slot)
  local force = opt(ctx, "INTERIORS_DOOR_STYLE", nil)
  if force and Doors.STYLES[force] then return force, "option" end
  local sec = ctx.sec
  if sec and type(sec.doorStyle) == "function" then
    local ok, v = pcall(sec.doorStyle, ctx, slot)
    if ok and type(v) == "string" and Doors.STYLES[v] then return v, "section" end
  end
  return Doors.defaultStyle(ctx.mapId), "default"
end

-- ---------------------------------------------------------------- colours
-- (caches that outlive one build, weak-keyed like the core's wallpaper
-- caches: the colours per atlas + wallpaper pick -- the texel searches were
-- ~80 % of this module's JIT-off time -- and the dark share per texel
-- table; a tile swap / re-entry rebuild reuses them)
local colCache = setmetatable({}, { __mode = "k" })  -- atlas -> { [key] = cols }
local darkCache = setmetatable({}, { __mode = "k" }) -- texel table -> dark share
function Doors.clearCaches()
  colCache = setmetatable({}, { __mode = "k" })
  darkCache = setmetatable({}, { __mode = "k" })
end
local function rk(r)
  if not r then return "-" end
  return string.format("%.7f,%.7f,%.7f,%.7f%s", r[1], r[2], r[3], r[4], r.over and "o" or "")
end
-- the room's solid colours: every colour with a 3 x 3 block of itself in
-- the wallpaper pair, the floor tile or the mesher's wall pair -> { [rgb] =
-- single-texel UV rect (.rgb) }, { [rgb] = texel count in the wallpaper pair }
-- (repair1, skeptic-visual FAIL 3) the room's wallpaper tiles: the picked
-- pair, or -- tier C, no pick (every Mart, One Island's PC) -- the mesher's
-- own wall pair its plain strips come from. The tile lists skip nils: an
-- ipairs over { P.lo, ... } stopped at a tier-C room's missing P.lo, found no
-- colour at all and gave those 13 rooms a black casing.
function Doors.paperTiles(ctx)
  local P, IN = ctx.wp or {}, ctx.env.IN
  if P.lo or P.up then return P.lo, P.up end
  return IN and IN.wallLower, IN and IN.wallUpper
end
function Doors.solids(ctx)
  local env = ctx.env
  local IN = env.IN
  local out, weight, seen = {}, {}, {}
  local lo, up = Doors.paperTiles(ctx)
  for _, m in ipairs({ lo or false, up or false }) do
    local t = m and ctx:tex(m)
    if t then for i = 1, 256 do weight[t[i]] = (weight[t[i]] or 0) + 1 end end
  end
  local tiles = { lo or false, up or false, ctx.floorMid or false, (IN and IN.wallLower) or false, (IN and IN.wallUpper) or false }
  for _, m in ipairs(tiles) do
    if m and not seen[m] then
      seen[m] = true
      local t = ctx:tex(m)
      local r = t and env.underRect(m)
      if t and r then
        for row = 1, 14 do
          for col = 1, 14 do
            local c = t[row * 16 + col + 1]
            if c and c >= 0 and not out[c] then
              local p = (row - 1) * 16 + col
              local ok = t[p] == c and t[p+1] == c and t[p+2] == c
                and t[p+16] == c and t[p+17] == c and t[p+18] == c
                and t[p+32] == c and t[p+33] == c and t[p+34] == c
              if ok then
                local f0, f1 = (col + 0.5) / 16, (row + 0.5) / 16
                local e = env.subRect(r, f0, f1, f0, f1)
                e.rgb = c
                out[c] = e
              end
            end
          end
        end
      end
    end
  end
  return out, weight
end
-- casing / trim, knob, outline, panel colours from the room's own palette
function Doors.colours(ctx)
  if ctx._doorCols then return ctx._doorCols end
  local env, P = ctx.env, ctx.wp or {}
  local IN = env.IN
  local key = table.concat({ tostring(P.tier), tostring(P.up), tostring(P.lo), tostring(P.col), tostring(ctx.floorMid),
    tostring(IN and IN.wallLower), tostring(IN and IN.wallUpper), rk(IN and IN.rimUv), rk(ctx.darkUv), rk(ctx.L) }, "|")
  local atlas = env.atlas
  local byA = atlas and colCache[atlas]
  local hit = byA and byA[key]
  if hit then ctx._doorCols = hit; return hit end
  -- Every door colour is a SOLID single texel (the centre of a 3 x 3 block
  -- of one colour, mip-safe like Kit.colourUv) found in the room's own
  -- wallpaper, floor and wall tiles. (Kit.palette falls back to the
  -- wallpaper rect itself when a colour has no 3 x 3 block -- striped
  -- papers like the Pewter Gym's -- which would stretch the stripes over the
  -- casing; its entries are used only when they are single texels.)
  local S, weight = Doors.solids(ctx)
  local loMid = Doors.paperTiles(ctx)
  local lo = loMid and ctx:tex(loMid)
  local mainC, trimC
  if lo then
    local cnt, tc = {}, {}
    for i = 1, 256 do cnt[lo[i]] = (cnt[lo[i]] or 0) + 1 end
    for i = 225, 256 do tc[lo[i]] = (tc[lo[i]] or 0) + 1 end
    local function modal(c)
      local best, bn = nil, -1
      for k, v in pairs(c) do if v > bn or (v == bn and k < best) then best, bn = k, v end end
      return best
    end
    mainC, trimC = modal(cnt), modal(tc)
  end
  local mainL = luma(mainC) or 128
  local function contrast(c) return mabs((luma(c) or mainL) - mainL) end
  -- casing: the trim (skirting) colour if it is solid and contrasts, else
  -- the most used solid colour that contrasts, else the most contrasting
  local casingC
  if trimC and S[trimC] and contrast(trimC) >= Doors.CONTRAST then casingC = trimC end
  if not casingC then
    local bw = -1
    for c in pairs(S) do
      local w = weight[c] or 0
      if contrast(c) >= Doors.CONTRAST and (w > bw or (w == bw and c < casingC)) then casingC, bw = c, w end
    end
  end
  if not casingC then
    local bc = -1
    for c in pairs(S) do
      local k = contrast(c)
      if k > bc or (k == bc and c < casingC) then casingC, bc = c, k end
    end
  end
  -- knob / pull bars: the most contrasting solid colour (ties: the lighter)
  local knobC, kb = nil, -1
  for c in pairs(S) do
    local k = contrast(c)
    if k > kb or (k == kb and (luma(c) or 0) > (luma(knobC) or 0)) then knobC, kb = c, k end
  end
  -- panels: the main colour if solid, else the most used other solid colour
  local panelC = (mainC and S[mainC] and mainC ~= casingC) and mainC or nil
  if not panelC then
    local bw = -1
    for c in pairs(S) do
      local w = weight[c] or 0
      if c ~= casingC and (w > bw or (w == bw and c < panelC)) then panelC, bw = c, w end
    end
  end
  local dark = ctx.darkUv
  -- (repair1) no solid colour at all: the room's rim colour (a light single
  -- texel) before the black void patch -- a wallpaper door never gets a
  -- black frame while the room has any other colour
  local rim = IN and IN.rimUv
  if rim and rim.over then rim = nil end
  local casing = casingC and S[casingC] or rim or dark
  local cols = {
    casing = casing,
    knob = knobC and S[knobC] or casing,
    outline = dark or casing,
    panel = panelC and S[panelC] or casing,
    main = mainC and S[mainC] or nil,
  }
  if not (cols.casing and cols.knob and cols.outline and cols.panel) then error("Doors: no solid colour for the door") end
  ctx._doorCols = cols
  if atlas then
    if not byA then byA = {}; colCache[atlas] = byA end
    byA[key] = cols
  end
  return cols
end

-- ---------------------------------------------------------------- frames
-- a door frame on one wall plane: s runs along the wall left -> right as
-- seen from the room (the world-anchored wallpaper coordinate, Core.sOf),
-- t is the depth behind the plane (t < 0: in front, into the room)
--   S (a room's south wall, inward normal 0,0,-1): x = -s, z = p + t
--   N (north wall, 0,0,1)  : x = s,  z = p - t
--   W (west wall, 1,0,0)   : x = p - t, z = -s
--   E (east wall, -1,0,0)  : x = p + t, z = s
local FRAMES = {
  S = { nx = 0, nz = -1, ux = -1, uz = 0 },
  N = { nx = 0, nz = 1, ux = 1, uz = 0 },
  W = { nx = 1, nz = 0, ux = 0, uz = -1 },
  E = { nx = -1, nz = 0, ux = 0, uz = 1 },
}
Doors.FRAMES = FRAMES

local F = {}
F.__index = F
local function newFrame(ctx, face, p, g, list)
  local fr = FRAMES[face]
  local sx, sy, sz = ctx:shadeN(fr.nx, fr.nz)
  return setmetatable({ ctx = ctx, face = face, fr = fr, p = p, g = g, list = list,
    snx = sx, sny = sy, snz = sz, tris0 = #list }, F)
end
function F:w(s, t)
  local f, p = self.face, self.p
  if f == "S" then return -s, p + t
  elseif f == "N" then return s, p - t
  elseif f == "W" then return p - t, -s end
  return p + t, s
end
-- a face parallel to the wall at depth t, s0 < s1 (left -> right), solid rect r
function F:front(s0, s1, t, y0, y1, r)
  if not r or s1 <= s0 + 1e-9 or y1 <= y0 + 1e-9 then return end
  local ax, az = self:w(s0, t)
  local bx, bz = self:w(s1, t)
  self.ctx:vquad(self.list, ax, az, bx, bz, y0, y1, r[1], r[3], r[2], r[4], self.snx, self.sny, self.snz)
end
-- the room's wallpaper parallel to the wall at depth t (bands anchored at g)
function F:paper(s0, s1, t, y0, y1)
  if s1 <= s0 + 1e-9 or y1 <= y0 + 1e-9 then return end
  local ax, az = self:w(s0, t)
  local bx, bz = self:w(s1, t)
  self.ctx:paper(self.list, ax, az, bx, bz, self.g, y0, y1, s0, self.snx, self.sny, self.snz)
end
-- a face across the wall at s, depth t0..t1 (dir: +1 faces +s, -1 faces -s)
function F:side(s, t0, t1, y0, y1, r, dir)
  if not r or y1 <= y0 + 1e-9 or mabs(t1 - t0) < 1e-9 then return end
  local ax, az = self:w(s, t0)
  local bx, bz = self:w(s, t1)
  local nx, ny, nz = self.ctx:shadeN(dir * self.fr.ux, dir * self.fr.uz)
  self.ctx:vquad(self.list, ax, az, bx, bz, y0, y1, r[1], r[3], r[2], r[4], nx, ny, nz)
end
-- a horizontal face over s0..s1 x t0..t1 at height y (up: normal up, else down)
function F:horiz(s0, s1, t0, t1, y, r, up, list)
  if not r or s1 <= s0 + 1e-9 or mabs(t1 - t0) < 1e-9 then return end
  local ax, az = self:w(s0, t0)
  local bx, bz = self:w(s1, t1)
  local x0, x1, z0, z1 = mmin(ax, bx), mmax(ax, bx), mmin(az, bz), mmax(az, bz)
  self.ctx:hquad(list or self.list, x0, z0, x1, z1, y, r, 0, up and 1 or -1, 0)
end
-- a small box standing out of the leaf (knob, pull bar): front + top + sides
function F:knob(s0, s1, tBack, out, y0, y1, r)
  local tf = tBack - out
  self:front(s0, s1, tf, y0, y1, r)
  self:horiz(s0, s1, tf, tBack, y1, r, true)
  self:side(s0, tf, tBack, y0, y1, r, -1)
  self:side(s1, tf, tBack, y0, y1, r, 1)
end
-- the cell beyond the span end sEdge (dir -1: left end, +1: right end) in the
-- row / column that holds the casing (depth t)
function F:beyond(sEdge, dir, t)
  local x, z = self:w(sEdge + dir * 0.5, t)
  return mfloor(x), mfloor(z)
end

-- ---------------------------------------------------------------- leaves
-- the leaf area o0..o1 (s) x g..g+OPEN_H at depth tL, one style
local function leaf(D, style, o0, o1, tL, cols)
  local g = D.g
  local top = g + Doors.OPEN_H
  local out = cols.outline
  -- 1-texel dark outline: left, right, top
  D:front(o0, o0 + TX, tL, g, top, out)
  D:front(o1 - TX, o1, tL, g, top, out)
  D:front(o0 + TX, o1 - TX, tL, top - TX, top, out)
  local i0, i1, it = o0 + TX, o1 - TX, top - TX
  local double = style == "sliding" or (i1 - i0) > Doors.DOUBLE_MIN
  local leaves
  if double then
    local mid = (i0 + i1) * 0.5
    D:front(mid - TX * 0.5, mid + TX * 0.5, tL, g, it, out) -- centre seam
    leaves = { { i0, mid - TX * 0.5, 1 }, { mid + TX * 0.5, i1, -1 } } -- (knob side: +1 right, -1 left)
  else
    leaves = { { i0, i1, 1 } }
  end
  for _, lf in ipairs(leaves) do
    local a, b, ks = lf[1], lf[2], lf[3]
    if style == "panel" then
      -- casing-colour stiles / rails, two main-colour panels (coplanar tiling)
      local c, pc = cols.casing, cols.panel
      local st = mmin(2 * TX, (b - a) * 0.25)
      local rows = { { g, g + 3 * TX, false }, { g + 3 * TX, g + 9 * TX, true }, { g + 9 * TX, g + 11 * TX, false },
        { g + 11 * TX, it - 2 * TX, true }, { it - 2 * TX, it, false } }
      for _, rw in ipairs(rows) do
        if rw[3] then
          D:front(a, a + st, tL, rw[1], rw[2], c)
          D:front(a + st, b - st, tL, rw[1], rw[2], pc)
          D:front(b - st, b, tL, rw[1], rw[2], c)
        else
          D:front(a, b, tL, rw[1], rw[2], c)
        end
      end
    elseif style == "sliding" then
      D:front(a, b, tL, g, g + 2 * TX, cols.casing) -- kick band
      D:paper(a, b, tL, g + 2 * TX, it)
    else
      D:paper(a, b, tL, g, it)
    end
    -- the handle
    if style == "sliding" then
      -- a vertical pull bar beside the seam
      if ks > 0 then D:knob(b - 3 * TX, b - 2 * TX, tL, Doors.KNOB_OUT, g + 8 * TX, g + 14 * TX, cols.knob)
      else D:knob(a + 2 * TX, a + 3 * TX, tL, Doors.KNOB_OUT, g + 8 * TX, g + 14 * TX, cols.knob) end
    else
      local w = mmin(2 * TX, (b - a) * 0.25)
      if ks > 0 then D:knob(b - 2 * TX - w, b - 2 * TX, tL, Doors.KNOB_OUT, g + 9 * TX, g + 11 * TX, cols.knob)
      else D:knob(a + 2 * TX, a + 2 * TX + w, tL, Doors.KNOB_OUT, g + 9 * TX, g + 11 * TX, cols.knob) end
    end
  end
end

-- ---------------------------------------------------------------- assembly
-- one door over the span sL..sR (s) on frame D.
-- spec: { tFront, tLeaf, wall = true (gap doors: wallpaper above the head
--   and the cap on the plane t = 0 .. capT), capT, capList, capRect,
--   nbL / nbR = { x, y } the cells beyond the ends in the casing's row,
--   extL / extR = the end is a concave extension (no outer face), bays }
local function assembly(D, spec, style, cols)
  local ctx, g = D.ctx, D.g
  local sL, sR = spec.sL, spec.sR
  local tF, tL = spec.tFront, spec.tLeaf
  local c = cols.casing
  local OH, HT, CAS = Doors.OPEN_H, Doors.HEAD_T, Doors.CAS
  local nb = spec.bays or 1
  -- bays over the warp cells' own span (cL..cR), so every opening is centred
  -- on its warp cells even where an end of the casing is trimmed
  local cL, cR = spec.cL or sL, spec.cR or sR
  local bw = (cR - cL) / nb
  local openings = {}
  for k = 0, nb - 1 do
    local b0, b1 = cL + bw * k, cL + bw * (k + 1)
    local o0, o1 = b0 + CAS, b1 - CAS
    if k == 0 then b0 = sL end
    if k == nb - 1 then b1 = sR end
    -- jambs (front), reveals (to the leaf), soffit
    D:front(b0, o0, tF, g, g + OH, c)
    D:front(o1, b1, tF, g, g + OH, c)
    D:side(o0, tF, tL, g, g + OH, c, 1)
    D:side(o1, tF, tL, g, g + OH, c, -1)
    D:horiz(o0, o1, tF, tL, g + OH, c, false)
    leaf(D, style, o0, o1, tL, cols)
    openings[#openings + 1] = { o0, o1 }
  end
  -- head (front + top) across the whole span
  D:front(sL, sR, tF, g + OH, g + HT, c)
  D:horiz(sL, sR, tF, 0, g + HT, c, true)
  -- outer sides of the casing (the casing's thickness in front of the wall),
  -- above whatever stands in the neighbouring cell (no coplanar faces)
  for _, e in ipairs({ { sL, -1, spec.nbL, spec.extL }, { sR, 1, spec.nbR, spec.extR } }) do
    local nbp = e[3]
    if nbp and not e[4] then
      local n = ctx:at(nbp[1], nbp[2])
      if n and n.role ~= "wall" and not ctx:open(nbp[1], nbp[2]) then
        local y0 = mmax(g, ctx:topAt(nbp[1], nbp[2]) or g)
        if y0 < g + HT - 1e-9 then D:side(e[1], tF, 0, y0, g + HT, c, e[2]) end
      end
    end
  end
  if spec.wall then
    -- the room's wallpaper above the head, and the cap over the wall's thickness
    D:paper(sL, sR, 0, g + HT, g + ctx.WH)
    if spec.capRect then D:horiz(sL, sR, 0, spec.capT, g + ctx.WH, spec.capRect, true, spec.capList) end
  end
  return openings
end

-- ---------------------------------------------------------------- slots
-- the along-wall ends of a gap slot, trimmed exactly like the core's slabs
-- (Ctx:slab / straightRun): N / S spans end SYNTH_WALL_INSET short at an
-- open (void / exit-frame) neighbour or run on at a concave corner; W / E
-- spans run on at a concave corner only.
local function gapSpan(ctx, s)
  local ins = ctx.ins
  if s.side == "down" or s.side == "up" then
    local row = s.cells[1].y
    local fy = s.side == "down" and row + 1 or row - 1
    local x0, x1 = s.x0 + 0.0, s.x1 + 0.0
    local ext0, ext1 = false, false
    if ctx:open(s.x0 - 1, row) then x0 = x0 + ins elseif ctx:concave(s.x0 - 1, row, s.x0 - 1, fy) then x0, ext0 = x0 - ins, true end
    if ctx:open(s.x1, row) then x1 = x1 - ins elseif ctx:concave(s.x1, row, s.x1, fy) then x1, ext1 = x1 + ins, true end
    if s.side == "down" then return -x1, -x0, ext1, ext0 end -- S: s = -x (left = east)
    return x0, x1, ext0, ext1
  end
  local col = s.cells[1].x
  local fx = s.side == "left" and col - 1 or col + 1
  local z0, z1 = s.z0 + 0.0, s.z1 + 0.0
  local ext0, ext1 = false, false
  if ctx:concave(col, s.z0 - 1, fx, s.z0 - 1) then z0, ext0 = z0 - ins, true end
  if ctx:concave(col, s.z1, fx, s.z1) then z1, ext1 = z1 + ins, true end
  if s.side == "left" then return -z1, -z0, ext1, ext0 end -- W: s = -z (left = south)
  return z0, z1, ext0, ext1
end

local function capRectOf(ctx, list, over)
  local IN = ctx.env.IN
  local rim = IN and IN.rimUv
  if rim and rim.over then
    if over then return rim, over end
    return ctx:capUv(), list -- (the shell cannot draw over art: dark, like straightRun)
  end
  return ctx:capUv(), list
end

-- (repair1, skeptic-visual FAIL 2) a gap door stands in front of the exit
-- frame -- void. Its coplanar pieces (casing, leaf, outline, head paper) and
-- its seams with the wall slabs beside it meet in T-junctions (1,562 inside
-- the assemblies, 316 wall / door), each a possible 1-pixel crack onto the
-- black background. A BACKSTOP closes every one of them: a box behind the
-- slot, outside the room -- a back face in the room's main wallpaper colour
-- BACKSTOP behind the slot's cell edge, the full wall height, and a lid in
-- the cap colour over the gap between the cell edge and it (the wall top just
-- reads 0.05 deeper there) -- over the whole slot span, on past each end by
-- BACKSTOP_EXT where the row beyond is open and the room cell beside the end
-- is no door (no room behind it, no neighbouring backstop). Only a crack ever
-- shows it; the S door's copy is in the door's shell group (hidden with it
-- in the 3/4 / table view and from outside the 4th wall).
Doors.BACKSTOP = 0.05
Doors.BACKSTOP_EXT = 0.5
Doors.BACKSTOP_BELOW = 0.25
function Doors.backstop(ctx, D, spec, cols)
  local r = cols.main or cols.panel or cols.casing
  if not r then return end
  local tB = ctx.ins + Doors.BACKSTOP
  -- the room-side cells of every exit on this face (a neighbouring slot's
  -- own backstop covers it: no overlap)
  local exitCell = {}
  for _, gp in ipairs(ctx.gaps or {}) do
    if gp.kind == "exit" then exitCell[gp.y * 65536 + gp.x] = true end
  end
  local function ext(s, dir)
    local x, z = D:w(s + dir * Doors.BACKSTOP_EXT * 0.5, tB)
    if not ctx:open(mfloor(x), mfloor(z)) then return 0 end
    local ix, iz = D:w(s + dir * 0.25, -0.25)
    if exitCell[mfloor(iz) * 65536 + mfloor(ix)] then return 0 end
    return Doors.BACKSTOP_EXT
  end
  local s0 = spec.sL - ext(spec.sL, -1)
  local s1 = spec.sR + ext(spec.sR, 1)
  local top = D.g + ctx.WH
  D:front(s0, s1, tB, D.g - Doors.BACKSTOP_BELOW, top, r) -- (below the floor too: a niche exit has no floor beyond it)
  -- (repair1, resumed: seam backstop) the box's two ENDS, from the wall plane
  -- back to it: a crack at the slot's end seams seen at a grazing angle
  -- (along the wall) passed the back face's end and reached the background
  -- (Rival's house, Dept Store 1F). Behind the wall plane: only a crack
  -- ever shows them.
  D:side(s0, 0, tB, D.g - Doors.BACKSTOP_BELOW, top, r, 1)
  D:side(s1, 0, tB, D.g - Doors.BACKSTOP_BELOW, top, r, -1)
  if spec.capRect then D:horiz(s0, s1, spec.capT or ctx.ins, tB, top, spec.capRect, true, spec.capList) end
end

-- one exit slot -> door; returns true when built
function Doors.buildSlot(ctx, slot, cols, st)
  -- (repair2, skeptic-visual-r2) the one open-air face exit -- the Dept
  -- Store roof's stair hut (15,6) E -- is plain brick: its art shows no door,
  -- so it gets one like any face exit. INTERIORS_OPEN_AIR_FACE_DOORS =
  -- false restores the old skip ("its art is the door").
  if slot.kind == "face" and ctx.openAir and opt(ctx, "INTERIORS_OPEN_AIR_FACE_DOORS", true) == false then
    slot.skip = "open-air facade (its art is the door)"
    return false
  end
  if slot.kind == "gap" and slot.side == "down" and ctx.openAir then
    slot.skip = "open-air south edge"
    return false
  end
  local style, src = Doors.styleFor(ctx, slot)
  local face = slot.face
  local p = (face == "S" or face == "N") and slot.z or slot.x
  local g = slot.g
  local list, grp, buf
  if slot.list == "roomShell" then
    grp = ctx:group("door", slot.plane)
    grp.slot = slot
    list = grp.list
  else
    buf = ctx:buffer("opaque")
    list = buf
  end
  local D = newFrame(ctx, face, p, g, list)
  -- the warp cells' own span along the wall (s)
  local cL, cR
  if face == "S" then cL, cR = -slot.x1, -slot.x0
  elseif face == "N" then cL, cR = slot.x0, slot.x1
  elseif face == "W" then cL, cR = -slot.z1, -slot.z0
  else cL, cR = slot.z0, slot.z1 end
  local spec
  if slot.kind == "gap" then
    local sL, sR, extL, extR = gapSpan(ctx, slot)
    local over = nil
    if not grp then over = ctx:buffer("over") end
    local capRect, capList = capRectOf(ctx, list, over)
    spec = { sL = sL, sR = sR, extL = extL, extR = extR, tFront = -Doors.PROUD, tLeaf = ctx.ins - Doors.LEAF_BACK,
      wall = true, capT = ctx.ins, capRect = capRect, capList = capList }
  else
    spec = { sL = cL, sR = cR, tFront = -Doors.FACE_LIFT - Doors.PROUD, tLeaf = -Doors.FACE_LIFT, wall = false }
  end
  spec.cL, spec.cR = cL, cR
  local w = #slot.cells
  spec.bays = w >= 3 and mceil(w / Doors.BAY_MAX) or 1
  local bx, by = D:beyond(spec.sL, -1, spec.tFront)
  spec.nbL = { bx, by }
  bx, by = D:beyond(spec.sR, 1, spec.tFront)
  spec.nbR = { bx, by }
  local openings = assembly(D, spec, style, cols)
  if slot.kind == "gap" then Doors.backstop(ctx, D, spec, cols) end
  slot.built = true
  slot.style, slot.styleFrom = style, src
  slot.door = { face = face, p = p, g = g, sL = spec.sL, sR = spec.sR, cL = cL, cR = cR, tFront = spec.tFront, tLeaf = spec.tLeaf,
    bays = spec.bays, openings = openings, list = grp and "roomShell" or "opaque", group = grp and grp.id or nil,
    tris = (#list - D.tris0) / 3 }
  st.built = st.built + 1
  st.byStyle[style] = (st.byStyle[style] or 0) + 1
  if grp then st.shellTris = st.shellTris + slot.door.tris else st.opaqueTris = st.opaqueTris + slot.door.tris end
  return true
end

-- ---------------------------------------------------------------- insets
-- in-wall doors with dark doorway art (the 0x60 family): the share of
-- lower-tile texels darker than DARK_LUMA
function Doors.darkShare(ctx, mid)
  local t = ctx:tex(mid)
  if not t then return nil end
  local e = darkCache[t]
  if e then return e end
  local n = 0
  for i = 1, 256 do
    local l = t[i] and t[i] >= 0 and luma(t[i])
    if l and l < Doors.DARK_LUMA then n = n + 1 end
  end
  darkCache[t] = n / 256
  return n / 256
end
-- every in-wall door cell whose face is drawn (the run's bottom row with a
-- floor-level cell south of it) -> { c, x, y, dark, inset = bool }
function Doors.insetCandidates(ctx)
  local out = {}
  -- (the core's door-cell list, row-major like a grid scan: in-wall doors
  -- are door cells; big maps without doors cost nothing)
  for _, c in ipairs(ctx:doorCells()) do
    local x, y = c.x, c.y
    if c.role == "wall" and c.inWall == "door" and c.runB == y then
      local s = ctx:at(x, y + 1)
      if s and s.role ~= "wall" and not s.exitFrame then
        local dk = Doors.darkShare(ctx, c.mid)
        out[#out + 1] = { c = c, x = x, y = y, dark = dk, inset = (dk or 0) >= Doors.INSET_DARK }
      end
    end
  end
  return out
end
function Doors.buildInset(ctx, e, cols, st)
  local style, src = Doors.styleFor(ctx, { kind = "inset", face = "N", cells = { { x = e.x, y = e.y } } })
  local buf = ctx:buffer("opaque")
  local g = e.c.hgt or 0
  local D = newFrame(ctx, "N", e.y + 1.0, g, buf) -- the wall's south face, the room to the south
  local spec = { sL = e.x + 0.0, sR = e.x + 1.0, cL = e.x + 0.0, cR = e.x + 1.0, tFront = -Doors.FACE_LIFT - Doors.PROUD,
    tLeaf = -Doors.FACE_LIFT, wall = false, bays = 1 }
  local bx, by = D:beyond(spec.sL, -1, spec.tFront)
  spec.nbL = { bx, by }
  bx, by = D:beyond(spec.sR, 1, spec.tFront)
  spec.nbR = { bx, by }
  local openings = assembly(D, spec, style, cols)
  e.style, e.styleFrom = style, src
  e.door = { face = "N", p = e.y + 1.0, g = g, sL = spec.sL, sR = spec.sR, cL = spec.cL, cR = spec.cR, tFront = spec.tFront, tLeaf = spec.tLeaf,
    bays = 1, openings = openings, list = "opaque", tris = #buf / 3 }
  st.insets = st.insets + 1
  st.opaqueTris = st.opaqueTris + #buf / 3
  st.byStyle[style] = (st.byStyle[style] or 0) + 1
end

-- ---------------------------------------------------------------- entry
local function buildAll(ctx, st)
  local cols = Doors.colours(ctx)
  for _, slot in ipairs(ctx.doors or {}) do
    if not Doors.buildSlot(ctx, slot, cols, st) then
      st.skipped = st.skipped + 1
      st.skips[#st.skips + 1] = string.format("%s %s (%d,%d): %s", slot.kind, slot.face, slot.cells[1].x, slot.cells[1].y,
        tostring(slot.skip))
    end
  end
  ctx.insetDoors = {}
  if opt(ctx, "INTERIORS_DOOR_INSETS", true) then
    for _, e in ipairs(Doors.insetCandidates(ctx)) do
      if e.inset then
        Doors.buildInset(ctx, e, cols, st)
        ctx.insetDoors[#ctx.insetDoors + 1] = e
      end
    end
  end
end
function Doors.build(ctx)
  local st = { built = 0, skipped = 0, insets = 0, shellTris = 0, opaqueTris = 0, byStyle = {}, skips = {} }
  ctx.doorStats = st
  if opt(ctx, "INTERIORS_DOORS", true) == false then return end
  ctx.insetDoors = {}
  local ok, err = pcall(buildAll, ctx, st)
  if not ok then
    -- the core drops every group / buffer of this module; un-mark the slots
    -- so its fallback jambs close the openings exactly as without Doors
    for _, s in ipairs(ctx.doors or {}) do s.built, s.door, s.style, s.styleFrom = false, nil, nil, nil end
    ctx.insetDoors = {}
    error(err, 0)
  end
end

return Doors
