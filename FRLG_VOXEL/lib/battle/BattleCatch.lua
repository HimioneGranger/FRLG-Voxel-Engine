-- FRLG_VOXEL (W6, battle phase P-B1 seam for P-B4): throwing a Poke Ball
-- INTO a battle from VR (user requirement 2026-09-28: catching inside
-- battles, as in every other generation).
--
-- The normal BAG -> Poke Ball flow needs nothing from here: the engine runs
-- it, and the 3D presenter shows the bag on the battle card and the throw,
-- shakes and catch as a ball card on the arena (BattlePass). This module is
-- the seam for the VRITK physical throw (P-B4): during the command phase it
-- queues the SAME command the BAG menu would produce, so the engine does
-- everything else exactly as for a menu throw -- ball stock, trainer
-- ("The TRAINER blocked the BALL!") and ghost ("It dodged the thrown BALL!")
-- blocking, the catch roll, the shakes, the Pokedex and party/PC storage.
--   canThrow(itemId) -> ok, reason, info { kind = "bag"|"safari",
--                       blockedBy = "trainer"|"ghost"|nil, safariBalls }
--   throw(itemId)    -> ok, reason|info
-- The command goes through the engine's Gen3 compat layer when it has the
-- seam: the mod-facing FireRed battle facade src.battle.BattleState
-- (src/mods/Gen3Compat.lua), method throwBall(itemId) -- user rule
-- 2026-09-28: Gen3 needs in shared/core code go in a Gen3 compat layer, never
-- a plain edit (w6/ENGINE_SEAM_battle_catch.md). Without it, as a lab-only
-- fallback, it sets Ui._pendingCommand, the field Ui.takeCommand consumes
-- (battle/ui.lua; the design's "internal field" row 23).
--
-- This is the presenter's ONLY game write, and it is an input action (like
-- pressing A on the menu), never done while drawing. BattleSource stays
-- read-only.
local V = ...
local _ = V

local BattleCatch = {}
BattleCatch.__index = BattleCatch

BattleCatch.PATHS = {
  battle = "src.core.game3.battle",
  ui = "src.core.game3.battle.ui",
  bag = "src.core.game3.bag",
  catching = "src.core.game3.battle.catching",
  runtime = "src.core.game3.runtime",
  bagMenu = "src.ui.game3.bag_menu",
  partyMenu = "src.ui.game3.party_menu",
  facade = "src.battle.BattleState", -- the engine's Gen3 compat battle facade
}
BattleCatch.POKE_BALL = 4       -- ITEM_POKE_BALL (FRLG numeric id)

local function defaultEngine(name)
  local ok, m = pcall(require, name)
  if ok and type(m) == "table" then return m end
  return nil
end

function BattleCatch.new(opts)
  opts = opts or {}
  return setmetatable({ engine = opts.engine or defaultEngine, cache = {}, log = opts.log or print,
    thrown = 0, lastCommand = nil }, BattleCatch)
end

function BattleCatch:mod(key)
  local m = self.cache[key]
  if m ~= nil then return m or nil end
  m = self.engine(BattleCatch.PATHS[key] or key)
  self.cache[key] = m or false
  return m
end

local function call(m, fn, ...)
  local f = m and m[fn]
  if type(f) ~= "function" then return nil end
  local ok, v = pcall(f, ...)
  if ok then return v end
  return nil
end

-- May a ball be thrown into the battle right now? Read-only.
-- Round 2: the throw WINDOW only (a battle in the command phase with the
-- action menu up, nothing queued), whatever ball is in hand. VR targets use
-- this; canThrow adds the ball checks. Returns ok, reason, st.
function BattleCatch:window()
  local B, Ui = self:mod("battle"), self:mod("ui")
  if not (B and Ui) then return false, "no battle module" end
  if call(B, "isActive") ~= true then return false, "no battle" end
  local st = call(B, "getState") or rawget(B, "_st")
  if type(st) ~= "table" then return false, "no battle state" end
  if st.link or st.pokedude then return false, "not in this battle type" end
  if rawget(B, "_phase") ~= "command" then return false, "not the command phase" end
  if rawget(B, "_auto") then return false, "battle is auto-playing" end
  if rawget(Ui, "_mode") ~= "menu" then return false, "the action menu is not up" end
  if rawget(Ui, "_pendingCommand") ~= nil then return false, "a command is already queued" end
  if call(self:mod("bagMenu"), "isOpen") or call(self:mod("partyMenu"), "isOpen") then
    return false, "a menu screen is open"
  end
  return true, nil, st
end

function BattleCatch:canThrow(itemId)
  local B, Ui = self:mod("battle"), self:mod("ui")
  if not (B and Ui) then return false, "no battle module" end
  if call(B, "isActive") ~= true then return false, "no battle" end
  local st = call(B, "getState") or rawget(B, "_st")
  if type(st) ~= "table" then return false, "no battle state" end
  if st.link or st.pokedude then return false, "not in this battle type" end
  if rawget(B, "_phase") ~= "command" then return false, "not the command phase" end
  if rawget(B, "_auto") then return false, "battle is auto-playing" end
  if rawget(Ui, "_mode") ~= "menu" then return false, "the action menu is not up" end
  if rawget(Ui, "_pendingCommand") ~= nil then return false, "a command is already queued" end
  if call(self:mod("bagMenu"), "isOpen") or call(self:mod("partyMenu"), "isOpen") then
    return false, "a menu screen is open"
  end
  local info = {}
  if st.safari then
    local balls = st.safariState and tonumber(st.safariState.balls) or 0
    if balls <= 0 then return false, "no Safari Balls left" end
    info.kind, info.safariBalls = "safari", balls
    return true, nil, info
  end
  itemId = tonumber(itemId) or itemId or BattleCatch.POKE_BALL
  local C = self:mod("catching")
  if not (C and call(C, "isBall", itemId)) then return false, "not a Poke Ball" end
  if not st.oldManTutorial then
    local Runtime, Bag = self:mod("runtime"), self:mod("bag")
    local session = call(Runtime, "getSession")
    local bag = session and session.bag
    if not (Bag and bag and call(Bag, "has", bag, itemId, 1)) then return false, "no such ball in the bag" end
  end
  info.kind = "bag"
  if st.ghostBattle then info.blockedBy = "ghost" elseif not st.wild then info.blockedBy = "trainer" end
  return true, nil, info
