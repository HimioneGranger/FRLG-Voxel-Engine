-- EngineSeams: the three engine seams Wilds of Hoenn / VRITK capture use, made at runtime.
--
--   E1  Encounters.rollSweetScent(mapId, terrain)
--         frlg : port of upstream gen1recomp fc7da4dd encounter_rules/frlg.lua rollSweetScent
--         rse  : the Emerald rule's gate-free sweet-scent roll, rebuilt from the public
--                rules table (R.tryGenerate / R.createWild) plus Encounters._h
--       A rules table that already has rollSweetScent is used as-is.
--   E2  Message.closeStay()        (frlg drops the pending done callback first; rse keeps it)
--   E3  Catching.vrTransactionalStore = 1 and storeCaught opts.onStored(result)
--
-- Engine modules are reached ONLY through pcall(require, ...). install() never edits a
-- file; it replaces fields on the live module tables and remembers the originals, and
-- uninstall() puts the very same function objects back (a slot someone else has since
-- replaced is left alone and reported). A seam that already exists natively is never
-- overridden. Everything fails soft with a log line.
local S = { version = 1 }

local unpack = table.unpack or unpack
local function pack(...) return { n = select("#", ...), ... } end

local state = nil -- non-nil while installed: { restore = { {tbl,key,orig,mine}... }, seams = {...} }

local function req(name)
  local ok, m = pcall(require, name)
  if ok and type(m) == "table" then return m end
  return nil
end

local function currentLayout()
  local GV = req("src.core.GameVersion")
  if not (GV and type(GV.get) == "function" and type(GV.layout) == "function") then return nil end
  local okId, id = pcall(GV.get)
  if not okId then return nil end
  local okL, layout = pcall(GV.layout, id)
  if okL and (layout == "frlg" or layout == "rse") then return layout end
  return nil
end

local function currentFamily()
  local P = req("src.core.game3.profile")
  if P and type(P.family) == "function" then
    local ok, f = pcall(P.family)
    if ok then return f end
  end
  return nil
end

