-- VRITK_FRLG_HOST compat (Gen3: FireRed/LeafGreen and Emerald battle openings, singles and Emerald doubles): the
-- user's own send-out energy beam for a battle-opening belt throw, one beam per player battler (vr-doubles,
-- 2026-10-01; singles added the same day).
--
-- battle-ui (2026-10-01), user rule: "stop relying on the game's visual pokeball effects and only use mine for
-- the visuals; trying to blend them is causing timing issues." The opening send-out is the user's only: the
-- VRITK release beam (catching/release_energy pose + catching/capture_plasma volume + catching/capture_material,
-- unchanged look, colours and timing) from the thrown ball to the battler's spot, on its own clock, and the
-- battler's picture growing in as the user's white silhouette (drawn by FRLG_VOXEL's BattlePass from this
-- module's beams: Gen3PartyActionFX.battleVisuals). The engine's release is physical (Gen3ChooseYouCompat /
-- EmeraldChooseYouCompat PHYSICAL): no native ball, burst, ball sounds or throw pose; its "Go!" line and cry stay.
--   reach : the beam grows from the ball to the spot (release pose 0 .. GROW_SEC - 0.15 s);
--   fade  : the release pose's own connector fade (0.30 s) runs straight after, as the picture finishes growing.
-- WAIT_FOR_NATIVE = true restores the old hold (connected until the engine's picture appears, MAX_HOLD s).
-- Each beam owns its geometry and mesh, so two beams (one per hand) draw at the same time without sharing state;
-- NativeBallFX's module caches (ROM sheets, the blend shader) are read-only and are not used here at all.
-- Nothing here touches game state; a failed draw only ends that beam.
-- belt-switch (2026-10-02, BELT SWITCH): the same list also carries RECALL beams (kind "recall", startRecall): the
-- user's red recall energy (release_energy's "recall" pose, its own 1.555 s clock) from the battler spot into the
-- held ball, following the ball's mouth while it moves (B.mouth). battleVisuals reports kind and recallSec so
-- FRLG_VOXEL's BattlePass shrinks the battler's picture into the beam instead of growing it.
local Host = ...
local B = {}
B.PX = 16               -- world px per cell (VRITK / FRLG_CATCH / BattleThrow.PX)
B.PIC_PX_PER_CELL = 56  -- FRLG_VOXEL BattleCards.PIC_PX_PER_CELL
B.FRAME_PX = 64         -- a battler picture's frame (GBA px); its centre sits half a frame above the ground
B.ARRIVE_LEAD = 0.15    -- NativeBallFX.COMBINED_DEPLOY_ARRIVE_LEAD: the connector fade starts here
B.FADE_SEC = 0.30       -- release_energy: fade = 1 - ease((t - (GROW_SEC - .15)) / .30)
B.WAIT_FOR_NATIVE = false -- battle-ui: the user's own timing; true = hold until the engine's mon appears
B.MAX_HOLD = 5.0        -- s the beam waits for the native mon before fading anyway (desktop run: the joint
                        -- "Go! A and B!" line + ball flight put the native open ~2.5 s after the release)
B.MAX_AGE = 9           -- s hard cap per beam
B.LOST_SEC = 1.0        -- s without a battler spot before a beam is dropped
local IDENT = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }

-- FRLG_VOXEL's vrHost.battle table, looked up once per V (mod.find allocates on every call). A failing or
-- non-table state() answer drops the cache, so a mod reload rebinds on the next call.
local battleCache = setmetatable({}, { __mode = "k" })
local function battleApi(V)
  local hit = battleCache[V]
  if hit then return hit end
  local finder = V and V.mod and V.mod.find
  if type(finder) ~= "function" then return nil end
  local okF, fv = pcall(finder, "FRLG_VOXEL")
  local vh = okF and fv and fv.exports and fv.exports.vrHost
  local battle = vh and vh.battle
  if not (battle and type(battle.state) == "function") then return nil end
  battleCache[V] = battle
  return battle
end
B._battleCache = battleCache

