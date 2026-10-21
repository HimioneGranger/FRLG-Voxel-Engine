-- FRLG_VOXEL (W6, battle phase P-B1): the battle's cards.
--
--  * battler card: FireRed's own battle picture (front for the foe, back for
--    your Pokemon) drawn into a small padded canvas with the engine's own
--    placement, offsets, alpha, flash, darken, scale and rotation (the data
--    Anim.present holds). The canvas's bottom row is the ground line, so a
--    fainting Pokemon sinks into the ground and is cut off there.
--  * HP card: FireRed's own healthbox (Healthbox.draw) in a 128x48 canvas,
--    floating above the battler card and turned to face you.
--  * ball card: the Poke Ball on show (the catch throw, shakes, catch or
--    break-out; send-outs), the engine's own ball sheet, placed on the arena
--    axis by BattleCards.screenToArena.
--  * command card: the engine UI frame's bottom strip (y 112-160: text box,
--    FIGHT/BAG/POKeMON/RUN, move menu, battle text) on a low card in front
--    of you; the whole frame while a full screen, a prompt or a small window
--    is up (CRITIQUE #7/#8). Drawn straight from the UI canvas with UVs.
--
-- Sizes follow the Crystal VR battle's values: a 56 px picture spans one
-- cell (1.6 m, 2.86 cm per picture pixel; Battle Art's FULL_PIC = 56 and
-- FULL_W = 16 world px; "life size = world scale"). Round 2 (readability):
-- was 64 px per cell, which drew every Pokemon 12.5% smaller than Crystal's.
--  * effect bands: the engine's own move-effect sprites (Ember, Rock Slide,
--    Thunder Shock, ...) and the ball-open burst, drawn per depth band into
--    padded canvases and stood on the vertical plane through both battlers
--    (BattleCards.bandQuad), in the engine's painter's order.
--  * picture tints: the ball-open fade, palette affine, mosaic, greyscale,
--    move blends and the Transform tint (BattleCards.TINT_SHADER), and the
--    row wobble (hShift).
-- Layout (BattleCards.layout) is pure Lua and unit-tested; the canvas
-- helpers need love.graphics and run once per frame, outside the eye pass.
local V = ...
local _ = V

local BattleCards = {}
BattleCards.__index = BattleCards

