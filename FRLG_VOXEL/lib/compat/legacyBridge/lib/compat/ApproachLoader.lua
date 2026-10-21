-- ApproachLoader (Lab 58, B2): warm the cold loads of a connected map BEFORE the player gets there.
--
-- FireRed layout ("frlg") only; any other layout installs nothing. Lives in VRITK_FRLG_HOST's compat layer, so it
-- exists only while VRITK is installed (and is inert unless ApproachLoader.ENABLED). It adds no seam to FRLG_VOXEL
-- and edits nothing in the engine or in wilds_of_hoenn.
--
-- Every SCAN_TICKS logic ticks it measures, for each Map.world neighbour, the gap (in cells) between the player cell
-- and the neighbour's rectangle. Within APPROACH_CELLS the neighbour is "active": warm jobs are queued on a
-- WarmQueue (one atomic job per frame, never in a menu/battle/dialogue/loading frame, never right after a slow
-- frame). Beyond CANCEL_CELLS (hysteresis) the neighbour's queued jobs are cancelled. The current map is warmed the
-- same way when it is entered.
--
-- Jobs (per map):
--   * NPC sheets: OwSprites.getDraw(gid) for every distinct graphics id of the map's object pool (the engine's
--     ghost pool for a neighbour, so the sheet is resident before the VR card or the flat view first draws it);
--   * art rows: after a sheet is resident, its Billboards.artRows scan runs a few rows per job step through
--     mod.find("FRLG_VOXEL").exports.warmArtRows(gid, rows) (pcall; resumable; loads nothing). Without that export
--     the job is not queued and `artRowsSkipped` counts the sheet;
--   * Wilds species: the walk and idle sheet of every species of the map's encounter table are cropped through
--     WildsAtlasCompat.warmSheet (read-only index strings, no RNG, no Wilds code called). Lab 60: when the compat has
--     a decode worker (love.thread, "compute" permission) the sheets are grouped by shard and ONE job per shard hands
--     the whole group to the worker and returns at once (the shard decodes once, off the main thread); without the
--     worker, or after a worker failure, the jobs are the per-sheet synchronous jobs of Lab 58.
-- It never calls anything that rolls the engine RNG (tableFor / national are table reads).
--
-- Diagnostics (design 3.3 and 5.1): one `[approach] jobs=.. skipped=.. maxMs=.. queue=.. neighbours=..` line per
-- 10 s, the same line plus the job on any job over SLOW_MS, an `[approach] atlas decodes=.. cropHits=..` line, and a
-- probe that times OwSprites.get / FieldEffects.loadSheet / Objects.loadMap and logs any call over SLOW_MS
-- (allocation-free unless a call is slow).
local M = {}

M.ENABLED = true
M.APPROACH_CELLS = 24
M.CANCEL_CELLS = 32
M.SCAN_TICKS = 15
M.SLOW_MS = 8
M.JOB_BUDGET_MS = 16     -- headroom handed to WarmQueue:pump (about one 72 Hz frame)
M.MIN_PUMP_GAP_MS = 8    -- at most one pump per ~frame even when several logic ticks run in one frame
M.MAX_WAIT_PUMPS = 12    -- a job bigger than the budget (a shard decode) runs after waiting this many pumps
M.ART_WAIT_TRIES = 60    -- an art-rows job whose sheet is still cold retries this many pumps, then gives up
M.ART_ROWS_STEP = 64    -- pixel rows of the art-rows scan per job step (a 16x32x10 sheet is 320 rows)
M.LOG_EVERY_S = 10
M.PROBE = true
M.MAX_PROBE_LINES = 200

local PROBES = {
  { mod = "src.core.game3.ow_sprites", fn = "get", label = "OwSprites.get" },
  { mod = "src.core.game3.field_effects", fn = "loadSheet", label = "FieldEffects.loadSheet" },
  { mod = "src.core.game3.objects", fn = "loadMap", label = "Objects.loadMap" },
}

local function defaultClock()
  if love and love.timer and love.timer.getTime then return love.timer.getTime() * 1000 end
  return os.clock() * 1000
end

