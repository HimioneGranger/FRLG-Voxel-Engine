-- FRLG_VOXEL Lab 60 EYE LEDGER (fixes60 item 2, DIAG.md section 2 (a) items 1, 3, 4, 5, 6).
--
-- Names what a slow world frame was doing: every GPU-side creation call is counted and timed, by a
-- PHASE label the renderer sets before each eye pass. Without it the 4.27 s first-outdoor-eye frame of Lab 58
-- looked like "shaders compiled 0" because the old counters only saw FRLG_VOXEL's own Shaders/Mip modules; the
-- real cost was the weather mod's cloud texture and shader. This counts the creation calls themselves (any mod).
--
-- Watched calls (wrapped on arm(), put back on disarm()):
--   love.graphics.newMesh / newImage / newCanvas / newShader / newArrayImage, love.image.newImageData,
--   ImageData:encode, Canvas:newImageData (the blocking GPU read-back).
-- Each call adds 1 to a counter and its wall ms to a timer, per kind and per phase. Any single call over
-- SLOW_MS (10) is logged at once with its kind, ms and phase (at most MAX_LOGS lines per session).
--
-- Zero cost when disarmed: arm() is the only thing that installs wrappers; with the ledger disarmed the love
-- functions are the originals, and setPhase / frameBegin / frameReport / heapMark / statsBegin / statsEnd return at
-- once without touching a table. Armed, the hot path (a wrapped call, setPhase, frameBegin) allocates nothing:
-- counters live in preallocated arrays; a phase's record is created the first time that phase name is seen.
--
-- Gate: nothing arms unless the gate says VRITK is installed and active. main.lua passes
-- `EL.setGate(function() return vritk:active() end)` once (VritkGate.lua provides vritk). With no gate set arm()
-- refuses, which is the Lab 58/59 behaviour (no wrappers, no lines).
--
-- API (all functions are plain calls on the module table, no self):
--   EL.setGate(fn)            fn() -> boolean. Required before arm() will do anything.
--   EL.setLog(fn)             fn(string). Receives the >10 ms lines and nothing else.
--   EL.arm() -> boolean       install the wrappers (idempotent). false if gated off / no love.graphics.
--   EL.disarm()               put the originals back (a wrapper someone else stacked on top goes inert instead).
--   EL.isArmed() -> boolean
--   EL.setPhase(name)         name is a string constant ("sky", "scene", "weatherSky", "hostLayers", ...). Cheap.
--   EL.frameBegin()           zero the per-frame counters (call once at the start of each world frame).
--   EL.frameReport() -> string|nil   nil when nothing was created this frame, else one line such as
--         "creations this frame: newShader x2 41.3 ms, newImage x1 18.0 ms | by phase: weatherSky 59.3 ms (3)"
--         Allocates a string, so call it only on a slow frame (the eye probe does).
--   EL.shaders() -> n, ms     shaders created since arm() (ALL mods, e.g. the weather cloud shader) and their ms:
--         use in place of / next to Mods.Shaders.stats in the probe's "shaders compiled" figure.
--   EL.totals() -> table      the cumulative per-kind table {name = {n=, ms=}} (a live table, read only).
--   EL.statsBegin() / EL.statsEnd() -> string|nil   love.graphics.getStats() before/after an eye; statsEnd returns
--         "gfx: textureMemory +1048576 images +1 canvases +0 shaderswitches +2 drawcalls +40" (nil if no change);
--         reuses two preallocated tables. Armed only.
--   EL.heapMark(slot) -> kb   store collectgarbage("count") in slot 1..4; EL.heapDelta(a, b) -> kb (b - a).
--   EL.reset()                zero everything (tests, session restart). Does not change armed state.
--   EL.configure(t)           test seam: {clock=, lg=, li=} replaces os-level sources (love.timer.getTime,
--         love.graphics, love.image). Call before arm().
--
-- Wiring the coordinator needs (not done here): require via V.require("perf/EyeLedger"); in the eye probe's armed
-- window (probeLines < 12) call EL.arm(), else EL.disarm(); EL.frameBegin() at the top of each world frame;
-- EL.setPhase("weatherSky") etc. beside View.lua's PASS_* samples; when a frame is slow append EL.frameReport()
-- and EL.statsEnd() to the probe line.
local V = ...
local _ = V

