-- FRLG_VOXEL: camera rig. Follows the game3 player with smoothed position,
-- height and yaw, and turns an OpenXR eye (LOCAL-space pose + fov) or the
-- desktop mono view into a view-projection over the voxel world.
--
-- Units: world = ROOT map cells (X east, Z south, Y up in mesher units).
-- OpenXR LOCAL space: metres, +Y up, -Z = where the head faced at session
-- start. Every mode is one rig:
--   worldFromLocal(L) = anchor + Ry(yaw) * (L - pivot) / m
-- anchor = a world point, pivot = the LOCAL point pinned to it, m = metres per
-- cell. An eye's view = R^T * T(-pose.pos) * [Rx(-pitch)] * T(pivot) * S(m) *
-- Ry(-yaw) * T(-anchor), which ends in METRES so near/far stay sane.
--
-- Modes:
--   first     eye at the trainer, 1 cell = 1.6 m (the Gen2 first-person scale
--             the user tested), eye 0.95 cells (~1.5 m) above the ground.
--   third     raised camera 3.4 cells behind / 3.0 above, same scale.
--   overview  "3/4 view" like the original screen: north-up, ~50 degrees
--             down. Desktop: a mono camera 12 cells out along that line.
--             Quest (seated diorama): the town as a table-top model at
--             0.1 m per cell, the trainer pinned 0.75 m ahead / 0.75 m below
--             the resting head, so looking at the trainer is looking ~45 deg
--             down; head motion is free, the world never tilts, and it stays
--             north-up (the right stick does not rotate it).
-- Room-scale walking (teams/locomotion, Lab 7): in first person the pivot is
-- the HEAD's horizontal LOCAL position (so the eye sits at the trainer and a
-- turn swings the world around the head, not around the playspace centre) and
-- the anchor carries the small offset the trainer still owes the head:
--   room = { px, pz (LOCAL metres), wx, wz (world cells) }   see setRoom
-- Battle seat (W6, battle P-B1): while `camera.seat` is set (by
-- battle/BattlePass.lua) the rig is pinned there in every mode, life size:
--   seat = { x, y, z (world cells, the eye), yaw, px, py, pz (the LOCAL
--            head position pinned to it), pitch (desktop mono), focusDist (m) }
-- update() stops following the trainer; clearing the seat plus reset()
-- snaps back to the trainer on the next update.
local V = ...
local Mat4 = V.require("render/Mat4")

local Camera = {}
Camera.__index = Camera

