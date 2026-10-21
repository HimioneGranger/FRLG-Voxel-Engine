-- WarmQueue: a small, game-neutral, budgeted job queue (Lab 58, approach loading B1).
--
-- Purpose: run cold, un-sliceable loads (a sheet read, an image decode) one at
-- a time in frames that have room, instead of in the frame that first needs
-- them. Nothing in here knows a game, a mod or an engine module: callers add
-- jobs, the host pumps once per frame.
--
-- Job: a table the caller owns. Fields read here:
--   run   function(job) -> true when the job has more steps and wants to run again, else nil/false (required)
--   tag   anything comparable; cancel(tag) drops every queued job carrying it
--   prio  number, higher runs first (default 0); ties run in insertion order
--   kind  string used to learn a cost estimate (EMA of measured ms) shared by all jobs of that kind
--   cost  fallback cost estimate in ms when the kind has no measurement yet (default 0)
--   key   optional; add() refuses a second queued job with the same key
--
-- Rules of pump(budgetMs, now):
--   * at most ONE job step per call (every job is one atomic call);
--   * nothing runs when the injected `blocked()` predicate is true (menu, battle, dialogue, loading);
--   * nothing runs when the frame since the previous pump took longer than slowFrameMs
--     (so a frame that a job itself blew up is followed by a quiet one);
--   * a job runs only when its cost estimate fits `budgetMs`; a job that never fits is run anyway after
--     maxWaitPumps pump calls in the queue, so it cannot starve (but never in a blocked or slow frame);
--   * an error in a job is caught with pcall, counted, remembered and the job is dropped.
-- pump() allocates nothing once the queue is warm: it returns plain numbers and calls onSlow(job, ms) by
-- reference. The only tables are the queue array and the stats table, both created by new().
local WarmQueue = {}
WarmQueue.__index = WarmQueue

WarmQueue.DEFAULTS = {
  slowFrameMs = 20,   -- a pump-to-pump gap above this skips the next pump
  slowJobMs = 8,      -- onSlow fires for a job step above this
  maxWaitPumps = 30,  -- a job that does not fit the budget runs after waiting this many pumps
  emaWeight = 0.3,    -- weight of a new measurement in a kind's cost estimate
}

local function defaultClock() return os.clock() * 1000 end

--- opts: clock (fn -> ms), blocked (fn -> truthy), onSlow (fn(job, ms)), onError (fn(job, err)),
--- slowFrameMs, slowJobMs, maxWaitPumps, emaWeight.
function WarmQueue.new(opts)
  opts = opts or {}
  local D = WarmQueue.DEFAULTS
  local self = setmetatable({
    clock = opts.clock or defaultClock,
    blocked = opts.blocked,
    onSlow = opts.onSlow,
    onError = opts.onError,
    slowFrameMs = opts.slowFrameMs or D.slowFrameMs,
    slowJobMs = opts.slowJobMs or D.slowJobMs,
    maxWaitPumps = opts.maxWaitPumps or D.maxWaitPumps,
    emaWeight = opts.emaWeight or D.emaWeight,
    jobs = {},      -- queued jobs, insertion order
    n = 0,
    seq = 0,
    kindCost = {},  -- kind -> learned ms
    lastNow = nil,
    lastError = nil,
    st = {
      added = 0, ran = 0, errors = 0, cancelled = 0, refused = 0,
      skippedBlocked = 0, skippedSlow = 0, skippedBudget = 0,
      pumps = 0, maxMs = 0, totalMs = 0, lastMs = 0,
    },
  }, WarmQueue)
  return self
end

--- Queue a job. Returns true, or false + reason (not a job / duplicate key).
function WarmQueue:add(job)
  if type(job) ~= "table" or type(job.run) ~= "function" then
    self.st.refused = self.st.refused + 1
    return false, "job needs a run function"
  end
  local key = job.key
  if key ~= nil then
    local jobs = self.jobs
    for i = 1, self.n do
      if jobs[i].key == key then
        self.st.refused = self.st.refused + 1
        return false, "duplicate key"
      end
    end
  end
  self.seq = self.seq + 1
  job._wqSeq = self.seq
  job._wqWait = 0
  local n = self.n + 1
  self.n = n
  self.jobs[n] = job
  self.st.added = self.st.added + 1
  return true
end

local function removeAt(self, i)
  local jobs, n = self.jobs, self.n
  for j = i, n - 1 do jobs[j] = jobs[j + 1] end
  jobs[n] = nil
  self.n = n - 1
