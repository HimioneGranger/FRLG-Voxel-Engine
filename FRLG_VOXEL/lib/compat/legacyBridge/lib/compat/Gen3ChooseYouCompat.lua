-- FireRed "I choose you" (Lab 8, user answer 2026-09-29 #1: both the
-- battle-opening belt throw AND the overworld belt throw that sends the
-- Pokemon out, the way Crystal's VRITK does). Gen3 compat layer (standing
-- rule 2026-09-28): VRITK's shared ChooseYou.lua / PartyFollower.lua stay
-- byte-identical; this file installs FireRed-only overrides into VRITK's own
-- V from ONE gated seam line in VR_INTERACTIONS_BACKPACK_LAB/main.lua
-- (mods.loaded, reached through Gen3HostCompat, so it never runs on
-- Crystal/Yellow: this mod only loads on generation 3).
--
-- Battle opening. The engine (quest-engine-0.3.22 4111976e, E3) holds a
-- single wild / single trainer intro just before "Go! X!" while a mod keeps
-- claiming it, through the BattleState facade (src.battle.BattleState):
--   claimOpening(label)  every tick while battles should wait (2 s lease)
--   openingPending()     nil | {token, kind, lead, index, ...}
--   chooseOpening(i)     send healthy party slot i instead of the lead
--   releaseOpening({physical=true})  resume; the mon appears without the 2D ball
-- The engine lets go by itself (claims stop 2 s, 8 s with no choice, 3 s
-- after the first choice, 11 s in all, intro reset), so a missed throw can
-- never trap a battle. This file claims exactly when the Gen2 path would
-- begin its opening (the same enabled() gate VRITK hands Gen2BattleCompat),
-- adopts the pause into V.chooseYou.state (gen3 = true), lets the belt stay
-- usable in the battle, and turns the belt's accepted deploy into
-- chooseOpening + native releaseOpening. Trainer battles: lead only (the
-- engine would take any healthy slot).
--
-- Overworld. PartyFollower's Gen1/Gen2 deploy/recall/entity code looks for a
-- Wilds trailer in ow.npcs, which FireRed does not have; on FireRed the
-- follower is the encounter mod's follower actor, driven by FRLG_CATCH's
-- follower (lib/FollowerSendOut.lua there). The overrides below route the
-- belt's deploy/recall to that follower and aim at its card.
local M, Host = {}, ...

local installed = nil -- { V, restore = {fn...}, ... } of the live install

M.OWNER = "VRITK_FRLG_HOST.chooseYou"
M.CLAIM_EVERY = 0.25 -- seconds; the engine's lease lasts 2 s
-- Seconds between an accepted opening throw and the engine's release.
M.APPEAR_DELAY = 0.3
-- battle-ui (2026-10-01), user rule: "stop relying on the game's visual pokeball effects and only use mine for
-- the visuals". An accepted VR opening throw releases the engine PHYSICALLY (engine contract: the owner already
-- showed the throw, so no 2D ball, no ball-open burst, no ball sounds, no throw pose; the "Go! X!" line, the
-- cry and who goes out stay the engine's). The user's beam and growing picture are the only send-out visuals
-- (Gen3PartyActionFX / OpeningBeamFX / FRLG_VOXEL BattlePass). Fallbacks with no VR throw (abort, clear, the VR
-- belt becoming unusable) still release non-physically, so the engine's own send-out shows.
-- false = the Lab 1 behaviour (native ball, burst and sounds at the battler spot).
M.PHYSICAL = true
-- battle-ui item 5 (2026-10-01, outside tester: "the Pokemon is coming out a little TOO soon ... I'd prefer the
-- PokeBall fly a LITTLE further before my party Pokemon emerged and the ball returned to me"). A thrown belt ball
-- is released (the send-out starts and the ball recoils back) once VRITK's SummonReturn.ready sees a visible
-- descent (>= 0.22 s in the air, falling >= 2.16 m/s, 18 cm below its apex). On Gen3 the ball now keeps flying
-- this many seconds more before that release, for the overworld send-out and the battle opening alike (both go
-- through the same belt release). Only the moment of the release moves; who is sent out does not. 0 = old timing.
M.SEND_OUT_EXTRA_FLIGHT = 0.20
M.PROMPT_WILD = "Choose a POK\195\169MON!\nThrow a party BALL!"
M.PROMPT_TRAINER = "Throw your lead\nPOK\195\169 BALL!"
-- belt-switch (2026-10-02): the battle's party switches made physical (compat/Gen3BeltSwitch, VR CONTROLS >
-- BELT SWITCH) and a forgiving recall aim with a hold-to-confirm (compat/Gen3RecallAim). Both reached through
-- Host.require; without them every path below behaves exactly as before.
local function hostModule(name)
  local ok, m = pcall(function() return Host and Host.require(name) end)
  return ok and type(m) == "table" and m or nil
