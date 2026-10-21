-- VRITK_FRLG_HOST (W5, untamed-hook DESIGN.md 2/3b): game3 helpers for an
-- overworld catch on FireRed/LeafGreen. Engine calls only; nothing here
-- keeps state, starts a flow or runs by itself. FRLG_CATCH's capture tail
-- decides WHEN each helper runs (always from input.step, never a render
-- callback) and in what order (build, lock, spend, seen, roll, store).
--
--   buildWild(spec)        a complete party-shaped mon from species, level,
--                          personality (+ optional ivs/item/hp/status/moves),
--                          without writing anything. nil, reason on failure.
--   roomFor(session)       party has a free slot, or the PC does.
--   standInState(opts)     the battle-state stand-in a throw outside a battle
--                          passes to Catching (terrain, turn, Safari state).
--   target(mon)            the foe-battler stand-in Catching reads.
--   odds(ball, target, st, session)     FireRed's catch odds 'a' (0..255).
--   shakeRoll(a, rng)      pret's four-check shake loop on odds a.
--   worldBusy() / fieldReady(game)       refusal gates (reason strings).
--   towerGhost(session)    a Pokemon Tower floor without the Silph Scope.
--   safari(session)        { active, balls } of the Safari Game.
--   roamerCaught(session, mon)  deactivate the roamer after a catch.
--   setLead(session, i)    party reorder: slot i becomes the lead (swap).
--   tallGrassAt(cx, cy)    the current map's cell is tall grass (a ball
--                          resting there is hidden by the grass blades).
--
-- Engine modules come through Game3Capture.modules (overridable in tests).
local V = ...
local _ = V

local Game3Capture = {}

Game3Capture.PATHS = {
  Pokemon = "src.core.game3.pokemon",
  Rng = "src.core.game3.rng",
  SummaryData = "src.core.game3.summary_data",
  Party = "src.core.game3.party",
  Storage = "src.core.game3.storage",
  Catching = "src.core.game3.battle.catching",
  Experience = "src.core.game3.battle.experience",
  Bag = "src.core.game3.bag",
  Dex = "src.core.game3.dex",
  ItemsData = "src.core.game3.items_data",
  Field = "src.core.game3.field",
  Battle = "src.core.game3.battle",
  BattleBridge = "src.core.game3.battle_bridge",
  Warp = "src.core.game3.warp",
  Space = "src.core.game3.scripting.space",
  Runtime = "src.core.game3.runtime",
  Forced = "src.core.game3.forced_movement",
  Player = "src.core.game3.player",
  Map = "src.core.game3.map",
  MapCatalog = "src.import.gba.map_catalog",
  Safari = "src.core.game3.safari",
  Rules = "src.core.game3.battle.rules",
  BattleProfile = "src.core.game3.battle.profile",
  Roamer = "src.core.game3.roamer",
  Help = "src.ui.game3.help_system",
  Collision = "src.core.game3.collision",
}

local cache = {}
function Game3Capture.modules(name)
  local m = cache[name]
  if m ~= nil then return m or nil end
  local path = Game3Capture.PATHS[name]
  local ok, mod = pcall(require, path)
  cache[name] = (ok and type(mod) == "table") and mod or false
  return cache[name] or nil
end
local function M(name) return Game3Capture.modules(name) end

