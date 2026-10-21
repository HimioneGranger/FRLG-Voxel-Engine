-- FRLG_VOXEL (battle-move, user request 2026-10-01: "I want movement in battle now."): the player's
-- visual movement inside a 3D battle.
--
-- A battle pins the camera to a "seat" (BattlePass:pin; Camera.seat = anchor + yaw + the LOCAL head
-- position pinned to it). This module moves that seat, and only that:
--   * stick walking (look-relative, at the VR CONTROLS walk speed), turning (SNAP / SMOOTH per VR
--     CONTROLS) and room-scale walking (the head moving inside the playspace already moves the eye,
--     because the rig is pinned to the head's LOCAL position; this module only keeps it in bounds);
--   * nothing here writes game state: the trainer's map position, steps, encounters and warps are not
--     touched, and the field camera (snapYaw, follow) is never changed. The turn accumulated here
--     lives in this object and is thrown away with the seat.
-- The area is a disc of RADIUS cells around the seat, minus a BATTLER_KEEPOUT disc around every battler
-- card, minus cells the world says are not standable (walls, trees, water, ledges) when a cell test
-- is given. Walking stops at an edge (sliding along it); a head pushed past an edge in the room is
-- pulled back and dims the view like the wall dim of room-scale walking.
--
-- Pure Lua (no love, no engine): the caller (BattlePass) hands in everything per frame.
-- Units: world = root map cells, X east, Z south; LOCAL = metres. Rig maths as Camera.lua:
--   eye(horizontal) = anchor + R(yaw) * (head - pivot) / m, R(yaw)(x, z) = (cos x + sin z, -sin x + cos z).
local BattleMove = {}
BattleMove.__index = BattleMove

BattleMove.RADIUS = 3.0            -- cells: the battle area around the seat
BattleMove.BATTLER_KEEPOUT = 1.0   -- cells: closest the eye may get to a battler card's centre
BattleMove.BODY_R = 0.25           -- cells: body radius for the wall/ground test
BattleMove.SEAT_OK = 1.0           -- cells around the seat that always count as standable (the seat
                                   -- itself is often just off the staged patch)
BattleMove.STICK_DEAD = 0.2        -- stick dead zone (InputMap / FreeMove.DEAD)
BattleMove.WALK_PX = 1.0           -- px per 60 Hz tick at 100% (FreeMove.WALK)
BattleMove.TICK_HZ = 60
BattleMove.CELL_PX = 16
BattleMove.METRES_PER_CELL = 1.6
BattleMove.GROUND_MAX = 0.6        -- cells: most the eye rises/falls with the ground vs the seat
BattleMove.GROUND_EASE = 8         -- 1/s
BattleMove.DIM_GAIN = 3            -- dim level per metre of head pushed past an edge
BattleMove.DIM_MAX = 0.6
BattleMove.DIM_TAU = 0.35          -- s
BattleMove.MAX_DT = 0.1

local sqrt, sin, cos, atan2, abs, exp, floor = math.sqrt, math.sin, math.cos, math.atan2, math.abs, math.exp, math.floor

local function wrapPi(a) return (a + math.pi) % (2 * math.pi) - math.pi end
BattleMove.wrapPi = wrapPi

-- Cells per second at a walk-speed percentage (100 = the game's own pace, 6 m/s at this scale).
function BattleMove.speed(pct)
  pct = tonumber(pct) or 75
  return BattleMove.WALK_PX * (pct / 100) * BattleMove.TICK_HZ / BattleMove.CELL_PX
end

function BattleMove.new(opts)
  opts = opts or {}
  local self = setmetatable({ log = opts.log or function() end }, BattleMove)
  self.enabled = opts.enabled ~= false
  self:reset()
  return self
end

function BattleMove:reset()
  self.base = nil          -- the seat as BattlePass pinned it { x, y, z, yaw, focusDist }
  self.centre = nil        -- { x, z } disc centre (the pinned seat)
  self.prev = nil          -- last resolved eye { x, z }
  self.eye = nil           -- this frame's resolved eye { x, z, y } (world cells), nil when idle
  self.dyaw = 0            -- total turn since the pin (radians)
  self.pendingTurn = 0
  self.stickX, self.stickY = 0, 0
  self.dy, self.g0 = 0, nil
  self.dim = 0
  self.lastBlock = nil
  self.stats = { frames = 0, walked = 0, radiusHits = 0, keepoutHits = 0, wallHits = 0, turns = 0 }
end

function BattleMove:setEnabled(on)
  self.enabled = on ~= false
  self.pendingTurn, self.stickX, self.stickY = 0, 0, 0 -- nothing stale survives a toggle
end

-- Called when the seat is (re)pinned: remember it as the origin. seat = Camera.seat table.
function BattleMove:begin(seat)
  self:reset()
  if type(seat) ~= "table" then return end
  self.base = { x = seat.x, y = seat.y, z = seat.z, yaw = seat.yaw, focusDist = seat.focusDist }
  self.centre = { x = seat.x, z = seat.z }
  self.prev = { x = seat.x, z = seat.z }
end

-- Put the seat back exactly where it was pinned (option switched off mid-battle, or a release).
function BattleMove:restore(seat)
  local b = self.base
  if b and type(seat) == "table" then
    seat.x, seat.y, seat.z, seat.yaw, seat.focusDist = b.x, b.y, b.z, b.yaw, b.focusDist
  end
  self.eye = nil
  self.dyaw, self.pendingTurn, self.dy, self.dim = 0, 0, 0, 0
  self.stickX, self.stickY = 0, 0
  if b then self.prev = { x = b.x, z = b.z } end
end

-- The left stick (raw -1..1, up = forward). Zero it when walking is not wanted this frame.
function BattleMove:setStick(sx, sy)
  self.stickX, self.stickY = tonumber(sx) or 0, tonumber(sy) or 0
end

-- The right stick, once per frame, in Camera:turnInput's terms: actions = { snap = +1|-1, turn = -1..1 };
-- style "smooth" | other (snap); speedDeg = smooth degrees/second; snapRad = one snap in radians.
function BattleMove:turnInput(actions, dt, style, speedDeg, snapRad)
  if type(actions) ~= "table" then return end
  if style == "smooth" then
    local t = tonumber(actions.turn) or 0
    if t ~= 0 then
      t = math.max(-1, math.min(1, t))
      dt = math.max(0, math.min(tonumber(dt) or 0, BattleMove.MAX_DT))
      self.pendingTurn = self.pendingTurn - t * math.rad(tonumber(speedDeg) or 90) * dt
    end
  elseif actions.snap then
    local a = tonumber(snapRad) or math.rad(30)
    self.pendingTurn = self.pendingTurn + (actions.snap > 0 and -a or a)
    self.stats.turns = self.stats.turns + 1
  end
end

local function rot(yaw, x, z)
  local c, s = cos(yaw), sin(yaw)
  return c * x + s * z, -s * x + c * z
end
BattleMove.rot = rot

-- One standable test with the body radius: all four corners.
local function bodyOk(self, cellOk, x, z)
  if not cellOk then return true end
  local c = self.centre
  local r = BattleMove.BODY_R
  local bubble = BattleMove.SEAT_OK
  for _, o in ipairs({ { -r, -r }, { r, -r }, { -r, r }, { r, r } }) do
    local px, pz = x + o[1], z + o[2]
    local dx, dz = px - c.x, pz - c.z
    if dx * dx + dz * dz > bubble * bubble and not cellOk(floor(px), floor(pz)) then return false end
  end
  return true
end

-- Disc and keep-out constraints on a point; returns x, z, which ("radius" | "keepout" | nil).
local function constrain(self, x, z, slots)
  local c = self.centre
  local why
  local K = BattleMove.BATTLER_KEEPOUT
  for _ = 1, 3 do
    local moved = false
    for _, s in ipairs(slots or {}) do
      local dx, dz = x - s.x, z - s.z
      local d = sqrt(dx * dx + dz * dz)
      local k = math.max(K, (tonumber(s.w) or 0) * 0.5 + 0.4) -- a wider card (Gen 5 art) keeps you further off
      if d < k then
        if d < 1e-6 then dx, dz, d = c.x - s.x, c.z - s.z, sqrt((c.x - s.x) ^ 2 + (c.z - s.z) ^ 2) end
        if d < 1e-6 then dx, dz, d = 0, 1, 1 end
        x, z = s.x + dx / d * k, s.z + dz / d * k
        moved, why = true, why or "keepout"
      end
    end
    local R = BattleMove.RADIUS
    local ex, ez = x - c.x, z - c.z
    local ed = sqrt(ex * ex + ez * ez)
    if ed > R then
      x, z = c.x + ex / ed * R, c.z + ez / ed * R
      moved, why = true, why or "radius"
    end
    if not moved then break end
  end
  return x, z, why
end
BattleMove.constrain = function(centre, x, z, slots) return constrain({ centre = centre }, x, z, slots) end

-- ctx = { seat = Camera.seat table (this module writes x, y, z, yaw, focusDist),
--         dt, head = { x, z } LOCAL metres (nil: the pinned point), headYaw (radians; 0 when unknown),
--         walkPct (VR CONTROLS walk speed), slots = { { x, z }, ... } battler centres (world cells),
--         cellOk(cx, cz) -> bool (integer cells; nil = no ground test), heightAt(x, z) -> cells | nil,
--         focus = { x, y, z } (for fog), lookYawFromHead = true }
-- Returns the eye { x, z, y } or nil when nothing was done.
function BattleMove:frame(ctx)
  local seat, b = ctx and ctx.seat, self.base
  if not (self.enabled and seat and b and self.centre) then self.eye = nil; return nil end
  local m = BattleMove.METRES_PER_CELL
  local dt = math.max(0, math.min(tonumber(ctx.dt) or 0, BattleMove.MAX_DT))
  local px, pz = tonumber(seat.px) or 0, tonumber(seat.pz) or 0
  local hx = ctx.head and tonumber(ctx.head[1]) or px
  local hz = ctx.head and tonumber(ctx.head[2]) or pz
  local relx, relz = (hx - px) / m, (hz - pz) / m
  local yaw0 = seat.yaw
  -- the eye now: the seat anchor carried by the head's room motion since the pin
  local ex, ez = rot(yaw0, relx, relz)
  local E = { x = seat.x + ex, z = seat.z + ez }
  local physDx, physDz = E.x - (self.prev and self.prev.x or E.x), E.z - (self.prev and self.prev.z or E.z)
  -- turn about the head: the eye stays, the world swings around it
  local yaw1 = yaw0
  if self.pendingTurn ~= 0 then
    yaw1 = wrapPi(yaw0 + self.pendingTurn)
    self.dyaw = wrapPi(self.dyaw + self.pendingTurn)
    self.pendingTurn = 0
    local nx, nz = rot(yaw1, relx, relz)
    seat.x, seat.z = E.x - nx, E.z - nz
    seat.yaw = yaw1
  end
  -- the stick
  local sx, sy = self.stickX, self.stickY
  local mag = sqrt(sx * sx + sy * sy)
  local dead = BattleMove.STICK_DEAD
  local target = { x = E.x, z = E.z }
  local walking = false
  if mag > dead then
    local k = math.min(1, (mag - dead) / (1 - dead))
    local look = wrapPi(yaw1 + (tonumber(ctx.headYaw) or 0))
    local ang = look + atan2(-sx, sy)
    local step = BattleMove.speed(ctx.walkPct) * k * dt
    target.x = E.x - sin(ang) * step
    target.z = E.z - cos(ang) * step
    walking = step > 0
  end
  -- resolve from the last valid spot: ground first (per axis, so a wall slides), then disc / keep-out
  local prev = self.prev or E
  local cellOk = ctx.cellOk
  local x, z = prev.x, prev.z
  local why
  if bodyOk(self, cellOk, target.x, z) then x = target.x else why = "wall" end
  if bodyOk(self, cellOk, x, target.z) then z = target.z else why = "wall" end
  local cx, cz, w2 = constrain(self, x, z, ctx.slots)
  if w2 then why = why or w2 end
  if (cx ~= x or cz ~= z) and not bodyOk(self, cellOk, cx, cz) then cx, cz = prev.x, prev.z end
  x, z = cx, cz
  if why then
    local s = self.stats
    if why == "wall" then s.wallHits = s.wallHits + 1
    elseif why == "radius" then s.radiusHits = s.radiusHits + 1
    else s.keepoutHits = s.keepoutHits + 1 end
    self.lastBlock = why
  end
  -- the anchor carries the eye from where it is (E) to where it may be (x, z): the walk step,
  -- minus whatever an edge refused; physical pushes past an edge dim the view
  local cdx, cdz = x - target.x, z - target.z
  seat.x, seat.z = seat.x + (x - E.x), seat.z + (z - E.z)
  local drop = sqrt(cdx * cdx + cdz * cdz)
  if not walking and drop > 1e-6 and (abs(physDx) + abs(physDz)) > 1e-6 then
    self.dim = math.min(BattleMove.DIM_MAX, self.dim + drop * m * BattleMove.DIM_GAIN)
  end
  if self.dim > 0 then
    self.dim = self.dim * exp(-dt / BattleMove.DIM_TAU)
    if self.dim < 0.01 then self.dim = 0 end
  end
  self.prev = { x = x, z = z }
  if walking then self.stats.walked = self.stats.walked + sqrt((x - E.x) ^ 2 + (z - E.z) ^ 2) end
  -- ground: the eye rides the terrain (eased, capped)
  if ctx.heightAt then
    local okG, gy = pcall(ctx.heightAt, x, z)
    if okG and type(gy) == "number" then
      if self.g0 == nil then
        local ok0, g0 = pcall(ctx.heightAt, self.centre.x, self.centre.z)
        self.g0 = (ok0 and type(g0) == "number") and g0 or gy
      end
      local want = math.max(-BattleMove.GROUND_MAX, math.min(BattleMove.GROUND_MAX, gy - self.g0))
      self.dy = self.dy + (want - self.dy) * (1 - exp(-dt * BattleMove.GROUND_EASE))
    end
  end
  seat.y = b.y + self.dy
  -- fog placement follows the real eye-to-focus distance
  local f = ctx.focus
  if f then
    local fx, fz = x - f.x, z - f.z
    local fy = seat.y - (f.y or seat.y)
    seat.focusDist = sqrt(fx * fx + fz * fz + fy * fy) * m
  end
  self.eye = { x = x, z = z, y = seat.y }
  self.stats.frames = self.stats.frames + 1
  return self.eye
end

function BattleMove:status()
  local b, e = self.base, self.eye
  return {
    enabled = self.enabled, active = e ~= nil, yaw = self.dyaw,
    eye = e and { x = e.x, y = e.y, z = e.z } or nil,
    fromSeat = (e and b) and sqrt((e.x - b.x) ^ 2 + (e.z - b.z) ^ 2) or nil,
    dim = self.dim, lastBlock = self.lastBlock,
    frames = self.stats.frames, walked = self.stats.walked, turns = self.stats.turns,
    radiusHits = self.stats.radiusHits, keepoutHits = self.stats.keepoutHits, wallHits = self.stats.wallHits,
  }
end

return BattleMove
