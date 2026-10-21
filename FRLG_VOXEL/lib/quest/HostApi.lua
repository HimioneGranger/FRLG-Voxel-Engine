-- FRLG_VOXEL: the vrHost API 1 object (DESIGN.md 2a, W4 phase P1).
--
-- This file builds `mod.exports.vrHost` but does not install it: the wiring
-- (main.lua calling HostApi.new with the live camera/scene/xr objects, then
-- `mod.exports.vrHost = hostApi.vrHost`) is a separate step, planned in
-- w4/WIRING_PLAN.md, because it touches files other workers are editing this
-- phase. Everything in this file is a NEW, self-contained module: it reads
-- Camera/Scene/XRSession through injected references (never edits them) and
-- degrades safely (nil/false/no-ops) when a reference is absent, so it also
-- works as the "desktop mock" DESIGN.md 2a asks for and as a plain-LuaJIT
-- test subject.
--
-- Only two of this module's own requires are unconditional and load-time:
-- render/Mat4 and data/Actors, both pure-ish FRLG_VOXEL lib modules loaded
-- the normal V.require way. Everything engine-side (src.core.game3.*) goes
-- through the injectable `engine(name)` accessor so tests can stub it.
local V = ...
local Mat4 = V.require("render/Mat4")
local Camera = V.require("render/Camera")
local Actors = V.require("data/Actors")
local HostLayers = V.require("quest/HostLayers")

local HostApi = {}
HostApi.__index = HostApi

HostApi.API = 1
HostApi.VERSION = "1.2" -- worker "atmos" (GW-P1/P2): clock.register/unregister,
-- emissive.registerProvider, atmosphere.get, eye.far/forward, debug.forceHour.
-- W5 (owmons): actors.registerProvider/unregisterProvider/targets (kept from 1.1).

-- Seconds of continuous flat (want3d false, every frame after the first
-- transient one) before an un-invalidated layer set is invalidated anyway.
-- CRITIQUE #8's safety net for a "transient" reason that never clears.
HostApi.FLAT_INVALIDATE_SECONDS = 2.0

-- Frame dt is never trusted past this (CRITIQUE #12: love.timer.getDelta is
-- unclamped; VRITK itself already clamps to 0.1-0.2 in its own modules).
HostApi.MAX_DT = 0.1

------------------------------------------------------------ pure rig maths
-- These two are the only place the worldFromLocal / localFromWorld formulas
-- are written down; everything else (HostApi.rigFrame, the runtime object)
-- calls them. Verified against Camera.lua's own header comment and
-- Camera:eyeView (see w4/tests/test_matrix_identities.lua):
--   worldFromLocal(L) = anchor + Ry(yaw) * (L - pivot) / m
--   localFromWorld(W)  = pivot + m * Ry(-yaw) * (W - anchor)
local function worldFromLocalMat(ax, ay, az, px, py, pz, m, yaw)
  return Mat4.chain(
    Mat4.translate(ax, ay, az),
    Mat4.rotY(yaw),
    Mat4.scale(1 / m),
    Mat4.translate(-px, -py, -pz))
end

local function localFromWorldMat(ax, ay, az, px, py, pz, m, yaw)
  return Mat4.chain(
    Mat4.translate(px, py, pz),
    Mat4.scale(m),
    Mat4.rotY(-yaw),
    Mat4.translate(-ax, -ay, -az))
end
HostApi._worldFromLocalMat = worldFromLocalMat
HostApi._localFromWorldMat = localFromWorldMat

-- Pure: the rig frame for a Camera instance's CURRENT pose (call after
-- camera:update()). No love, no engine, no side effects.
function HostApi.rigFrame(camera)
  local ax, ay, az, px, py, pz, m = camera:rig()
  return {
    anchor = { x = ax, y = ay, z = az },
    pivot = { x = px, y = py, z = pz },
    m = m, yaw = camera.yaw, mode = camera.mode,
    worldFromLocal = worldFromLocalMat(ax, ay, az, px, py, pz, m, camera.yaw),
    localFromWorld = localFromWorldMat(ax, ay, az, px, py, pz, m, camera.yaw),
  }
end

-- Pure: one eye's {vp, proj, view, pos, index, name}, built the same way
-- View.lua's renderBody builds `vp` (see w4/WIRING_PLAN.md for the exact
-- call site the layer slot sits next to).
-- eyePose = {pos, quat} | nil (desktop mono), eyeFov = {angleLeft,Right,Up,Down}
function HostApi.eyeFrame(camera, index, name, eyePose, eyeFov, pitch)
  local view = camera:eyeView(eyePose, pitch)
  local vp = camera:eyeViewProj(view, eyeFov, true)
  local proj = Mat4.flipY(Mat4.fovProjection(eyeFov.angleLeft, eyeFov.angleRight,
    eyeFov.angleUp, eyeFov.angleDown, Camera.NEAR, Camera.FAR))
  local ex, ey, ez = camera:eyeWorld(eyePose, pitch)
  -- worker "atmos" (vrHost 1.2, DESIGN.md 4.4 "eye gains far and forward"):
  -- far is the projection far plane (metres); forward follows the same yaw
  -- View.lua's R5 cardDir already uses for "where the eye looks in world
  -- terms" (pitch left out, same approximation cardDir makes).
  local lookYaw = camera.vr and camera:worldLookYaw(eyePose) or (camera.yaw or 0)
  return { index = index, name = name, view = view, proj = proj, vp = vp,
    pos = { x = ex, y = ey, z = ez }, far = Camera.FAR,
    forward = { x = math.sin(lookYaw), y = 0, z = math.cos(lookYaw) } }
end

