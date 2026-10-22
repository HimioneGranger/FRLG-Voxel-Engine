-- FRLG_VOXEL: the Quest OpenXR frame loop, through the host-owned bounded
-- adapter mod.device.questVR ({ GL, XR }, src/host/android/QuestVR.lua).
-- Same order as the headset-proven Gen2 compat (BATTLE_ART_QUEST_COMPAT
-- lib/QuestStereo.lua): start -> poll -> waitFrame -> input -> locateViews ->
-- per-eye canvases blitted into the eye swapchains -> optional flat quad ->
-- endFrame. Nothing here may raise inside a frame; every host call is pcall'd.
--
-- Starting the session asks the native launcher to hand its OpenXR session
-- over (QuestNativeXR.start). From then on this mod owns what the headset
-- shows, so "flat fallback" inside a running session = PANEL mode: the full
-- game frame on a floating quad with no world layer, like the stock panel.
local V = ...
local Mat4 = V.require("render/Mat4")

local XRSession = {}
XRSession.__index = XRSession

XRSession.QUAD_W, XRSession.QUAD_H = 960, 640

XRSession.PROFILES = {
  performance = { eyeScale = 0.65, refreshRate = 72 },
  balanced = { eyeScale = 0.80, refreshRate = 72 },
  smooth90 = { eyeScale = 0.70, refreshRate = 90 },
  quality = { eyeScale = 1.00, refreshRate = 72 },
}

-- VR DISPLAY (battle-move part B, user 2026-10-01): the profile can also come from three plain settings
-- (VrControls.resolveDisplay): display = { swapScale (0.5-1.0, the eye swapchain relative to the runtime's
-- recommended size: the engine adapter and native side both refuse more than 1.0), renderScale (>= 1: the
-- mod renders its eye canvases this much larger and the blit into the swapchain shrinks them, so a
-- RESOLUTION above 100% is supersampling), refreshRate (Hz), foveation (true = the native MEDIUM level;
-- the binding has no other level) }.
XRSession.DISPLAY_DEFAULT = { swapScale = 1.0, renderScale = 1.0, refreshRate = 72, foveation = true }

local function isAndroid()
  local ok, os = pcall(function() return love.system.getOS() end)
  return ok and os == "Android"
end
XRSession.isAndroid = isAndroid

function XRSession.new(opts)
  return setmetatable({
    mod = opts.mod,
    log = opts.log or print,
    profileName = opts.profile or "balanced",
    display = opts.display, -- VR DISPLAY settings (nil = the old named profile)
    state = "idle",
    started = false,
    fbo = setmetatable({}, { __mode = "k" }),
    frames = 0, worldFrames = 0,
    capSaved = nil,
    panelYaw = nil,
    lastControls = nil, -- W4: last frame's XR.input() result, for HostApi.input.snapshot()
  }, XRSession)
end

function XRSession:handle()
  local device = self.mod and self.mod.device
  local vr = device and device.questVR
  if type(vr) == "table" and vr.XR and vr.GL then return vr end
  return nil
end

function XRSession:panelActive()
  local device = self.mod and self.mod.device
  if device and type(device.questPanelActive) == "function" then
    local ok, v = pcall(device.questPanelActive, device)
    if ok then return v == true end
  end
  return false
end

-- Why the session cannot run here (nil = it can).
function XRSession:unavailableReason()
  if not isAndroid() then return "not-android" end
  if not self:handle() then return "no-questVR-handle" end
  if not self:panelActive() then return "quest-panel-inactive" end
  return nil
end

-- Lab 51: engine-side settings, as plain booleans: hints = XR_KHR_android_thread_settings
-- + XR_EXT_performance_settings (read when the session starts), lean = the engine's
-- allocation-free XR event poll (live). Hosts without XR.configure ignore it.
function XRSession:configure(t)
  if type(t) ~= "table" then return false end
  local c = self.engineConfig or {}
  self.engineConfig = c
  if t.hints ~= nil then c.hints = t.hints == true end
  if t.lean ~= nil then c.lean = t.lean == true end
  local vr = self:handle()
  local fn = vr and vr.XR and vr.XR.configure
  if type(fn) ~= "function" then return false end
  local ok, res = pcall(fn, { hints = c.hints, lean = c.lean })
  return ok and res ~= false
end

