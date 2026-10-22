-- Track C (Lab 54): Wilds of Hoenn 1.5.0 as the FireRed / LeafGreen overworld
-- provider. Gen-specific compat layer: every FireRed assumption of the Wilds
-- integration lives here (layout "frlg" only); Emerald keeps its own Lab 47
-- WildsOfHoennCompat. Wilds itself stays game-neutral: this file talks to it
-- through its exports only (spawnManager, battleTrigger, setSpawnDecorator,
-- vrFollowerState, renderers' vrSnapshotInto) and never reads RAM, ROM
-- symbols or map tables.
--
-- FireRed specifics handled here:
--   * Pokemon Tower 1F-7F without the Silph Scope (user decision 2026-10-10 #3):
--     every spawn there is shown as a ghost silhouette (2D: the renderer's own
--     silhouette; 3D: a dark translucent card). The engine turns the battle
--     into its ghost battle itself; FRLG_CATCH refuses the throw ("ghost").
--   * Life size (decision #2): cards use FRLG_VOXEL's first-person card scale,
--     like the Untamed cards (liftScaled, no native pixel scale).
--   * FireRed's billboard contract: pose -> image, uv, frame size, artBottom,
--     xscale, colour (10th); per-card colour and premultiplied cards are the
--     additive Billboards seam of this lab.
-- Budgets: 8 wild cards + the follower, 10 records at most. Action cards
-- (overworld-fight HP bars / hit popups as render-to-texture cards) are not
-- produced on FireRed yet (design D10 phase 2): MAX_ACTION_CARDS documents
-- the agreed cap for that phase.
--
-- Per frame: collect() walks the spawn manager's order array and fills
-- records pooled per entity (one per live entity, one follower record);
-- vrSnapshotInto writes into per-record tables. No closures, tables or
-- strings are made per frame once a record exists.
local M = {}

M.ID = "wilds_of_hoenn"
M.PIN = "1.5.0" -- legacy public pin
M.SUPPORTED_VERSIONS = { ["1.5.0"] = true, ["1.7.1"] = true, ["1.10.1"] = true }
M.LAYOUT = "frlg"
M.PROVIDER_ID = "wilds_of_hoenn"
M.FOLLOWER_KEY = "follower:1"
M.MAX_WILD_CARDS = 8
M.MAX_CARDS = 10
M.MAX_ACTION_CARDS = 4
M.GHOST = { 0.06, 0.05, 0.09, 0.72 } -- multiplied into the card: a dark, see-through shape
-- A water Pokemon (entity.terrain == "water") rides the surface: its card lift gets a slow bob (native pixels, cycles/s),
-- each Pokemon at its own phase. Not checked on a headset; set WATER_BOB_PX to 0 to switch it off.
M.WATER_BOB_PX = 1.0
M.WATER_BOB_HZ = 0.3
-- Handles of retired entities are pruned when a new key is made and more than
-- this many exist (ReVoxel Lab 48 found the Emerald router's handle table
-- growing for good: one entry per spawn and catch attempt).
M.HANDLE_PRUNE_AT = 24

local CELL = 16
local AVAILABLE = "available"
local floor, abs, max = math.floor, math.abs, math.max
local sin = math.sin
local function clock()
  if love and love.timer and love.timer.getTime then return love.timer.getTime() end
  return os.clock()
end

-- deps: find(id), layout() -> "frlg"|..., G3 (VRITK Game3Capture), capture
--       (compat/WildsCapture), emit(snapshot), log(text), host() -> vrHost|nil,
--       session() -> session|nil, Catching() -> engine catching module|nil
function M.new(deps)
  local A = {
    id = M.ID, label = "WILDS", optionMods = {}, deps = deps,
    epoch = 0, serial = 0, handles = {}, keys = setmetatable({}, { __mode = "k" }),
    hidden = {}, selected = nil, manager = nil, map = nil, wild = nil, handleCount = 0, pruned = 0,
    cardRecs = setmetatable({}, { __mode = "k" }), listRecs = setmetatable({}, { __mode = "k" }),
    out = {}, list = {}, frames = 0, cards = 0, ghosts = 0,
  }
  A.optionMods[M.ID] = true
  A.ambient = deps.ambient and deps.ambient.new() or nil
  local FST = {} -- vrFollowerState scratch
  local function handle() return deps.find(M.ID) end
  local function exports()
    local h = handle()
    return h and h.exports or nil
  end

  -- ------------------------------------------------------------ detection
  function A:gate() return exports() end

  function A:probe()
    local layout = deps.layout and deps.layout() or nil
    if layout ~= M.LAYOUT then return false, "not FireRed/LeafGreen (layout " .. tostring(layout) .. ")" end
    local h = handle()
    if not h then return false, "wilds_of_hoenn not loaded" end
    local ex = h.exports or {}
    local version = h.version or ex.version
    if not M.SUPPORTED_VERSIONS[version] then return false, "unsupported wilds_of_hoenn version: " .. tostring(version) end
    if ex.engineReady ~= true then
      return false, "Wilds engine probe failed (needs Encounters.rollSweetScent and Message.closeStay)"
    end
    if type(ex.setNativeProviderEnabled) ~= "function" then return false, "Wilds native gate missing" end
    if type(ex.vrFollowerState) ~= "function" or type(ex.setSpawnDecorator) ~= "function" then
      return false, "Wilds VR exports missing"
    end
    local sm = ex.spawnManager
    if not (sm and type(sm.get) == "function" and type(sm.order) == "table") then return false, "Wilds spawn manager missing" end
    if type(ex.vrProviderEnabled) == "function" then
      local ok, on = pcall(ex.vrProviderEnabled)
      if ok and on == false then return false, "Wilds 'Show Wild Mons' is off" end
    end
    return true
  end

  -- ------------------------------------------------------------ identity
  function A:reset()
    self.epoch = self.epoch + 1
    self.handles = {}
    self.handleCount = 0
    self.keys = setmetatable({}, { __mode = "k" })
    self.hidden = {}
    self.handoff = nil
  end

  -- WildsCapture contract: refresh() keeps manager/map current (cheap, no detection).
  function A:refresh()
    local ex = self.wild
    local m = ex and ex.spawnManager
    if m ~= self.manager or (m and m.mapId ~= self.map) then
      if self.manager ~= nil then self:reset() end
      self.manager = m
    end
    self.map = m and m.mapId or nil
    return self.selected
  end

  -- Drop handles whose entity left the manager (caught, despawned, battled).
  -- A reserved capture keeps its handle until its transaction ends.
  function A:pruneHandles()
    local m, n = self.manager, 0
    for k, h in pairs(self.handles) do
      local e = h.entity
      local live = m and h.manager == m and m:get(h.id) == e
      if not live and not (e and e._vrCapture) then
        self.handles[k] = nil
        if self.hidden[k] then self.hidden[k] = nil end
        self.pruned = self.pruned + 1
      else
        n = n + 1
      end
    end
    self.handleCount = n
  end

  function A:key(e)
    local k = self.keys[e]
    if not k then
      if self.handleCount >= M.HANDLE_PRUNE_AT then self:pruneHandles() end
      self.handleCount = self.handleCount + 1
      self.serial = self.serial + 1
      k = "wilds_of_hoenn:" .. self.epoch .. ":" .. self.serial
      self.keys[e] = k
      self.handles[k] = { entity = e, manager = self.manager, epoch = self.epoch, id = e.id }
    end
    return k
  end

  function A:resolveWild(k)
    self:refresh()
    local h = self.handles[k]
    if self.selected ~= M.ID or not h or h.epoch ~= self.epoch or h.manager ~= self.manager then return nil end
    local e = self.manager:get(h.id)
    if e ~= h.entity or e.state ~= AVAILABLE or e.engaged then return nil end
    local GI = M.GrowIn
    if GI and GI.pending(e) then return nil end -- Lab 60: not shown yet, so not targetable
    return e
  end

  -- ------------------------------------------------------------ FireRed spawn rule (decision #3)
  local function ghostDecorator(entity, mapId)
    local GI = M.GrowIn -- Lab 60 (item 4): the grow-in stagger slot (compat/WildsGrowInCompat; nil = no stagger)
    if GI then GI.stamp(entity, mapId) end
    local G3 = deps.G3
    if not (G3 and G3.towerGhost and deps.session) then return end
    local ok, ghost = pcall(G3.towerGhost, deps.session())
    if ok and ghost then
      entity.vrGhost = true
      if entity.renderer then entity.renderer.silhouette = true end
      A.ghosts = A.ghosts + 1
    end
  end
  A.ghostDecorator = ghostDecorator

  -- ------------------------------------------------------------ cards
  -- Snapshot -> billboard numbers (FRLG_VOXEL Billboards' pose contract).
  local function finish(rec, p, e)
    if not p or not p.image or not p.quad or (p.rotation or 0) ~= 0 then return nil end
    local u, v, w, h = p.quad:getViewport()
    local iw, ih = p.image:getDimensions()
    local sx, sy = p.sx or 1, p.sy or 1
    if sx == 0 or sy == 0 or iw == 0 or ih == 0 then return nil end
    local y0 = p.y - (p.oy or 0) * sy
    local y1 = y0 + h * sy
    local bottom = max(y0, y1)
    local width, height = abs(w * sx), abs(h * sy)
    -- feet on the ground: the native support line, not the frame's padding
    rec.liftPx = (p.groundY or (p.y + CELL)) - bottom
    if e and e.terrain == "water" and M.WATER_BOB_PX ~= 0 then
      rec.liftPx = rec.liftPx + M.WATER_BOB_PX * sin(clock() * M.WATER_BOB_HZ * 6.2831853 + (e.id or 0) * 1.7)
    end
    local c = rec.color
    if e and e.vrGhost then
      local g = M.GHOST
      c[1], c[2], c[3], c[4] = g[1], g[2], g[3], g[4]
    else
      c[1], c[2], c[3], c[4] = p.r or 1, p.g or 1, p.b or 1, p.a or 1
    end
    return p.image, (sx < 0 and u + w or u) / iw, (sy < 0 and v + h or v) / ih,
      (sx < 0 and u or u + w) / iw, (sy < 0 and v or v + h) / ih, width, height, height - 1, 1, c
  end
  A._finish = finish

  -- fix57 (bug 4): a reserved capture target keeps state "vr_capture" until its transaction ends. Its card is hidden
  -- from the commit on (A.hidden); when the capture tail reveals it for the break-out (tx.hide(false)) the card
  -- must draw again, otherwise the Pokemon stays invisible until the battle hand-off and "just disappears".
  local function drawable(e)
    return e.state == AVAILABLE or (e.state == "vr_capture" and e._vrCapture ~= nil)
  end

  local function wildPose(rec, relFacing)
    local e = rec._e
    if A.selected ~= M.ID or not e or not drawable(e) or A.hidden[rec.key] then return nil end
    local r = e.renderer
    if not (r and r.vrSnapshotInto) then return nil end
    local p = r:vrSnapshotInto(rec._snap, e.px or 0, e.py or 0, 0, 0, relFacing or e.facing, rec._walk, false)
    local img, u0, v0, u1, v1, w, h, ab, xs, c = finish(rec, p, e)
    local GI = M.GrowIn -- Lab 60 (item 4): grow-in about the feet; the lift shrinks with the card so the feet stay planted
    if img and GI then
      local sc = GI.scale(e)
      if sc < 1 then rec.liftPx = rec.liftPx * sc; w, h = w * sc, h * sc; ab = h - 1 end
    end
    return img, u0, v0, u1, v1, w, h, ab, xs, c
  end

  local function followerPose(rec, relFacing)
    if A.selected ~= M.ID or A.hidden[M.FOLLOWER_KEY] then return nil end
    local r = rec._r
    if not (r and r.vrSnapshotInto) then return nil end
    local p = r:vrSnapshotInto(rec._snap, rec._px, rec._py, 0, 0, relFacing or rec.facing, 0, false)
    return finish(rec, p, nil)
  end

  local function cardRec(e)
    local rec = A.cardRecs[e]
    if not rec then
      rec = { kind = "wild", provider = M.ID, shadow = 1, liftScaled = true, color = { 1, 1, 1, 1 },
        pose = wildPose, _e = e, _snap = {} }
      A.cardRecs[e] = rec
    end
    return rec
  end
  local followerCard = { key = M.FOLLOWER_KEY, kind = "follower", provider = M.ID, shadow = 1,
    liftScaled = true, catchable = false, color = { 1, 1, 1, 1 }, pose = followerPose, _snap = {} }
  A.followerCard = followerCard

  -- vrWildPose is Wilds' own allocation-free export (SpawnManager.poseOf); it is
  -- called directly: a pcall per entity per frame broke LuaJIT traces here.
  local function walkOf(ex, e)
    local f = ex.vrWildPose
    if f then return f(e) or "stand" end
    return "stand"
  end

  -- FRLG_VOXEL provider collect (prepare phase; no render-to-texture here).
  function A:collect()
    local out = self.out
    for i = #out, 1, -1 do out[i] = nil end
    self.frames = self.frames + 1
    if self.selected ~= M.ID then return out end
    local ex = self.wild
    local m = ex and ex.spawnManager
    if not m then return out end
    if m ~= self.manager or m.mapId ~= self.map then self:refresh() end
    local n, wilds = 0, 0
    local catchReady = self.captureReady == true
    local order, entities = m.order, m.entities
    local GI = M.GrowIn -- Lab 60 (item 4)
    if GI then GI.beginFrame() end
    for i = 1, #order do
      if wilds >= M.MAX_WILD_CARDS then break end
      local e = entities[order[i]]
      if e and drawable(e) and not (e.fx and (e.fx.mode == "swoop" or e.fx.mode == "swim")) and not (GI and GI.pending(e)) then
        local key = self:key(e)
        if not self.hidden[key] then
          local r = e.renderer
          if r and r.vrSnapshotInto then
            local rec = cardRec(e)
            rec.key = key
            rec._walk = walkOf(ex, e)
            local p = r:vrSnapshotInto(rec._snap, e.px or 0, e.py or 0, 0, 0, e.facing, rec._walk, false)
            if p then
              rec.x, rec.z = (p.groundX or ((e.px or 0) + 8)) / CELL, (p.groundZ or ((e.py or 0) + 8)) / CELL
              rec.facing = e.facing
              rec.catchable = catchReady and not e.engaged and e.state == AVAILABLE
              if GI then GI.touch(e) end
              n, wilds = n + 1, wilds + 1
              out[n] = rec
            end
          end
        end
      end
    end
    if n < M.MAX_CARDS and not self.hidden[M.FOLLOWER_KEY] and type(ex.vrFollowerState) == "function" then
      local ok, have = pcall(ex.vrFollowerState, FST)
      if ok and have and not FST.hidden and FST.renderer and FST.renderer.vrSnapshotInto then
        local rec = followerCard
        rec._r, rec._px, rec._py, rec.facing = FST.renderer, FST.x or 0, FST.y or 0, FST.facing or "down"
        local p = FST.renderer:vrSnapshotInto(rec._snap, rec._px, rec._py, 0, 0, rec.facing, 0, false)
        if p then
          rec.x, rec.z = (p.groundX or (rec._px + 8)) / CELL, (p.groundZ or (rec._py + 8)) / CELL
          n = n + 1
          out[n] = rec
        end
      end
    end
    self.cards = n
    if self.ambient and ex.version == "1.10.1" then self.ambient:append(out, ex, m, self.frames) end
    return out
  end

  -- ------------------------------------------------------------ owMons v1 (Wilds keys)
  local api = { api = 1, providerRouting = true, captureTransactions = 1, provider = M.ID }
  A.api = api

  local function listRec(e)
    local r = A.listRecs[e]
    if not r then r = { kind = "wild", provider = M.ID }; A.listRecs[e] = r end
    return r
  end
  local followerList = { key = M.FOLLOWER_KEY, slot = 1, kind = "follower", provider = M.ID, catchable = false }

  --- Records for the live wild Pokemon (and the follower). Records and the
  --- array are reused: read them before the next list() call.
  function api.list()
    local out = A.list
    for i = #out, 1, -1 do out[i] = nil end
    if A.selected ~= M.ID then return out end
    A:refresh()
    local m = A.manager
    if not m then return out end
    local n = 0
    local catchReady = A.captureReady == true
    local growIn = M.GrowIn -- Lab 60: a wild that is not shown yet is listed hidden (and so not catchable)
    for i = 1, #m.order do
      local e = m.entities[m.order[i]]
      if e and e.state == AVAILABLE then
        local key = A:key(e)
        local r = listRec(e)
        r.key, r.slot = key, e.id
        r.x, r.z = ((e.px or 0) + 8) / CELL, ((e.py or 0) + 8) / CELL
        r.liftPx, r.facing = 0, e.facing
        r.engineSpecies, r.level, r.personality = e.species, e.level, e.personality
        r.shiny, r.roamer, r.water = e.shiny == true, e.roamer == true, e.terrain == "water"
        r.hidden = A.hidden[key] == true or (growIn ~= nil and growIn.pending(e))
        r.ghost = e.vrGhost == true
        r.catchable = catchReady and not e.engaged and not r.hidden
        r.busy = e.engaged == true
        if catchReady then r.captureReason = nil else r.captureReason = "Wilds capture adapter unavailable" end
        n = n + 1
        out[n] = r
      end
    end
    local ex = A.wild
    if ex and type(ex.vrFollowerState) == "function" then
      local ok, have = pcall(ex.vrFollowerState, FST)
      if ok and have and not FST.hidden then
        local r = followerList
        r.x, r.z = ((FST.x or 0) + 8) / CELL, ((FST.y or 0) + 8) / CELL
        r.liftPx, r.facing = 0, FST.facing or "down"
        r.engineSpecies, r.personality = FST.species, FST.mon and FST.mon.personality or nil
        r.level = FST.mon and FST.mon.level or nil
        r.hidden = A.hidden[M.FOLLOWER_KEY] == true
        r.recalled = FST.recalled == true
        n = n + 1
        out[n] = r
      end
    end
    return out
  end

  function api.resolve(k)
    if type(k) ~= "string" or not k:match("^wilds_of_hoenn:") then return nil end
    return A:resolveWild(k)
  end

  -- Capture reserves/hides the entity before it asks for a sprite copy: read the
  -- pinned handle without making it catchable again (as Lab 47).
  local SNAP = {}
  local CI = { color = { 1, 1, 1, 1 } }
  function api.cardImage(record, facing)
    if A.selected ~= M.ID then return nil, "wilds not selected" end
    local key = type(record) == "table" and record.key or record
    if key == M.FOLLOWER_KEY then
      local ex = A.wild
      local ok, have = pcall(ex.vrFollowerState, FST)
      if not (ok and have and FST.renderer and FST.renderer.vrSnapshotInto) then return nil, "no follower" end
      local p = FST.renderer:vrSnapshotInto(SNAP, FST.x or 0, FST.y or 0, 0, 0, facing or FST.facing, 0, false)
      local img, u0, v0, u1, v1, w, h, bottom = finish(CI, p, nil)
      if not img then return nil, "native pose unavailable" end
      return img, u0, v0, u1, v1, w, h, false, bottom, CI.liftPx
    end
    local hd = A.handles[key]
    local e = hd and hd.entity
    if not (hd and hd.epoch == A.epoch and hd.manager == A.manager and A.manager and A.manager:get(hd.id) == e
        and (e.state == AVAILABLE or (e.state == "vr_capture" and e._vrCapture))) then
      return nil, "native card unavailable"
    end
    local r = e.renderer
    if not (r and r.vrSnapshotInto) then return nil, "native pose unavailable" end
    local p = r:vrSnapshotInto(SNAP, e.px or 0, e.py or 0, 0, 0, facing or e.facing, walkOf(A.wild, e), false)
    local img, u0, v0, u1, v1, w, h, bottom = finish(CI, p, e)
    if not img then return nil, "native pose unavailable" end
    -- uv already mirrored; artBottom = last frame row (the support line is the lift)
    return img, u0, v0, u1, v1, w, h, false, bottom
  end

  function api.busy()
    if A.selected ~= M.ID then return false end
    local t = A.wild and A.wild.battleTrigger
    return t ~= nil and t.pendingId ~= nil
  end

  function api.hide(k, on)
    if type(k) ~= "string" then return false end
    if k ~= M.FOLLOWER_KEY and not A:resolveWild(k) then return false, "gone or wrong provider" end
    A.hidden[k] = on and true or nil
    return true
  end

  local function snapshotOf(key, e)
    local r, x, y, facing, walk = e.renderer, e.px or 0, e.py or 0, e.facing, walkOf(A.wild, e)
    local snap = { key = key, provider = M.ID, slot = e.id, engineSpecies = e.species, species = e.species,
      level = e.level, personality = e.personality, shiny = e.shiny == true, ghost = e.vrGhost == true,
      x = (x + 8) / CELL, z = (y + 8) / CELL, cellX = e.cellX, cellY = e.cellY, facing = facing,
      water = e.terrain == "water", startedAt = clock() }
    -- battle-start only: a fresh table per call is fine here
    snap.cardImage = function(f)
      if not (r and r.vrSnapshotInto) then return nil, "native pose unavailable" end
      local p = r:vrSnapshotInto({}, x, y, 0, 0, f or facing, walk, false)
      local img, u0, v0, u1, v1, w, h, bottom = finish({ color = { 1, 1, 1, 1 } }, p, e)
      if not img then return nil, "native pose unavailable" end
      return img, u0, v0, u1, v1, w, h, false, bottom
    end
    return snap
  end

  function api.startBattle(k, preparedMon)
    local e = A:resolveWild(k)
    if not e then return false, "gone or wrong provider" end
    local trigger = A.wild and A.wild.battleTrigger
    if not (trigger and type(trigger.startForVR) == "function") then return false, "native VR battle acknowledgment unavailable" end
    local snap = snapshotOf(k, e)
    local ok, accepted, why = pcall(trigger.startForVR, trigger, e, preparedMon)
    if not ok then return false, tostring(accepted) end
    if accepted == true then
      A.hidden[k] = nil
      A.handoff = snap
      if deps.emit then pcall(deps.emit, snap) end
      return true
    end
    return false, why or "native battle refused"
  end

  function api.battleSnapshot()
    if A.handoff and not api.busy() then A.handoff.ended = true; A.handoff = nil end
    return A.handoff
  end

  -- No fake caught success: removal happens inside the capture transaction.
  function api.despawnCaught() return false, "Wilds removes a caught Pokemon inside its capture transaction" end
  function api.roamerFoe() return nil end
  function api.chainCaught() return false, "no chain" end
  function api.chain() return nil end
  function api.captureOwner() return api end
  function api.beginCapture(key, session)
    if not (deps.capture and A.captureReady) then return nil, "Wilds capture adapter unavailable" end
    return deps.capture.begin(A, key, session)
  end
  function api.status()
    local m = A.manager
    local atlas
    if A.wild and type(A.wild.atlasStats) == "function" then
      local ok, s = pcall(A.wild.atlasStats); atlas = ok and s or nil
    end
    return { provider = M.ID, selected = A.selected == M.ID, epoch = A.epoch, map = A.map,
      entities = m and #m.order or 0, cards = A.cards, frames = A.frames, ghosts = A.ghosts,
      captureReady = A.captureReady == true, registered = A.registeredActors ~= nil,
      handles = A.handleCount, pruned = A.pruned,
      hidden = A.hidden[M.FOLLOWER_KEY] == true, atlas = atlas }
  end
  -- WildsCapture calls router.api.startBattle
  A.routerApi = api

  -- ------------------------------------------------------------ lifecycle (router)
  function A:activate()
    local ex = exports()
    if not ex then return false, "wilds_of_hoenn not loaded" end
    self.wild = ex
    self.selected = M.ID
    self:reset()
    self.manager = ex.spawnManager
    self.map = self.manager and self.manager.mapId or nil
    pcall(ex.setSpawnDecorator, ghostDecorator)
    -- fix57 (bugs 2, 3, 5): follower fixes wrapped around Wilds' live objects (normally already installed by main.lua)
    local fix = deps.followerFix
    if fix and type(fix.install) == "function" then
      local okF, okI, whyF = pcall(fix.install, ex, { require = require, log = deps.log })
      if not (okF and okI) and deps.log then deps.log("wilds follower fix off: " .. tostring(okF and whyF or okI)) end
    end
    local C = deps.Catching and deps.Catching()
    self.captureReady = deps.capture ~= nil and C ~= nil and C.vrTransactionalStore == 1
    local host = deps.host and deps.host()
    local actors = host and host.actors
    if actors and type(actors.registerProvider) == "function" then
      local ok, res = pcall(actors.registerProvider, M.PROVIDER_ID, { collect = function() return A:collect() end })
      if ok and res ~= false then self.registeredActors = actors end
    end
    return true
  end

  function A:deactivate()
    if self.ambient then self.ambient:close() end
    local actors = self.registeredActors
    if actors and type(actors.unregisterProvider) == "function" then pcall(actors.unregisterProvider, M.PROVIDER_ID) end
    self.registeredActors = nil
    if self.selected == M.ID then self:reset() end
    self.selected = nil
    local ex = self.wild or exports()
    if ex and type(ex.setSpawnDecorator) == "function" then pcall(ex.setSpawnDecorator, nil) end
    -- COMPAT60: the follower-fix layer stays installed (main.lua installs it whenever Wilds is present; its ROLE-row guard
    -- must outlive the provider selection, and its interaction parts are inactive while the Wilds gate is off)
  end

  -- The VR host may appear after the router (FRLG_VOXEL session restart).
  function A:ensureRegistered()
    if self.selected ~= M.ID or self.registeredActors then return end
    local host = deps.host and deps.host()
    local actors = host and host.actors
    if actors and type(actors.registerProvider) == "function" then
      local ok, res = pcall(actors.registerProvider, M.PROVIDER_ID, { collect = function() return A:collect() end })
      if ok and res ~= false then self.registeredActors = actors end
    end
  end

  function A:onEpoch(reason, active)
    if active then
      self:reset()
      self:ensureRegistered()
    end
  end

  return A
end

return M
