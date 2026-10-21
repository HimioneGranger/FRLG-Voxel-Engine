-- VRITK_FRLG_HOST: the game3 data adapters DESIGN.md 2c scopes to P2
-- ("first bag.rows and party.list"). Reads the LIVE session
-- (src.core.game3.runtime.getSession()), never game.save (a snapshot
-- rebuilt only on save -- reading-game3-api.md "Live state lives in the
-- session, not in game.save"). Every engine call is pcall'd: this module
-- must degrade to an empty list, never throw, since VRHOST_PROBE-style
-- desktop checks and a cold boot (no session yet) both hit it.
--
-- This mod's own manifest is gen3-only (see manifest.json), so nothing
-- here needs its own generation guard -- it simply never loads on Gen1/2.
local V = ...
local _ = V

local Game3Data = {}

-- W4 review fix #5 (REVIEW_VRITK_P2.md): module lookups happen once and are
-- kept, instead of a fresh pcall(require, ...) every call (bagRows used to
-- do this once per pocket -- four times a frame).
local modCache = {}
local function engineModule(name)
  local m = modCache[name]
  if m == nil then
    local ok, found = pcall(require, name)
    m = (ok and type(found) == "table") and found or false
    modCache[name] = m
  end
  return m or nil
end

local function session()
  local Runtime = engineModule("src.core.game3.runtime")
  if not (Runtime and type(Runtime.getSession) == "function") then return nil end
  local ok, s = pcall(Runtime.getSession)
  if ok and type(s) == "table" then return s end
  return nil
end

-- {{itemId, key, pocket, name, count}} across every non-ball, non-key-item
-- pocket, in pocket then slot order. Balls are excluded on purpose: VRITK's
-- Gen2 path (Gen2PouchCompat/Gen2BattleCaptureCompat) always treats
-- POKE_BALLS as its own thing, never mixed into the ordinary backpack
-- contents list, and P2 has no ball/pouch feature yet (Q1, DESIGN.md 0.1
-- point 4). KEY_ITEMS is excluded per review fix #6: rods, the Bicycle, the
-- TM Case and the Berry Pouch are menu-access items, not grabbable backpack
-- props (note: the "TM_CASE" pocket kept below is Bag's own pocket NAME for
-- actual TM/HM items -- ItemsData.POCKET.TM_CASE -- a different thing from
-- the single "TM Case" KEY_ITEMS-pocket item, ItemsData.ITEM_TM_CASE, which
-- this exclusion also correctly drops).
local ROWS_POCKETS = { "ITEMS", "TM_CASE", "BERRY_POUCH" }

-- W4 review fix #5: per-id display-name cache (ItemsData.displayName does a
-- ROM-text lookup; names never change for a given id within a process).
local nameCache = {}

-- W4 review fix #6: when Items.resolveHostId(id) has no entry (an id
-- FRLG_TO_HOST never mapped), fall back to the display name, uppercased,
-- with '.' and "'" stripped and any run of spaces/hyphens turned into '_'
-- -- a same-shaped host-style id string so Gen3Contents/BackpackContents'
-- icon slug rule still has something item-specific to work with instead of
-- a bare number.
local function fallbackKey(name)
  if type(name) ~= "string" or name == "" then return nil end
  local s = name:upper():gsub("[%.']", ""):gsub("[%s%-]+", "_")
  if s == "" then return nil end
  return s
end

