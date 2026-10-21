-- Emerald-only adapter for the engine's explicit opening slot API.
-- No engine pause is created here. Single openings and other families retain
-- Gen3ChooseYouCompat's original methods. Mod sandbox: no package or debug.
--
-- vr-doubles (2026-10-01, user: "The user should be able to send out two balls
-- one with each hand simultaneously for double battles"). Two-hand double
-- opening. Before this, one throw at a time: the first accepted throw put the
-- adapter in "resolving" for APPEAR_DELAY, so a second ball thrown at the same
-- moment was refused (grab, release-as-throw and commit all checked
-- phase == "waiting") and went back to the belt; slot choice ignored the hand.
-- Now:
--   * the phase stays "waiting" while any slot is open, so each hand can grab,
--     throw and commit its own ball; a party member already thrown (pending or
--     released) and a slot already claimed are never offered twice;
--   * each accepted throw claims one open slot at once (chooseOpeningSlot):
--     by aim when the throw clearly points at one of the open battler spots,
--     else by hand (left hand -> slot 1 = battler 0, right -> slot 2 =
--     battler 2), else the old order (the slot that already holds that member,
--     then the first open one). The hand comes from the shared belt's own
--     release (PartyBelt release/request wrapped here, Emerald only);
--   * both slots thrown within PAIR_WINDOW s -> chooseOpeningPair + one
--     releaseOpening: the engine's joint "Go! A and B!" send-out, both balls
--     opening together;
--   * one throw and no partner by PAIR_WINDOW -> releaseOpeningSlot (the
--     engine's split send-out, as before); the other slot stays open for a
--     later throw, else the engine's own time limit sends its default;
--   * battle-ui (2026-10-01, user rule: own visuals only): releases are
--     physical (no native ball, burst, ball sounds or throw pose);
--     Gen3PartyActionFX draws the user's beam to each spot (c.rseBattler on
--     the accepted command) and FRLG_VOXEL grows each battler in as the
--     user's silhouette. (Was: non-physical, Lab 1 user fix.)
-- The lease is renewed by Gen3ChooseYouCompat.update every CLAIM_EVERY s for
-- as long as the belt is usable, i.e. through both send-outs. Engine timeout,
-- lapse, reset, abort and clear keep their fallbacks: the engine sends every
-- open slot with its current choice (an accepted throw is already seated).
local M = {}
M.PAIR_WINDOW = 0.5    -- s: an accepted throw waits this long for the other hand's throw
M.APPEAR_DELAY = 0.3   -- s: landing -> engine release (Gen3ChooseYouCompat.APPEAR_DELAY)
M.PAIR_SETTLE = 0.1    -- s: the later throw of a pair also lands before the joint release
M.PHYSICAL = true      -- battle-ui (2026-10-01): own visuals only; false = Lab 1 native ball, burst and sounds
M.AIM_MARGIN = math.rad(6)  -- aim decides only when one open spot is this much closer in angle
M.AIM_MAX = math.rad(35)    -- ... and lies within this angle of the throw
M.HAND_SLOT = { left = 1, right = 2 }
M.last = nil           -- the last resolved opening (driver/diagnostics; plain data)

local function sortedThrows(s)
  local out = {}
  for _, t in pairs(s.rseThrows or {}) do out[#out + 1] = t end
  table.sort(out, function(a, b) if a.at ~= b.at then return a.at < b.at end return a.slot < b.slot end)
  return out
end

function M.install(ctx, hooks)
  local ok, family = pcall(function() return ctx.require("src.core.game3.profile").family() end)
  if not ok or family ~= "rse" then return false end
  local cy, V = ctx.V.chooseYou, ctx.V
  local base = {}
  for _, name in ipairs({ "canGrab", "highlight", "select", "complete", "update", "commit" }) do base[name] = cy[name] end
  local hadCommit = rawget(cy, "commit")
  -- Belt time: the ChooseYou clock Gen3ChooseYouCompat.update advances by the frame's dt (clamped to 0.2 s), the
  -- same timeline as the belt's ball flights, so a frame hitch cannot expire the pair window between two throws.
  local function now() return tonumber(cy.clock) or 0 end
  local Beams
  do
    local okB, mod = pcall(function() return hooks.host and hooks.host.require("compat/OpeningBeamFX") end)
    if okB and type(mod) == "table" then Beams = mod end
  end
  local function pending(self)
    local s = self.state
    local p = hooks.call(hooks.battle(), "openingPending")
    if s and s.gen3 and p and p.token == s.token and p.double == true then return p, s end
  end
  local function capable(p)
    local b = hooks.battle()
    return type(b and b.chooseOpeningSlot) == "function" and type(b.releaseOpeningSlot) == "function"
      and type(p.slots) == "table" and (p.slotCount == 1 or p.slotCount == 2) and #p.slots == p.slotCount
  end
  local function sync(s, p)
    s.rseDouble, s.rseSlots, s.rseFixedOrder = true, p.slots, p.fixedOrder == true
    s.rseThrows = s.rseThrows or {}
    -- a slot the engine released (by us, or a timeout) no longer holds a pending throw
    for _, slot in ipairs(p.slots) do
      if slot.released then s.rseThrows[slot.slot] = nil end
    end
  end
  local function record(s, event)
    s.rseLog = s.rseLog or {}
    event.at = now()
    s.rseLog[#s.rseLog + 1] = event
  end
  -- Open slots no throw has claimed yet.
  local function freeSlots(p, s)
    local out = {}
    for _, slot in ipairs(p.slots) do
      if not slot.released and not (s.rseThrows and s.rseThrows[slot.slot]) then out[#out + 1] = slot end
    end
    return out
  end
  -- The member already went out, or another hand's throw already claimed it.
  local function taken(p, s, index)
    for _, slot in ipairs(p.slots) do
      if slot.released and slot.index == index then return true end
    end
    for _, t in pairs(s.rseThrows or {}) do if t.index == index then return true end end
    return false
  end
  local function fixedSlot(free, index)
    for _, slot in ipairs(free) do if slot.default == index then return slot end end
  end
  local function allowed(self, game, index, p, s)
    if not capable(p) or not self:inBattle(game) or s.phase ~= "waiting" then return false end
    if not hooks.healthy(game.save and game.save.party and game.save.party[index]) then return false end
    local offered = false
    for _, i in ipairs(p.eligible or {}) do if i == index then offered = true; break end end
    if not offered or taken(p, s, index) then return false end
    local free = freeSlots(p, s)
    if #free == 0 then return false end
    if p.fixedOrder then return fixedSlot(free, index) ~= nil end
    return true
  end
  -- Aim: the throw's horizontal direction against each open battler spot.
  local function aimSlot(free, c)
    local t = c and c.target
    local o, d = t and t.origin, t and t.direction
    if not (Beams and #free == 2 and type(o) == "table" and type(d) == "table") then return nil end
    local dx, dz = tonumber(d[1]) or 0, tonumber(d[3]) or 0
    local dl = math.sqrt(dx * dx + dz * dz)
    if dl < 1e-6 then return nil end
    local spots = Beams.spots(V)
    if not spots then return nil end
    local angles = {}
    for i, slot in ipairs(free) do
      local sp = spots[slot.battler]
      if not sp then return nil end
      local vx, vz = sp.center[1] - (tonumber(o[1]) or 0), sp.center[3] - (tonumber(o[3]) or 0)
      local vl = math.sqrt(vx * vx + vz * vz)
      if vl < 1e-6 then return nil end
      angles[i] = math.acos(math.max(-1, math.min(1, (vx * dx + vz * dz) / (vl * dl))))
    end
    local bi, oi = 1, 2
    if angles[2] < angles[1] then bi, oi = 2, 1 end
    if angles[bi] <= M.AIM_MAX and angles[oi] - angles[bi] >= M.AIM_MARGIN then return free[bi], angles[bi], angles[oi] end
    return nil
  end
  local function assign(p, s, index, c)
    local free = freeSlots(p, s)
    if #free == 0 then return nil end
    if p.fixedOrder then return fixedSlot(free, index), "fixed" end
    if #free == 1 then return free[1], "remaining" end
    local aimed = aimSlot(free, c)
    if aimed then return aimed, "aim" end
    local want = c and M.HAND_SLOT[c.hand]
    if want then
      for _, slot in ipairs(free) do if slot.slot == want then return slot, "hand" end end
    end
    for _, slot in ipairs(free) do if slot.index == index then return slot, "order" end end
    return free[1], "order"
  end
  local function show(s, p)
    if s.phase ~= "waiting" then return end
    local left = #freeSlots(p, s)
    if left == 0 then return end
    local key = tostring(left) .. ":" .. tostring(p.fixedOrder)
    if s.rsePrompt == key then return end
    s.rsePrompt = key
    local text
    if p.fixedOrder then
      text = left > 1 and "Throw both lead\nPOKE BALLS!" or "Throw the remaining\nlead POKE BALL!"
    else
      text = p.slotCount == 1 and "Choose a POKEMON!\nThrow a party BALL!" or (left > 1 and "Choose two POKEMON!\nOne BALL in each hand!" or "Choose your second\nPOKEMON! Throw a BALL!")
    end
    hooks.prompt(V, text, tonumber(p.deadline) or tonumber(p.waitLimit) or 8)
    s.prompted = true
  end
  local function opts() return M.PHYSICAL and { physical = true } or nil end
  local function note(s, reason, mode)
    if s.rseNoted then return end
    s.rseNoted = true
    local last = hooks.call(hooks.battle(), "lastOpening")
    M.last = { token = s.token, mode = mode, reason = reason, throws = s.rseLog,
      slots = last and last.slots or nil }
  end
  local function done(self, s, reason, mode)
    note(s, reason, mode)
    hooks.finish(self, s, reason)
  end

  -- One accepted throw: claim a slot now. c = the belt command (nil from adopt's preselection path).
  local function throw(self, game, index, c)
    local p, s = pending(self)
    if not p then return false end
    sync(s, p)
    if not allowed(self, game, index, p, s) then return false end
    local slot, why = assign(p, s, index, c)
    if not slot then return false end
    local okC, err = hooks.call(hooks.battle(), "chooseOpeningSlot", slot.slot, index)
    if okC ~= true then record(s, { event = "refused", slot = slot.slot, index = index, error = err }); return false end
    local t = { slot = slot.slot, battler = slot.battler, index = index, hand = c and c.hand, by = why,
      at = now(), mon = game.save.party[index] }
    s.rseThrows[slot.slot] = t
    s.mon, s.index = t.mon, index
    record(s, { event = "choose", slot = t.slot, battler = t.battler, index = index, hand = t.hand, by = why })
    if c then c.rseSlot, c.rseBattler, c.openingBattler = t.slot, t.battler, t.battler end
    return true
  end
  local function releaseOne(self, s, t, mode)
    local okR, err = hooks.call(hooks.battle(), "releaseOpeningSlot", t.slot, opts())
    if okR ~= true then
      record(s, { event = "release failed", slot = t.slot, error = err })
      self:abort("opening slot release unavailable")
      return
    end
    s.rseThrows[t.slot] = nil
    record(s, { event = "release", slot = t.slot, index = t.index, mode = mode })
    local p = pending(self)
    if not p then done(self, s, "thrown", mode); return end
    sync(s, p)
    s.rsePrompt = nil
    show(s, p)
  end
  local function releasePair(self, s, a, b)
    local first, second = a.slot == 1 and a or b, a.slot == 1 and b or a
    local B = hooks.battle()
    local okP, err = hooks.call(B, "chooseOpeningPair", first.index, second.index)
    if okP ~= true or type(B and B.releaseOpening) ~= "function" then
      -- cannot make it one joint send-out: release each slot (the engine plays them one after the other)
      record(s, { event = "pair fallback", error = err })
      releaseOne(self, s, first, "split")
      if s.phase == "waiting" and s.rseThrows[second.slot] then releaseOne(self, s, second, "split") end
      return
    end
    local okR, errR = hooks.call(B, "releaseOpening", opts())
    if okR ~= true then
      record(s, { event = "release failed", error = errR })
      self:abort("opening release unavailable")
      return
    end
    s.rseThrows = {}
    record(s, { event = "release pair", slots = { first.index, second.index } })
    local p = pending(self)
    if not p then done(self, s, "thrown", "pair"); return end
    sync(s, p) -- not expected: releaseOpening ends a two-slot pause
  end
  -- Release whatever is due (called every update tick while the pause is live).
  local function resolve(self, p, s)
    local list = sortedThrows(s)
    if #list == 0 then return end
    local t = now()
    if #list >= 2 then
      if t - list[1].at >= M.APPEAR_DELAY and t - list[#list].at >= M.PAIR_SETTLE then releasePair(self, s, list[1], list[2]) end
      return
    end
    local one = list[1]
    local wait = #freeSlots(p, s) > 0 and math.max(M.PAIR_WINDOW, M.APPEAR_DELAY) or M.APPEAR_DELAY
    if t - one.at >= wait then releaseOne(self, s, one, #freeSlots(p, s) > 0 and "split" or "last") end
  end

  cy.canGrab = function(self, game, index)
    local p, s = pending(self)
    if not p then return base.canGrab(self, game, index) end
    sync(s, p)
    if not self:inBattle(game) then return true end
    return allowed(self, game, index, p, s)
  end
  cy.highlight = function(self, game, index)
    local p, s = pending(self)
    if not p then return base.highlight(self, game, index) end
    sync(s, p)
    if not allowed(self, game, index, p, s) then return false end
    for _, slot in ipairs(freeSlots(p, s)) do
      if index == (p.fixedOrder and slot.default or slot.index) then return true end
    end
    return false
  end
  cy.select = function(self, game, index)
    local p = pending(self)
    if not p then return base.select(self, game, index) end
    return throw(self, game, index, nil)
  end
  -- The shared belt's in-battle commit (PartyFollower.commit -> V.chooseYou:commit), with the command itself so
  -- the slot can follow the throwing hand and its aim.
  cy.commit = function(self, game, c)
    local p = pending(self)
    if not p then return base.commit(self, game, c) end
    if type(c) ~= "table" or c.kind ~= "deploy" or c.context ~= (game.overworld and game.overworld.map)
        or game.save.party[c.index] ~= c.mon then
      return false, "opening_only"
    end
    if not throw(self, game, c.index, c) then return false, "opening_selection_rejected" end
    c.opening = true
    return true, "opening_selected"
  end
  -- Releases are clock-driven (resolve); a belt FX completion callback changes nothing.
  cy.complete = function(self)
    local s = self.state
    if not (s and s.rseDouble) then return base.complete(self) end
  end
  cy.update = function(self, game, dt)
    base.update(self, game, dt)
    local p, s = pending(self)
    if not p then
      -- the engine let go by itself (timeout, lapse, reset) or an abort/clear released the rest
      local st = self.state
      if st and st.rseDouble and st.phase == "complete" then note(st, st.reason, "engine") end
      return
    end
    if not capable(p) then self:abort("opening slot API unavailable"); return end
    if s.phase ~= "waiting" then return end
    sync(s, p)
    resolve(self, p, s)
    p, s = pending(self)
    if p and s.phase == "waiting" then show(s, p) end
  end

  -- The throwing hand rides on the belt command. PartyBelt.release clears slot.hand; keep it as rseHand until the
  -- deploy request is queued. Emerald only (this install), Gen1/Gen2/FireRed never see these wrappers.
  local beltUndo
  do
    local okBelt, Belt = pcall(V.require, "PartyBelt")
    if okBelt and type(Belt) == "table" and type(Belt.release) == "function" and type(Belt.request) == "function" then
      local origRelease, origRequest = Belt.release, Belt.request
      local wrappedRelease = function(self, h)
        local i = self.hands and self.hands[h]
        local index = origRelease(self, h)
        local slot = index and i and self.slots and self.slots[i]
        if slot then slot.rseHand = h end
        return index
      end
      local wrappedRequest = function(self, kind, index, target)
        local id, why = origRequest(self, kind, index, target)
        if id and kind == "deploy" then
          local c, slot = self.queue and self.queue[#self.queue], self.slots and self.slots[index]
          if c and c.id == id and slot then c.hand = slot.rseHand end
        end
        return id, why
      end
      Belt.release, Belt.request = wrappedRelease, wrappedRequest
      beltUndo = function()
        if Belt.release == wrappedRelease then Belt.release = origRelease end
        if Belt.request == wrappedRequest then Belt.request = origRequest end
      end
    end
  end

  return true, function()
    if beltUndo then beltUndo() end
    if rawget(cy, "commit") ~= hadCommit then rawset(cy, "commit", hadCommit) end
  end
end

return M