--- Cells between a player cell and a rectangle [ox, ox+w) x [oy, oy+h): 0 when inside, else dx + dy.
function M.gap(px, py, ox, oy, w, h)
  local dx = ox - px
  if dx < 0 then
    dx = px - (ox + w - 1)
    if dx < 0 then dx = 0 end
  end
  local dy = oy - py
  if dy < 0 then
    dy = py - (oy + h - 1)
    if dy < 0 then dy = 0 end
  end
  return dx + dy
end
local gapOf = M.gap

--- deps: find, log, layout (fn -> "frlg"|"rse"|nil), clock (fn -> ms), engine (fn(name) -> module|nil),
--- WarmQueue (the class), wildsAtlas (WildsAtlasCompat module or nil), blocked (fn(game) -> truthy),
--- wildsActive (fn -> bool). Returns the loader, or nil + reason.
function M.install(deps)
  deps = deps or {}
  local log = deps.log or function() end
  if not M.ENABLED then return nil, "disabled" end
  local layout = deps.layout and deps.layout()
  if layout ~= "frlg" then return nil, "layout " .. tostring(layout) end
  if not deps.WarmQueue then return nil, "no WarmQueue" end
  local clock = deps.clock or defaultClock

  local engineCache = {}
  local function engine(name)
    local hit = engineCache[name]
    if hit ~= nil then return hit or nil end
    local m
    if deps.engine then
      m = deps.engine(name)
    else
      local ok, v = pcall(require, name)
      if ok and type(v) == "table" then m = v end
    end
    engineCache[name] = m or false
    return m
  end

  local self = {
    clock = clock, log = log, tick = 0, lastPumpMs = -1e9, lastLogMs = clock(), probeLines = 0,
    nb = {},            -- map id -> { active, gap, sheetsQueued, wildsQueued }
    nbActive = 0,
    doneSheet = {},     -- gid -> true
    doneArt = {},       -- gid -> true (art rows cached)
    doneWild = {},      -- dex*2 + anim -> true
    currentMap = nil, currentQueued = false,
    st = { scans = 0, queuedSheets = 0, queuedWilds = 0, cancelled = 0, activations = 0, artRowsSkipped = 0,
           slowJobs = 0, probeSlow = 0, wildsWarmed = 0, wildsMissing = 0, sheetsWarmed = 0,
           queuedArt = 0, artRowsWarmed = 0, artRowsFailed = 0, wildsSubmitted = 0, queuedWildShards = 0 },
    wrapped = {},       -- { tbl, name, orig, wrapper }
    game = nil,
    disposed = false,
  }

  local queue
  local function summary(extra)
    local qs = queue:stats()
    local skipped = qs.skippedBlocked + qs.skippedSlow + qs.skippedBudget
    return ("[approach] jobs=%d skipped=%d maxMs=%.1f queue=%d neighbours=%d%s"):format(
      qs.ran, skipped, qs.maxMs, queue:size(), self.nbActive, extra or "")
  end
  self.summary = summary

  queue = deps.WarmQueue.new({
    clock = clock,
    slowJobMs = M.SLOW_MS,
    maxWaitPumps = M.MAX_WAIT_PUMPS,
    blocked = function()
      local b = deps.blocked
      if b then return b(self.game) end
      return false
    end,
    onSlow = function(job, ms)
      self.st.slowJobs = self.st.slowJobs + 1
      log(summary((" slow=%s %.1fms"):format(tostring(job.name or job.kind), ms)))
    end,
    onError = function(job, err)
      log(("[approach] job %s failed: %s"):format(tostring(job.name or job.kind), tostring(err)))
    end,
  })
  self.queue = queue

  -- ---------------------------------------------------------------- jobs
  local function sheetRun(job)
    local OwSprites = engine("src.core.game3.ow_sprites")
    if not OwSprites then return end
    local gid = job.gid
    if self.doneSheet[gid] then return end
    local spr = OwSprites.getDraw(gid)
    self.doneSheet[gid] = true
    if spr then self.st.sheetsWarmed = self.st.sheetsWarmed + 1 end
  end

  -- FRLG_VOXEL's art-rows seam (nil when that mod or the export is absent)
  local function artSeam()
    local find = deps.find
    local m = find and find("FRLG_VOXEL")
    local ex = m and m.exports
    local fn = type(ex) == "table" and ex.warmArtRows or nil
    return type(fn) == "function" and fn or nil
  end

  -- resumable: returns true while rows remain (the queue keeps the job), false/nil when finished or not possible
  local function artRun(job)
    local gid = job.gid
    if self.doneArt[gid] then return false end
    local fn = artSeam()
    if not fn then self.st.artRowsSkipped = self.st.artRowsSkipped + 1; return false end
    local ok, done = pcall(fn, gid, M.ART_ROWS_STEP)
    if not ok then
      self.doneArt[gid] = true
      self.st.artRowsFailed = self.st.artRowsFailed + 1
      log(("[approach] art rows %s failed: %s"):format(tostring(gid), tostring(done)))
      return false
    end
    if done == false then return true end
    if done == true then
      self.doneArt[gid] = true
      self.st.artRowsWarmed = self.st.artRowsWarmed + 1
    end
    -- nil: the sheet is not resident yet (its own job is still queued); wait a bounded number of pumps
    job.tries = (job.tries or 0) + 1
    return job.tries < M.ART_WAIT_TRIES
  end

  local function wildRun(job)
    local atlas = deps.wildsAtlas
    local k = job.dex * 2 + job.anim
    if self.doneWild[k] then return end
    self.doneWild[k] = true
    if atlas and atlas.warmSheet then
      local ok = atlas.warmSheet(job.dex, job.anim, false)
      if ok then self.st.wildsWarmed = self.st.wildsWarmed + 1 else self.st.wildsMissing = self.st.wildsMissing + 1 end
    end
  end

  -- Lab 60: one job per shard. Submitting is a table insert (the worker does the decode); it returns at once. If the
  -- worker goes away meanwhile ("no worker") the rest of the group is warmed synchronously like a Lab 58 job.
  local function wildShardRun(job)
    local atlas = deps.wildsAtlas
    if not (atlas and atlas.warmSheetAsync) then return end
    local items = job.items
    for i = 1, #items do
      local it = items[i]
      local k = it.dex * 2 + it.anim
      if not self.doneWild[k] then
        self.doneWild[k] = true
        local ok, why = atlas.warmSheetAsync(it.dex, it.anim, false, job.tag)
        if ok then
          self.st.wildsSubmitted = self.st.wildsSubmitted + 1
        elseif why == "cached" then
          self.st.wildsWarmed = self.st.wildsWarmed + 1
        elseif why == "no worker" then
          local okS = atlas.warmSheet and atlas.warmSheet(it.dex, it.anim, false)
          if okS then self.st.wildsWarmed = self.st.wildsWarmed + 1 else self.st.wildsMissing = self.st.wildsMissing + 1 end
        else
          self.st.wildsMissing = self.st.wildsMissing + 1
        end
      end
    end
  end

  -- distinct graphics ids of a pool (map id -> engine Ghosts pool; the live Objects for the current map)
  local function gidsOfPool(pool, out)
    local order, byId = pool and pool.order, pool and pool.byId
    if type(order) ~= "table" or type(byId) ~= "table" then return false end
    for i = 1, #order do
      local eo = byId[order[i]]
      local gid = eo and tonumber(eo.graphicsId)
      if gid and gid > 0 and gid < 240 then out[gid] = true end
    end
    return true
  end

  local function queueSheets(mapId, pool, prio)
    local set = {}
    if not gidsOfPool(pool, set) then return false end
    local sorted = {}
    for gid in pairs(set) do sorted[#sorted + 1] = gid end
    table.sort(sorted)
    local OwSprites = engine("src.core.game3.ow_sprites")
    local loaded = OwSprites and OwSprites._loaded
    for _, gid in ipairs(sorted) do
      if not self.doneSheet[gid] and not (loaded and loaded[gid]) then
        queue:add({ run = sheetRun, tag = mapId, prio = prio + 10, kind = "ow_sheet", name = "ow_sheet:" .. gid,
                    gid = gid, cost = 14, key = "s" .. mapId .. ":" .. gid })
        self.st.queuedSheets = self.st.queuedSheets + 1
      else
        self.doneSheet[gid] = true
      end
      -- the art-rows scan follows its sheet (lower priority than every sheet job of this map)
      if not self.doneArt[gid] then
        if artSeam() then
          queue:add({ run = artRun, tag = mapId, prio = prio + 9, kind = "art_rows", name = "art_rows:" .. gid,
                      gid = gid, cost = 3, key = "a" .. mapId .. ":" .. gid })
          self.st.queuedArt = self.st.queuedArt + 1
        else
          self.st.artRowsSkipped = self.st.artRowsSkipped + 1
        end
      end
    end
    return true
  end

  local function speciesOfTable(t, out)
    if type(t) ~= "table" then return end
    for _, area in ipairs({ "land", "grass", "water" }) do
      local a = t[area]
      local slots = type(a) == "table" and (a.slots or a.mons or (#a > 0 and a)) or nil
      if type(slots) == "table" then
        for i = 1, #slots do
          local s = slots[i]
          local sp = type(s) == "table" and (s.species or s.speciesId or s[1]) or s
          sp = tonumber(sp)
          if sp then out[sp] = true end
        end
      end
    end
  end

  local function queueWilds(mapId, prio)
    local atlas = deps.wildsAtlas
    if not (atlas and atlas.installed and atlas.installed()) then return false end
    if deps.wildsActive and not deps.wildsActive() then return false end
    local Enc, Pokemon = engine("src.core.game3.encounters"), engine("src.core.game3.pokemon")
    if not (Enc and Enc.tableFor and Pokemon and Pokemon.national) then return false end
    local okT, t = pcall(Enc.tableFor, mapId)
    if not okT or type(t) ~= "table" then return true end -- no table: nothing to warm, nothing to retry
    local species = {}
    speciesOfTable(t, species)
    local dexes = {}
    for sp in pairs(species) do
      local okN, dex = pcall(Pokemon.national, sp)
      if okN and type(dex) == "number" and dex > 0 then dexes[#dexes + 1] = dex end
    end
    table.sort(dexes)
    -- group the sheets by shard so consecutive jobs share one decode (the compat keeps the last shard for a moment)
    local list = {}
    for _, dex in ipairs(dexes) do
      for anim = 1, 2 do
        if not self.doneWild[dex * 2 + anim] then
          local shard = atlas.sheetInfo and atlas.sheetInfo(dex, anim, false)
          if shard or not atlas.sheetInfo then list[#list + 1] = { dex = dex, anim = anim, shard = shard or 0 } end
        end
      end
    end
    table.sort(list, function(a, b)
      if a.anim ~= b.anim then return a.anim < b.anim end
      if a.shard ~= b.shard then return a.shard < b.shard end
      return a.dex < b.dex
    end)
    if atlas.workerAvailable and atlas.warmSheetAsync and atlas.workerAvailable() then
      -- one job per (anim, shard) group, in the same order: the worker decodes each shard once
      local g
      for _, e in ipairs(list) do
        if not g or g.anim ~= e.anim or g.shard ~= e.shard then
          g = { anim = e.anim, shard = e.shard, items = {} }
          queue:add({ run = wildShardRun, tag = mapId, prio = prio, kind = "wild_shard",
                      name = ("wildshard:%d/%d"):format(e.anim, e.shard), items = g.items, cost = 1,
                      key = ("W%s:%d:%d"):format(tostring(mapId), e.anim, e.shard) })
          self.st.queuedWildShards = self.st.queuedWildShards + 1
        end
        g.items[#g.items + 1] = { dex = e.dex, anim = e.anim }
        self.st.queuedWilds = self.st.queuedWilds + 1
      end
      return true
    end
    for _, e in ipairs(list) do
      queue:add({ run = wildRun, tag = mapId, prio = prio, kind = "wild_sheet", name = ("wild:%d/%d"):format(e.dex, e.anim),
                  dex = e.dex, anim = e.anim, cost = 40, key = "w" .. mapId .. ":" .. e.dex .. ":" .. e.anim })
      self.st.queuedWilds = self.st.queuedWilds + 1
    end
    return true
  end

  -- ---------------------------------------------------------------- distance
  local gapOf = M.gap

  local function sizeOfDef(def)
    local L = def and def.midLayout
    if L and L.width and L.height then return L.width, L.height end
    return (tonumber(def and def.width) or 0) * 2, (tonumber(def and def.height) or 0) * 2
  end

  -- ---------------------------------------------------------------- scanning
  function self:scan()
    local Map, Player, Ghosts = engine("src.core.game3.map"), engine("src.core.game3.player"), engine("src.core.game3.ghosts")
    if not (Map and Player) then return end
    self.st.scans = self.st.scans + 1
    local px, py = Player.cellX, Player.cellY
    if type(px) ~= "number" or type(py) ~= "number" then return end
    local world = Map.world
    if type(world) ~= "table" then return end
    local pools = Ghosts and Ghosts._pools
    for i = 1, #world do
      local e = world[i]
      local id = e.id
      if id ~= nil and id ~= Map.current then
        local w, h = sizeOfDef(e.def)
        local gap = gapOf(px, py, e.ox or 0, e.oy or 0, w, h)
        local st = self.nb[id]
        if not st then st = { active = false, gap = gap }; self.nb[id] = st end
        st.gap = gap
        if not st.active then
          if gap <= M.APPROACH_CELLS then
            st.active = true
            self.nbActive = self.nbActive + 1
            self.st.activations = self.st.activations + 1
            st.sheetsQueued, st.wildsQueued = false, false
          end
        elseif gap > M.CANCEL_CELLS then
          st.active = false
          self.nbActive = self.nbActive - 1
          self.st.cancelled = self.st.cancelled + queue:cancel(id)
          if deps.wildsAtlas and deps.wildsAtlas.cancel then deps.wildsAtlas.cancel(id) end
          st.sheetsQueued, st.wildsQueued = false, false
        end
        if st.active then
          local prio = 1000 - gap
          if not st.sheetsQueued and pools then
            st.sheetsQueued = queueSheets(id, pools[id], prio)
          end
          if not st.wildsQueued then st.wildsQueued = queueWilds(id, prio) end
        end
      end
    end
  end

  --- The player entered a map (map.entered): warm the current map the same way, ahead of every neighbour.
  function self:onMapEntered()
    local Map, Objects = engine("src.core.game3.map"), engine("src.core.game3.objects")
    local cur = Map and Map.current
    self.currentMap = cur
    if cur == nil then return end
    -- jobs of a map we have left are stale; the done sets keep what is already resident
    for id, st in pairs(self.nb) do
      if st.active then
        -- the map we just entered keeps the jobs already queued for it (they are the current map's now)
        if id ~= cur then
          self.st.cancelled = self.st.cancelled + queue:cancel(id)
          if deps.wildsAtlas and deps.wildsAtlas.cancel then deps.wildsAtlas.cancel(id) end
        end
        st.active = false
        self.nbActive = self.nbActive - 1
      end
      st.sheetsQueued, st.wildsQueued = false, false
    end
    local pool = Objects and { order = Objects._order, byId = Objects._byId } or nil
    queueSheets(cur, pool, 2000)
    queueWilds(cur, 2000)
  end

  local installProbes -- defined with the probe code below

  -- ---------------------------------------------------------------- per-tick entry
  function self:onTick(game)
    if self.disposed then return end
    self.game = game
    local tick = self.tick + 1
    self.tick = tick
    if tick == 1 then installProbes() end
    local now = clock()
    if now - self.lastPumpMs >= M.MIN_PUMP_GAP_MS then
      self.lastPumpMs = now
      queue:pump(M.JOB_BUDGET_MS, now)
      local atlas = deps.wildsAtlas
      if atlas and atlas.update then atlas.update(now / 1000) end
    end
    if tick % M.SCAN_TICKS == 0 then self:scan() end
    if now - self.lastLogMs >= M.LOG_EVERY_S * 1000 then
      self.lastLogMs = now
      log(summary())
      local atlas = deps.wildsAtlas
      if atlas and atlas.installed and atlas.installed() then
        local c = atlas.counter
        log(("[approach] atlas decodes=%d cropHits=%d cropMisses=%d tileMisses=%d crops=%d sentinels=%d"):format(
          c("decodes"), c("cropHits"), c("cropMisses"), c("tileMisses"), (atlas.stats() or {}).crops or 0, c("sentinels")))
        if atlas.workerState and atlas.workerState() ~= nil and c("workerJobs") > 0 then
          log(("[approach] atlas worker=%s jobs=%d crops=%d decodes=%d decodeMs=%.0f maxMs=%.0f dup=%d demandWhilePending=%d errors=%d"):format(
            tostring(atlas.workerState()), c("workerJobs"), c("workerCrops"), c("workerDecodes"), c("workerDecodeMs"),
            c("workerDecodeMaxMs"), c("workerDup"), c("demandWhilePending"), c("workerErrors")))
        end
      end
    end
  end

  -- ---------------------------------------------------------------- the wrapped-call probe (design 5.1)
  local function probeSlow(label, ms)
    self.st.probeSlow = self.st.probeSlow + 1
    if self.probeLines < M.MAX_PROBE_LINES then
      self.probeLines = self.probeLines + 1
      log(("[approach] probe %s took %.1f ms%s"):format(label, ms, queue:size() > 0 and (" (queue=" .. queue:size() .. ")") or ""))
    end
  end
  local function post(label, t0, ...)
    local dt = clock() - t0
    if dt > M.SLOW_MS then probeSlow(label, dt) end
    return ...
  end
  local function installProbe(p)
    local m = engine(p.mod)
    local orig = m and m[p.fn]
    if type(orig) ~= "function" then return end
    local label = p.label
    local function wrapper(...) return post(label, clock(), orig(...)) end
    m[p.fn] = wrapper
    self.wrapped[#self.wrapped + 1] = { tbl = m, name = p.fn, orig = orig, wrapper = wrapper }
  end
  -- installed on the first tick (the game is running then), not at mods.loaded: it must not pull engine modules early
  installProbes = function()
    if M.PROBE then for _, p in ipairs(PROBES) do pcall(installProbe, p) end end
  end

  --- Remove the probe wrappers (only if still ours), cancel everything. Safe twice.
  function self:dispose()
    if self.disposed then return end
    self.disposed = true
    for i = #self.wrapped, 1, -1 do
      local w = self.wrapped[i]
      if w.tbl[w.name] == w.wrapper then w.tbl[w.name] = w.orig end
    end
    self.wrapped = {}
    queue:clear()
  end

  function self:stats()
    local o = {}
    for k, v in pairs(self.st) do o[k] = v end
    local qs = queue:stats()
    o.ran, o.errors, o.maxMs, o.queue, o.neighbours = qs.ran, qs.errors, qs.maxMs, queue:size(), self.nbActive
    o.skippedBlocked, o.skippedSlow, o.skippedBudget = qs.skippedBlocked, qs.skippedSlow, qs.skippedBudget
    return o
  end

  log(("[approach] loader installed (approach=%d cancel=%d scanTicks=%d probe=%s atlasWarm=%s)"):format(
    M.APPROACH_CELLS, M.CANCEL_CELLS, M.SCAN_TICKS, tostring(M.PROBE), tostring(deps.wildsAtlas ~= nil)))
  return self
end

-- ------------------------------------------------------------ the VRITK_FRLG_HOST seam
--- Builds the real dependencies and returns a handle { onModsLoaded, onTick, onMapEntered, dispose, status },
--- or nil + reason. Nothing is installed (no hook, no wrap, no event) unless env.active() is true and the layout is
--- FireRed; env: mod (VRITK mod: find, events), V (VRITK loader with .require), log, layout (fn), active (fn).
function M.installForHost(env)
  env = env or {}
  local log = env.log or function() end
  if not M.ENABLED then return nil, "disabled" end
  if not (env.active and env.active()) then return nil, "VRITK not active" end
  if not (env.layout and env.layout() == "frlg") then return nil, "layout is not frlg" end
  local mod, V = env.mod, env.V
  local WarmQueue = V.require("WarmQueue")
  local h = { loader = nil, atlas = nil, installed = false }

  local function wildsActive()
    local w = mod.find("wilds_of_hoenn")
    local ex = w and w.exports
    if not (ex and type(ex.nativeProviderEnabled) == "function") then return false end
    local ok, on = pcall(ex.nativeProviderEnabled)
    return ok and on == true
  end

  local engineCache = {}
  local function engine(name)
    local hit = engineCache[name]
    if hit ~= nil then return hit or nil end
    local ok, v = pcall(require, name)
    engineCache[name] = ok and type(v) == "table" and v or false
    return engineCache[name] or nil
  end
  -- the same "something else owns the screen" tests FRLG_VOXEL uses (fieldPhase / menuOpen), read-only
  local function blocked(game)
    if not (game and game.phase == "field") then return true end
    local R = engine("src.core.game3.runtime")
    if not (R and R.isActive and R.isActive()) then return true end
    local T = engine("src.core.game3.battle_transition")
    if T and T.isActive and T.isActive() then return true end
    if R.uiBusy then local ok, busy = pcall(R.uiBusy); if ok and busy then return true end end
    local Stack = engine("src.ui.game3.stack")
    if Stack and Stack.busy then local ok, busy = pcall(Stack.busy); if ok and busy then return true end end
    local Help = engine("src.ui.game3.help_system")
    if Help and Help.isOpen then local ok, open = pcall(Help.isOpen); if ok and open then return true end end
    return false
  end

  function h.onModsLoaded()
    if h.installed then return end
    h.installed = true
    local okA, WA = pcall(V.require, "compat/WildsAtlasCompat")
    if okA and WA then
      local logged = 0
      -- the design's 5.1 probe also covers the Wilds atlas shard decode (the call that was 20-73 ms on the desktop)
      local function onDecode(file, ms)
        if ms > M.SLOW_MS and logged < M.MAX_PROBE_LINES then
          logged = logged + 1
          log(("[approach] probe atlas decode %s took %.1f ms"):format(tostring(file):match("[^/]*$") or tostring(file), ms))
        end
      end
      -- Lab 60: the decode worker's source (started with love.thread.newThread(<source>) when the manifest grants
      -- "compute"; absent permission or no thread API = the synchronous path, detected at runtime by the compat)
      local function workerSource() return mod:read("lib/compat/WildsAtlasWorker.lua") end
      local okI, ok2, why = pcall(WA.install, { find = mod.find, log = log, onDecode = onDecode, workerSource = workerSource })
      if okI and ok2 then h.atlas = WA else log("[approach] atlas crop cache not installed: " .. tostring(okI and why or ok2)) end
    end
    local loader, why = M.install({
      find = mod.find, log = log, layout = env.layout, WarmQueue = WarmQueue, wildsAtlas = h.atlas,
      blocked = blocked, wildsActive = wildsActive,
    })
    h.loader = loader
    if not loader then log("[approach] loader not installed: " .. tostring(why)) end
  end
  h.errors = 0
  local function guarded(l, fn, arg)
    local ok, err = pcall(fn, l, arg)
    if not ok then
      h.errors = h.errors + 1
      if h.errors == 1 or h.errors % 1000 == 0 then log("[approach] error (" .. h.errors .. "): " .. tostring(err)) end
    end
  end
  function h.onTick(game)
    local l = h.loader
    if l then guarded(l, l.onTick, game) elseif h.atlas then h.atlas.update() end -- keep the shard memo from lingering
  end
  function h.onMapEntered() local l = h.loader; if l then guarded(l, l.onMapEntered) end end
  function h.dispose()
    if h.loader then h.loader:dispose(); h.loader = nil end
    if h.atlas then pcall(h.atlas.uninstall); h.atlas = nil end
    h.installed = false
  end
  function h.status()
    return { loader = h.loader and h.loader:stats() or nil, atlas = h.atlas and h.atlas.stats() or nil, errors = h.errors }
  end
  if mod.events and mod.events.on then mod.events:on("map.entered", function() h.onMapEntered() end) end
  return h
end

return M