-- item ids (pokefirered include/constants/items.h)
Game3Capture.MASTER_BALL, Game3Capture.SAFARI_BALL = 1, 5
-- the twelve balls of FireRed's POKE BALLS pocket (ITEM_MASTER_BALL = 1 ..
-- ITEM_PREMIER_BALL = 12), keyed by the names VRITK's pouch uses
Game3Capture.BALL_IDS = {
  MASTER_BALL = 1, ULTRA_BALL = 2, GREAT_BALL = 3, POKE_BALL = 4, SAFARI_BALL = 5, NET_BALL = 6,
  DIVE_BALL = 7, NEST_BALL = 8, REPEAT_BALL = 9, TIMER_BALL = 10, LUXURY_BALL = 11, PREMIER_BALL = 12,
}
-- battle terrain id for a Pokemon met on water (BattleBg.TERRAIN.WATER)
Game3Capture.TERRAIN_WATER = 4
-- pokefirered include/constants/metatile_behaviors.h MB_TALL_GRASS (the
-- engine's battle/bg.lua uses the same value)
Game3Capture.MB_TALL_GRASS = 0x02

--- Is map-local cell (cx, cy) of the current map tall grass? Read only.
function Game3Capture.tallGrassAt(cx, cy)
  local Collision = Game3Capture.modules("Collision")
  if not (Collision and Collision.behavior and cx and cy) then return false end
  local ok, b = pcall(Collision.behavior, math.floor(cx), math.floor(cy))
  return ok and b == Game3Capture.MB_TALL_GRASS
end
Game3Capture.SILPH_SCOPE = 359

-- ------------------------------------------------------------ build
local function rollIvs(Rng)
  local iv1, iv2 = Rng.Random(), Rng.Random()
  return {
    hp = iv1 % 32, atk = math.floor(iv1 / 32) % 32, def = math.floor(iv1 / 1024) % 32,
    spe = iv2 % 32, spa = math.floor(iv2 / 32) % 32, spd = math.floor(iv2 / 1024) % 32,
  }
end

-- Wild held item: pret GenerateWildMon (common 50%, rare 5%; both set = 50/5).
local function rollItem(meta, Rng)
  local common = tonumber(meta and meta.itemCommon) or 0
  local rare = tonumber(meta and meta.itemRare) or 0
  if common == 0 and rare == 0 then return nil end
  local r = Rng.Random() % 100
  if common ~= 0 and rare ~= 0 then
    if r < 50 then return common elseif r < 55 then return rare end
    return nil
  elseif common ~= 0 then
    if r < 50 then return common end
  elseif r < 5 then
    return rare
  end
  return nil
end

local function copyList(t)
  if type(t) ~= "table" then return nil end
  local out = {}
  for i, v in ipairs(t) do out[i] = v end
  return out
end
local function copyMap(t)
  if type(t) ~= "table" then return nil end
  local out = {}
  for k, v in pairs(t) do out[k] = v end
  return out
end

--- spec = { species, level, personality, ivs?, item?, hp?, status?, moves?, pp?,
---          session? }. Returns a fresh mon table (every nested table fresh:
--- storeCaught only copies two levels deep), or nil, reason. Writes nothing:
--- IVs and the held item draw from the game RNG, exactly as a battle's
--- wild-mon build would at battle start.
function Game3Capture.buildWild(spec)
  local Pokemon, Rng = M("Pokemon"), M("Rng")
  if not (Pokemon and Rng) then return nil, "engine modules unavailable" end
  local species = tonumber(spec and spec.species)
  local level = tonumber(spec and spec.level)
  local personality = tonumber(spec and spec.personality)
  if not (species and species >= 1) then return nil, "bad species" end
  if not (level and level >= 1 and level <= 100) then return nil, "bad level" end
  if not personality then return nil, "no personality" end
  personality = personality % 4294967296
  local meta = Pokemon.speciesMeta and Pokemon.speciesMeta(species)
  if not meta then return nil, "unknown species " .. species end
  local moves, pp, maxPp
  if type(spec.moves) == "table" and #spec.moves > 0 then
    moves = copyList(spec.moves)
    pp = copyList(spec.pp)
    maxPp = {}
    for i, m in ipairs(moves) do maxPp[i] = Pokemon.movePp and Pokemon.movePp(m) or (pp and pp[i]) or 0 end
    if not pp or #pp == 0 then pp = copyList(maxPp) end
  else
    moves, pp, maxPp = Pokemon.movesAtLevel(species, level)
    -- pokefirered GiveBoxMonInitialMoveset; the battle build errors here
    if not moves or #moves == 0 then return nil, "species has no moves at this level" end
    moves, pp, maxPp = copyList(moves), copyList(pp), copyList(maxPp)
  end
  local ivs = copyMap(spec.ivs) or rollIvs(Rng)
  local item = spec.item
  if item == nil then item = rollItem(meta, Rng) end
  local growthRate = tonumber(meta.growthRate) or 0
  local friendship = tonumber(meta.friendship) or 70
  local ability = Pokemon.abilityId and Pokemon.abilityId(species, personality) or 0
  local SummaryData, Party = M("SummaryData"), M("Party")
  local session = spec.session
  -- the field set of Party.giveMon (party.lua:224-262), with the given
  -- personality/IVs/item; OT, ball, met location and name are stamped by
  -- Catching.storeCaught
  local mon = {
    species = species, speciesId = species,
    speciesNumbering = Pokemon.NUMBERING_INTERNAL,
    name = Pokemon.name and Pokemon.name(species) or nil,
    nickname = "",
    level = level, metLevel = level,
    growthRate = growthRate,
    exp = SummaryData and SummaryData.expForLevel and SummaryData.expForLevel(growthRate, level) or 0,
    status = spec.status,
    moves = moves, pp = pp, maxPp = maxPp,
    personality = personality,
    nature = Pokemon.natureId and Pokemon.natureId(personality) or 0,
    ivs = ivs,
    evs = { hp = 0, atk = 0, def = 0, spe = 0, spa = 0, spd = 0 },
    ability = ability, abilityId = ability,
    gender = Pokemon.gender and Pokemon.gender(species, personality) or "U",
    happiness = friendship, friendship = friendship,
    item = item,
    metGame = Party and Party.metGame and Party.metGame() or nil,
    pokerus = 0,
    otGender = Party and Party.otGender and session and Party.otGender(session) or nil,
  }
  Pokemon.applyStats(mon)
  local hp = tonumber(spec.hp)
  if hp then mon.hp = math.max(0, math.min(mon.maxHp or hp, hp)) end
  local Experience = M("Experience")
  if Experience and Experience.syncExpToLevel then pcall(Experience.syncExpToLevel, mon) end
  return mon
end

-- ------------------------------------------------------------ room / odds / roll
function Game3Capture.roomFor(session)
  if type(session) ~= "table" then return false end
  if #(session.party or {}) < 6 then return true end
  local Storage = M("Storage")
  if not (Storage and Storage.findOpenSlot and Storage.ensure) then return false end
  local ok, slot = pcall(function() return Storage.findOpenSlot(Storage.ensure(session)) end)
  return ok and slot ~= nil
end

function Game3Capture.target(mon)
  local Pokemon = M("Pokemon")
  local t1, t2
  if Pokemon and Pokemon.types then
    local ok, a, b = pcall(Pokemon.types, mon.species)
    if ok then
      if type(a) == "table" then t1, t2 = a[1], a[2] else t1, t2 = a, b end
    end
  end
  return { species = mon.species, mon = mon, type1 = t1, type2 = t2 or t1 }
end

--- opts = { water = bool, safari = bool, species = n }. A stand-in, not a
--- battle: Catching reads only terrain/turn/safariState/wild from it. It
--- carries what a battle's first turn carries: turn 0 (Timer Ball x1, pret's
--- battleTurnCounter) and the numeric terrain id the battle sets
--- (battle/init.lua st.terrain; on water BattleBg.TERRAIN.WATER), so every
--- ball's multiplier is the one a first-turn throw in that battle gets.
function Game3Capture.standInState(opts)
  opts = opts or {}
  local st = { wild = true, turn = 0, terrain = opts.water and Game3Capture.TERRAIN_WATER or nil,
    overworld = true }
  if opts.safari then
    local Pokemon, Rules = M("Pokemon"), M("Rules")
    local meta = Pokemon and Pokemon.speciesMeta and Pokemon.speciesMeta(opts.species)
    if Rules and Rules.safari and Rules.safari.newState then
      -- the state a Safari battle starts with (no bait or rock thrown yet)
      st.safariState = V.require("compat/EmeraldCaptureCompat").safariState(opts, meta, Rules, M) or Rules.safari.newState(meta and meta.catchRate, meta and meta.safariZoneFleeRate)
    end
    st.safari = true
  end
  return st
