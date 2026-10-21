-- W4 P2: copied verbatim (no logic changes) from the fl16 game.love lab copy
-- at source/mods/BATTLE_ART_QUEST_COMPAT/lib/VRHandPose.lua
-- (local verified crystal-fishing-20260925/fl16/game.love, per the
-- Q1 fl16-payload decision -- w4/P2_DECISIONS.md). Self-contained: only V.require
-- of sibling lib files here, no mod.find, no Gen2-only engine requires, so it needed
-- no edit to serve VRITK_FRLG_HOST as well as BATTLE_ART_QUEST_COMPAT.
-- Renderer-neutral Quest hand pose adapter. It converts OpenXR controller
-- tracking into semantic hand instructions and owns no visual data.

local HandPose = {}

HandPose.STYLE_ID = "ash_fingerless_v1"

local function clamp(value)
  value = tonumber(value) or 0
  if value ~= value then return 0 end
  return math.max(0, math.min(1, value))
end

local function one(controls, side)
  controls = type(controls) == "table" and controls or {}
  local suffix = side == "left" and "L" or "R"
  local tracked = controls[side == "left" and "handl" or "handr"]
  if type(tracked) ~= "table" or type(tracked.pos) ~= "table"
      or type(tracked.quat) ~= "table" then
    return { tracked = false, side = side }
  end
  local grip = clamp(controls["grip" .. suffix])
  local trigger = clamp(controls["trigger" .. suffix])
  local thumbRest = controls["thumbRest" .. suffix] == true
  local combined = grip >= 0.35 and trigger >= 0.35
  local pointing = grip >= 0.35 and trigger <= 0.20
  return {
    tracked = true,
    side = side,
    pose = {
      position = { tracked.pos[1], tracked.pos[2], tracked.pos[3] },
      orientation = {
        tracked.quat[1], tracked.quat[2], tracked.quat[3], tracked.quat[4],
      },
    },
    model = {
      id = HandPose.STYLE_ID,
      styleId = HandPose.STYLE_ID,
      side = side,
      grip = grip,
      trigger = trigger,
      thumbRest = thumbRest,
      pointing = pointing,
      combined = combined,
      closedFist = combined and thumbRest,
      holding = false,
    },
  }
end

function HandPose.fromControls(controls)
  return {
    left = one(controls, "left"),
    right = one(controls, "right"),
  }
end

return HandPose
