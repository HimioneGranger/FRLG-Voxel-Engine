-- FRLG_VOXEL: the overworld actors (player + current-map event objects) as
-- plain records for the billboard pass. Mirrors the data FieldView's
-- collectGame3Actors reads (src/core/game3/field_view.lua:548-681) but keeps
-- only what a 3D billboard needs. Not included yet: the follower and
-- field-effect actors (grass, surf blob, shadows). Neighbour-map "ghost" NPCs
-- (engine src/core/game3/ghosts.lua pools) are appended only under VRITK and the
-- Speed58 `ghostcards` flag (Lab 58 approach loading A1, see _collectGhosts).
-- This file is FireRed's (game3 engine modules); the Emerald layout has its own.
--
-- Lab 8 (P0-2, CHECK "Missing" 1): display-rate interpolation. Game logic
-- runs at a fixed 60 Hz (src/core/FixedStep.lua) and the headset shows 72 Hz,
-- so 12 frames a second used to repeat the previous logic pose: the camera
-- and every walking card stood still for one frame and then jumped, even in
-- grid mode. Positions are now blended between the pose at the start of the
-- last logic tick and the current one by the fixed-step accumulator
-- (alpha = FixedStep.accum / FixedStep.STEP):
--   * Actors.beginTick() snapshots the player and the event objects at the
--     start of every logic tick (the engine's input.step hook, installed by
--     main.lua). Until it has run once, every position is raw, exactly as
--     before, so a missing hook costs nothing but the smoothing.
--   * Actors.beginFrame(dt) samples alpha once per rendered frame (View:prepare).
--   * Provider cards (another mod's records) carry no tick snapshot: they are
--     blended by record key between the last two logic poses seen at render
--     time, which is exact while a frame runs 0 or 1 logic ticks.
-- A move bigger than INTERP_STEP px in one tick is not blended. For the
-- player, a jump up to POP_MAX px (free walking handing a step to the grid,
-- a script moving a player who stood between cells) is absorbed instead: the
-- drawn position keeps where it was and eases to the logic pose over
-- ~POP_TAU seconds. Bigger jumps (warps, map changes) snap as before.
local V = ...
local _ = V

local Actors = {}

local CELL = 16

local cache = {}
local function engine(name)
  local m = cache[name]
  if m then return m end
  local ok, mod = pcall(require, name)
  if ok and type(mod) == "table" then cache[name] = mod; return mod end
  return nil
end

local out = {}
local pool = {}

-- Lab 58 approach loading (A1/A2): flags from perf/Speed58 (all off without the VRITK gate = the Lab 57 list)
local okS58, Speed58 = pcall(V.require, "perf/Speed58")
local function speedOn(name)
  if not okS58 or type(Speed58) ~= "table" then return false end
  return Speed58.on(name) == true
end
local okBB, Billboards = pcall(V.require, "render/Billboards")
if not okBB or type(Billboards) ~= "table" then Billboards = nil end
Actors.GHOST_MAX = 40       -- ghost cards per frame at most (engine pool order, after the cull)
Actors.CULL_MARGIN = 4      -- cells past the draw range; Billboards.CULL_MARGIN is the same number
Actors.clock = 0            -- seconds of rendered frames (Actors.beginFrame); the scale-in age clock

-- ------------------------------------------------------------ interpolation
Actors.INTERP_STEP = 6     -- px per logic tick; the bike is 4, a run 2, a walk 1
Actors.POP_MAX = 24        -- px: a player jump up to this is eased, not snapped
Actors.POP_TAU = 0.06      -- seconds for an absorbed jump to ease out (1/e)

local I = {
  hooked = false,   -- beginTick has run at least once
  tick = 0,         -- logic ticks seen
  alpha = 1,
  -- the player at the start of the last logic tick (engine px, py, lift)
  ppx = nil, ppy = nil, plift = nil, pmap = nil,
  popX = 0, popY = 0, popTick = -1,
  -- provider records by key: last two logic poses seen at render time
  provTick = -1, provSweep = 0,
  kx0 = {}, kz0 = {}, kx1 = {}, kz1 = {}, kseen = {},
}
-- event objects at the start of the last tick, weak so unloaded maps go
local objX = setmetatable({}, { __mode = "k" })
local objY = setmetatable({}, { __mode = "k" })
Actors._interp = I -- test seam (plain data)

-- Approach loading: card key of an event object = "<map>:<local id>". The key string is built once per object (and
-- again only if its map or id changes) so the steady state allocates nothing. A foreign carried object keeps the key
-- of the map it came from; a neighbour ghost uses its pool's map id, so the same NPC has ONE key as ghost and live.
local kMap = setmetatable({}, { __mode = "k" })
local kLid = setmetatable({}, { __mode = "k" })
local kStr = setmetatable({}, { __mode = "k" })
local function keyFor(eo, mapId, lid)
  if mapId == nil or lid == nil then return nil end
  if kMap[eo] == mapId and kLid[eo] == lid then return kStr[eo] end
  local key = tostring(mapId) .. ":" .. tostring(lid)
  kMap[eo], kLid[eo], kStr[eo] = mapId, lid, key
  return key
end
local G = { frame = 0, seen = {}, pool = {}, n = 0 } -- seen[key] = collect frame that emitted the key
Actors._ghost = G -- test seam

local function mapToken()
  local Map = engine("src.core.game3.map")
  return Map and Map.current or nil
end

local function playerLift(Player)
  local lift = Player.spriteYOffset or 0
  if lift == 0 and Player.jumpSpriteY then
    local okJ, j = pcall(Player.jumpSpriteY)
    if okJ and type(j) == "number" then lift = j end
  end
  return lift
end

-- The start of one logic tick (engine input.step hook): remember where the
-- player and every event object stand before this tick moves them.
function Actors.beginTick()
  I.hooked = true
  I.tick = I.tick + 1
  local Player = engine("src.core.game3.player")
  if Player then
    I.ppx = (Player.px or 0) + (Player.spriteXOffset or 0)
    I.ppy = Player.py or 0
    I.plift = playerLift(Player)
    I.pmap = mapToken()
  end
  local Objects = engine("src.core.game3.objects")
  local order, byId = Objects and Objects._order, Objects and Objects._byId
  if type(order) == "table" and type(byId) == "table" then
    for i = 1, #order do
      local eo = byId[order[i]]
      if eo then
        objX[eo] = eo.px or ((eo.cellX or 0) * CELL)
        objY[eo] = eo.py or ((eo.cellY or 0) * CELL)
      end
    end
  end
  if I.glim2 then Actors._snapshotGhosts() end
end

-- True once positions are display-rate blended (the tick hook is live).
function Actors.blending() return I.hooked end

-- Once per rendered frame, before any position is read: the blend factor
-- and the absorbed-jump ease.
function Actors.beginFrame(dt)
  local a = 1
  local FS = I.hooked and engine("src.core.FixedStep") or nil
  if FS then
    local step = tonumber(FS.STEP) or (1 / 60)
    a = (tonumber(FS.accum) or step) / step
    if a ~= a then a = 1 end
    a = math.max(0, math.min(1, a))
  end
  I.alpha = a
  dt = tonumber(dt) or 0
  if dt > 0 then Actors.clock = Actors.clock + (dt < 0.25 and dt or 0.25) end
  if dt > 0 and (I.popX ~= 0 or I.popY ~= 0) then
    local k = math.exp(-math.min(dt, 0.25) / Actors.POP_TAU)
    I.popX, I.popY = I.popX * k, I.popY * k
    if math.abs(I.popX) < 0.01 then I.popX = 0 end
    if math.abs(I.popY) < 0.01 then I.popY = 0 end
  end
end

local function blend(p, c, a)
  if p == nil or math.abs(c - p) > Actors.INTERP_STEP then return c end
  return p + (c - p) * a
end

-- The player's drawn pixel position (engine px incl. spriteXOffset, py) and
-- lift, blended and eased.
local function playerDrawn(Player)
  local cx = (Player.px or 0) + (Player.spriteXOffset or 0)
  local cy = Player.py or 0
  local lift = playerLift(Player)
  local px, py = I.ppx, I.ppy
  if not I.hooked or px == nil or I.pmap ~= mapToken() then
    I.popX, I.popY = 0, 0
    return cx, cy, lift
  end
  local dx, dy = cx - px, cy - py
  local big = math.max(math.abs(dx), math.abs(dy))
  local x, y
  if big <= Actors.INTERP_STEP then
    x, y = px + dx * I.alpha, py + dy * I.alpha
  elseif big <= Actors.POP_MAX then
    -- once per tick: keep the drawn body where it was, then ease out
    if I.popTick ~= I.tick then
      I.popTick = I.tick
      I.popX, I.popY = I.popX - dx, I.popY - dy
    end
    x, y = cx, cy
  else
    I.popX, I.popY = 0, 0
    return cx, cy, lift
  end
  return x + I.popX, y + I.popY, blend(I.plift, lift, I.alpha)
end

-- Provider records: blend by key between the last two logic poses seen.
local function blendProviders(first, n)
  local newTick = I.tick ~= I.provTick
  I.provTick = I.tick
  local kx0, kz0, kx1, kz1, seen = I.kx0, I.kz0, I.kx1, I.kz1, I.kseen
  local a, lim = I.alpha, Actors.INTERP_STEP / CELL
  for i = first, n do
    local r = out[i]
    local key = r.key
    if key ~= nil then
      local x, z = r.x, r.z
      if newTick or kx1[key] == nil then
        kx0[key], kz0[key] = kx1[key] or x, kz1[key] or z
      end
      kx1[key], kz1[key] = x, z
      seen[key] = I.tick
      local x0, z0 = kx0[key], kz0[key]
      if math.abs(x - x0) <= lim and math.abs(z - z0) <= lim then
        r.x, r.z = x0 + (x - x0) * a, z0 + (z - z0) * a
      end
    end
  end
  -- forget keys unseen for a while (despawned wild Pokemon, effects)
  if I.tick - I.provSweep > 300 then
    I.provSweep = I.tick
    for key, t in pairs(seen) do
      if I.tick - t > 120 then
        seen[key], kx0[key], kz0[key], kx1[key], kz1[key] = nil, nil, nil, nil, nil
      end
    end
  end
end

-- Lab 8: free walking hands the player's walk cycle in here (FreeMove sets
-- it); nil = the engine's own grid walkPhase/drawFlip.
Actors.playerAnim = nil

