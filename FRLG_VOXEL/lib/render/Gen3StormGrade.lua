-- Gen 3 lightning terrain channel. One shared result per prepared frame;
-- the eye passes consume it without sampling or advancing weather again.
local V = ...
local AtmosTime = V.require('render/AtmosTime')
local AtmosState = V.require('render/AtmosState')
local M = {}
function M.context(view, hour)
  local ctx = { hour = hour, outdoor = true }
  local mod = V.mod
  local handle = mod and mod.find and mod.find('the_world_weather_quest_lite_private')
  local ex = handle and handle.exports
  if not (ex and ex.gen3 and ex.gen3.lightning and ex.lib and ex.lib.require) then return ctx end
  local ok, storm = pcall(ex.lib.require, 'QuestStorm')
  if not (ok and storm and type(storm.flash) == 'function') then return ctx end
  local okF, flash = pcall(storm.flash)
  if not okF then return ctx end
  local now = love and love.timer and love.timer.getTime and love.timer.getTime() or 0
  view.stormFlashLimiter = view.stormFlashLimiter or AtmosState.FlashLimiter.new()
  local want = math.max(0, math.min(1, tonumber(flash) or 0))
  if want <= .02 then view.stormFlashSuppressed = false end
  local limited = view.stormFlashLimiter:step(want, now)
  if want > .02 and limited == 0 then view.stormFlashSuppressed = true end
  if view.stormFlashSuppressed then limited = 0 end
  ctx.flash = limited
  local base = AtmosTime.at(hour).mul
  ctx.tint = { base[1] + AtmosState.FLASH_CAP * limited,
    base[2] + AtmosState.FLASH_CAP * limited, base[3] + AtmosState.FLASH_CAP * limited }
  return ctx
end
return M