end

function Game3Capture.odds(ball, target, st, session)
  local Catching = M("Catching")
  return Catching.catchOdds(ball, target, st, session)
end

--- pret battle_script_commands.c Cmd_handleballthrow: odds >= 255 always
--- catches; else b = 1048560 / sqrt(sqrt(16711680 / a)) and four checks of
--- a 16-bit random < b. rng(lo, hi) -> integer. Returns caught, shakes (0..4).
function Game3Capture.shakeRoll(a, rng)
  a = tonumber(a) or 1
  if a >= 255 then return true, 4 end
  local b = math.floor(1048560 / math.sqrt(math.sqrt(16711680 / math.max(1, a))))
  for n = 1, 4 do
    if rng(0, 65535) >= b then return false, n - 1 end
  end
  return true, 4
end

--- Exact probability that a shake loop on odds a catches (for tests).
function Game3Capture.catchProbability(a)
  if a >= 255 then return 1 end
  local b = math.floor(1048560 / math.sqrt(math.sqrt(16711680 / math.max(1, a))))
  local p = math.min(1, b / 65536)
  return p ^ 4, p
end

-- ------------------------------------------------------------ gates
--- fix57 (bug 1): is the field locked by any tag other than `tag`? (Field.locked is derived from Field._locks.)
--- With no exempt tag this is exactly Field.locked.
local function lockedByOthers(Field, tag)
  if not Field.locked then return false end
  if type(tag) ~= "string" then return true end
  local locks = rawget(Field, "_locks")
  if type(locks) ~= "table" then return true end
  for t in pairs(locks) do
    if t ~= tag then return true end
  end
  return false