-- W5 (owmons): external actor providers. Another mod hands the 3D view
-- extra characters (records it owns and reuses) without this file knowing
-- what they are. A provider is a function(ctx) or a table { collect =
-- function(ctx) } returning an array of records:
--   { x, z (root cells, sprite base centre), liftPx, facing,
--     pose = function(rec, relFacing) -> image, u0, v0, u1, v1,
--            frameW, frameH (px), artBottom (px row or nil), xscale (or nil)
--     key, kind, catchable (hit-target identity, optional),
--     shadow = false | number (blob scale, default 1),
--     liftScaled = bool (lift follows the card scale: icons over a head) }
-- Billboards draws any record carrying `pose` through the usual ground,
-- lift, shadow and mesh path. Registration is keyed by id (re-registering
-- replaces); a provider that throws 30 times in a row is dropped with one
-- log line. HostApi forwards vrHost.actors.registerProvider/-Provider here.
Actors.PROVIDER_MAX_ERRORS = 30
Actors.providers = {}
local providerCtx = {}

function Actors.registerProvider(id, provider)
  if type(id) ~= "string" or id == "" then return false, "bad id" end
  local fn = provider
  if type(provider) == "table" then fn = provider.collect end
  if type(fn) ~= "function" then return false, "provider needs a collect function" end
  for _, p in ipairs(Actors.providers) do
    if p.id == id then p.collect, p.errors, p.failed = fn, 0, false; return true end
  end
  Actors.providers[#Actors.providers + 1] = { id = id, collect = fn, errors = 0, failed = false }
  return true
end

function Actors.unregisterProvider(id)
  for i, p in ipairs(Actors.providers) do
    if p.id == id then table.remove(Actors.providers, i); return true end
  end
  return false
end

-- Appends every provider's records after the engine actors; returns the new n.
local function collectProviders(game, n)
  local list = Actors.providers
  if #list == 0 then return n end
  providerCtx.game = game
  for _, p in ipairs(list) do
    if not p.failed then
      local ok, recs = pcall(p.collect, providerCtx)
      if ok then
        p.errors = 0
        if type(recs) == "table" then
          for _, r in ipairs(recs) do
            if type(r) == "table" and type(r.pose) == "function"
                and type(r.x) == "number" and type(r.z) == "number" then
              n = n + 1
              out[n] = r
            end
          end
        end
      else
        p.errors = p.errors + 1
        p.lastError = tostring(recs)
        if p.errors >= Actors.PROVIDER_MAX_ERRORS then
          p.failed = true
          print("[FRLG_VOXEL] actor provider '" .. p.id .. "' disabled after "
            .. p.errors .. " errors: " .. p.lastError)
        end
      end
    end
  end
  return n
end

local function record(i)
  local r = pool[i]
  if not r then r = {}; pool[i] = r end
  for k in pairs(r) do r[k] = nil end
  return r
end

-- Returns an array of { x, z (root cells, sprite base centre), gid, facing,
-- walkPhase, stepFlip, opts, player, liftPx }. The array is reused.
function Actors.collect(game, cullX, cullZ, far)
  for i = #out, 1, -1 do out[i] = nil end
  I.glim2 = nil -- re-armed when ghost cards run this frame
  local OwSprites = engine("src.core.game3.ow_sprites")
  if not (OwSprites and OwSprites.ready and OwSprites.ready()) then return out end
  -- credits and cutscenes hide every overworld actor (field_view.lua:1317)
  local FieldView = engine("src.core.game3.field_view")
  if FieldView and FieldView.hideActors then return out end
  local n = 0
  local Objects = engine("src.core.game3.objects")
  local Space = engine("src.core.game3.scripting.space")
  -- Lab 58 approach loading: keys for the scale-in and the ghost dedupe (flags off = no key, the Lab 57 record)
  local ghostOn = speedOn("ghostcards") and Billboards ~= nil and type(cullX) == "number" and type(cullZ) == "number"
    and type(far) == "number"
  local keyOn = ghostOn or speedOn("cardscale")
  local curMap
  if keyOn then
    curMap = mapToken()
    G.frame = G.frame + 1
    if G.frame % 600 == 0 then for k in pairs(G.seen) do G.seen[k] = nil end end
  end
  if Objects and Objects.hasMap and Objects.hasMap() and Objects.forDraw then
    local ok, list = pcall(Objects.forDraw)
    if ok and type(list) == "table" then
      for _, eo in ipairs(list) do
        local gid = eo.graphicsId or (eo.def and (eo.def.graphicsId or eo.def.graphics))
        if Space and Space.resolveObjectGraphicsId and eo.def then
          local okG, g2 = pcall(Space.resolveObjectGraphicsId, eo.def)
          if okG and g2 then gid = g2 end
        end
        if gid ~= nil then
          n = n + 1
          local r = record(n)
          -- raiseY is a screen-up hop (jumps, bounces): lift the card instead
          -- of sliding it north/south (review item 22)
          local ex = eo.px or ((eo.cellX or 0) * CELL)
          local ey = eo.py or ((eo.cellY or 0) * CELL)
          if I.hooked then -- Lab 8: blended to the display rate
            ex, ey = blend(objX[eo], ex, I.alpha), blend(objY[eo], ey, I.alpha)
          end
          local px = ex + (eo.raiseX or 0)
          local py = ey
          r.x = (px + CELL / 2) / CELL
          r.z = (py + CELL / 2) / CELL
          r.liftPx = -(tonumber(eo.raiseY) or 0)
          r.gid = gid
          r.facing = eo.facing or "down"
          local okW, wp = pcall(Objects.walkPhase, eo)
          r.walkPhase = okW and wp or 0
          r.stepFlip = eo.stepFlip and true or false
          r.opts = { bow = (eo.bowFrames and eo.bowFrames > 0) or eo.raiseHand == true,
                     frame = eo.customFrame }
          out[n] = r
          if keyOn then
            local key = keyFor(eo, eo.foreignMap or curMap, eo.foreignLid or eo.localId)
            if key then r.fadeKey = key; G.seen[key] = G.frame end
          end
        end
      end
    end
  end
  local Player = engine("src.core.game3.player")
  if Player and (not Player.isVisible or Player.isVisible()) then
    local okG, gid = pcall(OwSprites.playerGraphicsId, game)
    if okG and gid ~= nil then
      n = n + 1
      local r = record(n)
      local px, py, lift = playerDrawn(Player) -- Lab 8: blended
      -- field-move and fishing poses, as field_view.lua:638-662 builds them
      local opts = {}
      local fieldMove = (tonumber(Player.fieldMoveAnim) or 0) > 0
      if fieldMove then
        opts.fieldMove = true
        if OwSprites.fieldMoveFrame then
          local okM, f = pcall(OwSprites.fieldMoveFrame,
            (Player.fieldMoveTotal or Player.fieldMoveAnim) - Player.fieldMoveAnim,
            Player.fieldMoveKind)
          if okM then opts.fieldMoveFrame = f end
        end
      else
        local Field = engine("src.core.game3.field")
        if Field and Field.fishingPose then
          local okP, frame, fx, fy = pcall(Field.fishingPose)
          if okP and frame ~= nil then
            opts.fishing = true
            opts.fishFrame = frame
            px = px + (tonumber(fx) or 0)
            lift = lift + (tonumber(fy) or 0)
          end
        end
      end
      if Player.runPose then
        local okR, run = pcall(Player.runPose)
        if okR then opts.running = run end
      end
      r.x = (px + CELL / 2) / CELL
      r.z = (py + CELL / 2) / CELL
      r.liftPx = -(lift or 0)
      r.gid = gid
      r.facing = Player.facing or "down"
      local freeAnim = Actors.playerAnim
      local okA, fwp, ffl, frun = false, nil, nil, nil
      if freeAnim then okA, fwp, ffl, frun = pcall(freeAnim) end
      if okA and fwp ~= nil then
        -- Lab 8: free walking drives the walk cycle by distance
        r.walkPhase = fwp == 1 and 1 or 0
        r.stepFlip = ffl and true or false
        if frun ~= nil and not opts.fieldMove and not opts.fishing then opts.running = frun end
      else
        local okW, wp = pcall(Player.walkPhase)
        r.walkPhase = (okW and (wp == 1 or wp == true)) and 1 or 0
        local okF, fl = pcall(Player.drawFlip)
        r.stepFlip = okF and fl and true or false
      end
      r.player = true
      r.opts = opts
      out[n] = r
    end
  end
  if ghostOn then n = Actors._collectGhosts(game, n, cullX, cullZ, far, OwSprites, Objects) end
  local first = n + 1
  n = collectProviders(game, n) -- W5 (owmons): external cards go last
  if I.hooked and n >= first then blendProviders(first, n) end -- Lab 8
  return out
end

-- ------------------------------------------------------------ neighbour ghost cards (Lab 58 A1)
-- Read-only over the engine: Map.world entries other than Map.current, the pools in Ghosts._pools (the same objects
-- field_view.lua collectNeighborActors draws in the flat view), Objects.walkPhase. Nothing is spawned, ticked or loaded.
-- A ghost becomes a card only when
--   * it is visible by the rule of Objects.poolForDraw (visible, not hidden, not invisible, not off the pool bounds);
--   * it stands within far + CULL_MARGIN cells of the cull centre (the draw range, so the haze already hides the edge);
--   * its sheet is ALREADY loaded (Billboards.sheetFor: palette override sprite, else OwSprites._loaded) and its art rows
--     are ALREADY cached (Billboards.artRowsCached). Nothing here calls getDraw / load: cold sheets are the warm
--     queue's jobs (VRITK_FRLG_HOST ApproachLoader), so a ghost whose sheet is cold simply has no card yet;
--   * its key was not emitted this frame already (live object or carried-over foreign object of the same NPC).
-- Records are pooled with their opts table; the steady state allocates nothing.
local function offMap(bounds, eo)
  if not bounds then return false end
  local x, y = eo.cellX or 0, eo.cellY or 0
  return x < 0 or y < 0 or x >= bounds.w or y >= bounds.h
end

local function refreshStaleWorld(game, Map)
  if Map._worldRoot == Map.current or type(Map.refreshWorld) ~= "function" then return end
  -- exactly what field_view.lua:1368 does on each flat draw (idempotent: it returns at once when the root and the
  -- reach are unchanged); the last reach the flat view used, never a new one
  local rw, rh = tonumber(Map._worldReachW) or 0, tonumber(Map._worldReachH) or 0
  if rw < 0 then rw = 0 end
  if rh < 0 then rh = 0 end
  pcall(Map.refreshWorld, game, rw, rh, Map.current)
end

function Actors._collectGhosts(game, n, cullX, cullZ, far, OwSprites, Objects)
  local Map, Ghosts = engine("src.core.game3.map"), engine("src.core.game3.ghosts")
  if not (Map and Ghosts and Map.current ~= nil) then return n end
  refreshStaleWorld(game, Map)
  local world, pools = Map.world, Ghosts._pools
  if type(world) ~= "table" or type(pools) ~= "table" then return n end
  local lim = far + Actors.CULL_MARGIN
  local lim2 = lim * lim
  I.gcx, I.gcz, I.glim2 = cullX, cullZ, lim2 -- beginTick snapshots only ghosts inside this circle
  local cur = Map.current
  local seen, frame, gpool = G.seen, G.frame, G.pool
  local hooked, alpha = I.hooked, I.alpha
  local walkPhase = Objects and Objects.walkPhase
  local count, max = 0, Actors.GHOST_MAX
  for wi = 1, #world do
    local entry = world[wi]
    local id = entry.id
    local gp = id ~= cur and pools[id] or nil
    local order, byId = gp and gp.order, gp and gp.byId
    if order and byId then
      local eox, eoy = (entry.ox or 0) * CELL, (entry.oy or 0) * CELL
      local bounds = gp.bounds
      for i = 1, #order do
        local lid = order[i]
        local eo = byId[lid]
        if eo and eo.visible and not eo.hidden and not eo.invisible and not offMap(bounds, eo) then
          local ex = eo.px or ((eo.cellX or 0) * CELL)
          local ey = eo.py or ((eo.cellY or 0) * CELL)
          if hooked then ex, ey = blend(objX[eo], ex, alpha), blend(objY[eo], ey, alpha) end
          local x = (ex + (eo.raiseX or 0) + eox + CELL / 2) / CELL
          local z = (ey + eoy + CELL / 2) / CELL
          local dx, dz = x - cullX, z - cullZ
          if dx * dx + dz * dz <= lim2 then
            local gid = eo.graphicsId or (eo.def and (eo.def.graphicsId or eo.def.graphics))
            local key = gid ~= nil and keyFor(eo, id, lid) or nil
            if key and seen[key] ~= frame then
              local spr = Billboards.sheetFor(OwSprites, gid)
              if spr and Billboards.artRowsCached(spr) then
                if count >= max then return n end
                count = count + 1
                seen[key] = frame
                local r = gpool[count]
                if not r then r = { opts = {} }; gpool[count] = r end
                r.x, r.z = x, z
                r.liftPx = -(tonumber(eo.raiseY) or 0)
                r.gid = gid
                r.facing = eo.facing or "down"
                local okW, wp = false, nil
                if walkPhase then okW, wp = pcall(walkPhase, eo) end
                r.walkPhase = okW and wp or 0
                r.stepFlip = eo.stepFlip and true or false
                local o = r.opts
                o.bow = (eo.bowFrames and eo.bowFrames > 0) or eo.raiseHand == true
                o.frame = eo.customFrame
                r.ghostKey = key
                r.fadeKey = key
                n = n + 1
                out[n] = r
              end
            end
          end
        end
      end
    end
  end
  return n
end

-- Start of a logic tick: remember where each ghost inside the last cull circle stands (display-rate blending).
function Actors._snapshotGhosts()
  local Map, Ghosts = engine("src.core.game3.map"), engine("src.core.game3.ghosts")
  local world, pools = Map and Map.world, Ghosts and Ghosts._pools
  if type(world) ~= "table" or type(pools) ~= "table" then return end
  local cx, cz, lim2, cur = I.gcx, I.gcz, I.glim2, Map.current
  for wi = 1, #world do
    local entry = world[wi]
    local gp = entry.id ~= cur and pools[entry.id] or nil
    local order, byId = gp and gp.order, gp and gp.byId
    if order and byId then
      local eox, eoy = (entry.ox or 0) * CELL, (entry.oy or 0) * CELL
      for i = 1, #order do
        local eo = byId[order[i]]
        if eo then
          local ex = eo.px or ((eo.cellX or 0) * CELL)
          local ey = eo.py or ((eo.cellY or 0) * CELL)
          local dx, dz = (ex + eox + CELL / 2) / CELL - cx, (ey + eoy + CELL / 2) / CELL - cz
          if dx * dx + dz * dz <= lim2 then objX[eo], objY[eo] = ex, ey end
        end
      end
    end
  end
end

-- The player's own state for the camera rig. Lab 8: x/z are the blended
-- display-rate position (see the interpolation notes at the top).
function Actors.player()
  local Player = engine("src.core.game3.player")
  if not Player then return nil end
  local dx, dy = playerDrawn(Player)
  dx = dx - (Player.spriteXOffset or 0)
  return {
    x = (dx + CELL / 2) / CELL,
    z = (dy + CELL / 2) / CELL,
    facing = Player.facing or "down",
    cellX = Player.cellX, cellY = Player.cellY,
    moving = Player.moving,
    targetX = Player.targetX, targetY = Player.targetY,
  }
end

return Actors
