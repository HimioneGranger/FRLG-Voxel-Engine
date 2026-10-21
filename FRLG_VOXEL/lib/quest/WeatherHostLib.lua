-- FRLG_VOXEL: the `exports.lib.require(name)` facade TWS's legacy Gen1/Gen2
-- adapter (DramalessAtmos, CinematicAtmos, QuestStorm) already calls on
-- other hosts (worker "atmos", GW-P2 host-interface groundwork,
-- daynight-weather-hook/DESIGN.md 4.4 Table A). A strict whitelist: any
-- other name raises, exactly like the contract TWS already falls back to
-- stubs for (DramalessAtmos.lua:195-262).
--
-- Status (see daynight-weather-hook/W8_INTEGRATION.md): built and unit
-- tested in isolation this phase (GW-P1/GW-P4 come first per this worker's
-- assignment). Wiring `mod.exports.lib = WeatherHostLib...` into main.lua,
-- and having a real TWS Gen3 compat layer actually call it, is GW-P2 work
-- for the coordinator + the "tws-gen3" worker; nothing here has been
-- exercised against real TWS code.
--
-- Units (DESIGN.md 4.4): 16 world px per FRLG cell, Y up, X east, Z south,
-- 10 px per metre in first person -- the same convention Battle Art/VRITK's
-- Voxel3DShim already uses (PxContext.lua), so this is not a new mapping.
--
-- opts = {
--   getHour = fn() -> hour 0..24 (the resolved clock, vrHost.clock.get()),
--   getSource = fn() -> "rtc"|"rtc-os"|"tws"|"none" (DayNight.setting.get()),
--   getPreset = fn() -> "tuned"|"rtc" (AtmosTime preset in use),
--   getEyeVp  = fn() -> 16-number row-major VP (cells, current eye, set by
--       the caller before each questCelestialBeforeClouds/afterCelestial/
--       endScene call -- WeatherHost.lua does this per eye),
--   getEyePos = fn() -> {x,y,z} world cells (current eye),
--   getFocus  = fn() -> {x,y,z} world cells (player/seat focus),
--   getMapState = fn() -> { map = {id, width, height}, neighbors = {...} }
--       (Map.world-shaped, DESIGN.md 4.4 VoxelScene row),
--   getHaze = fn() -> 0..1|nil (Sky.haze() colour source; optional),
--   canvas = love.graphics.Canvas|nil (the eye canvas TWS may query),
--   viewportHeight = number|nil,
--   endSceneImpl = fn()|nil (drives storm bolts / rain-snow; set by
--       WeatherHost.lua once GW-P3 exists; a no-op until then, matching
--       DESIGN.md 4.4's "endScene() is a no-op that TWS wraps and calls
--       through").
-- }
local V = ...
local Mat4 = V.require("render/Mat4")
local AtmosTime = V.require("render/AtmosTime")

local WeatherHostLib = {}

local PX_PER_CELL = 16

local function noop() end
local function call0(fn, ...)
  if type(fn) ~= "function" then return nil end
  local ok, a, b, c = pcall(fn, ...)
  if ok then return a, b, c end
  return nil
end

local function toArrayPx(p)
  if type(p) ~= "table" then return { 0, 0, 0 } end
  local x = p.x or p[1] or 0
  local y = p.y or p[2] or 0
  local z = p.z or p[3] or 0
  return { x * PX_PER_CELL, y * PX_PER_CELL, z * PX_PER_CELL }
end

function WeatherHostLib.new(opts)
  opts = opts or {}

  -- DESIGN.md 4.4: "far = 4000" px == 250 cells (4000/16), matching the
  -- 400 m FAR / 1.6 m-per-cell relationship the coordinator's Camera.lua
  -- anchored edit sets up for GW-P2 (Camera.FAR = 400 m, CULL_FAR stays 150).
  local FAR_PX = 4000

  local Voxel3D
  Voxel3D = {
    far = FAR_PX,
    camera = { far = FAR_PX, up = { 0, 1, 0 } },
    curveX = 0, curveY = 0, curveZ = 0, curveK = 0,
    stableStarBillboards = true,
    fov = nil, viewportHeight = opts.viewportHeight,
    canvas = opts.canvas,
    -- vp/eye/focus are refreshed per eye by WeatherHost.lua before each of
    -- questCelestialBeforeClouds / afterCelestial / endScene, in PX, so TWS
    -- never sees our cell-space matrices (DESIGN.md 4.4).
    vp = nil, eye = nil, focus = nil,
    -- Required: DramalessAtmos calls hostLib.require('TileShape') directly
    -- inside its precipitation pass; endScene must exist and be callable
    -- even before GW-P3 wires real rain/snow/bolts (a no-op that TWS wraps
    -- and calls through, DESIGN.md 4.4).
    endScene = function(...)
      if type(opts.endSceneImpl) == "function" then return call0(opts.endSceneImpl, ...) end
    end,
    beginEffect = noop, endEffect = noop,
    -- set by the TWS Gen3 compat layer (Gen3Host.lua, not ours) once loaded;
    -- left nil here so `hostLib.require('Voxel3D').questCelestialBeforeClouds`
    -- being absent is exactly TWS's own "not yet set" case, not an error.
    questCelestialBeforeClouds = nil,
    afterCelestial = nil,
  }

  -- WeatherHost.lua refreshes these fields once per eye; exposed as plain
  -- setters here so that file (and only that file) owns "when".
  function Voxel3D._setEye(vpCells, eyePosCells, focusCells)
    Voxel3D.vp = vpCells and Mat4.chain(vpCells, Mat4.scale(1 / PX_PER_CELL)) or nil
    Voxel3D.eye = eyePosCells and toArrayPx(eyePosCells) or nil
    Voxel3D.focus = focusCells and toArrayPx(focusCells) or Voxel3D.eye
  end

  local function currentHour() return call0(opts.getHour) or 12 end
  local function currentSource() return call0(opts.getSource) or "none" end
  local function currentPreset() return call0(opts.getPreset) or AtmosTime.DEFAULT_PRESET end

  -- TWS's 1200-second dial, DAY_LEN 600: hour -> ((h-6) mod 24) * 50 (its
  -- own formula, TWS-X lib/TimeOfDay.lua:148-171, reproduced as published
  -- behaviour -- DESIGN.md 2.4).
  local CYCLE, DAY_LEN = 1200, 600
  local function hourToDial(h)
    return ((h - 6) % 24) * 50
  end
  local function dialToHour(t)
    return (t / 50 + 6) % 24
  end

  local DayNight
  DayNight = {
    CYCLE = CYCLE, DAY_LEN = DAY_LEN,
    time = function() return hourToDial(currentHour()) end,
    hours = function() return currentHour() end,
    -- [H]: TWS's exact use of mix(t) was not confirmed against its source
    -- this phase (marked [H] in reading-voxel-renderer-sky-light.md 4.2);
    -- a 0..1 fraction of the dial is the conservative reading. Re-verify
    -- against TWS's actual caller before GW-P2 wiring.
    mix = function(t) return (tonumber(t) or hourToDial(currentHour())) % CYCLE / CYCLE end,
    isNight = function() return AtmosTime.periodAt(currentHour()) == "night" end,
    isCanopy = function() return false end,
    shearAt = function() return 0, 0 end,
    -- Base (unwrapped) time light, our own schedule; TWS's Gen3 layer wraps
    -- this field (DESIGN.md 3.1: "TWS wraps it as time * (1-0.18*storm) +
    -- flash*(...)") the same way it already defers Interop.dayNight -- a
    -- plain table field, reassignable at runtime, never captured as a local.
    tint = function(outdoor, t)
      if not outdoor then return { 1, 1, 1 } end
      local h = t ~= nil and dialToHour(t) or currentHour()
      return AtmosTime.at(h, currentPreset()).mul
    end,
    -- DESIGN.md 2.4: values has no "cycle" so nothing can flip our clock to
    -- one; get() reports the resolved source for NightSky's moon/meteor
    -- day counter (which needs "system" specifically) and for diagnostics.
    setting = {
      values = { "system" },
      get = function()
        local src = currentSource()
        return (src == "rtc" or src == "rtc-os") and "system" or src
      end,
    },
  }

  local Sky = {
    haze = function() return call0(opts.getHaze) or { 0.80, 0.89, 0.97 } end,
    region = function() return nil end,
    paint = noop,
  }

  -- Fixed baked sun (DESIGN.md 4.6): TWS writes the sun shear here, we
  -- ignore it. `active = false` tells a careful caller not to bother.
  local ShadowMap = { KX = 0, KZ = 0, active = false }

  -- Required stub: DramalessAtmos calls hostLib.require('TileShape')
  -- directly inside the precipitation pass (DESIGN.md 4.4); a missing
  -- module would silently stop all rain. `at` intentionally always nil
  -- (v1 has no per-tile rain-surface shape query); the Gen3 layer's own
  -- rain-splash sampler wraps QuestRainSurface.sampler separately (not us).
  local TileShape = {
    forMap = function() return nil end,
    at = function() return nil end,
  }

  -- VoxelScene.render(state): TWS captures state.map/state.neighbors for
  -- clouds and weather once per frame (DramalessAtmos.lua:790-814). state is
  -- supplied by the caller (WeatherHost.lua) from opts.getMapState() each
  -- call; this module never builds it itself, so a stale/foreign format
  -- never gets guessed at here.
  local VoxelScene = {
    render = function(state)
      -- observation only, never throws outward: an odd `state` shape from a
      -- future engine version should not take down the weather draw
      local _ = state
      return true
    end,
  }

  -- Read-only diagnostic surface: no mutable solar functions/state escape.
  -- Resolve lazily so constructing the weather facade cannot create a cycle.
  local solarDiagnostics = {
    FIELD_CAP = 32 * 1024 * 1024, STAGE_CAP = 8 * 1024 * 1024,
    status = function()
      local ok, solar = pcall(V.require, "render/SolarShadows")
      if not ok or type(solar) ~= "table" or type(solar.status) ~= "function" then
        return { enabled = false, error = "solar diagnostics unavailable" }
      end
      local good, state = pcall(solar.status)
      if not good or type(state) ~= "table" then
        return { enabled = false, error = "solar status unavailable" }
      end
      local copy = {}
      for k, value in pairs(state) do
        local kind = type(value)
        if type(k) == "string" and (kind == "boolean" or kind == "string" or
          (kind == "number" and value == value and math.abs(value) < math.huge)) then
          copy[k] = value
        end
      end
      return copy
    end,
  }
  local SolarShadows = setmetatable({}, {
    __index = solarDiagnostics,
    __newindex = function() error("SolarShadows diagnostics are read-only", 0) end,
    __metatable = false,
  })

  local modules = {
    SolarShadows = SolarShadows,
    Voxel3D = Voxel3D, DayNight = DayNight, Sky = Sky,
    ShadowMap = ShadowMap, TileShape = TileShape, VoxelScene = VoxelScene,
  }

  return {
    -- Strict whitelist (DESIGN.md 4.4): anything else raises, so TWS falls
    -- back to its own Mat4/ForestAtmos/SpriteBillboards/TerrainAtlas stubs.
    require = function(name)
      local m = modules[name]
      if m == nil then error("WeatherHostLib: unsupported module '" .. tostring(name) .. "'", 0) end
      return m
    end,
    -- Internal accessors for WeatherHost.lua (per-eye refresh, GW-P2) and
    -- for tests; not part of the `exports.lib.require` contract itself.
    _modules = modules,
    _setEye = Voxel3D._setEye,
  }
end

return WeatherHostLib
