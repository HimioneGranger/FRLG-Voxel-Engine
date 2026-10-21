-- FRLG_VOXEL: the 3D time-of-day schedule (worker "atmos", GW-P1,
-- daynight-weather-hook/DESIGN.md 3.2). Pure data + pure function: no love,
-- no engine, no mod table. Given an hour (0..24, wraps), returns the grade
-- multiplier/add and the published period, on RTC's own hours and blend
-- length (published behaviour, not copied code -- DESIGN.md 3.1/6.3):
--   morning 4-10, day 10-18, night 18-4, 30-minute blends at each boundary.
--
-- Two colour presets (DESIGN.md 3.1, Question 5; user decision "whichever is
-- darker" for the night colour, 2026-09-28):
--   "tuned" -- our own colours, the default unless NIGHT_PRESET_MEASUREMENT.md
--             (daynight-weather-hook/, measured by tools/measure_night_presets.lua)
--             finds "rtc" darker at the reference maps, in which case AtmosState
--             is told to use "rtc" as the default instead. AtmosTime itself
--             always supports both; it does not decide.
--   "rtc"   -- RTC's own creative defaults (ffe8d0 morning-full / 7080c8 night,
--             RTC main.lua:15505-15506), offered as an opt-in "panel match" so
--             the flat panel and the 3D view can agree exactly (Question 5).
-- Do not copy RTC code; these are its published tint constants read once by
-- the design's reader R1, reproduced as data.
--
-- Dawn ramp (DESIGN.md 3.2 row 3, Question 1, default kept): RTC calls
-- 04:00 the start of "morning" (gameplay, NPC, tablet), but TWS's sun only
-- rises at 06:00, so the 3D *light* ramps night -> morning across 04:00-06:00
-- while the *period* still switches at 04:00. This is the one place the
-- published period and the 3D light disagree on purpose.
--
-- Pure math: no love, no requires (sandbox-safe; loadable and testable with
-- plain luajit, no `mod`/`V.require` chunk needed beyond the header below).
local V = ...
local _ = V

local AtmosTime = {}

-- RTC's own boundaries and blend length (RTC main.lua ~15505 vicinity, R1 S2).
AtmosTime.NIGHT_START = 18.0    -- day -> night blend starts (ends 18:30)
AtmosTime.BLEND = 0.5           -- hours
AtmosTime.MORNING_START = 4.0   -- period switches to "morning" here (gameplay)
AtmosTime.DAWN_RAMP_END = 6.0   -- 3D light finishes the night->morning ramp here
AtmosTime.DAY_START = 10.0      -- period switches to "day"; also blend start

AtmosTime.PRESETS = {
  -- our own tuned colours (DESIGN.md 3.1 rev 2 default): a darker night
  -- than RTC's, and a slightly softer morning warmth, tuned against
  -- reference-user-20260928/videos-20260928/v17_sheet.jpg, v18_sheet.jpg
  -- (deep blue ground/walls, full-bright warm windows, warm ground pools).
  -- Coordinator review 2026-09-28 (against the reference sheets directly):
  -- the first cut (0.32, 0.40, 0.46) read as cyan/teal on grass (green
  -- albedo G channel stayed the dominant channel after grading). Retuned so
  -- B is clearly the largest multiplier relative to G: every one of the
  -- seven representative surfaces in NIGHT_PRESET_MEASUREMENT.md now grades
  -- blue-dominant (only the red-albedo roof stays reddish, which the
  -- references also show), and the weighted mean luminance drops from
  -- 0.2277 to 0.1826 -- still well under the rtc preset's 0.2935, so the
  -- "whichever is darker" default is unaffected. Re-run
  -- night_preset_luminance.lua after any further tuning pass.
  tuned = {
    night   = { 0.28, 0.30, 0.50 },
    morning = { 0.96, 0.88, 0.80 },
  },
  -- RTC's own defaults, read not copied (RTC main.lua:15505-15506 [V]):
  -- night 0x7080c8, morning-full 0xffe8d0.
  rtc = {
    night   = { 0x70 / 255, 0x80 / 255, 0xc8 / 255 },
    morning = { 0xff / 255, 0xe8 / 255, 0xd0 / 255 },
  },
}
AtmosTime.DEFAULT_PRESET = "tuned"

