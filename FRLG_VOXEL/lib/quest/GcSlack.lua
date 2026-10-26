-- FRLG_VOXEL: GC MODE "SLACK" (Lab 51). The Lua collector does its work only in
-- the idle time just before xrWaitFrame, never inside the frame's allocations.
--
-- Why (RESEARCH_GC_HEAP.md 1.2, RESEARCH_FRAME_LOOP.md 2.2): LuaJIT 2.1's
-- automatic collector runs inside whatever code allocates (lj_gc_check), so a
-- running cycle taxes every bucket of the frame (~2 ms) and its post-atomic
-- sweep is under-priced (a burst over 20-35 frames). This controller:
--   * keeps the automatic collector STOPPED while it owns the collector, and
--     calls "stop" again after EVERY explicit step: any LUA_GCSTEP rewrites the
--     threshold (total or total+1 KB), so a single step re-arms the automatic
--     trigger. It also re-stops once per owned frame, because other code (a full
--     "collect" at a map load) re-arms it the same way;
--   * steps in small chunks, `collectgarbage("step", CHUNK_KB)`, checking the
--     clock between chunks, within a budget sized to the measured idle time
--     (EMA of xrWaitFrame time plus the time it stepped itself), clamped to
--     MIN_MS..MAX_MS;
--   * starts a cycle explicitly only once the heap passes START_RATIO x the heap
--     right after the last cycle (no step at all below that: zero cost);
--   * above CEIL_KB steps aggressively (AGGRESSIVE_MS), and above OVERFLOW_KB
--     hands the collector back to the automatic one (stepmul restored) until the
--     cycle ends, so falling behind can never run the process out of memory;
--   * restores the automatic collector (restart + the saved stepmul) on release.
--     The owner releases on every path where the stereo frame is not running.
--
-- stepmul (STEPMUL = 50, default 200). One lj_gc_step does (1024/100)*stepmul
-- work units, so step(k) does about (k+1) x 512 units at 50: a sweep chunk of
-- ~80 objects or ~0.5 KB of mark traversal. Low stepmul keeps every indivisible
-- quantum small, so the budget is overshot by at most one small chunk (the
-- atomic phase is the one indivisible exception), at a measured call overhead of
-- ~0.5 us per step on desktop. It is also the safety factor if anything re-arms
-- the automatic trigger before our next stop: allocation-driven work then runs at
-- a quarter of the default rate. The saved stepmul is restored on every release.
--
-- Pure module: gc and clock are injected (tests drive it with a fake collector).
local M = {}
M.__index = M

M.STEPMUL = 50
M.CHUNK_KB = 1            -- step(1) = two lj_gc_step quanta at STEPMUL
M.MIN_MS = 0.5
M.MAX_MS = 2.0
M.MARGIN_MS = 0.5         -- Phase Sync moves the wake time; keep this much idle
M.EMA_ALPHA = 0.1
M.EMA_START_MS = 1.0
M.START_RATIO = 1.7
M.CEIL_KB = 600 * 1024
M.START_CEILING_FRACTION = 0.75 -- reserve headroom for normal-budget collection
M.MIN_RESTART_GROWTH_KB = 32 * 1024 -- avoid continuous cycles on large live heaps
M.AGGRESSIVE_MS = 6.0
M.OVERFLOW_KB = 768 * 1024
M.MAX_CALLS = 4096        -- hard bound on chunks per frame

local function finite(n) return type(n) == "number" and n == n and n > -math.huge and n < math.huge end

function M.new(opts)
  opts = opts or {}
  local self = setmetatable({
    gc = opts.gc or collectgarbage,
    clock = opts.clock or os.clock,
    log = opts.log,
    owned = false,            -- automatic collector stopped by us
    savedStepmul = nil,       -- the stepmul to restore on release
    cycleActive = true,       -- unknown at first: assume a cycle may be running
    postCycleKB = nil,        -- heap right after our last completed cycle
    idleEmaMs = M.EMA_START_MS,
    lastStepMs = 0,
    budgetMs = 0,
    overflow = false,         -- handed back to the automatic collector until a cycle ends
    overflowAtomic = false,   -- overflow: the automatic collector's atomic phase has run
    sentinel = setmetatable({}, { __mode = "k" }),
    win = nil,
    total = { acquires = 0, releases = 0, cycles = 0, started = 0, ceilingHits = 0, overflows = 0, rearmed = 0, errors = 0 },
  }, M)
  self.sentinel[{}] = true
  self:_newWindow()
  return self
end

function M:_newWindow()
  local w = self.win
  if not w then w = {}; self.win = w end
  w.frames, w.ownedFrames, w.stepFrames = 0, 0, 0
  w.stepSum, w.stepMax, w.budgetSum, w.chunkMax = 0, 0, 0, 0
  w.heapMin, w.heapMax = math.huge, 0
  w.cycles, w.started, w.ceilingHits, w.releases, w.acquires, w.rearmed, w.overflows = 0, 0, 0, 0, 0, 0, 0
end

