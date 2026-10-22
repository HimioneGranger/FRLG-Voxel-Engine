-- FRLG_VOXEL Lab 59: PRECACHE ON FIRST LOAD (FireRed's own file).
--
-- When the world cache is missing or invalid (first launch, an update that changes the cache key, a cleared cache,
-- or a precache that was interrupted), every map and border ring is built once behind a "Preparing 3D world"
-- screen and saved with the Lab 57 WORLD CACHE writer (lib/perf/FrPrecache*.lua). Everything is generated here on
-- the device from the player's own game data; nothing is shipped or bundled.
--
-- How it works
--   * A SECOND Scene instance (env.newScene) is driven through the normal build path: for each map the root is
--     set to that map (so the mask plan, the neighbour placement and the border ring are what a visit produces),
--     the map job and then its ring job are run through Scene's own _start/_resume coroutine, and the record is
--     handed to the same capture writer a visit would use (PC:pump). The record is released as soon as it is
--     written. The live Scene is never touched.
--   * Everything runs in ONE coroutine (self.co) resumed once per frame with a time budget. Scene's own yield
--     points (the mesher's 14 checkpoints, the chunk uploads, the mask rows) yield the build coroutine through
--     Scene._setDeadline's deadline; the capture loop yields on the same clock. So a frame never waits for more
--     than the longest stretch between two checkpoints, and the caller keeps submitting XR frames.
--   * Order: outdoor towns, then routes, then other outdoor maps, then interiors. Each job is a map and its ring.
--   * Resumable. Each record is committed by the cache writer (parts first, header LAST: a record without a valid
--     header is simply a miss). A small manifest (prep.a / prep.b, written alternately, md5-sealed) names the
--     record each finished map produced. It is written only AFTER the index that lists those records. A map
--     whose record is missing from the index, a half-written map, a torn manifest, a changed code digest or a
--     cleared cache all just mean "not done": the next launch builds those maps again and nothing else.
--   * Skip: skip() drops the in-flight job and its unfinished files and ends the screen; the game builds maps on
--     demand as before and the precache resumes the next launch.
--   * Storage: two failed writes in a row end the precache softly (the writer itself switches the cache off for
--     the session after three, as in Lab 57); after two failed launches the precache stops trying until the cache key changes.
--   * GC: planned collector CYCLES run in small steps, a slice per frame (never one long stall), between maps when
--     the heap has grown and at the end, so the heap stays off the ceiling during the bulk build.
--
-- Pure logic: the clock, the scene factory, the world source, the collector and the progress screen are injected.
local V = ...
local F = V.require("perf/FrPrecacheFormat")
local K = V.require("perf/FrPrecacheKey")
local Store = V.require("perf/FrPrecacheStore")
local okS, Solar = pcall(V.require, "render/SolarShadows")
if not okS then Solar = nil end

local P = {}
P.__index = P

P.VERSION = 1
P.MAX_ATTEMPTS = 2        -- a map that comes back unclean / failed is retried on the next launch once, then given up
P.MAX_STORAGE_FAILS = 2   -- launches whose writes failed before the precache stops trying
P.CHECKPOINT_JOBS = 6     -- index + manifest are written every this many finished jobs ...
P.CHECKPOINT_S = 3.0      -- ... or this many seconds, whichever comes first
P.HEAP_STEP_KB = 192 * 1024      -- planned collect between jobs once the heap is this far above the clean baseline
P.HEAP_CEIL_FRAC = 0.6           -- ... but never wait for more than this fraction of GcSlack's ceiling (600 MiB)
P.CEIL_KB = 600 * 1024
P.RING_SHARE = 0.3        -- share of a job's progress weight that belongs to its ring
P.PAUSE_GAP_S = 0.5       -- a gap between two updates longer than this is a pause (menu, battle), not build time
P.ETA_MIN_WEIGHT = 0.04   -- no time estimate before this share of the work is done

local ST_OK, ST_SKIP, ST_FAIL, ST_RETRY = 1, 2, 3, 4
P.ST = { OK = ST_OK, SKIP = ST_SKIP, FAIL = ST_FAIL, RETRY = ST_RETRY }

local ACTIVE = { check = true, plan = true, tiles = true, run = true, finish = true }
P.ACTIVE = ACTIVE

local floor, min, max = math.floor, math.min, math.max

local function md5raw(s) return love.data.hash("md5", s) end

-- env = { pc, clock, log, newScene = fn -> Scene, scene = Scene class (releaseRecord, _setDeadline),
--         source = WorldSource, maps = fn(game) -> table, ensureLayout = fn(game, id, def) -> layout|nil,
--         isOutdoor = fn(def) -> bool, reach = number, shadows = fn -> bool, gate = fn -> bool,
--         collect = fn -> kbBefore, kbAfter, ms, heapKB = fn -> kb, capBytes = number|nil }
function P.new(env)
  local self = setmetatable({
    env = env, pc = env.pc, clock = env.clock or os.clock, log = env.log or print,
    phase = "idle", reason = nil,
    done = 0, total = 0, doneWeight = 0, totalWeight = 0,
    entries = {}, seq = 0, last = nil, dirtyManifest = false, storageFails = 0,
    skipReq = false, rearmed = 0,
    stats = { slices = 0, over16 = 0, over50 = 0, over100 = 0, over250 = 0, worstMs = 0, collects = 0, collectMs = 0,
      collectMsMax = 0, built = 0, hits = 0, skippedMaps = 0, failedMaps = 0, retryMaps = 0, writeFails = 0,
      bytesAtEnd = 0, busyMs = 0 },
    groupMs = {}, groupBytes = {}, groupMaps = {}, curGroup = nil,
    curName = "", etaSec = -1, activeS = 0, lastUpdate = nil, deadline = 0,
  }, P)
  return self
end

-- ------------------------------------------------------------------ manifest
local function encodeManifest(self, token)
  local w = F.writer()
  w:raw("FRPS")
  w:u32(P.VERSION)
  w:u32(self.seq)
  w:str(token)
  w:u8(min(255, self.storageFails))
  local keys = {}
  for k in pairs(self.entries) do keys[#keys + 1] = k end
  table.sort(keys)
  w:u32(#keys)
  for _, k in ipairs(keys) do
    local e = self.entries[k]
    w:str(k)
    w:u8(e.status)
    w:u8(min(255, e.attempts or 0))
    w:raw(e.rk and #e.rk == 16 and e.rk or string.rep("\0", 16))
  end
  local body = w:result()
  return body .. md5raw(body)
end

local function decodeManifest(s)
  if type(s) ~= "string" or #s < 40 then return nil, "short" end
  local body, sum = s:sub(1, -17), s:sub(-16)
  if md5raw(body) ~= sum then return nil, "md5" end
  local r = F.reader(body)
  if r:bytes(4) ~= "FRPS" then return nil, "magic" end
  if r:u32() ~= P.VERSION then return nil, "version" end
  local seq = r:u32()
  local token = r:str()
  local fails = r:u8()
  local n = r:u32()
  if n > 20000 then return nil, "count" end
  local entries = {}
  for _ = 1, n do
    local k = r:str()
    local status, attempts = r:u8(), r:u8()
    local rk = r:bytes(16)
    if status < 1 or status > 4 then return nil, "status" end
    entries[k] = { status = status, attempts = attempts, rk = rk ~= string.rep("\0", 16) and rk or nil }
  end
  if r:left() ~= 0 then return nil, "trailing" end
  return { seq = seq, token = token, fails = fails, entries = entries }
end
P._encodeManifest, P._decodeManifest = encodeManifest, decodeManifest

local function hexToRaw(hex) return love.data.decode("string", "hex", hex) end
local function rawToHex(raw) return love.data.encode("string", "hex", raw) end

function P:_token()
  local pc = self.pc
  return K.md5hex(table.concat({ "frpp1", tostring(pc.game), tostring(pc.code), tostring(pc.engine) }, "|"))
end

-- Load the newer valid copy; keep it only when its token matches. -> true when the manifest is usable
function P:_loadManifest()
  local cache = self.pc.cache
  local best, sawManifest
  for _, name in ipairs({ "a", "b" }) do
    local okR, s = pcall(cache.read, cache, Store.DIR .. "prep." .. name)
    if okR and type(s) == "string" then
      sawManifest = true
      local okD, m = pcall(decodeManifest, s)
      if okD and m and (not best or m.seq > best.seq) then best = m; best.which = name end
    end
  end
  self.entries, self.seq, self.last = {}, 0, nil
  -- Display-only mode: use existing saved-state evidence, never write a new cache marker.
  self.operation = (sawManifest or (tonumber(self.pc.store.count) or 0) > 0) and "rebuild" or "precache"
  if best then
    self.seq, self.last = best.seq, best.which
    if best.token == self.token then
      self.operation = "resume"
      self.entries, self.storageFails = best.entries, best.fails or 0
      return true
    end
  end
  self.storageFails = 0
  return false
end

function P:_saveManifest()
  local pc = self.pc
  local store = pc.store
  store:flush(true) -- the index that lists the records goes first; a manifest never names an unindexed record
  if store.dirty then return false end
  self.seq = self.seq + 1
  local okE, data = pcall(encodeManifest, self, self.token)
  if not okE then self.seq = self.seq - 1; return false end
  local target = self.last == "a" and "b" or "a"
  local okW, res = pcall(pc.cache.write, pc.cache, Store.DIR .. "prep." .. target, data)
  if okW and res ~= nil and res ~= false then
    self.last = target
    self.dirtyManifest = false
    self.lastCheckpoint = self.clock()
    return true
  end
  self.stats.writeFails = self.stats.writeFails + 1
  return false
end

function P:_isDone(key)
  local e = self.entries[key]
  if not e then return false end
  if e.status == ST_OK then
    local present = e.rk ~= nil and self.pc.store:has(rawToHex(e.rk)) ~= nil
    if not present then self.operation = "rebuild" end
    return present
  end
  if e.status == ST_SKIP then return true end
  return (e.attempts or 0) >= P.MAX_ATTEMPTS
end

function P:_note(key, status, rk)
  local e = self.entries[key]
  local attempts = e and e.attempts or 0
  if status == ST_FAIL or status == ST_RETRY then attempts = attempts + 1 end
  self.entries[key] = { status = status, attempts = attempts, rk = rk and hexToRaw(rk) or nil }
  self.dirtyManifest = true
end

-- ------------------------------------------------------------------ control
function P:isActive() return ACTIVE[self.phase] == true end
-- The screen is shown only once there is work to do, not during the short check of an already complete cache.
function P:isVisible() return self.phase == "run" or self.phase == "finish" or self.phase == "tiles" end
function P:isTerminal() return self.phase == "done" or self.phase == "skipped" or self.phase == "off" or self.phase == "failed" end

-- A new request (the switch turned ON again, or a CLEAR): look at the cache again from the start.
function P:rearm()
  if self:isActive() then return end
  self:_cleanup()
  self.phase, self.reason, self.skipReq, self.storageFailed = "idle", nil, false, false
  self.storageFails = 0
  self.operation = nil
  self.clearFails = true -- the manifest still holds the old counter: forget it when it is loaded
  self.rearmed = self.rearmed + 1
end

-- Skip for now (B button). Takes effect at the start of the next update.
function P:skip() if self:isActive() then self.skipReq = true end end

function P:progress(out)
  out.phase, out.done, out.total = self.phase, self.done, self.total
  out.operation = self.operation
  out.frac = self.totalWeight > 0 and min(1, self.doneWeight / self.totalWeight) or 0
  if self.phase == "tiles" then -- the tileset pre-pass counts tilesets, not maps
    out.done, out.total = self.tileDone or 0, self.tileTotal or 0
    out.frac = (self.tileTotal or 0) > 0 and min(1, (self.tileDone or 0) / self.tileTotal) or 0
  end
  out.etaSec = self.etaSec
  out.name = self.curName
  out.skipping = self.skipReq
  out.reason = self.reason
  return out
end

-- ------------------------------------------------------------------ planning
local function groupOf(self, def)
  local env = self.env
  if env.isOutdoor(def) then
    local mt = tonumber(def.mapType) or 0
    if mt == 1 or mt == 2 or (mt == 0 and def.kind == "town") then return 1 end
    if mt == 3 or def.kind == "route" then return 2 end
    return 3
  end
  return 4
end

function P:_plan(game)
  local maps = self.env.maps(game)
  local ids = {}
  if type(maps) == "table" then
    for id, def in pairs(maps) do
      if type(id) == "string" and type(def) == "table" then ids[#ids + 1] = id end
    end
  end
  table.sort(ids)
  local jobs = {}
  local only = self.env.only -- test seam: { [id] = true } limits the plan to those maps
  for _, id in ipairs(ids) do
    local def = maps[id]
    if only and not only[id] then goto continue end
    local L = def.midLayout
    local w = tonumber(L and L.width or def.width) or 16
    local h = tonumber(L and L.height or def.height) or 16
    local g = groupOf(self, def)
    jobs[#jobs + 1] = { id = id, group = g, weight = max(16, w * h) * (g <= 3 and 1.5 or 1.0), outdoor = g <= 3 }
    self:_tick()
    ::continue::
  end
  table.sort(jobs, function(a, b)
    if a.group ~= b.group then return a.group < b.group end
    return a.id < b.id
  end)
  self.jobs = jobs
  self.totalAll = #jobs
  return jobs
end

-- ------------------------------------------------------------------ the coroutine body
function P:_tick()
  if self.clock() >= self.deadline then coroutine.yield() end
end

function P:_yieldFrame() coroutine.yield() end

function P:_say(fmt, ...)
  local ok, s = pcall(string.format, fmt, ...)
  self.log("prepare " .. (ok and s or fmt))
end

-- Planned collect. A full "collect" is one indivisible stall (321 ms on the desktop, so seconds on the headset),
-- which is exactly what a frame-keeping precache must not do; the same work is done as one collector CYCLE in small
-- steps, a slice of steps per frame, and the build waits for it at a job boundary. env.gc / env.afterCollect are
-- injectable (the host tells GC SLACK about the new baseline).
P.GC_STEP_KB = 32
function P:_collect(why)
  local env = self.env
  local gc = env.gc or collectgarbage
  local clock = self.clock
  local kb0 = gc("count")
  local t0 = clock()
  local st = self.stats
  local worst, steps = 0, 0
  while steps < 200000 do
    local c0 = clock()
    local done = gc("step", P.GC_STEP_KB)
    local d = (clock() - c0) * 1000
    if d > worst then worst = d end
    steps = steps + 1
    if done then break end
    if clock() >= self.deadline then self:_yieldFrame() end
  end
  local kb1 = gc("count")
  local ms = (clock() - t0) * 1000
  st.collects = st.collects + 1
  st.collectMs = st.collectMs + ms
  if ms > st.collectMsMax then st.collectMsMax = ms end
  if worst > (st.gcStepMsMax or 0) then st.gcStepMsMax = worst end
  self.baselineKB = kb1
  if env.afterCollect then pcall(env.afterCollect, kb1) end
  self:_say("planned collect (%s): heap %.0f MB -> %.0f MB, %d steps, longest step %.1f ms, %.0f ms in all", why,
    kb0 / 1024, kb1 / 1024, steps, worst, ms)
end

function P:_maybeCollect()
  local env = self.env
  if not env.heapKB then return end
  local kb = env.heapKB()
  local base = self.baselineKB or 0
  -- never a cycle after every job when the live heap itself already sits high: at least 64 MB of growth first
  local high = max(min(base + P.HEAP_STEP_KB, P.HEAP_CEIL_FRAC * P.CEIL_KB), base + 64 * 1024)
  if kb and kb > high then self:_collect("heap high") end
end

-- Set the second Scene up as if the player had just arrived on map `job.id`. -> true | false, why
function P:_setRoot(job, game)
  local env = self.env
  local bulk = self.bulk
  local maps = env.maps(game)
  local def = maps and maps[job.id]
  if not def then return false, "no map definition" end
  local layout = env.ensureLayout(game, job.id, def)
  if not layout then return false, "no layout" end
  local entries, rootDef = env.source:worldEntries(game, job.id, env.reach)
  if not entries or not rootDef then return false, "no world entries" end
  bulk.rootId, bulk.rootDef = job.id, rootDef
  bulk.placed = {}
  for i, e in ipairs(entries) do bulk.placed[i] = { key = e.id, id = e.id, def = e.def, ox = e.ox, oy = e.oy } end
  bulk.placed[#bulk.placed + 1] = { key = tostring(job.id) .. "#border", border = true, ox = 0, oy = 0 }
  bulk.shadows = env.shadows and env.shadows() ~= false
  if env.enterMap then env.enterMap(job.id, rootDef) end
  return true
end

function P:_clearRoot()
  local bulk = self.bulk
  if bulk then
    bulk.rootId, bulk.rootDef, bulk.placed, bulk.queue = nil, nil, {}, {}
  end
end

function P:_releaseAll()
  local bulk = self.bulk
  if not bulk then return end
  local Scene = self.env.scene
  for _, store in ipairs({ bulk.cache, bulk.borders }) do
    for key, rec in pairs(store) do
      store[key] = nil
      pcall(Scene.releaseRecord, rec)
    end
  end
end

-- Drop the in-flight build, if any (skip / failure / switch off). Safe to call at any time.
function P:_cancelBuild()
  local bulk = self.bulk
  if not bulk then return end
  local a = bulk.active
  bulk.active = nil
  if a then
    pcall(bulk._releaseInflight, bulk, a.co)
    if Solar then pcall(Solar.cancelReservations, bulk, a.co) end
  end
end

function P:_cleanup()
  local Scene = self.env.scene
  if Scene and Scene._setDeadline then Scene._setDeadline(nil) end
  self:_cancelBuild()
  local pc = self.pc
  if pc then
    if self.bulk and pc:busy(self.bulk) then pc:dropFor(self.bulk) end
    pc:setBulk(false)
    if self.capSaved then pc.capBytes = self.capSaved; self.capSaved = nil end
  end
  self:_releaseAll()
  self:_clearRoot()
  self.co = nil
  self.bulk = nil
end

-- A capture of the LIVE Scene may still be running (started before the screen came up, or while a menu paused the
-- precache): only its own pump may continue it, and the live pump does not run while the screen is up, so finish it
-- here with that Scene (its record is still placed there, or the capture aborts by itself).
function P:_settleForeign()
  local pc = self.pc
  local n = 0
  while pc.co and pc.item and pc.item.scene ~= self.bulk and n < 100000 do
    n = n + 1
    if self.skipReq or not pc:enabled() then break end
    self:_pumpOnce(pc.item.scene)
  end
end

-- One capture step. The writer needs FLUSH_MIN_MS of budget, so a frame whose budget is nearly gone yields instead --
-- except that every frame gets at least one step (a budget smaller than that must not starve the writer).
function P:_pumpOnce(scene)
  local now = self.clock()
  if self.pumpedFrame == self.frameNo and now >= self.deadline - 0.0015 then
    self:_yieldFrame()
    return
  end
  self.pumpedFrame = self.frameNo
  self.pc:pump(scene, math.max(self.deadline, now + 0.003))
end

-- Engine tileset FIRST LOADS (tileset_native.get: palette hash + native_pack decode, 40-80 ms each on the desktop) cannot
-- be split without an engine edit, so they are done up front, ONE TILESET PER FRAME with the panel showing, instead of
-- stacking on top of mesher work in the middle of a map. The mod-side atlas scan that follows a load yields as usual.
function P:_loadTilesets(game)
  local env = self.env
  if not (env.source and env.source.atlasFor) then return end
  local maps = env.maps(game)
  local seen, list = {}, {}
  for _, job in ipairs(self.todo) do
    local def = maps[job.id]
    local pair = def and (def.pair or (def.midLayout and def.midLayout.pair))
    if pair and not seen[pair] then seen[pair] = true; list[#list + 1] = pair end
  end
  table.sort(list)
  self.phase, self.tileTotal, self.tileDone = "tiles", #list, 0
  for i, pair in ipairs(list) do
    if self.skipReq then break end
    local t0 = self.clock()
    pcall(env.source.atlasFor, env.source, pair)
    local ms = (self.clock() - t0) * 1000
    self.stats.tilesets = (self.stats.tilesets or 0) + 1
    if ms > (self.stats.tileMsMax or 0) then self.stats.tileMsMax = ms end
    self.tileDone = i
    self:_yieldFrame() -- the next load starts in a fresh slice
  end
  self.phase = "run"
end

-- One part of a job: kind "m" (the map) or "r" (its border ring). -> status
function P:_buildPart(kind, job, game)
  local pc, bulk = self.pc, self.bulk
  local jobT
  local key = kind == "r" and (job.id .. "#border") or job.id
  if kind == "m" or kind == "f" then
    local L = bulk.rootDef and bulk.rootDef.midLayout or {}
    jobT = { key = job.id, id = job.id, ox = 0, oy = 0, w = L.width or 0, h = L.height or 0, root = kind == "m" }
    if kind == "f" then
      -- the FAR-NEIGHBOUR variant: the same map met as a distant neighbour of some other root has mask plan "skip"
      -- (FAR SHADOWS off) = a different key. Nothing is placed near it and no root matches it.
      bulk.rootId, bulk.placed = nil, {}
    end
  else
    jobT = bulk:_borderJob()
  end
  local pcs = pc.stats
  local u0, b0, s0 = pcs.unclean, pcs.bypass, pcs.saveFailed
  self.curPart = kind == "m" and "map" or (kind == "f" and "far" or "ring")
  local a = bulk:_start(jobT, game)
  while bulk.active do
    bulk:_resume(a)
    if bulk.active then self:_yieldFrame() end
  end
  local store = kind == "r" and bulk.borders or bulk.cache
  local rec = store[key]
  local status, rk
  if not rec or rec.failed then
    status = ST_FAIL
    self.stats.failedMaps = self.stats.failedMaps + 1
    self:_say("FAILED %s: %s", key, tostring(rec and rec.reason or "no record"))
  elseif rec.empty then
    status = ST_SKIP -- a ring with no cells: nothing to cache, nothing to build later either
  elseif rec.cacheHit then
    status, rk = ST_OK, rec.cacheRk
    self.stats.hits = self.stats.hits + 1
  elseif rec.pcInfo then
    -- queued for the idle-frame writer: drain it (the same coroutine a visit uses, several writes per frame)
    rk = rec.pcInfo.rk
    self.curPart = kind == "m" and "map-write" or (kind == "f" and "far-write" or "ring-write")
    self.stats.built = self.stats.built + 1
    while pc:busy(bulk) do
      if self.skipReq or not pc:enabled() or pc.disabled then break end
      if pc.co and pc.item and pc.item.scene ~= bulk then self:_settleForeign()
      else self:_pumpOnce(bulk) end
    end
    if pc.disabled or (pc.failStreak or 0) >= 2 then
      -- two write failures in a row (the writer's own rule): the disk is full or unwritable; stop, stay playable
      status = ST_RETRY
      self.storageFailed = true
      self.stats.writeFails = self.stats.writeFails + 1
    elseif pc.store:has(rk) then status = ST_OK
    elseif pcs.saveFailed > s0 then status = ST_RETRY; rk = nil
    else status = ST_RETRY; rk = nil end
  elseif pcs.unclean > u0 then
    status = ST_RETRY
    self.stats.retryMaps = self.stats.retryMaps + 1
  elseif pcs.bypass > b0 then
    status = ST_SKIP
    self.stats.skippedMaps = self.stats.skippedMaps + 1
  else
    status = ST_RETRY
  end
  -- release the record: it lives on disk now
  store[key] = nil
  if rec then pcall(self.env.scene.releaseRecord, rec) end
  return status, rk
end

function P:_doJob(job, game)
  local mKey, rKey, fKey = "m:" .. job.id, "r:" .. job.id, "f:" .. job.id
  local needM, needR = not self:_isDone(mKey), not self:_isDone(rKey)
  local needF = job.outdoor and not self:_isDone(fKey)
  if not (needM or needR or needF) then return end
  self.curName = job.id
  self.curGroup = job.group
  local bytes0 = self.pc.store.total
  local ok, why = self:_setRoot(job, game)
  if not ok then
    self:_note(mKey, ST_SKIP); self:_note(rKey, ST_SKIP)
    self.stats.skippedMaps = self.stats.skippedMaps + 1
    self:_say("skip %s: %s", job.id, tostring(why))
    self.doneWeight = self.doneWeight + job.weight * (1 - P.RING_SHARE) -- keeps the bar reaching 100%
    return
  end
  if needM then
    local status, rk = self:_buildPart("m", job, game)
    if not self.skipReq then self:_note(mKey, status, rk) end
  end
  self.doneWeight = self.doneWeight + job.weight * (1 - P.RING_SHARE)
  if needR and not self.skipReq and not self.storageFailed then
    local status, rk = self:_buildPart("r", job, game)
    if not self.skipReq then self:_note(rKey, status, rk) end
  end
  if needF and not self.skipReq and not self.storageFailed then
    local planNear = self.bulk:_maskPlanFor(job.id, false) -- with the map as root
    self.bulk.rootId, self.bulk.placed = nil, {}
    local planFar = self.bulk:_maskPlanFor(job.id, false)
    if planFar == planNear then
      self:_note(fKey, ST_SKIP) -- same record as the root's (FAR SHADOWS full, SUN SHADOWS off ...)
    else
      local status, rk = self:_buildPart("f", job, game)
      if not self.skipReq then self:_note(fKey, status, rk) end
    end
  end
  self:_clearRoot()
  if not self.skipReq then
    local g = job.group
    self.groupBytes[g] = (self.groupBytes[g] or 0) + (self.pc.store.total - bytes0)
    self.groupMaps[g] = (self.groupMaps[g] or 0) + 1
  end
end

function P:_checkpoint(force)
  if not self.dirtyManifest then return end
  local t = self.clock()
  if not force and self.jobsSince < P.CHECKPOINT_JOBS and t - (self.lastCheckpoint or t) < P.CHECKPOINT_S then return end
  self.jobsSince = 0
  self:_saveManifest()
  self.lastCheckpoint = t
end

function P:_body(game)
  local env, pc = self.env, self.pc
  self.phase = "check"
  if not pc:enabled() then self.phase, self.reason = "off", "cache off"; return end
  pc:ensureReady(function() self:_tick() end)
  if pc.disabled then self.phase, self.reason = "off", "cache disabled"; return end
  self.token = self:_token()
  local valid = self:_loadManifest()
  if self.clearFails then self.storageFails, self.clearFails, self.dirtyManifest = 0, false, true end
  self:_tick()
  self.phase = "plan"
  if not valid then
    -- a different code digest / engine / game: every older record is unreachable now
    local n, bytes = pc.store:dropOtherGenerations(pc.gen)
    if n > 0 then self:_say("old cache generation: %d records, %.1f MB queued for deletion", n, bytes / 1048576) end
  end
  self:_plan(game)
  local todo, weight = {}, 0
  for _, job in ipairs(self.jobs) do
    if not (self:_isDone("m:" .. job.id) and self:_isDone("r:" .. job.id) and (not job.outdoor or self:_isDone("f:" .. job.id))) then
      todo[#todo + 1] = job
      weight = weight + job.weight
    end
    self:_tick()
  end
  self.todo = todo
  self.total, self.totalWeight = #self.jobs, 0
  for _, job in ipairs(self.jobs) do self.totalWeight = self.totalWeight + job.weight end
  self.done = self.total - #todo
  self.doneWeight = self.totalWeight - weight
  self.startDone, self.startDoneWeight = self.done, self.doneWeight
  if #todo == 0 then
    self.phase, self.reason = "off", "complete"
    return
  end
  if self.storageFails >= P.MAX_STORAGE_FAILS then
    self.phase, self.reason = "off", "storage"
    self:_say("not started: writes failed on %d earlier launches (change the code or turn the switch OFF and ON to retry)", self.storageFails)
    return
  end
  -- ---- run
  self.phase = "run"
  self.runStart = self.clock()
  self.activeS = 0
  self.jobsSince = 0
  self.lastCheckpoint = self.runStart
  if env.capBytes and pc.capBytes < env.capBytes then self.capSaved = pc.capBytes; pc.capBytes = env.capBytes end
  pc:setBulk(true)
  self.bulk = env.newScene()
  self:_settleForeign()
  self:_say("start: %d of %d maps to build (%d done), code=%s cap=%d MB", #todo, self.total, self.done,
    tostring(pc.code):sub(1, 8), pc.capBytes / 1048576)
  self.baselineKB = (env.gc or collectgarbage)("count")
  self:_loadTilesets(game)
  for i, job in ipairs(todo) do
    if self.skipReq or self.storageFailed then break end
    self:_doJob(job, game)
    if self.skipReq then break end
    self.done = self.done + 1
    self.doneWeight = self.doneWeight + job.weight * P.RING_SHARE
    self.jobsSince = self.jobsSince + 1
    self:_checkpoint(false)
    self:_maybeCollect()
    self:_tick()
  end
  if self.storageFailed then
    self.storageFails = self.storageFails + 1
    self.reason = "storage"
    self.dirtyManifest = true
  end
  self.phase = "finish"
  self:_checkpoint(true)
  self:_releaseAll()
  pc:setBulk(false)
  if self.capSaved then pc.capBytes = self.capSaved; self.capSaved = nil end
  self:_tick()
  if not self.skipReq then self:_collect("end") end
  local info = pc.store:info()
  self.stats.bytesAtEnd = info.bytes
  self:_say("finished: %d maps (%d built, %d hits, %d skipped, %d failed, %d retry), cache %.1f MB in %d records, %.1f s",
    self.done, self.stats.built, self.stats.hits, self.stats.skippedMaps, self.stats.failedMaps, self.stats.retryMaps,
    info.bytes / 1048576, info.records, self.clock() - self.runStart)
  self.phase = self.storageFailed and "failed" or "done"
end

-- ------------------------------------------------------------------ update (once per frame)
-- game = the engine game object; budgetSec = this frame's build time. -> true while the prepare screen owns the
-- frame (the caller then shows it, skips the live pump and the world), false otherwise.
function P:update(game, budgetSec)
  local env = self.env
  local ph = self.phase
  if ph == "idle" then
    local okG, on = pcall(env.gate)
    if not (okG and on == true) then return false end
    if type(game) ~= "table" then return false end
    local maps = env.maps(game)
    if type(maps) ~= "table" or next(maps) == nil then return false end -- the game data is not loaded yet
    self.co = coroutine.create(function() return self:_body(game) end)
    self.phase = "check"
    ph = "check"
    self.lastUpdate = nil
  elseif not ACTIVE[ph] then
    return false
  end
  -- the switch turned OFF (or VRITK went away) while we were running: stop at once
  local okG, on = pcall(env.gate)
  if not (okG and on == true) then
    self:_cleanup()
    self:_saveManifestSafe()
    self.phase, self.reason = "off", "switched off"
    return false
  end
  if self.skipReq then
    self:_cleanup()
    self:_saveManifestSafe()
    self.phase, self.reason = "skipped", "skip"
    self:_say("skipped at %d of %d maps; resumes next launch", self.done, self.total)
    return false
  end
  local t0 = self.clock()
  if self.lastUpdate and t0 - self.lastUpdate < P.PAUSE_GAP_S then self.activeS = self.activeS + (t0 - self.lastUpdate) end
  self.lastUpdate = t0
  self.deadline = t0 + (tonumber(budgetSec) or 0.008)
  self.frameNo = (self.frameNo or 0) + 1
  local Scene = env.scene
  Scene._setDeadline(self.deadline)
  local ok, err = coroutine.resume(self.co)
  Scene._setDeadline(nil)
  local ms = (self.clock() - t0) * 1000
  local st = self.stats
  st.slices = st.slices + 1
  st.busyMs = st.busyMs + ms
  local g = self.curGroup
  if g then self.groupMs[g] = (self.groupMs[g] or 0) + ms end
  if ms > st.worstMs then st.worstMs = ms end
  if ms > 16 then st.over16 = st.over16 + 1 end
  if ms > 50 then st.over50 = st.over50 + 1 end
  if ms > 100 then st.over100 = st.over100 + 1 end
  if ms > 250 then st.over250 = st.over250 + 1 end
  if ms > 120 and (st.slowLogged or 0) < 60 then
    st.slowLogged = (st.slowLogged or 0) + 1
    self:_say("slow slice %.0f ms at %s %s", ms, tostring(self.curName), tostring(self.curPart))
  end
  if not ok then
    self:_say("ERROR %s", tostring(err))
    self:_cleanup()
    self:_saveManifestSafe()
    self.phase, self.reason = "failed", "error: " .. tostring(err)
    return false
  end
  if coroutine.status(self.co) == "dead" then
    self.co = nil
    self:_cleanup()
    if self.phase == "finish" or ACTIVE[self.phase] then self.phase = "done" end
    return false
  end
  -- time remaining: wall time per unit of work so far
  local did = self.doneWeight - (self.startDoneWeight or 0)
  if self.phase == "run" and self.totalWeight > 0 and (self.doneWeight / self.totalWeight) >= P.ETA_MIN_WEIGHT and did > 0 then
    self.etaSec = (self.totalWeight - self.doneWeight) * (self.activeS / did)
  else
    self.etaSec = -1
  end
  return true
end

function P:_saveManifestSafe()
  if self.token and self.pc and self.pc.ready then
    pcall(function()
      self.pc.store:flush(true)
      if self.dirtyManifest or self.storageFails > 0 then self:_saveManifest() end
    end)
  end
end

return P
