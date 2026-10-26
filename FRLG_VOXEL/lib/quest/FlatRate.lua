-- FRLG_VOXEL: FLAT DRAW RATE (Lab 49). In VR, with the 3D field shown and no
-- menu, text or flat-only effect up, the engine's flat 2D frame (field plane,
-- world OAM, UI plane and the flat copies) is not visible to the player: the
-- flat copy feeds only the PANEL quad and the in-scene card reads the UI canvas.
-- This draws that flat frame on every Nth frame only and keeps the previous
-- canvases in between.
--
-- One wrapper on the engine module function src.core.game3.display.present,
-- installed BELOW FramePacer's displayPresent probe (main.lua installs it
-- before the pacer exists), so the probe still times what actually ran.
--
-- render.compose runs INSIDE Display.present (Renderer:endFrame). Gear's
-- watch/tablet and VRITK need that chain on every frame, and main.lua's own
-- compose hook is what tells the Quest frame that the field is live. So a
-- skipped frame still runs the compose chain through the engine's own
-- Runtime.call, with a fresh copy of the last real frame's ctx (worldActive
-- true: a frame is only skipped on the field path). main.lua's compose hook
-- asks isSkipFrame() to leave its flat PANEL copy alone on those frames.
--
-- Safety: a frame draws unless EVERY condition (deps.eligible) holds on this
-- frame AND held on the frame before with the same map signature, and the
-- frame number is not a multiple of the rate. Any error in the decision or in
-- the compose replay draws the original frame instead. Counters are per pacer
-- window (takeCounts) so headset logs prove the throttle ran.
local V = ...
local _ = V

local M = {}
local watchSource
local wearCounts={invalidState=0,notAttempted=0,admitted=0,unknown=0,callbackError=0}
local function takeWearCounts()
  local line=('invalidState=%d notAttempted=%d admitted=%d unknown=%d callbackError=%d'):format(wearCounts.invalidState,wearCounts.notAttempted,wearCounts.admitted,wearCounts.unknown,wearCounts.callbackError)
  local total=wearCounts.invalidState+wearCounts.notAttempted+wearCounts.admitted+wearCounts.unknown+wearCounts.callbackError
  wearCounts.invalidState,wearCounts.notAttempted,wearCounts.admitted,wearCounts.unknown,wearCounts.callbackError=0,0,0,0,0
  return 'total='..total..' '..line
end

M.RATES = { ["1"] = 1, ["2"] = 2, ["3"] = 3 }
M.DEFAULT = "3"
M.HOOK_KEY = "_frlgVoxelFlatRate"

-- Option value -> 1/2/3. nil or unknown = the schema default (what the
-- OPTION row shows for it too: VrControls.current falls back to the default).
function M.parse(value)
  local n = M.RATES[tostring(value)]
  if n then return n end
  return M.RATES[M.DEFAULT]
end

M.REASON_KEYS = { "xr", "world", "wear", "field", "menu", "battle", "battleWant", "effects", "overlay", "monPic", "planes", "ineligible", "gateError", "decisionError", "firstEligible", "signature", "fullRate", "frameUnknown", "scheduled", "watchUnknown", "watchError", "watchDue", "skip", "replayMissing", "replayError", "replayScope" }
local function newReasons()
  local t={}
  for i=1,#M.REASON_KEYS do t[M.REASON_KEYS[i]]=0 end
  return t
end
local FR = {}
FR.__index = FR

-- deps = {
--   eligible = fn() -> ok(bool), sigA, sigB   (all skip conditions; sig = map identity)
--   frame    = fn() -> integer frame number
--   compose  = fn(renderer, ctx) -> runs the engine render.compose chain
--   before   = fn() optional, run before the replay (engine canvas target)
--   log      = fn(text) optional
-- }
function M.new(deps)
  deps = deps or {}
  return setmetatable({
    deps = deps, rate = M.parse(deps.rate), log = deps.log or function() end,
    prevEligible = false, prevA = nil, prevB = nil,
    skipFrame = nil, snap = nil, snapRenderer = nil,
    drawn = 0, skipped = 0, fallbacks = 0, gateErrors = 0,
    totalDrawn = 0, totalSkipped = 0, warned = {}, reasons = newReasons(),
  }, FR)
end

function FR:_warn(key, text)
  if self.warned[key] then return end
  self.warned[key] = true
  pcall(self.log, "flat draw rate: " .. tostring(text))