local EL = {}

local SLOW_MS = 10
local MAX_LOGS = 24
local KINDS = { "newMesh", "newImage", "newCanvas", "newShader", "newArrayImage", "newImageData", "encode", "canvasImageData" }
local NK = #KINDS

local gate = nil
local logFn = nil
local armed = false
local clock = nil
local lg, li = nil, nil
local phase = "?"
local logs = 0

-- preallocated counters
local fCnt, fMs, tCnt, tMs = {}, {}, {}, {}
for i = 1, NK do fCnt[i], fMs[i], tCnt[i], tMs[i] = 0, 0, 0, 0 end
local byPhase = {}  -- name -> { n, ms }  (frame totals)
local phaseOrder = {} -- names seen, for reporting (grows only on a new phase name)
local totalsView = {}
for i = 1, NK do totalsView[KINDS[i]] = { n = 0, ms = 0 } end
local shaderN, shaderMs = 0, 0
local heap = { 0, 0, 0, 0 }
local statsA, statsB, statsTmp = {}, {}, {}
local hooks = {} -- { tbl, name, orig, fn }
local classPatched = false

function EL.setGate(fn) gate = fn end
function EL.setLog(fn) logFn = fn end
function EL.isArmed() return armed end

function EL.configure(t)
  t = t or {}
  clock = t.clock or clock
  lg = t.lg or lg
  li = t.li or li
end

local function defaults()
  if not clock then clock = (love and love.timer and love.timer.getTime) or os.clock end
  if not lg then lg = love and love.graphics end
  if not li then li = love and love.image end
end

local function record(k, ms)
  fCnt[k] = fCnt[k] + 1; fMs[k] = fMs[k] + ms
  tCnt[k] = tCnt[k] + 1; tMs[k] = tMs[k] + ms
  if k == 4 then shaderN = shaderN + 1; shaderMs = shaderMs + ms end
  local p = byPhase[phase]
  if p then p[1] = p[1] + 1; p[2] = p[2] + ms end
  if ms > SLOW_MS and logs < MAX_LOGS and logFn then
    logs = logs + 1
    logFn(("eye ledger: %s took %.1f ms in phase %s"):format(KINDS[k], ms, phase))
  end
end