local function patch(st, tbl, key, mine)
  st.restore[#st.restore + 1] = { tbl = tbl, key = key, orig = tbl[key], mine = mine }
  tbl[key] = mine
end

-- ------------------------------------------------------------------ E1
local function installE1(st, log)
  local Encounters = req("src.core.game3.encounters")
  if not Encounters then return "skipped", "encounters module unavailable" end
  if type(Encounters.rollSweetScent) == "function" then return "native" end
  local H = Encounters._h
  if type(H) ~= "table" or type(Encounters.ensureLoaded) ~= "function"
      or type(Encounters.rules) ~= "function" then
    return "skipped", "encounters module shape unexpected"
  end

  -- pokefirered/src/wild_encounter.c:464, as upstream gen1recomp fc7da4dd
  -- encounter_rules/frlg.lua rollSweetScent.
  local function frlg_roll(mapId, terrain)
    Encounters.ensureLoaded()
    local water = terrain == "water"
    local t = H.table_for(mapId)
    local area = water and H.normalize_area(t and t.water, 15)
      or H.normalize_area(t and (t.land or t.grass), nil)
    local okR, Roamer = pcall(require, "src.core.game3.roamer")
    if okR and Roamer and Roamer.tryEncounter then
      local okRt, Runtime = pcall(require, "src.core.game3.runtime")
      local session = okRt and Runtime and Runtime.getSession and Runtime.getSession()
      local roamerEnc = Roamer.tryEncounter(session, mapId, water and "water" or "land")
      if roamerEnc then return roamerEnc end
    end
    if not area or #area.slots == 0 then return nil end
    local entry = H.pick_slot(area.slots, water and H.WATER_WEIGHTS or H.LAND_WEIGHTS)
    if type(entry) ~= "table" then return nil end
    return { species = entry.species or entry[1], level = H.level_of(entry), item = entry.item }
  end

  -- pokeemerald wild_encounter.c SweetScentWildEncounter; the helpers below are the
  -- small file-local ones of encounter_rules/rse.lua, reimplemented over public API.
  local function session()
    local Runtime = req("src.core.game3.runtime")
    return Runtime and Runtime.getSession and Runtime.getSession() or nil
  end
  local function flag(name)
    local Space = req("src.core.game3.scripting.space")
    local s = (Space and Space.store) or session()
    if not s then return false end
    local Flags = require("src.core.game3.scripting.flags")
    return Flags.getFlag(s, nil, H.constants():require("flags", name)) == true
  end
  local function sootopolis_blocks(mapId)
    local MapIds = require("src.core.game3.map_ids")
    if not (mapId ~= nil and mapId == MapIds.forConst("MAP_SOOTOPOLIS_CITY", H.constants().game)) then
      return false
    end
    return flag("FLAG_LEGENDARIES_IN_SOOTOPOLIS")
  end
  local function outbreak_test(mapId)
    local s = session()
    local o = s and s.outbreak
    if type(o) ~= "table" or (tonumber(o.species) or 0) == 0 then return nil end
    if o.map ~= mapId then return nil end
    local Rng = require("src.core.game3.rng")
    if Rng.Random() % 100 < (tonumber(o.probability) or 0) then return o end
    return nil
  end
  local function outbreak_mon(R, o)
    local enc = R.createWild(tonumber(o.species), tonumber(o.level) or 1)
    if type(o.moves) == "table" then
      enc.moves = {}
      for i = 1, 4 do enc.moves[i] = o.moves[i] end
    end
    return enc
  end
  local function land_area(t)
    return H.normalize_area(t and t.land) or H.normalize_area(t and t.grass)
  end
  local function rse_roll(R, mapId, terrain)
    if terrain ~= "land" and terrain ~= "water" then return nil end
    Encounters.ensureLoaded()
    local t = H.table_for(mapId)
    if not t then return nil end
    if terrain == "water" and sootopolis_blocks(mapId) then return nil end
    local area
    if terrain == "land" then area = land_area(t) else area = H.normalize_area(t.water, 15) end
    if not area or #area.slots == 0 then return nil end
    -- roamer_encounter(mapId, terrain, false): no Repel rejection
    local s = session()
    local roamer
    if s and type(s.roamer) == "table" and s.roamer.active then
      local Roamer = req("src.core.game3.roamer")
      if Roamer and Roamer.tryEncounter then roamer = Roamer.tryEncounter(s, mapId, terrain) end
    end
    if roamer then return roamer end
    if terrain == "land" then
      local outbreak = outbreak_test(mapId)
      if outbreak then return outbreak_mon(R, outbreak) end
    end
    return R.tryGenerate(area, terrain, false, false)
  end

  local function rollSweetScent(mapId, terrain)
    local R = Encounters.rules()
    local native = R and R.rollSweetScent
    if type(native) == "function" then return native(mapId, terrain) end
    local family = currentFamily()
    if family == "frlg" then return frlg_roll(mapId, terrain) end
    if family == "rse" and R and type(R.tryGenerate) == "function" and type(R.createWild) == "function" then
      return rse_roll(R, mapId, terrain)
    end
    error("game3 encounters: " .. tostring(family) .. " rules have no rollSweetScent", 2)
  end
  patch(st, Encounters, "rollSweetScent", rollSweetScent)
  return "installed"
end

-- ------------------------------------------------------------------ E2
local function installE2(st, log)
  local Message = req("src.ui.game3.message")
  if not Message then return "skipped", "message module unavailable" end
  if type(Message.closeStay) == "function" then return "native" end
  if type(Message.close) ~= "function" then return "skipped", "Message.close missing" end
  local function closeStay()
    if not (Message.open and Message._stay) then return false end
    -- FireRed/LeafGreen: the caller abandons the line, so its done callback is dropped.
    -- Emerald keeps the callback.
    if currentLayout() == "frlg" then Message._done = nil end
    Message.close()
    return true
  end
  patch(st, Message, "closeStay", closeStay)
  return "installed"
end

-- ------------------------------------------------------------------ E3
local function installE3(st, log)
  local Catching = req("src.core.game3.battle.catching")
  if not Catching then return "skipped", "catching module unavailable" end
  if Catching.vrTransactionalStore ~= nil then return "native" end
  local orig = Catching.storeCaught
  if type(orig) ~= "function" then return "skipped", "Catching.storeCaught missing" end
  local ModRuntime = req("src.mods.Runtime")
  if not (ModRuntime and type(ModRuntime.wants) == "function" and type(ModRuntime.emit) == "function") then
    return "skipped", "mod Runtime unavailable"
  end

  local function storeCaught(session, foeBattler, ballId, opts)
    if not (opts and opts.onStored) then
      return orig(session, foeBattler, ballId, opts)
    end

    local origWants, origEmit = ModRuntime.wants, ModRuntime.emit
    local Storage = req("src.core.game3.storage")
    local origDeposit = Storage and Storage.depositCaught
    local wantsAsked, queued = false, nil

    -- (a) a failed insertion that nevertheless stored the mon counts as stored
    local myDeposit
    if Storage and type(origDeposit) == "function" then
      myDeposit = function(sess, mon, ...)
        local r = pack(pcall(origDeposit, sess, mon, ...))
        if r[1] then return unpack(r, 2, r.n) end
        local ok, bId, sId
        for bi, box in pairs((sess.storage or {}).boxes or {}) do
          for si, stored in pairs(box.mons or {}) do
            if stored == mon then ok, bId, sId = true, bi, si end
          end
        end
        if not ok then error(r[2], 0) end
        return ok, bId, sId
      end
      Storage.depositCaught = myDeposit
    end

    -- (b) hold back pokemon.caught: the stock code only builds and emits it when it
    -- would have called onStored (not pending, storage succeeded)
    local myWants = function(name)
      if name == "pokemon.caught" then wantsAsked = true; return true end
      return origWants(name)
    end
    local myEmit = function(name, payload)
      if name == "pokemon.caught" then queued = { payload = payload }; return end
      return origEmit(name, payload)
    end
    ModRuntime.wants, ModRuntime.emit = myWants, myEmit

    -- the payload is built by the stock code (species / ball names); a failure there must
    -- not abort the store, it becomes res.eventError after onStored, as in the edited engine
    local payloadErr
    local G3 = req("src.mods.Gen3Compat")
    local origSN, origIN = G3 and G3.speciesName, G3 and G3.itemName
    local function guard(f)
      return function(...)
        if not wantsAsked then return f(...) end
        local g = pack(pcall(f, ...))
        if g[1] then return unpack(g, 2, g.n) end
        if payloadErr == nil then payloadErr = g[2] end
        return nil
      end
    end
    local mySN, myIN
    if G3 and type(origSN) == "function" and type(origIN) == "function" then
      mySN, myIN = guard(origSN), guard(origIN)
      G3.speciesName, G3.itemName = mySN, myIN
    end

    local r = pack(pcall(orig, session, foeBattler, ballId, opts))

    if ModRuntime.wants == myWants then ModRuntime.wants = origWants end
    if ModRuntime.emit == myEmit then ModRuntime.emit = origEmit end
    if myDeposit and Storage.depositCaught == myDeposit then Storage.depositCaught = origDeposit end
    if mySN then
      if G3.speciesName == mySN then G3.speciesName = origSN end
      if G3.itemName == myIN then G3.itemName = origIN end
    end

    if not r[1] then error(r[2], 0) end
    local res = r[2]

    -- (c) onStored first, then the held event, failures of the event never fatal
    if wantsAsked then
      opts.onStored(res)
      if payloadErr ~= nil then
        res.eventError = tostring(payloadErr)
      elseif queued and origWants("pokemon.caught") then
        local okEvent, eventError = pcall(origEmit, "pokemon.caught", queued.payload)
        if not okEvent then res.eventError = tostring(eventError) end
      end
    end
    return res
  end

  patch(st, Catching, "vrTransactionalStore", 1)
  patch(st, Catching, "storeCaught", storeCaught)
  return "installed"
end

-- ------------------------------------------------------------------ public
function S.install(log)
  log = type(log) == "function" and log or function() end
  if state then return true, "already installed" end
  local layout = currentLayout()
  if not layout then
    log("layout is neither frlg nor rse; engine seams not installed")
    return false, "layout is neither frlg nor rse"
  end
  local st = { restore = {}, seams = {}, layout = layout }
  for _, row in ipairs({ { "sweetScent", installE1 }, { "closeStay", installE2 }, { "transactionalStore", installE3 } }) do
    local ok, result, why = pcall(row[2], st, log)
    if not ok then
      st.seams[row[1]] = "failed: " .. tostring(result)
      log("seam " .. row[1] .. " failed softly: " .. tostring(result))
    else
      st.seams[row[1]] = why and (result .. ": " .. why) or result
      if result == "skipped" then log("seam " .. row[1] .. " skipped: " .. tostring(why)) end
    end
  end
  state = st
  log("engine seams (" .. layout .. "): sweetScent=" .. st.seams.sweetScent
    .. " closeStay=" .. st.seams.closeStay .. " transactionalStore=" .. st.seams.transactionalStore)
  return true
end

function S.uninstall()
  local st = state
  if not st then return true end
  local clean = true
  for i = #st.restore, 1, -1 do
    local r = st.restore[i]
    if r.tbl[r.key] == r.mine then
      r.tbl[r.key] = r.orig
    else
      clean = false -- someone replaced the slot after us; do not clobber their function
    end
  end
  state = nil
  return clean
end

function S.status()
  if not state then return { installed = false } end
  local seams = {}
  for k, v in pairs(state.seams) do seams[k] = v end
  return { installed = true, layout = state.layout, seams = seams }
end

return S