end

function FR:setRate(value)
  local n = M.parse(value)
  if n ~= self.rate then
    self.rate = n
    self.prevEligible = false -- the first frame after a change always draws
  end
  return n
end

-- Forget the previous frame (teardown, renderer rebuilt): the next frame draws.
function FR:reset()
  self.prevEligible, self.prevA, self.prevB = false, nil, nil
  self.skipFrame, self.snap, self.snapRenderer = nil, nil, nil
  watchSource=nil
end

-- The skip decision for this frame. Always records this frame's eligibility,
-- so a frame whose conditions changed is the drawn "first frame after".
function FR:shouldSkip(frame)
  local okE, eligible, a, b, gate = pcall(self.deps.eligible)
  if not okE then
    self.gateErrors = self.gateErrors + 1
    self:_warn("gate", "eligibility check failed, drawing every frame it fails: " .. tostring(eligible))
    eligible, a, b, gate = false, nil, nil, "gateError"
  end
  eligible = eligible == true
  local n = self.rate
  local skip = eligible and self.prevEligible and a == self.prevA and b == self.prevB
    and n > 1 and type(frame) == "number" and frame % n ~= 0
  -- Attribute existing decisions only; no extra eligibility/provider calls.
  local reason
  if not eligible then reason=self.reasons[gate]~=nil and gate or "ineligible"
  elseif not self.prevEligible then reason="firstEligible"
  elseif a~=self.prevA or b~=self.prevB then reason="signature"
  elseif n<=1 then reason="fullRate"
  elseif type(frame)~="number" then reason="frameUnknown"
  elseif frame%n==0 then reason="scheduled"
  else reason="skip" end
  if skip and watchSource then
    -- Recheck at Display.present, after game update. A queued map refresh
    -- draws the native source before compose copies it in this same frame.
    -- Keep this separate from prevEligible: one refresh does not require an
    -- extra full-rate follow-up frame. Unknown/failed callbacks draw safely.
    local ok,needed=pcall(watchSource.navigationMapNeeded)
    if not ok or needed~=false then skip=false;reason=not ok and "watchError" or (needed==true and "watchDue" or "watchUnknown") end
  end
  self.prevEligible, self.prevA, self.prevB = eligible, a, b
  return skip and true or false, reason
end

function FR:isSkipFrame(frame)
  return frame ~= nil and self.skipFrame == frame
end

-- The pristine ctx of a real frame (main.lua's compose hook is the outermost
-- link, so nothing downstream has rewritten it yet). Reused snapshot table.
function FR:capture(renderer, ctx)
  if type(ctx) ~= "table" then return end
  local snap = self.snap
  if snap then
    for k in pairs(snap) do snap[k] = nil end
  else
    snap = {}
    self.snap = snap
  end
  for k, v in pairs(ctx) do snap[k] = v end
  self.snapRenderer = renderer or ctx.renderer
end

-- Run the compose chain for a skipped frame. -> true when it ran.
function FR:_replay(frame)
  local snap = self.snap
  if not snap then return false end
  local ctx = {}
  for k, v in pairs(snap) do ctx[k] = v end
  ctx.worldActive = true
  self.skipFrame = frame
  if self.deps.before then self.deps.before() end
  self.deps.compose(self.snapRenderer or ctx.renderer, ctx)
  return true
end

