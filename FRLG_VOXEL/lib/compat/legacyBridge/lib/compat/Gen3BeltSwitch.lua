-- VRITK_FRLG_HOST compat (Gen3 only: FireRed/LeafGreen and Emerald, singles and Emerald doubles): BELT SWITCH.
--
-- belt-switch (2026-10-02, user, Lab 10): "I want you to have to recall your Pokemon to your party belt and
-- physically switch in new Pokemon from your belt if you choose that in the battle menu. The same red circle
-- tells you what ball to select." VR CONTROLS > BELT SWITCH (FRLG_VOXEL option belt_switch, default ON).
--
-- The engine decides everything: who switches, when, Pursuit, entry effects, the party order. Only the
-- presentation waits for the player's hands. The engine's switch presentation is a step list in
-- src/core/game3/battle/switch_seq.lua (msg "X, come back!" -> withdraw -> swap_data -> msg_sendout "Go! Y!" ->
-- sendout_player -> cry -> healthbox -> entry effects). There is no engine hold for it (unlike the opening's
-- claimOpening/releaseOpening), so this module adds two from outside, with no engine edit:
--   * it wraps SwitchSeq.beginPlayerSwitch / beginShiftSwitch / beginSendOut (player) / beginDoubleSwitch
--     (player battlers) and, after the engine has built its steps, inserts a hold step before `withdraw`
--     (voluntary switches only) and one before the player's `msg_sendout` (every player switch-in, forced
--     ones after a faint included);
--   * a hold step is the engine's own `mon_anim_wait` with a key no battler has; it waits while
--     MonAnimBattle.busy(key) answers true, and that one function is wrapped here to answer for our keys only
--     (any other key goes to the original). If this module is gone the original answers false for an unknown
--     key and the battle simply goes on: a hold can never outlive us.
-- RECALL hold: the outgoing Pokemon's belt ball carries the red ring; grab it, point it at your Pokemon, hold
--   the trigger (Gen3RecallAim). The user's red recall beam runs from the battler into the ball
--   (OpeningBeamFX recall beam; FRLG_VOXEL BattlePass shrinks the picture into it), and when it ends the hold
--   lets go with the engine's withdraw step swapped for a silent hide (no 2D shrink, no ball sound).
-- THROW hold: after the engine has swapped the battler, the incoming Pokemon's ball carries the red ring;
--   throw it like an opening ball. The accepted throw starts the user's send-out beam to that battler spot
--   (OpeningBeamFX, the same path as the opening) and APPEAR_DELAY s later the hold lets go with the engine's
--   sendout_player step swapped for a silent appear (no 2D ball, ball sounds or ball-open burst); "Go! Y!",
--   the cry, the healthbox and the entry effects stay the engine's.
-- Never a soft-lock: each hold lets go with the engine's own presentation (native withdraw / send-out) after
-- WAIT_SEC, when B is held for SKIP_HOLD_SEC, when skip() is called (a tablet button can bind it), when the VR
-- belt stops being usable (no hands for 10 s, the option turned off), and when this module stops renewing its
-- lease (LEASE_SEC). A hold is only inserted when the belt is usable at that moment.
-- BELT SWITCH OFF (or no adopted VR opening in this battle): nothing is inserted; today's behaviour exactly.
-- Mod sandbox: no package, no debug. Engine tables are wrapped once (rawset markers), restored on uninstall.
-- Review fixes (2026-10-02): holds only when FRLG_VOXEL's 3D battle is seated with a spot for that battler (the
-- recall aims at it); never for a link/spectated battle or an AI partner's battler (multi / partner battles);
-- B skips only when pressed fresh during a recall/throw hold; a finished switch clears its prompt; uninstall puts
-- back any step it had swapped and shows a battler it had hidden.
local Host = ...
local S = {}
S.ENABLED = true          -- module switch (the user's switch is VR CONTROLS > BELT SWITCH)
S.WAIT_SEC = 30           -- s a hold waits for the player before the engine's own presentation plays
S.HINT_AFTER = 8          -- s before the prompt adds the skip hint
S.SKIP_HOLD_SEC = 1.0     -- B held this long skips the physical switch (engine presentation)
S.LEASE_SEC = 2           -- s without update() before a hold lets go
S.APPEAR_DELAY = 0.3      -- s: accepted throw -> release (Gen3ChooseYouCompat.APPEAR_DELAY)
S.RECALL_SEC = 1.555      -- the user's recall beam (release_energy RECALL_DURATION; read at install)
S.PROMPT_RECALL = "Recall your POK\195\169MON!\nAim its BALL + TRIGGER"
S.PROMPT_THROW = "Send it out! Throw\nthe marked BALL!"
S.HINT = "\n(hold B to skip)"
S.last = nil              -- the last finished switch (plain data, driver/diagnostics)

local live = nil          -- the hold record of the switch being presented
local sentinels = {}      -- hide/appear step keys -> their record (they run after the hold has let go)
local serial = 0
local stats = { inserted = 0, notReady = 0, recalls = 0, throws = 0, physical = 0, fallback = 0, skipped = 0 }
local installed = nil

local function clock() return love and love.timer and love.timer.getTime and love.timer.getTime() or os.clock() end

-- ------------------------------------------------------------ helpers over the engine's present/stage tables
local function present(Anim, State, d)
  if type(d) ~= "table" then return nil end
  if d.id == nil then return Anim.present(d.side or "player") end
  return Anim.present(d.id) or (d.id < 2 and Anim.present(State.sideOf(d.id))) or nil
end
local function healthbox(Anim, State, d)
  local s = Anim.stage and Anim.stage()
  local hb = s and s.healthbox
  if not (hb and type(d) == "table") then return nil end
  if d.id == nil then return hb[d.side or "player"] end
  return hb[d.id] or (d.id < 2 and hb[State.sideOf(d.id)]) or nil
end

local function find(steps, kind, pred)
  for i, step in ipairs(steps or {}) do
    if step.kind == kind and (not pred or pred(step.data or {})) then return i, step end
  end
end
local function playerStep(d) return d.side == "player" or (d.id ~= nil and d.id % 2 == 0) or (d.side == nil and d.id == nil) end

local function finishRecord(h, why)
  if not h or h.finished then return end
  h.finished = why
  if h.prompted and installed and installed.prompt then installed.prompt(nil); h.prompted = false end
  S.last = { serial = h.serial, id = h.id, from = h.from, to = h.to, forced = h.forced, reason = h.reason,
    physicalRecall = h.physicalW, physicalThrow = h.physicalS, fallback = h.fallback, finished = why,
    recallAt = h.recallAt and h.recallAt - h.startedAt, throwAt = h.throwAt and h.throwAt - h.startedAt,
    log = h.log }
  if live == h then live = nil end
end
local function note(h, event)
  h.log = h.log or {}
  event.t = clock() - h.startedAt
  h.log[#h.log + 1] = event
end

-- ------------------------------------------------------------ install
--- ctx = Gen3ChooseYouCompat's ctx (V, require, log); deps = { prompt = fn(V, text, seconds),
--- ready = fn() -> the VR belt owns this battle now, optionOn = fn() -> BELT SWITCH, controls = fn() -> snapshot }
function S.install(ctx, deps)
  if installed then S.uninstall() end
  deps = deps or {}
  local req = ctx.require or require
  local okS, SwitchSeq = pcall(req, "src.core.game3.battle.switch_seq")
  local okM, MonAnim = pcall(req, "src.core.game3.battle.mon_anim_battle")
  local okA, Anim = pcall(req, "src.core.game3.battle.anim")
  local okT, State = pcall(req, "src.core.game3.battle.state")
  if not (okS and type(SwitchSeq) == "table" and okM and type(MonAnim) == "table" and type(MonAnim.busy) == "function"
      and okA and type(Anim) == "table" and type(Anim.present) == "function" and okT and type(State) == "table") then
    return false, "engine switch modules unavailable"
  end
  do
    local okE, Energy = pcall(ctx.V.require, "catching/release_energy")
    if okE and type(Energy) == "table" and tonumber(Energy.RECALL_DURATION) then S.RECALL_SEC = Energy.RECALL_DURATION end
  end
  local V = ctx.V
  local inst = { ctx = ctx, deps = deps, SwitchSeq = SwitchSeq, MonAnim = MonAnim, Anim = Anim, State = State, orig = {} }
  local function prompt(text, seconds) if deps.prompt then pcall(deps.prompt, V, text, seconds) end end
  inst.prompt = prompt

  local function partyIndexOf(game, mon)
    local party = game and game.save and game.save.party
    for i, m in ipairs(party or {}) do if m == mon then return i end end
  end
  inst.partyIndexOf = partyIndexOf

  local function ready()
    if not S.ENABLED then return false end
    if deps.optionOn then local ok, on = pcall(deps.optionOn); if ok and on == false then return false end end
    if deps.ready then
      local ok, on, why = pcall(deps.ready)
      if ok and on == true then return true end
      stats.notReadyWhy = ok and tostring(why) or ("error: " .. tostring(on))
      return false
    end
    return false
  end
  inst.ready = ready

  -- A switch presentation the engine just built: add our holds.
  local function spotsOf()
    local okB, Beams = pcall(function() return Host and Host.require("compat/OpeningBeamFX") end)
    if not (okB and type(Beams) == "table" and type(Beams.spots) == "function") then return nil end
    local okS, spots = pcall(Beams.spots, ctx.V)
    return okS and type(spots) == "table" and spots or nil
  end
  local function skipWhy(pre)
    local st = pre.st
    if type(st) ~= "table" then return "no battle state" end
    if st.link or st.spectate then return "link or spectated battle" end
    -- an AI partner's battler (Emerald multi / partner battles): its balls are not on the player's belt
    if pre.id ~= 0 and (st.multi or st.playerHalf) then return "partner battler" end
    local spots = spotsOf()
    if not (spots and spots[pre.id]) then return "no seated 3D battle spot for battler " .. tostring(pre.id) end
    return nil
  end
  local function begin(pre)
    if not ready() then stats.notReady = stats.notReady + 1; return end
    local why = skipWhy(pre)
    if why then stats.notReady = stats.notReady + 1; stats.notReadyWhy = why; return end
    local steps = SwitchSeq._steps
    if type(steps) ~= "table" then return end
    local st = pre.st
    local party = st and st.playerParty
    -- the battle's party is a per-slot copy of the saved party in the same order (PartyView.fromSession), so
    -- the belt's ball for battle party slot i is belt slot i
    if not (party and pre.to and party[pre.to]) then return end
    local fromMon, toMon = pre.from and party[pre.from], party[pre.to]
    serial = serial + 1
    local h = { serial = serial, id = pre.id, from = pre.from, to = pre.to, fromMon = fromMon, toMon = toMon,
      forced = not pre.voluntary, reason = pre.reason, phase = "pending", startedAt = clock(), renewAt = clock(),
      usable = true, entity = { beltSwitch = serial, battler = pre.id } }
    h.keyW, h.keyS = "__vrbelt_W" .. serial, "__vrbelt_S" .. serial
    h.keyHide, h.keyAppear = "__vrbelt_H" .. serial, "__vrbelt_A" .. serial
    if pre.voluntary then
      local iW, W = find(steps, "withdraw", playerStep)
      if iW then
        h.W, h.wData = W, W.data
        table.insert(steps, iW, { kind = "mon_anim_wait", data = { ids = { h.keyW } } })
      end
    end
    local iS = find(steps, "msg_sendout", playerStep)
    local _, P = find(steps, "sendout_player")
    if iS and P then
      h.P, h.pData = P, P.data
      table.insert(steps, iS, { kind = "mon_anim_wait", data = { ids = { h.keyS } } })
    end
    if not (h.W or h.P) then return end
    if live then finishRecord(live, "superseded") end
    sentinels = {} -- a new engine sequence replaced any older steps
    live = h
    stats.inserted = stats.inserted + 1
    note(h, { event = "inserted", recall = h.W ~= nil, throw = h.P ~= nil, id = h.id, from = h.from, to = h.to })
  end

  local function wrapBegin(name, info)
    local key = "__vrbeltOrig_" .. name
    local orig = rawget(SwitchSeq, key) or SwitchSeq[name]
    if type(orig) ~= "function" then return end
    rawset(SwitchSeq, key, orig)
    local wrapped = function(st, ...)
      local okI, pre = pcall(info, st, ...)
      local r = orig(st, ...)
      if r == true and okI and pre then
        pre.st = st
        local okB, err = pcall(begin, pre)
        if not okB and ctx.log then ctx.log("belt switch hold failed: " .. tostring(err)) end
      end
      return r
    end
    SwitchSeq[name] = wrapped
    inst.orig[name] = { orig = orig, wrapped = wrapped, key = key }
  end
  local function battlerOf(st, id) return State.battler(st, id) end
  -- singles: the player's battler is 0
  wrapBegin("beginPlayerSwitch", function(st, newSlot, opts)
    if opts and opts.headless then return nil end
    local b = st and st.player
    return { id = 0, from = b and b.partyIndex, fromMon = b and b.mon, to = newSlot, voluntary = true, reason = "switch" }
  end)
  wrapBegin("beginShiftSwitch", function(st, playerSlot, enemySlot, opts)
    if opts and opts.headless then return nil end
    local b = st and st.player
    return { id = 0, from = b and b.partyIndex, fromMon = b and b.mon, to = playerSlot, voluntary = true, reason = "shift" }
  end)
  wrapBegin("beginSendOut", function(st, side, newSlot, opts)
    if (side or "player") ~= "player" or (opts and opts.headless) then return nil end
    local b = st and st.player
    return { id = 0, from = b and b.partyIndex, fromMon = b and b.mon, to = newSlot, voluntary = false, reason = "replace" }
  end)
  wrapBegin("beginDoubleSwitch", function(st, id, newSlot, opts)
    opts = opts or {}
    if opts.headless or type(id) ~= "number" or State.sideOf(id) ~= "player" then return nil end
    local b = battlerOf(st, id)
    return { id = id, from = b and b.partyIndex, fromMon = b and b.mon, to = newSlot, voluntary = opts.withdraw == true,
      reason = opts.reason or (opts.withdraw and "switch" or "replace") }
  end)

  -- ---------------------------------------------------------- the holds
  local function enter(h, phase, now)
    h.phase, h.phaseAt, h.hinted = phase, now, false
    if phase == "throw" then
      -- the new battler stays out of sight until the user's beam grows it in
      local p = h.pData and present(Anim, State, h.pData)
      if p then p.visible = false; h.hidThrow = true end
      if h.fallback then return end
    end
    note(h, { event = "phase", phase = phase })
    if phase == "recall" and h.recallAt then return end
    prompt(phase == "recall" and S.PROMPT_RECALL or S.PROMPT_THROW, S.WAIT_SEC)
    h.prompted = true
  end
  local function fallbackWhy(h, now)
    if h.skip then return h.skip end
    if not S.ENABLED then return "disabled" end
    if now - (h.renewAt or now) > S.LEASE_SEC then return "lapsed" end
    if not h.usable then return "belt unusable" end
    if now - h.phaseAt > S.WAIT_SEC then return "timeout" end
    return nil
  end
  local function release(h, phase, physical, why)
    if h.prompted then prompt(nil); h.prompted = false end
    if phase == "recall" then
      h.physicalW = physical
      if physical and h.W then
        h.W.kind, h.W.data = "mon_anim_wait", { ids = { h.keyHide } }
        sentinels[h.keyHide] = h
      end
    else
      h.physicalS = physical
      if physical and h.P then
        h.P.kind, h.P.data = "mon_anim_wait", { ids = { h.keyAppear } }
        sentinels[h.keyAppear] = h
      end
    end
    if physical then stats.physical = stats.physical + 1
    else
      stats.fallback = stats.fallback + 1
      h.fallback = h.fallback or why
    end
    note(h, { event = "release", phase = phase, physical = physical, why = why })
    if phase == "throw" or not h.P then finishRecord(h, physical and "physical" or ("fallback: " .. tostring(why))) end
  end
  -- the user's recall beam for battler `id` is still drawing (Gen3PartyActionFX.battleVisuals: live = true)
  local function recallBeamLive(id)
    local okF, FX = pcall(function() return Host and Host.require("compat/Gen3PartyActionFX") end)
    if not (okF and type(FX) == "table" and type(FX.battleVisuals) == "function") then return false end
    local okV, list = pcall(FX.battleVisuals)
    for _, b in ipairs(okV and type(list) == "table" and list or {}) do
      if b.live and b.kind == "recall" and b.battler == id then return true end
    end
    return false
  end
  local function hold(h, phase)
    local now = clock()
    if h.phase ~= phase then enter(h, phase, now) end
    if phase == "recall" then
      if h.recallDoneAt then
        -- let go once the beam has really finished (its clock runs on frame time), at most 2 s late
        if now >= h.recallDoneAt and (not recallBeamLive(h.id) or now >= h.recallDoneAt + 2) then
          release(h, phase, true, "recalled"); return false
        end
        return true
      end
    else
      if h.fallback then release(h, phase, false, h.fallback); return false end
      if h.appearAt then
        if now >= h.appearAt then release(h, phase, true, "thrown"); return false end
        return true
      end
    end
    local why = fallbackWhy(h, now)
    if why then release(h, phase, false, why); return false end
    if not h.hinted and now - h.phaseAt > S.HINT_AFTER then
      h.hinted = true
      prompt((phase == "recall" and S.PROMPT_RECALL or S.PROMPT_THROW) .. S.HINT, S.WAIT_SEC)
      h.prompted = true
    end
    return true
  end
  local function hide(h)
    local p = present(Anim, State, h.wData)
    if p then p.visible = false; p.scale = 1 end
    local hb = healthbox(Anim, State, h.wData)
    if hb then hb.visible = false end
    note(h, { event = "hidden" })
  end
  local function appear(h)
    h.appeared = true
    local p = present(Anim, State, h.pData)
    if p then p.visible, p.ox, p.oy, p.scale, p.darken = true, 0, 0, 1, 0 end
    local s = Anim.stage and Anim.stage()
    if s and s.ball then s.ball.visible = false end
    note(h, { event = "appeared" })
  end
  local origBusy = rawget(MonAnim, "__vrbeltOrig_busy") or MonAnim.busy
  rawset(MonAnim, "__vrbeltOrig_busy", origBusy)
  local busy = function(keys)
    if type(keys) == "table" then
      for _, key in ipairs(keys) do
        if type(key) == "string" and key:sub(1, 8) == "__vrbelt" then
          local done = sentinels[key]
          if done then
            sentinels[key] = nil
            if key == done.keyHide then hide(done) else appear(done) end
            return false
          end
          local h = live
          if h and key == h.keyW then return hold(h, "recall") end
          if h and key == h.keyS then return hold(h, "throw") end
          return false -- a hold of a switch that is no longer ours: never block
        end
      end
    end
    return origBusy(keys)
  end
  MonAnim.busy = busy
  inst.busy, inst.origBusy = busy, origBusy
  -- uninstall: a hide/appear step that was swapped in but has not run yet is done now (the original busy() would
  -- just skip it, leaving a recalled battler on screen or a thrown one invisible)
  inst.restoreSteps = function()
    local pending = sentinels
    sentinels = {}
    for key, r in pairs(pending) do
      if key == r.keyHide then pcall(hide, r) elseif key == r.keyAppear then pcall(appear, r) end
    end
  end
  installed = inst
  return true, function() S.uninstall() end
end

function S.uninstall()
  local inst = installed
  if not inst then return false end
  for name, w in pairs(inst.orig) do
    if inst.SwitchSeq[name] == w.wrapped then inst.SwitchSeq[name] = w.orig end
  end
  if inst.MonAnim.busy == inst.busy then inst.MonAnim.busy = inst.origBusy end
  if inst.restoreSteps then pcall(inst.restoreSteps) end
  if live then finishRecord(live, "uninstalled") end
  installed = nil
  return true
end

-- ------------------------------------------------------------ the belt's view (Gen3ChooseYouCompat delegates)
--- The live hold record or nil (plain reads only).
function S.active() return live end

local function phaseOf(h)
  if not h or h.finished then return nil end
  if (h.phase == "pending" or h.phase == "recall") and h.W and not h.recallAt and h.physicalW == nil then
    return "recall"
  end
  if h.phase == "throw" and not h.throwAt and not h.fallback then return "throw" end
  return "busy"
end
local function sameSlot(game, index, slotIndex)
  local party = game and game.save and game.save.party
  return slotIndex ~= nil and index == slotIndex and party ~= nil and party[index] ~= nil
end

--- nil = not ours (no switch in progress); else whether the belt may give out party ball `index`.
function S.canGrab(game, index)
  local h = live
  local ph = phaseOf(h)
  if not ph then return nil end
  if ph == "recall" then return sameSlot(game, index, h.from) end
  if ph == "throw" then return sameSlot(game, index, h.to) end
  return false
end
--- nil = not ours; else whether ball `index` wears the red ring.
function S.highlight(game, index)
  local h = live
  local ph = phaseOf(h)
  if not ph then return nil end
  if ph == "recall" then return sameSlot(game, index, h.from) end
  if ph == "throw" then return sameSlot(game, index, h.to) end
  return false
end
--- The battler proxy a recall aims at (only during the recall part, only for the outgoing Pokemon).
function S.entity(game, mon)
  local h = live
  local party = game and game.save and game.save.party
  if phaseOf(h) == "recall" and mon ~= nil and party and party[h.from] == mon then return h.entity end
  return nil
end
--- World px aim point {x, y, z, w, h} of our proxy (the battler spot of FRLG_VOXEL's 3D battle), or nil.
function S.target(entity)
  local h = live
  if not (h and entity == h.entity and installed) then return nil end
  local okB, Beams = pcall(function() return Host and Host.require("compat/OpeningBeamFX") end)
  local spots = okB and type(Beams) == "table" and Beams.spots(installed.ctx.V) or nil
  local sp = spots and spots[h.id]
  if not sp then return nil end
  return { x = sp.center[1], y = sp.center[2], z = sp.center[3], w = sp.width, h = sp.height }
end

--- The belt's commit in a battle (PartyFollower.commit -> V.chooseYou:commit). nil = not ours.
function S.commit(game, c)
  local h = live
  if not (h and type(c) == "table") then return nil end
  local ph = phaseOf(h)
  if not ph then return nil end
  if c.kind == "recall" then
    if ph ~= "recall" then return false, "switch_not_recalling" end
    if c.index ~= h.from then return false, "switch_wrong_ball" end
    local now = clock()
    h.recallAt, h.recallDoneAt = now, now + S.RECALL_SEC
    c.switchRecall, c.recallBattler = true, h.id
    stats.recalls = stats.recalls + 1
    if h.prompted and installed then installed.prompt(nil); h.prompted = false end
    note(h, { event = "recall accepted", index = c.index })
    return true, "switch_recalled"
  elseif c.kind == "deploy" then
    if ph ~= "throw" then return false, "switch_not_throwing" end
    if c.index ~= h.to then return false, "switch_wrong_ball" end
    local now = clock()
    h.throwAt, h.appearAt = now, now + S.APPEAR_DELAY
    c.opening, c.openingBattler, c.switchSendOut = true, h.id, true
    stats.throws = stats.throws + 1
    if h.prompted and installed then installed.prompt(nil); h.prompted = false end
    note(h, { event = "throw accepted", index = c.index })
    return true, "switch_thrown"
  end
  return nil
end

--- Every input.step (Gen3ChooseYouCompat.update): renew the lease, read the belt state and the B skip.
function S.update(game, dt, on)
  local h = live
  if not (h and installed) then return end
  local SwitchSeq = installed.SwitchSeq
  if not SwitchSeq._steps then finishRecord(h, "sequence ended"); return end
  local now = clock()
  h.renewAt = now
  h.usable = on == true and installed.ready()
  local deps = installed.deps
  local controls = deps.controls and (function() local ok, c = pcall(deps.controls); return ok and c or nil end)()
  local down = controls ~= nil and controls.b == true
  local holding = not h.finished and (h.phase == "recall" or h.phase == "throw")
  if holding and h.bPhase ~= h.phase then
    -- a B already down when the hold starts (text skipping, a menu) must be let go first
    h.bPhase, h.bArmed, h.bSince, h.bHeld = h.phase, not down, nil, 0
  end
  if holding and down and h.bArmed then
    h.bSince = h.bSince or now
    h.bHeld = now - h.bSince
    if h.bHeld >= S.SKIP_HOLD_SEC and not h.skip then
      h.skip = "b held"
      stats.skipped = stats.skipped + 1
      note(h, { event = "skip", why = "b held" })
    end
  else
    if holding and not down then h.bArmed = true end
    h.bHeld, h.bSince = 0, nil
  end
end

--- Skip the physical switch for the switch in progress (a tablet button may call this). true when one was live.
function S.skip(reason)
  local h = live
  if not h or h.finished then return false end
  h.skip = tostring(reason or "skip")
  stats.skipped = stats.skipped + 1
  if installed then note(h, { event = "skip", why = h.skip }) end
  return true
end

function S.status()
  local out = {}
  for k, v in pairs(stats) do out[k] = v end
  out.installed = installed ~= nil
  local h = live
  if h then
    out.live = { serial = h.serial, id = h.id, from = h.from, to = h.to, forced = h.forced, phase = h.phase,
      belt = phaseOf(h), recallAt = h.recallAt, throwAt = h.throwAt, fallback = h.fallback }
  end
  out.last = S.last
  return out
end

return S