function XRSession:start()
  if self.started then return true end
  local reason = self:unavailableReason()
  if reason then self.state = reason; return false, reason end
  if self.engineConfig then self:configure({}) end -- Lab 51: settings in place before XR.start
  local vr = self:handle()
  local profile = XRSession.PROFILES[self.profileName] or XRSession.PROFILES.balanced
  local foveation = true
  if type(self.display) == "table" then
    profile = { eyeScale = self.display.swapScale or 1.0, refreshRate = self.display.refreshRate or 72 }
    foveation = self.display.foveation ~= false
  end
  self.startedScale = profile.eyeScale
  local ok, started = pcall(vr.XR.start, XRSession.QUAD_W, XRSession.QUAD_H, profile.eyeScale)
  if not ok or not started then
    local okS, status = pcall(vr.XR.status)
    self.state = "start-failed: " .. tostring(okS and status or started)
    self.log("[FRLG_VOXEL] OpenXR start failed: " .. self.state)
    return false, self.state
  end
  self.started = true
  self.state = "session-created"
  self.refreshRate = profile.refreshRate
  local okR, applied = pcall(vr.XR.requestRefreshRate, profile.refreshRate)
  self.foveation = foveation
  pcall(vr.XR.setFixedFoveatedRendering, foveation)
  self.log(("[FRLG_VOXEL] Quest OpenXR session created: eyes %.0f%% (canvas x%.2f) at %d Hz (refresh request %s), foveation %s")
    :format(profile.eyeScale * 100, self:renderScale(), profile.refreshRate, tostring(okR and applied),
      foveation and "ON" or "OFF"))
  return true
end

-- How much larger than the eye swapchain the eye canvases are drawn (>= 1; 1 = same size). The blit into
-- the swapchain (GL_LINEAR, scaled) shrinks them. Read every frame, so it changes live.
function XRSession:renderScale()
  local d = self.display
  local rs = type(d) == "table" and tonumber(d.renderScale) or 1
  if not rs or rs ~= rs or rs < 1 then return 1 end
  return math.min(rs, 1.5)
end