-- The Display.present replacement body. orig = the function it wraps.
function FR:present(orig, ...)
  local frame
  local okF, f = pcall(self.deps.frame)
  if okF then frame = f end
  local okS, skip, reason = pcall(self.shouldSkip, self, frame)
  if not okS then
    self.gateErrors = self.gateErrors + 1
    self.prevEligible = false
    self:_warn("decide", "skip decision failed: " .. tostring(skip))
    skip = false
    reason = "decisionError"
  end
  if skip then
    -- The watch keeps its last map during replay, including a clock or HUD
    -- refresh discovered after an arbitrarily slow compose callback. Capture
    -- the atomic setter so teardown/rebinding cannot prevent scope cleanup.
    local source=watchSource
    local mode=source and source.navigationSourceMode
    local resetMode=source and source.navigationSourceReset
    local scoped,previous=true,nil
    if source then scoped,previous=pcall(mode,false)end
    local okR,ran
    if scoped then okR,ran=pcall(self._replay,self,frame)
    else okR,ran=false,'watch source-mode binding unavailable'end
    if mode and scoped then
      local restored,why=pcall(mode,previous)
      if not restored then pcall(resetMode);okR,ran=false,why end
    end
    if source and not scoped then pcall(resetMode)end
    if okR and ran then
      self.skipped, self.totalSkipped = self.skipped + 1, self.totalSkipped + 1
      self.reasons.skip=self.reasons.skip+1
      return true
    end
    -- Nothing skipped after all: draw the real frame (its own compose runs).
    self.skipFrame = nil
    self.prevEligible = false
    self.fallbacks = self.fallbacks + 1
    reason = not scoped and "replayScope" or (okR and not ran and "replayMissing" or "replayError")
    if not okR then self:_warn("replay", "compose replay failed, drew the frame: " .. tostring(ran)) end
  else
    self.skipFrame = nil
  end
  self.reasons[reason or "decisionError"] = self.reasons[reason or "decisionError"] + 1
  self.drawn, self.totalDrawn = self.drawn + 1, self.totalDrawn + 1
  return orig(...)
end

-- Per pacer window: drawn, skipped, fallbacks, gate errors, rate. Resets.
function FR:takeCounts()
  local d, s, f, e = self.drawn, self.skipped, self.fallbacks, self.gateErrors
  self.drawn, self.skipped, self.fallbacks, self.gateErrors = 0, 0, 0, 0
  local parts,total={},0
  for i=1,#M.REASON_KEYS do
    local key=M.REASON_KEYS[i];local count=self.reasons[key]
    total=total+count;parts[i]=key.."="..count;self.reasons[key]=0
  end
  local navContract,navSource
  if self.deps.navigationCounts then
    local ok,c,v=pcall(self.deps.navigationCounts)
    if ok then navContract,navSource=c,v else navContract='reportError';navSource='reportError' end
  end
  return d, s, f, e, self.rate, table.concat(parts," "), total,takeWearCounts(),navContract,navSource
end

-- Install on the engine's Display module. Idempotent per process: the module
-- outlives a mod reload, so a second install only rebinds the owner. A nil
-- owner (uninstall) makes the wrapper a plain pass-through.
function M.install(Display, owner)
  if type(Display) ~= "table" then return false, "no display module" end
  local hook = rawget(Display, M.HOOK_KEY)
  if type(hook) == "table" then
    hook.owner = owner
    return true, "rebound"
  end
  local orig = Display.present
  if type(orig) ~= "function" then return false, "no Display.present" end
  hook = { owner = owner, orig = orig }
  hook.fn = function(...)
    local o = hook.owner
    if not o then return hook.orig(...) end
    return o:present(hook.orig, ...)
  end
  rawset(Display, M.HOOK_KEY, hook)
  Display.present = hook.fn
  return true, "installed"
end

function M.uninstall(Display, owner)
  local hook = type(Display) == "table" and rawget(Display, M.HOOK_KEY) or nil
  if type(hook) == "table" and (owner == nil or hook.owner == owner) then hook.owner = nil end
end

-- Lab 50 (headset: "Yeah the tablet lags this way"): Kanto Gear's watch and
-- tablet are refreshed from the render.compose chain inside Display.present,
-- and Gear also reads the session position mirror that the flat FieldView
-- draw writes. While either device can be on screen, every frame draws.
-- wearableVisible(info) answers from the last Quest frame:
--   info = { gear = true|false|nil   kanto_gear loaded (nil = not known yet)
--            tablet = VRITK compat.tablet table (active/presented) | nil
--            controls = XR.input table (handl = left controller pose) | nil
--            head = { pos = {x,y,z}, quat = {x,y,z,w} } | nil }
-- -> visible(bool), why. Fail-closed: anything unknown or malformed answers
-- "visible", so the frame draws. Only a confirmed absent Gear, or a tablet
-- that is not out plus a watch (left wrist) that is untracked or outside a
-- wide cone around the view direction, answers "not visible".
M.WEAR_HOLD_S = 1.0                      -- keep drawing this long after the last visible frame
M.WEAR_CONE_COS = math.cos(math.rad(75)) -- half-angle; wider than the Quest's field of view
M.WEAR_NEAR_M = 0.05                     -- a hand this close to the head counts as visible

local function num(v)
  v = tonumber(v)
  if v == nil or v ~= v or v == math.huge or v == -math.huge then return nil end
  return v
