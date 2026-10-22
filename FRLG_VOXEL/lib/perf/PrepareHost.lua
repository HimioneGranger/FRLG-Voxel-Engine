-- FRLG_VOXEL Lab 59: the glue between main.lua's questFrame and the PRECACHE ON FIRST LOAD driver (FireRed's own
-- file; keeps main.lua's changes to a few calls).
--
-- main.lua calls frame() once per Quest frame, before the live map pump. While it returns true the
-- "Preparing 3D world" screen owns the frame: main.lua skips the live pump and the Loading hold, shows the panel
-- (not the world), asks XRSession to keep the panel in front of the head, and does not forward the controls to
-- the game. B skips for now. The module is created lazily and only when the switches and VRITK allow it,
-- so with PRECACHE ON FIRST LOAD OFF, or without VRITK, nothing here is built and frame() is one cheap check.
--
-- ctx = { mod, log, V, Mods (Scene, WorldSource, ...), OutdoorPerf, vritk, worldCache = fn -> PC|nil,
--         grass = fn -> RetroGrass|nil, android = bool, clock = fn, collectFn = fn(pacer) -> kb }
local H = {}
H.__index = H

H.BUDGET_MS = 8            -- build time per Quest frame while the screen is up (a panel frame; no eye passes)
H.CAP_BYTES = nil          -- cache cap while the precache runs (nil = the Lab 57 cap); set by the measured total

function H.new(ctx)
  local V = ctx.V
  local self = setmetatable({ ctx = ctx, prep = nil, screen = nil, prog = {}, bWas = nil, shown = false,
    clock = ctx.clock or (love and love.timer and love.timer.getTime) or os.clock }, H)
  self.Prep = V.require("perf/FrPrepare")
  local okS, Screen = pcall(V.require, "render/PrepareScreen")
  self.Screen = okS and Screen or nil
  return self
end

-- Switches and VRITK allow the precache (the cheap per-frame test).
function H:allowed()
  local c = self.ctx
  local P = c.OutdoorPerf
  return P.precacheFirstLoad ~= false and P.worldCache ~= false and (c.android ~= true or c.vritk:active() == true)
end

local function engineMap()
  local ok, m = pcall(require, "src.core.game3.map")
  return ok and type(m) == "table" and m or nil
end

-- The driver, built on first use. -> Prep | nil
function H:ensure(r)
  if self.prep then return self.prep end
  if self.failed then return nil end
  local c = self.ctx
  local pc = c.worldCache()
  if not pc then self.failed = "no world cache"; return nil end
  local Mods = c.Mods
  local ok, prep = pcall(self.Prep.new, {
    pc = pc, clock = self.clock, log = c.log, scene = Mods.Scene, source = r.source, reach = Mods.Scene.REACH,
    maps = function(game) return game and game.data and game.data.maps end,
    ensureLayout = function(game, id, def)
      local Map = engineMap()
      if Map and Map.ensureMidLayout then
        local okL, layout = pcall(Map.ensureMidLayout, game, id, def)
        if okL then return layout end
        return nil
      end
      return def and def.midLayout
    end,
    isOutdoor = Mods.WorldSource.isOutdoor,
    shadows = function() return r.scene.shadows end,
    gate = function() return self:allowed() end,
    heapKB = function() return collectgarbage("count") end,
    afterCollect = function(kb) -- GC SLACK: the heap right after a completed cycle is the new baseline
      local pacer = r.pacer
      local slack = pacer and pacer.slack
      if slack and type(slack.noteFullCollect) == "function" then pcall(slack.noteFullCollect, slack, kb) end
    end,
    newScene = function()
      return Mods.Scene.new({ source = r.source, mesher = r.scene.mesher, log = c.log, shadows = r.scene.shadows,
        isBusy = r.scene.isBusy, retroGrass = c.grass(), precache = pc })
    end,
    capBytes = H.CAP_BYTES,
  })
  if not ok then self.failed = tostring(prep); c.log("precache prepare not built: " .. tostring(prep)); return nil end
  self.prep = prep
  return prep
end