end

-- Queue the throw for the engine's next command step. Trainer and ghost
-- battles are allowed through on purpose: the engine blocks them with its
-- own message, exactly like a menu throw.
function BattleCatch:throw(itemId)
  local ok, why, info = self:canThrow(itemId)
  if not ok then return false, why end
  local B, Ui = self:mod("battle"), self:mod("ui")
  local st = call(B, "getState") or rawget(B, "_st")
  local cmd
  if info.kind == "safari" then
    cmd = { kind = "safari", action = "ball", user = "player" }
  else
    cmd = { kind = "bag", user = "player", itemId = tonumber(itemId) or itemId or BattleCatch.POKE_BALL }
  end
  if st and st.double then cmd.battler = tonumber(rawget(Ui, "_active")) or 0 end
  -- the compat facade's throwBall when present (rawget: an absent key would
  -- make the facade print its "no Gen 3 backing" warning)
  local F = self:mod("facade")
  local seam = type(F) == "table" and rawget(F, "throwBall") or nil
  if type(seam) == "function" then
    local okQ, res, why2 = pcall(seam, F, info.kind == "safari" and nil or cmd.itemId)
    if not okQ or res ~= true then return false, "engine refused: " .. tostring(okQ and why2 or res) end
    self.path = "compat"
  else
    Ui._pendingCommand = cmd -- lab-only fallback until the compat seam exists
    self.path = "lab-fallback"
  end
  if self.loggedPath ~= self.path then
    self.loggedPath = self.path
    self.log("[FRLG_VOXEL] in-battle ball throw queued via " .. (self.path == "compat"
      and "the engine's Gen3 compat seam BattleState:throwBall"
      or "the lab fallback Ui._pendingCommand (engine has no BattleState:throwBall)"))
  end
  self.thrown = self.thrown + 1
  self.lastCommand = cmd
  return true, info
end

-- battle-ui (2026-10-01): the user's own in-battle catch presentation (FRLG_CATCH BattleCaptureFX) starts at
-- the VR contact and takes only the RESULT from the engine. Read-only: the engine's live catch sequence
-- (catch_seq.lua: the shake count and outcome CatchSeq.begin rolled, the step it is on).
BattleCatch.PATHS.catchSeq = "src.core.game3.battle.catch_seq"
BattleCatch.PATHS.message = "src.ui.game3.message"
function BattleCatch:catchResult()
  local C = self:mod("catchSeq")
  local B = self:mod("battle")
  local busy = C and call(C, "busy") == true or false
  local out = { busy = busy, phase = B and rawget(B, "_phase") or nil }
  if busy then
    out.caught = rawget(C, "_caught") == true
    out.shakes = tonumber(rawget(C, "_shakes")) or 0
    out.ballId = rawget(C, "_ballId")
    out.step = tonumber(rawget(C, "_i")) or 1
    out.waitingMsg = rawget(C, "_waitingMsg") == true
    out.result = rawget(C, "_result")
  end
  return out
end

-- The engine prints "<player> used POKe BALL!" as an ordinary battle message that waits for A; pret prints it
-- (printstring) and goes straight on to the throw. While the user's presentation runs, this advances exactly
-- that line, once it is fully shown, through the battle UI's own Message.advance (the call the A button makes).
-- An input action from input.step, never from a draw. Returns true once advanced.
function BattleCatch:advanceThrowText()
  local C, Msg = self:mod("catchSeq"), self:mod("message")
  if not (C and Msg and call(C, "busy") == true) then return false end
  if (tonumber(rawget(C, "_i")) or 0) ~= 1 or rawget(C, "_waitingMsg") ~= true then return false end
  local steps = rawget(C, "_steps")
  local first = type(steps) == "table" and steps[1] or nil
  if not (first and first.kind == "msg" and first.data and first.data.text) then return false end
  if call(Msg, "isOpen") ~= true then return false end
  local pages = rawget(Msg, "_pages")
  local page = tonumber(rawget(Msg, "_page")) or 1
  if type(pages) == "table" and page < #pages then return false end
  local shown = call(Msg, "currentPage")
  local want = tostring(first.data.text)
  -- the box shows this line (a single page; FrlgFont control codes may differ, so compare the visible start)
  if type(shown) ~= "string" or shown:sub(1, 6) ~= want:sub(1, 6) then return false end
  if call(Msg, "isWaiting") ~= true then
    call(Msg, "skipReveal")
    return false
  end
  local ok = pcall(Msg.advance)
  if ok then self.advancedThrowText = (self.advancedThrowText or 0) + 1 end
  return ok
end

return BattleCatch