Camera.METRES_PER_CELL = 1.6
Camera.EYE_HEIGHT = 0.95        -- cells above ground (first person)
Camera.THIRD_BACK = 3.4         -- cells south of the player (third person)
Camera.THIRD_UP = 3.0           -- cells above the player's ground
-- 3/4 view angle and zoom are player options (VOXEL 3/4 ANGLE / ZOOM; the
-- idea follows the Emerald 3DS port's 3D ANGLE / 3D ZOOM settings). Angle =
-- how far the view looks down; zoom = 100 / distance factor (130% is 30%
-- closer to the model than 100%, 80% farther).
Camera.ANGLE_MIN, Camera.ANGLE_MAX, Camera.ANGLE_DEFAULT = 35, 55, 45   -- degrees
Camera.ZOOM_MIN, Camera.ZOOM_MAX, Camera.ZOOM_DEFAULT = 80, 130, 100    -- percent
Camera.OVERVIEW_PITCH = math.rad(Camera.ANGLE_DEFAULT)   -- default look-down angle
Camera.OVERVIEW_DIST = 14       -- cells from the trainer at 100% (desktop 3/4)
Camera.OVERVIEW_FOV = math.rad(40)
Camera.DIORAMA_M = 0.10         -- metres per cell at 100% (Quest 3/4 diorama)
-- LOCAL metres (ahead, below the head) at the default 45 degrees: the model
-- sits DIORAMA_DIST from the head along the chosen angle
Camera.DIORAMA_PIVOT = { 0, -0.75, -0.75 }
Camera.DIORAMA_DIST = math.sqrt(0.75 * 0.75 + 0.75 * 0.75)
Camera.DIORAMA_FAR_CELLS = 48   -- table-top cull radius around the trainer
Camera.NEAR = 0.05              -- metres
-- worker "atmos" (GW-P2, DESIGN.md 4.5): FAR is the projection far plane
-- only, raised so TWS's sky pieces are not clipped. CULL_FAR is the
-- unchanged old value: the chunk build/draw cull radius (View.lua) stays
-- 150 m so raising FAR does not 6.6x the terrain built and drawn.
Camera.FAR = 400                -- metres (projection only)
Camera.CULL_FAR = 150           -- metres (cull radius; the pre-GW-P2 FAR)
-- 90 degrees: movement is 4-way, so a 45-degree snap left "forward" exactly
-- on the boundary between two grid directions (review item 5). Lab 8: the
-- legacy/fallback snap; the player now picks the turn (VOXEL TURN MODE):
-- SMOOTH turns while the right stick is held, at VOXEL TURN SPEED degrees per
-- second at full tilt; SNAP turns once per flick by VOXEL SNAP ANGLE (see
-- below for the Lab 7 default). With free walking a 45-degree forward is a
-- real direction, not a grid boundary.
Camera.SNAP = math.pi / 2
-- Lab 7 (user answer 2026-10-01): the default turn is SNAP 30 degrees, with both
-- adjusters: VOXEL TURN MODE (snap | smooth), VOXEL SNAP ANGLE (15-90, steps of
-- 15) and VOXEL TURN SPEED (smooth). "snap" turns by Camera.snapDeg; snap30 /
-- snap45 / snap90 are the old fixed styles, still accepted (saved options).
Camera.TURN_STYLES = { smooth = 0, snap = math.rad(30), snap30 = math.rad(30), snap45 = math.rad(45), snap90 = math.rad(90) }
Camera.TURN_DEFAULT = "snap"
Camera.SNAP_DEG_MIN, Camera.SNAP_DEG_MAX, Camera.SNAP_DEG_DEFAULT = 15, 90, 30
Camera.TURN_SPEED_DEFAULT = 90   -- degrees per second at full stick
Camera.TURN_SPEED_MIN, Camera.TURN_SPEED_MAX = 30, 180

local FACING_YAW = { up = 0, right = -math.pi / 2, down = math.pi, left = math.pi / 2 }
Camera.FACING_YAW = FACING_YAW
Camera.MODES = { "first", "third", "overview" }

local function wrapPi(a)
  return (a + math.pi) % (2 * math.pi) - math.pi
end
Camera.wrapPi = wrapPi

function Camera.new(opts)
  opts = opts or {}
  return setmetatable({
    mode = opts.mode or "first",     -- "first" | "third" | "overview"
    follow = opts.follow ~= false,   -- world yaw follows the game facing
    vr = opts.vr == true,            -- rig for a headset (diorama overview)
    x = nil, y = nil, z = nil, yaw = 0,
    snapYaw = 0,
    angle = Camera.ANGLE_DEFAULT, zoom = Camera.ZOOM_DEFAULT,
    turnStyle = Camera.TURN_DEFAULT, turnSpeed = Camera.TURN_SPEED_DEFAULT,
    snapDeg = Camera.SNAP_DEG_DEFAULT,
  }, Camera):setOverview(opts.angle, opts.zoom):setTurn(opts.turnStyle, opts.turnSpeed, opts.snapDeg)
end

local function clampNum(v, lo, hi, def)
  v = tonumber(v)
  if v == nil or v ~= v then return def end
  return math.max(lo, math.min(hi, v))
end

-- 3/4 view angle (degrees) and zoom (percent); nil keeps the current value.
-- Returns self.
function Camera:setOverview(angle, zoom)
  if angle ~= nil then self.angle = clampNum(angle, Camera.ANGLE_MIN, Camera.ANGLE_MAX, Camera.ANGLE_DEFAULT) end
  if zoom ~= nil then self.zoom = clampNum(zoom, Camera.ZOOM_MIN, Camera.ZOOM_MAX, Camera.ZOOM_DEFAULT) end
  return self
end

function Camera:overviewPitch()
  return math.rad(self.angle or Camera.ANGLE_DEFAULT)
end

-- Desktop: cells from the trainer; the zoom brings the eye closer.
function Camera:overviewDist()
  return Camera.OVERVIEW_DIST * 100 / (self.zoom or Camera.ZOOM_DEFAULT)
end

-- Quest diorama: the model's pivot (LOCAL metres) along the chosen angle and
-- its scale (metres per cell) from the zoom.
function Camera:dioramaPivot()
  local a, d = self:overviewPitch(), Camera.DIORAMA_DIST
  return 0, -d * math.sin(a), -d * math.cos(a)
end

function Camera:dioramaScale()
  return Camera.DIORAMA_M * (self.zoom or Camera.ZOOM_DEFAULT) / 100
end

-- Room-scale walking (FreeMove.roomFrame): nil = the old rig (pivot at the
-- LOCAL origin). First person only; a battle seat or any other mode ignores it.
-- Returns self.
function Camera:setRoom(room)
  self.room = room
  return self
end

-- Yaw this frame's update() will settle on while the world does NOT follow the
-- trainer's facing (free walking, always on the headset): the player's own
-- snap/smooth turn. FreeMove.roomFrame runs before update() and needs it to
-- rotate the head's move into the world.
function Camera:turnYaw()
  return self.snapYaw
end

function Camera:reset()
  self.x, self.y, self.z = nil, nil, nil
  self.lastTx, self.lastTz = nil, nil
end

function Camera:setMode(mode)
  if mode ~= "third" and mode ~= "overview" then mode = "first" end
  self.mode = mode
  self:reset()
  -- the 3/4 view / table-top model is always north-up (review item 4)
  if mode == "overview" then self.yaw = 0 end
end

-- Sprite cards: a 32 px trainer frame is 2 cells tall in the GBA art, but the
-- art itself spans rows 11-30 (47 of the 16x32 FireRed sheets; 22 more start
-- at row 12). Tour review R1: in first person an adult's visible art is
-- ~1.05 cells (1.68 m), head just above the 0.95-cell eye:
-- 1.05 * 16 / 20 px = 0.84 per GBA pixel-cell. One scale for every sheet,
-- so children and Pokemon keep their measured size relative to adults
-- (Billboards also stands each sheet's lowest art row on the ground). The
-- raised cameras keep the original screen's proportions.
Camera.ADULT_ART_PX = 20
Camera.ADULT_ART_CELLS = 1.05
Camera.CARD_SCALE = {
  first = Camera.ADULT_ART_CELLS * 16 / Camera.ADULT_ART_PX, third = 0.8, overview = 1.0,
}
function Camera:cardScale()
  return Camera.CARD_SCALE[self.mode] or 1.0
end

function Camera:nextMode()
  local i = 1
  for k, m in ipairs(Camera.MODES) do if m == self.mode then i = k end end
  self:setMode(Camera.MODES[i % #Camera.MODES + 1])
end

-- A seamless connection re-rooted the world: the old root now sits at
-- (dx, dz) in the new root's frame.
function Camera:shift(dx, dz)
  if self.x then
    self.x = self.x + (dx or 0)
    self.z = self.z + (dz or 0)
  end
  if self.lastTx then
    self.lastTx = self.lastTx + (dx or 0)
    self.lastTz = self.lastTz + (dz or 0)
  end
end

-- Lab 8 + Lab 7: turn style ("smooth" | "snap" | the old "snap30" | "snap45" |
-- "snap90"), smooth speed (degrees/second) and the snap angle (degrees, 15-90);
-- nil keeps the current value. Returns self.
function Camera:setTurn(style, speed, snapDeg)
  if style ~= nil then
    self.turnStyle = Camera.TURN_STYLES[style] and style or Camera.TURN_DEFAULT
  end
  if speed ~= nil then
    self.turnSpeed = clampNum(speed, Camera.TURN_SPEED_MIN, Camera.TURN_SPEED_MAX,
      Camera.TURN_SPEED_DEFAULT)
  end
  if snapDeg ~= nil then
    self.snapDeg = clampNum(snapDeg, Camera.SNAP_DEG_MIN, Camera.SNAP_DEG_MAX,
      Camera.SNAP_DEG_DEFAULT)
  end
  return self
end

-- One snap's angle (radians): SNAP uses the VOXEL SNAP ANGLE, the old fixed
-- styles their own angle, else the legacy 90 degrees.
function Camera:snapAngle()
  if self.turnStyle == "snap" then
    return math.rad(self.snapDeg or Camera.SNAP_DEG_DEFAULT)
  end
  local a = Camera.TURN_STYLES[self.turnStyle or ""]
  if a and a > 0 then return a end
  return Camera.SNAP
end

function Camera:snapTurn(dir)
  local a = self:snapAngle()
  self.snapYaw = wrapPi(self.snapYaw + (dir > 0 and -a or a))
end

-- Lab 8: the right stick, once per frame. actions = InputMap:apply's result
-- ({ snap = +1|-1 on a flick, turn = -1..1 analog past the dead zone});
-- dt = the frame's real seconds. SMOOTH turns by turn * speed * dt (stick
-- right = turn right); the snap styles turn once per flick.
function Camera:turnInput(actions, dt)
  if type(actions) ~= "table" then return end
  if self.turnStyle == "smooth" then
    local t = tonumber(actions.turn) or 0
    if t ~= 0 then
      t = math.max(-1, math.min(1, t))
      dt = math.max(0, math.min(tonumber(dt) or 0, 0.1))
      self.snapYaw = wrapPi(self.snapYaw - t * math.rad(self.turnSpeed or Camera.TURN_SPEED_DEFAULT) * dt)
    end
  elseif actions.snap then
    self:snapTurn(actions.snap)
  end
end

-- target = { x, z (root cells, player centre), ground (mesher units),
--            facing ("up"/"down"/"left"/"right"), lift (extra height),
--            offsetX, offsetZ (cells: cutscene camera object, raised
--            cameras only -- never moves the head-locked first person),
--            blended (Lab 8: x/z are display-rate interpolated) }
-- Snaps instead of gliding when the target jumps (warps, warp pads).
Camera.SNAP_JUMP = 1.5
function Camera:update(dt, target)
  if self.seat then -- W6: a battle seat owns the rig; the trainer is not followed
    self.yaw = self.seat.yaw or self.yaw
    return
  end
  dt = math.max(0, math.min(tonumber(dt) or 0, 0.1))
  local tx, tz = target.x, target.z
  if self.mode ~= "first" then
    tx = tx + (tonumber(target.offsetX) or 0)
    tz = tz + (tonumber(target.offsetZ) or 0)
  end
  local ty = (target.ground or 0) + (target.lift or 0)
  local jumped = self.lastTx and (math.abs(target.x - self.lastTx)
    + math.abs(target.z - self.lastTz)) > Camera.SNAP_JUMP
  self.lastTx, self.lastTz = target.x, target.z
  if not self.x or jumped or math.abs(tx - self.x) + math.abs(tz - self.z) > 4 then
    self.x, self.y, self.z = tx, ty, tz
  else
    local ky = 1 - math.exp(-dt * 10)
    if self.mode == "first" and target.blended then
      -- Lab 8: the target is already blended to the display rate
      -- (data/Actors.lua), so the eye rides it with no follow lag; only the
      -- ground height keeps its ease (stairs, ledges). Without the blend
      -- (no logic-tick hook) the old ease stays: it is the only smoothing.
      self.x, self.z = tx, tz
    else
      local k = 1 - math.exp(-dt * 22)
      self.x = self.x + (tx - self.x) * k
      self.z = self.z + (tz - self.z) * k
    end
    self.y = self.y + (ty - self.y) * ky
  end
  local want = self.snapYaw
  if self.mode == "overview" then
    want = 0
  elseif self.follow and self.mode == "first" then
    want = wrapPi((FACING_YAW[target.facing] or 0) + self.snapYaw)
  end
  local d = wrapPi(want - self.yaw)
  if self.vr or math.abs(d) < 1e-4 then
    -- headset: turns are instant (an eased world rotation is exactly the
    -- artificial smooth turn snap turning exists to avoid, review item 14)
    self.yaw = want
  else
    self.yaw = wrapPi(self.yaw + d * (1 - math.exp(-dt * 12)))
  end
end

-- anchor (world cells), pivot (LOCAL metres), m (metres per cell)
function Camera:rig()
  local seat = self.seat
  if seat then -- W6: battle seat, life size in every mode
    return seat.x, seat.y, seat.z, seat.px or 0, seat.py or 0, seat.pz or 0, Camera.METRES_PER_CELL
  end
  local x, y, z = self.x or 0, self.y or 0, self.z or 0
  local m = Camera.METRES_PER_CELL
  if self.mode == "third" then
    local s, c = math.sin(self.yaw), math.cos(self.yaw)
    return x + s * Camera.THIRD_BACK, y + Camera.THIRD_UP, z + c * Camera.THIRD_BACK,
      0, 0, 0, m
  elseif self.mode == "overview" then
    if self.vr then
      local px, py, pz = self:dioramaPivot()
      return x, y, z, px, py, pz, self:dioramaScale()
    end
    local d, a = self:overviewDist(), self:overviewPitch()
    local s, c = math.sin(self.yaw), math.cos(self.yaw)
    local back, up = d * math.cos(a), d * math.sin(a)
    return x + s * back, y + 0.5 + up, z + c * back, 0, 0, 0, m
  end
  local rm = self.room
  if rm then
    return x + (rm.wx or 0), y + Camera.EYE_HEIGHT, z + (rm.wz or 0), rm.px or 0, self.mrLift or 0, rm.pz or 0, m -- PORTAL_MR P1: mrLift
  end
  return x, y + Camera.EYE_HEIGHT, z, 0, self.mrLift or 0, 0, m -- PORTAL_MR P1: mrLift = the portal floor lift (LOCAL m, nil = 0)
end

function Camera:anchor()
  local ax, ay, az = self:rig()
  return ax, ay, az
end

function Camera:metresPerCell()
  local _, _, _, _, _, _, m = self:rig()
  return m
end

-- Distance (metres) from the eye to the trainer, for fog placement.
function Camera:focusDistance()
  if self.seat then return tonumber(self.seat.focusDist) or 0 end -- W6
  if self.mode == "third" then
    local b, u = Camera.THIRD_BACK, Camera.THIRD_UP
    return math.sqrt(b * b + u * u) * Camera.METRES_PER_CELL
  elseif self.mode == "overview" then
    if self.vr then return 1.1 end
    return self:overviewDist() * Camera.METRES_PER_CELL
  end
  return 0
end

-- view (metres) for a LOCAL-space eye pose.
function Camera:eyeView(pose, pitch)
  local ax, ay, az, px, py, pz, m = self:rig()
  local pos = pose and pose.pos or { 0, 0, 0 }
  if not pose and self.room and self.mode == "first" and not self.seat then pos = { px, 0, pz } end
  local q = pose and pose.quat or { 0, 0, 0, 1 }
  local R = Mat4.fromQuat(q[1], q[2], q[3], q[4])
  return Mat4.chain(
    Mat4.transpose(R),
    Mat4.translate(-pos[1], -pos[2], -pos[3]),
    pitch and Mat4.rotX(-pitch) or Mat4.identity(),
    Mat4.translate(px, py, pz),
    Mat4.scale(m),
    Mat4.rotY(-self.yaw),
    Mat4.translate(-ax, -ay, -az))
end

-- Full view-projection for one eye. `canvas` = true flips clip Y for
-- rendering into a LOVE Canvas (see Mat4.flipY).
function Camera:eyeViewProj(view, fov, canvas)
  local P = Mat4.fovProjection(fov.angleLeft, fov.angleRight, fov.angleUp,
    fov.angleDown, Camera.NEAR, Camera.FAR)
  if canvas then P = Mat4.flipY(P) end
  return Mat4.mul(P, view)
end

-- Yaw of where the eye looks, in world terms (for look-relative movement).
function Camera:worldLookYaw(pose)
  local head = pose and pose.quat and Mat4.quatYaw(pose.quat) or 0
  return wrapPi(self.yaw + head)
end

-- Eye position in world cells (for billboards / culling).
function Camera:eyeWorld(pose, pitch)
  local ax, ay, az, px, py, pz, m = self:rig()
  local pos = pose and pose.pos or { 0, 0, 0 }
  if not pose and self.room and self.mode == "first" and not self.seat then pos = { px, 0, pz } end
  local rx, ry, rz = Mat4.transformDir(Mat4.rotY(self.yaw),
    (pos[1] - px) / m, (pos[2] - py) / m, (pos[3] - pz) / m)
  local _ = pitch
  return ax + rx, ay + ry, az + rz
end

-- Desktop mono camera pitch per mode.
function Camera:monoPitch()
  if self.seat then return tonumber(self.seat.pitch) or -0.2 end -- W6: look at the arena
  if self.mode == "third" then return -0.72 end
  if self.mode == "overview" then return -self:overviewPitch() end
  return -0.12
end

function Camera:monoFovY()
  if self.seat then return math.rad(70) end -- W6
  if self.mode == "overview" then return Camera.OVERVIEW_FOV end
  return math.rad(70)
end

function Camera.monoFov(aspect, fovy)
  fovy = fovy or math.rad(70)
  local half = fovy / 2
  local hx = math.atan(math.tan(half) * aspect)
  return { angleLeft = -hx, angleRight = hx, angleUp = half, angleDown = -half }
end

-- Synthetic Quest-like stereo views for the desktop preview (asymmetric,
-- mirrored per eye, 64 mm IPD). Numbers are representative, not measured.
function Camera.syntheticViews(w, h)
  local l = { angleLeft = -0.942, angleRight = 0.698, angleUp = 0.768, angleDown = -0.855 }
  local r = { angleLeft = -0.698, angleRight = 0.942, angleUp = 0.768, angleDown = -0.855 }
  return {
    { pose = { pos = { -0.032, 0, 0 }, quat = { 0, 0, 0, 1 } }, fov = l, w = w, h = h },
    { pose = { pos = { 0.032, 0, 0 }, quat = { 0, 0, 0, 1 } }, fov = r, w = w, h = h },
  }
end

return Camera