-- ------------------------------------------------------------ tunables
BattleCards.METRES_PER_CELL = 1.6
BattleCards.PIC_PX_PER_CELL = 56          -- picture pixels per world cell (Crystal: 56 px = 1 cell)
BattleCards.BATTLER_W, BattleCards.BATTLER_H = 128, 112   -- canvas px; ground = bottom row
BattleCards.BATTLER_PAD_X, BattleCards.BATTLER_HEADROOM = 32, 48
BattleCards.BATTLER_STEP = 16
-- Screen rows from a slot's base y (pret sBattlerCoords) to its ground line:
-- the engine's per-species y offset puts the art's lowest row there, and
-- elevated (floating) species sit above it (CRITIQUE #10).
BattleCards.GROUND_DY = { player = 36, enemy = 32 }
BattleCards.GROUND_EPS = 0.01             -- cells: card bottom above the ground
-- User question 4 (DESIGN 6): FireRed's own battler pictures (no Kanto in
-- Motion art yet).
BattleCards.ART_SOURCE = "firered"
-- User question 3 (DESIGN 6): "healthbox" = FireRed's full healthbox
-- (default); "bar" = a plain HP bar like Crystal's.
BattleCards.HP_STYLE = "healthbox"
BattleCards.HP_W, BattleCards.HP_H = 128, 48          -- canvas px
BattleCards.HP_PAD_X, BattleCards.HP_PAD_Y = 0, 8     -- rest top-left of the box in the canvas
BattleCards.HP_WIDTH_M = 1.2
BattleCards.HP_GAP_M = 0.35                           -- above the picture's frame top
-- User question 2 (DESIGN 6): "low" = the command card low in front of you
-- (default). Placement is LOCAL metres from the head pose pinned at seat time.
BattleCards.COMMAND_PLACEMENT = "low"
BattleCards.COMMAND = { dist = 1.3, drop = 0.75, width = 0.8 }
BattleCards.FULL = { dist = 1.1, drop = 0.35, width = 0.95 }
BattleCards.STRIP_Y, BattleCards.STRIP_H = 112, 48    -- rows of the 240x160 frame
BattleCards.BLOB_W, BattleCards.BLOB_D = 0.9, 0.6     -- cells
BattleCards.BLOB_ALPHA = 0.8
-- Poke Balls (catch throw, shakes, send-outs): a 16 px ball in a 32 px canvas
-- (room for the rotation), on the same picture-pixel scale as the battlers.
BattleCards.BALL_PX = 32
-- Screen -> arena map for balls (singles slot base points, pret
-- sBattlerCoords, and their ground lines): t runs along the arena axis from
-- your Pokemon (0) to the foe (1), and each screen row above the local ground
-- line is one picture pixel of height (critique #6: affine, with shear).
BattleCards.SCREEN_OWN = { x = 72, ground = 80 + 36 }
BattleCards.SCREEN_FOE = { x = 176, ground = 40 + 32 }

local sqrt, atan2 = math.sqrt, math.atan2

-- ------------------------------------------------------------ pure helpers
-- Which engine battler ids get cards, and on which stage side.
-- info = BattleSource:info(). Returns { {id, side = "own"|"foe"}, ... }.
function BattleCards.slotIds(info)
  local ids = (info and info.double) and { 0, 1, 2, 3 } or { 0, 1 }
  local out = {}
  for _, id in ipairs(ids) do
    out[#out + 1] = { id = id, side = (id % 2 == 0) and "own" or "foe" }
  end
  return out
end

-- pan-in fix (user 2026-10-02: "In battle you can visibly see the invisible screen the Pokemon pans in from"):
-- the GBA's slide-ins and lunges move a picture 100+ px sideways on the 240 px screen, but a battler card's
-- canvas is only BATTLER_W wide, so the sprite was cut off at the canvas edge: in 3D it came out of an invisible
-- vertical edge in mid-air. With PAN_WORLD the picture is drawn at its REST column and the whole card moves
-- sideways in the world instead (BattleCards.layout, along the card's own screen-right vector), by the same
-- number of pixels / PIC_PX_PER_CELL. Vertical offsets (bounces, elevation) stay in the canvas. false = the old
-- behaviour (offsets drawn in the canvas, clipped at its edge).
BattleCards.PAN_WORLD = true

function BattleCards.picOrigin(desc)
  return tonumber(desc and desc.originX) or 32, tonumber(desc and desc.originY) or 32
end



-- Canvas position (centre of the 64x64 picture) for a draw descriptor from
-- BattleSource:battlerDraw: the slot's base x maps to the canvas centre
-- column and its ground line to the bottom row.
function BattleCards.canvasPos(desc)
  local gdy = BattleCards.GROUND_DY[desc.side] or 32
  local groundY = (desc.baseY or 0) + gdy
  local colX = desc.cx or 0
  if BattleCards.PAN_WORLD then colX = desc.restCx or colX end -- pan-in fix: the rest column; the card pans in the world
  local px = (desc.cw or BattleCards.BATTLER_W) / 2 + (colX - (desc.baseX or 0)) + ((tonumber(desc.originX) or 32) % 1)
  local py = (desc.ch or BattleCards.BATTLER_H) - (groundY - (desc.cy or 0))
  return px, py, groundY
end

-- gen5 native-res (2026-10-02): battler canvas size for a draw descriptor. The engine's own 64x64 pictures
-- keep BATTLER_W x BATTLER_H exactly; an imported original-resolution picture (up to 256x256) gets a canvas
-- that holds it with the same margins (lunges, bounces, elevation), so nothing is cropped. Same picture
-- pixels per world cell either way: a bigger canvas is a bigger card, never a smaller sprite.
BattleCards.IMPORT_MARGIN_X = 32  -- px each side beyond the picture (the native canvas has 32)
BattleCards.IMPORT_MARGIN_TOP = 48 -- px above the picture's top at rest, including its elevation
BattleCards.IMPORT_MAX = 320
function BattleCards.battlerCanvasSize(desc)
  local w, h = BattleCards.BATTLER_W, BattleCards.BATTLER_H
  if not desc then return w, h end
  local step = BattleCards.BATTLER_STEP
  local function up(n) return math.ceil(n / step) * step end
  local iw = tonumber(desc.imageW) or 64
  w = math.max(w, up(iw + 2 * BattleCards.BATTLER_PAD_X))
  h = math.max(h, up(math.max(0, BattleCards.frameTopPx(desc)) + BattleCards.BATTLER_HEADROOM))
  return w, h
end

-- Card alpha for a draw descriptor: the present alpha, times the engine's
-- hit-flash blink (ui.lua draw_mon_sprite).
function BattleCards.cardAlpha(desc)
  if not desc then return 1 end
  local a = tonumber(desc.alpha) or 1
  local flash = tonumber(desc.flash) or 0
  if flash > 0 then a = a * (0.4 + 0.6 * ((flash % 2 == 0) and 1 or 0.3)) end
  return a
end

-- Height of the picture's 64 px frame top above the ground line (pixels), at
-- rest (no lunge/bounce), for placing the HP card.
function BattleCards.frameTopPx(desc)
  local gdy = BattleCards.GROUND_DY[desc.side] or 32
  local groundY = (desc.baseY or 0) + gdy
  return groundY - ((desc.restCy or desc.cy or 0) - (tonumber(desc.originY) or (tonumber(desc.imgH) or 64) / 2))
end

-- Same for a trainer picture centred at screen (x, y) on `side` (cw, ch = the battler canvas size; default
-- the native canvas).
function BattleCards.trainerCanvasPos(side, x, y, base, cw, ch, ox)
  local gdy = BattleCards.GROUND_DY[side] or 32
  local groundY = base.y + gdy
  if BattleCards.PAN_WORLD then x = x - (tonumber(ox) or 0) end -- pan-in fix: rest column; the trainer card pans in the world
  return (cw or BattleCards.BATTLER_W) / 2 + (x - base.x), (ch or BattleCards.BATTLER_H) - (groundY - y)
end

local function facingDir(x, z, vx, vz)
  local dx, dz = (vx or x) - x, (vz or z + 1) - z
  local len = sqrt(dx * dx + dz * dz)
  if len < 1e-4 then return 0, 1, 0 end
  return dx / len, dz / len, len
end

-- World cards for this frame. stage = BattleStage result; slots = array of
-- { id, x, z, ground, visible, topPx, hbVisible } (x/z/ground from
-- BattleStage.slotPosition); view = { x, y, z } head centre (cells).
-- Returns an array sorted far-to-near of
-- { kind = "battler"|"hp"|"blob", id, x, z, base, w, h, dx, dz, dist }.
function BattleCards.layout(slots, view)
  local mpc, ppc = BattleCards.METRES_PER_CELL, BattleCards.PIC_PX_PER_CELL
  local vx, vy, vz = view and view.x, view and view.y, view and view.z
  local cards = {}
  for _, s in ipairs(slots) do
    local dx, dz, dist = facingDir(s.x, s.z, vx, vz)
    local ground = s.ground or 0
    if s.visible then
      cards[#cards + 1] = { kind = "blob", id = s.id, x = s.x, z = s.z, base = ground + 0.02,
        w = BattleCards.BLOB_W, h = BattleCards.BLOB_D, dx = dx, dz = dz, dist = dist + 0.001 }
    end
    -- pan-in fix: the card's screen-right vector in the world is the quad's x0 -> x1 direction
    -- (BattleCards.quad: x1 - x0 = (dz, -dx) * w), the side image-left (u = 0) is on the viewer's left
    local ux, uz = dz, -dx
    local function pan(px)
      if not BattleCards.PAN_WORLD then return s.x, s.z end
      local d = (tonumber(px) or 0) / ppc
      return s.x + ux * d, s.z + uz * d
    end
    local bx, bz = pan(s.pan)
    cards[#cards + 1] = { kind = "battler", id = s.id, x = bx, z = bz, restX = BattleCards.PAN_WORLD and s.x or nil, restZ = BattleCards.PAN_WORLD and s.z or nil,
      base = ground + BattleCards.GROUND_EPS,
      w = (s.cw or BattleCards.BATTLER_W) / ppc, h = (s.ch or BattleCards.BATTLER_H) / ppc, -- gen5 native-res
      dx = dx, dz = dz, dist = dist, visible = s.visible and true or false }
    if BattleCards.PAN_WORLD and s.trainerDrawn then
      local tx, tz = pan(s.trPan)
      cards[#cards + 1] = { kind = "trainer", id = s.id, x = tx, z = tz, restX = s.x, restZ = s.z,
        base = ground + BattleCards.GROUND_EPS,
        w = (s.cw or BattleCards.BATTLER_W) / ppc, h = (s.ch or BattleCards.BATTLER_H) / ppc,
        dx = dx, dz = dz, dist = dist + 0.002, visible = true }
    end
    if s.hbVisible then
      local w = BattleCards.HP_WIDTH_M / mpc
      local h = w * BattleCards.HP_H / BattleCards.HP_W
      local top = ground + (tonumber(s.topPx) or ppc) / ppc
      cards[#cards + 1] = { kind = "hp", id = s.id, x = s.x, z = s.z,
        base = top + BattleCards.HP_GAP_M / mpc, w = w, h = h, dx = dx, dz = dz,
        dist = dist - 0.001 }
    end
  end
  if vx then
    for _, c in ipairs(cards) do
      local cy = c.base + (c.kind == "blob" and 0 or c.h / 2)
      local ex, ey, ez = c.x - vx, cy - (vy or cy), c.z - vz
      c.dist = sqrt(ex * ex + ey * ey + ez * ez) + (c.kind == "blob" and 0.01 or 0)
        + (c.kind == "trainer" and 0.002 or 0) -- the trainer picture is behind its Pokemon
    end
  end
  return BattleCards.sort(cards)
end

-- Pure: screen point (x, y) of the 240x160 battle frame -> (t, height):
-- t along the arena axis (0 = your Pokemon, 1 = the foe; < 0 is behind
-- yours, toward the seat), height = cells above the local ground.
function BattleCards.screenToArena(x, y)
  local o, f = BattleCards.SCREEN_OWN, BattleCards.SCREEN_FOE
  local t = ((tonumber(x) or 0) - o.x) / (f.x - o.x)
  local groundY = o.ground + (f.ground - o.ground) * t
  return t, (groundY - (tonumber(y) or 0)) / BattleCards.PIC_PX_PER_CELL
end

-- Pure: a world card for one ball descriptor on a stage (own/foe slot
-- centres and grounds), facing the head at view {x, y, z}.
function BattleCards.ballCard(stage, b, view, index)
  local t, h = BattleCards.screenToArena(b.x, b.y)
  local o, f = stage.own, stage.foe
  local x = o.x + (f.x - o.x) * t
  local z = o.z + (f.z - o.z) * t
  local tc = math.max(0, math.min(1, t))
  local ground = (o.ground or 0) + ((f.ground or 0) - (o.ground or 0)) * tc
  local size = BattleCards.BALL_PX / BattleCards.PIC_PX_PER_CELL
  local dx, dz = facingDir(x, z, view and view.x, view and view.z)
  local c = { kind = "ball", id = 10 + (index or 1), x = x, z = z,
    base = ground + math.max(0, h) - size / 2, w = size, h = size, dx = dx, dz = dz, t = t }
  if view and view.x then
    local ex, ey, ez = x - view.x, c.base + size / 2 - (view.y or c.base), z - view.z
    c.dist = sqrt(ex * ex + ey * ey + ez * ez)
  else
    c.dist = 0
  end
  return c
end

-- Draw order (depth writes off, so order is what layers them), the engine's
-- painter's order from ui.lua's Ui.draw: platform, shadow blobs, the back
-- effect band, the foe's cards, the middle band, your cards, the front band
-- (with the ball-open burst), the thrown ball, the HP cards, debug marker.
-- Within a group: far to near, then by id.
local function group(c)
  local k = c.kind
  if k == "curtain" then return -1 end
  if k == "platform" then return 0 end
  if k == "blob" then return 1 end
  if k == "band" then return ({ [0] = 2, [1] = 4, [2] = 6 })[c.id] or 6 end
  if k == "battler" or k == "trainer" then return (c.id % 2 == 1) and 3 or 5 end
  if k == "ball" then return 7 end
  if k == "hp" then return 8 end
  return 9
end
BattleCards.group = group
function BattleCards.sort(cards)
  table.sort(cards, function(a, b)
    local ga, gb = group(a), group(b)
    if ga ~= gb then return ga < gb end
    if math.abs((a.dist or 0) - (b.dist or 0)) > 1e-6 then return (a.dist or 0) > (b.dist or 0) end
    return (a.id or 0) < (b.id or 0)
  end)
  return cards
end

-- ------------------------------------------------------------ effect bands
BattleCards.BAND_PAD = 48                     -- canvas pixels around the 240x160 frame
BattleCards.BANDS = { [0] = { 1, 99 }, [1] = { 101, 199 }, [2] = { 201, 999 } }

-- Pure: world point (cells) of screen point (sx, sy) on the arena plane: t
-- along the axis from your Pokemon to the foe, height above the ground line
-- interpolated between the two slots (affine, so a canvas maps to a flat
-- parallelogram; critique #6).
function BattleCards.arenaPoint(stage, sx, sy)
  local t, h = BattleCards.screenToArena(sx, sy)
  local o, f = stage.own, stage.foe
  local og, fg = o.ground or 0, f.ground or 0
  return o.x + (f.x - o.x) * t, og + (fg - og) * t + h, o.z + (f.z - o.z) * t, t
end

-- Pure: the band canvas quad on the arena plane: 4 corners (cells) in the
-- order top-left, top-right, bottom-right, bottom-left of the canvas.
function BattleCards.bandQuad(stage)
  local P = BattleCards.BAND_PAD
  local pts = {}
  for i, c in ipairs({ { -P, -P }, { 240 + P, -P }, { 240 + P, 160 + P }, { -P, 160 + P } }) do
    local x, y, z = BattleCards.arenaPoint(stage, c[1], c[2])
    pts[i] = { x, y, z }
  end
  return pts
end

-- Round 2: where the effect bands stand. Round 3 default: "battler" (below,
-- BattleCards.battlerBandVerts). "view": a plane facing
-- the eye through the arena centre, mapped with a similarity (uniform scale)
-- so the two slot ground points of the 240x160 frame land exactly on your
-- Pokemon and the foe as seen from the seat; sprites keep their shape
-- (about 2.5 cm per pixel at the seat). "axis": the vertical plane through
-- both battlers (true depth along the arena, but seen 20-30 degrees off
-- its axis, sprites shrink sideways to slivers).
BattleCards.BAND_PLANE = "battler" -- "battler" | "view" | "axis"
BattleCards.SCREEN_OWN_GROUND = { 72, 80 + 36 }
BattleCards.SCREEN_FOE_GROUND = { 176, 40 + 32 }

local function sub3(a, b) return { a[1] - b[1], a[2] - b[2], a[3] - b[3] } end
local function dot3(a, b) return a[1] * b[1] + a[2] * b[2] + a[3] * b[3] end
local function norm3(a)
  local n = sqrt(dot3(a, a))
  if n < 1e-9 then return { 0, 0, 0 } end
  return { a[1] / n, a[2] / n, a[3] / n }
end
local function cross3(a, b)
  return { a[2] * b[3] - a[3] * b[2], a[3] * b[1] - a[1] * b[3], a[1] * b[2] - a[2] * b[1] }
end

-- Pure: the eye-facing band plane. eye = {x, y, z} (cells). Returns the 4
-- canvas corners (top-left, top-right, bottom-right, bottom-left) and a
-- mapping function screen (sx, sy) -> world point, or nil when degenerate.
function BattleCards.viewPlane(stage, eye)
  local o, f = stage.own, stage.foe
  local E = { eye.x, eye.y, eye.z }
  local C = { (o.x + f.x) / 2, ((o.ground or 0) + (f.ground or 0)) / 2 + 0.5, (o.z + f.z) / 2 }
  local fwd = norm3(sub3(C, E))
  if dot3(fwd, fwd) < 0.5 then return nil end
  local right = norm3(cross3(fwd, { 0, 1, 0 }))
  if dot3(right, right) < 0.5 then return nil end
  local up = cross3(right, fwd)
  -- a world point's image on the plane (along its ray from the eye), in plane coords
  local function onPlane(P)
    local d = sub3(P, E)
    local den = dot3(d, fwd)
    if den < 1e-6 then return nil end
    local s = dot3(sub3(C, E), fwd) / den
    local q = { E[1] + d[1] * s - C[1], E[2] + d[2] * s - C[2], E[3] + d[3] * s - C[3] }
    return dot3(q, right), dot3(q, up)
  end
  local ou, ov = onPlane({ o.x, o.ground or 0, o.z })
  local fu, fv = onPlane({ f.x, f.ground or 0, f.z })
  if not (ou and fu) then return nil end
  local so, sf = BattleCards.SCREEN_OWN_GROUND, BattleCards.SCREEN_FOE_GROUND
  -- screen vector (y flipped to up) -> plane vector: similarity (k, theta)
  local sx, sy = sf[1] - so[1], -(sf[2] - so[2])
  local px, py = fu - ou, fv - ov
  local sl = sx * sx + sy * sy
  if sl < 1e-9 then return nil end
  local a = (px * sx + py * sy) / sl        -- k cos(theta)
  local b = (py * sx - px * sy) / sl        -- k sin(theta)
  local function map(scrX, scrY)
    local dx, dy = scrX - so[1], -(scrY - so[2])
    local u = ou + a * dx - b * dy
    local v = ov + b * dx + a * dy
    return { C[1] + right[1] * u + up[1] * v, C[2] + right[2] * u + up[2] * v, C[3] + right[3] * u + up[3] * v }
  end
  local P = BattleCards.BAND_PAD
  local pts = {}
  for i, c in ipairs({ { -P, -P }, { 240 + P, -P }, { 240 + P, 160 + P }, { -P, 160 + P } }) do
    pts[i] = map(c[1], c[2])
  end
  return pts, map, sqrt(a * a + b * b)
end

-- Round 3: "battler" band surface (default). Each effect sits at the depth of
-- the battler it plays on: around your Pokemon, one screen pixel is one
-- picture pixel on the plane of your card (facing the eye, anchored on its
-- ground point); around the foe, the same on the foe's plane; anything in
-- between (a projectile like Ember) blends the two by its screen column, so
-- it flies from the attacker's depth to the target's. Effect sizes keep the
-- GBA proportions to the battler they play on (1 screen px = 1 picture px).
-- The mapping is affine in screen y for a fixed column, so the canvas is
-- drawn as vertical strips (BAND_STRIP px wide).
BattleCards.BAND_STRIP = 8

-- Screen anchors of the two sides: the battlers' ground points on the
-- 240x160 frame (singles: pret sBattlerCoords + the ground lines; doubles:
-- the mean of each side's two slots).
function BattleCards.bandAnchors(double)
  if double then
    return { x = (32 + 90) / 2, y = ((80 + 36) + (88 + 36)) / 2 }, { x = (200 + 152) / 2, y = ((40 + 32) + (32 + 32)) / 2 }
  end
  return { x = 72, y = 80 + 36 }, { x = 176, y = 40 + 32 }
end

-- Pure: the screen -> world map of the battler surface. stage = { own, foe }
-- (x, z, ground), eye = { x, z }. Returns map(sx, sy) -> {x, y, z}, t(sx).
function BattleCards.battlerMap(stage, eye, double)
  local sc = 1 / BattleCards.PIC_PX_PER_CELL
  local ao, af = BattleCards.bandAnchors(double)
  local function side(s)
    local fx, fz = s.x - eye.x, s.z - eye.z
    local l = sqrt(fx * fx + fz * fz)
    if l < 1e-6 then fx, fz, l = 0, -1, 1 end
    fx, fz = fx / l, fz / l
    return { gx = s.x, gy = s.ground or 0, gz = s.z, rx = -fz, rz = fx }
  end
  local o, f = side(stage.own), side(stage.foe)
  local span = af.x - ao.x
  local function tOf(sx)
    local t = (sx - ao.x) / span
    if t < 0 then return 0 elseif t > 1 then return 1 end
    return t
  end
  local function map(sx, sy)
    local t = tOf(sx)
    local ox = o.gx + o.rx * (sx - ao.x) * sc
    local oz = o.gz + o.rz * (sx - ao.x) * sc
    local oy = o.gy + (ao.y - sy) * sc
    local fx = f.gx + f.rx * (sx - af.x) * sc
    local fz = f.gz + f.rz * (sx - af.x) * sc
    local fy = f.gy + (af.y - sy) * sc
    return { ox + (fx - ox) * t, oy + (fy - oy) * t, oz + (fz - oz) * t }
  end
  return map, tOf
end

-- Pure: the band surface as a triangle list (Shaders.FORMAT vertices).
function BattleCards.battlerBandVerts(stage, eye, double)
  local map = BattleCards.battlerMap(stage, eye, double)
  local P, step = BattleCards.BAND_PAD, BattleCards.BAND_STRIP
  local W, H = 240 + 2 * P, 160 + 2 * P
  local verts = {}
  local prevTop, prevBot, prevU
  for sx = -P, 240 + P, step do
    local top, bot = map(sx, -P), map(sx, 160 + P)
    local u = (sx + P) / W
    if prevTop then
      local a = { prevTop[1], prevTop[2], prevTop[3], prevU, 0, 0, 0, 0 }
      local b = { top[1], top[2], top[3], u, 0, 0, 0, 0 }
      local c = { bot[1], bot[2], bot[3], u, 1, 0, 0, 0 }
      local d = { prevBot[1], prevBot[2], prevBot[3], prevU, 1, 0, 0, 0 }
      verts[#verts + 1] = a; verts[#verts + 1] = b; verts[#verts + 1] = c
      verts[#verts + 1] = a; verts[#verts + 1] = c; verts[#verts + 1] = d
    end
    prevTop, prevBot, prevU = top, bot, u
  end
  local _ = H
  return verts
end

-- Upright card corners (x0, z0, x1, z1, bottom, top) facing (dx, dz).
function BattleCards.quad(c)
  local rx, rz = c.dz * (c.w / 2), -c.dx * (c.w / 2)
  return c.x - rx, c.z - rz, c.x + rx, c.z + rz, c.base, c.base + c.h
end

-- LOCAL-space pose of the command card: position, yaw, tilt (radians), width
-- and the UV rows of the UI frame shown. base = pinned head position {x,y,z}
-- (metres, LOCAL), yaw = pinned head yaw; full = show the whole frame.
function BattleCards.commandPose(base, yaw, full, frameH)
  local p = full and BattleCards.FULL or BattleCards.COMMAND
  local b = base or { 0, 0, 0 }
  yaw = yaw or 0
  local s, c = math.sin(yaw), math.cos(yaw)
  frameH = frameH or 160
  local v0 = full and 0 or BattleCards.STRIP_Y / frameH
  local v1 = full and 1 or (BattleCards.STRIP_Y + BattleCards.STRIP_H) / frameH
  return {
    x = b[1] - s * p.dist, y = b[2] - p.drop, z = b[3] - c * p.dist,
    yaw = yaw, tilt = atan2(p.drop, p.dist), width = p.width,
    height = p.width * (full and (160 / 240) or (BattleCards.STRIP_H / 240)),
    v0 = v0, v1 = v1, full = full and true or false,
  }
end

-- ------------------------------------------------------------ canvases
function BattleCards.new(opts)
  opts = opts or {}
  return setmetatable({ battler = {}, trainer = {}, trainerDrawn = {}, hp = {}, ball = {}, band = {}, quads = {}, log = opts.log or print,
    hpStyle = opts.hpStyle or BattleCards.HP_STYLE }, BattleCards)
end

local function newCanvas(w, h)
  local ok, c = pcall(love.graphics.newCanvas, w, h, { dpiscale = 1 })
  if not ok or not c then return nil end
  c:setFilter("nearest", "nearest")
  return c
end

function BattleCards:battlerDims(id)
  local s = self.battlerSize and self.battlerSize[id]
  if s then return s[1], s[2] end
  return BattleCards.BATTLER_W, BattleCards.BATTLER_H
end

-- Grows battler canvas id to hold w x h (never shrinks it). Returns the size.
function BattleCards:growBattler(id, w, h)
  local cw, ch = self:battlerDims(id)
  if w <= cw and h <= ch then return cw, ch end
  cw, ch = math.max(cw, w), math.max(ch, h)
  self.battlerSize = self.battlerSize or {}
  self.battlerSize[id] = { cw, ch }
  local old = self.battler[id]
  if old and old.release then pcall(old.release, old) end
  self.battler[id] = nil
  return cw, ch
end

function BattleCards:canvas(kind, id, w, h)
  local t = self[kind]
  local c = t[id]
  if c and (kind == "battler" or kind == "trainer") and w and h then
    -- gen5 native-res: a battler canvas follows its picture's size (native pictures: always the default)
    local okD, cw, ch = pcall(c.getDimensions, c)
    if okD and (cw ~= w or ch ~= h) then pcall(c.release, c); t[id] = nil; c = nil end
  end
  if c then return c end
  if kind == "battler" or kind == "trainer" then
    c = newCanvas(w or BattleCards.BATTLER_W, h or BattleCards.BATTLER_H)
  elseif kind == "ball" then
    c = newCanvas(BattleCards.BALL_PX, BattleCards.BALL_PX)
  else
    c = newCanvas(BattleCards.HP_W, BattleCards.HP_H)
  end
  t[id] = c
  return c
end

local function trainerQuad(self, t)
  local key = tostring(t.imageW) .. "x" .. tostring(t.imageH) .. ":" .. tostring(t.quadFrame)
  local q = self.quads[key]
  if not q then
    q = love.graphics.newQuad(0, t.quadFrame * t.frameH, t.frameW, t.frameH, t.imageW, t.imageH)
    self.quads[key] = q
  end
  return q
end

-- Picture tints, written fresh from the engine's tint maths (battle/ui.lua,
-- ball_open.lua): 15-bit blend toward a colour, palette affine, mosaic and
-- greyscale. GLES: default precision untouched, highp per variable (memory:
-- LOVE GLES shader precision); checked by the ES gate.
BattleCards.TINT_SHADER = [[
uniform highp vec2 u_texSize;
uniform highp float u_block;
uniform mediump float u_mode;
uniform mediump vec4 u_blend;
uniform mediump vec4 u_affine;
vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc)
{
  highp vec2 uv = VaryingTexCoord.st;
  if (u_mode > 2.5 && u_mode < 3.5) {
    highp vec2 px = floor(uv * u_texSize / u_block) * u_block;
    uv = (px + vec2(0.5)) / u_texSize;
  }
  mediump vec4 c = Texel(tex, uv) * color;
  if (u_mode > 0.5 && u_mode < 1.5) {
    mediump vec3 c5 = floor(c.rgb * 31.0 + 0.5);
    mediump vec3 o = c5 + floor((u_blend.yzw - c5) * u_blend.x / 16.0);
    c.rgb = o / 31.0;
  } else if (u_mode > 1.5 && u_mode < 2.5) {
    c.rgb = clamp(c.rgb * u_affine.x + u_affine.yzw, 0.0, 1.0);
  } else if (u_mode > 3.5) {
    mediump vec3 g5 = floor(c.rgb * 31.0 + 0.5);
    mediump float gr = floor((g5.r + g5.g + g5.b) / 3.0);
    c.rgb = vec3(gr / 31.0);
  }
  return c;
}
]]
BattleCards.TINT_MODES = { blend = 1, affine = 2, mosaic = 3, gray = 4 }

local tintShader -- nil = untried, false = unavailable
local function tintShaderGet(log)
  if tintShader ~= nil then return tintShader or nil end
  local ok, sh = pcall(love.graphics.newShader, BattleCards.TINT_SHADER)
  tintShader = (ok and sh) or false
  if not tintShader and log then log("[FRLG_VOXEL] battle picture tints off: " .. tostring(sh)) end
  return tintShader or nil
end

local function send(sh, name, ...) pcall(sh.send, sh, name, ...) end

-- Sets the tint shader for `tint` (BattleSource:tintFor); true when set.
function BattleCards:setTint(image, tint)
  if type(tint) ~= "table" then return false end
  local mode = BattleCards.TINT_MODES[tint.mode]
  if not mode then return false end
  local sh = tintShaderGet(self.log)
  if not sh then return false end
  local iw, ih = image:getDimensions()
  send(sh, "u_mode", mode)
  send(sh, "u_texSize", { iw, ih })
  send(sh, "u_block", math.max(1, tonumber(tint.block) or 1))
  send(sh, "u_blend", { tonumber(tint.coeff) or 0, tonumber(tint.r) or 0, tonumber(tint.g) or 0, tonumber(tint.b) or 0 })
  send(sh, "u_affine", { tonumber(tint.m) or 1, tonumber(tint.r) or 0, tonumber(tint.g) or 0, tonumber(tint.b) or 0 })
  love.graphics.setShader(sh)
  self.tints = (self.tints or 0) + 1
  return true
end

local function rowQuad(self, iw, ih, r)
  local key = "row:" .. iw .. "x" .. ih .. ":" .. r
  local q = self.quads[key]
  if not q then
    q = love.graphics.newQuad(0, r, iw, 1, iw, ih)
    self.quads[key] = q
  end
  return q
end

-- Round 3 (P-B3): the stat-change overlay, written fresh from the engine's
-- maths (battle/ui.lua draw_stat_mask): the picture's opaque texels show the
-- 256 px mask pattern at their SCREEN position (origin + uv * size + scroll).
BattleCards.STAT_SHADER = [[
uniform Image u_mask;
uniform highp vec2 u_origin;
uniform highp vec2 u_size;
uniform highp vec2 u_scroll;
uniform mediump float u_flip;
uniform mediump float u_eva;
uniform mediump float u_darken;
vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc)
{
  highp vec2 uv = VaryingTexCoord.st;
  mediump vec4 m = Texel(tex, uv);
  if (m.a < 0.01) discard;
  highp vec2 t = uv;
  if (u_flip > 0.5) t.x = 1.0 - t.x;
  highp vec2 pos = floor(u_origin + t * u_size);
  mediump vec4 k = Texel(u_mask, (pos + u_scroll + vec2(0.5)) / 256.0);
  if (k.a < 0.01) discard;
  if (u_darken > 0.5) return vec4(0.0, 0.0, 0.0, u_eva);
  return vec4(k.rgb, u_eva);
}
]]

-- Round 3 (P-B3): full-screen move effects, per eye (BattlePass:postEye):
-- 1 invert, 2 fade to white, 3 fade to black / darken, 4 greyscale, 5 blend
-- toward a colour. The eye image is copied to a scratch canvas and drawn
-- back through this shader. highp UVs (large eye canvases), the TEX_HI
-- pattern of render/Shaders.lua for the sampler call.
BattleCards.SCREEN_SHADER = [[
#if defined(LOVE_GLSL1_ON_GLSL3) && __VERSION__ >= 130
#undef texture
#define TEX_HI(s, c) texture(s, c)
#else
#define TEX_HI(s, c) texture2D(s, c)
#endif
uniform mediump float u_type;
uniform mediump float u_coeff;
uniform mediump vec3 u_target;
vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc)
{
  highp vec2 uv = VaryingTexCoord.st;
  mediump vec4 c = TEX_HI(tex, uv);
  mediump vec3 o = c.rgb;
  if (u_type > 0.5 && u_type < 1.5) {
    o = mix(c.rgb, vec3(1.0) - c.rgb, u_coeff);
  } else if (u_type > 1.5 && u_type < 2.5) {
    o = mix(c.rgb, vec3(1.0), u_coeff);
  } else if (u_type > 2.5 && u_type < 3.5) {
    o = mix(c.rgb, vec3(0.0), u_coeff);
  } else if (u_type > 3.5 && u_type < 4.5) {
    mediump float l = dot(c.rgb, vec3(0.299, 0.587, 0.114));
    o = mix(c.rgb, vec3(l), u_coeff);
  } else if (u_type > 4.5) {
    o = mix(c.rgb, u_target, u_coeff);
  }
  return vec4(o, 1.0);
}
]]
BattleCards.SCREEN_TYPES = { invert = 1, fade_white = 2, fade_black = 3, darken = 3, grayscale = 4,
  custom_blend = 5 }

local extraShaders = {} -- name -> shader | false
local function extraShader(name, src, log)
  local s = extraShaders[name]
  if s ~= nil then return s or nil end
  local ok, sh = pcall(love.graphics.newShader, src)
  extraShaders[name] = (ok and sh) or false
  if not extraShaders[name] and log then log("[FRLG_VOXEL] battle " .. name .. " shader off: " .. tostring(sh)) end
  return extraShaders[name] or nil
end
BattleCards.extraShader = extraShader

-- The stat overlay over a picture already drawn at canvas (px, py). desc =
-- BattleSource:battlerDraw descriptor with .statMask.
function BattleCards:drawStatMask(desc, px, py)
  local sm = desc.statMask
  if not (sm and sm.image) then return false end
  local sh = extraShader("stat", BattleCards.STAT_SHADER, self.log)
  if not sh then return false end
  local g = love.graphics
  local img = desc.image
  local iw, ih = img:getDimensions()
  local sx, sy = desc.sx or 1, desc.sy or 1
  local asx, asy = math.abs(sx), math.abs(sy)
  send(sh, "u_mask", sm.image)
  local ox, oy = desc.originX or 32, desc.originY or 32 -- gen5 native-res: the picture's own draw origin
  send(sh, "u_origin", { (desc.cx or 0) - ox * asx, (desc.cy or 0) - oy * asy })
  send(sh, "u_size", { iw * asx, ih * asy })
  send(sh, "u_scroll", { sm.x or 0, sm.y or 0 })
  send(sh, "u_flip", sx < 0 and 1 or 0)
  local eva = sm.eva or 0
  local evb = sm.evb or (16 - eva)
  g.setShader(sh)
  g.setColor(1, 1, 1, 1)
  if eva + evb ~= 16 then
    send(sh, "u_darken", 1)
    send(sh, "u_eva", 1 - evb / 16)
    g.draw(img, px, py, 0, sx, sy, ox, oy)
    send(sh, "u_darken", 0)
    send(sh, "u_eva", eva / 16)
    g.setBlendMode("add", "alphamultiply")
    g.draw(img, px, py, 0, sx, sy, ox, oy)
    g.setBlendMode("alpha", "alphamultiply")
  else
    send(sh, "u_darken", 0)
    send(sh, "u_eva", math.min(1, eva / 16))
    g.draw(img, px, py, 0, sx, sy, ox, oy)
  end
  g.setShader()
  self.statMasks = (self.statMasks or 0) + 1
  return true
end

-- The move background canvas (240x160). Inside a push("all") guard.
function BattleCards:renderBackground(source)
  local c = self.bg
  if not c then
    c = newCanvas(240, 160)
    self.bg = c
  end
  if not c then return nil end
  local g = love.graphics
  g.setCanvas(c)
  g.origin()
  g.setScissor()
  g.setShader()
  g.setBlendMode("alpha")
  g.clear(0, 0, 0, 0)
  g.setColor(1, 1, 1, 1)
  source:drawBackground()
  g.setShader()
  g.setColor(1, 1, 1, 1)
  return c
end

-- Pure: the move-background curtain behind the foe, facing the eye: centre
-- CURTAIN_BACK cells behind the foe on the eye's line, wide enough to fill
-- CURTAIN_HALF_DEG each side, standing CURTAIN_SINK cells below the foe's
-- ground. Returns an upright card { x, z, base, w, h, dx, dz }.
BattleCards.BACKGROUND_STYLE = "curtain" -- "curtain" | "off"
BattleCards.CURTAIN_BACK = 3
BattleCards.CURTAIN_HALF_DEG = 55
BattleCards.CURTAIN_SINK = 1.0
function BattleCards.curtain(stage, eye)
  local f = stage.foe
  local dx, dz = f.x - eye.x, f.z - eye.z
  local l = sqrt(dx * dx + dz * dz)
  if l < 1e-6 then dx, dz, l = 0, -1, 1 end
  dx, dz = dx / l, dz / l
  local cx, cz = f.x + dx * BattleCards.CURTAIN_BACK, f.z + dz * BattleCards.CURTAIN_BACK
  local dist = l + BattleCards.CURTAIN_BACK
  local w = 2 * dist * math.tan(math.rad(BattleCards.CURTAIN_HALF_DEG))
  local h = w * 160 / 240
  return { kind = "curtain", id = -3, x = cx, z = cz, base = (f.ground or 0) - BattleCards.CURTAIN_SINK,
    w = w, h = h, dx = -dx, dz = -dz, dist = dist }
end

-- Draws one battler card canvas: trainer pictures (behind), then the
-- Pokemon. desc may be nil (nothing to show). base = the slot's pret base
-- point {x, y} for trainers. Called inside a push("all")/pcall guard.
function BattleCards:renderBattler(id, side, desc, trainers, base, trainerOx)
  -- gen5 native-res: the canvas fits the picture (native: the default BATTLER_W x BATTLER_H)
  local cw, ch = self:growBattler(id, BattleCards.battlerCanvasSize(desc and desc.imported and desc.image and desc or nil))
  if desc then desc.cw, desc.ch = cw, ch end
  self.battlerSize = self.battlerSize or {}
  self.battlerSize[id] = { cw, ch }
  local c = self:canvas("battler", id, cw, ch)
  if not c then return false end
  local g = love.graphics
  g.setCanvas(c)
  g.origin()
  g.setScissor()
  g.setShader()
  g.setBlendMode("alpha")
  g.clear(0, 0, 0, 0)
  local drew = false
  -- pan-in fix: trainer pictures slide in on their own offset, so they get their own card (canvas)
  local tc = BattleCards.PAN_WORLD and trainers and #trainers > 0 and self:canvas("trainer", id, cw, ch) or nil
  self.trainerDrawn = self.trainerDrawn or {}
  self.trainerDrawn[id] = tc ~= nil
  if tc then
    g.setCanvas(tc)
    g.clear(0, 0, 0, 0)
  end
  for _, t in ipairs(trainers or {}) do
    local px, py = BattleCards.trainerCanvasPos(side, t.x, t.y, base, cw, ch, trainerOx)
    g.setColor(1, 1, 1, 1)
    if t.quadFrame then
      g.draw(t.image, trainerQuad(self, t), px, py, 0, 1, 1, 32, 32)
    else
      g.draw(t.image, px, py, 0, 1, 1, 32, 32)
    end
    drew = true
  end
  if tc then g.setCanvas(c) end
  if desc and desc.image then
    local px, py = BattleCards.canvasPos(desc)
    -- Alpha (fades, the flash blink) is applied when the card is drawn
    -- (BattleCards.cardAlpha), not baked in: a canvas drawn with alpha
    -- blending would hold it premultiplied and darken the colours.
    if (desc.flash or 0) > 0 then
      g.setColor(1, 1, 1, 1)
    else
      local s = desc.shade or 1
      g.setColor(s, s, s, 1)
    end
    local tinted = self:setTint(desc.image, desc.tint)
    local ox, oy = desc.originX or 32, desc.originY or 32 -- gen5 native-res: the picture's own draw origin
    if type(desc.hShift) == "table" then
      -- the row wobble (hShift, screen rows): one image row per draw, like
      -- ui.lua's draw_mon_sprite
      local img = desc.image
      local iw, ih = img:getDimensions()
      local top = desc.hTop or math.floor(desc.cy - oy + 0.5)
      local rowY = py - oy
      for r = 0, ih - 1 do
        local dx = tonumber(desc.hShift[top + r]) or 0
        g.draw(img, rowQuad(self, iw, ih, r), px + dx, rowY + r, 0, desc.sx or 1, 1, ox, 0)
      end
    else
      g.draw(desc.image, px, py, desc.rot or 0, desc.sx or 1, desc.sy or 1, ox, oy)
    end
    if tinted then g.setShader() end
    if desc.statMask and (desc.rot or 0) == 0 then self:drawStatMask(desc, px, py) end
    drew = true
  end
  g.setColor(1, 1, 1, 1)
  return drew
end

-- Draws the three effect band canvases (source = BattleSource). Called
-- inside a push("all") guard, once per frame while effects are live.
-- battle-ui (2026-10-01): noBallOpen = the user's own catch presentation is running, so the engine's ball-open
-- burst / capture stars (BallOpen.draw, front band) are left out; move effects still draw.
function BattleCards:renderBands(source, noBallOpen)
  local g = love.graphics
  local P = BattleCards.BAND_PAD
  local n = 0
  for k = 0, 2 do
    local c = self.band[k]
    if not c then
      c = newCanvas(240 + 2 * P, 160 + 2 * P)
      self.band[k] = c
    end
    if c then
      g.setCanvas(c)
      g.origin()
      g.setScissor()
      g.setShader()
      g.setBlendMode("alpha")
      g.clear(0, 0, 0, 0)
      g.setColor(1, 1, 1, 1)
      g.translate(P, P)
      local b = BattleCards.BANDS[k]
      source:drawBand(b[1], b[2], k == 2 and not noBallOpen)
      g.origin()
      g.setShader()
      g.setBlendMode("alpha")
      g.setColor(1, 1, 1, 1)
      n = n + 1
    end
  end
  return n
end

-- Draws one ball canvas (BattleSource:ballDraw descriptor): the engine's own
-- ball sheet quad, rotated like the shakes. Returns the card alpha.
function BattleCards:renderBall(i, b)
  local c = self:canvas("ball", i)
  if not c then return nil end
  local g = love.graphics
  g.setCanvas(c)
  g.origin()
  g.setScissor()
  g.setShader()
  g.setBlendMode("alpha")
  g.clear(0, 0, 0, 0)
  if (b.flash or 0) > 0 and (b.flash % 2 == 0) then
    g.setColor(1, 1, 1, 1)
  else
    local s = math.max(0, math.min(1, 1 - (b.darken or 0) * (1 - 8 / 255)))
    g.setColor(s, s, s, 1)
  end
  local half = BattleCards.BALL_PX / 2
  g.draw(b.image, b.quad, half, half, b.rot or 0, 1, 1, 8, 8)
  g.setColor(1, 1, 1, 1)
  return tonumber(b.alpha) or 1
end

-- HP bar only (user question 3 "bar"): green/yellow/red on a dark frame.
local function drawBar(slot)
  local g = love.graphics
  local hp = tonumber(slot.displayHp) or 0
  local max = math.max(1, tonumber(slot.displayMaxHp) or 1)
  local f = math.max(0, math.min(1, hp / max))
  local w, y = 96, 20
  local x = (BattleCards.HP_W - w) / 2
  g.setColor(0.16, 0.18, 0.16, 1)
  g.rectangle("fill", x - 2, y - 2, w + 4, 12)
  if f > 0.5 then g.setColor(0.44, 0.97, 0.66, 1)
  elseif f > 0.2 then g.setColor(0.97, 0.88, 0.22, 1)
  else g.setColor(0.97, 0.35, 0.22, 1) end
  g.rectangle("fill", x, y, math.floor(w * f + 0.5), 8)
end

-- Draws one HP card canvas. source = BattleSource; slot = BattleSource:slot.
function BattleCards:renderHp(id, source, slot, st)
  local c = self:canvas("hp", id)
  if not c then return false end
  local g = love.graphics
  g.setCanvas(c)
  g.origin()
  g.setScissor()
  g.setShader()
  g.setBlendMode("alpha")
  g.clear(0, 0, 0, 0)
  g.setColor(1, 1, 1, 1)
  local drew = false
  if self.hpStyle == "bar" then
    drawBar(slot)
    drew = true
  else
    local tlx, tly = source:healthboxTopLeft(id, st)
    g.push()
    g.translate(BattleCards.HP_PAD_X - tlx, BattleCards.HP_PAD_Y - tly)
    drew = source:drawHealthbox(id, st)
    g.pop()
  end
  g.setColor(1, 1, 1, 1)
  return drew
end

function BattleCards:release()
  if self.bg and self.bg.release then pcall(self.bg.release, self.bg) end
  self.bg = nil
  if self.scratch and self.scratch.release then pcall(self.scratch.release, self.scratch) end
  self.scratch = nil
  for _, kind in ipairs({ "battler", "trainer", "hp", "ball", "band" }) do
    for k, c in pairs(self[kind]) do
      if c.release then pcall(c.release, c) end
      self[kind][k] = nil
    end
  end
  self.battlerSize = nil
  self.quads = {}
end

return BattleCards