end
local Switch = hostModule("compat/Gen3BeltSwitch")
local Aim = hostModule("compat/Gen3RecallAim")
M.RECALL_CONFIRM = true -- false = a recall fires on the first aimed trigger frame (the shared VRITK behaviour)
-- fix57 (bug 1): Wilds locks the field (Field.lock(tag)) while its follower swap scene runs, which is how a belt
-- send-out / recall of the Wilds follower is played. M.SWAP_LOCK is that scene's tag (wilds_of_hoenn
-- lib/follower_adapter.lua SWAP_LOCK); the belt stays eligible for at most M.SWAP_HOLD_MAX seconds after OUR deploy /
-- recall command, and only while Wilds itself reports the follower busy.
M.SWAP_LOCK = "wilds_of_hoenn_follower_swap"
M.SWAP_HOLD_MAX = 6
-- headset58 (Lab 58 log, FireRed: recall AND deploy effects still reset right after an accepted command although fix57's
-- lock exemption passes with the real Lab 58 file set in a fixture): for this many seconds after OUR accepted deploy / recall
-- the belt stays eligible (field gate relaxed, structural checks kept), so whatever the headset's cause of the false
-- eligibility is, the effect is not reset by it. New commands and grabs are still decided by the strict checks (inCommit).
-- Every reset and every relaxed answer inside the window is LOGGED with the strict gate's reason, so the next headset
-- log names the cause.
M.SWAP_RECENT_MAX = 8
M.RELAX_IN_WINDOW = true

local function healthy(mon)
  return type(mon) == "table" and not mon.isEgg and not mon.egg and (tonumber(mon.hp) or 0) > 0
end

-- The BattleState facade (Gen3Compat on FireRed). Resolved lazily: the
-- facade exists from boot, the battle modules behind it from the field
-- runtime's first tick (claims answer false until then; renewing is enough).
local function battleState(ctx)
  if ctx.battle then return ctx.battle end
  local ok, B = pcall(ctx.require, "src.battle.BattleState")
  if ok and type(B) == "table" and type(B.openingPending) == "function" then
    ctx.battle = B
    return B
  end
  return nil
end

local function call(B, name, ...)
  local fn = B and B[name]
  if type(fn) ~= "function" then return nil end
  local ok, a, b = pcall(fn, ...)
  if not ok then return nil, a end
  return a, b
end

local function catchExports(V)
  local ok, found = pcall(function() return V.require("CatchProvider").find() end)
  return ok and found and found.exports or nil
end

local function prompt(V, text, seconds)
  local ex = catchExports(V)
  local hud = ex and ex.catching and ex.catching.hud
  if not hud then return end
  if text then
    if type(hud.showFeedback) == "function" then pcall(hud.showFeedback, hud, text, seconds) end
  elseif type(hud.clearFeedback) == "function" then
    pcall(hud.clearFeedback, hud)
  end
end

local function isGen3(s) return type(s) == "table" and s.gen3 == true end

