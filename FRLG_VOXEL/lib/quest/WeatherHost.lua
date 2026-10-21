-- FRLG_VOXEL: the two new per-eye draw steps a weather layer needs (worker
-- "atmos", GW-P2 host-interface groundwork, DESIGN.md 4.5 table, steps 6 and
-- 8). Not a vrHost.layers registry entry (that slot runs after this one and
-- has no depth-off "sky" phase, reading-voxel-renderer-sky-light.md 0.5) --
-- a direct object the coordinator's View.lua anchored edit calls, the same
-- pattern lib/battle/BattlePass.lua already uses for its own draw slots
-- (opts.battle:drawEye / :postEye / :drawOverlay in View.lua today).
--
-- sky(eye, env):  set Voxel3D's per-eye fields, then call
--                 questCelestialBeforeClouds() and afterCelestial() if the
--                 TWS Gen3 compat layer has set them on the Voxel3D module
--                 this WeatherHostLib instance exposes. Depth test on, no
--                 write (matches TWS's own `lequal`, no-write celestial
--                 draws, reading-voxel-renderer-sky-light.md 0.5), so it
--                 must run AFTER Scene:draw's depth write and BEFORE the
--                 vrHost layer slot (View.lua step order, DESIGN.md 4.5).
-- late(eye, env): call Voxel3D.endScene() (storm bolts, rain/snow -- a
--                 no-op until GW-P3 wires endSceneImpl into
--                 WeatherHostLib.new). Runs AFTER the vrHost layer slot,
--                 BEFORE the UI card.
--
-- Status: built and self-tested against a stub Voxel3D this phase (no real
-- TWS code exercised it; that is GW-P2, after this worker's GW-P1/GW-P4
-- phases). See daynight-weather-hook/W8_INTEGRATION.md for the View.lua
-- anchor points that call sky()/late() and for main.lua's mono wiring
-- (DESIGN.md 4.5: "Desktop mono never runs the layer slot today; one
-- anchored edit makes steps 6 and 8 run there too").
local V = ...
local _ = V

local WeatherHost = {}
WeatherHost.__index = WeatherHost

-- opts = { hostLib = WeatherHostLib.new(...) result, log = fn(msg) }
function WeatherHost.new(opts)
  opts = opts or {}
  return setmetatable({
    hostLib = opts.hostLib, log = opts.log or function() end,
    failCounts = { sky = 0, late = 0 }, disabled = { sky = false, late = false },
  }, WeatherHost)
end

local MAX_CONSECUTIVE_ERRORS = 3

local function guarded(self, phase, fn, ...)
  if self.disabled[phase] then return end
  local ok, err = pcall(fn, ...)
  if ok then
    self.failCounts[phase] = 0
  else
    self.failCounts[phase] = self.failCounts[phase] + 1
    if self.failCounts[phase] >= MAX_CONSECUTIVE_ERRORS then
      self.disabled[phase] = true
      self.log("[WeatherHost] " .. phase .. " disabled after "
        .. MAX_CONSECUTIVE_ERRORS .. " consecutive errors: " .. tostring(err))
    end
  end
end

-- eye = { vp (cells, row-major 16), pos = {x,y,z} (cells) } -- the same
-- shape View.lua's renderBody already builds for the vrHost layer slot.
-- env = { focus = {x,y,z} cells|nil } (defaults to eye.pos).
function WeatherHost:sky(eye, env)
  local hl = self.hostLib
  if not (hl and eye and eye.vp and eye.pos) then return end
  guarded(self, "sky", function()
    hl._setEye(eye.vp, eye.pos, env and env.focus)
    local V3 = hl._modules.Voxel3D
    if type(V3.questCelestialBeforeClouds) == "function" then V3.questCelestialBeforeClouds() end
    if type(V3.afterCelestial) == "function" then V3.afterCelestial() end
  end)
end

function WeatherHost:late(eye, env)
  local hl = self.hostLib
  if not (hl and eye and eye.vp and eye.pos) then return end
  guarded(self, "late", function()
    hl._setEye(eye.vp, eye.pos, env and env.focus)
    local V3 = hl._modules.Voxel3D
    if type(V3.endScene) == "function" then V3.endScene() end
  end)
end

-- Lab 60 (fixes60 item 2): build the weather cloud deck, its density image, mesh and shader ahead of
-- the first outdoor eye frame. The Gen3 weather compat layer publishes Voxel3D.questCloudPrewarm
-- (compat/gen3/Gen3SkyRse.lua); this forwards to it.
--   host:prewarm(phase)        runs every stage in one call (boot / 'Preparing 3D world' / Loading)
--   host:prewarm(phase, true)  runs ONE stage per call (idle fallback while indoors)
-- phase is a label string ('boot', 'prepare', 'loading', ...) used in the once-only log line
-- 'cloud deck warmed at <phase> in N ms'.
-- Returns done(boolean), info(string). done=true also means "nothing to do" (no compat layer,
-- clouds off, VRITK absent, already warm, or a stage failed and will not be retried); callers stop
-- calling once done. Never throws and never counts against the "sky" failure budget. Callers gate
-- it on VritkGate (the coordinator does); the compat side checks VRITK_FRLG_HOST itself too.
function WeatherHost:prewarm(phase, oneStep)
  local hl = self.hostLib
  local mods = hl and hl._modules
  local V3 = mods and mods.Voxel3D
  local fn = V3 and V3.questCloudPrewarm
  if type(fn) ~= "function" then return true, "unavailable" end
  local ok, done, info = pcall(fn, phase, oneStep == true)
  if not ok then
    self.log("[WeatherHost] prewarm failed: " .. tostring(done))
    return true, "error"
  end
  return done ~= false, info
end

-- Re-arm after three consecutive failures (e.g. a fresh TWS load, or a map
-- reset); called by the same lifecycle edges HostLayers:invalidateAll uses.
function WeatherHost:invalidate()
  self.failCounts.sky, self.failCounts.late = 0, 0
  self.disabled.sky, self.disabled.late = false, false
end

function WeatherHost:debugState()
  return { sky = { disabled = self.disabled.sky, errors = self.failCounts.sky },
    late = { disabled = self.disabled.late, errors = self.failCounts.late } }
end

return WeatherHost