------------------------------------------------------------ input claims
-- Registers per-frame claims from vrHost.input.claim() and derives the
-- suppress mask handed to InputMap:apply's ctx.suppress (see
-- w4/WIRING_PLAN.md and CRITIQUE #2). Kept as its own small object so it is
-- independently testable (w4/tests/test_input_claims.lua) without a full
-- HostApi instance.
local Claims = {}
Claims.__index = Claims

-- Never claimable, whatever a layer asks for (DESIGN 1 "Never claimable").
Claims.NEVER = { start = true, toggle = true }

-- Buttons the "hands" input profile removes from the game mapping outright
-- (DESIGN 1 "Fixed hands profile"): grip stops pressing L/R, left trigger
-- stops pressing SELECT.
local HANDS_PROFILE_MASK = { gripL = true, gripR = true, triggerL = true }

local ANALOG_THRESH = {
  gripL = { on = 0.7, off = 0.45 }, gripR = { on = 0.7, off = 0.45 },
  triggerL = { on = 0.6, off = 0.35 }, triggerR = { on = 0.6, off = 0.35 },
}
local STICK_DEAD = 0.35

-- Is `name` still physically active right now? `heldStyle` = true uses the
-- lower (release) threshold for analogs, matching InputMap's own hysteresis
-- (CRITIQUE #2's "give suppressed analog controls held-style hysteresis").
local function controlActive(name, controls, heldStyle)
  if not controls then return false end
  local th = ANALOG_THRESH[name]
  if th then
    local v = tonumber(controls[name]) or 0
    return v > (heldStyle and th.off or th.on)
  end
  if name == "a" or name == "b" then return controls[name] == true end
  if name == "moveStick" then
    local x, y = tonumber(controls.moveX) or 0, tonumber(controls.moveY) or 0
    return (x * x + y * y) > STICK_DEAD * STICK_DEAD
  end
  if name == "lookStick" then
    local x, y = tonumber(controls.lookX) or 0, tonumber(controls.lookY) or 0
    return (x * x + y * y) > STICK_DEAD * STICK_DEAD
  end
  return false
end
Claims.controlActive = controlActive

function Claims.new()
  return setmetatable({ pending = {}, sticky = {}, profile = "game" }, Claims)
end

-- Cleared at the start of every world frame's layer update pass (valid for
-- the current frame only, DESIGN 2a input.claim).
function Claims:beginCycle()
  for k in pairs(self.pending) do self.pending[k] = nil end
end

function Claims:claim(ownerId, mask)
  if type(ownerId) ~= "string" or ownerId == "" then return false, "bad ownerId" end
  if type(mask) ~= "table" then return false, "bad mask" end
  for k, v in pairs(mask) do
    if v and not Claims.NEVER[k] then self.pending[k] = ownerId end
  end
  return true
end

function Claims:setProfile(profile)
  self.profile = (profile == "hands") and "hands" or "game"
  return true
end

