-- FRLG_VOXEL Lab 57: LOADING SCREEN (FireRed's own file). An opaque black canvas with a centred white
-- "Loading", shown on the headset while the 3D world is not ready, plus a small hold state machine.
--
-- Prior art, ideas only: the Emerald/ReVoxel Lab 44 loading screen (opaque black canvas, centred "Loading",
-- a pure show policy). This file is written for FireRed's questFrame: it supplies the canvas through the
-- panel-quad callback only, and leaves S.flatWorld and the render-fail counters to main.lua.
--
-- HOLD (Lab 57). A hard re-root (boot, warp, Fly: the camera snaps, no seamless shift) or a root with no
-- geometry yet ("building") starts a hold. While holding, the stereo world is not drawn (the quad shows
-- Loading) and the build pump gets the larger panel-frame budget. The hold ends when the root is built and no
-- build job is due near the arrival point (Scene:buildsDue), after a full garbage collect behind the black
-- screen (so play starts on a clean heap) and one warm-up eye pass (rendered, not submitted), when the work is ready; elapsed time never reveals an unfinished world. Leaving the
-- field (menu, battle, failure, switch off) ends it at once and never collects. Walking over a map connection
-- is a seamless re-root and never holds.
--
-- Pure logic: the clock is the caller's dt, the collector is injected, nothing here touches main.lua state.
local M = {}
M.__index = M

M.DT_CLAMP = 0.25      -- one frame never counts for more than this (focus loss must not eat the cap)
M.COOLDOWN_S = 0.5     -- after a hold ended, a "building" trigger waits this long (no flicker)

-- Is the Loading canvas shown this frame? o = { enabled, failed, battle, menu, phase, holding, reason }
function M.shouldShow(o)
  if not o.enabled or o.failed or o.battle or o.menu then return false end
  if o.phase ~= "field" then return false end
  return o.holding == true or o.reason == "building"
end

function M.new()
  return setmetatable({ holding = false, elapsed = 0, cool = 0, holds = 0, collects = 0, caps = 0 }, M)
end

-- Once per questFrame, after the build pump. o = { dt, enabled, failed, battle, menu, phase, active (field and
-- 3D wanted), hard (hard re-root this frame), reason ("building" when the root has no geometry),
-- rootReady, due (Scene:buildsDue), warmed (a full eye pass completed since the collect) }.
-- -> holding (bool), collectNow (bool), warmNow (bool: this frame must render the eyes but not submit them)
--
-- Stages: "build" (until the root is built and nothing is due) -> the collect frame (still Loading) -> "warm"
-- (the eyes are rendered for real but not submitted, so first-use work in the eye pass -- shader compiles,
-- atlas mirror canvases, uploads; a 5 s frame was seen on Lab 56 -- happens behind the black screen) -> the world.
function M:update(o)
  local dt = tonumber(o.dt) or 0
  if dt < 0 then dt = 0 elseif dt > M.DT_CLAMP then dt = M.DT_CLAMP end
  if self.cool > 0 then self.cool = math.max(0, self.cool - dt) end
  local stay = o.enabled and not o.failed and not o.battle and not o.menu and o.phase == "field" and o.active
  if not stay then
    if self.holding then
      self.holding, self.elapsed, self.stage = false, 0, nil
      -- Lab 60: why the hold ended without finishing (for the "loading screen hide reason=" log line)
      self.endWhy = (not o.enabled and "disabled") or (o.failed and "failed") or (o.battle and "battle")
        or (o.menu and "menu") or (o.phase ~= "field" and "left-field") or "world-off"
    end
    return false, false, false
  end
  if not self.holding then
    local trigger = o.hard == true or (o.reason == "building" and self.cool <= 0)
    if not trigger then return false, false, false end
    self.holding, self.elapsed, self.stage, self.warmFrames = true, 0, "build", 0
    self.startWhy, self.endWhy = o.hard == true and "hard" or "building", nil -- Lab 60: log reasons
    self.holds = self.holds + 1
  else
    self.elapsed = self.elapsed + dt
  end
  local function finish()
    self.lastElapsed, self.lastCapped = self.elapsed, false
    self.endWhy = "done"
    self.holding, self.elapsed, self.stage, self.cool = false, 0, nil, M.COOLDOWN_S
  end
  if self.stage == "build" then
    local done = o.rootReady == true and (o.due or 0) == 0 and o.hard ~= true
    if done then
      self.stage = "warm"
      self.collects = self.collects + 1
      return true, true, false -- collect now; the warm-up eye pass starts next frame
    end
    return true, false, false
  end
  -- warm stage
  self.warmFrames = self.warmFrames + 1
  if o.warmed == true then
    finish()
    return false, false, false
  end
  return true, false, true
end

-- Full collect behind the black screen. SLACK owns the collector only for stereo world frames; the lease is
-- released here (idempotent) before the explicit collect, and SLACK re-takes it on the next stereo frame.
-- gc is injected for tests. -> heap KB after
function M.collect(pacer, gc)
  gc = gc or collectgarbage
  if pacer and type(pacer._slackRelease) == "function" then pcall(pacer._slackRelease, pacer, "loading screen collect") end
  pcall(gc, "collect")
  pcall(gc, "collect")
  local ok, kb = pcall(gc, "count")
  kb = ok and tonumber(kb) or nil
  local slack = pacer and pacer.slack
  if kb and slack and type(slack.noteFullCollect) == "function" then pcall(slack.noteFullCollect, slack, kb) end
  return kb
end

-- ------------------------------------------------------------------ canvas
local function paint(w, h, font, stage)
  local g = love.graphics
  g.origin(); g.setShader(); g.setScissor(); g.setStencilTest(); g.setDepthMode(); g.setMeshCullMode("none")
  g.setColorMask(true, true, true, true); g.setWireframe(false); g.setBlendMode("alpha"); g.setColor(0, 0, 0, 1); g.rectangle("fill", 0, 0, w, h)
  g.setFont(font); g.setColor(1, 1, 1, 1)
  g.printf(stage == "warm" and "Preparing the view" or "Loading nearby terrain", 0, math.floor(h * 0.34), w, "center")
  g.printf(stage == "warm" and "Finishing terrain loading..." or "Preparing terrain for this area...", 0, math.floor(h * 0.56), w, "center")
end

-- The opaque canvas, cached per size. Raises on a graphics failure (the caller falls back to the flat panel).
function M:canvas(w, h)
  local g = love.graphics
  if self.image and (self.image:getWidth() ~= w or self.image:getHeight() ~= h) then
    self.image:release(); self.image = nil
  end
  if self.image and self.paintedStage ~= self.stage then self.image:release(); self.image = nil end
  if not self.image then
    self.font = self.font or g.newFont(math.max(24, math.floor(h / 12)))
    local c = g.newCanvas(w, h, { dpiscale = 1 })
    c:setFilter("linear", "linear")
    g.push("all")
    local ok, why = pcall(function() g.setCanvas(c); g.clear(0, 0, 0, 1); paint(w, h, self.font, self.stage) end)
    g.pop()
    if not ok then c:release(); error(why, 0) end
    self.image, self.paintedStage = c, self.stage
  end
  return self.image
end

function M:release()
  if self.image then self.image:release(); self.image = nil end
  if self.font then self.font:release(); self.font = nil end
  self.holding, self.elapsed = false, 0
end

return M
