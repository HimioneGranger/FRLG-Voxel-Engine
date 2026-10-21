-- W4 P5 (vritk-hook/DESIGN.md P5 file list): FireRed/LeafGreen's own
-- fishing behind the physical rod, implementing the EXACT same interface
-- FishingCrystal.lua gives FishingPlay.lua (world/isWater/facingFor/
-- floatCell/prepare -- see that file's own header for the Gen2 native-rule
-- summary this mirrors), backed by game3's Field/Player/Collision/
-- Encounters/battle_bridge instead of a Gen2 World instance.
--
-- Every fact below (function names, field names, exact behaviour) was
-- confirmed by reading the current engine source, not assumed from the
-- design doc's own [F] (inference) tags:
--   * bite roll: Field.lua's own "bite" step is
--     `(not hasMons) or (Rng.Random() % 2 == 1)` -> NO bite (field.lua's
--     updateFishing, ~line 1324-1327). This module rolls the SAME way,
--     just without running the vanilla wait/dots minigame first (matching
--     how FishingCrystal.lua's own M.prepare skips Crystal's vanilla
--     minigame too -- one roll per cast, at cast time).
--   * `Rng.Random()` (src.core.game3.rng) is the game's own PRNG, matching
--     the "use the game's own random number generator" requirement.
--   * `Encounters.hasFishingMons(mapId)` / `Encounters.rollFishing(mapId,
--     rodKind)` (src.core.game3.encounters) do the has-mons check and the
--     species/level/item pick. `rodKind` accepts the string ids
--     "OLD_ROD"/"GOOD_ROD"/"SUPER_ROD" directly (encounters.lua's
--     ROD_KINDS table) -- no translation needed from FishingRodComponent's
--     own `rod.id`.
--   * The walking lock is the generic `Field.locked` flag Player.lua's own
--     input handler already checks (`if Field.locked then return end`),
--     NOT a per-instance method-patch the way Gen2's World object needs
--     (that approach does not apply: Gen3 has no per-session World
--     instance to patch). `Player.fishing` is the separate animation/
--     follower-facing flag Field.startFishing also sets alongside it; this
--     module sets and clears both together, matching FishingCrystal.lua's
--     own `finish` closure.
--   * `ItemUse.canFish()` -- the NATIVE FireRed facing/water/surf gate --
--     explicitly ALLOWS fishing while surfing (its surfing branch requires
--     an adjacent surfable+water tile, it never refuses outright). DESIGN.md
--     P5's "Allow fishing while surfing, as FireRed does" is followed
--     here: unlike FishingCrystal.lua (which adds its OWN surf refusal on
--     top of Gen2, not present in Gen2's own engine either), this module
--     never rejects on `world.player.surfing`.
--   * No standalone "fishing.lua" module exists in game3; this file reads
--     src.core.game3.{field,player,collision,encounters,battle_bridge,rng}
--     directly via plain require() -- the same technique FishingCrystal.lua
--     uses for Gen2's src.world.gen2.* modules. Everything touched
--     (Field.locked, Player.fishing, Field._session, module-level table
--     fields) is a plain, publicly-reachable Lua field, not a private
--     accessor; nothing here writes to the save.
local V = ...
local M = {}

-- Review #19: memoize successful lookups only -- module load state can
-- still change during boot (a module not yet loaded the first time this
-- runs but loaded by the time fishing is actually reachable), so a FAILED
-- lookup is never cached, only a real module table.
local modCache = {}
local function engineRequire(name)
  local m = modCache[name]
  if m ~= nil then return m end
  local ok, found = pcall(require, name)
  if ok and type(found) == "table" then
    modCache[name] = found
    return found
  end
  return nil
end

-- ------------------------------------------------------------ world()
-- "Stable per map": `.map` is the map id STRING (interned, so `~=`
-- compares by value correctly -- unlike Gen2's object identity comparison,
-- this needs no MapView-cache workaround at all; see CRITIQUE #4, which is
-- specific to the Gen2Compat facade FRLG_CATCH's OWN party/belt reads go
-- through, not this module).
local function currentMapId()
  local Field = engineRequire("src.core.game3.field")
  local session = Field and Field._session
  if session and session.map then return session.map end
  -- Review #19: `package.loaded[...]` is always an empty shim in the mod
  -- sandbox on Quest (no real `package` table); the earlier `or` here only
  -- ever worked on desktop, where the sandbox happens not to hide it.
  -- engineRequire (plain require()) is the real global and works on both.
  local Map = engineRequire("src.core.game3.map")
  return Map and Map.current or nil
end

local function battleActive(game)
  if not (type(game) == "table" and game.phase == "field") then return true end
  local T = engineRequire("src.core.game3.battle_transition")
  if T and type(T.isActive) == "function" then
    local ok, active = pcall(T.isActive)
    if ok and active then return true end
  end
  return false
end

-- W4 P5 desktop-verification fix: FishingPlay.lua's own per-frame safety
-- check (generation-agnostic, "the session ends if the world moves on")
-- reads `world ~= self.ticket.world` -- a Lua object-IDENTITY comparison,
-- captured once at cast time. FishingCrystal.lua (Gen2) already satisfies
-- this: its `world` is a real, stable World instance. A first version of
-- this function allocated a brand-new table on every call (no caching, "no
-- MapView-cache workaround at all" per this file's own header, since Gen3
-- has no Gen2Compat facade in the way here) -- which meant `world` was a
-- FRESH object every single frame, so FishingPlay's identity check tripped
-- ONE FRAME after every successful cast, cancelling the session before the
-- bite could ever be seen: found via a real desktop run ("Fishing cast ...
-- -> battle (bite coming)" immediately followed by "Fishing ended: world
-- changed"). Same fix shape as the (separately, engine-side, NOT applied --
-- see w4/ENGINE_PATCH_gen3compat_mapview.md) Gen3Compat MapView cache: keep
-- ONE table alive per current map id and mutate its fields in place, so
-- identity is stable while nothing meaningful changed, and only replaced
-- when `mapId` itself actually changes (a real map transition/warp) --
-- exactly the case FishingPlay's check is meant to catch.
local cachedWorld = nil

function M.world(game)
  local Player = engineRequire("src.core.game3.player")
  local Field = engineRequire("src.core.game3.field")
  if not (Player and Field) then return nil end
  local mapId = currentMapId()
  if not mapId then cachedWorld = nil; return nil end
  if not cachedWorld or cachedWorld.map ~= mapId then
    cachedWorld = { map = mapId, player = {} }
  end
  cachedWorld.battleActive = battleActive(game)
  local cellX, cellY = Player.cellX, Player.cellY
  local p = cachedWorld.player
  p.cellX, p.cellY = cellX, cellY
  -- Review #18: top-left cell px, matching Gen2's own world.player.px/py
  -- convention -- FishingPlay.lua's `floatPosition()` reeling-shore lerp
  -- (`shore={p.px+8,...,p.py+8}`) already adds the +8 cell-centre offset
  -- itself; this used to add it HERE too, so the reeled float landed 8px
  -- off-centre (at the cell corner, not the middle) as it came in to shore.
  p.px = (tonumber(cellX) or 0) * 16
  p.py = (tonumber(cellY) or 0) * 16
  p.facing = Player.facing
  p.surfing = Player.surfing == true
  return cachedWorld
end

-- ------------------------------------------------------------ isWater / facingFor / floatCell
-- Collision.isWater(x, y) answers for the engine's currently-bound map
-- only (no map parameter, unlike Gen2's map:cellCollision) -- exactly the
-- same call FireRed's own ItemUse.canFish() uses for its facing-tile
-- check, so this is the native-faithful choice, not merely convenient.
-- Review #14: a waterfall tile is real ".isWater()" collision (you can Surf
-- across the base of one), but FireRed's own ItemUse.canFish() rejects
-- casting at one regardless -- and floatCell's own "keep going while the
-- next cell is water" walk would otherwise carry the float straight up the
-- fall. Collision.isWaterfall(behaviour) is the native check (collision.lua
-- :408, `beh==MB_WATERFALL`); exclude it here so every caller (facingFor,
-- floatCell) sees a waterfall tile as "not water" uniformly.
local function isWaterCell(cx, cy)
  local Collision = engineRequire("src.core.game3.collision")
  if not (Collision and type(Collision.isWater) == "function") then return false end
  local ok, v = pcall(Collision.isWater, cx, cy)
  if not (ok and v == true) then return false end
  if type(Collision.isWaterfall) == "function" and type(Collision.behavior) == "function" then
    local okB, beh = pcall(Collision.behavior, cx, cy)
    local okF, fall = pcall(Collision.isWaterfall, okB and beh or nil)
    if okF and fall == true then return false end
  end
  return true
end
M.isWater = isWaterCell

M.DELTA = { up = { 0, -1 }, down = { 0, 1 }, left = { -1, 0 }, right = { 1, 0 } }

function M.facingFor(world, dirX, dirZ)
  local p = world and world.player
  if not (p and p.cellX and p.cellY) then return nil end
  local len = math.sqrt(dirX * dirX + dirZ * dirZ)
  if len < 1e-6 then return nil end
  dirX, dirZ = dirX / len, dirZ / len
  local best, bestDot
  for facing, d in pairs(M.DELTA) do
    local dot = d[1] * dirX + d[2] * dirZ
    if dot > 0.2 and isWaterCell(p.cellX + d[1], p.cellY + d[2]) and (not bestDot or dot > bestDot) then
      best, bestDot = facing, dot
    end
  end
  return best
end

function M.floatCell(world, facing, power)
  local p, d = world.player, M.DELTA[facing]
  if not (p and d) then return nil, nil end
  local cx, cy = p.cellX + d[1], p.cellY + d[2]
  local reach = 1 + math.floor((power or 0) * 4 + 0.5)
  for _ = 2, reach do
    local nx, ny = cx + d[1], cy + d[2]
    if not isWaterCell(nx, ny) then break end
    cx, cy = nx, ny
  end
  return cx, cy
end

-- ------------------------------------------------------------ CRITIQUE #1 lifecycle watchdog
-- "Never leave the player stuck": if nothing calls M.heartbeat() for about
-- 10 frames (the layer stopped pumping -- toggle, panel, a 3D failure), or
-- one of the listed host events fires, force-finish(false) the active
-- ticket. Only ever unlocks a lock THIS module's own ticket.finish took
-- (there is at most one active ticket at a time, matching Field.locked's
-- own single-flag nature).
local S = { active = nil, lastHeartbeat = 0, subscribed = false }
-- Review #3 (REVIEW_VRITK_P3P5.md): 10/60 (~0.167s) was too tight -- after
-- a real ~0.2s stall, the engine's own FixedStep catch-up runs roughly 12
-- ticks in a row to make up the gap, so a COUNT-based "N ticks since the
-- last heartbeat" check (considered and rejected) still trips on an
-- ordinary hitch, and even this time-based check needs enough headroom
-- that a single frame hitch doesn't look like "the layer stopped". ~0.5s
-- is comfortably past normal frame-time jitter while still being well
-- under "the player would notice something is wrong".
local STALE_SEC = 0.5

local function now()
  return (love and love.timer and love.timer.getTime and love.timer.getTime()) or 0
end

function M.heartbeat()
  S.lastHeartbeat = now()
end

local function forceFinish(reason)
  local ticket = S.active
  if not (ticket and ticket.status == "prepared") then return end
  pcall(ticket.finish, false, reason or "host_lost")
end

local function ensureSubscribed()
  if S.subscribed then return end
  S.subscribed = true
  local mod = V.mod
  local events = mod and mod.events
  if not (events and type(events.on) == "function") then return end
  local function watch(reason) return function() forceFinish(reason) end end
  events:on("mod.FRLG_VOXEL.session_stopped", watch("session_stopped"))
  events:on("mod.FRLG_VOXEL.failed", watch("failed"))
  events:on("mod.FRLG_VOXEL.stereo", function(payload)
    if payload and payload.on == false and not payload.transient then forceFinish("stereo_off") end
  end)
  events:on("battle.started", watch("battle_started"))
  events:on("map.entered", watch("map_entered"))
  events:on("save.loaded", watch("save_loaded"))
  events:on("core.session_ending", watch("session_ending"))
end

-- Call every engine tick regardless of whether the stereo/VRITK layer is
-- currently pumping (VK main.lua's `input.step` hook, which -- CRITIQUE
-- #7's own point -- already runs on every Game3:update independent of
-- XR/stereo frame state). This is the ONLY reliable place to detect "the
-- layer stopped calling M.heartbeat()", since the layer's own update loop
-- obviously cannot notice its own absence.
function M.tick()
  ensureSubscribed()
  local ticket = S.active
  if not (ticket and ticket.status == "prepared") then return end
  if now() - S.lastHeartbeat > STALE_SEC then forceFinish("no_layer_update") end
end

-- Review #8 (REVIEW_VRITK_P3P5.md): the engine's own general field-input
-- gates -- a running script, a warp mid-transition, a menu/UI, forced-
-- movement tiles (conveyor belts, waterfall descents, spin tiles), pushing
-- a boulder -- were not checked at all, so a cast could be accepted mid
-- one of those and leave Field.locked/Player.fishing set across it.
-- Gen3Compat.worldBusy() (src/mods/Gen3Compat.lua:1323, confirmed reachable
-- via plain require) already covers Field.running/.locked, Runtime.uiBusy,
-- a running script, an active battle and Warp.isBusy in one call; add
-- ForcedMovement.isForced()/Player.boulderPush on top (worldBusy does not
-- know about either). If Gen3Compat itself cannot be loaded, fall back to
-- checking the same individual conditions directly rather than skipping
-- the gate entirely.
local function worldBusy()
  local GC = engineRequire("src.mods.Gen3Compat")
  if GC and type(GC.worldBusy) == "function" then
    local ok, busy = pcall(GC.worldBusy)
    if ok and busy then return true end
  else
    local Field2 = engineRequire("src.core.game3.field")
    if not (Field2 and Field2.running) then return true end
    if Field2.locked then return true end
    local Runtime2 = engineRequire("src.core.game3.runtime")
    if Runtime2 and type(Runtime2.uiBusy) == "function" then
      local ok, busy = pcall(Runtime2.uiBusy)
      if ok and busy then return true end
    end
    local B = engineRequire("src.core.game3.battle")
    if B and type(B.isActive) == "function" then
      local ok, active = pcall(B.isActive)
      if ok and active then return true end
    end
    local W = engineRequire("src.core.game3.warp")
    if W and type(W.isBusy) == "function" then
      local ok, busy = pcall(W.isBusy)
      if ok and busy then return true end
    end
  end
  local FM = engineRequire("src.core.game3.forced_movement")
  if FM and type(FM.isForced) == "function" then
    local ok, forced = pcall(FM.isForced)
    if ok and forced then return true end
  end
  local Player2 = engineRequire("src.core.game3.player")
  if Player2 and (Player2.boulderPush or Player2.moving) then return true end
  return false
end

-- Reasons the watchdog/host already know mean "something else now owns
-- this lock, or is about to" -- clearing Field.locked on top of that could
-- release a lock this module never took. finish() below leaves Field.locked
-- alone for these (Player.fishing, the animation/follower-facing flag, is
-- always safe to clear -- it is never a gate anything else checks).
local NO_UNLOCK_REASON = { map_entered = true, battle_started = true, save_loaded = true, session_ending = true }

-- ------------------------------------------------------------ prepare()
-- Same contract as FishingCrystal.lua's M.prepare: one roll per cast, a
-- ticket with `finish(landed, reason) -> {accepted, error}`. Rejection
-- reasons mirror Gen2's: "no_world", "busy", "no_water", or a
-- "roll_failed: <err>"-shaped string (Gen2 also has "surfing"; Gen3 never
-- returns it, per the native-surf-allowed note above).
function M.prepare(game, rodId, dirX, dirZ, power)
  ensureSubscribed()
  local world = M.world(game)
  if not (world and world.map) then return nil, "no_world" end
  if world.battleActive then return nil, "busy" end
  local Field = engineRequire("src.core.game3.field")
  local Player = engineRequire("src.core.game3.player")
  if not (Field and Player) then return nil, "no_world" end
  if Field.locked or (type(Field.isFishing) == "function" and Field.isFishing()) then return nil, "busy" end
  if worldBusy() then return nil, "busy" end
  local facing = M.facingFor(world, dirX, dirZ)
  if not facing then return nil, "no_water" end
  local Encounters = engineRequire("src.core.game3.encounters")
  if not (Encounters and type(Encounters.hasFishingMons) == "function"
      and type(Encounters.rollFishing) == "function") then
    return nil, "no_world"
  end

  local previousFacing = Player.facing
  Player.facing = facing

  -- Review #14 (part 2): the native facing/water/surf gate, ItemUse.canFish
  -- (item_use.lua:933) -- rejects a waterfall tile at the facing cell and,
  -- while surfing, requires the facing cell to be BOTH surfable and water.
  -- isWaterCell above already excludes waterfalls from facingFor/floatCell,
  -- but canFish is the one call FireRed's own rod item itself gates on, so
  -- check it too rather than re-deriving every one of its rules by hand.
  local ItemUse = engineRequire("src.core.game3.item_use")
  if ItemUse and type(ItemUse.canFish) == "function" then
    local okCan, can = pcall(ItemUse.canFish)
    if not (okCan and can == true) then
      Player.facing = previousFacing
      return nil, "no_water"
    end
  end

  local okHas, hasMons = pcall(Encounters.hasFishingMons, world.map)
  hasMons = okHas and hasMons == true
  local Rng = engineRequire("src.core.game3.rng")
  local bite = false
  if hasMons and Rng and type(Rng.Random) == "function" then
    local okRoll, r = pcall(Rng.Random)
    bite = okRoll and (r % 2 == 0)
  end

  -- Review #13: a no-bite cast, or any cast on a map with no fishing mons,
  -- used to be rejected outright as "no_water" -- as if the water was not
  -- there at all -- instead of casting normally and getting FireRed's own
  -- "Not even a nibble!" (a real cast, hasBite=false, FishingSession's own
  -- "waiting" mode already finishes it as `_finish(false,"no_bite")` once
  -- hasBite is false). The facing is kept either way (a real cast turns the
  -- player to face the water regardless of whether anything bites).
  local outcome, wild = hasMons and "nibble" or "nofish", nil
  if bite then
    -- Review #17: Encounters.rollFishing (encounters.lua:655) resets the
    -- step-based encounter cooldown and rate buff unconditionally as a
    -- side effect of finding a slot -- correct once a battle actually
    -- starts (BattleBridge.startWild's own path re-applies it on a real
    -- landing), but this roll happens speculatively at CAST time, before
    -- the player has even seen a bite. A cancelled/no-bite/missed cast
    -- must not have spent that cooldown reset; save and restore the two
    -- fields the roll touches around the call.
    local savedSteps = Encounters._stepsSinceLastEncounter
    local savedBuff = Encounters._encounterRateBuff
    local okEnc, enc = V.require("compat/EmeraldCaptureCompat").rollFishing(engineRequire, Encounters, world.map, rodId, Field, Player, M.DELTA)
    Encounters._stepsSinceLastEncounter = savedSteps
    Encounters._encounterRateBuff = savedBuff
    if okEnc and enc then outcome, wild = "battle", enc end
  end

  local cx, cy = M.floatCell(world, facing, power)
  -- Review #16: FishingPlay.lua's own float target used a hardcoded
  -- P.WATER_Y (-1) for every generation. Gen3's real water height varies by
  -- map; read it from the same world-px ground query FRLG_CATCH's own ball
  -- physics already uses. This file now lives inside VRITK_FRLG_HOST
  -- itself (moved from VR_INTERACTIONS_BACKPACK_LAB's lib/FishingGen3.lua),
  -- so worldPx is this mod's own export, no cross-mod HostProvider lookup
  -- needed. floatY stays nil on any failure -- FishingPlay's own
  -- `ticket.floatY or P.WATER_Y` fallback then behaves exactly as before;
  -- Crystal tickets never set this field at all.
  local floatY = nil
  do
    local worldPx = V.mod and V.mod.exports and V.mod.exports.worldPx
    if worldPx and type(worldPx.groundY) == "function" then
      local okY, y = pcall(worldPx.groundY, cx * 16 + 8, cy * 16 + 8)
      if okY and type(y) == "number" then floatY = y end
    end
  end
  Field.locked = true
  Player.fishing = true

  local ticket = { status = "prepared", hasBite = outcome == "battle" and wild ~= nil, outcome = outcome,
    wild = wild, facing = facing, floatCell = { cx, cy }, floatY = floatY, world = world }
  ticket.finish = function(landed, reason)
    if ticket.status ~= "prepared" then return { accepted = false } end
    ticket.status = "finished"
    Player.fishing = false
    -- Review #8 (finish side): do not blindly clear Field.locked -- if the
    -- host already moved on for one of these reasons, or a warp/script has
    -- started since, something else now owns (or is about to own) that
    -- lock and Field.unlock()'s own silent refusal could otherwise leave
    -- the wrong thing thinking it still holds it. Never route through
    -- Field.unlock() itself either way (its silent-refusal design is meant
    -- for ITS OWN callers, not a third party guessing at their state).
    local suppressUnlock = NO_UNLOCK_REASON[reason] == true
    if not suppressUnlock then
      local Warp = engineRequire("src.core.game3.warp")
      if Warp and type(Warp.isBusy) == "function" then
        local okW, busy = pcall(Warp.isBusy)
        if okW and busy then suppressUnlock = true end
      end
    end
    if not suppressUnlock then
      local GC = engineRequire("src.mods.Gen3Compat")
      if GC and type(GC.worldBusy) == "function" then
        -- worldBusy() also reports busy on Field.locked (still true here,
        -- since we have not cleared it yet -- always a false positive for
        -- "should I still clear MY OWN lock") and, on a landed catch, would
        -- soon ALSO report busy once our own startWild call below actually
        -- starts the battle. Only the "a script is running" signal is new,
        -- useful information here.
        local okB, busy, why = pcall(GC.worldBusy)
        if okB and busy and why == "a script is running" then suppressUnlock = true end
      end
    end
    if not suppressUnlock then Field.locked = false end
    if S.active == ticket then S.active = nil end
    if landed and wild then
      local BattleBridge = engineRequire("src.core.game3.battle_bridge")
      if not (BattleBridge and type(BattleBridge.startWild) == "function") then
        return { accepted = false, error = "no_battle_bridge" }
      end
      local Runtime = engineRequire("src.core.game3.runtime")
      -- Same call shape as field.lua's own Field.tryFishingEncounter:
      -- BattleBridge.startWild(Runtime._mod, Field._game, encounter, opts).
      local modArg = Runtime and Runtime._mod
      local gameArg = Field._game or game
      -- W4 P5 desktop-verification fix: BattleBridge.start (battle_bridge.lua,
      -- ~line 474: `local ok,err=Battle.start(startOpts); if not ok then
      -- return nil,err end; return true`) reports success/failure through its
      -- OWN return values (true, or nil+reason), not by throwing -- a clean
      -- "empty party"/"no session" rejection returns normally. The previous
      -- version here only checked pcall's OWN ok (whether startWild threw),
      -- so a clean rejection was silently reported as accepted=true,
      -- error=nil -- found via a real desktop run: `ticket.finish` said
      -- "landed" with no error, but Battle.isActive() stayed false the whole
      -- time afterward. Capture startWild's own two return values and only
      -- report accepted when it actually returned `true`.
      local ok, started, startErr = pcall(BattleBridge.startWild, modArg, gameArg, wild, { battleType = "fish" })
      if not ok then return { accepted = false, error = tostring(started) } end
      if started ~= true then return { accepted = false, error = tostring(startErr or "battle_start_failed") } end
      return { accepted = true }
    end
    return { accepted = true }
  end

  S.active = ticket
  S.lastHeartbeat = now()
  return ticket
end

return M
