-- FRLG_VOXEL: the resolved atmosphere for one frame (worker "atmos", GW-P1,
-- daynight-weather-hook/DESIGN.md 3.3). Pure composition: given the clock,
-- the DayNight facade's tint (looked up at call time so a TWS wrap applies,
-- DESIGN.md 3.3 step 2) and optional weather numbers, returns everything the
-- coordinator's View.lua/Shaders.lua anchored edits need to send this frame:
-- the shader grade, the shadow-fade terms, the sky palette, and the
-- emissive/pools gains. No love, no requires: pure tables in, pure table out
-- (same style as HostApi's pure rig/eye builders), so this is testable with
-- plain luajit and safe to call every frame with no allocation surprises
-- beyond the small tables it returns.
--
-- This module does NOT read a clock or a tint itself -- the caller (the
-- View.lua anchored edit, via vrHost.clock.get()/DayNight.tint from
-- WeatherHostLib) resolves those first and passes the numbers in. That
-- keeps AtmosState decoupled from vrHost.clock.register's provider
-- arbitration (HostApi.lua, coordinator-anchored) and from any TWS/RTC
-- presence, so it works identically whether TWS is loaded or not.
local V = ...
local AtmosTime = V.require("render/AtmosTime")
local AtmosSky = V.require("render/AtmosSky")

local AtmosState = {}

-- DESIGN.md 3.3 step 3: the lightning comfort cap. Independent of whether a
-- weather layer is even loaded (defaults make it a no-op).
AtmosState.FLASH_CAP = 0.35
AtmosState.MAX_FLASH_RISES_PER_SEC = 3

-- DESIGN.md 3.3 step 6: shadow-fade terms. At s=1 (sunShare = full day, no
-- overcast) these equal today's Light.TERMS {0.58, 0.50, 0.16} exactly
-- (CRITIQUE R9's fixed formula); the night grade does the darkening at
-- s=0, so this only reshapes face contrast, never re-darkens the world.
local function shadowTerms(s)
  return { 0.78 - 0.20 * s, 0.50 * (0.40 + 0.60 * s), 0.16 }
end
AtmosState.shadowTerms = shadowTerms

-- DESIGN.md 4.7: warm ground light pools. Coordinator review 2026-09-28
-- (against reference-user-20260928/videos-20260928/v17/v18): deepened
-- toward amber and re-saturated twice -- round 1 (1.0,0.85,0.6 -> 1.0,
-- 0.80,0.45) fixed the wall blow-out (v_up weighting) but still read pale
-- in a live capture (w8/captures/night_pallet_34.png: (127,148,155), still
-- blue-dominant) because the per-channel cap (0.30) was too conservative
-- once it was made hue-preserving (SH1/SH2's poolMax scale); round 2 raises
-- the cap to 0.42 and saturates the colour further so the pool reads as a
-- clear warm accent against the deep-blue ground instead of a pale wash.
AtmosState.POOL_COLOR = { 1.0, 0.45, 0.10 }

-- DESIGN.md 3.4/3.5, coordinator review 2026-09-28: windows read as warm
-- yellow at night regardless of the atlas's own (blue) glass colour --
-- matches Shaders.frame's identity default in the anchored patch (SH3).
AtmosState.EMIT_COLOR = { 1.0, 0.82, 0.42 }

-- Coordinator review round 2 (2026-09-28): open water (ponds, Sea.lua's
-- plane) stayed too vivid/bright at night; halved at full night weight
-- (Shaders.lua's waterK factor already restricts this to blue-dominant
-- texels only, so it never touches ground/wall/roof colours).
AtmosState.WATER_DARK = 0.5

local function clamp01(x) return x < 0 and 0 or (x > 1 and 1 or x) end
local function smooth01(a, b, x)
  local t = clamp01((x - a) / (b - a))
  return t * t * (3 - 2 * t)
end
local function min3(a, b) return { math.min(a[1], b[1]), math.min(a[2], b[2]), math.min(a[3], b[3]) } end

-- ctx = {
--   hour, outdoor (bool), preset ("tuned"|"rtc", default AtmosTime.DEFAULT_PRESET),
--   tint = {r,g,b}|nil (DayNight.tint(true) read at call time; nil = use the
--           time light unwrapped, e.g. no TWS layer loaded),
--   stormMul = number|nil (default 1; the un-flashed reference for the
--           comfort cap, DESIGN.md 3.3 step 3),
--   flash = 0..1|nil (already rate-limited by the caller; see FlashLimiter),
--   overcast = 0..1|nil (default 0),
--   hazeLevel = 0..1|nil (Voxel3D.weatherHazeLevel(), GW-P3),
--   fogDefaults = { start, end, max }|nil (View.FOG_START/END/MAX + focus,
--           only consulted when hazeLevel is given),
-- }
-- Returns nil, "indoor" when ctx.outdoor is false (caller keeps the fixed
-- indoor env unchanged, DESIGN.md 4.8: one rule for time light, weather,
-- windows and pools).
function AtmosState.compute(ctx)
  ctx = ctx or {}
  if ctx.outdoor == false then return nil, "indoor" end
  local hour = AtmosTime.wrapHour(ctx.hour)
  local time = AtmosTime.at(hour, ctx.preset)
  local tint = ctx.tint or time.mul
  local stormMul = tonumber(ctx.stormMul) or 1
  local flash = clamp01(tonumber(ctx.flash) or 0)

  -- step 3: grade.mul = min(tint, time * stormMul + FLASH_CAP); a no-op
  -- unless a weather layer's own tint pushed brightness past the cap.
  local ceiling = {
    time.mul[1] * stormMul + AtmosState.FLASH_CAP * flash,
    time.mul[2] * stormMul + AtmosState.FLASH_CAP * flash,
    time.mul[3] * stormMul + AtmosState.FLASH_CAP * flash,
  }
  local mul = min3(tint, ceiling)
  -- step 4: the night lift, faded out while a flash is on (a flash already
  -- reads as bright; stacking the readability lift on top would blow it out)
  local liftK = 1 - flash
  local add = { time.add[1] * liftK, time.add[2] * liftK, time.add[3] * liftK }

  -- step 6: shadow fade. sunShare = dayWeight * (1 - overcast).
  local overcast = clamp01(tonumber(ctx.overcast) or 0)
  local s = clamp01(time.dayWeight * (1 - overcast))
  local terms = shadowTerms(s)

  local sky = AtmosSky.at(hour, time.nightWeight, overcast, flash)

  -- DESIGN.md 4.7: emissive windows / warm pools ease in with night weight;
  -- the shader keeps its uniform branch for daytime (cost ~0 then).
  local nw = time.nightWeight
  local emissive = { on = nw > 0.01, gain = nw, color = AtmosState.EMIT_COLOR }
  local pools = { on = nw > 0.01, gain = nw, color = AtmosState.POOL_COLOR }
  -- coordinator review round 2 (2026-09-28): water darkens extra at night,
  -- same easing as emissive/pools (0 by day, full at night weight 1).
  local waterFade = nw

  -- step 5: haze -> fog (GW-P3; optional, only when a normalised haze level
  -- is supplied). fogEnd eases from the default toward 25 m as haze -> 1.
  local fog = nil
  if ctx.hazeLevel ~= nil then
    local h = clamp01(tonumber(ctx.hazeLevel) or 0)
    local d = ctx.fogDefaults or {}
    local fogEndDefault = tonumber(d["end"]) or 62
    local fogStart = tonumber(d.start) or 14
    local t = smooth01(0.15, 1, h)
    local fogEnd = fogEndDefault + (25 - fogEndDefault) * t
    fog = { start = fogStart, ["end"] = fogEnd, max = math.max(0.92, tonumber(d.max) or 0.92) }
  end

  return {
    mul = mul, add = add,
    terms = terms, shadowFade = s, sunShare = s,
    sky = sky,
    emissive = emissive, pools = pools,
    waterFade = waterFade, waterDark = AtmosState.WATER_DARK,
    fog = fog,
    period = time.period, nightWeight = nw, dayWeight = time.dayWeight,
    preset = ctx.preset or AtmosTime.DEFAULT_PRESET, hour = hour,
  }
end

-- Identity grade (indoors/caves, or before the first compute()); matches
-- Shaders.frame's own identity defaults (DESIGN.md 3.4 "Identity by
-- default") so a caller can always have *a* table to send, never nil.
AtmosState.IDENTITY = {
  mul = { 1, 1, 1 }, add = { 0, 0, 0 },
  terms = nil, shadowFade = 1, sunShare = 1,
  sky = AtmosSky.IDENTITY,
  emissive = { on = false, gain = 0, color = AtmosState.EMIT_COLOR }, pools = { on = false, gain = 0, color = AtmosState.POOL_COLOR },
  waterFade = 0, waterDark = AtmosState.WATER_DARK,
  fog = nil, period = "day", nightWeight = 0, dayWeight = 1,
}

-- DESIGN.md 3.3 step 3: "no more than 3 flash rises per second". A rise is
-- an increase from ~0 to >0. Stateful, so it is its own small object rather
-- than living inside the pure compute() above; a weather layer (GW-P3,
-- outside this worker's phases) drives it once per frame and passes the
-- clamped result in as ctx.flash.
local FlashLimiter = {}
FlashLimiter.__index = FlashLimiter
AtmosState.FlashLimiter = FlashLimiter

function FlashLimiter.new()
  return setmetatable({ last = 0, times = {}, n = 0 }, FlashLimiter)
end

-- wantFlash: 0..1 this frame; now: seconds (love.timer.getTime() or a test
-- clock). Returns the flash value to actually use this frame.
function FlashLimiter:step(wantFlash, now)
  wantFlash = clamp01(tonumber(wantFlash) or 0)
  now = tonumber(now) or 0
  local rising = wantFlash > 0.02 and self.last <= 0.02
  if rising then
    -- drop timestamps older than 1 second, then check the budget
    local kept = {}
    for i = 1, self.n do
      if now - self.times[i] < 1.0 then kept[#kept + 1] = self.times[i] end
    end
    self.times, self.n = kept, #kept
    if self.n >= AtmosState.MAX_FLASH_RISES_PER_SEC then
      self.last = wantFlash
      return 0   -- budget spent this second: suppress this rise
    end
    self.n = self.n + 1
    self.times[self.n] = now
  end
  self.last = wantFlash
  return wantFlash
end

return AtmosState