end

--- Drop every queued job whose tag equals `tag`. Returns how many.
function WarmQueue:cancel(tag)
  local jobs, removed = self.jobs, 0
  local i = 1
  while i <= self.n do
    if jobs[i].tag == tag then
      removeAt(self, i)
      removed = removed + 1
    else
      i = i + 1
    end
  end
  self.st.cancelled = self.st.cancelled + removed
  return removed
end

--- Drop everything. Returns how many.
function WarmQueue:clear()
  local n = self.n
  for i = 1, n do self.jobs[i] = nil end
  self.n = 0
  self.st.cancelled = self.st.cancelled + n
  return n
end

function WarmQueue:size() return self.n end

--- Number of queued jobs carrying `tag`.
function WarmQueue:count(tag)
  local c = 0
  for i = 1, self.n do if self.jobs[i].tag == tag then c = c + 1 end end
  return c
end

--- The cost estimate (ms) that pump() would use for `job` right now.
function WarmQueue:estimate(job)
  local k = job.kind
  local c = k ~= nil and self.kindCost[k] or nil
  return c or job.cost or 0
end

-- index of the job to run, or nil. Highest prio that fits the budget; failing that the oldest job that has waited
-- long enough.
local function pick(self, budgetMs)
  local jobs, kindCost = self.jobs, self.kindCost
  local best, bestPrio, bestSeq
  local starved, starvedSeq
  local maxWait = self.maxWaitPumps
  for i = 1, self.n do
    local j = jobs[i]
    local k = j.kind
    local est = (k ~= nil and kindCost[k]) or j.cost or 0
    local prio = j.prio or 0
    if est <= budgetMs then
      if best == nil or prio > bestPrio or (prio == bestPrio and j._wqSeq < bestSeq) then
        best, bestPrio, bestSeq = i, prio, j._wqSeq
      end
    elseif j._wqWait >= maxWait then
      if starved == nil or j._wqSeq < starvedSeq then starved, starvedSeq = i, j._wqSeq end
    end
  end
  return best or starved
end

--- Run at most one job step. budgetMs: headroom the caller grants this frame. now: caller's frame clock in ms
--- (any monotonic ms clock; used only to measure the gap between pumps). Returns the number of jobs run (0 or 1).
function WarmQueue:pump(budgetMs, now)
  local st = self.st
  st.pumps = st.pumps + 1
  local last = self.lastNow
  self.lastNow = now
  if self.n == 0 then return 0 end
  -- age every waiting job (cheap, no allocation); a blocked/slow frame still counts as waiting
  local jobs = self.jobs
  for i = 1, self.n do jobs[i]._wqWait = jobs[i]._wqWait + 1 end
  local blocked = self.blocked
  if blocked and blocked() then
    st.skippedBlocked = st.skippedBlocked + 1
    return 0
  end
  if last and now and (now - last) > self.slowFrameMs then
    st.skippedSlow = st.skippedSlow + 1
    return 0
  end
  local i = pick(self, budgetMs or 0)
  if not i then
    st.skippedBudget = st.skippedBudget + 1
    return 0
  end
  local job = jobs[i]
  local clock = self.clock
  local t0 = clock()
  local ok, more = pcall(job.run, job)
  local ms = clock() - t0
  st.ran = st.ran + 1
  st.lastMs = ms
  st.totalMs = st.totalMs + ms
  if ms > st.maxMs then st.maxMs = ms end
  local kind = job.kind
  if kind ~= nil then
    local prev = self.kindCost[kind]
    if prev then
      local w = self.emaWeight
      self.kindCost[kind] = prev * (1 - w) + ms * w
    else
      self.kindCost[kind] = ms
    end
  end
  if not ok then
    st.errors = st.errors + 1
    self.lastError = more
    removeAt(self, i)
    local onError = self.onError
    if onError then pcall(onError, job, more) end
  elseif more then
    job._wqWait = 0 -- stays queued for another step
  else
    removeAt(self, i)
  end
  if ms > self.slowJobMs then
    local onSlow = self.onSlow
    if onSlow then pcall(onSlow, job, ms) end
  end
  return 1
end

--- Live counters (the same table every call; do not keep it across a reset).
function WarmQueue:stats() return self.st end

--- Zero the counters (not the queue).
function WarmQueue:resetStats()
  local st = self.st
  for k in pairs(st) do st[k] = 0 end
end

return WarmQueue
