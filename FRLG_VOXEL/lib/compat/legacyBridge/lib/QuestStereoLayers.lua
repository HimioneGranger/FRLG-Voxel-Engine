-- W4 P2: copied verbatim (no logic changes) from the fl16 game.love lab copy
-- at source/mods/BATTLE_ART_QUEST_COMPAT/lib/QuestStereoLayers.lua
-- (local verified crystal-fishing-20260925/fl16/game.love, per the
-- Q1 fl16-payload decision -- w4/P2_DECISIONS.md). Self-contained: only V.require
-- of sibling lib files here, no mod.find, no Gen2-only engine requires, so it needed
-- no edit to serve VRITK_FRLG_HOST as well as BATTLE_ART_QUEST_COMPAT.
-- Generic stereo-scene extension seam for optional Quest companion mods.
-- Battle Art Quest Compatibility owns when extensions run, but it owns no
-- companion-specific models, UI, interaction rules, or assets.
--
-- W4 P2 review fix #3 (REVIEW_VRITK_P2.md): one addition since the verbatim
-- copy above -- Layers.anyLive() at the bottom of this file. No-allocation,
-- read-only (iterates the existing `entries` table, touches no other
-- state), added so VRITK_FRLG_HOST's own main.lua can gate its per-frame
-- input.claim on "at least one registered VRITK layer is actually live"
-- instead of claiming unconditionally whenever the bridge itself is bound.

local Layers = {}
local entries = {}
local MAX_CONSECUTIVE_FAILURES = 3

local function ids()
  local out = {}
  for id in pairs(entries) do out[#out + 1] = id end
  table.sort(out)
  return out
end

local function fail(entry, stage, detail)
  entry.lastError = tostring(stage) .. ": " .. tostring(detail)
  entry.consecutiveErrors = entry.consecutiveErrors + 1
  if entry.consecutiveErrors >= MAX_CONSECUTIVE_FAILURES then
    entry.failed = true
  end
end

function Layers.register(id, layer)
  if type(id) ~= "string" or id == "" or type(layer) ~= "table"
      or type(layer.update) ~= "function"
      or type(layer.draw) ~= "function" then
    return false, "stereo layer requires id/update/draw"
  end
  local old = entries[id]
  if old and type(old.layer.invalidate) == "function" then
    pcall(old.layer.invalidate)
  end
  entries[id] = {
    layer = layer,
    failed = false,
    consecutiveErrors = 0,
    lastError = nil,
  }
  return true
end

function Layers.unregister(id, layer)
  local entry = entries[id]
  if not entry or (layer ~= nil and entry.layer ~= layer) then return false end
  if type(entry.layer.invalidate) == "function" then
    pcall(entry.layer.invalidate)
  end
  entries[id] = nil
  return true
end

function Layers.update(context)
  local records = {}
  for _, id in ipairs(ids()) do
    local entry = entries[id]
    if entry and not entry.failed then
      local ok, scene = pcall(entry.layer.update, context)
      if ok then
        entry.consecutiveErrors, entry.lastError = 0, nil
        if scene ~= nil then
          records[#records + 1] = { id = id, layer = entry.layer, scene = scene }
        end
      else
        fail(entry, "update", scene)
      end
    end
  end
  return records
end

function Layers.draw(records)
  for _, record in ipairs(type(records) == "table" and records or {}) do
    local entry = entries[record.id]
    if entry and not entry.failed and entry.layer == record.layer then
      local ok, detail = pcall(entry.layer.draw, record.scene)
      if ok then
        entry.consecutiveErrors, entry.lastError = 0, nil
      else
        fail(entry, "draw", detail)
      end
    end
  end
end

function Layers.invalidate()
  for _, entry in pairs(entries) do
    if type(entry.layer.invalidate) == "function" then
      pcall(entry.layer.invalidate)
    end
  end
end

function Layers.clear()
  Layers.invalidate()
  for id in pairs(entries) do entries[id] = nil end
end

-- W4 P2 review fix #3: true while at least one registered layer is not
-- failed-off. No allocation, safe to call every frame.
function Layers.anyLive()
  for _, e in pairs(entries) do
    if not e.failed then return true end
  end
  return false
end

function Layers.debugState()
  local out = { version = 1, layers = {} }
  for _, id in ipairs(ids()) do
    local entry = entries[id]
    out.layers[#out.layers + 1] = {
      id = id,
      failed = entry.failed == true,
      consecutiveErrors = entry.consecutiveErrors,
      lastError = entry.lastError,
    }
  end
  return out
end


-- Registration capability, never inferred from a stale frame's absence.
function Layers.flashCoverage()
 for id,e in pairs(entries)do
  local p=e.provider or e.layer
  if not e.failed then
   if not p or p.nativeFlashCovered~=true then return false,'unmasked provider: '..tostring(id)end
   if p.flashCoverage then local ok,covered,why=pcall(p.flashCoverage);if not ok or not covered then return false,why or 'provider capability failed'end end
  end
 end
 return true
end
return Layers
