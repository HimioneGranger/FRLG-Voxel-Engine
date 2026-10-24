-- FRLG_VOXEL: sky/horizon/forest/sea-haze colours per time of day (worker
-- "atmos", GW-P1, daynight-weather-hook/DESIGN.md 4.6). Pure data + pure
-- function: no love, no requires. Feeds render/Sky.lua's Sky.setPalette
-- (an atmos edit to Sky.lua), which is the only thing that touches
-- love.image/love.graphics; this module just computes the four colours.
--
-- Day values are today's Sky.lua constants, unchanged (ZENITH/HORIZON and
-- the FOREST/SEA_HAZE mix formulas), so a desktop run with the grade forced
-- off at 12:00 reproduces today's sky exactly (P1 acceptance: UI/battle
-- cards pixel-identical at 12:00). Night is a dark blue zenith/horizon with
-- a near-black forest/sea base, tuned against the user's reference sheets
-- (v17/v18) alongside AtmosTime's night grade -- both read the same
-- nightWeight so the sky and the ground darken together. Broad warm
-- sunrise and golden-hour palettes align with the ground's new daylight
-- transitions rather than disappearing before the selectable holds.
local V = ...
local _ = V

local AtmosSky = {}

-- Day (== today's Sky.lua constants; kept here as the t=0 endpoint of every
-- blend, not a duplicate source of truth: DAY, the closest to unity, is what
-- a desktop grade-off proof compares against).
AtmosSky.DAY = {
  zenith = { 0.40, 0.64, 0.93 },
  horizon = { 0.80, 0.89, 0.97 },
  forestBase = { 0.25, 0.40, 0.28 },  -- Sky.lua's FOREST mix target
  seaBlue = { 0.26, 0.52, 0.86 },
}

-- Night: dark blue sky, near-black forest/sea base so the horizon band does
-- not read as a lit strip under a starry sky.
AtmosSky.NIGHT = {
  zenith = { 0.03, 0.05, 0.11 },
  horizon = { 0.09, 0.11, 0.20 },
  forestBase = { 0.02, 0.03, 0.05 },
  seaBlue = { 0.03, 0.06, 0.13 },
}

-- Broad daylight-backed sunrise and golden-hour palettes, aligned with
-- the shared clock's representative morning07:00/evening17:00 holds.
AtmosSky.DUSK_HORIZON = { 1.00, 0.62, 0.28 }
AtmosSky.DUSK_START, AtmosSky.DUSK_PEAK, AtmosSky.DUSK_END = 16, 17, 19.5
AtmosSky.DUSK_ZENITH = { 0.36, 0.47, 0.73 }
AtmosSky.DAWN_HORIZON = { 1.00, 0.70, 0.52 }
AtmosSky.DAWN_START, AtmosSky.DAWN_PEAK, AtmosSky.DAWN_END = 4, 7, 10
AtmosSky.DAWN_ZENITH = { 0.34, 0.48, 0.79 }

local function clamp01(x) return x < 0 and 0 or (x > 1 and 1 or x) end
local function lerp3(a, b, t)
  return { a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t }
end
local function mix3(a, b, t) return lerp3(a, b, t) end

local function triangle(x, a, mid, b)
  -- 0 at a and b, 1 at mid, smooth between. a < mid < b.
  if x <= a or x >= b then return 0 end
  local t = x <= mid and (x - a) / (mid - a) or (b - x) / (b - mid)
  return t * t * (3 - 2 * t)
end

