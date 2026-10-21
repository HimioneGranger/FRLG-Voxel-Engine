-- UntamedGateCompat: gives STOCK Untamed Advanced the native-provider gate that the
-- Lab 49-57 edited Untamed carried in lib/native_provider_gate.lua, from outside.
--
-- Added to untamed_advanced's exports (default ON = stock behaviour, nothing changed):
--   setNativeProviderEnabled(on) -> true | false, reason   (refuses while busy)
--   nativeProviderEnabled()      -> boolean
--   nativeProviderBusy()         -> false | true, reason
-- busy = a battle is active, or Owe.busy() or Follower.talking() or Field.locked.
--
-- "Gate off" must equal "Untamed does nothing". The edited Untamed returned early in every
-- engine wrapper and wrapped each of its hooks and events. Stock Untamed keeps its raw
-- originals private, so from outside this is done by making every wrapper's own body inert:
--   * Owe.reset(); Follower.reset(); E.invalidateMapCaches()   (what the edited onChange did)
--     leaves every pooled actor and effect inactive, so FieldView.draw / FX.drawFront /
--     Objects.forDraw / Objects.blocks / Collision.canEnter / QuestRecorder.capture have
--     nothing to add or collide with;
--   * E.C.OW_FOLLOWERS_ENABLED, WE_OW_ENCOUNTERS, OW_STATIC_RESKIN are forced false, which
--     makes Field.update / Field.interact / Warp.startDoorEntrance / Movement.start /
--     Heal.start / OwSprites.draw run their raw function only;
--   * the two unconditional calls inside the Field.update wrapper, Owe.updateAmbientCry and
--     E.tickGrass, are replaced by no-ops (both reached through live tables);
--   * every hook and event entry owned by untamed_advanced is wrapped to pass straight
--     through (hooks: nextFn(...); events: no-op), then unwrapped on enable.
-- Turning ON undoes all of it, then repeats the edited onChange(true): Owe.reset(),
-- Follower.reset(), E.invalidateMapCaches(), re-read the options through Untamed's own
-- mod.options_changed listener, Follower.update(). Uninstall puts the same function
-- objects back and re-enables Untamed. See the report for the known residual differences.
local M = {}

local UNTAMED = "untamed_advanced"
local OWNER = "VRITK_FRLG_HOST"
local FORCED_OFF = { "OW_FOLLOWERS_ENABLED", "WE_OW_ENCOUNTERS", "OW_STATIC_RESKIN" }

local state = nil

local function req(name)
  local ok, m = pcall(require, name)
  if ok and type(m) == "table" then return m end
  return nil
end

local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end

local function busyNow(st)
  if st.battle then return true, "battle active" end
  local E = st.E
  local ok, v = pcall(function()
    return E.Owe.busy() or E.Follower.talking() or (E.Field and E.Field.locked)
  end)
  if not ok then return true, "busy query failed" end
  if v then return true, "native transaction active" end
  return false
end

