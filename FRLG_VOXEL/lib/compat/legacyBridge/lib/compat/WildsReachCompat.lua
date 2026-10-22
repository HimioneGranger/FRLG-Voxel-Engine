-- VRITK_FRLG_HOST compat (FireRed / LeafGreen, Wilds of Hoenn 1.5.0 as the overworld provider): spawn-area measuring as a
-- time-sliced job, and a cached eligible-cell list. Gen-specific compat layer (user rule 2026-10-10: "all these changes need
-- to go in a compat layer that turns on with VRITK installed"). The Wilds mod and the engine are NOT edited: this file puts
-- instance overrides on the live SpawnManager / EncounterSource objects and undoes every one of them in uninstall().
--
-- Why (Lab 56 numbers): stock SpawnManager measures the reachable area with ONE flood fill of ~2,300 engine canEnter calls
-- inside a single frame, every 15 s (each canEnter is ~15 KB of garbage on FireRed because of the editor.gen3.* hook chains:
-- ~35-52 MB and ~90 ms), and stock EncounterSource:eligibleCells allocates a table per eligible cell on every call (refill asks
-- every tick).
--
-- How the flood fill is sliced. The STOCK class method SpawnManager._rebuildReach (and with it the stock Reachability.build,
-- EnginePatch.reachStart/reachMover/canEnterWhy, none of which a mod can reach) runs unchanged inside a coroutine. While a
-- slice runs, six engine functions are replaced by thin wrappers (Collision.canEnter / isWater / isWalkable / ledgeLanding /
-- nextElevation and Objects.at), put back the moment the slice ends, so the real game never sees them:
--   * the canEnter wrapper only counts (and marks "inside canEnter");
--   * the other five are SAFE POINTS: once the slice has used up its budget, the next safe point yields.
-- A safe point is always OUTSIDE EnginePatch.canEnterWhy, which sets Wilds' private `probing` flag around Collision.canEnter
-- (the Objects.blocks hook uses that flag to tell its own probe from the player's step). The coroutine is therefore NEVER
-- suspended while the flag is set; a suspension inside canEnter is impossible by construction (the wrappers are not even
-- installed while the real game runs). The budget is counted in canEnter calls and the slice is armed one call early, so on
-- foot a slice makes at most `stepsPerTick` calls (the mover starts every walking step with ledgeLanding, a safe point, and a
-- step makes at most 2 canEnter calls). While surfing the mover has no call before canEnter, so a run of consecutive
-- BLOCKED steps (no isWater call between them) can run past the budget until the next step that goes through: surfing
-- slices are therefore armed early by the longest such gap (at least 7: three blocked steps of one cell, three of the
-- next and the one that goes through; longer if the job has met a longer one). That is a performance bound only: on
-- very walled lakes a new longest gap can still pass the budget by a call or two once (see the stress test).
--
-- Bookkeeping re-implemented here (what Lab 56 added to spawn_manager.lua, with the same behaviour):
--   * keep: a re-measure starts without dropping the old area (stock _rebuildReach nils it at once; it is put back after the
--     first slice and replaced only when the new area is complete);
--   * the measure starts exactly when the old code started it (decision time, start cell read then) and then advances one
--     slice per tick from _checkReach; refill() does not spawn while the FIRST measure of a map is unfinished;
--   * the 15 s timer re-measure is off: a re-measure starts when the player is outside the measured area (or the first
--     measure of a map never came in: 60 ticks);
--   * _pruneUnreachable after completion; a map change / clearAll drops the running job;
--   * eligibleCells returns arrays cached until the cell scan or the reachable set changes (the source's own cell tables,
--     read-only for callers, zero allocation on a hit).
-- Not reachable from a mod, so assumed: Config.REACHABLE_SPAWNS stays true (if it were off the stock body measures nothing,
-- every 60 ticks, and spawning stays unrestricted; no harm, one wasted check).
--
-- New FireRed1.10.1 land placement uses the native filtered reachable view:
-- near-player3-12cell band for new/refill encounters, bounded free probes and
-- stock fallback. Distant ordinary land residents leave through native effects,
-- one at a time, so the native refill follows a continuously moving player.
-- Mod sandbox: no package, no debug. Engine modules only through pcall(require).
local M = {}

local pcall, error, type, rawget = pcall, error, type, rawget
local getmetatable, tostring = getmetatable, tostring
local cocreate, coresume, costatus, coyield = coroutine.create, coroutine.resume, coroutine.status, coroutine.yield
local function clock()
  if love and love.timer and love.timer.getTime then return love.timer.getTime() end
  return os.clock()
end

local PLAYER = "src.core.game3.player"
local COLLISION = "src.core.game3.collision"
local OBJECTS = "src.core.game3.objects"

local DEFAULT_STEPS = 32
local FIRST_MEASURE_TICKS = 60 -- stock: a map whose first measure never came in is retried after this many ticks
local EMPTY = {}
-- FireRed1.10.1: prioritize new ground encounters near the player without
-- changing encounter rolls, eligible counts or the eight-mon cap.
M.NEAR_MIN_CELLS, M.NEAR_MAX_CELLS, M.NEAR_PROBES = 3, 12, 8
M.RETIRE_CELLS, M.RETIRE_TICKS = 16, 30

local S = nil -- installed state (nil when not installed)

local function say(st, fmt, ...)
  local log = st and st.log
  if type(log) == "function" then pcall(log, fmt, ...) end
end

local function engine(name)
  local ok, m = pcall(require, name)
  if ok and type(m) == "table" then return m end
  return nil
end

--------------------------------------------------------------------------------------------------- slice wrappers

-- wrappers[i] = { tbl, name, fn, orig, on }. Built once; the table fields are only touched while a slice runs.
local function buildWrappers(st)
  local list = {}
  local Collision, Objects = engine(COLLISION), engine(OBJECTS)
  local function add(tbl, name, fn)
    if tbl and type(tbl[name]) == "function" then
      local w = { tbl = tbl, name = name, on = false }
      w.fn = fn(w)
      list[#list + 1] = w
    end
  end
  add(Collision, "canEnter", function(w)
    return function(game, tx, ty, opts, extra)
      local n = st.sliceCalls + 1
      st.sliceCalls = n
      st.totalCalls = st.totalCalls + 1
      local gap = st.gap + 1
      st.gap = gap
      -- Arm early enough that the calls still to come before the next safe point end inside the budget. On foot a gap is at
      -- most 2 calls; surfing steps have no safe point before their canEnter, so a gap is at least 7 and the longest gap
      -- seen so far in this job is used when it is longer.
      local g = st.maxGap
      if type(opts) == "table" and opts.surfing then
        if g < 7 then g = 7 end
        if gap > st.maxGap then st.maxGap = gap end
      end
      if n >= st.steps - g + 1 then st.armed = true end
      st.inCanEnter = true
      local ok, a, b, c = pcall(w.orig, game, tx, ty, opts, extra)
      st.inCanEnter = false
      if not ok then error(a, 0) end
      return a, b, c
    end
  end)
  local function safe(w)
    return function(...)
      if st.gap > st.maxGap then st.maxGap = st.gap end
      st.gap = 0
      if st.armed and not st.inCanEnter then
        st.armed = false
        coyield()
      end
      return w.orig(...)
    end
  end
  add(Collision, "isWater", safe)
  add(Collision, "isWalkable", safe)
  add(Collision, "ledgeLanding", safe)
  add(Collision, "nextElevation", safe)
  add(Objects, "at", safe)
  return list
end

local function wrapOn(st)
  local list = st.wrappers
  for i = 1, #list do
    local w = list[i]
    local cur = w.tbl[w.name]
    if type(cur) == "function" then
      w.orig = cur
      w.tbl[w.name] = w.fn
      w.on = true
    end
  end
end

local function wrapOff(st)
  local list = st.wrappers
  for i = 1, #list do
    local w = list[i]
    if w.on then
      w.tbl[w.name] = w.orig
      w.on = false
    end
  end
end

--------------------------------------------------------------------------------------------------- the job

local function cancel(st)
  local j = st.job
  if j then
    st.job = nil
    st.cancelled = st.cancelled + 1
  end
end

local function finish(st, self, j, err)
  st.job = nil
  self.reachAge = 0
  if err ~= nil then
    st.errors = st.errors + 1
    say(st, "[wilds_of_hoenn] reach job error, area left as it was: %s", tostring(err))
    if j.keep then self.reach, self.reachCount = j.oldReach, j.oldCount else self.reach, self.reachCount = nil, nil end
    self.source:setReachable(self.reach)
    return
  end
  if self.reach == nil then
    -- the stock body failed open (no start cell / mover / feature off): same as the old code's "no job" path
    if j.keep then
      self.reach, self.reachCount = j.oldReach, j.oldCount
      self.source:setReachable(self.reach)
    end
    return
  end
  st.completed = st.completed + 1
  if j.sx and self.reach[j.sy * 65536 + j.sx] ~= true then
    -- the start cell is always in the set; if it is not, the key formula below no longer matches Reachability.key
    st.keyBad = true
    say(st, "[wilds_of_hoenn] reach set key layout changed: leaving-the-area re-measure disabled")
  end
  st.lastCells, st.lastCalls, st.lastTicks = self.reachCount or 0, j.calls, j.ticks
  if j.ticks == 0 and j.calls > 2 * st.steps then
    -- nothing yielded although the fill was big: the yield seam did not match this engine
    say(st, "[wilds_of_hoenn] reach slicing found no safe point: %d canEnter calls in one tick", j.calls)
  end
  say(st, "[wilds_of_hoenn] reachable area on %s: %d cells, %d canEnter calls over %d ticks (%.0f ms wall, all work in those ticks)",
    tostring(self.mapId), self.reachCount or 0, j.calls, j.ticks, (clock() - j.t0) * 1000)
  self:_pruneUnreachable()
end

-- one resume of the job coroutine; `prime` = yield at the first safe point (start of the fill, nothing measured yet)
local function runSlice(st, self, j, prime)
  st.sliceCalls = 0
  st.gap = 0
  st.armed = prime == true
  st.inCanEnter = false
  local before = st.totalCalls
  wrapOn(st)
  local ok, err = coresume(j.co)
  wrapOff(st)
  st.inCanEnter = false
  st.armed = false
  local used = st.totalCalls - before
  j.calls = j.calls + used
  st.slices = st.slices + 1
  if st.sliceCalls > st.maxSliceCalls then st.maxSliceCalls = st.sliceCalls end
  if not ok then
    finish(st, self, j, err)
  elseif costatus(j.co) == "dead" then
    finish(st, self, j, nil)
  elseif j.keep then
    -- stock _rebuildReach nilled the area at its start; the old one stays in force until the new one is complete
    self.reach, self.reachCount = j.oldReach, j.oldCount
  end
end

local function startJob(st, self, keep)
  cancel(st)
  local rebuild = st.stockRebuild
  local j = {
    co = cocreate(function() rebuild(self) end),
    keep = keep == true and self.reach ~= nil,
    oldReach = self.reach, oldCount = self.reachCount,
    ticks = 0, calls = 0, t0 = clock(),
  }
  st.maxGap = 2
  local P = st.Player
  if P and type(P.cellX) == "number" and type(P.cellY) == "number" then j.sx, j.sy = P.cellX, P.cellY end
  st.job = j
  st.started = st.started + 1
  self.reachAge = 0
  runSlice(st, self, j, true)
end

local function stepJob(st, self)
  local j = st.job
  if not j then return false end
  j.ticks = j.ticks + 1
  runSlice(st, self, j, false)
  return true
end

-- Shared read-only local view, invalidated by native view identity or player cell.
local function nearPool(st, source, P)
  local list=source.view and source.view.land
  if type(list)~="table" then return nil end
  local c=st.nearCache
  if not c or c.list~=list or c.x~=P.cellX or c.y~=P.cellY then
    c={list=list,x=P.cellX,y=P.cellY,pool={}}
    local min2,max2=M.NEAR_MIN_CELLS^2,M.NEAR_MAX_CELLS^2
    for _,cell in ipairs(list)do
      local d2=(cell.x-c.x)^2+(cell.y-c.y)^2
      if d2>=min2 and d2<=max2 then c.pool[#c.pool+1]=cell end
    end
    st.nearCache=c;st.nearBuilds=st.nearBuilds+1
  end
  return c
end

-- Native spawning counts LEAVING entities separately from active ones. Never
-- edit either count or an entity position: the host cap still counts every live
-- entity, including a departing one, until native tick removes it.
local function refreshResidents(st, sm)
  if not st.rolling or not sm.filled or st.job then return end
  local tick = tonumber(sm.ticks)
  if not tick or tick < (st.refreshAt or 0) then return end
  st.refreshAt = tick + M.RETIRE_TICKS
  local P, patch = st.Player, st.enginePatch
  if not (P and type(P.cellX)=="number" and type(P.cellY)=="number") then return end
  for _, name in ipairs({"fieldBusy", "battleActive", "safariActive"}) do
    local ok, busy = pcall(patch[name])
    if not ok or busy then return end
  end
  if not sm.source:isEligible() then return end
  -- No local grass/free slot means retirement cannot improve nearby visibility.
  -- Do not churn distant native-fallback spawns while crossing pavement.
  local c=nearPool(st,sm.source,P)
  local free=false
  for _,cell in ipairs(c and c.pool or EMPTY)do
    if sm:_cellFree(cell.x,cell.y)then free=true;break end
  end
  if not free then return end
  local far, far2 = nil, M.RETIRE_CELLS^2
  for _, e in pairs(sm.entities or EMPTY) do
    if e.terrain=="land" and e.state=="available" and not st.protected[e]
      and not (e.engaged or e._vrCapture or e.shiny or e.roamer or e.lured or e.react
        or e.fx or e.moving or e.charging or e.chaseHome or e.runAway or e.parting
        or e.noFight or e.rare or e.legendary or e.static or e.scripted or e.isStatic
        or e.rareTier or e.rarityTier)
      and type(e.cellX)=="number" and type(e.cellY)=="number" then
      local d2=(e.cellX-P.cellX)^2+(e.cellY-P.cellY)^2
      if d2>far2 then far,far2=e,d2 end
    end
  end
  if far then
    sm:despawn(far.id, {animate=true})
    st.retired=st.retired+1
  end
end

--------------------------------------------------------------------------------------------------- install / uninstall

local function setOverride(st, obj, key, fn)
  st.overrides[#st.overrides + 1] = { obj = obj, key = key, fn = fn, own = rawget(obj, key) }
  obj[key] = fn
end

--- ctx = { spawnManager = live SpawnManager, log = function(fmt, ...), stepsPerTick = 32 }
function M.install(ctx)
  if S then
    if ctx and ctx.spawnManager == S.sm then return true, "already installed" end
    M.uninstall()
  end
  if type(ctx) ~= "table" then return false, "no context" end
  local sm = ctx.spawnManager
  if type(sm) ~= "table" then return false, "no spawn manager" end
  local source = sm.source
  if type(source) ~= "table" then return false, "spawn manager has no source" end
  local cls = getmetatable(sm)
  if type(cls) == "table" and type(cls.__index) == "table" then cls = cls.__index end
  local scls = getmetatable(source)
  if type(scls) == "table" and type(scls.__index) == "table" then scls = scls.__index end
  if type(cls) ~= "table" or type(scls) ~= "table" then return false, "no class tables" end

  if sm._stepReach ~= nil then return false, "spawn manager already measures in steps" end
  for _, k in ipairs({ "_rebuildReach", "_pruneUnreachable", "_checkReach", "clearAll", "refill" }) do
    if type(sm[k]) ~= "function" then return false, "spawn manager lacks " .. k end
  end
  if type(source.eligibleCells) ~= "function" or type(source.setReachable) ~= "function"
    or type(source.isEligible) ~= "function" then
    return false, "source lacks eligibleCells/setReachable/isEligible"
  end
  -- _rebuildReach / _checkReach / eligibleCells are replaced outright, so someone else's override would be lost
  if rawget(sm, "_rebuildReach") ~= nil or rawget(sm, "_checkReach") ~= nil then
    return false, "spawn manager reach methods already overridden"
  end
  if rawget(source, "eligibleCells") ~= nil then return false, "eligibleCells already overridden" end

  local steps = tonumber(ctx.stepsPerTick)
  if not steps or steps < 1 then steps = DEFAULT_STEPS end
  steps = math.floor(steps)

  local Player = engine(PLAYER)
  local st = {
    sm = sm, source = source, log = ctx.log, steps = steps, Player = Player,
    maxGap = 2, gap = 0,
    stockRebuild = sm._rebuildReach, prevRefill = sm.refill, prevClearAll = sm.clearAll,
    prevEligible = source.eligibleCells, shoreRange = ctx.shoreRange,
    overrides = {}, job = nil, cache = { arr = {} },
    sliceCalls = 0, totalCalls = 0, armed = false, inCanEnter = false,
    started = 0, completed = 0, cancelled = 0, errors = 0, slices = 0, maxSliceCalls = 0,
    lastCells = 0, lastCalls = 0, lastTicks = 0,
  }
  st.wrappers = buildWrappers(st)

  setOverride(st, sm, "_rebuildReach", function(self, keep)
    if S ~= st or self ~= sm then return st.stockRebuild(self) end
    startJob(st, self, keep)
  end)

  setOverride(st, sm, "_checkReach", function(self)
    if S ~= st or self ~= sm then return end
    if not self.source:isEligible() then return end
    if st.job then stepJob(st, self); return end
    self.reachAge = (self.reachAge or 0) + 1
    local px, py, moving
    local P = Player
    if P and type(P.cellX) == "number" and type(P.cellY) == "number" then
      px, py, moving = P.cellX, P.cellY, P.moving == true
    end
    if moving then return end
    local reach = self.reach
    local outside = false
    if reach and px and not st.keyBad then outside = reach[py * 65536 + px] ~= true end -- the stock set's key (Reachability.key)
    local stale = ctx.version == "1.10.1" and reach and type(self._reachStale) == "function" and self:_reachStale()
    if outside or stale or (not reach and self.reachAge >= FIRST_MEASURE_TICKS) then
      startJob(st, self, reach ~= nil)
    end
  end)

  local prevClear, prevRefill = st.prevClearAll, st.prevRefill
  setOverride(st, sm, "clearAll", function(self, ...)
    if S == st and self == sm then cancel(st);st.nearCache=nil;st.refreshAt=nil;st.protected=setmetatable({}, {__mode="k"}) end
    return prevClear(self, ...)
  end)

  setOverride(st, sm, "refill", function(self, terrain, ...)
    -- the first measure of a map is still running: never spawn outside the area
    if S == st and self == sm and st.job and not self.reach then return end
    if S == st and self == sm then refreshResidents(st, self) end
    return prevRefill(self, terrain, ...)
  end)

  -- Select only from the stock reachable land view. Water and other Wilds
  -- versions retain their original picker. Captures, shinies and engaged mons
  -- are never retired by the rolling refresh.
  local GV=engine("src.core.GameVersion")
  local okLayout,layout=false,nil
  if GV and type(GV.layout)=="function"then okLayout,layout=pcall(GV.layout)end
  if ctx.version=="1.10.1"and okLayout and layout=="frlg"and type(source.randomCell)=="function"and type(sm._cellFree)=="function"then
    local previousRandom=source.randomCell
    st.nearby=true;st.nearPicks,st.nearFallbacks,st.nearBuilds=0,0,0
    local patch=ctx.enginePatch
    st.enginePatch=patch;st.protected=setmetatable({}, {__mode="k"});st.retired=0
    st.rolling=type(patch)=="table" and type(patch.fieldBusy)=="function"
      and type(patch.battleActive)=="function" and type(patch.safariActive)=="function"
      and type(sm.despawn)=="function"
    -- Tool/script-selected spawns are not ordinary refill encounters. Keep their
    -- identity protected without adding private fields to native entities.
    if st.rolling and type(sm.spawnSpecies)=="function" then
      local prevSpecies=sm.spawnSpecies
      setOverride(st,sm,"spawnSpecies",function(self,...)
        local first=self.nextId or 0
        local a,b=prevSpecies(self,...)
        if S==st and self==sm then
          for id=first,(self.nextId or first)-1 do
            local e=self.entities[id];if e then st.protected[e]=true end
          end
        end
        return a,b
      end)
    end
    setOverride(st,source,"randomCell",function(self,terrain,rng)
      local P=st.Player
      local list=self.view and self.view.land
      if S~=st or self~=source or terrain~="land"or not(P and type(P.cellX)=="number"and type(P.cellY)=="number")or type(list)~="table"then
        return previousRandom(self,terrain,rng)
      end
      local c=nearPool(st,self,P)
      local n=#c.pool
      if n>0 then
        local pick=rng or math.random
        for _=1,math.min(n,M.NEAR_PROBES)do
          local cell=c.pool[pick(1,n)]
          -- Existing _cellFree owns occupancy and the player's current/next
          -- tile. Recheck on every pick; never cache occupancy between ticks.
          if sm:_cellFree(cell.x,cell.y)then st.nearPicks=st.nearPicks+1;return cell end
        end
      end
      -- Empty/full local grass must not starve the ordinary native refill.
      st.nearFallbacks=st.nearFallbacks+1
      return previousRandom(self,terrain,rng)
    end)
  end

  -- 1.10.1 already owns a cached view used directly by randomCell/refill.
  -- Preserve that view and its unrestricted ambient-water eligibility.
  local prevEligible = st.prevEligible
  if ctx.version ~= "1.10.1" then
  setOverride(st, source, "eligibleCells", function(self, terrain)
    if S ~= st or self ~= st.source then return prevEligible(self, terrain) end
    local list = self.cells and self.cells[terrain]
    if not list then return EMPTY end
    local c = st.cache
    local range = st.shoreRange and st.shoreRange() or nil
    if c.cells ~= self.cells or c.reach ~= self.reachable or c.shore ~= self.shore or c.range ~= range then
      c.cells, c.reach, c.shore, c.range, c.arr = self.cells, self.reachable, self.shore, range, {}
    end
    local hit = c.arr[terrain]
    if hit then return hit end
    -- build once per (cell scan, reachable set): the stock call decides which cells qualify, then the source's own cell
    -- tables are handed out instead of its copies
    local fresh = prevEligible(self, terrain)
    local out, j = {}, 1
    for i = 1, #list do
      local cell, f = list[i], fresh[j]
      if f and f.x == cell.x and f.y == cell.y then out[j] = cell; j = j + 1 end
    end
    if #out ~= #fresh then out = fresh end
    c.arr[terrain] = out
    return out
  end)

  end

  S = st
  return true, "installed (" .. steps .. " canEnter calls per tick)"
end

--- Removes every instance override (the field goes back to what it was before, nil when the class method shows through).
--- An override someone wrapped on top of is left in place and reported.
function M.uninstall()
  local st = S
  if not st then return true, "not installed" end
  S = nil
  st.job = nil
  wrapOff(st)
  local left = {}
  for i = #st.overrides, 1, -1 do
    local o = st.overrides[i]
    if rawget(o.obj, o.key) == o.fn then
      o.obj[o.key] = o.own
    else
      left[#left + 1] = o.key
    end
  end
  if #left > 0 then return true, "left in place (wrapped by others, now inert): " .. table.concat(left, ",") end
  return true, "uninstalled"
end

function M.status()
  local st = S
  if not st then return { installed = false } end
  local j = st.job
  return {
    installed = true, stepsPerTick = st.steps, maxGap = st.maxGap,
    jobActive = j ~= nil, jobTicks = j and j.ticks or 0, jobCalls = j and j.calls or 0, jobKeep = j and j.keep or false,
    started = st.started, completed = st.completed, cancelled = st.cancelled, errors = st.errors,
    slices = st.slices, maxSliceCalls = st.maxSliceCalls, totalCalls = st.totalCalls,
    lastCells = st.lastCells, lastCalls = st.lastCalls, lastTicks = st.lastTicks,
    rolling = st.rolling == true, retired = st.retired or 0,
    nearby = st.nearby == true, nearPicks = st.nearPicks or 0, nearFallbacks = st.nearFallbacks or 0, nearBuilds = st.nearBuilds or 0,
  }
end

return M