-- Player/foe battler spots of the live 3D battle, from FRLG_VOXEL's vrHost.battle.state() (plain data).
-- Returns { [battlerId] = { center = {x,y,z} world px, width, height (px), drawn } } or nil.
function B.spots(V)
  if type(V) ~= "table" then return nil end
  local battle = battleApi(V)
  if not battle then return nil end
  local okS, st = pcall(battle.state)
  if not (okS and type(st) == "table") then battleCache[V] = nil; return nil end
  if type(st.cards) ~= "table" then return nil end
  if st.state ~= "seated" and st.state ~= "fadein" then return nil end
  local out, any = {}, false
  local size = B.FRAME_PX / B.PIC_PX_PER_CELL
  for _, c in ipairs(st.cards) do
    if c.kind == "battler" and type(c.id) == "number" and tonumber(c.x) and tonumber(c.z) then
      local base = tonumber(c.base) or 0
      out[c.id] = { center = { c.x * B.PX, (base + size / 2) * B.PX, c.z * B.PX },
        width = size * B.PX, height = size * B.PX, drawn = c.drawn == true }
      any = true
    end
  end
  return any and out or nil
end

local function release(object)
  if object and type(object.release) == "function" then pcall(object.release, object) end
end

-- A new list holder (one per PartyActionFX instance).
function B.newList() return { beams = {}, recent = {}, stats = { started = 0, held = 0, appeared = 0, completed = 0,
  failed = 0, dropped = 0, draws = 0 } } end
B.RECENT_SEC = 3.0      -- s a finished beam stays in battleVisuals (FRLG_VOXEL latches it on the first report)
local serials = 0