-- Once per Quest frame, before the live pump. -> true while the prepare screen owns this frame
function H:frame(r, game, battle3d, menuOpen, failed, mode)
  local preintro = mode and mode.preintro == true
  self.preintro = preintro
  local xr = r and r.xr
  if self.bootSkipped then return false end
  if not self:allowed() and not self.failure then
    if self.shown then self:_hide(r) end
    if self.prep and self.prep:isActive() then self.prep:update(game, 0) end -- notices the switch and stops cleanly
    return false
  end
  if self.prep and self.prep:isTerminal() and not self.failure then
    if self.shown then self:_hide(r) end
    return false
  end
  -- paused (menu, battle, a failed renderer, no XR session): the live game runs as usual, the precache waits
  if (self.ctx.android == true and not preintro and not (xr and xr.started)) or battle3d or menuOpen or (failed and not self.failure) or not game or (game.phase ~= "field" and not (preintro and game.phase == "boot")) then
    if self.shown then self:_hide(r) end
    return false
  end
  if self.failure then
    local ctl = xr and xr.lastControls
    local down = preintro and mode.bootB == true or not preintro and (self.ctx.android == true and ctl and ctl.b == true
      or self.ctx.android ~= true and love and love.keyboard and love.keyboard.isDown("return") == true)
    if self.failureWas ~= nil and down and not self.failureWas then
      self.failure, self.failedDismissed = nil, true
      self:_hide(r)
      return false
    end
    self.failureWas = down == true
    self.shown = true
    return true
  end
  if self.failedDismissed then return false end
  -- A fresh B after the native placeholder was painted can skip before
  -- constructing a driver; it remains skipped for this game session.
  if preintro and mode.bootPressed and not self.prep then
    self.bootSkipped=true
    self:_hide(r)
    return false
  end
  -- Announce first, and require an actually presented panel/window frame before
  -- cache validation, planning, uploads or collection can begin.
  if not self.presented then
    self.shown = true
    if xr then xr.panelFollow = true end
    return true
  end
  local prep = self:ensure(r)
  if not prep then self.failure = self.failed or "unavailable"; self.shown = true; return true end
  -- B / Y: skip for now (a press that began before the screen did is ignored until released)
  local ctl = xr and xr.lastControls
  local b = preintro and mode.bootB == true or not preintro and ctl ~= nil and ctl.b == true
  if self.bWas == nil then self.bWas = b
  else
    if b and not self.bWas and prep:isActive() then prep:skip() end
    self.bWas = b
  end
  if preintro and mode.bootPressed and prep:isActive() then prep:skip() end
  local active = prep:update(game, H.BUDGET_MS / 1000)
  if active then
    self.shown = true
    if xr then xr.panelFollow = true end
  elseif prep.phase == "failed" then
    self.failure, self.failureWas, self.shown = prep.reason or "unavailable", nil, true
    self.ctx.log("World preparation failed: " .. tostring(self.failure))
    return true
  elseif self.shown then
    self:_hide(r)
  end
  return active
end

function H:_hide(r)
  self.shown = false
  self.presented = false
  if r and r.xr then r.xr.panelFollow = false end
  if self.screen then self.screen:release(); self.screen = nil end
end

-- The prepare canvas for the panel quad (never raises). -> Canvas | nil
function H:canvas(w, h)
  if not (self.shown and self.Screen) then return nil end
  local ok, c = pcall(self._canvas, self, w, h)
  if ok then return c end
  self.ctx.log("prepare screen failed: " .. tostring(c))
  self.failed, self.failedDismissed = tostring(c), true
  self:_hide(nil)
  return nil
end

function H:_canvas(w, h)
  local s = self.screen
  if not s then s = self.Screen.new(); self.screen = s end
  local prog = self.failure and { phase = "failed", done = 0, total = 0, frac = 0 } or self.prep and self.prep:progress(self.prog) or { phase = "check", done = 0, total = 0, frac = 0 }
  prog.canSkip = not self.failure and (self.preintro or self.ctx.android == true) and self.prep ~= nil and self.prep:isActive()
  prog.continueHint = self.failure and ((self.preintro or self.ctx.android == true) and "Press B to continue with on-demand loading." or "Press Enter to continue with on-demand loading.") or nil
  return s:canvas(w, h, prog, self.clock())
end

-- Call only after the outer renderer successfully presented the screen.
function H:skipSession(r)
  self:release(r)
  self.bootSkipped = true
end

function H:showFailure(reason)
  self.failure, self.failureWas, self.shown = tostring(reason), nil, true
end

function H:presentedFrame()
  if self.shown then self.presented = true end
end

function H:status()
  local p = self.prep
  if not p then return { phase = self.bootSkipped and "skipped" or self.failed and "failed" or "idle", reason = self.failed } end
  local s = {}
  for k, v in pairs(p.stats) do s[k] = v end
  s.phase, s.reason, s.done, s.total = p.phase, p.reason, p.done, p.total
  s.storageFails = p.storageFails
  return s
end

-- The switch turned ON again, or the cache was cleared: look at the cache again at the next opportunity
function H:rearm()
  if self.prep then self.prep:rearm() end
  self.bWas, self.presented = nil, false
  self.failure, self.failureWas, self.failedDismissed, self.failed, self.bootSkipped = nil, nil, nil, nil, nil
end

function H:release(r)
  self:_hide(r)
  if self.prep and self.prep:isActive() then self.prep:skip(); pcall(self.prep.update, self.prep, nil, 0) end
  self.prep, self.bWas = nil, nil -- a new session starts a fresh driver
  self.failure, self.failureWas, self.failedDismissed, self.failed, self.bootSkipped = nil, nil, nil, nil, nil
end

-- The switch (or WORLD CACHE) was turned OFF: stop a running precache at once (main.lua stops calling frame())
function H:switchedOff(r)
  self:_hide(r)
  if self.prep and self.prep:isActive() then pcall(self.prep.update, self.prep, nil, 0) end
end

return H
