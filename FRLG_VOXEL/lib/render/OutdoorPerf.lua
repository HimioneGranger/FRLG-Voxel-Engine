-- FRLG_VOXEL Lab 55: the outdoor renderer performance switches (VR PERFORMANCE
-- page, main.lua schema). One plain table read on the hot paths; main.lua
-- writes it from the options at renderer build and on every option change.
-- Every switch ON draws the same picture as OFF (same draw calls in the same
-- order with the same uniform values), except the look trades marked below:
-- farMasks, weatherTier, drawRange and sunShadows.
--   hoist   FRAME HOIST:  frame-constant uniforms sent only when their value
--                         changes (render/Shaders.lua), the per-eye env/light/
--                         grade tables built once per frame (render/View.lua),
--                         Sky's scratch matrices and env (render/Sky.lua)
--   scratch EYE SCRATCH:  caller-owned frustum planes and per-map MVP
--                         (render/Scene.lua), reused shadow-transform and
--                         atlas-size uniform tables (render/Shaders.lua), the
--                         emissive mask looked up once per frame per map layer
--   grass   GRASS STATE:  RetroGrass skips repeated shader binds, deform
--                         uniform re-sends and instance attach/detach pairs
--   sea     SEA ONCE:     the sea fan's vertices are built and uploaded once
--                         per frame, not once per eye (render/Sea.lua)
--   weather WEATHER HOIST: pushed to the shared weather mod's game-neutral
--                         exports.setFrameHoist (cloud uniforms, atmosphere
--                         closures); main.lua owns the push
--   buildSlice BUILD SLICING: finer cooperative build checkpoints and a
--                         resident-geometry budget (render/Scene.lua build path)
--   worldCache WORLD CACHE: Lab 57 (lib/perf/FrPrecache*.lua). ON: finished map and
--                         border-ring builds are saved to mod.cache and loaded on a
--                         later visit instead of being rebuilt. OFF is exactly Lab 56.
--   loadingScreen LOADING SCREEN: Lab 57. ON: a black "Loading" screen while a warp / Fly / unbuilt root
--                         loads, kept until the nearby maps are built, then a full collect. OFF is Lab 56.
--   speed58 SPEED PATCHES: Lab 58. ON: the equivalent-output speed items of lib/perf/Speed58.lua run (while VRITK is
--                         active). OFF is exactly Lab 57. Not one of the Lab 55 renderer switches (no epoch bump).
--   precacheFirstLoad PRECACHE ON FIRST LOAD: Lab 59 (lib/perf/FrPrepare.lua). ON: when the world cache is
--                         missing or invalid (first launch, an update that changes the cache key, a cleared
--                         cache) every map is built behind a "Preparing 3D world" screen, resumable, with B =
--                         skip for now. OFF is exactly the Lab 57/58 on-demand behaviour. Needs WORLD CACHE ON.
--   farMasks FAR SHADOWS: "full" (Lab 52), "defer" (mask rastered later) or
--                         "off" (no sun mask on border rings and far maps)
--                         (render/Scene.lua / SolarShadows.lua). Look trade.
--   weatherTier WEATHER:  "full" (Lab 52 look), "lite" (cheaper sky/cloud/late
--                         passes), "off" (rain/snow/day-night only); pushed to
--                         the weather mod's exports.setQuestWeatherTier. Look trade.
--   drawRange DRAW RANGE: "full" (Lab 52 fog end 62 m), "medium" (50 m) or
--                         "near" (40 m): haze end and cull radius (View.lua). Look trade.
--   sunShadows SUN SHADOWS: "moving" (Lab 52: masks follow the clock),
--                         "fixed" (one mid-morning direction baked per map,
--                         strength/colour still follow the clock; the weather
--                         mod's sun and moon keep to that side) or "off".
--                         SolarShadows publishes P.fixedSunDir (toward the sun,
--                         x east, y up, z south) and P.fixedSunBearingDeg
--                         (compass bearing); main.lua converts fixedSunDir for
--                         the weather mod (degrees from +X toward +Z).
-- User direction (2026-10-10): frames first, so the look-trading switches
-- default to their cheap setting in this build; FULL keeps today's look.
local P = {
  hoist = true, scratch = true, grass = true, sea = true, weather = true,
  buildSlice = true, worldCache = true, loadingScreen = true, speed58 = true, precacheFirstLoad = true, farMasks = "off", weatherTier = "lite", drawRange = "medium", sunShadows = "fixed",
  epoch = 0, -- bumped on every change (render/Shaders.lua empties its uniform cache)
}

-- Option keys (main.lua schema and VrControls.PERF_SPECS use the same keys).
P.KEYS = {
  perf_frame_hoist = "hoist", perf_eye_scratch = "scratch", perf_grass_state = "grass",
  perf_sea_once = "sea", perf_weather_hoist = "weather", perf_build_slice = "buildSlice",
  perf_far_masks = "farMasks", perf_weather_tier = "weatherTier", perf_draw_range = "drawRange",
  perf_sun_shadows = "sunShadows",
}

local CHOICES = {
  farMasks = { full = true, defer = true, off = true },
  weatherTier = { full = true, lite = true, off = true },
  drawRange = { full = true, medium = true, near = true },
  sunShadows = { moving = true, fixed = true, off = true },
}
P.DEFAULTS = { farMasks = "off", weatherTier = "lite", drawRange = "medium", sunShadows = "fixed" }
-- fog end (metres beyond the focus) per DRAW RANGE; nil = View.FOG_END
P.FOG_END = { medium = 50, near = 40 }

-- Apply one option value; returns the field name it set (nil = not ours).
function P.apply(key, value)
  -- Lab 57 WORLD CACHE (lib/perf/FrPrecache*.lua): not one of the ten Lab 55 renderer switches, so it is
  -- handled here and not listed in P.KEYS. A plain toggle; no epoch bump (it changes no uniform).
  if key == "perf_world_cache" then
    P.worldCache = value ~= false
    return "worldCache"
  end
  if key == "perf_loading_screen" then -- Lab 57 LOADING SCREEN (lib/render/VoxelLoading.lua)
    P.loadingScreen = value ~= false
    return "loadingScreen"
  end
  if key == "perf_speed58" then -- Lab 58 SPEED PATCHES (lib/perf/Speed58.lua)
    P.speed58 = value ~= false
    return "speed58"
  end
  if key == "perf_precache_first_load" then -- Lab 59 PRECACHE ON FIRST LOAD (lib/perf/FrPrepare.lua)
    P.precacheFirstLoad = value ~= false
    return "precacheFirstLoad"
  end
  local field = P.KEYS[key]
  if not field then return nil end
  local set = CHOICES[field]
  local old = P[field]
  if set then
    value = tostring(value)
    P[field] = set[value] and value or P.DEFAULTS[field]
  else
    P[field] = value ~= false
  end
  if P[field] ~= old then P.epoch = P.epoch + 1 end
  return field
end

-- Apply every key from opt(key) (nil keeps the default).
function P.applyAll(opt)
  for key, field in pairs(P.KEYS) do
    local v = opt(key)
    if v ~= nil then P.apply(key, v) end
  end
  local wc = opt("perf_world_cache") -- Lab 57
  if wc ~= nil then P.apply("perf_world_cache", wc) end
  local ls = opt("perf_loading_screen") -- Lab 57
  if ls ~= nil then P.apply("perf_loading_screen", ls) end
  local sp = opt("perf_speed58") -- Lab 58
  if sp ~= nil then P.apply("perf_speed58", sp) end
  local pf = opt("perf_precache_first_load") -- Lab 59
  if pf ~= nil then P.apply("perf_precache_first_load", pf) end
end

return P