-- Refresh rates the runtime reports (a sorted array of Hz), {} when unknown (no session, no extension, or the
-- runtime lists none). Read-only.
XRSession.RATES_CACHE_S = 2   -- the OPTION page asks every drawn frame; the native call enumerates
function XRSession:supportedRates()
  local vr = self:handle()
  if not (self.started and vr and vr.XR and type(vr.XR.refreshRates) == "function") then return {} end
  local now = os.clock()
  if self._rates and now - (self._ratesAt or 0) < XRSession.RATES_CACHE_S then return self._rates end
  local ok, list = pcall(vr.XR.refreshRates)
  local out = {}
  if ok and type(list) == "table" then
    for _, r in ipairs(list) do if tonumber(r) then out[#out + 1] = tonumber(r) end end
  end
  self._rates, self._ratesAt = out, now
  return out
end

-- Does the running session still hold a swapchain of another size than the settings ask for? (Resolution up
-- to 100% is the swapchain, fixed when the session starts; refresh rate, foveation and the supersampling
-- canvas scale above 100% change live.)
function XRSession:pendingRestart()
  local d = self.display
  if not (self.started and type(d) == "table" and self.startedScale) then return false end
  return math.abs((d.swapScale or 1) - self.startedScale) > 1e-6
end

-- Apply new VR DISPLAY settings to the running session. Refresh rate and foveation go to the headset now;
-- the swapchain size waits for the next session start (pendingRestart). -> { refresh = bool|nil, foveation = bool|nil }
function XRSession:applyDisplay(d)
  if type(d) ~= "table" then return {} end
  local old = self.display
  self.display = d
  local out = {}
  local vr = self:handle()
  if not (self.started and vr) then return out end
  if not old or old.refreshRate ~= d.refreshRate then
    local ok, applied = pcall(vr.XR.requestRefreshRate, d.refreshRate)
    out.refresh = ok and applied ~= false
    self.refreshRate = d.refreshRate
  end
  if not old or old.foveation ~= d.foveation then
    local ok, applied = pcall(vr.XR.setFixedFoveatedRendering, d.foveation ~= false)
    out.foveation = ok and applied ~= false
    self.foveation = d.foveation ~= false
  end
  self.log(("[FRLG_VOXEL] VR display settings applied live: refresh %s, foveation %s, canvas x%.2f%s")
    :format(tostring(out.refresh), tostring(out.foveation), self:renderScale(),
      self:pendingRestart() and " (eye resolution waits for the next session start)" or ""))
  return out
end

-- Keep the engine's software frame cap from pacing below the headset
-- refresh (FrameCap defaults to 60; xrWaitFrame paces the loop instead).
function XRSession:_assertFrameCap()
  local ok, FrameCap = pcall(require, "src.core.FrameCap")
  if not (ok and type(FrameCap) == "table") then return end
  local rate = self.refreshRate or 72
  local want = rate >= 110 and 130 or (rate >= 90 and 100 or 75)
  if self.capSaved == nil then self.capSaved = FrameCap.current end
  if FrameCap.current ~= want then FrameCap.current = want end
end

function XRSession:_restoreFrameCap()
  if self.capSaved == nil then return end
  local ok, FrameCap = pcall(require, "src.core.FrameCap")
  if ok and type(FrameCap) == "table" then FrameCap.current = self.capSaved end
  self.capSaved = nil
end

local function pixelDimensions(canvas)
  if canvas.getPixelDimensions then return canvas:getPixelDimensions() end
  return canvas:getWidth(), canvas:getHeight()
end

function XRSession:_token(canvas)
  local t = self.fbo[canvas]
  if t then return t end
  local vr = self:handle()
  local ok, token = pcall(vr.GL.canvasFBO, canvas)
  if ok and token then self.fbo[canvas] = token; return token end
  return nil
end

function XRSession:_submitEyes(canvases)
  local vr = self:handle()
  for index = 1, 2 do
    local canvas = canvases[index]
    local ok, tex, tw, th = pcall(vr.XR.acquireEye, index)
    if not ok or not tex then return false, "eye-swapchain-unavailable" end
    local token = canvas and self:_token(canvas)
    local sw, sh = 0, 0
    if canvas then sw, sh = pixelDimensions(canvas) end
    local okB, copied = false, false
    if token then okB, copied = pcall(vr.GL.blitToTexture, token, sw, sh, tex, tw, th) end
    pcall(vr.XR.releaseEye, index)
    if not (okB and copied) then return false, "eye-blit-failed" end
  end
  return true
end

local function yawQuat(yaw)
  return { 0, math.sin(yaw / 2), 0, math.cos(yaw / 2) }
end

-- Quad in front of where the head looked when panel mode began.
function XRSession:_panelPose(views, reset)
  local pose = views and views[1] and views[1].pose
  -- Lab 59: while the "Preparing 3D world" screen is up (panelFollow, set by main.lua), a head that has turned well away
  -- from the panel, or walked away from it, brings it back in front of the player. Off otherwise: the Lab 57/58 pose.
  if self.panelFollow and pose and self.panelYaw and not reset then
    local d = (Mat4.quatYaw(pose.quat) - self.panelYaw + math.pi) % (2 * math.pi) - math.pi
    local b, p = self.panelBase, pose.pos
    if math.abs(d) > 1.0 or (b and p and ((p[1] - b[1]) ^ 2 + (p[3] - b[3]) ^ 2) > 0.64) then reset = true end
  end
  if reset or not self.panelYaw then
    self.panelYaw = pose and Mat4.quatYaw(pose.quat) or 0
    local p = pose and pose.pos or { 0, 0, 0 }
    self.panelBase = { p[1], p[2], p[3] }
  end
  local yaw = self.panelYaw
  local dist, drop = 1.25, 0.05
  local b = self.panelBase or { 0, 0, 0 }
  return {
    pos = { b[1] - math.sin(yaw) * dist, b[2] - drop, b[3] - math.cos(yaw) * dist },
    quat = yawQuat(yaw),
    width = 1.30,
  }
end

function XRSession:_copyQuad(canvas, views, reset)
  local vr = self:handle()
  local ok, tex, tw, th = pcall(vr.XR.acquireQuad)
  if not ok or not tex then return nil end
  local token = self:_token(canvas)
  local sw, sh = pixelDimensions(canvas)
  local okB, copied = false, false
  if token then okB, copied = pcall(vr.GL.blitToTexture, token, sw, sh, tex, tw, th) end
  pcall(vr.XR.releaseQuad)
  if not (okB and copied) then return nil end
  return self:_panelPose(views, reset)
end

-- Lab 60: has the head turned well away from the panel, or walked away from it? (hooks.panelFollow, set by main.lua while the
-- Loading screen is up: the panel is brought back in front of the player, with the same hysteresis as every other re-anchor.)
-- Mat4.quatYaw without its 16-slot matrix (this runs every Loading frame): the same yaw, no table.
local function quatYawFlat(q)
  if type(q) ~= "table" then return 0 end
  local x, y, z, w = tonumber(q[1]) or 0, tonumber(q[2]) or 0, tonumber(q[3]) or 0, tonumber(q[4]) or 1
  local len = math.sqrt(x * x + y * y + z * z + w * w)
  if len < 1e-12 then return 0 end
  x, y, z, w = x / len, y / len, z / len, w / len
  local m3, m11 = 2 * (x * z + w * y), 1 - 2 * (x * x + y * y)
  if m3 * m3 + m11 * m11 < 1e-9 then return 0 end
  return math.atan2(m3, m11)
end
XRSession._quatYawFlat = quatYawFlat -- test seam

function XRSession:_panelFar(views)
  local pose = views and views[1] and views[1].pose
  if not (pose and self.panelYaw and self.panelBase) then return false end
  local d = (quatYawFlat(pose.quat) - self.panelYaw + math.pi) % (2 * math.pi) - math.pi
  local b, p = self.panelBase, pose.pos
  return math.abs(d) > 1.0 or ((p[1] - b[1]) ^ 2 + (p[3] - b[3]) ^ 2) > 0.64
end

-- One headset frame.
--   hooks.renderEyes(views) -> { canvasL, canvasR } | nil, reason
--   hooks.panelCanvas()     -> canvas for the flat quad (panel mode) | nil
--   hooks.wantWorld         -> boolean: show the stereo world this frame
--   hooks.wantPanel         -> boolean: show the flat quad this frame
-- Returns controls (plain table from XR.input) and views, or nil, status.
function XRSession:frame(hooks)
  self.panelSubmitted = false
  if not self.started then return nil, self.state end
  local vr = self:handle()
  if not vr then return nil, "no-handle" end
  local okP, alive = pcall(vr.XR.poll)
  if not okP or not alive then
    self.log("[FRLG_VOXEL] OpenXR session lost")
    self:stop("session-lost")
    return nil, "session-lost"
  end
  local okR, running = pcall(vr.XR.isRunning)
  if not (okR and running) then self.state = "waiting-for-focus"; return nil, self.state end
  self:_assertFrameCap()
  local okW, token, shouldRender = pcall(vr.XR.waitFrame)
  if not okW or not token then return nil, "frame-wait-failed" end
  local okI, controls = pcall(vr.XR.input, token)
  if not okI then controls = nil end
  -- W4: cached for HostApi.input.snapshot() and so the renderEyes closure
  -- can reach this frame's controls without a second hook parameter.
  self.lastControls = controls
  local views
  local world = false
  local reason
  if shouldRender then
    local okV, v = pcall(vr.XR.locateViews, token)
    if okV then views = v end
    if hooks.mr then -- PORTAL_MR P1: hold/chord/setup; may rewrite the controls, may hold the world for setup
      controls = hooks.mr:begin(views, controls, token); self.lastControls = controls
      if hooks.mr:holdWorld() then hooks.wantWorld = false end
    end
    -- PortalSession.begin may change its read-only active/setup scalars now.
    if hooks.collector and hooks.mr then
      local safeMR=hooks.collector.mrInactive
      local ok,inactive=pcall(safeMR,hooks.mr)
      if not ok or inactive~=true then hooks.collector:cancel("MR active/unavailable") end
    end
    if views and hooks.wantWorld and hooks.renderEyes then
      local okE, canvases, why
      if hooks.collector then okE, canvases, why = hooks.collector:call(hooks.renderEyes, views)
      else okE, canvases, why = pcall(hooks.renderEyes, views) end
      if okE and canvases then
        if hooks.mr then canvases = hooks.mr:compose(canvases) end -- PORTAL_MR P1: the window (unchanged when not presented)
        world, reason = self:_submitEyes(canvases)
      else
        reason = okE and why or ("render error: " .. tostring(canvases))
      end
    end
  end
  local quad
  local wantPanel = hooks.wantPanel or not world
  local mrCard = hooks.mr and hooks.mr:card(XRSession.QUAD_W, XRSession.QUAD_H) -- PORTAL_MR P1: the setup card replaces the panel
  if mrCard then wantPanel = false end
  if shouldRender and wantPanel and hooks.panelCanvas then
    local okC, canvas = pcall(hooks.panelCanvas)
    if okC and canvas then
      local reset = not self.panelShown
      if not reset and hooks.panelFollow then reset = self:_panelFar(views) end -- Lab 60 (Loading screen)
      quad = self:_copyQuad(canvas, views, reset)
    end
  end
  if mrCard and mrCard.canvas and shouldRender and self:_copyQuad(mrCard.canvas, views, true) then quad = mrCard.pose end -- PORTAL_MR P1
  self.panelShown = quad ~= nil
  if hooks.mr and hooks.mr:submit(world == true) then -- PORTAL_MR P1: passthrough under the window this frame
    local ended, submitted = pcall(vr.XR.endFrame, token, world == true, quad, true)
    self.panelSubmitted = ended and submitted ~= false and quad ~= nil
  else
    local ended, submitted = pcall(vr.XR.endFrame, token, world == true, quad)
    self.panelSubmitted = ended and submitted ~= false and quad ~= nil
  end
  self.frames = self.frames + 1
  if world then self.worldFrames = self.worldFrames + 1 end
  self.state = world and "running-stereo" or "running-panel"
  self.lastReason = reason
  return controls, views, world, reason
end

function XRSession:stop(reason)
  self:_restoreFrameCap()
  local vr = self:handle()
  if self.started and vr then pcall(vr.XR.stop) end
  self.started = false
  self.state = reason or "stopped"
  -- W4 / CRITIQUE #12: a resumed session's first input read must come back
  -- nil, not the previous session's last controls.
  self.lastControls = nil
  for canvas in pairs(self.fbo) do self.fbo[canvas] = nil end
end

return XRSession
