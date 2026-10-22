-- VR comfort for native stair/ladder warps and escalators. Native movement,
-- timing, sound and map loading retain ownership. Only the simulated camera
-- rig is held; eye orientation/position still come from live OpenXR poses.
local T = {}
T.__index = T
T.OUT, T.IN = 0.10, 0.16
function T.new() return setmetatable({ alpha = 0 }, T) end
function T:veil(native)
  if self.alpha <= 0 then return native end
  -- Native stair/escalator fades start after the comfort cover is opaque.
  -- Ordinary cave/ladder warps can fade white immediately: retain their
  -- coverage strength, but use black throughout this comfort envelope.
  return { 0, 0, 0, math.max(self.alpha, native and native[4] or 0) }
end
local stairs = setmetatable({}, { __mode = "k" })
local installed = setmetatable({}, { __mode = "k" })

-- Native stair warps have no public isStairActive flag and do not populate
-- _pending. Observe their public entry point without changing sequencing.
function T.install(warp)
  if not warp or installed[warp] or type(warp.startStairWarp) ~= "function" then return end
  local original = warp.startStairWarp
  local wrapper = function(...)
    local accepted = original(...)
    if accepted then stairs[warp] = true end
    return accepted
  end
  installed[warp] = { original = original, wrapper = wrapper }
  warp.startStairWarp = wrapper
end
function T.uninstall(warp)
  local entry = warp and installed[warp]
  if not entry then return end
  if warp.startStairWarp == entry.wrapper then warp.startStairWarp = entry.original end
  installed[warp], stairs[warp] = nil, nil
end

local function active(warp, name)
  local f = warp and warp[name]
  if type(f) ~= "function" then return false end
  local ok, value = pcall(f)
  return ok and value == true
end

function T:update(dt, warp, cam)
  dt = math.max(0, math.min(tonumber(dt) or 0, 0.1))
  local busy = active(warp, "isBusy")
  if not busy and warp then stairs[warp] = nil end
  if not cam.vr or cam.mode == "overview" or cam.seat then
    self.hold, self.alpha = nil, 0
    return false
  end
  -- _pending is the native ordinary warp record. Animated doors have a
  -- separate guard and deliberately do not enter this comfort transition.
  local pending = warp and warp._pending
  local begin = busy and (stairs[warp] or active(warp, "isEscalatorActive")
    or type(pending) == "table" and pending.fade ~= false)
  local hold = self.hold
  if not hold and begin then
    -- A valid previous render pose is required. Initial map loads already
    -- have the loading panel; don't manufacture a rig at the origin.
    if cam.x == nil or cam.y == nil or cam.z == nil then return false end
    hold = { x = cam.x, y = cam.y, z = cam.z, yaw = cam.yaw,
      room = cam.room and { px = cam.room.px, pz = cam.room.pz,
        wx = cam.room.wx, wz = cam.room.wz } or nil }
    self.hold = hold
  end
  if hold and busy then
    self.alpha = math.min(1, self.alpha + dt / T.OUT)
    -- Scene:pump may reset the camera on a root change. Restore the held
    -- source rig even then, until native arrival/forced steps finish.
    cam.x, cam.y, cam.z, cam.yaw = hold.x, hold.y, hold.z, hold.yaw
    cam.room = hold.room
    return true
  elseif hold then
    self.hold = nil
    self.alpha = 1
    -- Destination snap happens this frame under a fully black cover. Only
    -- subsequent frames uncover it; no visible source-to-destination glide.
    cam:reset()
    return false
  end
  self.alpha = math.max(0, self.alpha - dt / T.IN)
  return false
end
return T
