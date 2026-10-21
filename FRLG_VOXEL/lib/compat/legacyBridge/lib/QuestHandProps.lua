-- W4 P2: copied verbatim (no logic changes) from the fl16 game.love lab copy
-- at source/mods/BATTLE_ART_QUEST_COMPAT/lib/QuestHandProps.lua
-- (local verified crystal-fishing-20260925/fl16/game.love, per the
-- Q1 fl16-payload decision -- w4/P2_DECISIONS.md). Self-contained: only V.require
-- of sibling lib files here, no mod.find, no Gen2-only engine requires, so it needed
-- no edit to serve VRITK_FRLG_HOST as well as BATTLE_ART_QUEST_COMPAT.
-- Optional tracked-hand presentation seam for Quest companion mods.
-- Providers receive the same right-hand world model used by the native
-- Battle Art stereo renderer and draw once inside each physical eye.
local V = ...

local VRRig = V.require("VRRig")

local QuestHandProps = {}
local providers = {}
local MAX_CONSECUTIVE_FAILURES = 3

local function providerIds()
  local ids = {}
  for id in pairs(providers) do ids[#ids + 1] = id end
  table.sort(ids)
  return ids
end

local function safeClear(entry)
  entry.frameReady = false
  entry.lastModel = nil
  if type(entry.provider.clear) == "function" then
    pcall(entry.provider.clear)
  end
end

local function recordFailure(entry, stage, err)
  entry.lastError = tostring(stage) .. ": " .. tostring(err)
  entry.consecutiveErrors = (tonumber(entry.consecutiveErrors) or 0) + 1
  if entry.consecutiveErrors >= MAX_CONSECUTIVE_FAILURES then
    entry.failed = true
  end
  safeClear(entry)
end

function QuestHandProps.register(id, provider)
  if type(id) ~= "string" or id == "" or type(provider) ~= "table" then
    return false, "invalid hand-prop provider"
  end
  if type(provider.active) ~= "function"
     or type(provider.place) ~= "function"
     or type(provider.draw) ~= "function" then
    return false, "provider requires active/place/draw"
  end
  local old = providers[id]
  if old then safeClear(old) end
  providers[id] = {
    provider = provider,
    frameReady = false,
    failed = false,
    lastModel = nil,
    lastError = nil,
    consecutiveErrors = 0,
  }
  return true
end

function QuestHandProps.unregister(id, provider)
  local entry = providers[id]
  if not entry or (provider ~= nil and entry.provider ~= provider) then
    return false
  end
  safeClear(entry)
  providers[id] = nil
  return true
end

-- Called once before both eye renders. Released Balls may keep their last
-- world model through a brief controller-tracking loss.
function QuestHandProps.place(handPose, pivot, anchor, scale, yaw)
  for _, id in ipairs(providerIds()) do
    local entry = providers[id]
    if entry and not entry.failed then
      local okActive, active = pcall(entry.provider.active)
      if not okActive then
        recordFailure(entry, "active", active)
      elseif active == true then
        local trackingOptional = false
        if not handPose and type(entry.provider.trackingOptional) == "function" then
          local okOptional, optional = pcall(entry.provider.trackingOptional)
          if not okOptional then
            recordFailure(entry, "trackingOptional", optional)
          else
            trackingOptional = optional == true
          end
        end
        if not entry.failed and (handPose or trackingOptional) then
          local model = entry.lastModel
          if handPose then
            local okModel, made = pcall(VRRig.propMatrix,
              handPose, pivot, anchor, scale, yaw)
            if okModel then
              model = made
              entry.lastModel = made
            else
              recordFailure(entry, "propMatrix", made)
            end
          end
          if not entry.failed then
            local okPlace, placeErr = pcall(entry.provider.place,
              model, handPose)
            entry.frameReady = okPlace
            if not okPlace then recordFailure(entry, "place", placeErr) end
          end
        elseif not entry.failed then
          safeClear(entry)
        end
      else
        entry.consecutiveErrors = 0
        safeClear(entry)
      end
    end
  end
end

function QuestHandProps.clear()
  for _, entry in pairs(providers) do safeClear(entry) end
end

-- Optional semantic bridge: companion props may name the hand that is still
-- physically holding them. The host uses this only to pose its own hand mesh;
-- providers continue to own all item geometry and release timing.
function QuestHandProps.heldHands()
  local held = {}
  for _, id in ipairs(providerIds()) do
    local entry = providers[id]
    local fn = entry and not entry.failed and entry.provider.heldHand
    if type(fn) == "function" then
      local ok, side = pcall(fn)
      if ok and (side == "left" or side == "right") then held[side] = true end
    end
  end
  return held
end

function QuestHandProps.draw()
  for _, id in ipairs(providerIds()) do
    local entry = providers[id]
    if entry and entry.frameReady and not entry.failed then
      local ok, drawErr = pcall(entry.provider.draw)
      if not ok then
        recordFailure(entry, "draw", drawErr)
      else
        entry.consecutiveErrors = 0
      end
    end
  end
end

function QuestHandProps.count()
  local total = 0
  for _ in pairs(providers) do total = total + 1 end
  return total
end

function QuestHandProps.debugState()
  local out = { version = 1, providers = {} }
  for _, id in ipairs(providerIds()) do
    local entry = providers[id]
    out.providers[#out.providers + 1] = {
      id = id,
      failed = entry.failed == true,
      frameReady = entry.frameReady == true,
      lastError = entry.lastError,
      consecutiveErrors = tonumber(entry.consecutiveErrors) or 0,
    }
  end
  return out
end


-- Registration capability, never inferred from a stale frame's absence.
function QuestHandProps.flashCoverage()
 for id,e in pairs(providers)do
  local p=e.provider or e.layer
  if not e.failed then
   if not p or p.nativeFlashCovered~=true then return false,'unmasked provider: '..tostring(id)end
   if p.flashCoverage then local ok,covered,why=pcall(p.flashCoverage);if not ok or not covered then return false,why or 'provider capability failed'end end
  end
 end
 return true
end
return QuestHandProps