local function count(self)
  local ok, kb = pcall(self.gc, "count")
  if ok and finite(kb) then return kb end
  return nil
end

-- Take the collector (automatic stopped, low stepmul). -> true when owned.
function M:acquire()
  if self.owned then return true end
  if self.overflow then return false end
  local gc = self.gc
  local okM, prev = pcall(gc, "setstepmul", M.STEPMUL)
  if not okM then self.total.errors = self.total.errors + 1; return false end
  local okS = pcall(gc, "stop")
  if not okS then
    pcall(gc, "setstepmul", finite(prev) and prev or 200)
    pcall(gc, "restart")
    self.total.errors = self.total.errors + 1
    return false
  end
  self.savedStepmul = finite(prev) and prev or 200
  self.owned = true
  -- The automatic collector ran while we did not own it: a cycle may be in
  -- progress (restart arms it at once). Continue stepping until one completes.
  -- Lab 57: right after a planned full collect (the Loading screen) no cycle is running and the baseline is clean
  self.cycleActive = not self.freshBaseline
  self.freshBaseline = nil
  self.total.acquires = self.total.acquires + 1
  self.win.acquires = self.win.acquires + 1
  return true
end

-- Give the collector back: automatic collection and the saved stepmul.
-- Safe to call at any time and any number of times. -> true if it was owned.
function M:release(reason)
  if not self.owned then return false end
  local gc = self.gc
  self.owned = false
  self.lastStepMs = 0 -- Lab 57: a released lease leaves no step time behind for later waits
  pcall(gc, "setstepmul", self.savedStepmul or 200)
  local ok = pcall(gc, "restart")
  local okR, running = pcall(gc, "isrunning")
  if not ok or (okR and running == false) then
    pcall(gc, "restart")
    self.total.errors = self.total.errors + 1
  end
  self.savedStepmul = nil
  self.total.releases = self.total.releases + 1
  self.win.releases = self.win.releases + 1
  self.lastReleaseReason = reason
  return true
end

-- Measured time the frame waited in xrWaitFrame (ms). The idle time the loop
-- had = that wait plus what we stepped ourselves just before it.
function M:noteWait(waitMs)
  if not finite(waitMs) or waitMs < 0 then return end
  local idle = waitMs + (self.lastStepMs or 0)
  -- Lab 57: the step time belongs to the ONE wait that followed it. step() resets it only on owned frames, so on
  -- menu / battle-intro / non-stereo frames (release or return before step) the last owned frame's step time was
  -- added again on every wait and the EMA crept up to ~2 ms above the real idle time. Consume it.
  self.lastStepMs = 0
  self.idleEmaMs = self.idleEmaMs + M.EMA_ALPHA * (idle - self.idleEmaMs)
end

function M:budget(heapKB)
  if heapKB and heapKB >= M.CEIL_KB then return M.AGGRESSIVE_MS end
  local b = self.idleEmaMs - M.MARGIN_MS
  if b < M.MIN_MS then b = M.MIN_MS elseif b > M.MAX_MS then b = M.MAX_MS end
  return b
end

-- A completed cycle (any source): remember the post-cycle heap.
function M:_cycleDone(kb)
  self.cycleActive = false
  kb = kb or count(self)
  -- Lab 57: a cycle that ended at the ceiling says nothing about the live heap (it is build garbage that
  -- merely had not been collected yet); keep the last full-collect baseline if there is one.
  if kb and kb >= M.CEIL_KB and self.fullBaselineKB then
    self.postCycleKB = self.fullBaselineKB
  else
    self.postCycleKB = kb
  end
  self.total.cycles = self.total.cycles + 1
  self.win.cycles = self.win.cycles + 1
end

-- Lab 57: a planned full collect ("collect" behind the Loading screen) just ran with the heap at kb: that is the
-- only heap number that is a true live baseline. No cycle is running afterwards.
function M:noteFullCollect(kb)
  if not finite(kb) then return false end
  self.fullBaselineKB = kb
  self.postCycleKB = kb
  self.cycleActive = false
  self.freshBaseline = true
  self.total.fullCollects = (self.total.fullCollects or 0) + 1
  return true
end