-- hour: 0..24 (wraps); nightWeight: optional, from AtmosTime.at(hour) so the
-- sky and the ground use exactly the same night fraction (recommended: pass
-- it through rather than recomputing here). dim (0..1, weather darkening)
-- and flash (0..1, lightning) are optional GW-P3 hooks; both default to 0
-- (identity) so GW-P1/GW-P4 callers can omit them.
function AtmosSky.at(hour, nightWeight, dim, flash)
  hour = (tonumber(hour) or 12) % 24
  if hour < 0 then hour = hour + 24 end
  local nw = clamp01(tonumber(nightWeight) or 0)
  local base = {
    zenith = mix3(AtmosSky.DAY.zenith, AtmosSky.NIGHT.zenith, nw),
    horizon = mix3(AtmosSky.DAY.horizon, AtmosSky.NIGHT.horizon, nw),
    forestBase = mix3(AtmosSky.DAY.forestBase, AtmosSky.NIGHT.forestBase, nw),
    seaBlue = mix3(AtmosSky.DAY.seaBlue, AtmosSky.NIGHT.seaBlue, nw),
  }
  -- Warm sky and haze follow the same sunrise/golden-hour windows as the ground.
  local duskK = triangle(hour, AtmosSky.DUSK_START, AtmosSky.DUSK_PEAK, AtmosSky.DUSK_END)
  local dawnK = triangle(hour, AtmosSky.DAWN_START, AtmosSky.DAWN_PEAK, AtmosSky.DAWN_END)
  local horizon = base.horizon
  if duskK > 0 then horizon = mix3(horizon, AtmosSky.DUSK_HORIZON, duskK) end
  if dawnK > 0 then horizon = mix3(horizon, AtmosSky.DAWN_HORIZON, dawnK) end

  local zenith, forestBase, seaBlue = base.zenith, base.forestBase, base.seaBlue
  if dawnK > 0 then
    zenith = mix3(zenith, AtmosSky.DAWN_ZENITH, dawnK * (1 - nw))
    forestBase = mix3(forestBase, {0.32, 0.36, 0.26}, dawnK)
    seaBlue = mix3(seaBlue, {0.32, 0.48, 0.72}, dawnK)
  end
  if duskK > 0 then
    zenith = mix3(zenith, AtmosSky.DUSK_ZENITH, duskK * (1 - nw))
    forestBase = mix3(forestBase, {0.34, 0.32, 0.20}, duskK)
    seaBlue = mix3(seaBlue, {0.34, 0.45, 0.66}, duskK)
  end
  dim = clamp01(tonumber(dim) or 0)
  flash = clamp01(tonumber(flash) or 0)
  if dim > 0 then
    local k = 1 - 0.6 * dim
    zenith, horizon = { zenith[1] * k, zenith[2] * k, zenith[3] * k }, { horizon[1] * k, horizon[2] * k, horizon[3] * k }
    forestBase, seaBlue = { forestBase[1] * k, forestBase[2] * k, forestBase[3] * k },
      { seaBlue[1] * k, seaBlue[2] * k, seaBlue[3] * k }
  end
  if flash > 0 then
    -- same comfort-capped flash tint the ground grade uses (AtmosState),
    -- lifted toward white so a bolt lights the whole sky briefly
    local FLASH_TINT, CAP = { 0.70, 0.80, 1.00 }, 0.35
    local f = flash * CAP
    zenith = { zenith[1] + FLASH_TINT[1] * f, zenith[2] + FLASH_TINT[2] * f, zenith[3] + FLASH_TINT[3] * f }
    horizon = { horizon[1] + FLASH_TINT[1] * f, horizon[2] + FLASH_TINT[2] * f, horizon[3] + FLASH_TINT[3] * f }
  end
  -- Derive FOREST/SEA_HAZE the same way today's Sky.lua does (its own
  -- comment: "HORIZON * 0.55 pushed halfway toward" the forest target; SEA_HAZE
  -- = HORIZON*0.6 + SEA_BLUE*0.4), just fed the time-shifted horizon/bases so
  -- the below-horizon band and the sea plane darken together with the sky.
  local forest = {
    (horizon[1] * 0.55 + forestBase[1]) / 2,
    (horizon[2] * 0.55 + forestBase[2]) / 2,
    (horizon[3] * 0.55 + forestBase[3]) / 2,
  }
  local seaHaze = {
    horizon[1] * 0.6 + seaBlue[1] * 0.4,
    horizon[2] * 0.6 + seaBlue[2] * 0.4,
    horizon[3] * 0.6 + seaBlue[3] * 0.4,
  }
  return { zenith = zenith, horizon = horizon, forest = forest, seaHaze = seaHaze }
end

-- Today's exact Sky.lua constants (0 night weight, no dim/flash): the
-- identity a caller uses indoors/in caves, where Sky.draw never runs, or as
-- a safe default before AtmosState has run once.
AtmosSky.IDENTITY = AtmosSky.at(12, 0, 0, 0)

return AtmosSky
