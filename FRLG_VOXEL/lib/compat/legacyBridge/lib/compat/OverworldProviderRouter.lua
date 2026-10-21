-- Track C (Lab 54): one overworld-Pokemon provider at a time, chosen by a cached,
-- event-driven router. Game-neutral: it knows adapters only through the interface
-- below; every game or provider assumption lives in the adapter files
-- (WildsFireRedAdapter, UntamedAdapter, ...). Design: integration-20261010
-- WILDS_FIRERED_DESIGN.md section 4.
--
-- Adapter interface (all optional fields may be absent):
--   id, label                      "wilds_of_hoenn", "WILDS"
--   probe() -> ok, why             cached detection; called only on the events below
--   gate() -> exports | nil        the provider's native gate (setNativeProviderEnabled,
--                                  nativeProviderEnabled, nativeProviderBusy) while the
--                                  mod is loaded, candidate or not
--   activate(router) -> ok, why    after its gate is on: register cards, seams
--   deactivate(router)             before its gate goes off: unregister cards
--   onEpoch(reason)                map / save / checkpoint boundary
--   api                            the provider's owMons v1 table
--
-- Selection (VR option ow_provider, stored by the user only):
--   AUTO    -> the first candidate in ORDER (Wilds first)
--   WILDS / UNTAMED -> that provider when it is a candidate, else AUTO for this
--             session only (the stored choice is never rewritten for that)
--   OFF     -> no provider; every native gate off
-- One-time migration (user decision 2026-10-10 #1): a setup that predates the
-- router ran Untamed implicitly (no build before this one stored ow_provider).
-- It moves to AUTO (Wilds) without rewriting anything: the first session with a
-- compatible Wilds stores a marker and logs the move. A stored "untamed" is
-- always a choice the user made through this router and is never rewritten. Mod Manager enable flags are
-- never changed and nothing is uninstalled.
--
-- Detection runs on mods.loaded, mod.options_changed, save.loaded,
-- save.created, checkpoint.restored and game.ready. map.entered / map.exited
-- only bump the adapters' epoch. A switch refused as busy is retried on
-- battle.ended, world.stepped and map.entered (at most RETRY_MAX times). No
-- input.step wrap, no per-frame work here: API calls read the cached choice.
local M = {}

M.ORDER = { "wilds_of_hoenn", "untamed_advanced" }
M.OPTION_KEY = "ow_provider"
M.MARKER_KEY = "ow_provider_migrated"
M.CHOICES = { { "AUTO", "auto" }, { "WILDS", "wilds" }, { "UNTAMED", "untamed" }, { "OFF", "off" } }
M.CHOICE_TO_ID = { wilds = "wilds_of_hoenn", untamed = "untamed_advanced" }
M.RETRY_MAX = 40
M.LOG_MAX = 24

local function short(why)
  why = tostring(why or "")
  return why
end

function M.new(env)
  env = env or {}
  local R = {
    env = env, adapters = {}, byId = {}, candidate = {}, why = {},
    active = nil, activeId = "none", reason = "waiting for mods.loaded", reasonCode = "WAIT",
    explicit = false, choice = "auto", switchError = nil, pending = nil, attempts = 0,
    generation = 0, logCount = 0, detected = false, migration = nil,
  }

  local function log(fmt, ...)
    if R.logCount >= M.LOG_MAX then return end
    R.logCount = R.logCount + 1
    local ok, line = pcall(string.format, fmt, ...)
    if env.log then pcall(env.log, "[overworld-provider] " .. (ok and line or fmt)) end
  end
  R.log = log

  function R:add(adapter)
    self.adapters[#self.adapters + 1] = adapter
    self.byId[adapter.id] = adapter
    return adapter
  end

  -- ------------------------------------------------------------ detection (events only)
  function R:detect(cause)
    for _, a in ipairs(self.adapters) do
      local ok, res, why = pcall(a.probe, a)
      if not ok then res, why = false, "probe error: " .. tostring(res) end
      self.candidate[a.id] = res == true
      self.why[a.id] = res == true and nil or short(why or "unavailable")
    end
    self.detected = true
    self.detectCause = cause
  end

  local function option(key)
    if env.getOption then
      local ok, v = pcall(env.getOption, key)
      if ok then return v end
    end
    return nil
  end

  -- The stored choice (review fix: never reinterpreted; an explicit UNTAMED wins).
  function R:effectiveChoice()
    local stored = option(M.OPTION_KEY)
    if stored ~= "auto" and stored ~= "wilds" and stored ~= "untamed" and stored ~= "off" then stored = "auto" end
    local migrating = option(M.MARKER_KEY) ~= true and stored == "auto" and self.candidate.wilds_of_hoenn == true
    return stored, stored, migrating
  end

  -- -> targetId|nil, code, text, explicit
  function R:choose()
    local choice, stored, migrating = self:effectiveChoice()
    self.choice, self.storedChoice, self.migrating = choice, stored, migrating
    if choice == "off" then return nil, "OFF CHOSEN", "overworld Pokemon turned off (OVERWORLD MONS: OFF)", true end
    local wanted = M.CHOICE_TO_ID[choice]
    local fellBack
    if wanted then
      if self.candidate[wanted] then
        return wanted, "CHOSEN", "explicit choice " .. choice, true
      end
      fellBack = ("%s unavailable (%s); AUTO for this session"):format(choice, tostring(self.why[wanted] or "not loaded"))
    end
    for i, id in ipairs(M.ORDER) do
      if self.byId[id] and self.candidate[id] then
        if fellBack then return id, "FALLBACK", fellBack .. " -> " .. id, false end
        if i == 1 then return id, "PREFERRED", "AUTO: " .. id .. " preferred", false end
        local first = M.ORDER[1]
        return id, "NO " .. ((self.byId[first] and self.byId[first].label) or "WILDS"),
          ("AUTO: %s (%s unavailable: %s)"):format(id, first, tostring(self.why[first] or "not loaded")), false
      end
    end
    return nil, "NONE FOUND", fellBack or "no compatible overworld provider is loaded", false
  end

  -- ------------------------------------------------------------ switching
  local function gateOf(a)
    local ok, g = pcall(a.gate, a)
    if ok and type(g) == "table" and type(g.setNativeProviderEnabled) == "function" then return g end
    return nil
  end
  local function gateOn(g)
    if type(g.nativeProviderEnabled) ~= "function" then return true end
    local ok, v = pcall(g.nativeProviderEnabled)
    return not ok or v == true
  end
  local function busyOf(g)
    if not g then return false end
    if type(g.nativeProviderBusy) ~= "function" then return true, "no busy query" end
    local ok, v, why = pcall(g.nativeProviderBusy)
    if not ok then return true, "busy query failed" end
    return v == true, why
  end
  R._gateOf = gateOf

  -- Make `targetId` (or nil) the only provider with its native gate on.
  -- -> true | false, why (busy: pending set)
  function R:apply(targetId, code, text, explicit)
    local target = targetId and self.byId[targetId] or nil
    -- 1. busy check on every provider whose gate would change, before anything moves
    for _, a in ipairs(self.adapters) do
      local g = gateOf(a)
      if g then
        local want = (a == target)
        if gateOn(g) ~= want or (a == target and self.active ~= a) or (a == self.active and a ~= target) then
          local busy, why = busyOf(g)
          if busy then
            self.pending = { id = targetId, code = code, text = text, explicit = explicit }
            self.switchError = ("%s busy (%s); switch deferred"):format(a.id, tostring(why or "transaction"))
            return false, self.switchError
          end
        end
      end
    end
    local previous = self.active
    if target and previous == target then
      local g = gateOf(target)
      if not g or gateOn(g) then
        -- already the active provider: no deactivate / re-activate (that would reset its keys and abort a
        -- capture in flight); only make sure every other gate is off
        for _, a in ipairs(self.adapters) do
          if a ~= target then
            local og = gateOf(a)
            if og and gateOn(og) then pcall(og.setNativeProviderEnabled, false) end
          end
        end
        self.reasonCode, self.reason, self.explicit = code, text, explicit == true
        self.pending, self.attempts = nil, 0
        return true
      end
    end
    -- 2. take every other provider down (cards first, then its gate). Idempotent:
    -- at the first selection both native gates start on (their defaults).
    for _, a in ipairs(self.adapters) do
      if a ~= target and a.deactivate then pcall(a.deactivate, a, self) end
    end
    for _, a in ipairs(self.adapters) do
      if a ~= target then
        local g = gateOf(a)
        if g and gateOn(g) then
          local ok, v, why = pcall(g.setNativeProviderEnabled, false)
          if not ok or v ~= true then
            self.switchError = ("%s refused to stop (%s)"):format(a.id, tostring(ok and why or v))
            log("%s", self.switchError)
          end
        end
      end
    end
    -- 3. bring the target up; roll back to the previous provider on failure
    if target then
      local g = gateOf(target)
      local okOn, why = true, nil
      if g and not gateOn(g) then
        local ok, v, w = pcall(g.setNativeProviderEnabled, true)
        okOn, why = ok and v == true, ok and w or v
      end
      if okOn and target.activate then
        local ok, v, w = pcall(target.activate, target, self)
        okOn, why = ok and v ~= false, ok and w or v
      end
      if not okOn then
        self.switchError = ("%s activation refused (%s)"):format(target.id, tostring(why))
        if g then pcall(g.setNativeProviderEnabled, false) end
        if previous and previous ~= target then
          local pg = gateOf(previous)
          if pg then pcall(pg.setNativeProviderEnabled, true) end
          if previous.activate then pcall(previous.activate, previous, self) end
          self.active, self.activeId = previous, previous.id
        else
          self.active, self.activeId = nil, "none"
        end
        log("%s; kept %s", self.switchError, self.activeId)
        return false, self.switchError
      end
    end
    if self.active ~= target then self.generation = self.generation + 1 end
    self.active, self.activeId = target, target and target.id or "none"
    self.reasonCode, self.reason, self.explicit = code, text, explicit == true
    self.pending, self.attempts = nil, 0
    if self.switchError and self.switchError:find("deferred", 1, true) then self.switchError = nil end
    return true
  end

  function R:select(cause)
    if not self.detected then self:detect(cause) end
    local id, code, text, explicit = self:choose()
    local before = self.activeId
    local ok = self:apply(id, code, text, explicit)
    if not ok and id and not self.pending and self.active ~= self.byId[id] then
      -- activation refused (not busy): drop it for this session and choose again (e.g. AUTO -> Untamed)
      self.candidate[id] = false
      self.why[id] = tostring(self.switchError or "activation refused")
      id, code, text, explicit = self:choose()
      ok = self:apply(id, code, text, explicit)
    end
    if ok then
      self.reasonCode, self.reason = code, text
      if before ~= self.activeId or self.lastLogged ~= code then
        self.lastLogged = code
        log("provider=%s reason=%s (%s) cause=%s gen=%d", self.activeId, code, tostring(text), tostring(cause), self.generation)
      end
    else
      log("switch to %s deferred/refused (%s) cause=%s", tostring(id), tostring(self.switchError), tostring(cause))
    end
    return ok
  end

  function R:refresh(cause)
    self:detect(cause)
    return self:select(cause)
  end

  function R:retryPending(cause)
    local p = self.pending
    if not p then return end
    self.attempts = self.attempts + 1
    if self.attempts > M.RETRY_MAX then
      log("deferred switch to %s abandoned after %d tries (%s)", tostring(p.id), M.RETRY_MAX, tostring(self.switchError))
      self.pending, self.attempts = nil, 0
      return
    end
    local ok = self:apply(p.id, p.code, p.text, p.explicit)
    if ok then log("deferred switch done: provider=%s cause=%s", self.activeId, tostring(cause)) end
  end

  function R:epoch(reason)
    for _, a in ipairs(self.adapters) do
      if a.onEpoch then pcall(a.onEpoch, a, reason, a == self.active) end
    end
  end

  -- ------------------------------------------------------------ migration (decision #1)
  -- write(key, value) -> ok (the persisted option writer). Runs at most once per
  -- session with a writer; the marker makes it once per installation.
  function R:migrate(write)
    if self.migration and self.migration.done then return self.migration end
    if option(M.MARKER_KEY) == true then
      self.migration = { done = true, state = "marker present" }
      return self.migration
    end
    if not self.candidate.wilds_of_hoenn then
      self.migration = { done = false, state = "waiting for a compatible Wilds" }
      return self.migration
    end
    if type(write) ~= "function" then
      self.migration = { done = false, state = "no option writer yet" }
      return self.migration
    end
    local stored = option(M.OPTION_KEY)
    -- marker absent + AUTO (nothing stored) = a setup from before the router,
    -- which ran Untamed implicitly. Only the marker is written; a stored
    -- wilds / untamed / off is the user's own choice and stays as it is.
    local legacyUntamed = stored == nil or stored == "auto"
    local okW = write(M.MARKER_KEY, true) ~= false
    if okW then
      self.migration = { done = true, state = legacyUntamed and "migrated untamed (implicit pre-router default) -> AUTO (Wilds)"
        or ("kept explicit " .. tostring(stored)) }
      log("one-time migration: %s; marker %s stored", self.migration.state, M.MARKER_KEY)
    else
      self.migration = { done = false, state = "option write failed; retried next session" }
      log("one-time migration: %s", self.migration.state)
    end
    return self.migration
  end

  -- ------------------------------------------------------------ status
  function R:status()
    local c = {}
    for _, a in ipairs(self.adapters) do
      c[#c + 1] = { id = a.id, candidate = self.candidate[a.id] == true, why = self.why[a.id] }
    end
    local adapterStatus
    if self.active and self.active.api and type(self.active.api.status) == "function" then
      local ok, s = pcall(self.active.api.status)
      adapterStatus = ok and s or nil
    end
    return {
      provider = self.activeId, label = self.active and self.active.label or "NONE",
      reason = self.reason, reasonCode = self.reasonCode, explicit = self.explicit,
      choice = self.choice, storedChoice = self.storedChoice, migrating = self.migrating,
      candidates = c, switchError = self.switchError,
      pending = self.pending and self.pending.id or nil, generation = self.generation,
      migration = self.migration and self.migration.state or nil,
      adapter = adapterStatus,
    }
  end

  -- ------------------------------------------------------------ owMons v1 facade
  -- Stable table: FRLG_CATCH caches it once. Every call reads the cached
  -- active adapter; nothing here detects or allocates per frame.
  local EMPTY = {}
  local api = { api = 1, providerRouting = true, captureTransactions = 1 }
  local function A() local a = R.active; return a and a.api end
  function api.list()
    local a = A(); if a then return a.list() end
    for i = #EMPTY, 1, -1 do EMPTY[i] = nil end
    return EMPTY
  end
  function api.resolve(key) local a = A(); if a then return a.resolve(key) end; return nil end
  function api.cardImage(rec, facing) local a = A(); if a then return a.cardImage(rec, facing) end; return nil, "no provider" end
  function api.busy() local a = A(); if a then return a.busy() end; return false end
  function api.hide(key, on) local a = A(); if a then return a.hide(key, on) end; return false end
  function api.startBattle(key, mon) local a = A(); if a then return a.startBattle(key, mon) end; return false, "no provider" end
  function api.battleSnapshot() local a = A(); if a and a.battleSnapshot then return a.battleSnapshot() end; return nil end
  function api.despawnCaught(key) local a = A(); if a and a.despawnCaught then return a.despawnCaught(key) end; return false, "no provider" end
  function api.roamerFoe() local a = A(); if a and a.roamerFoe then return a.roamerFoe() end; return nil end
  function api.chainCaught(sp) local a = A(); if a and a.chainCaught then return a.chainCaught(sp) end; return false, "no chain" end
  function api.chain() local a = A(); if a and a.chain then return a.chain() end; return nil end
  -- CaptureTail: the provider that owns a capture started now (held in cur.owner).
  function api.captureOwner() local a = A(); return a or api end
  function api.beginCapture(key, session)
    local a = A(); if a and a.beginCapture then return a.beginCapture(key, session) end
    return nil, "legacy"
  end
  function api.status() return R:status() end
  function api.providerGeneration() return R.generation end
  function api.providerId() return R.activeId end
  R.api = api
  return R
end

-- ------------------------------------------------------------ install
-- env: { find, log, getOption(key), writeOption(game, key, value) -> ok,
--        events (mod.events), modId }
function M.install(env, adapters)
  local R = M.new(env)
  for _, a in ipairs(adapters) do R:add(a) end
  local game = nil
  local function writer()
    if not (env.writeOption and game) then return nil end
    return function(key, value) return env.writeOption(game, key, value) end
  end
  local function full(cause)
    R:refresh(cause)
    R:migrate(writer())
    -- a migration write may have changed the effective choice
    local id = R:choose()
    if id ~= (R.active and R.active.id or nil) and not R.pending then R:select(cause .. "+migration") end
  end
  local ev = env.events
  -- modsLoadedByHost: the host calls R.onModsLoaded from its own mods.loaded handler
  R.onModsLoaded = function() full("mods.loaded") end
  if not env.modsLoadedByHost then ev:on("mods.loaded", R.onModsLoaded) end
  ev:on("game.ready", function(payload)
    game = (type(payload) == "table" and payload.game) or game
    full("game.ready")
  end)
  for _, name in ipairs({ "save.loaded", "save.created", "checkpoint.restored" }) do
    ev:on(name, function() R:epoch(name); full(name) end)
  end
  for _, name in ipairs({ "map.entered", "map.exited" }) do
    ev:on(name, function() R:epoch(name); if name == "map.entered" then R:retryPending(name) end end)
  end
  ev:on("battle.ended", function() R:retryPending("battle.ended") end)
  ev:on("world.stepped", function() if R.pending then R:retryPending("world.stepped") end end)
  ev:on("mod.options_changed", function(e)
    if type(e) ~= "table" then return end
    local relevant = (e.mod == env.modId and (e.key == M.OPTION_KEY or e.key == M.MARKER_KEY))
    for _, a in ipairs(R.adapters) do
      if e.mod == a.id or (a.optionMods and a.optionMods[e.mod]) then relevant = true end
    end
    if relevant then R:refresh("options:" .. tostring(e.mod) .. "." .. tostring(e.key)) end
  end)
  R.setGame = function(g) game = g end
  return R
end

return M
