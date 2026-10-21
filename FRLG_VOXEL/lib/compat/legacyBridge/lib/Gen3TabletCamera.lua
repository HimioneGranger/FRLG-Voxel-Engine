-- VRITK_FRLG_HOST: the Kanto Gear tablet's live Pokedex camera on Gen3
-- (2026-10-02, gen3-dex-scanner tablet). VRITK's QuestPokedexCamera asks the
-- host for one small picture of the world through `context.renderCamera(cam)`
-- (KantoGearComponent.lua passes the per-frame context through unchanged).
-- On Crystal, BATTLE_ART_QUEST_COMPAT's StereoRenderer answers by rendering
-- one more 240x216 eye from the tablet camera inside its layer-update window.
-- This is the FireRed/Emerald equivalent: the camera record (world px, the
-- same frame PxContext builds for VRITK) is turned into one FRLG_VOXEL LOCAL
-- eye (pose + fov) and handed to vrHost.camera.render, which draws the frame
-- that FRLG_VOXEL already prepared (same culled maps, cards, sky and light)
-- into a small canvas of its own.
--
--   Gen3TabletCamera.localEye(cam, rig, w, h) -> {pose={pos,quat}, fov} | nil, why
--     cam = QuestPokedexCamera.build(gaze): eye/focus/up in world px, fov
--     (vertical, radians). rig = HostApi.rigFrame (localFromWorld, cells).
--   Gen3TabletCamera.new(opts) -> camera host; host:window(ctx, vrHost) ->
--     renderCamera, close. renderCamera is valid only until close() (the
--     same "camera window" rule StereoRenderer uses: a frame is rendered
--     only inside the layer update, after the view was prepared).
--   host:stats() -> plain scalars (calls, rendered, failures, ms, draws).
--
-- Cost policy: low resolution and a short draw distance. Size: 320x288, the
-- viewfinder's 240x216 shape at 4x the pixels of the old 160x144. While a scan
-- is looking (Gen3DexScannerCompat CAMERA_FILL) the Gear draws the feed over the
-- whole 240x216 tablet screen (720x648 target pixels at the 3x readability
-- scale), 2.25x upscale; it used to fill a 54x54 portrait window (about 1:1).
-- That is below the panel's real pixel count (720x648) on purpose: the camera is a
-- second world render at 20 Hz, so its fill cost is the thing to keep small. It
-- keeps the short draw distance
-- (FAR_CELLS). The render rate is set by the caller (Gen3DexScannerCompat
-- runs VRITK's camera at FRAME_INTERVAL there); at most one render per host
-- frame here regardless.
local V = ...
local _ = V

local M = {}
M.__index = M

M.WIDTH, M.HEIGHT = 320, 288
M.FAR_CELLS = 32
M.PX_PER_CELL = 16
M.DEFAULT_FOV_Y = math.rad(60)
M.MAX_PER_FRAME = 1

local function finite(n) return type(n) == "number" and n == n and n > -math.huge and n < math.huge end

local function vec(v)
  if type(v) ~= "table" then return nil end
  local x, y, z = v[1] or v.x, v[2] or v.y, v[3] or v.z
  if not (finite(x) and finite(y) and finite(z)) then return nil end
  return { x, y, z }
end

local function norm(v)
  local n = math.sqrt(v[1] * v[1] + v[2] * v[2] + v[3] * v[3])
  if not (n > 1e-9 and n < math.huge) then return nil end
  return { v[1] / n, v[2] / n, v[3] / n }
end

local function cross(a, b)
  return { a[2] * b[3] - a[3] * b[2], a[3] * b[1] - a[1] * b[3], a[1] * b[2] - a[2] * b[1] }
end

-- row-major 4x4 (FRLG_VOXEL Mat4 layout)
local function point(m, v)
  return { m[1] * v[1] + m[2] * v[2] + m[3] * v[3] + m[4],
    m[5] * v[1] + m[6] * v[2] + m[7] * v[3] + m[8],
    m[9] * v[1] + m[10] * v[2] + m[11] * v[3] + m[12] }
end
local function dir(m, v)
  return { m[1] * v[1] + m[2] * v[2] + m[3] * v[3],
    m[5] * v[1] + m[6] * v[2] + m[7] * v[3],
    m[9] * v[1] + m[10] * v[2] + m[11] * v[3] }
end

-- Quaternion {x,y,z,w} of the rotation whose COLUMNS are r, u, b (right, up,
-- back = -forward): an OpenXR pose looks down its own -Z with +Y up, and
-- Camera:eyeView uses R^T of Mat4.fromQuat(q) (columns = the pose axes).
function M.quatFromBasis(r, u, b)
  local m00, m01, m02 = r[1], u[1], b[1]
  local m10, m11, m12 = r[2], u[2], b[2]
  local m20, m21, m22 = r[3], u[3], b[3]
  local tr = m00 + m11 + m22
  local x, y, z, w
  if tr > 0 then
    local s = math.sqrt(tr + 1) * 2
    w, x, y, z = 0.25 * s, (m21 - m12) / s, (m02 - m20) / s, (m10 - m01) / s
  elseif m00 > m11 and m00 > m22 then
    local s = math.sqrt(1 + m00 - m11 - m22) * 2
    w, x, y, z = (m21 - m12) / s, 0.25 * s, (m01 + m10) / s, (m02 + m20) / s
  elseif m11 > m22 then
    local s = math.sqrt(1 + m11 - m00 - m22) * 2
    w, x, y, z = (m02 - m20) / s, (m01 + m10) / s, 0.25 * s, (m12 + m21) / s
  else
    local s = math.sqrt(1 + m22 - m00 - m11) * 2
    w, x, y, z = (m10 - m01) / s, (m02 + m20) / s, (m12 + m21) / s, 0.25 * s
  end
  local n = math.sqrt(x * x + y * y + z * z + w * w)
  return { x / n, y / n, z / n, w / n }
end

function M.localEye(cam, rig, w, h)
  if type(cam) ~= "table" then return nil, "invalid-camera" end
  if type(rig) ~= "table" or type(rig.localFromWorld) ~= "table" then return nil, "rig-unavailable" end
  local L = rig.localFromWorld
  for i = 1, 12 do if not finite(L[i]) then return nil, "rig-unavailable" end end
  local eye, focus, up = vec(cam.eye), vec(cam.focus), vec(cam.up)
  if not (eye and focus and up) then return nil, "invalid-camera" end
  local k = 1 / M.PX_PER_CELL
  local pos = point(L, { eye[1] * k, eye[2] * k, eye[3] * k })
  local f = norm(dir(L, { focus[1] - eye[1], focus[2] - eye[2], focus[3] - eye[3] }))
  local u = norm(dir(L, up))
  if not (f and u) then return nil, "invalid-camera" end
  local d = f[1] * u[1] + f[2] * u[2] + f[3] * u[3]
  if math.abs(d) > 0.99 then return nil, "invalid-camera" end
  u = norm({ u[1] - f[1] * d, u[2] - f[2] * d, u[3] - f[3] * d })
  local r = norm(cross(f, u))
  if not (u and r) then return nil, "invalid-camera" end
  local q = M.quatFromBasis(r, u, { -f[1], -f[2], -f[3] })
  local fovY = finite(cam.fov) and cam.fov > 0.05 and cam.fov < 3 and cam.fov or M.DEFAULT_FOV_Y
  w, h = tonumber(w) or M.WIDTH, tonumber(h) or M.HEIGHT
  local ty = math.tan(fovY / 2)
  local tx = ty * (w / h)
  local ax, ay = math.atan(tx), math.atan(ty)
  return { pose = { pos = pos, quat = q },
    fov = { angleLeft = -ax, angleRight = ax, angleUp = ay, angleDown = -ay } }
end

local function now()
  if love and love.timer and type(love.timer.getTime) == "function" then return love.timer.getTime() end
  return os.clock()
end

-- Lab 52 (GC SLACK budget): window() runs on every VR layer update, so it
-- must not build closures or tables there. The two functions it hands out are
-- built once per host in new(); the window's state lives in scalar fields
-- (winOpen/winUsed/winCtx/winHost). The rule is unchanged: renderCamera works
-- only between window() and close(); outside a window it answers
-- "camera-frame-expired". The render options table is reused (api.render
-- reads opts.farCells only and keeps nothing).
function M.new(opts)
  opts = opts or {}
  local self = setmetatable({
    width = opts.width or M.WIDTH, height = opts.height or M.HEIGHT,
    farCells = opts.farCells or M.FAR_CELLS, clock = opts.clock or now, log = opts.log,
    frame = nil,
    winOpen = false, winUsed = 0, winCtx = nil, winHost = nil,
    renderOpts = { farCells = opts.farCells or M.FAR_CELLS },
    st = { calls = 0, rendered = 0, failures = 0, expired = 0, lastMs = 0, totalMs = 0, maxMs = 0,
      lastCalls = 0, lastTris = 0, lastReason = nil },
  }, M)
  self.renderFn = function(cam) return self:_render(cam) end
  self.closeFn = function() self.winOpen, self.winCtx, self.winHost = false, nil, nil end
  return self
end

function M:_render(cam)
  local st = self.st
  st.calls = st.calls + 1
  if not self.winOpen then st.expired = st.expired + 1; return nil, "camera-frame-expired" end
  local vrHost, ctx = self.winHost, self.winCtx
  local api = type(vrHost) == "table" and vrHost.camera
  if type(api) ~= "table" or type(api.render) ~= "function" then
    st.lastReason = "unsupported"; return nil, "unsupported"
  end
  if self.winUsed >= M.MAX_PER_FRAME and self.frame then return self.frame end
  self.winUsed = self.winUsed + 1
  local eye, why = M.localEye(cam, ctx and ctx.rig, self.width, self.height)
  if not eye then
    st.failures, st.lastReason = st.failures + 1, why
    return nil, why
  end
  local t0 = self.clock()
  local opts = self.renderOpts
  opts.farCells = self.farCells
  local ok, frame, reason, info = pcall(api.render, eye, self.width, self.height, opts)
  local ms = (self.clock() - t0) * 1000
  if not ok or not frame then
    st.failures, st.lastReason = st.failures + 1, tostring(ok and reason or frame)
    return nil, st.lastReason
  end
  st.rendered, st.lastMs, st.totalMs = st.rendered + 1, ms, st.totalMs + ms
  if ms > st.maxMs then st.maxMs = ms end
  if type(info) == "table" then st.lastCalls, st.lastTris = tonumber(info.calls) or 0, tonumber(info.tris) or 0 end
  st.lastReason = nil
  self.frame = frame
  return frame
end

-- One host frame's camera window. ctx = the vrHost layer ctx (ctx.rig);
-- vrHost = FRLG_VOXEL.exports.vrHost. Returns renderCamera, close (the same
-- two functions every frame; no allocation).
function M:window(ctx, vrHost)
  self.winOpen, self.winUsed, self.winCtx, self.winHost = true, 0, ctx, vrHost
  return self.renderFn, self.closeFn
end

function M:stats()
  local st, out = self.st, {}
  for k, v in pairs(st) do out[k] = v end
  out.avgMs = st.rendered > 0 and st.totalMs / st.rendered or 0
  out.width, out.height, out.farCells = self.width, self.height, self.farCells
  return out
end

return M