-- Wrap tbl[name]. The wrapper is inert (plain pass-through) once its hook is switched off.
local function wrap(tbl, name, k)
  local orig = tbl[name]
  if type(orig) ~= "function" then return end
  local hook = { tbl = tbl, name = name, orig = orig, on = true }
  local c = clock
  hook.fn = function(...)
    if not hook.on then return orig(...) end
    local t0 = c()
    local a, b, d = orig(...)
    record(k, (c() - t0) * 1000)
    return a, b, d
  end
  hooks[#hooks + 1] = hook
  tbl[name] = hook.fn
end

local function methodTable(obj)
  if obj == nil then return nil end
  local mt = getmetatable(obj)
  local idx = mt and mt.__index
  if type(idx) == "table" then return idx end
  return nil
end

function EL.arm()
  if armed then return true end
  if gate == nil or gate() ~= true then return false end
  defaults()
  if not (lg and type(lg.newShader) == "function") then return false end
  if not classPatched then
    classPatched = true -- probe objects are made once, before any wrapper exists
    if li and type(li.newImageData) == "function" then
      local ok, d = pcall(li.newImageData, 1, 1)
      local idx = ok and methodTable(d)
      if idx then EL._imageDataMethods = idx end
    end
    if type(lg.newCanvas) == "function" then
      local ok, c = pcall(lg.newCanvas, 1, 1)
      local idx = ok and methodTable(c)
      if idx then EL._canvasMethods = idx end
    end
  end
  armed = true
  wrap(lg, "newMesh", 1); wrap(lg, "newImage", 2); wrap(lg, "newCanvas", 3); wrap(lg, "newShader", 4)
  wrap(lg, "newArrayImage", 5)
  if li then wrap(li, "newImageData", 6) end
  if EL._imageDataMethods then wrap(EL._imageDataMethods, "encode", 7) end
  if EL._canvasMethods then wrap(EL._canvasMethods, "newImageData", 8) end
  return true
end

function EL.disarm()
  if not armed then return end
  armed = false
  for i = #hooks, 1, -1 do
    local h = hooks[i]
    h.on = false
    if h.tbl[h.name] == h.fn then h.tbl[h.name] = h.orig end
    hooks[i] = nil
  end
end

function EL.setPhase(name)
  if not armed then return end
  phase = name
  if not byPhase[name] then
    byPhase[name] = { 0, 0 }
    phaseOrder[#phaseOrder + 1] = name
  end
end

function EL.frameBegin()
  if not armed then return end
  for i = 1, NK do fCnt[i], fMs[i] = 0, 0 end
  for i = 1, #phaseOrder do
    local p = byPhase[phaseOrder[i]]
    p[1], p[2] = 0, 0
  end
end

function EL.frameReport()
  if not armed then return nil end
  local any = false
  for i = 1, NK do if fCnt[i] > 0 then any = true; break end end
  if not any then return nil end
  local parts = {}
  for i = 1, NK do
    if fCnt[i] > 0 then parts[#parts + 1] = ("%s x%d %.1f ms"):format(KINDS[i], fCnt[i], fMs[i]) end
  end
  local ph = {}
  for i = 1, #phaseOrder do
    local p = byPhase[phaseOrder[i]]
    if p[1] > 0 then ph[#ph + 1] = ("%s %.1f ms (%d)"):format(phaseOrder[i], p[2], p[1]) end
  end
  return "creations this frame: " .. table.concat(parts, ", ") .. " | by phase: " .. (#ph > 0 and table.concat(ph, ", ") or "-")
end

function EL.shaders() return shaderN, shaderMs end

function EL.totals()
  for i = 1, NK do
    local v = totalsView[KINDS[i]]
    v.n, v.ms = tCnt[i], tMs[i]
  end
  return totalsView
end

local function snap(into)
  local g = lg or (love and love.graphics)
  if not (g and g.getStats) then return false end
  local s = g.getStats(statsTmp)
  s = s or statsTmp
  into.textureMemory, into.images, into.canvases = s.texturememory or 0, s.images or 0, s.canvases or 0
  into.shaderswitches, into.drawcalls = s.shaderswitches or 0, s.drawcalls or 0
  return true
end

local statsOk = false
function EL.statsBegin()
  if not armed then return end
  statsOk = snap(statsA)
end

function EL.statsEnd()
  if not (armed and statsOk) then return nil end
  if not snap(statsB) then return nil end
  local dm, di, dc = statsB.textureMemory - statsA.textureMemory, statsB.images - statsA.images, statsB.canvases - statsA.canvases
  local ds, dd = statsB.shaderswitches - statsA.shaderswitches, statsB.drawcalls - statsA.drawcalls
  if dm == 0 and di == 0 and dc == 0 and ds == 0 and dd == 0 then return nil end
  return ("gfx: textureMemory %+d images %+d canvases %+d shaderswitches %+d drawcalls %+d"):format(dm, di, dc, ds, dd)
end

function EL.heapMark(slot)
  if not armed then return 0 end
  local kb = collectgarbage("count")
  heap[slot] = kb
  return kb
end
function EL.heapDelta(a, b) return heap[b] - heap[a] end

function EL.reset()
  for i = 1, NK do fCnt[i], fMs[i], tCnt[i], tMs[i] = 0, 0, 0, 0 end
  for i = 1, #phaseOrder do local p = byPhase[phaseOrder[i]]; p[1], p[2] = 0, 0 end
  shaderN, shaderMs, logs = 0, 0, 0
end

return EL