-- Start (or restart) the beam for one battler. c = the accepted belt command (c.openingBattler or c.rseBattler,
-- c.target.origin).
function B.start(list, c, deps, V)
  if not (list and c and deps and deps.pose and deps.Plasma and deps.Material) then return false, "deps" end
  local battler = tonumber(c.openingBattler or c.rseBattler)
  local origin = c.target and (c.target.mouth or c.target.origin or (c.target.ray and c.target.ray.origin))
  if not (battler and type(origin) == "table" and tonumber(origin[1]) and tonumber(origin[2]) and tonumber(origin[3])) then
    return false, "no origin"
  end
  for i = #list.beams, 1, -1 do
    local old = list.beams[i]
    if old.battler == battler then B.clearBeam(old, "superseded"); table.remove(list.beams, i) end
  end
  local spots = B.spots(V)
  local spot = spots and spots[battler]
  local holdAt = (deps.growSec or 1.0) - B.ARRIVE_LEAD
  serials = serials + 1
  local beam = { serial = serials, battler = battler, slot = c.rseSlot, index = c.index, hand = c.hand,
    mouth = { origin[1], origin[2], origin[3] },
    age = 0, t = 0, holdAt = holdAt, endAt = holdAt + B.FADE_SEC, hold = 0, lost = 0,
    wasDrawn = spot and spot.drawn or nil, appeared = false, phase = "reach" }
  if spot then beam.center, beam.width, beam.height = spot.center, spot.width, spot.height end
  list.beams[#list.beams + 1] = beam
  list.stats.started = list.stats.started + 1
  return true
end

-- belt-switch: a recall beam for one battler. c = the accepted recall command (c.recallBattler, c.index,
-- c.target.mouth: the held ball's aperture, world px).
function B.startRecall(list, c, deps, V)
  if not (list and c and deps and deps.pose and deps.Plasma and deps.Material) then return false, "deps" end
  local battler = tonumber(c.recallBattler)
  local origin = c.target and (c.target.mouth or c.target.origin or (c.target.ray and c.target.ray.origin))
  if not (battler and type(origin) == "table" and tonumber(origin[1]) and tonumber(origin[2]) and tonumber(origin[3])) then
    return false, "no origin"
  end
  for i = #list.beams, 1, -1 do
    local old = list.beams[i]
    if old.battler == battler then B.clearBeam(old, "superseded"); table.remove(list.beams, i) end
  end
  local spots = B.spots(V)
  local spot = spots and spots[battler]
  local dur = tonumber(deps.recallDuration) or 1.555
  serials = serials + 1
  local beam = { serial = serials, battler = battler, index = c.index, kind = "recall", purpose = "recall",
    mouth = { origin[1], origin[2], origin[3] }, age = 0, t = 0, holdAt = dur, endAt = dur, hold = 0, lost = 0,
    wasDrawn = spot and spot.drawn or nil, appeared = false, phase = "recall" }
  if spot then beam.center, beam.width, beam.height = spot.center, spot.width, spot.height end
  list.beams[#list.beams + 1] = beam
  list.stats.started = list.stats.started + 1
  list.stats.recalls = (list.stats.recalls or 0) + 1
  return true
end

-- belt-switch: the held ball moved (PartyActionFX:mouth, every frame while a party ball is in hand).
function B.mouth(list, index, point)
  if not (list and type(point) == "table") then return end
  for _, beam in ipairs(list.beams) do
    if beam.kind == "recall" and beam.index == index then beam.mouth = { point[1], point[2], point[3] } end
  end
end

function B.clearBeam(beam, reason)
  release(beam.mesh)
  beam.mesh, beam.vertices, beam.indices, beam.key = nil, nil, nil, nil
  beam.done = reason or "complete"
end

function B.clear(list, reason)
  if not list then return end
  for _, beam in ipairs(list.beams) do B.clearBeam(beam, reason or "reset") end
  list.beams = {}
end

-- Advance once per prepared scene (never per eye).
function B.step(list, dt, V)
  if not list then return end
  dt = math.max(0, math.min(0.25, tonumber(dt) or 0))
  if #list.beams == 0 then
    for i = #(list.recent or {}), 1, -1 do
      local r = list.recent[i]
      r.age = r.age + dt
      if r.age > B.RECENT_SEC then table.remove(list.recent, i) end
    end
    return
  end
  local spots = B.spots(V)
  for i = #list.beams, 1, -1 do
    local beam = list.beams[i]
    beam.age = beam.age + dt
    beam.eye = nil -- one facing per prepared frame, the same in both eyes (taken at the first eye's draw)
    local spot = spots and spots[beam.battler]
    if spot then
      beam.center, beam.width, beam.height, beam.lost = spot.center, spot.width, spot.height, 0
      if beam.wasDrawn == nil then beam.wasDrawn = spot.drawn end
      -- the engine's mon became visible at this spot: the native ball has opened
      if spot.drawn and not beam.wasDrawn and not beam.appeared then
        beam.appeared = true
        list.stats.appeared = list.stats.appeared + 1
      end
      if not spot.drawn then beam.wasDrawn = false end
    else
      beam.lost = beam.lost + dt
    end
    if beam.kind == "recall" then
      beam.t = beam.t + dt
    elseif beam.t < beam.holdAt then
      beam.t = math.min(beam.holdAt, beam.t + dt)
    elseif B.WAIT_FOR_NATIVE and not beam.appeared and beam.hold < B.MAX_HOLD then
      if beam.phase ~= "hold" then beam.phase = "hold"; list.stats.held = list.stats.held + 1 end
      beam.hold = beam.hold + dt
    else
      beam.phase = "fade"
      beam.t = beam.t + dt
    end
    local reason
    if beam.t >= beam.endAt then reason = "complete"
    elseif beam.age >= B.MAX_AGE then reason = "max age"
    elseif beam.lost >= B.LOST_SEC then reason = "no battler spot" end
    if reason then
      if reason == "complete" then list.stats.completed = list.stats.completed + 1 else list.stats.dropped = list.stats.dropped + 1 end
      list.stats.last = { battler = beam.battler, reason = reason, age = beam.age, hold = beam.hold, appeared = beam.appeared }
      if list.recent then list.recent[#list.recent + 1] = { serial = beam.serial, battler = beam.battler, age = beam.age,
        kind = beam.kind } end
      B.clearBeam(beam, reason)
      table.remove(list.beams, i)
    end
  end
  for i = #(list.recent or {}), 1, -1 do
    local r = list.recent[i]
    r.age = r.age + dt
    if r.age > B.RECENT_SEC then table.remove(list.recent, i) end
  end
end

-- battle-ui: the beams FRLG_VOXEL's BattlePass draws the user's growing picture for. Appends plain records
-- { battler, serial, age, growSec, settleSec } to `out` (live beams and ones finished < RECENT_SEC ago).
function B.visuals(list, deps, out)
  out = out or {}
  if not list then return out end
  local grow = deps and tonumber(deps.growSec) or 1.0
  local settle = deps and tonumber(deps.settleSec) or 0.35
  local recallSec = deps and tonumber(deps.recallDuration) or 1.555
  for _, beam in ipairs(list.beams) do
    out[#out + 1] = { battler = beam.battler, serial = beam.serial, age = beam.age, growSec = grow, settleSec = settle,
      kind = beam.kind or "sendout", recallSec = recallSec, live = true }
  end
  for _, r in ipairs(list.recent or {}) do
    out[#out + 1] = { battler = r.battler, serial = r.serial, age = r.age, growSec = grow, settleSec = settle,
      kind = r.kind or "sendout", recallSec = recallSec }
  end
  return out
end

-- Draw every live beam (inside the eye pass; voxel = the shared Voxel3D stand-in with vp/eye set).
function B.draw(list, voxel, deps)
  if not (list and #list.beams > 0 and voxel and deps) then return end
  for i = #list.beams, 1, -1 do
    local beam = list.beams[i]
    local ok, err = true, nil
    if beam.center then
      ok, err = pcall(function()
        local eye = beam.eye or voxel.eye
        if not beam.eye and voxel.eye then beam.eye = { voxel.eye[1], voxel.eye[2], voxel.eye[3] } end
        local cx, cz = beam.center[1], beam.center[3]
        local yaw = eye and math.atan2((eye[1] or cx) - cx, (eye[3] or cz + 1) - cz) or 0
        local recall = beam.kind == "recall"
        local p = deps.pose(beam.t, beam.center, beam.mouth, beam.width, beam.height, yaw, recall and "recall" or "battle")
        if not p or (not recall and p.pull >= .995) or p.fade <= .001 then return true end
        -- keep the plasma flowing while the geometry holds at the spot (a recall keeps its own intake clock)
        if not recall then p.timer = beam.age end
        if not beam.vertices then beam.vertices, beam.indices = deps.Plasma.newGeometry() end
        local key = table.concat({ p.timer, beam.center[1], beam.center[2], beam.center[3],
          beam.mouth[1], beam.mouth[2], beam.mouth[3], beam.t, yaw }, ":")
        if beam.key ~= key then
          deps.Plasma.update(beam.vertices, p)
          if not beam.mesh then
            beam.mesh = voxel.newMesh(beam.vertices, beam.indices)
          elseif type(beam.mesh.setVertices) == "function" then
            beam.mesh:setVertices(beam.vertices)
          end
          beam.key = key
        end
        if not beam.mesh then error("no beam mesh", 0) end
        if deps.Material.draw(voxel, beam.mesh, nil, IDENT, 0, p, false) == false then error("beam material draw failed", 0) end
        list.stats.draws = list.stats.draws + 1
        beam.draws = (beam.draws or 0) + 1
        return true
      end)
    end
    if not ok then
      list.stats.failed = list.stats.failed + 1
      list.lastError = tostring(err)
      B.clearBeam(beam, "draw failed")
      table.remove(list.beams, i)
    end
  end
end

function B.status(list)
  if not list then return nil end
  local out = {}
  for k, v in pairs(list.stats) do out[k] = v end
  out.live = {}
  for i, beam in ipairs(list.beams) do
    out.live[i] = { battler = beam.battler, slot = beam.slot, index = beam.index, hand = beam.hand, phase = beam.phase,
      age = beam.age, t = beam.t, hold = beam.hold, appeared = beam.appeared, draws = beam.draws or 0,
      center = beam.center and { beam.center[1], beam.center[2], beam.center[3] } or nil }
  end
  out.lastError = list.lastError
  return out
end

return B