end

function M.wearableVisible(info)
  if type(info) ~= "table" then return true, "unknown" end
  if info.gear == false then return false, "no-gear" end
  if info.gear ~= true then return true, "gear-unknown" end
  local t = info.tablet
  if type(t) ~= "table" or type(t.active) ~= "function" then return true, "tablet-unknown" end
  local okA, a = pcall(t.active)
  if not okA then return true, "tablet-error" end
  if a then return true, "tablet" end
  if type(t.presented) == "function" then
    local okP, p = pcall(t.presented)
    if not okP then return true, "tablet-error" end
    if p then return true, "tablet" end
  end
  local c = info.controls
  if type(c) ~= "table" then return true, "controls-unknown" end
  local h = c.handl
  -- VRITK's VRHandPose: no pos/quat table = an untracked hand, and an
  -- untracked left hand draws no watch (QuestDeviceRenderer needs its pose)
  if type(h) ~= "table" or type(h.pos) ~= "table" or type(h.quat) ~= "table" then return false, "watch-untracked" end
  local head = info.head
  if type(head) ~= "table" or type(head.pos) ~= "table" or type(head.quat) ~= "table" then return true, "head-unknown" end
  local hx, hy, hz = num(h.pos[1]), num(h.pos[2]), num(h.pos[3])
  local ex, ey, ez = num(head.pos[1]), num(head.pos[2]), num(head.pos[3])
  local x, y, z, w = num(head.quat[1]), num(head.quat[2]), num(head.quat[3]), num(head.quat[4])
  if not (hx and hy and hz and ex and ey and ez and x and y and z and w) then return true, "pose-invalid" end
  local ql = math.sqrt(x * x + y * y + z * z + w * w)
  if ql < 1e-6 then return true, "pose-invalid" end
  x, y, z, w = x / ql, y / ql, z / ql, w / ql
  -- view direction: -Z rotated by the head quaternion (x, y, z, w)
  local fx, fy, fz = -2 * (w * y + x * z), 2 * (w * x - y * z), -1 + 2 * (x * x + y * y)
  local dx, dy, dz = hx - ex, hy - ey, hz - ez
  local d = math.sqrt(dx * dx + dy * dy + dz * dz)
  if d < M.WEAR_NEAR_M then return true, "watch-near" end
  if (dx * fx + dy * fy + dz * fz) / d >= M.WEAR_CONE_COS then return true, "watch-in-view" end
  return false, "watch-out-of-view"
end

-- One Quest frame's wearable state -> away(bool). st = the caller's state
-- table, now = seconds. Away only when not visible now AND no visible frame
-- within WEAR_HOLD_S. An error, or no clock, answers false (draw).
function M.wearStep(st, info, now)
  if type(st) ~= "table" then wearCounts.invalidState=wearCounts.invalidState+1;return false end
  watchSource=nil
  local okV, visible, why = pcall(M.wearableVisible, info)
  if not okV then visible, why = true, "error" end
  now = num(now)
  local tablet=type(info)=='table' and info.gear==true and info.tablet
  if now~=nil and (why=='watch-in-view' or why=='watch-near')
      and type(tablet)=='table' and type(tablet.navigationMapNeeded)=='function'
      and type(tablet.navigationSourceMode)=='function' and type(tablet.navigationSourceReset)=='function' then
    local ok,needed=pcall(tablet.navigationMapNeeded,true)
    if ok and type(needed)=='boolean' then
      wearCounts.admitted=wearCounts.admitted+1
      watchSource=tablet;st.why='watch-map-cadence'
      st.visibleFrames=(st.visibleFrames or 0)+1;st.lastVisible=now;st.holdPending=nil
      return true
    end
    if ok then wearCounts.unknown=wearCounts.unknown+1 else wearCounts.callbackError=wearCounts.callbackError+1 end
  else wearCounts.notAttempted=wearCounts.notAttempted+1 end
  st.why = why
  if visible then
    st.visibleFrames = (st.visibleFrames or 0) + 1
    if now ~= nil then st.lastVisible = now else st.holdPending = true end
    return false
  end
  if now == nil then return false end
  if st.holdPending then st.holdPending = nil; st.lastVisible = now; return false end
  if st.lastVisible ~= nil and now - st.lastVisible < M.WEAR_HOLD_S then return false end
  return true
end

M.FR = FR
return M
