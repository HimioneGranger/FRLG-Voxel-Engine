-- VRITK_FRLG_HOST compat (Gen 3 only: FireRed / LeafGreen and Emerald; Wilds of Hoenn1.5.0 /1.7.1 as the overworld provider).
-- Gen-specific compat layer (standing rule 2026-09-28; user rule 2026-10-10: "all these changes need to go in a compat
-- layer that turns on with VRITK installed"). Wilds of Hoenn retains upstream behavior outside generic optional hooks; everything the
-- VR layer needs from it is added HERE, at runtime, to the live objects the mod exports (spawnManager, battleTrigger,
-- followerAdapter, followerInteraction, portraitUI, companion) and, for the renderers, to their class tables reached
-- through a live renderer. No package.loaded, no debug; the only Wilds edit is the small upstreamable hook set (SpriteAtlas.configure,
-- EnginePatch.cacheModules, two exports). With VRITK absent none of this
-- exists and Wilds behaves as stock.
--
-- What it provides (each item replaces a direct edit that Labs 47-57 made to the Wilds files):
--   main.lua       the native-provider gate (setNativeProviderEnabled / nativeProviderEnabled / nativeProviderBusy), default ON
--                  (stock Wilds is always on), vrProviderEnabled/Ready, vrPoseReady, vrCollectActors, vrOwnsFollower,
--                  vrFollowerState, vrFollowerOverride, vrFollowerBusy, vrWildPose, atlasStats, setSpawnDecorator
--   follower_adapter.lua  setOverride / clearOverride (a session-local "show this party Pokemon" request, consulted before
--                  the companion; the swap scene plays as usual)
--   battle_trigger.lua    startForVR (identity-guarded native battle entry with an explicit acknowledgement)
--   spawn_manager.lua     MAX_TOTAL_VISIBLE cap (8 live wild Pokemon in total), spawn decorator seam
--   actor_renderer / pmd_renderer  vrSnapshotInto / vrSnapshot          -> WildsSnapshotCompat (adopt on every new renderer)
--   reachability / spawn_manager / encounter_source / config  incremental flood fill, cached eligible cells -> WildsReachCompat
-- The gate is a flag consulted by persistent wrappers on the instance methods Wilds' engine callbacks call, so a later
-- compat layered on the same instance (WildsFollowerFixCompat) restores cleanly. "Off" makes Wilds do nothing the same way
-- the edited gate did (no actors, no blocking, no follower tick, no menus, no map/save/step handling).
-- Documented residuals of "off" (hooks whose callbacks live in main.lua locals): the party menu ROLE rows
-- (partyRoles) and the "encounter.roll" / "world.follower.spawn" hooks stay registered; the ROLE rows are hidden by the
-- follower-fix layer while the gate is off, the roll hook only matters when Classic Encounters is switched off.
local M = {}

M.VERSION = "1.5.0" -- legacy public pin
M.SUPPORTED_VERSIONS = { ["1.5.0"] = true, ["1.7.1"] = true, ["1.10.1"] = true }
M.MAX_TOTAL_VISIBLE = 8 -- was Config.MAX_TOTAL_VISIBLE
M.ATLAS_MAX_SHARDS = 2 -- decoded atlas shards kept at once (was Config.ATLAS_MAX_SHARDS)
M.ATLAS_MAX_IMAGES = 48 -- sliced sheets kept at once (was Config.ATLAS_MAX_IMAGES)
M.WATER_SLOTS = 3 -- places of the total cap kept free for water Pokemon (WildsWaterSlotsCompat), st.waterSlots

local S -- installed state (nil when not installed)

local function noop() end

-- Thrown by the _spawnOne wrapper (only while a refill is running) the moment the cap is reached, and swallowed by the
-- refill wrapper: the edited refill() left its loop at that point (total >= cap), so the random draws that follow are the
-- same ones the edited game made.
local CAP_STOP = {}

-- ---------------------------------------------------------------- source guards
-- The constants this layer mirrors are read out of the stock files once, so a Wilds release it was not written for
-- fails soft instead of drifting.
local function grep(src, pattern) return type(src) == "string" and src:find(pattern) ~= nil end

local function verifyStock(mod, log)
  local function read(rel)
    local ok, s = pcall(mod.read, mod, rel)
    return ok and s or nil
  end
  local cfg, ar = read("lib/config.lua"), read("lib/actor_renderer.lua")
  local ok = grep(cfg, 'AVAILABLE%s*=%s*"available"') and grep(cfg, "IDLE_FLAP_TICKS%s*=%s*20")
    and grep(ar, 'POSE_STAND%s*=%s*"stand"') and grep(ar, 'POSE_WALK_A%s*=%s*"walkA"') and grep(ar, 'POSE_WALK_B%s*=%s*"walkB"')
    and grep(ar, 'IDLE_FLAP_SEQUENCE%s*=%s*{%s*"walkA",%s*"stand",%s*"walkB",%s*"stand"%s*}')
  if not ok then log("wilds host compat: stock pose constants differ from the reviewed contract; pose export disabled") end
  return ok
end

-- ---------------------------------------------------------------- instance wrapping
-- wrap(obj, name, make): obj[name] is replaced on the INSTANCE by make(orig) where orig is whatever obj[name] resolved to
-- (class method or an earlier instance override). Restores only when the field is still ours; otherwise the wrapper is
-- left in place and S == nil makes it a pass-through.
local function wrap(rec, obj, name, make)
  local prevRaw = rawget(obj, name)
  local orig = obj[name]
  if type(orig) ~= "function" then return false end
  local fn = make(orig)
  obj[name] = fn
  rec.wraps[#rec.wraps + 1] = { obj = obj, name = name, fn = fn, prev = prevRaw }
  return true
end

local function setField(rec, obj, name, fn)
  local prevRaw = rawget(obj, name)
  obj[name] = fn
  rec.wraps[#rec.wraps + 1] = { obj = obj, name = name, fn = fn, prev = prevRaw }
end

-- ---------------------------------------------------------------- install
--- ctx = { find = mod.find, events = mod.events, log = fn, require = fn, parts = { snapshot = M, reach = M } }
function M.install(ctx)
  if S then return true, "already installed" end
  ctx = ctx or {}
  local log = ctx.log or noop
  local req = ctx.require or require
  local w = ctx.find and ctx.find("wilds_of_hoenn") or nil
  local ex = type(w) == "table" and w.exports or nil
  if type(ex) ~= "table" then return false, "wilds_of_hoenn not loaded" end
  local version = w.version or ex.version
  if not M.SUPPORTED_VERSIONS[version] then return false, "unsupported wilds_of_hoenn version: " .. tostring(version) end
  if ex.engineReady ~= true then return false, "wilds_of_hoenn engine not ready" end
  local sm, bt, fa, fi, pu, comp = ex.spawnManager, ex.battleTrigger, ex.followerAdapter, ex.followerInteraction,
    ex.portraitUI, ex.companion
  -- (an ordered list: pairs() over a constructor with nil values would skip exactly the missing ones)
  local objs = { sm, bt, fa, fi, pu, comp }
  for i, name in ipairs({ "spawnManager", "battleTrigger", "followerAdapter", "followerInteraction", "portraitUI", "companion" }) do
    if type(objs[i]) ~= "table" then return false, "wilds_of_hoenn " .. name .. " missing" end
  end
  for _, need in ipairs({ { sm, "collectActors" }, { sm, "entityAt" }, { sm, "tick" }, { sm, "onMapEntered" },
      { sm, "onMapExited" }, { sm, "clearAll" }, { sm, "refill" }, { sm, "_spawnOne" }, { sm, "count" },
      { sm, "markEncounterStarting" }, { sm, "get" }, { sm, "despawn" },
      { bt, "checkContact" }, { bt, "onPlayerStepped" }, { bt, "_onBattleEnded" }, { bt, "isPending" },
      { fa, "collectActors" }, { fa, "tick" }, { fa, "mapChanged" }, { fa, "resetBehaviors" }, { fa, "resetDisplay" },
      { fa, "isBusy" }, { fi, "tryStart" }, { fi, "tick" }, { fi, "onSaveChanged" }, { fi, "isActive" },
      { pu, "draw" }, { comp, "resolve" } }) do
    if type(need[1][need[2]]) ~= "function" then return false, "wilds_of_hoenn method missing: " .. need[2] end
  end
  if version ~= "1.5.0" then
    if type(sm._place) ~= "function" then return false, "wilds_of_hoenn _place missing" end
    if type(sm.reflections) ~= "function" or type(fa.reflections) ~= "function" then
      return false, "wilds_of_hoenn 1.7.1 reflections missing"
    end
    for _, name in ipairs({ "snapshot", "reach", "slots" }) do
      local part = ctx.parts and ctx.parts[name]
      if type(part) ~= "table" or type(part.install) ~= "function" or type(part.uninstall) ~= "function" then
        return false, "wilds_of_hoenn 1.7.1 required compat part missing: " .. name
      end
    end
    if type(ex.spriteAtlas) ~= "table" or type(ex.spriteAtlas.configure) ~= "function"
        or type(ex.enginePatch) ~= "table" or type(ex.enginePatch.cacheModules) ~= "function"
        or type(ex.hdField) ~= "table" or type(ex.hdField.speciesFactor) ~= "function" then
      return false, "wilds_of_hoenn 1.7.1 generic compatibility hooks missing"
    end
  end
  if version == "1.10.1" then
    if type(sm.source) ~= "table" or type(sm.source.randomCell) ~= "function"
        or type(sm.source.eligibleCount) ~= "function" or type(sm._reachStale) ~= "function"
        or type(ex.spriteAtlas.sheetData) ~= "function" then
      return false, "wilds_of_hoenn 1.10.1 source/atlas contract missing"
    end
  end
  local mod = sm.mod
  if type(mod) ~= "table" or type(mod.read) ~= "function" then return false, "wilds_of_hoenn mod handle missing" end
  local constantsOk = verifyStock(mod, log)
  if version ~= "1.5.0" and not constantsOk then return false, "wilds_of_hoenn 1.7.1 pose constants unsupported" end

  local rec = { wraps = {}, exports = {}, unsub = {}, parts = {}, ex = ex, version = version }
  local cache = {} -- engine modules, resolved once (a mod's require goes through the loader's gate and allocates)
  local function engine(name)
    local v = cache[name]
    if v then return v end
    local ok, m = pcall(req, name)
    if ok and type(m) == "table" then cache[name] = m; return m end
    return nil
  end

  local st = {
    enabled = true, battle = false, epoch = 0, lastMap = sm.mapId ~= nil and { mapId = sm.mapId } or nil,
    override = nil, decorator = nil, decoratorWarned = false, cap = M.MAX_TOTAL_VISIBLE, waterSlots = M.WATER_SLOTS,
  }
  rec.st = st
  S = rec
  local function abortPart(name, part, why)
    -- A throwing install may already own resources. Include it in rollback even if it never returned success.
    if part then rec.parts[name] = part end
    M.uninstall()
    return false, "wilds_of_hoenn 1.7.1 " .. name .. " install failed: " .. tostring(why)
  end

  local Snapshot = ctx.parts and ctx.parts.snapshot or nil
  local Reach = ctx.parts and ctx.parts.reach or nil

  -- ------------------------------------------------------------ helpers over engine modules
  local followerModule
  local function currentFollower()
    if followerModule == nil then
      local F = engine("src.world.game3.Follower")
      followerModule = (F and type(F.current) == "function" and F) or false
    end
    if not followerModule then return nil end
    local ok, npc = pcall(followerModule.current)
    if ok then return npc end
    return nil
  end

  local function partyMons()
    local R = engine("src.core.game3.runtime")
    local ok, session = pcall(R and R.getSession or noop)
    local out = {}
    if not (ok and type(session) == "table" and type(session.party) == "table") then return out end
    for i = 1, 6 do
      if type(session.party[i]) == "table" then out[#out + 1] = session.party[i] end
    end
    return out
  end

  local function monHealthy(mon)
    return type(mon) == "table" and not mon.isEgg and not mon.egg
      and (tonumber(mon.hp) or tonumber(mon.currentHp) or 1) > 0
  end

  local function partyIndexOf(mon)
    local party = partyMons()
    for i = 1, #party do
      if party[i] == mon then return i end
    end
    return nil
  end

  -- ------------------------------------------------------------ renderer adoption (snapshot API)
  local function adopt(renderer)
    if Snapshot and renderer ~= nil then pcall(Snapshot.adopt, renderer) end
  end
  if Snapshot then
    local okS, whyS = pcall(Snapshot.install, { log = log, version = version, hdField = ex.hdField, spriteAtlas = ex.spriteAtlas, voxelActive = ctx.voxelActive })
    if not okS or whyS == false then
      if version ~= "1.5.0" then return abortPart("snapshot", Snapshot, whyS) end
      log("wilds host compat: snapshot layer not installed: " .. tostring(whyS)); Snapshot = nil
    end
    if Snapshot then rec.parts.snapshot = Snapshot end
  end
  if Snapshot then
    for _, e in pairs(sm.entities or {}) do adopt(e.renderer) end
    adopt(fa.renderer)
  end

  -- 1.10.1 owns ambient sky/water/local scenes and Sweet Scent callbacks.
  -- Its main closes over these live instances, so gate those instances too.
  if version == "1.10.1" then
    for _, aux in ipairs({ ex.skyFlyers, ex.waterLife, ex.localScenes }) do
      if type(aux) == "table" then
        for _, method in ipairs({ "tick", "onMapEntered", "collectActors" }) do
          wrap(rec, aux, method, function(orig)
            return function(self, ...)
              if S == rec and not st.enabled then return end
              return orig(self, ...)
            end
          end)
        end
      end
    end
    wrap(rec, sm, "sweetScent", function(orig)
      return function(self, ...)
        if S == rec and not st.enabled then return nil end
        return orig(self, ...)
      end
    end)
  end

  -- ------------------------------------------------------------ the gate (flag consulted by persistent wrappers)
  wrap(rec, sm, "collectActors", function(orig)
    return function(self, actors, ...)
      if S ~= rec or st.enabled then return orig(self, actors, ...) end
    end
  end)
  for _, obj in ipairs({ sm, fa }) do
    wrap(rec, obj, "reflections", function(orig)
      return function(self, list, ...)
        if S == rec then
          if not st.enabled then return end
          if type(ctx.voxelActive) == "function" and ctx.voxelActive() == true then return end
        end
        return orig(self, list, ...)
      end
    end)
  end
  wrap(rec, sm, "entityAt", function(orig)
    return function(self, tx, ty)
      if S ~= rec or st.enabled then return orig(self, tx, ty) end
      return nil
    end
  end)
  wrap(rec, sm, "tick", function(orig)
    return function(self, game)
      if S ~= rec or st.enabled then return orig(self, game) end
    end
  end)
  wrap(rec, sm, "onMapEntered", function(orig)
    return function(self, mapId, game)
      if S == rec and not st.enabled then return end
      return orig(self, mapId, game)
    end
  end)
  wrap(rec, sm, "onMapExited", function(orig)
    return function(self)
      if S == rec and not st.enabled then return end
      return orig(self)
    end
  end)
  wrap(rec, bt, "checkContact", function(orig)
    return function(self)
      if S == rec and not st.enabled then return end
      return orig(self)
    end
  end)
  wrap(rec, bt, "onPlayerStepped", function(orig)
    return function(self, x, y)
      if S == rec and not st.enabled then return end
      return orig(self, x, y)
    end
  end)
  wrap(rec, fa, "collectActors", function(orig)
    return function(self, actors)
      if S == rec and not st.enabled then return end
      return orig(self, actors)
    end
  end)
  wrap(rec, fa, "mapChanged", function(orig)
    return function(self)
      if S == rec and not st.enabled then return end
      return orig(self)
    end
  end)
  wrap(rec, fi, "tryStart", function(orig)
    return function(self, game)
      if S == rec and not st.enabled then return false end
      return orig(self, game)
    end
  end)
  wrap(rec, fi, "tick", function(orig)
    return function(self, game)
      if S == rec and not st.enabled then return end
      return orig(self, game)
    end
  end)
  wrap(rec, fi, "onSaveChanged", function(orig)
    return function(self)
      if S == rec and not st.enabled then return end
      return orig(self)
    end
  end)
  wrap(rec, pu, "draw", function(orig)
    return function(self, ...)
      if S == rec and not st.enabled then return end
      return orig(self, ...)
    end
  end)
  -- the save/checkpoint handler also reset these three; the edited gate swallowed the whole handler while off. The gate's
  -- own onChange runs them while the flag still allows it (on -> off) or after it was raised (off -> on).
  wrap(rec, comp, "reset", function(orig)
    return function(self, ...)
      if S == rec and not st.enabled then return end
      return orig(self, ...)
    end
  end)
  wrap(rec, fa, "resetBehaviors", function(orig)
    return function(self, ...)
      if S == rec and not st.enabled then return end
      return orig(self, ...)
    end
  end)
  wrap(rec, fa, "resetDisplay", function(orig)
    return function(self, ...)
      if S == rec and not st.enabled then return end
      return orig(self, ...)
    end
  end)

  -- ------------------------------------------------------------ follower override (follower_adapter.lua)
  -- The edited tick() consulted the override BEFORE the companion. The only companion call in tick() is
  -- self.companion:resolve(party), so for the duration of that call the field points at a prebuilt stand-in whose resolve
  -- answers the override first; nothing else sees it. No allocation per tick.
  local realCompanion
  local stand = {}
  function stand.resolve(_, party)
    local ov = st.override
    if ov and monHealthy(ov.mon) then
      -- `party` is the list the stock tick just built (EnginePatch.partyMons()): look in it instead of building another
      local inParty = false
      if type(party) == "table" then
        for i = 1, #party do if party[i] == ov.mon then inParty = true; break end end
      else
        inParty = partyIndexOf(ov.mon) ~= nil
      end
      if inParty then return ov.mon, ov.role end
    end
    return realCompanion:resolve(party)
  end
  wrap(rec, fa, "tick", function(orig)
    return function(self)
      if S ~= rec then return orig(self) end
      if not st.enabled then return end
      local c = rawget(self, "companion")
      -- an earlier tick that threw left the stand-in installed: put the real companion back first
      if c == stand then c = realCompanion; self.companion = c end
      if st.override and c ~= nil then
        realCompanion = c
        self.companion = stand
        orig(self) -- no pcall (it allocated under the JIT); an error leaves the stand-in, undone at the top of the next tick
        self.companion = c
      else
        orig(self)
      end
      if Snapshot then
        -- adopt only when the follower's renderer object changed (a pcall per tick showed up in the JIT allocation probe)
        local r = rawget(self, "renderer")
        if r ~= rec.lastAdopted then rec.lastAdopted = r; adopt(r) end
        if Snapshot.update then Snapshot.update() end -- releases the opaque-bottom shard memo after its TTL
      end
    end
  end)

  setField(rec, fa, "setOverride", function(self, mon, role)
    if mon == nil then st.override = nil; self.override = nil; return true end
    if role ~= nil and role ~= "follow" and role ~= "recall" then return false, "bad role" end
    if type(mon) ~= "table" then return false, "bad mon" end
    if not partyIndexOf(mon) then return false, "not in party" end
    if not monHealthy(mon) then return false, "not healthy" end
    st.override = { mon = mon, role = role == "recall" and "recall" or "follow" }
    self.override = st.override
    return true
  end)
  setField(rec, fa, "clearOverride", function(self) st.override = nil; self.override = nil end)
  setField(rec, fa, "_resolveOverride", function(_)
    local ov = st.override
    if not ov then return nil end
    if partyIndexOf(ov.mon) and monHealthy(ov.mon) then return ov.mon, ov.role end
    return nil
  end)
  rec.clearsOverrideField = true

  -- ------------------------------------------------------------ battle trigger (battle_trigger.lua)
  if constantsOk then setField(rec, bt, "startForVR", function(self, entity, preparedMon)
    if self:isPending() then return false, "busy" end
    local manager = self.spawnManager
    if not entity or manager:get(entity.id) ~= entity or entity.state ~= "available" or entity.engaged then
      return false, "gone"
    end
    local token = { entity = entity, mapId = manager.mapId, id = entity.id }
    self._vrBattleToken = token
    self.pendingId = entity.id
    manager:markEncounterStarting(entity.id)
    local enc = { species = entity.species, level = entity.level, personality = entity.personality,
      ivs = entity.ivs, roamer = entity.roamer, moves = entity.moves }
    -- BattleBridge/foe_mon_from already preserve these fields when supplied.
    for _, field in ipairs({ "species", "level", "personality", "ivs", "moves", "pp", "hp", "maxHp", "status", "item",
        "evs", "nature", "ability", "gender" }) do
      local value = (preparedMon or entity)[field]
      if value ~= nil then enc[field] = value end
    end
    local Bridge = engine("src.core.game3.battle_bridge")
    local called, accepted, why
    if Bridge and type(Bridge.startWild) == "function" then
      called, accepted, why = pcall(Bridge.startWild, nil, manager.game, enc, {
        done = function(result)
          if self._vrBattleToken ~= token then return end
          self._vrBattleToken = nil
          if manager.mapId == token.mapId and manager:get(token.id) == token.entity then
            self:_onBattleEnded(token.id, result)
          elseif self.pendingId == token.id then self.pendingId = nil end
        end,
      })
    else
      called, accepted, why = false, "battle_bridge unavailable", nil
    end
    if not called then why, accepted = accepted, false end
    if not accepted then
      if self._vrBattleToken == token then
        self._vrBattleToken = nil
        self.pendingId = nil
        if manager.mapId == token.mapId and manager:get(token.id) == token.entity then entity.state = "available" end
      end
      return false, why or "native battle refused"
    end
    return true
  end) end

  -- ------------------------------------------------------------ spawn manager: cap and decorator
  setField(rec, sm, "setDecorator", function(self, fn)
    if fn ~= nil and type(fn) ~= "function" then return false end
    st.decorator = fn
    st.decoratorWarned = false
    self.decorator = fn
    return true
  end)
  wrap(rec, sm, version ~= "1.5.0" and "_place" or "_spawnOne", function(orig)
    return function(self, terrain, cell, ...)
      if S ~= rec then return orig(self, terrain, cell, ...) end
      if not st.enabled then return false end
      if st.cap and self:count() >= st.cap then
        if st.inRefill then error(CAP_STOP, 0) end
        return false
      end
      local ok = orig(self, terrain, cell, ...)
      if ok then
        local e = self.entities[self.nextId - 1]
        if e then
          adopt(e.renderer)
          local deco = st.decorator
          if deco then
            -- A host may tag the entity before the next tick. Errors are ignored (logged once): a bad decorator must
            -- never stop spawning.
            local okD, errD = pcall(deco, e, self.mapId, terrain)
            if not okD and not st.decoratorWarned then
              st.decoratorWarned = true
              log("wilds host compat: spawn decorator error: " .. tostring(errD))
            end
          end
        end
        if st.inRefill and st.cap and self:count() >= st.cap then error(CAP_STOP, 0) end
      end
      return ok
    end
  end)
  wrap(rec, sm, "refill", function(orig)
    return function(self, terrain)
      if S ~= rec then return orig(self, terrain) end
      local cap = st.cap
      if not cap then return orig(self, terrain) end
      -- at the cap nothing can spawn: skip the attempts entirely (no random draws, no cell scans)
      if st.enabled and self:count() >= cap then return end
      local was = st.inRefill
      st.inRefill = true
      local ok, err = pcall(orig, self, terrain)
      st.inRefill = was
      if not ok and err ~= CAP_STOP then error(err, 0) end
    end
  end)
  wrap(rec, sm, "battleSpecies", function(orig)
    return function(self, ...)
      if S == rec and not st.enabled then return nil, "native provider disabled" end
      return orig(self, ...)
    end
  end)
  if type(sm.refreshSpriteStyle) == "function" then
    wrap(rec, sm, "refreshSpriteStyle", function(orig)
      return function(self, ...)
        local r1, r2 = orig(self, ...)
        if S == rec and Snapshot then for _, e in pairs(self.entities or {}) do adopt(e.renderer) end end
        return r1, r2
      end
    end)
  end

  -- ------------------------------------------------------------ reachability (spawn_manager / encounter_source)
  if Reach then
    local okR, whyR = pcall(Reach.install, { spawnManager = sm, log = log, stepsPerTick = 32, shoreRange = ctx.shoreRange, version = version, enginePatch = ex.enginePatch })
    if not okR or whyR == false then
      if version ~= "1.5.0" then return abortPart("reach", Reach, whyR) end
      log("wilds host compat: reachability layer not installed: " .. tostring(okR and whyR or whyR))
    else
      rec.parts.reach = Reach
    end
  end

  -- Reserved places for water Pokemon under the cap (installed after the reach part so it is the outermost refill wrapper).
  local Slots = ctx.parts and ctx.parts.slots or nil
  if Slots then
    local okS, whyS = pcall(Slots.install, { spawnManager = sm, log = log,
      cap = function() return st.cap end, slots = function() return st.waterSlots end, shoreRange = ctx.shoreRange })
    if not okS or whyS == false then
      if version ~= "1.5.0" then return abortPart("slots", Slots, whyS) end
      log("wilds host compat: water slots not installed: " .. tostring(okS and whyS or whyS))
    else
      rec.parts.slots = Slots
    end
  end

  -- Legacy1.5.0 only: Water Pokemon Without Surf is enabled for the session through Wilds' own
  -- session-local setter (never written to saved options). 1.7.1 owns shoreline eligibility; never force this obsolete option.
  if version == "1.5.0" and type(ex.setOption) == "function" then
    local okO, resO = pcall(ex.setOption, "look_water", true)
    if okO and resO ~= false then rec.lookWater = true else log("wilds host compat: look_water not accepted: " .. tostring(resO)) end
  elseif version == "1.5.0" then
    log("wilds host compat: this Wilds has no setOption; water Pokemon stay Surf dependent")
  end

  -- ------------------------------------------------------------ the gate state machine
  local function setExport(name, fn)
    if rec.exports[name] == nil then rec.exports[name] = { had = ex[name] ~= nil, prev = ex[name] } end
    ex[name] = fn
  end

  local function isBusy()
    local battler = ex.battler
    for _, entity in pairs(sm.entities) do
      if entity._vrCapture then return true end
    end
    return bt.pendingId ~= nil or fi:isActive() == true or fa.action ~= nil or fa.swap ~= nil
      or (type(battler) == "table" and battler.fight ~= nil)
  end

  local function busy()
    if st.battle then return true, "battle active" end
    local ok, v = pcall(isBusy)
    if not ok then return true, "busy query failed" end
    if v then return true, "native transaction active" end
    return false
  end

  -- the edited gate's onChange: any host follower override is dropped on every gate change
  local function onChange(on)
    fa:clearOverride()
    sm:clearAll()
    fa:resetBehaviors()
    fa:resetDisplay()
    local npc = currentFollower()
    if not on and npc and npc.sprite == rawget(fa, "renderer") then npc.sprite = nil end
    if on and st.lastMap then
      -- the edited gate handed over mod.world.game; sm.game is the same object the last tick / map entry saw
      local world = mod.world
      sm:onMapEntered(st.lastMap.mapId, (type(world) == "table" and world.game) or sm.game)
      fa:mapChanged()
    end
  end

  local function setEnabled(on)
    on = on == true
    if on == st.enabled then return true end
    local isBusyNow, why = busy()
    if isBusyNow then return false, why end
    -- "off" -> "on": the wrappers must pass through while onChange runs the real methods; "on" -> "off": onChange runs
    -- first, then the flag flips (same order as the edited gate: prepare, then switch)
    local was = st.enabled
    if on then st.enabled = true end
    local ok, err = pcall(onChange, on)
    if not ok then st.enabled = was; return false, tostring(err) end
    st.enabled = on
    st.epoch = st.epoch + 1
    return true
  end

  setExport("setNativeProviderEnabled", function(on) return setEnabled(on) end)
  setExport("nativeProviderEnabled", function() return st.enabled end)
  setExport("nativeProviderBusy", function() return busy() end)

  local function optEnabled()
    local o = mod.options
    if o and type(o.get) == "function" then
      local v = o:get("enabled")
      if v ~= nil then return v == true end
    end
    return true -- Config.DEFAULTS.enabled
  end

  setExport("vrPoseReady", true)
  setExport("vrProviderReady", true) -- the router additionally requires clean-host capabilities + transactional storage
  setExport("vrProviderEnabled", function() return optEnabled() end)

  setExport("vrCollectActors", function(actors)
    if not st.enabled then return end
    sm:collectActors(actors)
    local npc = currentFollower()
    if npc and not npc.hidden and npc.sprite == rawget(fa, "renderer") then
      local F = followerModule
      local actor = F and F.actor and F.actor()
      if actor then actor.renderer = actor.renderer or npc.sprite; actors[#actors + 1] = actor end
    end
    fa:collectActors(actors)
  end)

  setExport("vrOwnsFollower", function()
    local npc = currentFollower()
    return st.enabled and npc ~= nil and npc.sprite == rawget(fa, "renderer")
  end)

  -- Allocation-free follower state for a VR host: fills `out`, returns true; false while the gate is off or the engine
  -- follower is not drawn by us.
  setExport("vrFollowerState", function(out)
    if not st.enabled or type(out) ~= "table" then return false end
    local renderer = rawget(fa, "renderer")
    if not renderer then return false end
    local npc = currentFollower()
    if not npc or npc.sprite ~= renderer then return false end
    local disp = rawget(fa, "disp")
    local mon = disp and disp.mon or nil
    out.x, out.y = npc.px, npc.py
    out.cellX, out.cellY = npc.cellX, npc.cellY
    out.facing = npc.facing
    out.moving = npc.moving and true or false
    out.hidden = npc.hidden and true or false
    out.renderer = renderer
    out.mon = mon
    out.species = mon and tonumber(mon.species) or nil
    out.recalled = (rawget(fa, "role") == "recall" or (renderer.recall or 1) < 0.5) and true or false
    return true
  end)

  -- Session-local "show this party Pokemon" request. Never writes mod.save; the change plays through the normal swap
  -- scene. nil clears it.
  setExport("vrFollowerOverride", function(mon, role, _session)
    if mon == nil then return fa:setOverride(nil) end
    if not st.enabled then return false, "native provider disabled" end
    return fa:setOverride(mon, role)
  end)

  setExport("vrFollowerBusy", function()
    return fa:isBusy() == true or fi:isActive() == true
  end)

  if constantsOk then
    local IDLE_SEQ = { "walkA", "stand", "walkB", "stand" }
    -- The exact pose collectActors hands draw() for a wild entity (spawn_manager.lua collectActors, allocation-free).
    setExport("vrWildPose", function(e)
      local pose = "stand"
      if e.moving then
        pose = e.stepParity and "walkA" or "walkB"
      elseif e.floater then
        local ticks = 20 -- Config.IDLE_FLAP_TICKS (verified against the stock config above)
        local i = math.floor((tonumber(e.flapClock) or 0) / ticks) % #IDLE_SEQ
        pose = IDLE_SEQ[i + 1]
      end
      if e.owPose then pose = e.owPose end -- set by the Battler's skirmish
      return pose
    end)
  end

  -- Memory bounds and the engine-module cache come from two small, generic hooks that Wilds exports
  -- (exports.spriteAtlas.configure, exports.enginePatch.cacheModules). A Wilds without them runs unbounded, as stock.
  local atlasHook = type(ex.spriteAtlas) == "table" and type(ex.spriteAtlas.configure) == "function" and ex.spriteAtlas or nil
  local patchHook = type(ex.enginePatch) == "table" and type(ex.enginePatch.cacheModules) == "function" and ex.enginePatch or nil
  if atlasHook then
    if version ~= "1.5.0" then rec.atlasHook = atlasHook end
    local ok, err = pcall(atlasHook.configure, { maxShards = M.ATLAS_MAX_SHARDS, maxImages = M.ATLAS_MAX_IMAGES })
    if ok and err ~= false then rec.atlasHook = atlasHook
    elseif version ~= "1.5.0" then return abortPart("atlas bounds", nil, err)
    else log("wilds host compat: spriteAtlas.configure failed: " .. tostring(err)) end
  else
    log("wilds host compat: this Wilds has no spriteAtlas.configure hook; the atlas stays unbounded")
  end
  -- 1.10.1 enables its own module cache by default. Do not own or disable
  -- that upstream setting on uninstall. Older versions still need this shim.
  if patchHook and version ~= "1.10.1" then
    if version ~= "1.5.0" then rec.patchHook = patchHook end
    local ok, err = pcall(patchHook.cacheModules, true)
    if ok and err ~= false then rec.patchHook = patchHook
    elseif version ~= "1.5.0" then return abortPart("engine module cache", nil, err)
    else log("wilds host compat: enginePatch.cacheModules failed: " .. tostring(err)) end
  elseif version ~= "1.10.1" then
    log("wilds host compat: this Wilds has no enginePatch.cacheModules hook; engine lookups stay uncached")
  end

  -- The atlas counters (shards, images, evictedShards, evictedImages, decodes) come from the hook; decodeMs/decodeMaxMs and
  -- the shard figures of the opaque-bottom scans come from the snapshot part.
  setExport("atlasStats", function()
    local out = { shards = 0, images = 0, evictedShards = 0, evictedImages = 0, decodes = 0, decodeMs = 0, decodeMaxMs = 0 }
    local h = ex.spriteAtlas
    if type(h) == "table" and type(h.stats) == "function" then
      local ok, s = pcall(h.stats)
      if ok and type(s) == "table" then
        for k, v in pairs(s) do out[k] = v end
      end
    end
    if Snapshot and Snapshot.atlasStats then
      local s = Snapshot.atlasStats()
      out.shards = out.shards + (s.shards or 0)
      out.decodes = out.decodes + (s.decodes or 0)
      out.decodeMs = (s.decodeMs or 0)
      out.decodeMaxMs = (s.decodeMaxMs or 0)
    end
    return out
  end)

  setExport("setSpawnDecorator", function(fn)
    if fn ~= nil and type(fn) ~= "function" then return false, "decorator must be a function or nil" end
    return sm:setDecorator(fn)
  end)

  -- ------------------------------------------------------------ events (VRITK's own subscriptions)
  local events = ctx.events
  if events and type(events.on) == "function" then
    local function sub(name, fn)
      local ok, unsub = pcall(events.on, events, name, fn)
      if ok and type(unsub) == "function" then rec.unsub[#rec.unsub + 1] = unsub end
    end
    sub("map.entered", function(ev) st.lastMap = ev end)
    sub("map.exited", function() st.lastMap = nil end)
    sub("battle.started", function() st.battle = true end)
    sub("battle.ended", function() st.battle = false end)
    for _, name in ipairs({ "save.loaded", "save.created", "checkpoint.restored" }) do
      sub(name, function() pcall(function() fa:clearOverride() end) end)
    end
  end

  log("wilds host compat installed (gate, exports, follower override, VR battle entry, cap, decorator)")
  return true
end

--- Removes everything install() added (same function objects back; an instance override someone else layered on top is
--- left in place and passes through because the installed state is gone).
function M.uninstall()
  local rec = S
  if not rec then return false end
  -- turn the gate back on first so that no stub-state survives
  if rec.st then rec.st.enabled = true end
  S = nil
  for _, unsub in ipairs(rec.unsub) do pcall(unsub) end
  if rec.lookWater and type(rec.ex.setOption) == "function" then pcall(rec.ex.setOption, "look_water", nil) end
  -- reverse install order: slots (outermost refill wrapper), reach, snapshot
  for _, name in ipairs({ "slots", "reach", "snapshot" }) do
    local p = rec.parts[name]
    if p then pcall(p.uninstall) end
  end
  for i = #rec.wraps, 1, -1 do
    local wr = rec.wraps[i]
    if rawget(wr.obj, wr.name) == wr.fn then wr.obj[wr.name] = wr.prev end
  end
  for i = 1, #rec.wraps do
    local wr = rec.wraps[i]
    if wr.name == "setOverride" then wr.obj.override = nil end
    if wr.name == "setDecorator" and rawget(wr.obj, "decorator") == rec.st.decorator then wr.obj.decorator = nil end
  end
  rec.st.override, rec.st.decorator, rec.st.inRefill = nil, nil, false
  if rec.atlasHook then pcall(rec.atlasHook.configure, {}) end -- unlimited again, as stock
  if rec.patchHook then pcall(rec.patchHook.cacheModules, false) end
  for name, e in pairs(rec.exports) do
    if e.had then rec.ex[name] = e.prev else rec.ex[name] = nil end
  end
  return true
end

function M.status()
  local rec = S
  if not rec then return { installed = false } end
  local st = rec.st
  return { installed = true, enabled = st.enabled, epoch = st.epoch, override = st.override ~= nil,
    decorator = st.decorator ~= nil, cap = st.cap, snapshot = rec.parts.snapshot ~= nil, reach = rec.parts.reach ~= nil }
end

--- Test seam: the live state table (cap, decorator, override, lastMap).
function M._state() return S and S.st or nil end

return M