-- Night lift (DESIGN.md 3.2 row 2): a small additive floor for VR
-- readability, the same idea as TWS NITE's own add term. Same for both
-- presets (a comfort floor, not a creative colour choice).
AtmosTime.NIGHT_LIFT = { 0, 0.01, 0.05 }

local DAY_MUL = { 1, 1, 1 }
local ZERO_ADD = { 0, 0, 0 }

local function clamp01(x) return x < 0 and 0 or (x > 1 and 1 or x) end

local function lerp3(a, b, t)
  return { a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t }
end

local function scale3(a, k)
  return { a[1] * k, a[2] * k, a[3] * k }
end

-- Smoothstep, used only for the dawn ramp (the ground light, not the
-- published period, which switches sharply at 04:00 like RTC's own).
local function smooth01(a, b, x)
  local t = clamp01((x - a) / (b - a))
  return t * t * (3 - 2 * t)
end

-- Normalises to [0, 24).
local function wrapHour(h)
  h = tonumber(h) or 0
  h = h % 24
  if h < 0 then h = h + 24 end
  return h
end
AtmosTime.wrapHour = wrapHour

-- RTC's published period for this hour: "morning" | "day" | "night".
function AtmosTime.periodAt(hour)
  hour = wrapHour(hour)
  if hour >= AtmosTime.MORNING_START and hour < AtmosTime.DAY_START then return "morning" end
  if hour >= AtmosTime.DAY_START and hour < AtmosTime.NIGHT_START then return "day" end
  return "night"
end

-- Returns { mul = {r,g,b}, add = {r,g,b}, period, nightWeight, dayWeight }.
-- preset: "tuned" (default) | "rtc"; an unknown name falls back to tuned.
function AtmosTime.at(hour, presetName)
  hour = wrapHour(hour)
  local preset = AtmosTime.PRESETS[presetName] or AtmosTime.PRESETS[AtmosTime.DEFAULT_PRESET]
  local period = AtmosTime.periodAt(hour)
  local NS, BL, MS, DE, DS = AtmosTime.NIGHT_START, AtmosTime.BLEND, AtmosTime.MORNING_START,
    AtmosTime.DAWN_RAMP_END, AtmosTime.DAY_START

  local mul, nightWeight
  if hour >= NS and hour < NS + BL then
    -- 18:00-18:30: day -> night
    local t = (hour - NS) / BL
    mul = lerp3(DAY_MUL, preset.night, t)
    nightWeight = t
  elseif hour >= NS + BL or hour < MS then
    -- 18:30-04:00: full night
    mul = preset.night
    nightWeight = 1
  elseif hour >= MS and hour < DE then
    -- 04:00-06:00: dawn ramp, night -> morning (light only; period already
    -- switched to "morning" at 04:00, DESIGN.md 3.2 Question 1 default)
    local t = smooth01(MS, DE, hour)
    mul = lerp3(preset.night, preset.morning, t)
    nightWeight = 1 - t
  elseif hour >= DE and hour < DS then
    -- 06:00-10:00: morning
    mul = preset.morning
    nightWeight = 0
  elseif hour >= DS and hour < DS + BL then
    -- 10:00-10:30: morning -> day
    local t = (hour - DS) / BL
    mul = lerp3(preset.morning, DAY_MUL, t)
    nightWeight = 0
  else
    -- 10:30-18:00: full day
    mul = DAY_MUL
    nightWeight = 0
  end
  local dayWeight = 1 - nightWeight
  local add = nightWeight > 0 and scale3(AtmosTime.NIGHT_LIFT, nightWeight) or ZERO_ADD
  return {
    mul = mul, add = add, period = period,
    nightWeight = nightWeight, dayWeight = dayWeight,
  }
end

-- Identity (indoors/caves, DESIGN.md 4.8; also the "grade unavailable" case).
AtmosTime.IDENTITY = { mul = DAY_MUL, add = ZERO_ADD, period = "day", nightWeight = 0, dayWeight = 1 }

return AtmosTime