end

--- Set ONLY by compat/Gen3ChooseYouCompat around PartyFollower:eligible while our own Wilds swap scene runs: the lock
--- tag that scene holds is then not "busy". Every other check below, and every other caller (throws, deploys,
--- captures), still sees the lock.
Game3Capture.lockExempt = nil

--- true, reason when the overworld cannot take a capture write right now.
function Game3Capture.worldBusy()
  local Field = M("Field")
  if not (Field and Field.running) then return true, "no overworld" end
  if lockedByOthers(Field, Game3Capture.lockExempt) then return true, "field locked" end
  -- Field.unlock() refuses while these run (field.lua:226-235): never take
  -- the lock then, or our own unlock could not release it
  if Field._flyLanding or Field._fallWarp or Field._fieldCallback then
    return true, "a field effect is running"
  end
  local okP, Preview = pcall(require, "src.ui.game3.map_preview_screen")
  if okP and type(Preview) == "table" and Preview.isForestActive then
    local okF, active = pcall(Preview.isForestActive)
    if okF and active then return true, "a map preview is showing" end
  end
  local Runtime = M("Runtime")
  if Runtime and Runtime.uiBusy then
    local ok, busy = pcall(Runtime.uiBusy)
    if ok and busy then return true, "a menu is open" end
  end
  local Space = M("Space")
  if Space and Space.vm and Space.vm.isRunning and Space.vm:isRunning() then
    return true, "a script is running"
  end
  local Battle, BB = M("Battle"), M("BattleBridge")
  if Battle and Battle.isActive and Battle.isActive() then return true, "a battle is running" end
  -- hazard H1: between BattleBridge.start and finish (the transition too)
  if BB and BB._finish ~= nil then return true, "a battle is starting" end
  local Warp = M("Warp")
  if Warp and Warp.isBusy and Warp.isBusy() then return true, "mid-warp" end
  local Forced = M("Forced")
  if Forced and Forced.fieldControlsLocked then
    local ok, locked = pcall(Forced.fieldControlsLocked)
    if ok and locked then return true, "forced movement" end
  end
  local Help = M("Help")
  if Help and Help.isOpen and Help.isOpen() then return true, "help is open" end
  return false
end

function Game3Capture.playerMoving()
  local Player = M("Player")
  return Player and Player.moving == true or false
end

--- game.phase must be the plain field (not boot, quest log, arena, ...).
function Game3Capture.fieldReady(game)
  if not (game and game.phase == "field") then return false, "not in the field" end
  local Runtime = M("Runtime")
  if Runtime and Runtime.isActive and not Runtime.isActive() then return false, "runtime stopped" end
  return true