-- Shared by bagRows/ballRows: bootstrap s.bag.pockets into a real table at
-- most once (see the comment below), then read the given pockets directly,
-- writing rows into `out`. Never calls Bag.listPocket once pockets is
-- already a table -- no per-frame full-bag sanitize, ever.
local function readPockets(s, pockets, out)
  local Bag = engineModule("src.core.game3.bag")
  local ItemsData = engineModule("src.core.game3.items_data")
  local Items = engineModule("src.core.game3.items")
  if not Bag then return out end

  -- Bootstrap only: Bag.listPocket is the one exported call that reaches
  -- Bag's own internal ensure()/sanitize_pockets (normalizing a legacy
  -- schema, fixing any misplaced slot). Once `s.bag.pockets` is a real
  -- table, Bag's own mutators (add/remove) keep it correct incrementally,
  -- so every later frame reads it directly below -- no more full-bag
  -- cleanup, and never through Bag.listPocket's own per-row
  -- ItemsData.info()/description() work these rows don't need.
  if type(s.bag.pockets) ~= "table" and type(Bag.listPocket) == "function" then
    pcall(Bag.listPocket, s.bag, pockets[1])
  end
  if type(s.bag.pockets) ~= "table" then return out end

  for _, pocket in ipairs(pockets) do
    local slots = s.bag.pockets[pocket]
    if type(slots) == "table" then
      for _, slot in ipairs(slots) do
        local id = slot.id
        local qty = tonumber(slot.qty) or 0
        if id ~= nil and qty > 0 then
          local name = nameCache[id]
          if name == nil then
            name = (ItemsData and ItemsData.displayName(id)) or tostring(id)
            nameCache[id] = name
          end
          local key = Items and Items.resolveHostId(id)
          if not key then key = fallbackKey(name) end
          out[#out + 1] = { itemId = id, key = key, pocket = pocket, name = name, count = qty }
        end
      end
    end
  end
  return out
end

-- W4 P5 (DESIGN.md 2c bag.bestRod -- "264|263|262|nil"): rods are KEY_ITEMS
-- (pret ids OLD_ROD=262, GOOD_ROD=263, SUPER_ROD=264 -- item_use.lua:837,
-- encounters.lua:622), not one of ROWS_POCKETS/BALL_POCKETS, so this reads
-- that pocket directly (same no-Bag.listPocket-per-frame discipline as
-- bagRows/ballRows -- review fix #5's whole point) instead of going
-- through the Gen3Compat facade's `game.save.inventory` (which is what the
-- OLD FishingRodComponent.R.best did on Gen1/2 and would, unchanged, cost a
-- full Bag.get sanitize per rod id per frame on Gen3).
local ROD_IDS_BEST_FIRST = { 264, 263, 262 } -- SUPER, GOOD, OLD

function Game3Data.bestRod()
  local s = session()
  if not (s and type(s.bag) == "table") then return nil end
  if type(s.bag.pockets) ~= "table" then
    -- Same one-time bootstrap as readPockets: only reached if nothing else
    -- (bagRows/ballRows) has already normalized the bag this session.
    local Bag = engineModule("src.core.game3.bag")
    if Bag and type(Bag.listPocket) == "function" then pcall(Bag.listPocket, s.bag, "KEY_ITEMS") end
  end
  if type(s.bag.pockets) ~= "table" then return nil end
  local slots = s.bag.pockets.KEY_ITEMS
  if type(slots) ~= "table" then return nil end
  local owned = {}
  for _, slot in ipairs(slots) do
    local id = tonumber(slot.id)
    if id and (tonumber(slot.qty) or 0) > 0 then owned[id] = true end
  end
  for _, id in ipairs(ROD_IDS_BEST_FIRST) do
    if owned[id] then return id end
  end
  return nil
end

function Game3Data.bagRows()
  local s = session()
  if not (s and type(s.bag) == "table") then return {} end
  return readPockets(s, ROWS_POCKETS, {})
end

-- W4 P3 (DESIGN.md 2c bag.balls): the POKE_BALLS pocket, deliberately
-- excluded from ROWS_POCKETS/bagRows (VRITK's Gen2 pouch path always
-- treats balls as their own thing, never mixed into the ordinary backpack
-- list) but needed for the pouch's own ball display. Read-only, like
-- bagRows: P3's throw is a stub and never calls Bag.remove, so this list
-- never has to reflect a mid-frame count change from this mod's own writes.
local BALL_POCKETS = { "POKE_BALLS" }

function Game3Data.ballRows()
  local s = session()
  if not (s and type(s.bag) == "table") then return {} end
  return readPockets(s, BALL_POCKETS, {})
end

-- Scalar equivalent of Catch's ballRows count: reads the live canonical
-- pocket without allocating public row snapshots or sanitizing every query.
-- Both arguments are scalars; mappedItemId is the caller's BALL_IDS lookup.
function Game3Data.ballCount(ballType, mappedItemId)
  local s = session()
  if not (s and type(s.bag) == "table") then return 0 end
  local Bag = engineModule("src.core.game3.bag")
  if not Bag then return 0 end
  if type(s.bag.pockets) ~= "table" and type(Bag.listPocket) == "function" then
    pcall(Bag.listPocket, s.bag, "POKE_BALLS")
  end
  if type(s.bag.pockets) ~= "table" then return 0 end
  local slots = s.bag.pockets.POKE_BALLS
  if type(slots) ~= "table" then return 0 end
  local ItemsData = engineModule("src.core.game3.items_data")
  local Items = engineModule("src.core.game3.items")
  local n = 0
  for _, slot in ipairs(slots) do
    local id = slot.id
    local qty = tonumber(slot.qty) or 0
    if id ~= nil and qty > 0 then
      local matches = (mappedItemId and tonumber(id) == mappedItemId)
          or tostring(id) == tostring(ballType)
      if not matches then
        local key = Items and Items.resolveHostId(id)
        if not key then
          local name = nameCache[id]
          if name == nil then
            name = (ItemsData and ItemsData.displayName(id)) or tostring(id)
            nameCache[id] = name
          end
          key = fallbackKey(name)
        end
        matches = key == ballType
      end
      if matches then n = n + qty end
    end
  end
  return n
end

function Game3Data.partyList()
  local s = session()
  local out = {}
  if not (s and type(s.party) == "table") then return out end
  -- Review #5 (REVIEW_VRITK_P3P5.md): `engineRequire` was never defined in
  -- this file -- an undefined global, always nil -- so this threw "attempt
  -- to call a nil value" the first time partyList() ran with a non-empty
  -- party. `engineModule` (defined at the top of this file, the same
  -- memoize-on-success cache bagRows/ballRows already use) is the real
  -- helper.
  local Pokemon = engineModule("src.core.game3.pokemon")
  for slot, mon in ipairs(s.party) do
    if type(mon) == "table" then
      local name = nil
      if Pokemon and type(Pokemon.displayMonName) == "function" then
        local ok, n = pcall(Pokemon.displayMonName, mon)
        if ok and type(n) == "string" and n ~= "" then name = n end
      end
      local key = nil
      if Pokemon and type(Pokemon.keyName) == "function" then
        local ok, k = pcall(Pokemon.keyName, mon.species)
        if ok then key = k end
      end
      local shiny = false
      if Pokemon and type(Pokemon.isShiny) == "function" then
        local ok, sh = pcall(Pokemon.isShiny, mon)
        shiny = ok and sh == true
      end
      out[#out + 1] = {
        slot = slot,
        speciesId = mon.speciesId or mon.species,
        key = key,
        name = name,
        level = mon.level,
        hp = mon.hp,
        maxHp = mon.maxHp,
        shiny = shiny,
        isEgg = mon.isEgg == true,
        ballId = mon.pokeball,
      }
    end
  end
  return out
end

-- gear-hook follow-up round: the user's decision is that a post-catch
-- nickname is entered ON THE TABLET (the just-patched gen3NamingGrid route
-- in the kanto_gear lab copy, w4/kanto_gear_333_naming_lab.diff). This is
-- the "small hook" W5's catch flow can call -- a thin wrapper around
-- game3's own REAL naming entry point, `src.ui.game3.naming.open(opts)`
-- (confirmed against `battle/init.lua`'s own "give this caught mon a
-- nickname?" flow, ~line 3216 -- `template="CAUGHT_MON"`, `maxLen=10`,
-- `species`, `gender`, `personality`, `seed`=the display name, `sentToPc`,
-- `title=Naming.monTitle(...)`, `onDone(nick)` writing `mon.nickname`).
-- This wrapper does NOT touch FRLG_CATCH or any catch logic; it only opens
-- the SAME naming screen the battle catch flow already uses, targeted at
-- an arbitrary live party slot, so a future overworld-catch flow (or
-- anything else) can call it directly:
--   local ok, why = Game3Data.openNicknameForPartySlot(slot, function(nick) ... end)
-- `onDone` is called (with the entered nick, or nil/"" if cancelled/kept)
-- AFTER this function has already written `mon.nickname` itself when a
-- real name was entered -- a caller only needs onDone for its OWN
-- follow-up (closing a menu, continuing a flow), not to persist the name.
-- Shared by both entry points below: everything from here down only
-- depends on having found the live `mon` table and knowing whether it is
-- a party slot or a PC box slot (`sentToPc`, matching the same field
-- `battle/init.lua`'s own catch-nickname prompt sets -- the flat-panel
-- naming screen shows a slightly different confirmation/back-out prompt
-- for a PC-bound mon, per `naming_screen.c:696`).
local function openNicknameForMon(mon, sentToPc, onDone)
  if type(mon) ~= "table" then return false, "no_mon" end
  local Naming = engineModule("src.ui.game3.naming")
  if not (Naming and type(Naming.open) == "function") then return false, "no_naming_module" end
  local Pokemon = engineModule("src.core.game3.pokemon")
  local species = mon.speciesId or mon.species
  local displayName = type(mon.nickname) == "string" and mon.nickname ~= "" and mon.nickname or nil
  if not displayName and Pokemon and type(Pokemon.name) == "function" then
    local ok, n = pcall(Pokemon.name, species)
    if ok and type(n) == "string" and n ~= "" then displayName = n end
  end
  displayName = displayName or "?"
  local title = displayName
  if type(Naming.monTitle) == "function" then
    local ok, t = pcall(Naming.monTitle, displayName)
    if ok and type(t) == "string" and t ~= "" then title = t end
  end
  local ok = pcall(Naming.open, {
    template = "CAUGHT_MON",
    maxLen = 10,
    species = species,
    gender = mon.gender or (mon.isFemale and 1) or 0,
    personality = mon.personality or 0,
    seed = displayName,
    sentToPc = sentToPc == true,
    title = title,
    onDone = function(nick)
      if nick and nick ~= "" and nick ~= displayName then mon.nickname = nick end
      if type(onDone) == "function" then pcall(onDone, nick) end
    end,
  })
  if not ok then return false, "naming_open_failed" end
  return true
end

function Game3Data.openNicknameForPartySlot(slot, onDone)
  local s = session()
  local mon = s and type(s.party) == "table" and s.party[slot]
  return openNicknameForMon(mon, false, onDone)
end

-- gear-hook follow-up round 2: the same hook, for a catch that went
-- straight to the PC (the party was full -- `Party.giveMon`'s own
-- `opts.toPC` branch, `src.core.game3.storage.sendMonToPC`, which is what
-- returns the `(boxId, slotIdx)` pair this takes). `boxRef` is
-- `{box=boxId, slot=slotIdx}` -- exactly the two values `sendMonToPC`
-- hands back (and the same pair `Storage.getBoxMon`/`Storage.withdraw`
-- already take), so a caller does not need to invent its own reference
-- shape:
--   local sent, boxId, slotIdx = Storage.sendMonToPC(session, mon)
--   if sent then Game3Data.openNicknameForBoxMon({box=boxId, slot=slotIdx}, onDone) end
function Game3Data.openNicknameForBoxMon(boxRef, onDone)
  if type(boxRef) ~= "table" or not boxRef.box or not boxRef.slot then
    return false, "bad_box_ref"
  end
  local s = session()
  local Storage = engineModule("src.core.game3.storage")
  if not (Storage and type(Storage.ensure) == "function" and type(Storage.getBoxMon) == "function") then
    return false, "no_storage_module"
  end
  local storage = s and Storage.ensure(s)
  local mon = storage and Storage.getBoxMon(storage, boxRef.box, boxRef.slot)
  return openNicknameForMon(mon, true, onDone)
end

function Game3Data.ready()
  return session() ~= nil
end

return Game3Data
