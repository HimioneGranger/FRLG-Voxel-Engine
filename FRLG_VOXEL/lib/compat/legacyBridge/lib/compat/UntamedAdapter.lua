-- Track C (Lab 54): the Untamed provider as a router adapter. Game-neutral:
-- untamed_advanced (pinned 1.0.0-beta.5) owns the overworld actors and its own
-- native gate (untamed_advanced/native_provider_gate.lua); FRLG_OW_MONS owns
-- the owMons v1 API and the 3D cards. This file only wires the two to the
-- router; it adds no behaviour of its own, so routing to Untamed is the
-- pre-router control path (FRLG_OW_MONS cards, FollowerSendOut).
local M = {}

M.ID = "untamed_advanced"
M.PIN = "1.0.0-beta.5"
M.FACADE = "FRLG_OW_MONS"

function M.new(find)
  local A = { id = M.ID, label = "UNTAMED", optionMods = { [M.FACADE] = true } }
  local function handle() local h = find(M.ID); return h end
  local function facade()
    local f = find(M.FACADE)
    local api = f and f.exports and f.exports.owMons
    if type(api) == "table" and api.api == 1 then return api end
    return nil
  end

  function A:gate()
    local h = handle()
    return h and h.exports or nil
  end

  function A:probe()
    local h = handle()
    if not h then return false, "untamed_advanced not loaded" end
    if h.version ~= M.PIN then return false, ("untamed_advanced %s is not %s"):format(tostring(h.version), M.PIN) end
    local ex = h.exports or {}
    if type(ex.setNativeProviderEnabled) ~= "function" then return false, "untamed native gate missing" end
    local api = facade()
    if not api then return false, "FRLG_OW_MONS facade missing" end
    local ok, st = pcall(api.status)
    if ok and type(st) == "table" and st.bound == false then
      return false, "FRLG_OW_MONS idle: " .. tostring(st.reason)
    end
    self.api = api
    return true
  end

  local function cards(on)
    local api = facade()
    local d = api and api._debug
    if d and type(d.setProviderEnabled) == "function" then pcall(d.setProviderEnabled, on) end
  end

  -- Called once per switch, never per frame (the Emerald router flipped this
  -- on every refresh).
  function A:activate()
    self.api = facade() or self.api
    if not self.api then return false, "FRLG_OW_MONS facade missing" end
    cards(true)
    return true
  end
  function A:deactivate() cards(false) end
  return A
end

return M