local function entriesOwnedByUntamed(Runtime)
  local list = {}
  local listeners = Runtime.events and Runtime.events.listeners
  for name, entries in pairs(type(listeners) == "table" and listeners or {}) do
    for _, e in ipairs(entries) do
      if type(e) == "table" and e.owner == UNTAMED and type(e.callback) == "function" then
        list[#list + 1] = { kind = "event", name = name, entry = e }
      end
    end
  end
  local chains = Runtime.hooks and Runtime.hooks.chains
  for name, entries in pairs(type(chains) == "table" and chains or {}) do
    for _, e in ipairs(entries) do
      if type(e) == "table" and e.owner == UNTAMED and type(e.callback) == "function" then
        list[#list + 1] = { kind = "hook", name = name, entry = e }
      end
    end
  end
  return list
end

-- Make Untamed do nothing. Reversible; records every touched slot.
local function neutralise(st)
  local E, C = st.E, st.E.C
  local n = { wrapped = {}, saved = {}, stubs = {} }
  for _, k in ipairs(FORCED_OFF) do
    n.saved[#n.saved + 1] = { key = k, value = C[k] }
    C[k] = false
  end
  local function stub(tbl, key)
    local orig = tbl[key]
    local mine = function() end
    n.stubs[#n.stubs + 1] = { tbl = tbl, key = key, orig = orig, mine = mine }
    tbl[key] = mine
  end
  stub(E.Owe, "updateAmbientCry")
  stub(E, "tickGrass")
  for _, row in ipairs(entriesOwnedByUntamed(st.Runtime)) do
    local entry, orig = row.entry, row.entry.callback
    local mine
    if row.kind == "hook" then
      -- gate off: pass straight to the next link, exactly what the edited gate did
      mine = function(nextFn, ...) return nextFn(...) end
    else
      mine = function() end
    end
    entry.callback = mine
    n.wrapped[#n.wrapped + 1] = { entry = entry, orig = orig, mine = mine }
  end
  st.neutral = n
end

local function restoreNeutral(st)
  local n = st.neutral
  if not n then return end
  for i = #n.wrapped, 1, -1 do
    local w = n.wrapped[i]
    if w.entry.callback == w.mine then w.entry.callback = w.orig end
  end
  for i = #n.stubs, 1, -1 do
    local s = n.stubs[i]
    if s.tbl[s.key] == s.mine then s.tbl[s.key] = s.orig end
  end
  for _, s in ipairs(n.saved) do st.E.C[s.key] = s.value end
  st.neutral = nil
end

-- the options_changed listener Untamed registered; calling it re-runs its readOptions()
local function optionsListener(Runtime)
  local listeners = Runtime.events and Runtime.events.listeners
  local list = type(listeners) == "table" and listeners["mod.options_changed"]
  for _, e in ipairs(list or {}) do
    if e.owner == UNTAMED and type(e.callback) == "function" then return e end
  end
  return nil
end

local function enableSequence(st)
  local E = st.E
  E.Owe.reset(); E.Follower.reset(); E.invalidateMapCaches()
  local listener = optionsListener(st.Runtime)
  if not listener then error("untamed options listener not found", 0) end
  listener.callback({ mod = UNTAMED, key = "*" })
  E.Follower.update()
end

local function set(st, on)
  on = on == true
  if on == st.enabled then return true end
  local busy, why = busyNow(st)
  if busy then return false, why end
  if not on then
    local ok, err = pcall(function()
      st.E.Owe.reset(); st.E.Follower.reset(); st.E.invalidateMapCaches()
    end)
    if not ok then return false, tostring(err) end
    local okN, errN = pcall(neutralise, st)
    if not okN then
      pcall(restoreNeutral, st)
      return false, tostring(errN)
    end
    st.enabled = false
    st.epoch = st.epoch + 1
    return true
  end
  -- turning ON: undo the neutralisation first so the re-read options and the follower
  -- refresh run against the real (stock) functions
  restoreNeutral(st)
  local ok, err = pcall(enableSequence, st)
  if not ok then
    pcall(neutralise, st) -- fail closed: stay off
    return false, tostring(err)
  end
  st.enabled = true
  st.epoch = st.epoch + 1
  return true
end

function M.install(find, log)
  log = type(log) == "function" and log or function() end
  if state then return true, "already installed" end
  local rec = type(find) == "function" and find(UNTAMED) or nil
  local ex = type(rec) == "table" and rec.exports or nil
  if type(ex) ~= "table" then return false, "untamed_advanced not loaded" end
  if type(ex.setNativeProviderEnabled) == "function" then return true, "native gate present" end
  local E = ex.engine
  if type(E) ~= "table" or type(E.C) ~= "table" or type(E.Owe) ~= "table"
      or type(E.Follower) ~= "table" or type(E.Field) ~= "table" then
    return false, "untamed engine export incomplete"
  end
  if not (fn(E.Owe, "reset") and fn(E.Owe, "busy") and fn(E.Owe, "updateAmbientCry")
      and fn(E.Follower, "reset") and fn(E.Follower, "update") and fn(E.Follower, "talking")
      and fn(E, "invalidateMapCaches") and fn(E, "tickGrass")) then
    return false, "untamed engine export lacks the expected functions"
  end
  local Runtime = req("src.mods.Runtime")
  if not (Runtime and type(Runtime.events) == "table" and type(Runtime.events.listeners) == "table"
      and type(Runtime.hooks) == "table" and type(Runtime.hooks.chains) == "table"
      and type(Runtime.events.on) == "function") then
    return false, "mod runtime buses unavailable"
  end
  if not optionsListener(Runtime) then return false, "untamed options listener not found" end

  local st = { E = E, ex = ex, Runtime = Runtime, enabled = true, battle = false, epoch = 0, unsub = {} }
  local function sub(name, cb)
    local un = Runtime.events:on(name, cb, 0, OWNER)
    if type(un) == "function" then st.unsub[#st.unsub + 1] = un end
  end
  sub("battle.started", function() st.battle = true end)
  sub("battle.ended", function() st.battle = false end)

  st.exports = {
    setNativeProviderEnabled = function(on) return set(st, on) end,
    nativeProviderEnabled = function() return st.enabled end,
    nativeProviderBusy = function() return busyNow(st) end,
  }
  for k, v in pairs(st.exports) do ex[k] = v end
  state = st
  log("untamed native-provider gate installed (default ON)")
  return true
end

function M.uninstall()
  local st = state
  if not st then return true end
  if not st.enabled then
    restoreNeutral(st)
    pcall(enableSequence, st)
    st.enabled = true
  end
  for _, un in ipairs(st.unsub) do pcall(un) end
  for k, v in pairs(st.exports) do
    if st.ex[k] == v then st.ex[k] = nil end
  end
  state = nil
  return true
end

function M.status()
  local st = state
  if not st then return { installed = false } end
  local busy, why = busyNow(st)
  return { installed = true, enabled = st.enabled, busy = busy, why = why, epoch = st.epoch,
    neutralised = st.neutral ~= nil, wrapped = st.neutral and #st.neutral.wrapped or 0 }
end

return M