-- One owned frame, just before xrWaitFrame. Steps the collector within the
-- budget and leaves the automatic collector stopped. -> ms spent stepping.
function M:step()
  local w = self.win
  w.frames = w.frames + 1
  self.lastStepMs, self.lastCalls, self.lastChunkMaxMs, self.lastDone = 0, 0, 0, false
  self.budgetMs = 0
  if not self.owned then return 0 end
  w.ownedFrames = w.ownedFrames + 1
  local gc, clock = self.gc, self.clock
  -- Anything that ran a full collect or a step since our last stop re-armed the
  -- automatic trigger: count it, stop again. Only our own step's return value
  -- marks a cycle complete (a weak sentinel is cleared by the ATOMIC phase, which
  -- comes before the sweep, so it cannot tell when a cycle ends). After an external
  -- full collect we may therefore start one extra cycle: correct, just early.
  local okR, running = pcall(gc, "isrunning")
  if okR and running == true then
    self.total.rearmed = self.total.rearmed + 1
    w.rearmed = w.rearmed + 1
    pcall(gc, "stop")
  end
  local kb = count(self)
  if not kb then self.total.errors = self.total.errors + 1; return 0 end
  if kb < w.heapMin then w.heapMin = kb end
  if kb > w.heapMax then w.heapMax = kb end
  if kb >= M.OVERFLOW_KB then
    -- Far behind: let the automatic collector (default stepmul) finish the cycle.
    self.overflow = true
    self.overflowAtomic = false
    self.overflowAtCycle = self.total.cycles
    for k in pairs(self.sentinel) do self.sentinel[k] = nil end
    self.sentinel[{}] = true -- the automatic collector's next atomic phase clears it
    self.total.overflows = self.total.overflows + 1
    w.overflows = w.overflows + 1
    self:release("heap overflow")
    return 0
  end
  local ceiling = kb >= M.CEIL_KB
  if ceiling then
    self.total.ceilingHits = self.total.ceilingHits + 1
    w.ceilingHits = w.ceilingHits + 1
  end
  if not self.cycleActive then
    local post = self.postCycleKB or kb
    -- A large live baseline can put the ratio threshold above the emergency
    -- ceiling. Begin ordinary bounded work before reaching that ceiling.
    local headroomStart = math.max(M.CEIL_KB * M.START_CEILING_FRACTION, post + M.MIN_RESTART_GROWTH_KB)
    local startAt = math.min(post * M.START_RATIO, headroomStart)
    if kb < startAt and not ceiling then return 0 end -- nothing to do: no cost
    self.cycleActive = true
    self.total.started = self.total.started + 1
    w.started = w.started + 1
  end
  local budget = self:budget(kb)
  self.budgetMs = budget
  local t0 = clock()
  local limit = t0 + budget / 1000
  local calls, maxChunk, done = 0, 0, false
  repeat
    local c0 = clock()
    local ok, complete = pcall(gc, "step", M.CHUNK_KB)
    pcall(gc, "stop") -- re-stop after EVERY step: LUA_GCSTEP re-arms the trigger
    local c1 = clock()
    if c1 - c0 > maxChunk then maxChunk = c1 - c0 end
    calls = calls + 1
    if not ok then self.total.errors = self.total.errors + 1; break end
    if complete == true then done = true; break end
  until c1 >= limit or calls >= M.MAX_CALLS
  local spent = (clock() - t0) * 1000
  if done then
    local okC, after = pcall(gc, "count")
    self:_cycleDone(okC and after or nil)
  end
  self.lastStepMs, self.lastCalls, self.lastChunkMaxMs, self.lastDone = spent, calls, maxChunk * 1000, done
  w.stepFrames = w.stepFrames + 1
  w.stepSum = w.stepSum + spent
  if spent > w.stepMax then w.stepMax = spent end
  if maxChunk * 1000 > w.chunkMax then w.chunkMax = maxChunk * 1000 end
  w.budgetSum = w.budgetSum + budget
  return spent
end

-- Overflow mode ends when the automatic collector has completed a cycle (the
-- sentinel is cleared by its atomic phase). Called once per frame while not owned.
function M:pollOverflow()
  if not self.overflow then return false end
  if next(self.sentinel) == nil then
    self.sentinel[{}] = true
    self.overflowAtomic = true
  end
  if not self.overflowAtomic then return false end
  local kb = count(self)
  if not kb or kb >= M.CEIL_KB then return false end -- still sweeping a huge heap: keep it automatic
  self.overflow, self.overflowAtomic = false, false
  self.cycleActive = true -- the automatic cycle may still be sweeping: finish it by steps
  return true
end

-- One telemetry line per window; resets the window. -> string
function M:windowLine(frames)
  local w = self.win
  local n = math.max(1, w.stepFrames)
  local heapMin = w.heapMin == math.huge and 0 or w.heapMin
  local line = ("pacer gc-slack n=%d owned=%d stepFrames=%d stepMs avg=%.3f max=%.3f chunkMaxMs=%.3f budgetMs avg=%.2f idleEmaMs=%.2f heapMB min=%.1f max=%.1f postCycleMB=%.1f cycles=%d started=%d ceilingHits=%d overflows=%d releases=%d acquires=%d rearmed=%d errors=%d stepmul=%d chunkKB=%d startRatio=%.2f ceilMB=%d")
    :format(frames or w.frames, w.ownedFrames, w.stepFrames, w.stepSum / n, w.stepMax, w.chunkMax,
      w.budgetSum / n, self.idleEmaMs, heapMin / 1024, w.heapMax / 1024, (self.postCycleKB or 0) / 1024,
      w.cycles, w.started, w.ceilingHits, w.overflows, w.releases, w.acquires, w.rearmed, self.total.errors,
      M.STEPMUL, M.CHUNK_KB, M.START_RATIO, M.CEIL_KB / 1024)
  self:_newWindow()
  return line
end

return M