-- ------------------------------------------------------------ ChooseYou (instance overrides)
local function installChooseYou(ctx)
  local V = ctx.V
  local cy = V.chooseYou
  if type(cy) ~= "table" then return false, "no V.chooseYou" end
  local Compat = V.require("Gen2PartyCompat")
  local orig = {}
  for _, name in ipairs({ "inBattle", "canGrab", "highlight", "select", "complete", "clear", "abort", "update", "commit" }) do
    orig[name] = cy[name]
  end
  local function B() return battleState(ctx) end
  local function live()
    local on = call(B(), "isActive")
    return on == true
  end

  local function finish(self, s, reason)
    s.phase = "complete"
    s.reason = reason
    if s.prompted then prompt(V, nil); s.prompted = false end
    ctx.last = { token = s.token, reason = reason, index = s.index, kind = s.kind }
  end

  cy.inBattle = function(self, game)
    local s = self.state
    if isGen3(s) then
      return game ~= nil and s.save == game.save and live()
    end
    return orig.inBattle(self, game)
  end

  cy.canGrab = function(self, game, index)
    local s = self.state
    if not isGen3(s) then return orig.canGrab(self, game, index) end
    if not self:inBattle(game) then return true end
    if Switch then local sw = Switch.canGrab(game, index); if sw ~= nil then return sw end end
    local party = game.save and game.save.party
    return s.phase == "waiting" and healthy(party and party[index])
      and (s.kind == "wild" or index == s.lead) and (not s.rseFixedOrder or index == s.lead)
  end

  cy.highlight = function(self, game, index)
    local s = self.state
    if not isGen3(s) then return orig.highlight(self, game, index) end
    if Switch and self:inBattle(game) then local sw = Switch.highlight(game, index); if sw ~= nil then return sw end end
    return self:inBattle(game) and s.phase == "waiting" and (s.kind == "trainer" or s.rseFixedOrder == true) and index == s.lead
  end

  cy.select = function(self, game, index)
    local s = self.state
    if not isGen3(s) then return orig.select(self, game, index) end
    if not self:inBattle(game) or not self:canGrab(game, index) then return false end
    local pending = call(B(), "openingPending")
    if not (pending and pending.token == s.token) then return false end
    local ok = call(B(), "chooseOpening", index)
    if ok ~= true then return false end
    s.mon = game.save.party[index]
    s.index = index
    s.phase = "resolving"
    s.age = 0
    return true
  end

  -- vr-doubles singles beam (2026-10-01, user rule: "I want all of my animations as the base animations with the
  -- originals effects mixed in"): an accepted single opening throw names its battler (0) on the belt command, so
  -- Gen3PartyActionFX draws the user's beam from the thrown ball to the battler spot while the engine's native
  -- ball, burst and sound still play (the release stays non-physical). FireRed and Emerald singles alike; Emerald
  -- doubles set their own battler in EmeraldChooseYouCompat (which wraps this commit).
  cy.commit = function(self, game, c)
    if Switch and isGen3(self.state) then
      local okS, whyS = Switch.commit(game, c)
      if okS ~= nil then return okS, whyS end
    end
    local ok, why = orig.commit(self, game, c)
    local s = self.state
    if ok == true and type(c) == "table" and c.opening and isGen3(s) and not s.rseDouble and c.openingBattler == nil then
      c.openingBattler = 0
    end
    return ok, why
  end

  cy.complete = function(self)
    local s = self.state
    if not isGen3(s) then return orig.complete(self) end
    if s.phase ~= "resolving" then return end
    local pending = call(B(), "openingPending")
    if pending and pending.token == s.token then
      call(B(), "releaseOpening", M.PHYSICAL and { physical = true } or nil)
    end
    finish(self, s, "thrown")
  end

  -- Let go of a live pause (the engine throws the current choice the normal
  -- 2D way). Used on abort, clear and when the VR belt stops being usable.
  local function letGo(self, s, reason)
    if s.phase == "waiting" or s.phase == "resolving" then
      local pending = call(B(), "openingPending")
      if pending and pending.token == s.token then call(B(), "releaseOpening") end
      finish(self, s, reason)
    end
  end

  cy.abort = function(self, reason)
    local s = self.state
    if not isGen3(s) then return orig.abort(self, reason) end
    letGo(self, s, "abort")
    if V.mod and V.mod.log then pcall(V.mod.log.warn, V.mod.log, "Opening throw fallback: %s", tostring(reason)) end
  end

  cy.clear = function(self)
    local s = self.state
    if not isGen3(s) then return orig.clear(self) end
    letGo(self, s, "cleared")
    self.state = nil
  end

  local function adopt(self, game, pending)
    ctx.lastToken = pending.token
    local ow = game.overworld
    local s = { gen3 = true, token = pending.token, battle = { gen3Opening = pending.token },
      save = game.save, map = ow and ow.map, phase = "waiting", kind = pending.kind,
      lead = pending.lead, index = pending.lead, age = 0 }
    -- Emerald facilities keep their engine-selected lead, including wild rooms.
    if pending.fixedOrder == true then local ok, fixed = pcall(function() return ctx.require("src.core.game3.profile").family() == "rse" end); s.rseFixedOrder = ok and fixed == true end
    self.state = s
    ctx.adopted = (ctx.adopted or 0) + 1
    -- An overworld throw at a wild Pokemon started this battle: send that
    -- Pokemon (Crystal's encounter token -> preselected opening).
    local ex = catchExports(V)
    local follower = ex and ex.follower
    local pre
    if follower and type(follower.takeEncounter) == "function" then
      local enemy = B() and B().enemy
      local ok, mon = pcall(follower.takeEncounter, follower, { kind = pending.kind,
        foeSpecies = type(enemy) == "table" and enemy.species or nil })
      pre = ok and mon or nil
    end
    if pre then
      for i, mon in ipairs(game.save.party or {}) do
        if mon == pre and self:select(game, i) then
          s.preselected = true
          self:complete()
          return
        end
      end
    end
    if ctx.onBegin then pcall(ctx.onBegin) end
    prompt(V, (s.kind == "trainer" or s.rseFixedOrder == true) and M.PROMPT_TRAINER or M.PROMPT_WILD,
      tonumber(pending.waitLimit) or 8)
    s.prompted = true
  end

  cy.update = function(self, game, dt)
    local s = self.state
    if s and not isGen3(s) then return orig.update(self, game, dt) end
    game = Compat.view(game)
    dt = math.max(0, math.min(.2, tonumber(dt) or 0))
    self.clock = (self.clock or 0) + dt
    if self.encounter and self.encounter.expires < self.clock then self.encounter = nil end
    local Bs = B()
    if not Bs then return end
    local on = ctx.enabled == nil or (function()
      local ok, v = pcall(ctx.enabled)
      return ok and v == true
    end)()
    -- Renew the 2 s lease every CLAIM_EVERY s of wall time (the engine's
    -- clock): after any hitch the next tick claims before the intro checks.
    local wall = ctx.now()
    if on and (not ctx.claimAt or wall - ctx.claimAt >= M.CLAIM_EVERY or wall < ctx.claimAt) then
      call(Bs, "claimOpening", M.OWNER)
      ctx.claimAt = wall
    end
    ctx.claiming = on
    s = self.state
    -- no battle, nothing adopted: nothing to poll
    if not s and not live() then return end
    local pending = call(Bs, "openingPending")
    if s then
      if not game or game.save ~= s.save or not live() then
        self:clear()
        s = nil
      elseif s.phase == "waiting" or s.phase == "resolving" then
        if not (pending and pending.token == s.token) then
          -- the engine let go by itself: lapse, timeout or intro reset
          local last = call(Bs, "lastOpening")
          finish(self, s, "engine:" .. tostring(last and last.reason or "released"))
        elseif s.phase == "waiting" and not on then
          self:abort("VR belt unavailable")
        elseif s.phase == "resolving" then
          s.age = (s.age or 0) + dt
          if s.age >= M.APPEAR_DELAY then self:complete() end
        end
      end
    end
    if pending and on and not self.state and pending.token ~= ctx.lastToken and game and game.save then
      adopt(self, game, pending)
    end
    if Switch then pcall(Switch.update, game, dt, on) end
  end

  -- vr-doubles (2026-10-01): the Emerald adapter now returns its own undo (two-hand throws wrap one more
  -- ChooseYou method and the shared PartyBelt's release/request); FireRed returns false and installs nothing.
  local emeraldUndo
  if Host then
    local okE, onE, undoE = pcall(function()
      return Host.require("compat/EmeraldChooseYouCompat").install(ctx, { battle = B, call = call, prompt = prompt,
        finish = finish, healthy = healthy, host = Host })
    end)
    if okE and onE and type(undoE) == "function" then emeraldUndo = undoE
    elseif not okE then ctx.log("Emerald two-slot adapter off: " .. tostring(onE)) end
  end

  return true, function()
    if emeraldUndo then pcall(emeraldUndo) end
    for name, fn in pairs(orig) do
      if rawget(cy, name) ~= nil and rawget(cy, name) ~= fn then cy[name] = nil end
    end
    local s = cy.state
    if isGen3(s) then cy.state = nil end
  end
end

-- ------------------------------------------------------------ PartyFollower (module wraps, Gen3 only)
local function installFollower(ctx)
  local V = ctx.V
  local PF = V.require("PartyFollower")
  local Compat = V.require("Gen2PartyCompat")
  local orig = { eligible = PF.eligible, entity = PF.entity, commit = PF.commit, aim = PF.aim }

  local function gen3Battle(game)
    local cy = V.chooseYou
    return cy and isGen3(cy.state) and cy:inBattle(game)
  end

  -- In a FireRed battle that had an opening pause, the belt stays up for the
  -- whole battle, as on Crystal (the Gen1/Gen2 test is "the battle state is
  -- on top of the UI stack", which FireRed's id stack cannot answer).
  -- fix57 (bug 1): the Wilds swap scene of OUR belt command (see M.SWAP_LOCK)
  local swapAt = nil
  local function wildsBusy()
    local finder = V.mod and V.mod.find
    local okF, found = pcall(function() return finder and finder("wilds_of_hoenn") end)
    local fn = okF and found and found.exports and found.exports.vrFollowerBusy
    if type(fn) ~= "function" then return false end
    local ok, busy = pcall(fn)
    return ok and busy == true
  end
  local function swapHold()
    if swapAt and ctx.now() - swapAt <= M.SWAP_HOLD_MAX and wildsBusy() then return M.SWAP_LOCK end
    return false
  end
  M.swapHold = swapHold

  -- headset58: is our accepted command still inside its window? (M.swapRecent is what Gen3PartyActionFX asks)
  local function swapRecent()
    return swapAt ~= nil and ctx.now() - swapAt <= M.SWAP_RECENT_MAX
  end
  M.swapRecent = swapRecent
  local inCommit = false
  -- one line per category (relaxed / refused / reset) per 2 s; the text is only built when the line is due
  local diagAt = { relaxed = -1e9, refused = -1e9, reset = -1e9 }
  local function diagDue(cat)
    local now = ctx.now()
    if now - diagAt[cat] > 2 then diagAt[cat] = now; return true end
    return false
  end
  local function lockTags()
    local G3 = hostModule("Game3Capture")
    local okF, F = pcall(function() return G3 and G3.modules and G3.modules("Field") end)
    local locks = okF and F and rawget(F, "_locks")
    local t = {}
    if type(locks) == "table" then for k in pairs(locks) do t[#t + 1] = tostring(k) end end
    table.sort(t)
    return table.concat(t, ",")
  end
  local function whyStrict(self)
    local c = self.catching
    local okG, busy, reason = pcall(function()
      local G3 = hostModule("Game3Capture")
      if G3 and G3.worldBusy then return G3.worldBusy() end
    end)
    return ("gate=%s worldBusy=%s/%s locks=[%s] phase=%s wildsBusy=%s"):format(tostring(c and c._gateReason),
      tostring(okG and busy), tostring(okG and reason), lockTags(), tostring(c and c.phase), tostring(wildsBusy()))
  end
  -- the stock structural conditions of PartyFollower:eligible WITHOUT the field gate (c.canAcceptVRInput)
  local function structural(self, game)
    local g = Compat.view(game)
    local c = self.catching
    local ow = g and g.overworld
    if not Compat.allowed(g) then return false end
    return self.follower ~= nil and c ~= nil and ow ~= nil and ow.map ~= nil and g.save ~= nil and c.phase == "idle"
      and not c:safariSession(g, ow) and self.follower:controlMode(g) == "follow"
  end

  local function eligibleCore(self, game)
    -- only an adopted FireRed opening changes anything (no extra cost on the
    -- field, where this runs several times a frame)
    local cy = V.chooseYou
    if cy and isGen3(cy.state) and gen3Battle(Compat.view(game)) then
      return self.follower ~= nil and self.catching ~= nil
    end
    -- fix57 (bug 1): Wilds locks the field while its follower swap scene (our belt send-out / recall) runs, which made
    -- the field gate read "busy", this function false, and PartyBeltComponent reset the user's beam at age 0. While
    -- OUR scene runs evaluate every normal check with only that one lock tag ignored: a menu, script, warp, battle
    -- start, running capture or any other lock still refuses.
    if swapAt then
      local tag = swapHold()
      local G3 = tag and hostModule("Game3Capture") or nil
      if G3 then
        G3.lockExempt = tag
        local okE, res = pcall(orig.eligible, self, game)
        G3.lockExempt = nil
        return okE and res or false
      end
    end
    return orig.eligible(self, game)
  end

  PF.eligible = function(self, game)
    local r = eligibleCore(self, game)
    if r or inCommit or not M.RELAX_IN_WINDOW or not swapRecent() then return r end
    local okS, ok = pcall(structural, self, game)
    local cat = (okS and ok) and "relaxed" or "refused"
    if diagDue(cat) then
      local okW, why = pcall(whyStrict, self)
      ctx.log(("belt %s %.2fs after our command (structural=%s) although the strict gate refuses: %s"):format(
        cat == "relaxed" and "kept eligible" or "ineligible", ctx.now() - swapAt, tostring(okS and ok), tostring(okW and why or "?")))
    end
    if cat == "relaxed" then return true end
    return r
  end

  -- headset58: every belt reset inside our command window is logged with the strict gate's reason and the belt's own
  -- liveness, so a reset from the fixed step (fresh/eligible) is told apart from one in update (pose, dt, head jump)
  local okPBC, PBC = pcall(V.require, "PartyBeltComponent")
  local origPBCReset
  if okPBC and type(PBC) == "table" and type(PBC.reset) == "function" then
    origPBCReset = PBC.reset
    local wrappedReset = function(self, ...)
      if swapRecent() and diagDue("reset") then
        local auth = rawget(self, "authority")
        local okE, strict = pcall(function() return orig.eligible(auth, auth and auth.game) end)
        local okW, why = pcall(whyStrict, auth or {})
        ctx.log(("belt reset %.2fs after our command: fresh=%s strictEligible=%s relaxedWindow=%s %s"):format(
          ctx.now() - swapAt, tostring(rawget(self, "fresh")), tostring(okE and strict), tostring(M.RELAX_IN_WINDOW), tostring(okW and why or "?")))
      end
      return origPBCReset(self, ...)
    end
    PBC.reset = wrappedReset
    ctx.pbcReset = { wrapped = wrappedReset, orig = origPBCReset, PBC = PBC }
  end

  PF.entity = function(self, game, mon)
    local g = Compat.view(game)
    if gen3Battle(g) then
      -- belt-switch: during a battle switch the outgoing Pokemon's battler spot is the recall target
      local e = Switch and Switch.entity(g, mon)
      if e then return e end
      return orig.entity(self, game, mon)
    end
    if not self:eligible(g) then return nil end
    local f = self.follower
    if f and type(f.entityFor) == "function" then
      local ok, e = pcall(f.entityFor, f, g, mon)
      if ok then return e end
    end
    return nil
  end

  -- belt-switch: the forgiving recall aim (compat/Gen3RecallAim): an angle cone sized to the target, the runtime's
  -- pointing ray as a third ray, and a ray that hit stays good for the commit recheck. Same entity rules.
  local vhCache
  local function controls()
    if not vhCache then
      local finder = V.mod and V.mod.find
      local okF, fv = pcall(function() return finder and finder("FRLG_VOXEL") end)
      vhCache = okF and fv and fv.exports and fv.exports.vrHost or false
    end
    local input = vhCache and vhCache.input
    if not (input and type(input.snapshot) == "function") then return nil end
    local ok, c = pcall(input.snapshot)
    return ok and type(c) == "table" and c or nil
  end
  ctx.controls = controls
  if Aim then
    local Haptics
    -- fix57 (bug 7, Emerald Lab 50: "recalling isn't working at all", no log line): say WHY a held ball has no target to
    -- aim at (throttled: one line per reason, repeated every 3 s while the ball stays held)
    local noTargetAt, noTargetWhy = -1e9, nil
    local function why(self, g, mon)
      if gen3Battle(g) then return "battle switch: no recall target for this Pokemon (no live switch hold)" end
      if not self:eligible(g) then
        local c = self.catching
        return "belt not eligible (" .. tostring(c and c._gateReason or "field gate / follower mode") .. ")"
      end
      local f = self.follower
      local okS, st = pcall(function() return f and f.sendOutStatus and f:sendOutStatus() end)
      local okM, shown = pcall(function() return f and f.getActiveFollowerMon and f:getActiveFollowerMon(g, false) end)
      if not (okM and shown) then
        return "no follower is shown (backend=" .. tostring(okS and st and st.backend) .. ", " .. tostring(okS and st and st.reason) .. ")"
      end
      if shown ~= mon then return "the follower shown is not this ball's Pokemon" end
      local finder = V.mod and V.mod.find
      local okW, w = pcall(function() return finder and finder("wilds_of_hoenn") end)
      local fn = okW and w and w.exports and w.exports.vrFollowerState
      local st = {}
      local okS2, have = false, false
      if type(fn) == "function" then okS2, have = pcall(fn, st) end
      if okS2 and have and (st.recalled or st.hidden) then
        return ("the follower is %s on the Wilds side: nothing to aim at"):format(st.recalled and "recalled" or "hidden")
      end
      if okS2 and not have then return "the Wilds follower reports no state (no engine follower / renderer yet)" end
      return "the follower has no target card (the overworld provider lists no 'follower:1' record, or it is hidden / recalled)"
    end
    local function noteNoTarget(self, g, mon)
      local okW, text = pcall(why, self, g, mon)
      text = okW and text or ("unknown (" .. tostring(text) .. ")")
      local now = ctx.now()
      if text ~= noTargetWhy or now - noTargetAt > 3 then
        noTargetWhy, noTargetAt = text, now
        ctx.log("recall aim: no target - " .. text)
      end
    end
    PF.aim = function(self, game, mon, ray)
      if type(ray) ~= "table" or type(ray.origin) ~= "table" or type(ray.direction) ~= "table" then return nil end
      local g = Compat.view(game)
      local e = self:entity(g, mon)
      if not e then noteNoTarget(self, g, mon); return nil end
      if Aim.recalled(ray, e) then return e end
      local t = Switch and Switch.target(e)
      -- fix57 (bug 6): Switch.target answers only for a battle switch's recall: that one gets the wider battle profile
      local profile = t and Aim.BATTLE or nil
      local prop = self.catching and self.catching.vrThrowInput and self.catching.vrThrowInput.ballProp
      if not t and prop and prop.targetWorldPoint and g and g.overworld then
        local okT, x, y, z, w, h = pcall(prop.targetWorldPoint, prop, e, g.overworld, ray)
        if okT and x then t = { x = x, y = y, z = z, w = w, h = h } end
      end
      if not t then return nil end
      local hit, via = Aim.hit(ray.origin, ray.direction, t, profile), "ray"
      local side
      if not hit and prop and type(prop.worldFromRoom) == "table" then
        local dir
        dir, side = Aim.pointing(controls(), prop.worldFromRoom, ray.origin)
        if dir then hit, via = Aim.hit(ray.origin, dir, t, profile), "pointing" end
      end
      local before = Aim.state.aims[e]
      local fresh = not before or Aim.clock() - before.at > Aim.AIM_FRESH_SEC * 3
      Aim.noteAim(e, t, hit, via)
      if not hit then return nil end
      Aim.memo(ray, e)
      if fresh then
        if not side and prop then
          local _
          _, side = Aim.pointing(controls(), prop.worldFromRoom, ray.origin)
        end
        if Haptics == nil then
          local okH, H = pcall(V.require, "InteractionHaptics")
          Haptics = okH and type(H) == "table" and H or false
        end
        if Haptics and side then pcall(Haptics.pulse, side, Aim.TICK_AMP, Aim.TICK_SEC) end
      end
      return e
    end
  end

  local commitCore
  PF.commit = function(self, c)
    inCommit = true
    local ok, a, b = pcall(commitCore, self, c)
    inCommit = false
    if not ok then error(a, 0) end
    return a, b
  end
  commitCore = function(self, c)
    local game = Compat.view(self.game)
    self.game = game
    if gen3Battle(game) then return orig.commit(self, c) end
    local f = self.follower
    if not (f and type(f.deploy) == "function") then return orig.commit(self, c) end
    if not self:eligible(game) then return false, "busy" end
    local ow = game.overworld
    if c.context ~= (ow and ow.map) or game.save.party[c.index] ~= c.mon then return false, "stale_party" end
    if not Compat.healthy(c.mon) then return false, "fainted_or_egg" end
    if c.kind == "recall" then
      if not c.target or self:aim(game, c.mon, c.target.ray) ~= c.target.entity then return false, "target_lost" end
      local okR, done, why = pcall(f.recall, f, game, c.mon)
      if not (okR and done) then return false, okR and why or "adapter_error" end
      swapAt = ctx.now() -- fix57 (bug 1)
      self:cue(c, c.target.entity)
      return true, "recalled"
    end
    if c.kind ~= "deploy" then return false, "unsupported" end
    local okD, done, why = pcall(f.deploy, f, game, c.mon, c.target)
    if not (okD and done) then
      self.lastFailure = okD and why or "adapter_error"
      return false, self.lastFailure
    end
    self.lastFailure = nil
    swapAt = ctx.now() -- fix57 (bug 1)
    self:cue(c, self:entity(game, c.mon))
    return true, "deployed"
  end

  -- belt-switch: hold-to-confirm on the recall request (the shared belt asks every frame while the trigger is
  -- pulled on target; it only gets a command once that has lasted Aim.HOLD_SEC)
  local beltUndo
  if Aim then
    local okBelt, Belt = pcall(V.require, "PartyBelt")
    if okBelt and type(Belt) == "table" and type(Belt.request) == "function" then
      local origRequest = Belt.request
      local Haptics
      local wrappedRequest = function(self, kind, index, target)
        if kind == "recall" and M.RECALL_CONFIRM then
          local s = self.slots and self.slots[index]
          if not (s and s.state == "held" and not s.pending and target ~= nil) then
            return origRequest(self, kind, index, target)
          end
          if not Aim.confirm(index) then return nil, "confirming" end
          local id, why = origRequest(self, kind, index, target)
          if id then
            if Haptics == nil then
              local okH, H = pcall(V.require, "InteractionHaptics")
              Haptics = okH and type(H) == "table" and H or false
            end
            if Haptics and (s.hand == "left" or s.hand == "right") then
              pcall(Haptics.pulse, s.hand, Aim.FIRE_AMP, Aim.FIRE_SEC)
            end
          end
          return id, why
        end
        return origRequest(self, kind, index, target)
      end
      Belt.request = wrappedRequest
      beltUndo = function() if Belt.request == wrappedRequest then Belt.request = origRequest end end
    end
  end

  return true, function()
    if beltUndo then beltUndo() end
    for name, fn in pairs(orig) do PF[name] = fn end
  end
end

-- ------------------------------------------------------------ belt release delay (item 5, Gen3 only)
-- Wraps VRITK's SummonReturn.ready (the belt flight's release test) in its own module table. Once the original
-- test first passes for a flight, the release waits SEND_OUT_EXTRA_FLIGHT s more of that flight (latched, so a
-- bounce after the original moment cannot cancel it). A new launch (age back below the latch) starts over.
local function installSummonDelay(ctx)
  local okR, R = pcall(ctx.V.require, "SummonReturn")
  if not (okR and type(R) == "table" and type(R.ready) == "function") then return false, "no SummonReturn" end
  local orig = R.ready
  local wrapped = function(j)
    local extra = tonumber(M.SEND_OUT_EXTRA_FLIGHT) or 0
    if extra <= 0 or type(j) ~= "table" then return orig(j) end
    local age = tonumber(j.age) or 0
    local at = rawget(j, "_gen3ReleaseAt")
    if at and age < at then at = nil; rawset(j, "_gen3ReleaseAt", nil) end
    if not at then
      if not orig(j) then return false end
      at = age
      rawset(j, "_gen3ReleaseAt", at)
    end
    return age >= at + extra
  end
  R.ready = wrapped
  ctx.summonReady = { wrapped = wrapped, orig = orig }
  return true, function()
    if R.ready == wrapped then R.ready = orig end
  end
end

-- ------------------------------------------------------------ install / uninstall
-- Keep version adaptation inside FRLG_VOXEL. Catch retains its own lifecycle.
function M.installFollowerBackend(ctx)
  local found=ctx.V.mod.find('FRLG_CATCH')
  local lib=found and found.exports and found.exports.lib
  if not(lib and type(lib.require)=='function')then return false end
  local F=lib.require('FollowerSendOut')
  if not(type(F)=='table' and type(F.wilds)=='function')then return false end
  local raw=F.wilds
  local function wrapped(self)
    -- Native provider switching/retirement and already-bound fast path stay native.
    if self.wex then return raw(self) end
    local api=self.deps.owMons and self.deps.owMons()
    local ok,id=pcall(function()return api and api.providerId and api.providerId()end)
    if not(ok and id=='wilds_of_hoenn')then return raw(self)end
    local w=self.deps.find and self.deps.find('wilds_of_hoenn')
    local ex=w and w.exports
    if not(w and (w.version or (ex and ex.version))=='1.10.1' and ex
      and type(ex.vrFollowerOverride)=='function' and type(ex.vrFollowerState)=='function')then return raw(self)end
    self.wex,self.wMissAt,self.reason=ex,nil,'bound (wilds_of_hoenn)'
    self.override,self.approach,self.encounter,self.deployed,self.recallAt=nil,nil,nil,nil,nil
    return ex
  end
  F.wilds=wrapped
  return true,function()if F.wilds==wrapped then F.wilds=raw end end
end

function M.installLowHealth(ctx)
  local B=ctx.require('src.core.game3.battle.init')
  local A=ctx.require('src.core.game3.battle.anim')
  local Audio=ctx.require('src.core.game3.audio')
  local SE=ctx.require('src.core.game3.se_ids')
  if not(B and A and Audio and SE and SE.SE_LOW_HEALTH and type(B.update)=='function' and type(Audio.playSe)=='function')then return false end
  local function hidden()
    if not(B.isActive and B.isActive())then return false end
    local facade=battleState(ctx)
    if call(facade,'openingPending')then return true end
    local p=A.present('player')
    return not p or p.visible==false or (p.alpha~=nil and p.alpha<=0)
  end
  local play,update=Audio.playSe,B.update
  local function hush()
    if B._lowHpSong and hidden()then
      if Audio.stopSe then Audio.stopSe(SE.SE_LOW_HEALTH)end
      B._lowHpSong=false
    end
  end
  local function wrappedPlay(id,...)
    if id==SE.SE_LOW_HEALTH and hidden()then B._lowHpSong=false;return false end
    return play(id,...)
  end
  local function wrappedUpdate(...)hush();return update(...)end
  Audio.playSe,B.update=wrappedPlay,wrappedUpdate
  return true,function()
    if Audio.playSe==wrappedPlay then Audio.playSe=play end
    if B.update==wrappedUpdate then B.update=update end
  end
end

--- VRITK's seam: install(V, enabled, onBegin[, deps]). V is VRITK's own
--- module table (V.chooseYou, V.require); enabled() is the Gen2 opening
--- gate (layer registered, belt built, no errors, hands seen < 10 s ago);
--- onBegin() re-seats the belt balls for the opening. deps (tests only):
--- { require = fn, log = fn }. Idempotent per V.
function M.install(V, enabled, onBegin, deps)
  if installed and installed.V == V then return true, "already installed" end
  if installed then M.uninstall() end
  deps = deps or {}
  local ctx = { V = V, enabled = enabled, onBegin = onBegin, require = deps.require or require,
    log = deps.log or function() end, restore = {},
    now = deps.now or function() return love and love.timer and love.timer.getTime() or os.clock() end }
  local ok1, a, undo1 = pcall(installChooseYou, ctx)
  if ok1 and a then ctx.restore[#ctx.restore + 1] = undo1 else ctx.log("ChooseYou overrides off: " .. tostring(ok1 and undo1 or a)) end
  local ok2, b, undo2 = pcall(installFollower, ctx)
  if ok2 and b then ctx.restore[#ctx.restore + 1] = undo2 else ctx.log("follower overrides off: " .. tostring(ok2 and undo2 or b)) end
  if Switch then
    local okW, onW, undoW = pcall(Switch.install, ctx, {
      prompt = prompt,
      controls = function() return ctx.controls and ctx.controls() end,
      ready = function()
        -- the VR belt owns this battle: an adopted Gen3 opening that has finished, and the belt usable now
        local cy = V.chooseYou
        local s = cy and cy.state
        if ctx.claiming ~= true then return false, "belt not claiming" end
        if not isGen3(s) then return false, "no adopted Gen3 opening" end
        if s.phase ~= "complete" then return false, "opening phase " .. tostring(s.phase) end
        return true
      end,
      optionOn = function()
        local finder = V.mod and V.mod.find
        local okF, fv = pcall(function() return finder and finder("FRLG_VOXEL") end)
        local fn = okF and fv and fv.exports and fv.exports.beltSwitch
        if type(fn) ~= "function" then return true end -- default ON (user 2026-10-02)
        local okO, on = pcall(fn)
        return not okO or on ~= false
      end,
    })
    if okW and onW and type(undoW) == "function" then ctx.restore[#ctx.restore + 1] = undoW
    else ctx.log("belt switch off: " .. tostring(okW and undoW or onW)) end
  end
  local ok3, c3, undo3 = pcall(installSummonDelay, ctx)
  if ok3 and c3 then ctx.restore[#ctx.restore + 1] = undo3 else ctx.log("belt release delay off: " .. tostring(ok3 and undo3 or c3)) end
  -- Field effects use the Gen3 card provider. This adapter also declines
  -- opening effects, whose presentation is owned by the native intro.
  local okFx, undoFx = pcall(function()
    local fx = deps.partyActionFX or (Host and Host.require("compat/Gen3PartyActionFX"))
    if fx then return fx.install(V) end
  end)
  if okFx and type(undoFx) == "function" then
    ctx.restore[#ctx.restore + 1] = undoFx
  elseif not okFx then
    ctx.log("party effects overrides off: " .. tostring(undoFx))
  end
  for _,install in ipairs{M.installFollowerBackend,M.installLowHealth}do
    local ok,on,undo=pcall(install,ctx)
    if ok and on and type(undo)=='function'then ctx.restore[#ctx.restore+1]=undo
    else ctx.log('party/audio compatibility unavailable: '..tostring(ok and on or on))end
  end
  installed = ctx
  return ok1 and a and ok2 and b and true or false
end

function M.uninstall()
  if not installed then return false end
  do -- headset58
    local r = installed.pbcReset
    if r and r.PBC and r.PBC.reset == r.wrapped then r.PBC.reset = r.orig end
  end
  for i = #installed.restore, 1, -1 do pcall(installed.restore[i]) end
  installed = nil
  return true
end

-- battle-ui: the user's live opening beams for FRLG_VOXEL's 3D battle (reached through
-- mod.find("VRITK_FRLG_HOST").exports.compat.chooseYou). Plain data or nil.
function M.battleVisuals()
  local okFx, fx = pcall(function() return Host and Host.require("compat/Gen3PartyActionFX") end)
  if not (okFx and type(fx) == "table" and type(fx.battleVisuals) == "function") then return nil end
  local ok, list = pcall(fx.battleVisuals)
  return ok and list or nil
end

-- belt-switch: the physical switch (status / skip for a tablet button) and the recall aim counters.
M.beltSwitch = Switch
M.recallAim = Aim

function M.status()
  if not installed then return { installed = false } end
  local cy = installed.V.chooseYou
  local s = cy and cy.state
  return { installed = true, claiming = installed.claiming == true, adopted = installed.adopted or 0,
    lastToken = installed.lastToken, last = installed.last,
    state = isGen3(s) and { token = s.token, phase = s.phase, kind = s.kind, lead = s.lead,
      index = s.index, preselected = s.preselected == true } or nil }
end

return M