-- Computes this frame's suppress set and advances the sticky/held
-- bookkeeping. Call once per headset frame (world OR panel), even when no
-- layer ran this frame (CRITIQUE #2: "keep the last claims through frames
-- where layers did not run; clear a claim only when its control is
-- physically released").
--
-- Sticky (already-suppressed-and-still-held) suppression applies even while
-- menuOpen, so a grip held through a toggle/menu transition cannot fire L/R
-- the instant the frame flips (the bug CRITIQUE #2 found). A FRESH claim or
-- the hands profile, however, only takes effect while menuOpen is false
-- (DESIGN 1 "Never claimable... anything while a menu or the panel is up").
function Claims:commit(controls, menuOpen)
  -- W4 review fix #8b (REVIEW_VRITK_P2.md): a nil-controls frame (Meta
  -- overlay, resume -- CRITIQUE #12) used to fall straight into the sticky
  -- loop below, where controlActive(k, nil, true) is false for every k, so
  -- `suppress` came back empty and `self.sticky` got overwritten with that
  -- same empty set -- wiping the sticky memory of a control that was, and
  -- still is, physically held on the other side of the blip. Leave
  -- self.sticky untouched and just hand back a copy of it: the next REAL
  -- frame resolves the control's actual state either way (CRITIQUE #2's own
  -- "clear a claim only when its control is physically released" already
  -- covers that case correctly once real controls return).
  if controls == nil then
    local keep = {}
    for k in pairs(self.sticky) do keep[k] = true end
    return keep
  end
  local suppress = {}
  -- Sticky suppression only continues while the control is STILL
  -- physically active this frame (held-style hysteresis): a control that
  -- has genuinely released drops out of the returned suppress set on this
  -- same frame, not one frame later ("clear a claim only when its control
  -- is physically released" -- CRITIQUE #2).
  for k in pairs(self.sticky) do
    if controlActive(k, controls, true) then suppress[k] = true end
  end
  if not menuOpen then
    for k in pairs(self.pending) do suppress[k] = true end
    if self.profile == "hands" then
      for k in pairs(HANDS_PROFILE_MASK) do suppress[k] = true end
    end
  end
  suppress.start, suppress.toggle = nil, nil
  local nextSticky = {}
  for k in pairs(suppress) do
    if controlActive(k, controls, true) then nextSticky[k] = true end
  end
  self.sticky = nextSticky
  return suppress
end

HostApi.Claims = Claims

------------------------------------------------------------ construction
local function noopLog() end

-- Lab 58 #12 (flag "requirememo"): the default engine lookup remembers the module table after the first success
-- (isWater / isWalkable run it from the weather mod's habitat code). A failed require is never remembered.
-- An injected opts.engine is untouched. HostApi.resetEngineMemo() forgets (new session, engine reload).
local okS58, Speed58 = pcall(V.require, "perf/Speed58")
if not (okS58 and type(Speed58) == "table") then Speed58 = nil end
local engineMemo = {}
local function defaultEngine(name)
  if Speed58 and Speed58.on("requirememo") then
    local m = engineMemo[name]
    if m then return m end
    local ok, mod = pcall(require, name)
    if ok and type(mod) == "table" then engineMemo[name] = mod; return mod end
    return nil
  end
  local ok, m = pcall(require, name)
  if ok and type(m) == "table" then return m end
  return nil
end
function HostApi.resetEngineMemo() for k in pairs(engineMemo) do engineMemo[k] = nil end end

local function defaultClock()
  -- Bare `love`, not _G.love: see HostLayers.lua's defaultGraphics comment
  -- -- a bare identifier resolves through any sandboxed _ENV without
  -- needing that sandbox to also alias _G to itself.
  if love and love.timer and love.timer.getTime then
    local ok, t = pcall(love.timer.getTime)
    if ok then return t end
  end
  return os.clock()
end

-- opts = {
--   mod = <mod handle>, log = fun(msg), android = bool,
--   camera = <Camera instance>, scene = <Scene instance>, xr = <XRSession>,
--   layers = <HostLayers instance>, engine = fun(name) -> module|nil,
--   clock = fun() -> seconds, eventSink = array (test observation only),
-- }
function HostApi.new(opts)
  opts = opts or {}
  local self = setmetatable({
    mod = opts.mod,
    log = opts.log or noopLog,
    android = opts.android == true,
    camera = opts.camera,
    scene = opts.scene,
    xr = opts.xr,
    engine = opts.engine or defaultEngine,
    clock = opts.clock or defaultClock,
    eventSink = opts.eventSink,
    layers = opts.layers or HostLayers.new({ log = opts.log }),
    claims = Claims.new(),
    lastControls = nil,
    mockControls = nil,
    field = false,
    battle = false,                 -- W6: a 3D battle frame (field is false then)
    battlePass = opts.battlePass,   -- W6: battle/BattlePass.lua instance (main.lua sets it)
    menuOpen = false,
    worldActive = false,
    flatSince = nil,
    flatInvalidated = false,
    failed = nil,
    frame = 0,
    -- W4 review fix #7 (optional half): true once a lost-session frame has
    -- already reported session_stopped on its own (main.lua's questFrame,
    -- right after r.xr:frame{}); teardown() reads this to skip its OWN
    -- session_stopped for the same session, so a loss followed shortly by
    -- teardown emits exactly one session_stopped/invalidate, not two.
    -- Cleared by notifySessionStarted, so a stale flag from a PREVIOUS
    -- session's loss can never suppress teardown's own stop notification
    -- for a session that actually did start cleanly afterward.
    lossReported = false,
    -- worker "atmos" (vrHost 1.2): day/night clock providers, the emissive
    -- (glow mask) provider, and this frame's published atmosphere state.
    -- Kept separate from `clock` above, which is an unrelated injectable
    -- wall-clock function (self.clock(), used by the flat-invalidate timer).
    dayClocks = {}, dayClockOrder = {},
    emissiveProviders = {}, emissiveProviderOrder = {},
    atmosphereState = nil,
  }, HostApi)
  self.vrHost = self:_buildExports()
  return self
end

------------------------------------------------------------ events
function HostApi:_emit(name, payload)
  local events = self.mod and self.mod.events
  if events and type(events.emit) == "function" then
    pcall(events.emit, events, "mod.FRLG_VOXEL." .. name, payload)
  end
  if self.eventSink then self.eventSink[#self.eventSink + 1] = { name = name, payload = payload } end
end

------------------------------------------------------------ lifecycle notifications
-- Wiring calls these from the points DESIGN.md 2a's events table names.
function HostApi:notifySessionStarted(refreshRate)
  self.lossReported = false -- W4 review fix #7: a fresh session, forget any prior loss
  self:_emit("session_started", { refreshRate = refreshRate })
end

function HostApi:notifySessionStopped(reason)
  self.lastControls, self.mockControls = nil, nil
  self.worldActive, self.flatSince, self.flatInvalidated = false, nil, false
  self:invalidateNow(reason or "session_stopped")
  self:_emit("session_stopped", { reason = reason })
end

function HostApi:notifyFailed(where, err)
  self.failed = tostring(where) .. ": " .. tostring(err)
  self:invalidateNow("failed:" .. tostring(where))
  self:_emit("failed", { where = where, err = err })
end

function HostApi:notifyModeChanged(mode, metresPerCell)
  self:invalidateNow("mode:" .. tostring(mode))
  self:_emit("mode", { mode = mode, metresPerCell = metresPerCell })
end

function HostApi:notifyCameraReset(reason)
  self:_emit("camera_reset", { reason = reason })
end

function HostApi:notifyRootShift(dx, dz, from, to)
  self:_emit("root_shift", { dx = dx, dz = dz, from = from, to = to })
end

-- W6 (battle P-B1): 3D battle lifecycle, emitted by battle/BattlePass.lua as
-- mod.FRLG_VOXEL.battle_stage / battle_end.
function HostApi:notifyBattle(kind, payload)
  self:_emit("battle_" .. tostring(kind), payload)
end

-- Explicit hard invalidate: toggle off, session stop, failure, mode change.
-- Never call this for a transient flat reason (heal machine, banner, a menu
-- opening, "building") -- use setWorldActive(false, reason) for those.
function HostApi:invalidateNow(reason)
  self.flatInvalidated = true
  local ok, err = pcall(self.layers.invalidateAll, self.layers, reason)
  if not ok then self.log("[HostApi] invalidateAll failed: " .. tostring(err)) end
  self:_emit("invalidate", { reason = reason })
end

-- Call once per headset frame with whether the world (stereo) layer actually
-- drew this frame. Emits stereo{on,reason,transient} and only escalates to a
-- real invalidate after FLAT_INVALIDATE_SECONDS of continuous flat
-- (CRITIQUE #8's fix for "which stereo off events call invalidate").
function HostApi:setWorldActive(active, reason)
  local now = self.clock()
  if active then
    if not self.worldActive then
      self.worldActive = true
      self.flatSince, self.flatInvalidated = nil, false
      self:_emit("stereo", { on = true, reason = reason })
    end
    return
  end
  if self.worldActive then
    self.worldActive = false
    self.flatSince = now
    self:_emit("stereo", { on = false, reason = reason, transient = true })
    return
  end
  if self.flatSince and not self.flatInvalidated
      and (now - self.flatSince) > HostApi.FLAT_INVALIDATE_SECONDS then
    self:invalidateNow(reason or "flat-timeout")
  end
end

------------------------------------------------------------ per-frame pump
-- Called once per headset frame (world or panel) right after view:prepare
-- succeeds, before layer updates run. info = { controls, views, head, dt,
-- frame, menuOpen, field, rootId }. Clamps dt (CRITIQUE #12) and stores
-- controls for input.snapshot().
function HostApi:beginFrame(info)
  info = info or {}
  self.frame = (info.frame ~= nil) and info.frame or (self.frame + 1)
  self.lastControls = info.controls
  self.menuOpen = info.menuOpen == true
  self.field = info.field == true
  self.battle = info.battle == true -- W6
  self.rootIdOverride = info.rootId
  local dt = tonumber(info.dt) or 0
  if dt < 0 then dt = 0 end
  if dt > HostApi.MAX_DT then dt = HostApi.MAX_DT end
  self.dt = dt
  self.claims:beginCycle()
  return self:_buildLayerCtx(info)
end

function HostApi:_rig()
  if not self.camera then return nil end
  local ok, rig = pcall(HostApi.rigFrame, self.camera)
  if ok then return rig end
  return nil
end

function HostApi:_buildLayerCtx(info)
  local rig = self:_rig()
  return {
    frame = self.frame, dt = self.dt,
    controls = info.controls, views = info.views, head = info.head,
    worldFromLocal = rig and rig.worldFromLocal, localFromWorld = rig and rig.localFromWorld,
    rig = rig, gaze = info.gaze,
    rootId = self.rootIdOverride or (self.scene and self.scene.rootId),
    menuOpen = self.menuOpen, field = self.field,
    battle = self.battle, -- W6
  }
end

-- Runs the layer update pass. Returns the same ctx (also stored) so a
-- caller that built it via beginFrame can pass it straight through.
function HostApi:updateLayers(ctx)
  self.layers:update(ctx)
end

-- Per eye, eyeInfo = { index, name, vp, proj, view, pos } (see
-- HostApi.eyeFrame). Delegates straight to the registry.
function HostApi:drawEye(eyeInfo)
  self.layers:draw(eyeInfo)
end

function HostApi:endFrame()
  -- Reserved for future per-frame teardown (matches HostLayers:update's
  -- per-frame table so both have a symmetric pump shape); nothing to do yet
  -- in P1.
end

-- Suppress mask for this frame's InputMap:apply(controls, {suppress=...}).
-- Safe to call even on frames where updateLayers() never ran (panel/menu
-- frames): sticky suppression from a still-held claimed control persists.
function HostApi:suppressMask(controls, menuOpen)
  return self.claims:commit(controls, menuOpen == true)
end

------------------------------------------------------------ world queries
function HostApi:heightAt(wx, wz)
  if not self.scene then return nil end
  local ok, v = pcall(self.scene.heightAt, self.scene, wx, wz)
  if ok then return v end
  return nil
end

-- mapId, lx, ly, mapDef | nil. Reads Scene.placed directly (documented
-- internal shape, DESIGN 2a world.locate): {key,id,def,ox,oy,border}.
function HostApi:locate(wx, wz)
  local scene = self.scene
  if not scene then return nil end
  wx,wz=scene:worldToNative(wx,wz)
  local cx, cz = math.floor(wx), math.floor(wz)
  for _, p in ipairs(scene.placed or {}) do
    if not p.border then
      local w, h
      local rec = scene.cache and scene.cache[p.key]
      if rec and not rec.failed and not rec.empty then
        w, h = rec.w, rec.h
      elseif p.def and p.def.midLayout then
        w, h = p.def.midLayout.width, p.def.midLayout.height
      end
      if w and h then
        local lx, lz = cx - p.ox, cz - p.oy
        if lx >= 0 and lz >= 0 and lx < w and lz < h then
          return p.id, lx, lz, p.def
        end
      end
    end
  end
  return nil
end

-- Nearby trees from the exact cached geometry used to render the map.
-- Coordinates are root-map cells (16 weather pixels), X east / Z south.
-- Index once per immutable record/tree-list identity, never census per frame.
local VEGETATION_BIN, VEGETATION_RADIUS = 4, 6
local function finiteVegetation(v)
  return type(v) == "number" and v == v and math.abs(v) < 1e7
end
function HostApi:vegetationAt(wx, wz)
  if not finiteVegetation(wx) or not finiteVegetation(wz) then return nil end
  local scene = self.scene
  if not scene then return nil end
  self.vegetationIndexes = self.vegetationIndexes or setmetatable({}, { __mode = "k" })
  local known, count = false, 0
  for _, p in ipairs(scene.placed or {}) do
    local rec = scene.cache and scene.cache[p.key]
    local trees = rec and not rec.failed and not rec.empty and rec.occluders and rec.occluders.trees
    local ox, oz = tonumber(p.ox), tonumber(p.oy)
    if type(trees) == "table" and finiteVegetation(ox) and finiteVegetation(oz) then
      local x, z = wx - ox, wz - oz
      local w, h = tonumber(rec.w), tonumber(rec.h)
      -- Only intersecting maps/rings establish known habitat near this point.
      if finiteVegetation(w) and finiteVegetation(h) and x >= -VEGETATION_RADIUS
        and z >= -VEGETATION_RADIUS and x < w + VEGETATION_RADIUS and z < h + VEGETATION_RADIUS then
        known = true
        local index = self.vegetationIndexes[rec]
        if not index or index.trees ~= trees then
          index = { trees = trees, bins = {} }
          for _, t in ipairs(trees) do
            local tx, tz = type(t) == "table" and (t.x or t[1]), type(t) == "table" and (t.z or t[2])
            if finiteVegetation(tx) and finiteVegetation(tz) then
              local bx, bz = math.floor(tx / VEGETATION_BIN), math.floor(tz / VEGETATION_BIN)
              local key = bx .. ":" .. bz
              local bucket = index.bins[key]
              if not bucket then bucket = {}; index.bins[key] = bucket end
              bucket[#bucket + 1] = { tx, tz }
            end
          end
          self.vegetationIndexes[rec] = index
          self.vegetationIndexBuilds = (self.vegetationIndexBuilds or 0) + 1
        end
        for bz = math.floor((z - VEGETATION_RADIUS) / VEGETATION_BIN), math.floor((z + VEGETATION_RADIUS) / VEGETATION_BIN) do
          for bx = math.floor((x - VEGETATION_RADIUS) / VEGETATION_BIN), math.floor((x + VEGETATION_RADIUS) / VEGETATION_BIN) do
            for _, t in ipairs(index.bins[bx .. ":" .. bz] or {}) do
              local dx, dz = t[1] - x, t[2] - z
              if dx * dx + dz * dz <= VEGETATION_RADIUS * VEGETATION_RADIUS then
                count = count + 1
                if count >= 12 then return 1 end
              end
            end
          end
        end
      end
    end
  end
  if known then return math.min(1, count / 12) end
  return nil -- Unknown is distinct from a genuinely tree-free street.
end

function HostApi:isWater(wx, wz)
  local mapId, lx, lz, mapDef = self:locate(wx, wz)
  if not mapId then return nil end
  local Collision = self.engine("src.core.game3.collision")
  if not (Collision and Collision.isWaterOn) then return nil end
  local ok, v = pcall(Collision.isWaterOn, mapDef, lx, lz)
  if ok then return v end
  return nil
end

-- PARTIAL (DESIGN/CRITIQUE): Collision.isWalkable only answers for the
-- engine's currently bound (active) map. For a located point on a
-- different placed map this returns nil ("unknown") rather than guessing;
-- fixing that needs an any-map walkability query the engine does not
-- expose yet (see w4/REPORT.md open issues).
function HostApi:isWalkable(wx, wz)
  local mapId, lx, lz = self:locate(wx, wz)
  if not mapId then return nil end
  if self.scene and mapId ~= self.scene.rootId then return nil end
  local Collision = self.engine("src.core.game3.collision")
  if not (Collision and Collision.isWalkable) then return nil end
  local ok, v = pcall(Collision.isWalkable, lx, lz)
  if ok then return v end
  return nil
end

function HostApi:behavior(wx, wz)
  local mapId, lx, lz, mapDef = self:locate(wx, wz)
  if not mapId then return nil end
  local Collision = self.engine("src.core.game3.collision")
  if not (Collision and Collision.behaviorOn) then return nil end
  local ok, v = pcall(Collision.behaviorOn, mapDef, lx, lz)
  if ok then return v end
  return nil
end

function HostApi:elevation(wx, wz)
  local mapId, lx, lz, mapDef = self:locate(wx, wz)
  if not mapId then return nil end
  local Collision = self.engine("src.core.game3.collision")
  if not (Collision and Collision.elevationOn) then return nil end
  local ok, v = pcall(Collision.elevationOn, mapDef, lx, lz)
  if ok then return v end
  return nil
end

HostApi.RAYCAST_STEP = 0.05

-- origin/dir = {x,y,z} (root cells). Heightfield march + binary-search
-- refine against Scene:heightAt, with a coarse wall check against
-- isWalkable while still above the ground plane (DESIGN 2a world.raycast).
-- No CPU triangle data survives mesh upload (see reading notes), so this is
-- necessarily an approximation, not a true triangle raycast.
function HostApi:raycast(origin, dir, maxDist)
  if not (self.scene and origin and dir) then return nil end
  local ox, oy, oz = origin.x or origin[1] or 0, origin.y or origin[2] or 0, origin.z or origin[3] or 0
  local dx, dy, dz = dir.x or dir[1] or 0, dir.y or dir[2] or 0, dir.z or dir[3] or 0
  local len = math.sqrt(dx * dx + dy * dy + dz * dz)
  if len < 1e-9 then return nil end
  dx, dy, dz = dx / len, dy / len, dz / len
  maxDist = tonumber(maxDist) or 20
  local step = HostApi.RAYCAST_STEP
  local t = 0
  while t <= maxDist do
    local wx, wy, wz = ox + dx * t, oy + dy * t, oz + dz * t
    local ground = self:heightAt(wx, wz)
    if ground ~= nil then
      if wy <= ground then
        local lo, hi = math.max(0, t - step), t
        for _ = 1, 24 do
          local mid = (lo + hi) / 2
          local my = oy + dy * mid
          local g = self:heightAt(ox + dx * mid, oz + dz * mid)
          if g ~= nil and my <= g then hi = mid else lo = mid end
        end
        local hx, hy, hz = ox + dx * hi, oy + dy * hi, oz + dz * hi
        local hGround = self:heightAt(hx, hz) or ground
        return { pos = { x = hx, y = hGround, z = hz }, normal = { x = 0, y = 1, z = 0 },
          dist = hi, cell = { wx = math.floor(hx), wz = math.floor(hz) }, kind = "ground" }
      end
      local walkable = self:isWalkable(wx, wz)
      if walkable == false then
        return { pos = { x = wx, y = wy, z = wz }, normal = { x = 0, y = 0, z = 0 },
          dist = t, cell = { wx = math.floor(wx), wz = math.floor(wz) }, kind = "wall" }
      end
    end
    t = t + step
  end
  return nil
end

function HostApi:rootId()
  return self.scene and self.scene.rootId or nil
end

------------------------------------------------------------ actors
function HostApi:player()
  local ok, p = pcall(Actors.player)
  if ok and p then
    local copy={};for k,v in pairs(p)do copy[k]=v end
    if self.scene then copy.x,copy.ground,copy.z=self.scene:nativeToWorld(p.x,p.z)end
    return copy
  end
  return nil
end

function HostApi:actorsList(game)
  local ok, list = pcall(Actors.collect, game)
  if not ok then return {} end
  local out = {}
  for i, r in ipairs(list) do
    local x,_,z=r.x,nil,r.z
    if self.scene then x,_,z=self.scene:nativeToWorld(r.x,r.z)end
    out[i] = { x = x, z = z, gid = r.gid, facing = r.facing, walkPhase = r.walkPhase,
      stepFlip = r.stepFlip, player = r.player, liftPx = r.liftPx,
      key = r.key, kind = r.kind } -- W5 (owmons): provider records carry key/kind, gid nil
  end
  return out
end

-- W5 (owmons): this frame's hit targets, built by Billboards:prepare from
-- the same numbers as each provider card: { frame, list = { { key, kind,
-- catchable, center = {x,y,z}, width, height, base, ground, facing,
-- frame } } }, root cells, Y up. Empty before the first 3D frame; while no
-- 3D frame is prepared it keeps the last list and .frame stops advancing,
-- so a caller that sees the same .frame again should treat it as stale.
-- The live renderer's Billboards registers itself (Billboards.current,
-- cleared on release), so this needs no main.lua wiring.
function HostApi:targets()
  local bb = self.billboards
  if not bb then
    local okB, BB = pcall(V.require, "render/Billboards")
    bb = okB and type(BB) == "table" and BB.current or nil
  end
  if not (bb and bb.targetsSnapshot) then return { frame = 0, list = {} } end
  local ok, snap = pcall(bb.targetsSnapshot, bb)
  if ok and type(snap) == "table" then return snap end
  return { frame = 0, list = {} }
end

------------------------------------------------------------ input: snapshot/pulse
function HostApi:snapshot()
  return self.mockControls or self.lastControls
end

function HostApi:pulse(side, amplitude, seconds)
  if side ~= "left" and side ~= "right" then return false, "bad side" end
  amplitude = tonumber(amplitude)
  seconds = tonumber(seconds)
  if not (amplitude and amplitude > 0 and amplitude <= 0.35) then return false, "bad amplitude" end
  if not (seconds and seconds > 0 and seconds <= 0.2) then return false, "bad seconds" end
  local xr = self.xr
  local vr = xr and type(xr.handle) == "function" and xr:handle()
  if not (vr and vr.XR and vr.XR.pulse) then return false, "no-handle" end
  local ok, result = pcall(vr.XR.pulse, side, amplitude, seconds)
  if not ok then return false, result end
  return result ~= false
end

function HostApi:setMockControls(controls)
  if self.android then return false, "desktop only" end
  self.mockControls = controls
  return true
end

------------------------------------------------------------ state / panel
function HostApi:state()
  local xr = self.xr
  local cam = self.camera
  local metresPerCell = nil
  if cam then
    local ok, m = pcall(cam.metresPerCell, cam)
    if ok then metresPerCell = m end
  end
  return {
    xr = xr and xr.state or "idle",
    started = xr and xr.started == true or false,
    stereo = self.worldActive,
    mode = cam and cam.mode or nil,
    metresPerCell = metresPerCell,
    field = self.field,
    battle = self.battle, -- W6
    menuOpen = self.menuOpen,
    rootId = self:rootId(),
    failed = self.failed,
    android = self.android,
  }
end

-- W6 (battle P-B1): read-only view of the 3D battle presenter
-- (vrHost.battle.state / .stage). Plain data; never nil.
function HostApi:battleState()
  local bp = self.battlePass
  if not (bp and bp.status) then return { available = false, active = false, state = "none" } end
  local ok, st = pcall(bp.status, bp)
  if not ok or type(st) ~= "table" then
    return { available = true, active = false, state = "error", error = tostring(st) }
  end
  st.available = true
  st.active = st.state ~= "idle"
  return st
end

function HostApi:battleStage()
  local bp = self.battlePass
  if not (bp and bp.stageSummary) then return nil end
  local ok, s = pcall(bp.stageSummary, bp)
  if ok then return s end
  return nil
end

-- W6: throwing a Poke Ball into a battle from VR (battle/BattleCatch.lua;
-- the P-B4 VRITK physical throw). Queues the same command the BAG menu
-- would; the engine does the rest (stock, trainer/ghost blocking, catch).
function HostApi:battleCatch()
  if self._battleCatch == nil then
    local ok, BC = pcall(V.require, "battle/BattleCatch")
    self._battleCatch = (ok and type(BC) == "table") and BC.new({ log = self.log }) or false
  end
  return self._battleCatch or nil
end

function HostApi:battleCanThrow(itemId)
  local bc = self:battleCatch()
  if not bc then return false, "unavailable" end
  local ok, a, b, c = pcall(bc.canThrow, bc, itemId)
  if not ok then return false, tostring(a) end
  return a, b, c
end

function HostApi:battleThrowBall(itemId)
  local bc = self:battleCatch()
  if not bc then return false, "unavailable" end
  local ok, a, b = pcall(bc.throw, bc, itemId)
  if not ok then return false, tostring(a) end
  return a, b
end

------------------------------------------------------------ atmos: clock, emissive, atmosphere
-- worker "atmos" (vrHost 1.2, DESIGN.md 4.4 B). "The highest live provider
-- wins": TWS's Gen3 compat layer registers at priority 100, FRLG_RTC_BRIDGE
-- at priority 10 (DESIGN.md 6.1); the resolved clock is whichever
-- registered fn() call succeeds and returns a table with a numeric .hour,
-- highest priority first. A provider that errors or returns nothing this
-- frame is skipped (not unregistered), so a transient hiccup does not drop
-- the world to identity time for a frame.
local function resortIds(order, byId)
  local list = {}
  for id in pairs(byId) do list[#list + 1] = id end
  table.sort(list, function(a, b) return byId[a].priority > byId[b].priority end)
  for i, id in ipairs(list) do order[i] = id end
  for i = #list + 1, #order do order[i] = nil end
end

function HostApi:registerClock(id, fn, priority)
  if type(id) ~= "string" or id == "" or type(fn) ~= "function" then return false, "bad args" end
  self.dayClocks[id] = { fn = fn, priority = tonumber(priority) or 0 }
  resortIds(self.dayClockOrder, self.dayClocks)
  return true
end

function HostApi:unregisterClock(id)
  if not self.dayClocks[id] then return false end
  self.dayClocks[id] = nil
  resortIds(self.dayClockOrder, self.dayClocks)
  return true
end

-- Returns {hour, period, source, ...} from the highest-priority live
-- provider (its own fn() result, whatever shape it likes; DESIGN.md 4.4 B
-- only requires a numeric .hour), and that provider's id, or nil when none
-- is registered / all failed this call.
function HostApi:resolveClock()
  for _, id in ipairs(self.dayClockOrder) do
    local e = self.dayClocks[id]
    if e then
      local ok, result = pcall(e.fn)
      if ok and type(result) == "table" and type(result.hour) == "number" then
        return result, id
      end
    end
  end
  return nil
end

function HostApi:registerEmissiveProvider(id, provider)
  if type(id) ~= "string" or id == "" or type(provider) ~= "table" then return false, "bad args" end
  self.emissiveProviders[id] = provider
  local found = false
  for _, existing in ipairs(self.emissiveProviderOrder) do if existing == id then found = true end end
  if not found then self.emissiveProviderOrder[#self.emissiveProviderOrder + 1] = id end
  return true
end

function HostApi:unregisterEmissiveProvider(id)
  if not self.emissiveProviders[id] then return false end
  self.emissiveProviders[id] = nil
  return true
end

-- The most recently registered live provider (v1 expects at most one: BR).
function HostApi:emissiveProvider()
  for i = #self.emissiveProviderOrder, 1, -1 do
    local id = self.emissiveProviderOrder[i]
    local p = self.emissiveProviders[id]
    if p then return p end
  end
  return nil
end

-- Set once per frame by the View.lua anchored edit, right after
-- render/AtmosState.lua's compute() runs; read-only to everyone else.
function HostApi:publishAtmosphere(state)
  self.atmosphereState = state
end

function HostApi:atmosphere()
  return self.atmosphereState
end

-- Debug-only forced hour (DESIGN.md 2.7 "Forcing hours for proofs (desktop
-- only)"; Question 2 default: "no time preview in normal play ... forced
-- hours only in a desktop proof harness that never ships"). Registered at
-- the lowest priority, so a real RTC/TWS/BR clock provider always wins when
-- one is loaded; nothing in the shipped game calls this, exactly like
-- vrHost.debug.setMockControls above it. hour = nil clears the override.
function HostApi:debugForceHour(hour)
  if hour == nil then
    self:unregisterClock("debug-force-hour")
    return true
  end
  local h = tonumber(hour)
  if not h then return false, "not a number" end
  return self:registerClock("debug-force-hour", function() return { hour = h, source = "debug" } end, -1000)
end

function HostApi:panelState()
  return { menuOpen = self.menuOpen, field = self.field, worldActive = self.worldActive,
    failed = self.failed }
end

-- Gen3 dex scanner (2026-10-02): vrHost.camera.render(eye, w, h, opts) draws
-- one extra small view of the frame View:prepare already set up (same maps,
-- cards, sky and light) into the "tablet-camera" canvas and returns it, for
-- the Kanto Gear tablet's live Pokedex camera (VRITK_FRLG_HOST's
-- Gen3TabletCamera calls it inside its layer update, the same window the
-- Crystal host renders its tablet camera in). eye = { pose = LOCAL {pos,
-- quat}, fov = {angleLeft, angleRight, angleUp, angleDown} } (an XR eye's
-- shape). No vrHost layer slot, card, battle or veil is drawn into it (the
-- tablet must not film itself). opts.farCells shortens the draw distance for
-- this view only. Returns canvas, nil, { calls, tris } | nil, reason.
HostApi.CAMERA_MAX_PX = 512
local function finiteNum(n) return type(n) == "number" and n == n and n > -math.huge and n < math.huge end
function HostApi:renderCameraView(eye, w, h, opts)
  local view = self.view
  if not (view and view.prepared) then return nil, "view-not-prepared" end
  local pose, fov = type(eye) == "table" and eye.pose, type(eye) == "table" and eye.fov
  if type(pose) ~= "table" or type(fov) ~= "table" or type(pose.pos) ~= "table"
      or type(pose.quat) ~= "table" then return nil, "invalid-eye" end
  local p, q = pose.pos, pose.quat
  if not (finiteNum(p[1]) and finiteNum(p[2]) and finiteNum(p[3]) and finiteNum(q[1])
      and finiteNum(q[2]) and finiteNum(q[3]) and finiteNum(q[4]) and finiteNum(fov.angleLeft)
      and finiteNum(fov.angleRight) and finiteNum(fov.angleUp) and finiteNum(fov.angleDown)) then
    return nil, "invalid-eye"
  end
  w, h = math.floor(tonumber(w) or 0), math.floor(tonumber(h) or 0)
  if w < 8 or h < 8 or w > HostApi.CAMERA_MAX_PX or h > HostApi.CAMERA_MAX_PX then
    return nil, "invalid-size"
  end
  local canvas = view:canvas("tablet-camera", w, h)
  if not canvas then return nil, "canvas-unavailable" end
  local far, savedFar = opts and tonumber(opts.farCells), view.farCells
  if far and far > 0 and (savedFar == nil or far < savedFar) then view.farCells = far end
  -- Lab 52 review D1: PORTAL_MR's per-eye seams (capture/eyeTarget/props)
  -- are keyed by the XR eye index; this extra view has none, and
  -- PortalSession:capture(nil) raises. Hide the portal session for this one
  -- render: the tablet camera films the world without portal clip/capture.
  local okMr, MrLink = pcall(V.require, "quest/MrLink")
  local mrSaved = okMr and type(MrLink) == "table" and MrLink.s or nil
  if mrSaved then MrLink.s = nil end
  local ok, a, b = pcall(view.renderEye, view, canvas, {
    pose = { pos = { p[1], p[2], p[3] }, quat = { q[1], q[2], q[3], q[4] } },
    fov = { angleLeft = fov.angleLeft, angleRight = fov.angleRight,
      angleUp = fov.angleUp, angleDown = fov.angleDown },
  }, {})
  if mrSaved and MrLink.s == nil then MrLink.s = mrSaved end
  view.farCells = savedFar
  if not ok then return nil, "render error: " .. tostring(a) end
  if not a then return nil, tostring(b) end
  return canvas, nil, { calls = view.eyeCalls, tris = view.eyeTris }
end

------------------------------------------------------------ exports table
function HostApi:_buildExports()
  local self_ = self
  return {
    api = HostApi.API,
    version = HostApi.VERSION,
    state = function() return self_:state() end,
    layers = {
      register = function(id, layer) return self_.layers:register(id, layer) end,
      unregister = function(id, layer) return self_.layers:unregister(id, layer) end,
      debugState = function() return self_.layers:debugState() end,
    },
    input = {
      snapshot = function() return self_:snapshot() end,
      pulse = function(side, amp, sec) return self_:pulse(side, amp, sec) end,
      claim = function(ownerId, mask) return self_.claims:claim(ownerId, mask) end,
      setProfile = function(profile) return self_.claims:setProfile(profile) end,
      mapping = function()
        return { a = "A", b = "B", start = "START", triggerL = "SELECT",
          gripL = "L", gripR = "R", moveStick = "DPAD", lookStick = "SNAP" }
      end,
    },
    debug = {
      setMockControls = function(controls) return self_:setMockControls(controls) end,
      forceHour = function(hour) return self_:debugForceHour(hour) end, -- worker "atmos"
    },
    world = {
      heightAt = function(wx, wz) return self_:heightAt(wx, wz) end,
      locate = function(wx, wz) return self_:locate(wx, wz) end,
      isWater = function(wx, wz) return self_:isWater(wx, wz) end,
      vegetationAt = function(wx, wz) return self_:vegetationAt(wx, wz) end,
      isWalkable = function(wx, wz) return self_:isWalkable(wx, wz) end,
      behavior = function(wx, wz) return self_:behavior(wx, wz) end,
      elevation = function(wx, wz) return self_:elevation(wx, wz) end,
      raycast = function(origin, dir, maxDist) return self_:raycast(origin, dir, maxDist) end,
      rootId = function() return self_:rootId() end,
    },
    actors = {
      player = function() return self_:player() end,
      list = function(game) return self_:actorsList(game) end,
      -- W5 (owmons), vrHost 1.1: other mods hand the 3D view extra cards
      -- (data/Actors.lua registerProvider contract) and read back hit targets
      registerProvider = function(id, provider) return Actors.registerProvider(id, provider) end,
      unregisterProvider = function(id) return Actors.unregisterProvider(id) end,
      targets = function() return self_:targets() end,
      -- Track C (Lab 54): what a provider record may carry beyond W5's pose
      -- contract (render/Billboards.lua prepareExternal). color = a 10th pose
      -- return or rec.color {r,g,b,a} multiplied into the card; premultiplied =
      -- rec.premultiplied draws that card with premultiplied alpha; lifeSize =
      -- every external card uses the first-person card scale (no native pixel
      -- scale on FireRed: the user's life-size rule).
      capabilities = { color = true, premultiplied = true, lifeSize = true },
    },
    battle = { -- W6 (battle P-B1)
      state = function() return self_:battleState() end,
      stage = function() return self_:battleStage() end,
      canThrow = function(itemId) return self_:battleCanThrow(itemId) end,
      throwBall = function(itemId) return self_:battleThrowBall(itemId) end,
    },
    clock = { -- worker "atmos" (vrHost 1.2, DESIGN.md 4.4 B)
      register = function(id, fn, priority) return self_:registerClock(id, fn, priority) end,
      unregister = function(id) return self_:unregisterClock(id) end,
      get = function() return self_:resolveClock() end,
    },
    emissive = { -- worker "atmos" (vrHost 1.2)
      registerProvider = function(id, p) return self_:registerEmissiveProvider(id, p) end,
      unregisterProvider = function(id) return self_:unregisterEmissiveProvider(id) end,
    },
    atmosphere = { -- worker "atmos" (vrHost 1.2)
      get = function() return self_:atmosphere() end,
    },
    camera = { -- Gen3 dex scanner (2026-10-02): the tablet's live camera
      render = function(eye, w, h, opts) return self_:renderCameraView(eye, w, h, opts) end,
    },
    panel = {
      state = function() return self_:panelState() end,
      quadPose = function() return nil end, -- GAP: needs XRSession:_panelPose exported (P4)
    },
  }
end

return HostApi