end

-- pokefirered battle_setup.c: Pokemon Tower 1F-7F without the Silph Scope
-- is a ghost encounter (a ball is dodged and nothing is caught).
function Game3Capture.towerGhost(session)
  local Map, Catalog, Bag = M("Map"), M("MapCatalog"), M("Bag")
  local mapId = Map and Map.current
  if type(mapId) ~= "string" then return false end
  local tower = false
  for f = 1, 7 do
    local id = Catalog and Catalog.pretToEngine and Catalog.pretToEngine("PokemonTower_" .. f .. "F")
      or ("FR_POKEMON_TOWER_" .. f .. "F")
    if mapId == id then tower = true; break end
  end
  if not tower then return false end
  return not (Bag and session and session.bag and Bag.has(session.bag, Game3Capture.SILPH_SCOPE, 1))
end

function Game3Capture.safari(session)
  local Safari = M("Safari")
  if not (Safari and Safari.isActive) then return { active = false, balls = 0 } end
  local ok, on = pcall(Safari.isActive, session)
  if not (ok and on) then return { active = false, balls = 0 } end
  return { active = true, balls = Safari.balls(session) }
end

-- ------------------------------------------------------------ bag / Safari stock
function Game3Capture.ballId(key)
  if Game3Capture.BALL_IDS[key] then return Game3Capture.BALL_IDS[key] end
  local ItemsData = M("ItemsData")
  return (ItemsData and ItemsData.toNumericId and ItemsData.toNumericId(key)) or tonumber(key)
end

function Game3Capture.hasBall(session, ballId, safari)
  if safari then return (tonumber(session.safari and session.safari.balls) or 0) > 0 end
  local Bag = M("Bag")
  return Bag and session and session.bag and Bag.has(session.bag, ballId, 1) or false
end

--- Spends one ball. Returns true when it did (the caller refunds on abort).
function Game3Capture.spendBall(session, ballId, safari)
  if safari then
    local sf = session.safari
    local n = tonumber(sf and sf.balls) or 0
    if n < 1 then return false end
    sf.balls = n - 1
    return true
  end
  local Bag = M("Bag")
  return Bag.remove(session.bag, ballId, 1) == true
end

function Game3Capture.refundBall(session, ballId, safari)
  if safari then
    session.safari = session.safari or {}
    session.safari.balls = (tonumber(session.safari.balls) or 0) + 1
    return true
  end
  local Bag = M("Bag")
  return Bag.add(session.bag, ballId, 1) ~= false
end

function Game3Capture.markSeen(session, species, personality)
  local Dex = M("Dex")
  if not (Dex and session) then return end
  session.dex = session.dex or Dex.new()
  Dex.handleSetPokedexFlag(session.dex, species, false, personality)
end

-- ------------------------------------------------------------ roamer
function Game3Capture.roamerCaught(session, mon)
  local Roamer = M("Roamer")
  if not (Roamer and Roamer.onBattleEnd) then return false end
  -- the result string must be "caught" (roamer.lua:311; engine bug B1)
  Roamer.onBattleEnd(session, { hp = mon and mon.hp, status = mon and mon.status }, "caught")
  return not (session.roamer and session.roamer.active)
end

-- ------------------------------------------------------------ lead swap
--- Party slot i becomes the lead: slots 1 and i swap (the party menu's
--- SWITCH). Pure table reorder; the caller gates it (no battle, script,
--- warp, forced movement, menu or capture in progress).
function Game3Capture.setLead(session, i)
  local party = session and session.party
  i = tonumber(i)
  if type(party) ~= "table" then return false, "no party" end
  if not (i and i >= 1 and i <= #party and i == math.floor(i)) then return false, "bad slot" end
  if i == 1 then return true, "already the lead" end
  local mon = party[i]
  if type(mon) ~= "table" then return false, "empty slot" end
  if mon.isEgg then return false, "an egg cannot lead" end
  party[1], party[i] = party[i], party[1]
  return true
end

return Game3Capture
