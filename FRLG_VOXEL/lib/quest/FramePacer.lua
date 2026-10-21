-- FRLG_VOXEL: FramePacer (Lab 8 P0-1 fix 1e, 2026-09-29). A per-frame
-- split of where the time goes, so the next headset session can name the
-- subsystem behind a stall instead of guessing (triage CHECK.md item 2: the
-- old timing line, main.lua "timing n=...", covers the eye pass only, while
-- at least 300 ms of each 350-460 ms headset stall was outside it).
--
-- One frame = from one game update to the next (the engine calls
-- Game:update once per displayed frame). Timed parts, all disjoint:
--   update   the game's own update (logic, audio, other mods' update hooks)
--   pump     View:pump, the map build slices (Scene.pump)
--   wait     xrWaitFrame (Quest only; idle time while the headset paces us)
--   prepare  View:prepare (camera, visible maps, billboards, sky)
--   layers   HostApi beginFrame + updateLayers (VRITK and other layers)
--   eyes     View:renderEye, both eyes (world, sprites, layers, card)
--   submit   eye blits + xrEndFrame (+ the panel quad) (Quest only)
--   gc       explicit collector steps taken by this module (fix 1d, gcPace;
--            0 while it is off, the default -- Gen 3's Game3:update has NO
--            collector step of its own, unlike Gen 1/2's Game.lua:451)
--   other    the rest of the frame (engine draw, compose, present, ...)
-- Every LOG_FRAMES frames it logs one line: frame avg/p50/p99/max, slow
-- (> SLOW_MS) and hitch (> HITCH_MS) counts, the average split, heap MB
-- (min/max), heap growth per frame (a lower bound on allocation: frees
-- inside a frame hide some of it), completed collector cycles, and the full
-- split of the slowest frame.
--
-- Debug: pauseGC(seconds) measures a BASE window of the same length with the
-- collector running, then stops the collector for `seconds` (ending early if
-- the heap grows GC_PAUSE_HEAP_MB) and logs both windows side by side. If
-- the stalls improve while it is stopped, the collector contributes; the
-- split and matched headset runs are needed to identify other causes.
-- Experiment-only heap deltas at wrapper seams are inclusive (nested calls
-- overlap). BASE is net heap movement while GC runs, never allocated bytes.
-- STOPPED removes automatic collection but still reports heap deltas, not
-- GPU allocations. Triggered by the optional options
-- toggle (opts.option, rising edge) or exports.framePacer.pauseGC().
--
-- Installed by one line in main.lua (see the Lab 8 patch doc); everything
-- else is instance-level wrapping of this renderer's own objects plus the
-- game instance's update. Wrappers never catch errors (the original
-- behaviour, including any error, passes straight through), allocate nothing
-- per call, and pass results through as varargs.
local V = ...
local _ = V

local FramePacer = {}
FramePacer.__index = FramePacer

FramePacer.LOG_FRAMES = 300     -- one summary line per this many frames
FramePacer.SLOW_MS = 20
FramePacer.HITCH_MS = 50
FramePacer.GC_PAUSE_S = 10
FramePacer.GC_PAUSE_HEAP_MB = 384
FramePacer.OPTION_POLL = 30     -- frames between option polls
FramePacer.GC_STEP_MS = 0       -- fix 1d budget per frame (0 = off; see gcPace)
FramePacer.GC_STEP_KB = 0       -- LuaJIT minimum request; budget/lifecycle unchanged
-- Lab 51: GC MODE SLACK (lib/quest/GcSlack.lua). The engine's outer loop keeps a
-- watchdog over the lease this pacer renews on every owned frame: a lease not
-- renewed for SLACK_LEASE_ITERATIONS loop iterations gets the automatic
-- collector back even when this mod's own code no longer runs (mod disabled,
-- an error in a path the release calls below do not cover).
FramePacer.SLACK_LEASE_ITERATIONS = 2
-- Lab 51 heap seams (GC PAUSE TEST only; installed when the test starts, so
-- they cost nothing in normal play). Inclusive; nested seams overlap.
local SEAM51_KEYS = { "seamHands", "seamDevice", "seamBackpackEye", "seamWearable", "seamPouch", "seamBelt",
  "seamXrInput", "seamXrPoll", "seamXrLocate", "seamCompose", "seamHud", "seamUntamedField" }
FramePacer.SEAM51_KEYS = SEAM51_KEYS

local PARTS = { "update", "pump", "wait", "prepare", "layers", "eyes", "submit", "gc" }
FramePacer.PARTS = PARTS
-- Heap sub-seams are inclusive and deliberately absent from PARTS: adding
-- their times would double-count the existing disjoint update/layers split.
local HEAP_KEYS = { "update", "pump", "wait", "prepare", "layers", "eyes", "submit", "gc",
  "hostBeginFrame", "hostUpdateLayers", "fixedUpdate", "nativeRuntime", "audioUpdate", "inputStep", "sceneDraw", "hostDrawEye", "stereoUpdate" }
FramePacer.HEAP_KEYS = HEAP_KEYS
local HOST_HEAP_KEYS = { "sceneDraw", "hostDrawEye", "stereoUpdate" }
local CATCH_KEYS = { "catchRefreshTargets", "catchVtiInput", "catchTailStep",
  "catchBattleFxStep", "catchSendOutTick", "catchPollChain" }

local CPU_LAYER_KEYS = { "FRLG_CATCH.ball", "VRITK_FRLG_HOST.bridge",
  "fixedUpdate", "nativeRuntime", "audioUpdate", "inputStep",
  "fieldUpdate", "hudUpdate", "taskUpdate", "fieldWeatherUpdate",
  "drainDeferred", "tilesetStep", "compatWorldTick",
  "displayPresent", "fieldDraw", "gameHud", "renderCompose",
  "stereoUpdate", "sceneDraw", "hostDrawEye",
  "tabletGen3Refresh", "tabletTools", "watchMapDraw", "watchMapCopy",
  "rtcNightScan", "fieldResolve", "fieldTiles", "fieldBelow", "fieldActors", "fieldOverTiles", "fieldAbove" }
local FIELD_INNER_KEYS = { "fieldResolve", "fieldTiles", "fieldBelow", "fieldActors", "fieldOverTiles", "fieldAbove" }
local CPU_INNER_SPECS = {
  { "displayPresent", "src.core.game3.display", "present" },
  { "fieldDraw", "src.core.game3.field_view", "draw" },
  { "fieldUpdate", "src.core.game3.field", "update" },
  { "hudUpdate", "src.ui.game3.hud", "update" },
  { "taskUpdate", "src.core.game3.task", "update" },
  { "fieldWeatherUpdate", "src.core.game3.field_weather", "update" },
  { "drainDeferred", "src.core.game3.runtime", "drainDeferred" },
  { "tilesetStep", "src.core.game3.tileset_anim", "step" },
  { "compatWorldTick", "src.mods.Gen3Compat", "worldTick" },
}

-- Lab 55 (G0): per-pass eye timers. View.renderBody / Scene:draw call the
-- observer (renderer.view._pacerPass, renderer.scene._pacerPass) around each
-- pass of one eye: two clock reads and scalar adds into preallocated arrays,
-- no tables, no closures per call. Inclusive; "scene" contains "grass".
local PASS_KEYS = { "sky", "sea", "scene", "grass", "healer", "blobs", "cards", "weatherSky", "battle",
  "hostLayers", "weatherLate", "uiCard" }
FramePacer.PASS_KEYS = PASS_KEYS
FramePacer.PASS = {}
for i = 1, #PASS_KEYS do FramePacer.PASS[PASS_KEYS[i]] = i end

local OUTER_KEYS = { "events","preGameUpdate", "draw", "presentWait", "present", "postPresent", "capYield", "graphicsSetup", "frameDrawn" }

local getTime = (love and love.timer and love.timer.getTime) or os.clock
local gcount = collectgarbage

-- Preallocated chronological records are independent of walls, which the
-- existing percentile report sorts in place. -1 means missing, never zero work.
local CHRONO_LIMIT, CHRONO_LINE_BYTES = 300, 3000
local CHRONO_FIELDS = "frame,wallMs,atomicObserved,nativeRebuilds,combinedWaitMs,xrWaitMs,xrBeginMs,waitAttempts,waitCompleted,beginAttempts,beginCompleted,xrErrors,predictedDeltaMs,predictedPeriodMs,gcMs,gcAttempts,gcCompleted,gcMaxStepMs,gcCyclesComplete,gcBudgetMs,pauseStage,diagnosticReportMs,scopePhase,scopeCalls,scopeSpanMs,scopeStopAttempts,scopeStopOK,scopeRestartAttempts,scopeRestartOK,scopeEntryRunning,scopeDuringRunning,scopeExitRunning,scopeRenderOK,scopeHeapDeltaKiB"
local active = nil -- the pacer of the live renderer (module state: V.require caches this file)

-- ------------------------------------------------------------ helpers
local function newParts()
  local t = {}
  for i = 1, #PARTS do t[PARTS[i]] = 0 end
  return t
end

local function newWindow()
  return { n = 0, sum = 0, max = 0, slow = 0, slowCycled = 0, hitch = 0, cycles = 0, heapMin = math.huge,
           heapMax = 0, grow = 0, t0 = nil, parts = newParts() }
end
local function newHeapParts(keys)
  keys = keys or HEAP_KEYS
  local t = {}
  for i = 1, #keys do t[keys[i]] = 0 end
  return t
end

local function ms(x) return ("%.1f"):format((x or 0) * 1000) end

-- ------------------------------------------------------------ construction
local function collectorMRInactive(mr)
  return mr==nil or (type(mr)=="table" and rawget(mr,"frozen")==false and rawget(mr,"presented")==false and rawget(mr,"hold")==false)
end
function FramePacer.new(opts)
  opts = opts or {}
  local self = setmetatable({
    log = opts.log or print,
    option = opts.option,          -- fn() -> truthy while the debug GC-pause option is ON
    renderOption = opts.renderOption, renderOptionWas = nil, collectorMod = opts.collectorMod,
    collector = nil, collectorInvalid = false, collectorScene = nil, collectorRoot = nil,
    stepOption = opts.stepOption,  -- fn() -> fix 1d budget in ms ("0" = off), optional
    flatRate = opts.flatRate,      -- Lab 49: fn() -> drawn, skipped, fallbacks, gateErrors, rate (resets), optional
    cur = newParts(),              -- this frame's parts (seconds)
    frameT0 = nil, frameNo = 0,
    heapKB = nil,
    walls = {},                    -- frame times of this log window (reused)
    win = newWindow(),
    slowest = { wall = 0, frame = 0, parts = newParts() },
    sentinel = setmetatable({}, { __mode = "k" }),
    cyclesTotal = 0,
    xrRegistry=nil, xrPrevious=nil, xrRecords={}, chronology={}, chronoParts={},
    reportPending=0, reportCostCurrent=0,
    gcAttempts=0, gcCompleted=0, gcMaxStep=0, gcCyclesComplete=0,
    optionWas = nil,
    pause = nil,                   -- GC pause experiment state
    gcStepMs = opts.gcStepMs,      -- fix 1d budget override (nil = FramePacer.GC_STEP_MS)
    gcPaceAtFrameStart = opts.gcPaceAtFrameStart, -- desktop test: pace at the frame start
    last = nil,                    -- last logged window (plain data, for drivers/tests)
    wrapped = {},                  -- { obj, key, raw } to undo
    outerRecords = {}, outerRegistry = nil, outerPrevious = nil, outerObserver = nil,
    outerPendingTime = nil, outerPendingToken = nil,
    fieldInnerRegistry=nil, fieldInnerPrevious=nil, fieldInnerObserver=nil, fieldNativeToken=nil,
    cpuById = {}, cpuRegistry = nil, cpuPreviousObserver = nil, cpuObserver = nil,
    cpuEnabled = true, cpuSources = {}, cpuInstalled = {}, cpuInnerResolved = false,
    renderer=nil, hostCpuResolved=false, hostBridge=nil, hostBridgeLib=nil, hostBridgeRequire=nil,
    tabletRegistry=nil,tabletPrevious=nil,tabletObserver=nil,
    probeModules = {}, probeGame = nil, probeResolved = false,
    catchProbeResolved=false, catchProbeReady=false,
    heapKeys = {}, inputHooks = {}, inputHooksDiscovered = false, inputHookBus = nil,
    probeReady = { fixedUpdate=false, nativeRuntime=false, audioUpdate=false, inputStep=false },
    -- Lab 51: "off" | "pace" (GC PACING 0.5/1 MS) | "slack" (GcSlack)
    gcMode = "off", slack = opts.gcSlack, slackWant = false, slackLeaseRec = nil,
    seam51Installed = false, seam51Ready = {},
  }, FramePacer)
  for i = 1, #HEAP_KEYS do self.heapKeys[i] = HEAP_KEYS[i] end
  for i = 1, #CPU_LAYER_KEYS do
    self.cpuById[CPU_LAYER_KEYS[i]] = { cur=0, calls=0, errors=0,
      total=0, totalCalls=0, totalErrors=0, maxCall=0,
      maxFrame=0, maxFrameNo=0, maxFrameCycle=false, maxFrameCalls=0,
      slow=0, slowCycle=0, slowest=0, slowestCalls=0 }
  end
  local tiles = self.cpuById.fieldTiles
  tiles.curRebuilds, tiles.curCached, tiles.totalRebuilds, tiles.totalCached = 0, 0, 0, 0
  tiles.maxFrameRebuilds, tiles.maxFrameCached, tiles.slowestRebuilds, tiles.slowestCached = 0, 0, 0, 0
  self.fieldInnerObserver = {
    begin = function(id)
      local key = FIELD_INNER_KEYS[id]
      if not self:_fieldInnerOwned() or not key then return end
      if id == 2 then self.fieldNativeToken = self.frameNo end
      return self.cpuObserver.clock(key)
    end,
    finish = function(id, t0, token)
      if not self:_fieldInnerOwned() then return end
      local key = FIELD_INNER_KEYS[id]
      if key then self.cpuObserver.sample(key, t0, token, true) end
      if id == 2 and self.fieldNativeToken == token then self.fieldNativeToken = nil end
    end,
    native = function(rebuilt, token)
      if not self:_fieldInnerOwned() or token ~= self.frameNo or self.fieldNativeToken ~= token then return end
      local record = self.cpuById.fieldTiles
      if rebuilt then record.curRebuilds=record.curRebuilds+1 else record.curCached=record.curCached+1 end
    end,
  }
  self.cpuObserver = {
    clock = function(id)
      if self.cpuEnabled and self.frameT0 and self.cpuById[id] then return getTime(), self.frameNo end
    end,
    sample = function(id, t0, token, ok)
      if not self.cpuEnabled or token ~= self.frameNo then return end
      local record = self.cpuById[id]
      if not record then return end
      local elapsed = getTime() - t0
      record.cur = record.cur + elapsed
      record.calls = record.calls + 1
      if not ok then record.errors = record.errors + 1 end
      if elapsed > record.maxCall then record.maxCall = elapsed end
    end,
  }
  -- Lab 55 (G0): pass records, one number array per field
  local pCur, pCalls, pTotal, pTotalCalls, pMaxCall, pMaxFrame = {}, {}, {}, {}, {}, {}
  for i = 1, #PASS_KEYS do
    pCur[i], pCalls[i], pTotal[i], pTotalCalls[i], pMaxCall[i], pMaxFrame[i] = 0, 0, 0, 0, 0, 0
  end
  self.pass = { cur = pCur, calls = pCalls, total = pTotal, totalCalls = pTotalCalls, maxCall = pMaxCall,
    maxFrame = pMaxFrame, frames = 0, eyes = 0 }
  self.passObserver = {
    clock = function()
      if self.cpuEnabled and self.frameT0 then return getTime() end
    end,
    sample = function(i, t0)
      local e = getTime() - t0
      pCur[i] = pCur[i] + e
      pCalls[i] = pCalls[i] + 1
      if e > pMaxCall[i] then pMaxCall[i] = e end
    end,
  }
  for i = 1, #OUTER_KEYS do
    self.outerRecords[i] = { cur=0, calls=0, total=0, totalCalls=0,
      maxFrame=0, maxFrameNo=0, maxFrameCalls=0, maxFrameCycle=false, slowest=0, slowestCalls=0 }
  end
  self.outerObserver = {
    begin = function(id)
      if not self.cpuEnabled or not self.frameT0 or not self.outerRecords[id] then return end
      local now = getTime()
      if id == 2 then self.outerPendingTime, self.outerPendingToken = now, self.frameNo end
      return now, self.frameNo
    end,
    finish = function(id, t0, token)
      self:_outerSample(id, t0, token, getTime())
    end,
    abandon = function(token)
      if self.outerPendingToken == token then self.outerPendingTime, self.outerPendingToken = nil, nil end
    end,
  }
  self.tabletObserver={
    clock=function(key)
      if self:_tabletOwned() then return self.cpuObserver.clock(key) end
    end,
    sample=function(key,t0,token,ok)
      if self:_tabletOwned() and t0 and token==self.frameNo and self.cpuById[key] then
        self.cpuObserver.sample(key,t0,token,ok);return true
      end
    end,
  }
  self.rtcCounts={attempts=0,completed=0,scanned=0,slots=0,transitions=0,under=0,over=0,dirty=0,lastFrame=0}
  self.rtcObserver={
    clock=function()
      if not self:_rtcOwned() then return end
      local t,token=self.cpuObserver.clock("rtcNightScan")
      if t then self.rtcCounts.attempts=self.rtcCounts.attempts+1 end
      return t,token
    end,
    sample=function(t,token,scanned,slots,transitions,under,over,dirty)
      if not self:_rtcOwned() or not t or token~=self.frameNo then return end
      self.cpuObserver.sample("rtcNightScan",t,token,true)
      local c=self.rtcCounts;c.completed=c.completed+1;c.scanned=c.scanned+scanned;c.slots=c.slots+slots
      c.transitions=c.transitions+transitions;c.under=c.under+under;c.over=c.over+over;c.dirty=c.dirty+dirty;c.lastFrame=token
      return true
    end,
  }
  for i=1,2 do self.xrRecords[i]={attempts=0,completed=0,errors=0,elapsed=0,delta=-1,period=-1} end
  for i=1,CHRONO_LIMIT do
    local row={};for j=1,34 do row[j]=0 end;self.chronology[i]=row
  end
  self.xrObserver={
    clock=function(id)
      if not self:_xrOwned() or not self.xrRecords[id] then return end
      local r=self.xrRecords[id];r.attempts=r.attempts+1
      return getTime(),self.frameNo
    end,
    sample=function(id,t0,token,code,delta,period)
      if not self:_xrOwned() or token~=self.frameNo or not self.xrRecords[id] then return false end
      local r=self.xrRecords[id]
      r.completed=r.completed+1;r.elapsed=r.elapsed+getTime()-t0
      if code~=0 then r.errors=r.errors+1 end
      if id==1 and code==0 then r.delta,r.period=delta,period end
      return true
    end,
  }
  self:_bindOuterTiming()
  self:_bindXrTiming()
  self:_bindTabletTiming()
  self:_bindRtcTiming()
  self.sentinel[{}] = true
  -- Optional only: ordinary owners never require the experiment module.
  if self.renderOption and type(V)=="table" and type(V.require)=="function" then
    local ok,M=pcall(V.require,"quest/CollectorExperiment")
    if ok and type(M)=="table" and type(M.new)=="function" then
      local made,scope=pcall(M.new,{clock=getTime,gc=gcount,log=function(reason,phase,span,heap)
        self.log(("pacer gc-render-scope edge frame=%d phase=%s reason=%s spanOrTime=%s heapDeltaKiB=%s budget=%s quantum=%d caps=384MiB,+32MiB settle=2s phases=8s deadline=45s")
          :format(self.frameNo,tostring(phase),tostring(reason),tostring(span),tostring(heap),tostring(self.gcStepMs or FramePacer.GC_STEP_MS),FramePacer.GC_STEP_KB))
      end})
      if made and type(scope)=="table" then scope.mrInactive=collectorMRInactive;self.collector=scope end
    end
  end
  return self
end

-- Actual tablet update/draw wrappers own these readiness scalars.
local function collectorTabletClosed(mod)
  if type(mod)~="table" or type(mod.find)~="function" then return false end
  local host=mod.find("VRITK_FRLG_HOST")
  if host==nil then return true end
  if type(host)~="table" or type(host.exports)~="table" then return false end
  local compat=host.exports.compat
  local tablet=type(compat)=="table" and compat.tablet
  if type(tablet)~="table" or type(tablet.active)~="function" or type(tablet.presented)~="function" then return false end
  return not tablet.active() and not tablet.presented()
end
function FramePacer:cancelCollector(reason)
  local scope=self.collector
  if not scope or (scope.stage==0 and not scope.lease) then return end
  self.collectorInvalid=true
  scope:cancel(reason or "cancelled")
end
function FramePacer:collectorBeforeFrame(eligible,scene,root,mr)
  local scope=self.collector
  if not scope or scope.stage==0 then return nil end
  local ok,closed=pcall(collectorTabletClosed,self.collectorMod)
  eligible=eligible==true and ok and closed==true and type(scene)=="table" and root~=nil and collectorMRInactive(mr)
  if self.collectorScene~=scene or self.collectorRoot~=root then
    if scope.stage>=2 then self:cancelCollector("world identity changed")
    else scope.settleAt,scope.identity=nil,nil end
    self.collectorScene,self.collectorRoot=scene,root
  end
  scope:frame(eligible,self.gcStepMs or FramePacer.GC_STEP_MS,self.pause~=nil,scene,self.frameNo)
  if scope.stage==0 then return nil end
  return scope
end
function FramePacer:collectorAfterFrame(eligible,scene,root,hardFailure,mr)
  local scope=self.collector
  if not scope or scope.stage==0 then return end
  local ok,closed=pcall(collectorTabletClosed,self.collectorMod)
  if hardFailure or eligible~=true or not ok or closed~=true or not collectorMRInactive(mr) or scene~=self.collectorScene or root~=self.collectorRoot then
    if scope.stage==1 and not hardFailure then scope.settleAt,scope.identity=nil,nil
    else self:cancelCollector("XR world/eligibility lost") end
  end
end

function FramePacer:_xrOwned()
  local r=self.xrRegistry
  return self.cpuEnabled and self.frameT0~=nil and type(r)=="table"
    and r==(love and love._pacerOuterLoop) and r.xrObserver==self.xrObserver
end
function FramePacer:_bindXrTiming()
  local r=love and love._pacerOuterLoop
  if r==self.xrRegistry then return end
  local old=self.xrRegistry
  if old and old.xrObserver==self.xrObserver then old.xrObserver=self.xrPrevious end
  self.xrRegistry,self.xrPrevious=nil,nil
  if type(r)=="table" then
    self.xrRegistry,self.xrPrevious=r,r.xrObserver;r.xrObserver=self.xrObserver
  end
end
function FramePacer:_recordChronology(index,wall,atomicObserved)
  if not self.cpuEnabled then return end
  local row=self.chronology[index]
  if not row then return end -- LOG_FRAMES overrides cannot grow this buffer.
  local w,b=self.xrRecords[1],self.xrRecords[2]
  row[1],row[2],row[3]=self.frameNo,wall*1000,atomicObserved and 1 or 0
  row[4],row[5]=self:_fieldInnerOwned() and self.cpuById.fieldTiles.curRebuilds or -1,self.cur.wait*1000
  row[6]=w.completed>0 and w.elapsed*1000 or -1
  row[7]=b.completed>0 and b.elapsed*1000 or -1
  row[8],row[9],row[10],row[11],row[12]=w.attempts,w.completed,b.attempts,b.completed,w.errors+b.errors
  row[13],row[14]=w.delta,w.period
  row[15],row[16],row[17],row[18],row[19]=self.cur.gc*1000,self.gcAttempts,self.gcCompleted,self.gcMaxStep*1000,self.gcCyclesComplete
  row[20]=(self.gcMode=="slack" and self.slack and self.slack.budgetMs) or (self.gcStepMs or FramePacer.GC_STEP_MS) -- Lab 51: SLACK budget
  row[21]=not self.pause and 0 or (self.pause.stage=="stopped" and 2 or 1)
  row[22]=self.reportCostCurrent*1000
  local scope=self.collector
  local valid=scope and not self.collectorInvalid and scope.recordValid==true and scope.callFrameToken==self.frameNo
  row[23]=scope and (scope.calls>0 and scope.callStage or ((self.collectorInvalid or (scope.stage==0 and scope.callStage>=2 and scope.reason~="complete")) and 5 or scope.stage)) or 0
  row[24]=valid and scope.calls or 0
  row[25]=valid and scope.spanMs or -1
  row[26],row[27]=scope and scope.stopAttempts or 0,scope and scope.stopOK or 0
  row[28],row[29]=scope and scope.restartAttempts or 0,scope and scope.restartOK or 0
  row[30],row[31],row[32]=scope and scope.entryRunning or -1,scope and scope.duringRunning or -1,scope and scope.exitRunning or -1
  row[33]=valid and scope.renderOK or -1
  row[34]=valid and scope.heapDeltaKiB or -1
end
function FramePacer:_logChronology(n)
  if not self.cpuEnabled then return end
  local count=math.min(n,CHRONO_LIMIT)
  self.log("pacer chronology v=2 rows="..count.." omitted="..math.max(0,n-count)
    .." missing=-1 pauseStage=0:normal,1:base,2:stopped scopePhase=0:off,1:settle,2:A1,3:B,4:A2,5:invalid scopeSpan=inclusive-policy-and-callback gcStepKB="..FramePacer.GC_STEP_KB.." fields="..CHRONO_FIELDS)
  local prefix="pacer chronology-data v=2 rows="
  local line=prefix
  for i=1,count do
    local row=self.chronology[i]
    for j=1,34 do
      local v=row[j]
      if j==2 or (j>=5 and j<=7) or j==13 or j==14 or j==15 or j==18 or j==20 or j==22 or j==25 or j==34 then
        self.chronoParts[j]=("%.3f"):format(v)
      else self.chronoParts[j]=tostring(v) end
    end
    local encoded=table.concat(self.chronoParts,",")
    if #line+#encoded+1>CHRONO_LINE_BYTES and #line>#prefix then self.log(line);line=prefix end
    line=line..(#line>#prefix and ";" or "")..encoded
  end
  if #line>#prefix then self.log(line) end
end

function FramePacer:_fieldInnerOwned()
  local module = self.fieldInnerRegistry
  return self.cpuEnabled and self.frameT0 ~= nil and module ~= nil
    and module == self.cpuSources.fieldDraw and module._pacerDrawProbeVersion == 1
    and module._pacerDrawTiming == self.fieldInnerObserver
end
function FramePacer:_bindFieldInnerTiming(module)
  if module == self.fieldInnerRegistry then return end
  local old = self.fieldInnerRegistry
  if old and old._pacerDrawTiming == self.fieldInnerObserver then old._pacerDrawTiming = self.fieldInnerPrevious end
  self.fieldInnerRegistry, self.fieldInnerPrevious, self.fieldNativeToken = nil, nil, nil
  if type(module) == "table" and module._pacerDrawProbeVersion == 1 then
    self.fieldInnerRegistry, self.fieldInnerPrevious = module, module._pacerDrawTiming
    module._pacerDrawTiming = self.fieldInnerObserver
  end
  for i = 1, #FIELD_INNER_KEYS do self.probeReady[FIELD_INNER_KEYS[i]] = self.fieldInnerRegistry ~= nil end
end

-- Root-loop durations overlap the existing PARTS. They are elapsed time,
-- not pure CPU cycles, and never participate in the PARTS subtraction.
-- Four bounded tablet scopes share existing elapsed records and root registry.
function FramePacer:_rtcOwned()
  local r=self.rtcRegistry
  return self.cpuEnabled and self.frameT0~=nil and type(r)=="table"
    and r==(love and love._pacerOuterLoop) and r.rtcObserver==self.rtcObserver
end
function FramePacer:_bindRtcTiming()
  local r=love and love._pacerOuterLoop
  if r==self.rtcRegistry then return end
  local old=self.rtcRegistry
  if type(old)=="table" and old.rtcObserver==self.rtcObserver then old.rtcObserver=self.rtcPrevious end
  self.rtcRegistry,self.rtcPrevious=nil,nil
  if type(r)=="table" then
    if type(r.rtcSources)~="table" then r.rtcSources={} end
    self.rtcRegistry,self.rtcPrevious=r,r.rtcObserver;r.rtcObserver=self.rtcObserver
  end
end

function FramePacer:_tabletOwned()
  local r=self.tabletRegistry
  return self.cpuEnabled and self.frameT0~=nil and type(r)=="table" and r==(love and love._pacerOuterLoop)
    and r.tabletObserver==self.tabletObserver
end
function FramePacer:_bindTabletTiming()
  local r=love and love._pacerOuterLoop
  if r==self.tabletRegistry then return end
  local old=self.tabletRegistry
  if old and old.tabletObserver==self.tabletObserver then old.tabletObserver=self.tabletPrevious end
  self.tabletRegistry,self.tabletPrevious=nil,nil
  if type(r)=="table" then
    if type(r.tabletSources)~="table" then r.tabletSources={} end
    self.tabletRegistry,self.tabletPrevious=r,r.tabletObserver
    r.tabletObserver=self.tabletObserver
  end
end

function FramePacer:_bindOuterTiming()
  local registry = love and love._pacerOuterLoop
  if registry == self.outerRegistry then return end
  local old = self.outerRegistry
  if old and old.observer == self.outerObserver then old.observer = self.outerPrevious end
  self.outerRegistry, self.outerPrevious = nil, nil
  self.outerPendingTime, self.outerPendingToken = nil, nil
  if type(registry) == "table" then
    self.outerRegistry, self.outerPrevious = registry, registry.observer
    registry.observer = self.outerObserver
  end
end
function FramePacer:_outerSample(id, t0, token, now)
  local registry = self.outerRegistry
  if not self.cpuEnabled or token ~= self.frameNo or not t0
    or not registry or registry ~= (love and love._pacerOuterLoop)
    or registry.observer ~= self.outerObserver then return end
  local record = self.outerRecords[id]
  if not record then return end
  record.cur, record.calls = record.cur + now - t0, record.calls + 1
end
function FramePacer:_closeOuterTiming(slowest, cycled)
  for i = 1, #OUTER_KEYS do
    local r = self.outerRecords[i]
    r.total, r.totalCalls = r.total + r.cur, r.totalCalls + r.calls
    if r.cur > r.maxFrame then
      r.maxFrame, r.maxFrameNo, r.maxFrameCalls = r.cur, self.frameNo, r.calls
      r.maxFrameCycle = cycled == true
    end
    if slowest then r.slowest, r.slowestCalls = r.cur, r.calls end
  end
end
function FramePacer:_logOuterTiming()
  local registry = self.outerRegistry
  local available = registry and registry == (love and love._pacerOuterLoop) and registry.ready == true
  local owned = available and registry.observer == self.outerObserver
  for i = 1, #OUTER_KEYS do
    local r = self.outerRecords[i]
    self.log(("pacer outer-elapsed %s available=%s observerOwned=%s completed=%d avg=%.3fms maxFrame=%.3fms frame=%d cycleEnd=%s callsInMaxFrame=%d slowestPacerFrame=%d slowestCycleEnd=%s elapsed=%.3fms callsInSlowestPacerFrame=%d inclusive=true")
      :format(OUTER_KEYS[i], tostring(available == true), tostring(owned == true), r.totalCalls,
        r.total * 1000 / math.max(1, self.win.n), r.maxFrame * 1000, r.maxFrameNo, tostring(r.maxFrameCycle == true),
        r.maxFrameCalls, self.slowest.frame, tostring(self.slowest.cycled == true), r.slowest * 1000, r.slowestCalls))
    r.total, r.totalCalls, r.maxFrame, r.maxFrameNo, r.maxFrameCalls, r.slowest, r.slowestCalls = 0, 0, 0, 0, 0, 0, 0
    r.maxFrameCycle = false
  end
end

-- Bind only the private observer, never callbacks or registry entries. A
-- changed registry is handled at frame boundaries; diagnostics stay inclusive
-- and outside PARTS, so the existing layers time is never double-counted.
function FramePacer:_bindLayerTiming()
  local registry = self.hostApi and self.hostApi.layers
  if registry == self.cpuRegistry then return end
  local old = self.cpuRegistry
  if old and old._pacerUpdateTiming == self.cpuObserver then
    old._pacerUpdateTiming = self.cpuPreviousObserver
  end
  self.cpuRegistry, self.cpuPreviousObserver = nil, nil
  if type(registry) == "table" then
    self.cpuRegistry = registry
    self.cpuPreviousObserver = registry._pacerUpdateTiming
    registry._pacerUpdateTiming = self.cpuObserver
  end
end

function FramePacer:_closeLayerTiming(cycled, slowest)
  for i = 1, #CPU_LAYER_KEYS do
    local record = self.cpuById[CPU_LAYER_KEYS[i]]
    record.total = record.total + record.cur
    record.totalCalls = record.totalCalls + record.calls
    record.totalErrors = record.totalErrors + record.errors
    if record == self.cpuById.fieldTiles then
      record.totalRebuilds=record.totalRebuilds+record.curRebuilds
      record.totalCached=record.totalCached+record.curCached
    end
    if record.cur > record.maxFrame then
      record.maxFrame, record.maxFrameNo = record.cur, self.frameNo
      record.maxFrameCycle = cycled == true
      record.maxFrameCalls = record.calls
      if record == self.cpuById.fieldTiles then
        record.maxFrameRebuilds, record.maxFrameCached = record.curRebuilds, record.curCached
      end
    end
    if record.cur * 1000 > FramePacer.SLOW_MS then
      record.slow = record.slow + 1
      if cycled then record.slowCycle = record.slowCycle + 1 end
    end
    if slowest then
      record.slowest, record.slowestCalls = record.cur, record.calls
      if record == self.cpuById.fieldTiles then record.slowestRebuilds, record.slowestCached=record.curRebuilds, record.curCached end
    end
  end
end

function FramePacer:_logLayerTiming()
  local registry = self.cpuRegistry
  for i = 1, #CPU_LAYER_KEYS do
    local key = CPU_LAYER_KEYS[i]
    local record = self.cpuById[key]
    local entry = registry and registry.byId and registry.byId[key]
    local owned = registry and registry._pacerUpdateTiming == self.cpuObserver
    local available = (i <= 2 and entry ~= nil) or (i > 2 and self.probeReady[key] == true)
    local label = i <= 2 and "layer-cpu" or "fine-cpu"
    if i > 2 then
      owned = false
      local currentObject
      if key == "fixedUpdate" or key == "gameHud" then currentObject = self.game
      elseif key == "stereoUpdate" or key == "sceneDraw" or key == "hostDrawEye" then currentObject = self:_hostCpuObject(key,true)
      else currentObject = self.cpuSources[key] or self.probeModules[key] end
      if key == "stereoUpdate" or key == "sceneDraw" or key == "hostDrawEye" then
        local method=key=="stereoUpdate" and "update" or key=="sceneDraw" and "draw" or "drawEye"
        available=type(currentObject)=="table" and type(currentObject[method])=="function"
      end
      for j = 1, #self.wrapped do
        local wrapped = self.wrapped[j]
        if (wrapped.heapKey == key or wrapped.cpuKey == key or wrapped.cpuKey2 == key) and wrapped.obj == currentObject
          and rawget(wrapped.obj, wrapped.name) == wrapped.fn then owned = true end
      end
    end
    if i > #CPU_LAYER_KEYS - #FIELD_INNER_KEYS then
      local module = self.cpuSources.fieldDraw
      available = type(module) == "table" and module._pacerDrawProbeVersion == 1
      owned = available and module == self.fieldInnerRegistry and module._pacerDrawTiming == self.fieldInnerObserver
    end
    owned = owned == true
      if key=="tabletGen3Refresh" or key=="tabletTools" or key=="watchMapDraw" or key=="watchMapCopy" then
        local r=self.tabletRegistry
        available=r and r==(love and love._pacerOuterLoop) and r.tabletObserver==self.tabletObserver and type(r.tabletSources)=="table" and r.tabletSources[key]==self.tabletObserver or false
        owned=self:_tabletOwned()==true
      end
    if key=="rtcNightScan" then
      local r=self.rtcRegistry
      available=type(r)=="table" and r==(love and love._pacerOuterLoop) and r.rtcObserver==self.rtcObserver
        and type(r.rtcSources)=="table" and r.rtcSources.rtcNightScan==self.rtcObserver or false
      owned=self:_rtcOwned()==true
    end
    local failed = entry and entry.failed == true or false
    local coverageChanged = record.lastAvailable ~= available or record.lastOwned ~= owned or record.lastFailed ~= failed
    if record.totalCalls > 0 or coverageChanged then
    self.log(("pacer %s %s available=%s failed=%s observerOwned=%s calls=%d errors=%d avg=%.3fms maxCall=%.3fms maxFrame=%.3fms frame=%d callsInMaxFrame=%d cycleEnd=%s slow>%d=%d slowCycleEnd=%d slowestPacerFrame=%.3fms callsInSlowestPacerFrame=%d; inclusive elapsed time, outer failures included/fine completed calls only; shared-frame cycle correlation is not causation")
      :format(label,key,tostring(available),tostring(entry and entry.failed==true or false),tostring(owned==true),
        record.totalCalls,record.totalErrors,record.total*1000/math.max(1,record.totalCalls),
        record.maxCall*1000,record.maxFrame*1000,record.maxFrameNo,record.maxFrameCalls,tostring(record.maxFrameCycle),
        FramePacer.SLOW_MS,record.slow,record.slowCycle,record.slowest*1000,record.slowestCalls))
    end
    if key == "fieldTiles" then
      self.log(("pacer field-native-branches available=%s observerOwned=%s rebuild=%d cached=%d maxFrame=%d rebuildAtMax=%d cachedAtMax=%d slowestPacerFrame=%d rebuildAtSlowest=%d cachedAtSlowest=%d; actual branch entries, not elapsed cause")
        :format(tostring(available),tostring(owned),record.totalRebuilds,record.totalCached,record.maxFrameNo,
          record.maxFrameRebuilds,record.maxFrameCached,self.slowest.frame,record.slowestRebuilds,record.slowestCached))
      record.totalRebuilds,record.totalCached,record.maxFrameRebuilds,record.maxFrameCached,record.slowestRebuilds,record.slowestCached=0,0,0,0,0,0
    end
    if key=="rtcNightScan" then
      local c=self.rtcCounts
      if c.attempts>0 or coverageChanged then
        self.log(("pacer rtc-night-scan available=%s observerOwned=%s attempts=%d completed=%d incomplete=%d scanned=%d slots=%d transitions=%d underUploads=%d overUploads=%d dirtyRequests=%d lastCompletedFrame=%d; completed counts only, incomplete cost unknown; inclusive frame correlation is not cause")
          :format(tostring(available),tostring(owned),c.attempts,c.completed,math.max(0,c.attempts-c.completed),c.scanned,c.slots,c.transitions,c.under,c.over,c.dirty,c.lastFrame))
      end
      c.attempts,c.completed,c.scanned,c.slots,c.transitions,c.under,c.over,c.dirty,c.lastFrame=0,0,0,0,0,0,0,0,0
      local r=self.rtcRegistry
      if type(r)=="table" and type(r.rtcSources)=="table" and r.rtcSources.rtcNightScan==self.rtcObserver then r.rtcSources.rtcNightScan=nil end
    end
    local tablet=self.tabletRegistry
    if (key=="tabletGen3Refresh" or key=="tabletTools" or key=="watchMapDraw" or key=="watchMapCopy")
      and tablet and type(tablet.tabletSources)=="table" and tablet.tabletSources[key]==self.tabletObserver then
      tablet.tabletSources[key]=nil
    end
    record.lastAvailable, record.lastOwned, record.lastFailed = available, owned, failed
    record.total, record.totalCalls, record.totalErrors, record.maxCall = 0, 0, 0, 0
    record.maxFrame, record.maxFrameNo, record.maxFrameCycle, record.maxFrameCalls = 0, 0, false, 0
    record.slow, record.slowCycle, record.slowest, record.slowestCalls = 0, 0, 0, 0
  end
end

-- ------------------------------------------------------------ timing core
-- varargs pass-through: time one call without packing its results
function FramePacer:_add(key, t0, ...)
  local cur = self.cur
  cur[key] = cur[key] + (getTime() - t0)
  return ...
end

-- Two scalar results, no per-call table. Normal frames never query the heap
-- here. Capturing the window prevents a callback that ends/cancels a phase
-- from attributing its whole call to the next phase.
function FramePacer:_heapStart()
  local pz = self.pause
  if pz then return pz.win, gcount("count") end
end

function FramePacer:_addMeasured(key, t0, window, heap0, ...)
  self.cur[key] = self.cur[key] + (getTime() - t0)
  local pz = self.pause
  if window and pz and pz.win == window then
    window.allocKB[key] = window.allocKB[key] + gcount("count") - heap0
    window.allocCalls[key] = window.allocCalls[key] + 1
  end
  return ...
end

function FramePacer:_heapAdd(key, window, heap0)
  local pz = self.pause
  if window and pz and pz.win == window then
    local delta = gcount("count") - heap0
    window.allocKB[key] = window.allocKB[key] + delta
    window.allocCalls[key] = window.allocCalls[key] + 1
    return delta
  end
end

function FramePacer:_heapReturn(key, window, heap0, ...)
  self:_heapAdd(key, window, heap0)
  return ...
end

function FramePacer:_addSplit(timeKey, heapKey, t0, window, heap0, ...)
  self.cur[timeKey] = self.cur[timeKey] + (getTime() - t0)
  local delta = self:_heapAdd(heapKey, window, heap0)
  if delta ~= nil then
    window.allocKB[timeKey] = window.allocKB[timeKey] + delta
    window.allocCalls[timeKey] = window.allocCalls[timeKey] + 1
  end
  return ...
end

-- The function a wrapper forwards to: the instance's own field as it was
-- when wrapped, else the CLASS method looked up at call time, so a later
-- class-level patch by other code is still honoured.
local function resolver(obj, name)
  local raw = rawget(obj, name)
  if type(raw) == "function" then return function() return raw end, raw end
  return function()
    local mt = getmetatable(obj)
    local idx = mt and mt.__index
    if type(idx) == "table" then return idx[name] end
    if type(idx) == "function" then return idx(obj, name) end
    return nil
  end, raw
end
FramePacer._resolver = resolver

-- Wrap obj[name] at instance level (the class method stays untouched).
function FramePacer:_wrap(obj, name, key, heapKey)
  if type(obj) ~= "table" or type(obj[name]) ~= "function" then return false end
  local target, raw = resolver(obj, name)
  local pacer = self
  obj[name] = function(...)
    local window, heap0 = pacer:_heapStart()
    local t0 = getTime()
    if heapKey then return pacer:_addSplit(key, heapKey, t0, window, heap0, target()(...)) end
    return pacer:_addMeasured(key, t0, window, heap0, target()(...))
  end
  self.wrapped[#self.wrapped + 1] = { obj = obj, name = name, raw = raw, fn = obj[name] }
  return true
end

-- Measurement-only wrappers never add time to the existing split. Calls
-- outside the experiment or other hook names forward directly. No catch,
-- argument/result packing, module load, or per-call record construction.
-- Fine CPU timing counts completed calls only: errors still propagate through
-- the original tail call without any new catch/packing boundary.
function FramePacer:_fineCpuReturn(key, t0, token, window, heap0, ...)
  if t0 then self.cpuObserver.sample(key, t0, token, true) end
  self:_heapAdd(key, window, heap0)
  return ...
end

function FramePacer:_wrapHeap(obj, name, key, hookName)
  if type(obj) ~= "table" or type(obj[name]) ~= "function" then return false end
  local target, raw = resolver(obj, name)
  local pacer = self
  obj[name] = function(...)
    if hookName and select(1, ...) ~= hookName then
      -- One owner for Runtime.call: mutually exclusive CPU-only compose branch
      -- avoids stacking a wrapper over the existing input-step measurement.
      if key == "inputStep" and select(1, ...) == "render.compose" and pacer.cpuEnabled then
        local t0, token = pacer.cpuObserver.clock("renderCompose")
        if pacer.pause and pacer.seam51Installed then -- Lab 51 heap seam (GC PAUSE TEST only)
          local window, heap0 = pacer:_heapStart()
          return pacer:_composeSeamReturn(t0, token, window, heap0, target()(...))
        end
        return pacer:_cpuReturn("renderCompose", t0, token, target()(...))
      end
      return target()(...)
    end
    if pacer.cpuEnabled and pacer.cpuById[key] then
      local window, heap0 = pacer:_heapStart()
      local t0, token = pacer.cpuObserver.clock(key)
      return pacer:_fineCpuReturn(key, t0, token, window, heap0, target()(...))
    end
    if not pacer.pause then return target()(...) end
    local window, heap0 = pacer:_heapStart()
    return pacer:_heapReturn(key, window, heap0, target()(...))
  end
  self.wrapped[#self.wrapped + 1] = { obj=obj, name=name, raw=raw, fn=obj[name], heapKey=key, cpuKey2=key == "inputStep" and "renderCompose" or nil }
  return true
end

function FramePacer:_composeSeamReturn(t0, token, window, heap0, ...)
  if t0 then self.cpuObserver.sample("renderCompose", t0, token, true) end
  self:_heapAdd("seamCompose", window, heap0)
  return ...
end

-- CPU-only inner seams: no heap keys, public snapshots or result packing.
function FramePacer:_cpuReturn(key, t0, token, ...)
  if t0 then self.cpuObserver.sample(key, t0, token, true) end
  return ...
end

function FramePacer:_wrapCpu(obj, name, key)
  if type(obj) ~= "table" or type(obj[name]) ~= "function" then return false end
  local target, raw = resolver(obj, name)
  local pacer = self
  obj[name] = function(...)
    if not pacer.cpuEnabled then return target()(...) end
    local t0, token = pacer.cpuObserver.clock(key)
    return pacer:_cpuReturn(key, t0, token, target()(...))
  end
  self.wrapped[#self.wrapped + 1] = { obj=obj, name=name, raw=raw, fn=obj[name], cpuKey=key }
  return true
end

-- Private renderer/bridge seams. Provider lookup happens only at initial
-- live-field resolution and log boundaries; calls keep scalar tokens/varargs.
function FramePacer:_hostCpuObject(key, liveProvider)
  local r=type(self.renderer)=="table" and self.renderer or nil
  if key=="sceneDraw" then return r and r.scene end
  if key=="hostDrawEye" then return r and r.hostApi end
  if key=="stereoUpdate" then
    local bridge,lib=self.hostBridge,self.hostBridgeLib
    if not bridge or not lib or not bridge.exports or bridge.exports.lib~=lib
      or lib.require~=self.hostBridgeRequire then return end
    if liveProvider then
      local mod=V and V.mod
      if not mod or type(mod.find)~="function"then return end
      local ok,current=pcall(mod.find,"VRITK_FRLG_HOST")
      if not ok or type(current)~="table" or current.exports~=bridge.exports then return end
    end
    return self.cpuSources.stereoUpdate
  end
end
function FramePacer:_hostCpuReturn(key,obj,name,wrapper,t0,token,window,heap0,...)
  if t0 and self:_hostCpuObject(key,false)==obj and rawget(obj,name)==wrapper then
    self.cpuObserver.sample(key,t0,token,true)
    if window and self.cpuEnabled and self.frameT0 and self.frameNo==token then self:_heapAdd(key,window,heap0) end
  end
  return ...
end
function FramePacer:_wrapHostCpu(obj,name,key)
  if type(obj)~="table"or type(obj[name])~="function"then return false end
  local target,raw=resolver(obj,name);local pacer=self;local wrapper
  wrapper=function(...)
    if not pacer.cpuEnabled or pacer:_hostCpuObject(key,false)~=obj or rawget(obj,name)~=wrapper then return target()(...)end
    local t0,token=pacer.cpuObserver.clock(key)
    local window,heap0
    if t0 and pacer.pause then
      window,heap0=pacer:_heapStart()
      if window and window.allocAttempts then window.allocAttempts[key]=window.allocAttempts[key]+1 end
    end
    return pacer:_hostCpuReturn(key,obj,name,wrapper,t0,token,window,heap0,target()(...))
  end
  obj[name]=wrapper
  self.wrapped[#self.wrapped+1]={obj=obj,name=name,raw=raw,fn=wrapper,cpuKey=key}
  return true
end
-- Only experiment boundaries query current provider ownership. Calls use the
-- existing owned attachment and never perform provider discovery.
function FramePacer:_hostHeapCoverage(window,field)
  local values={};window[field]=values
  for _,key in ipairs(HOST_HEAP_KEYS)do
    local ok,obj=true,nil
    if self.cpuEnabled then ok,obj=pcall(self._hostCpuObject,self,key,true) end
    local owned=false
    if type(obj)=="table" then for _,w in ipairs(self.wrapped)do
      if w.cpuKey==key and w.obj==obj and rawget(obj,w.name)==w.fn then owned=true;break end
    end end
    values[key]=owned
    if not ok then values[key]="unknown" end
  end
end
function FramePacer:_ensureHostCpuProbes()
  local game,runtime=self.game,self.probeModules.runtimeSource
  if not self.cpuEnabled or not game or game.phase~="field"or not runtime or runtime.active~=true
    or type(runtime.session)~="table"then return end
  local r=type(self.renderer)=="table" and self.renderer or nil
  if r then
    if r.scene~=self.cpuInstalled.sceneDraw and self:_wrapHostCpu(r.scene,"draw","sceneDraw")then
      self.cpuInstalled.sceneDraw,self.probeReady.sceneDraw=r.scene,true
    end
    if r.hostApi~=self.cpuInstalled.hostDrawEye and self:_wrapHostCpu(r.hostApi,"drawEye","hostDrawEye")then
      self.cpuInstalled.hostDrawEye,self.probeReady.hostDrawEye=r.hostApi,true
    end
  end
  if not self.hostCpuResolved then
    self.hostCpuResolved=true
    local mod=V and V.mod;local ok,bridge
    if mod and type(mod.find)=="function"then ok,bridge=pcall(mod.find,"VRITK_FRLG_HOST")end
    local lib=ok and bridge and bridge.exports and bridge.exports.lib
    if type(lib)=="table"and type(lib.require)=="function"then
      local got,module=pcall(lib.require,"QuestStereoLayers")
      if got and type(module)=="table"then
        self.hostBridge,self.hostBridgeLib,self.hostBridgeRequire=bridge,lib,lib.require
        self.cpuSources.stereoUpdate=module
        if self:_wrapHostCpu(module,"update","stereoUpdate")then
          self.cpuInstalled.stereoUpdate,self.probeReady.stereoUpdate=module,true
        end
      end
    end
  end
end

function FramePacer:_ensureInnerCpuProbes()
  local game, runtime = self.game, self.probeModules.runtimeSource
  -- These modules are field dependencies. Do not load them merely because a
  -- boot placeholder happens to expose fixedUpdate, or before a live session.
  if not game or game.phase ~= "field" or not runtime or runtime.active ~= true
    or type(runtime.session) ~= "table" then return end
  if not self.cpuInnerResolved then
    self.cpuInnerResolved = true
    for i = 1, #CPU_INNER_SPECS do
      local spec = CPU_INNER_SPECS[i]
      local ok, module = pcall(require, spec[2])
      self.cpuSources[spec[1]] = ok and type(module) == "table" and module or false
    end
  end
  if game ~= self.cpuInstalled.gameHud and self:_wrapCpu(game, "_drawHud", "gameHud") then
    self.cpuInstalled.gameHud, self.probeReady.gameHud = game, true
  end
  for i = 1, #CPU_INNER_SPECS do
    local spec = CPU_INNER_SPECS[i]
    local key, module = spec[1], self.cpuSources[spec[1]]
    if module and module ~= self.cpuInstalled[key] and self:_wrapCpu(module, spec[3], key) then
      self.cpuInstalled[key], self.probeReady[key] = module, true
    end
  end
  self:_bindFieldInnerTiming(self.cpuSources.fieldDraw)
end

function FramePacer:_ensureFineProbes()
  local game = self.game
  if game and game ~= self.probeGame and self:_wrapHeap(game, "fixedUpdate", "fixedUpdate") then
    self.probeGame, self.probeReady.fixedUpdate = game, true
  end
  -- The mod sandbox intentionally exposes no package.loaded. These three
  -- engine modules are already dependencies of the real Game3 class before
  -- its instance can expose fixedUpdate. Resolve permitted require once,
  -- never from the measured hot path, and never probe a boot placeholder.
  if not game or type(game.fixedUpdate) ~= "function" then return end
  if not self.probeResolved then
    self.probeResolved = true
    local ok, found = pcall(require, "src.core.game3.runtime")
    self.probeModules.runtimeSource = ok and found or false
    ok, found = pcall(require, "src.core.game3.audio")
    self.probeModules.audioSource = ok and found or false
    ok, found = pcall(require, "src.mods.Runtime")
    self.probeModules.modsSource = ok and found or false
  end
  local runtime = self.probeModules.runtimeSource
  if runtime and runtime ~= self.probeModules.nativeRuntime
    and self:_wrapHeap(runtime, "update", "nativeRuntime") then
    self.probeModules.nativeRuntime, self.probeReady.nativeRuntime = runtime, true
  end
  local audio = self.probeModules.audioSource
  if audio and audio ~= self.probeModules.audioUpdate
    and self:_wrapHeap(audio, "update", "audioUpdate") then
    self.probeModules.audioUpdate, self.probeReady.audioUpdate = audio, true
  end
  local mods = self.probeModules.modsSource
  if mods and mods ~= self.probeModules.inputStep
    and self:_wrapHeap(mods, "call", "inputStep", "input.step") then
    self.probeModules.inputStep, self.probeReady.inputStep = mods, true
    self.probeModules.renderCompose, self.probeReady.renderCompose = mods, true
  end
end

-- Discover once, before the first experiment window. Only the callback field
-- is wrapped: the dispatcher supplies its original nextFn unchanged. Inclusive
-- callback deltas overlap and cannot generally be subtracted to infer self cost.
function FramePacer:_ensureInputHookProbes()
  if self.inputHooksDiscovered then return end
  self.inputHooksDiscovered = true
  local mods = self.probeModules.modsSource
  local bus = mods and mods.hooks
  local chain = bus and bus.chains and bus.chains["input.step"]
  self.inputHookBus = bus or false
  if type(chain) ~= "table" then return end
  for i = 1, #chain do
    local entry = chain[i]
    if type(entry) == "table" and type(entry.callback) == "function" then
      local key = ("inputHook%02d"):format(i)
      local record = { entry=entry, key=key, owner=tostring(entry.owner or "?"),
        priority=entry.priority or 0, ordinal=i }
      if self:_wrapHeap(entry, "callback", key) then
        record.fn = entry.callback
        self.inputHooks[#self.inputHooks + 1] = record
        self.heapKeys[#self.heapKeys + 1] = key
      end
    end
  end
end

-- Coverage is checked only at experiment/phase boundaries, never per frame.
-- A missing or replaced callback is unavailable, not a zero-allocation handler.
function FramePacer:_logInputHookCoverage(tag)
  local mods = self.probeModules.modsSource
  local bus = mods and mods.hooks
  local busChanged = bus ~= self.inputHookBus
  local chain = bus and bus.chains and bus.chains["input.step"]
  local matched, changed, added = 0, 0, 0
  if type(chain) == "table" then
    for i = 1, #chain do
      local entry, found = chain[i], false
      for j = 1, #self.inputHooks do
        local r = self.inputHooks[j]
        if r.entry == entry then
          found = true
          if entry.callback == r.fn then matched = matched + 1 else changed = changed + 1 end
          break
        end
      end
      if not found then added = added + 1 end
    end
  end
  self.log(("pacer input-hook coverage %s: discovered=%d matched=%d changed=%d missing=%d added=%d available=%s busChanged=%s")
    :format(tag, #self.inputHooks, matched, changed,
      #self.inputHooks - matched - changed, added, tostring(type(chain) == "table"), tostring(busChanged)))
end

function FramePacer:_logInputHookAllocations(tag, window)
  for i = 1, #self.inputHooks do
    local r = self.inputHooks[i]
    local calls = window.allocCalls[r.key]
    self.log(("pacer input-hook %s key=%s owner=%s priority=%s ordinal=%d calls=%d inclusive=%.1fKB avg=%.1fKB/call")
      :format(tag, r.key, r.owner, tostring(r.priority), r.ordinal, calls,
        window.allocKB[r.key], calls > 0 and window.allocKB[r.key] / calls or 0))
  end
  self.log("pacer input-hook deltas are inclusive; short circuits, errors, repeated next and reentrancy invalidate general adjacent subtraction")
end

-- Resolve the private Catch attachment once through the real mod.find API.
-- Install fixed slots before any phase window is allocated; never in hot calls.
function FramePacer:_ensureCatchProbes()
  if self.catchProbeResolved then return end
  self.catchProbeResolved = true
  local mod = V and V.mod
  local ok, found
  if mod and type(mod.find) == "function" then ok, found = pcall(mod.find, "FRLG_CATCH") end
  local attach = ok and found and found.exports and found.exports._attachAllocationProbes
  if type(attach) ~= "function" then return end
  local installed = 0
  local pacer = self
  local success = pcall(attach, function(slots)
    if type(slots) ~= "table" then return false end
    for i = 1, #CATCH_KEYS do
      local key = CATCH_KEYS[i]
      if pacer:_wrapHeap(slots, key, key) then
        pacer.heapKeys[#pacer.heapKeys + 1] = key
        installed = installed + 1
      end
    end
    return true
  end)
  self.catchProbeReady = success and installed == #CATCH_KEYS
  self.catchProbeCount = installed
end

-- Lab 51: locate the unexplained ~90 KB/frame (RESEARCH_ALLOCATION_MAP 3).
-- Resolved and installed once, when the GC PAUSE TEST starts; never in normal
-- play, so the hot paths keep their plain functions until then. A target that
-- cannot be found is reported "unavailable", never as zero.
function FramePacer:_ensureSeam51Probes()
  if self.seam51Installed then return end
  self.seam51Installed = true
  for i = 1, #SEAM51_KEYS do self.heapKeys[#self.heapKeys + 1] = SEAM51_KEYS[i] end
  local ready = self.seam51Ready
  local mod = V and V.mod
  local function find(id)
    if mod and type(mod.find) == "function" then
      local ok, h = pcall(mod.find, id)
      if ok and type(h) == "table" then return h end
    end
  end
  local function lib(handle, field)
    local l = handle and type(handle.exports) == "table" and handle.exports[field]
    if type(l) == "table" and type(l.require) == "function" then return l end
  end
  local function module(l, name)
    if not l then return nil end
    local ok, m = pcall(l.require, name)
    if ok and type(m) == "table" then return m end
  end
  local vritk = lib(find("VRITK_FRLG_HOST"), "lib")
  local bp = lib(find("VR_INTERACTIONS_BACKPACK_LAB"), "diagLib")
  local un = find("untamed_advanced")
  local E = un and type(un.exports) == "table" and un.exports.engine
  local field = type(E) == "table" and type(E.Field) == "table" and E.Field or nil
  local specs = {
    { "seamHands", module(vritk, "QuestHandsRenderer"), "draw" },
    { "seamDevice", module(bp, "QuestDeviceRenderer"), "draw" },
    { "seamBackpackEye", module(bp, "BackpackRenderer"), "drawEye" },
    { "seamWearable", module(bp, "QuestWearableInteraction"), "update" },
    { "seamPouch", module(bp, "PouchView"), "update" },
    { "seamBelt", module(bp, "PartyBeltComponent"), "update" },
    { "seamUntamedField", field, "update" },
    { "seamHud", self.game, "_drawHud" },
  }
  for i = 1, #specs do
    local sp = specs[i]
    ready[sp[1]] = sp[2] ~= nil and self:_wrapHeap(sp[2], sp[3], sp[1]) or false
  end
  ready.seamCompose = self.probeReady.renderCompose == true
  self.xrSeamsWanted = true -- the XR proxy is rebuilt with input/poll/locate seams
  ready.seamXrInput, ready.seamXrPoll, ready.seamXrLocate = true, true, true
  local parts = {}
  for i = 1, #SEAM51_KEYS do parts[i] = SEAM51_KEYS[i] .. "=" .. tostring(ready[SEAM51_KEYS[i]] == true) end
  self.log("pacer heap-seams51 installed: " .. table.concat(parts, " ")
    .. "; false means unavailable, not zero; seamUntamedField is the whole field update incl. untamed_advanced's tick")
end

function FramePacer:_logSeam51(tag, w)
  if not self.seam51Installed or type(w) ~= "table" or not w.allocCalls then return end
  local frames = math.max(1, w.n or 0)
  local parts = {}
  for i = 1, #SEAM51_KEYS do
    local key = SEAM51_KEYS[i]
    local calls, kb = w.allocCalls[key] or 0, w.allocKB[key] or 0
    if calls > 0 then
      parts[#parts + 1] = ("%s=%.2fKB/call n=%d %.2fKB/f"):format(key, kb / calls, calls, kb / frames)
    else
      parts[#parts + 1] = key .. (self.seam51Ready[key] == true and "=0calls" or "=unavailable")
    end
  end
  self.log("pacer heap-seams51 " .. tag .. " frames=" .. (w.n or 0) .. ": " .. table.concat(parts, " ")
    .. " | inclusive, nested seams overlap (hands/device/backpackEye sit inside hostDrawEye; wearable/pouch/belt inside stereoUpdate)")
end

function FramePacer:_logCatchAllocations(tag, window)
  for i = 1, #CATCH_KEYS do
    local key = CATCH_KEYS[i]
    local calls = window.allocCalls[key]
    if calls ~= nil then
      self.log(("pacer catch-subcall %s key=%s calls=%d inclusive=%.1fKB avg=%.1fKB/call")
        :format(tag, key, calls, window.allocKB[key],
          calls > 0 and window.allocKB[key] / calls or 0))
    end
  end
end

-- Quest: time xrWaitFrame and xrEndFrame through a proxy of the host handle
-- (XRSession calls vr.XR.waitFrame(...) / vr.XR.endFrame(...) as plain
-- functions; every other field reads through to the real tables).
function FramePacer:_wrapXR(xr)
  if type(xr) ~= "table" or type(xr.handle) ~= "function" then return false end
  local target, raw = resolver(xr, "handle")
  local pacer = self
  local realVr, proxy = nil, nil
  xr.handle = function(s, ...)
    local vr = target()(s, ...)
    if type(vr) ~= "table" or type(vr.XR) ~= "table" then return vr end
    if vr ~= realVr or pacer.xrSeamsWanted ~= pacer.xrSeamsBuilt then
      local XR = vr.XR
      local pXR = setmetatable({
        waitFrame = function(...)
          pacer:_slackBeforeWait() -- Lab 51: GC MODE SLACK steps in the idle time (no-op otherwise)
          local t0 = getTime()
          return pacer:_waitDone(t0, XR.waitFrame(...))
        end,
        endFrame = function(...)
          local t0 = getTime()
          return pacer:_afterEnd(pacer:_add("submit", t0, XR.endFrame(...)))
        end,
      }, { __index = XR })
      -- Lab 51 heap seams: only once the GC PAUSE TEST installed them (the
      -- proxy is rebuilt then), so normal play keeps the plain read-through.
      if pacer.xrSeamsWanted then
        pXR.input = function(...)
          if not pacer.pause then return XR.input(...) end
          local window, heap0 = pacer:_heapStart()
          return pacer:_heapReturn("seamXrInput", window, heap0, XR.input(...))
        end
        pXR.poll = function(...)
          if not pacer.pause then return XR.poll(...) end
          local window, heap0 = pacer:_heapStart()
          return pacer:_heapReturn("seamXrPoll", window, heap0, XR.poll(...))
        end
        pXR.locateViews = function(...)
          if not pacer.pause then return XR.locateViews(...) end
          local window, heap0 = pacer:_heapStart()
          return pacer:_heapReturn("seamXrLocate", window, heap0, XR.locateViews(...))
        end
      end
      pacer.xrSeamsBuilt = pacer.xrSeamsWanted
      proxy = setmetatable({ XR = pXR }, { __index = vr })
      realVr = vr
    end
    return proxy
  end
  self.wrapped[#self.wrapped + 1] = { obj = xr, name = "handle", raw = raw, fn = xr.handle }
  self:_wrap(xr, "_submitEyes", "submit")
  self:_wrap(xr, "_copyQuad", "submit")
  return true
end

-- Lab 51: the "wait" part, plus the measured wait for the SLACK idle estimate.
function FramePacer:_waitDone(t0, ...)
  local dt = getTime() - t0
  local cur = self.cur
  cur.wait = cur.wait + dt
  local s = self.slack
  if s and self.gcMode == "slack" then s:noteWait(dt * 1000) end
  return ...
end

-- fix 1d: collector pacing right after xrEndFrame (results pass through)
function FramePacer:_afterEnd(...)
  if self.gcStepMs or FramePacer.GC_STEP_MS > 0 then self:gcPace() end
  return ...
end

-- The game instance's update: the frame boundary, plus the "update" part.
-- One wrapper per game instance, for the session (it forwards to whichever
-- pacer is active, so a rebuilt renderer does not stack wrappers).
local MARK = "_frlgVoxelFramePacer"
function FramePacer.attachGame(game)
  if type(game) ~= "table" or rawget(game, MARK) then return false end
  if type(game.update) ~= "function" then return false end
  local target = resolver(game, "update")
  rawset(game, MARK, true)
  game.update = function(...)
    local p = active
    if not p then return target()(...) end
    p:_frameStart(getTime())
    local window, heap0 = p:_heapStart()
    local t0 = getTime() -- after _frameStart: a desktop gcPace there is "gc", not "update"
    return p:_addMeasured("update", t0, window, heap0, target()(...))
  end
  return true
end

-- ------------------------------------------------------------ per frame
-- `cycled`: a collector cycle ended (its atomic phase ran) inside this frame
function FramePacer:_closeFrame(wall, cycled)
  local win = self.win
  local cur = self.cur
  win.n = win.n + 1
  win.sum = win.sum + wall
  if wall > win.max then win.max = wall end
  if wall * 1000 > FramePacer.SLOW_MS then
    win.slow = win.slow + 1
    if cycled then win.slowCycled = win.slowCycled + 1 end
  end
  if wall * 1000 > FramePacer.HITCH_MS then win.hitch = win.hitch + 1 end
  if cycled then
    win.cycles = win.cycles + 1
    self.cyclesTotal = self.cyclesTotal + 1
    if self.pause then self.pause.win.cycles = self.pause.win.cycles + 1 end
  end
  self:_recordChronology(win.n,wall,cycled)
  self.walls[win.n] = wall
  for i = 1, #PARTS do
    local k = PARTS[i]
    win.parts[k] = win.parts[k] + cur[k]
  end
  local s = self.slowest
  self:_closeOuterTiming(wall > s.wall, cycled)
  self:_closeLayerTiming(cycled, wall > s.wall)
  self:_closePassTiming()
  if wall > s.wall then
    s.wall, s.frame, s.cycled = wall, self.frameNo, cycled and true or false
    for i = 1, #PARTS do s.parts[PARTS[i]] = cur[PARTS[i]] end
  end
  local pz = self.pause
  if pz then self:_pauseFrame(pz, wall) end
  if win.n >= FramePacer.LOG_FRAMES then self:_logWindow() end
end

-- Lab 55 (G0): fold this frame's pass times into the window (no allocation).
function FramePacer:_closePassTiming()
  local p = self.pass
  local cur, calls = p.cur, p.calls
  local any = false
  for i = 1, #PASS_KEYS do
    local c = cur[i]
    if calls[i] > 0 then any = true end
    p.total[i] = p.total[i] + c
    p.totalCalls[i] = p.totalCalls[i] + calls[i]
    if c > p.maxFrame[i] then p.maxFrame[i] = c end
    cur[i], calls[i] = 0, 0
  end
  if any then p.frames = p.frames + 1 end
end

-- One line per log window: per pass, ms per world frame (both eyes), worst
-- frame, and calls. Window-boundary allocation only.
function FramePacer:_logPassTiming()
  local p = self.pass
  if p.frames > 0 then
    local parts = {}
    local sum = 0
    for i = 1, #PASS_KEYS do
      if p.totalCalls[i] > 0 then
        parts[#parts + 1] = ("%s=%.2f/%.2f(%d)"):format(PASS_KEYS[i], p.total[i] * 1000 / p.frames,
          p.maxFrame[i] * 1000, p.totalCalls[i])
        if PASS_KEYS[i] ~= "grass" then sum = sum + p.total[i] end -- grass is inside scene
      end
    end
    self.log(("pacer eye-pass frames=%d sum=%.2fms/frame | %s | ms per world frame (both eyes)/worst frame ms(calls); inclusive, scene includes grass")
      :format(p.frames, sum * 1000 / p.frames, table.concat(parts, " ")))
  end
  for i = 1, #PASS_KEYS do p.total[i], p.totalCalls[i], p.maxFrame[i], p.maxCall[i] = 0, 0, 0, 0 end
  p.frames = 0
end

function FramePacer:_frameStart(now)
  -- collector cycles: a weak-keyed sentinel is cleared by every cycle's
  -- atomic phase, so finding it empty now means a cycle ended in the frame
  -- that is closing
  -- Incoming root prefix belongs to the interval about to close.
  if self.outerPendingTime then
    self:_outerSample(2, self.outerPendingTime, self.outerPendingToken, now)
    self.outerPendingTime, self.outerPendingToken = nil, nil
  end
  local cycled = next(self.sentinel) == nil
  if cycled then self.sentinel[{}] = true end
  if self.frameT0 then self:_closeFrame(now - self.frameT0, cycled) end
  -- Close preceding record first; an acquired callback cannot reset its owner.
  if self.collector then
    if self.collector:resetFrame() then self.collectorInvalid=false
    else self:cancelCollector("frame rollover during callback") end
  end
  local cur = self.cur
  for i = 1, #PARTS do cur[PARTS[i]] = 0 end
  for i = 1, #CPU_LAYER_KEYS do
    local record = self.cpuById[CPU_LAYER_KEYS[i]]
    record.cur, record.calls, record.errors = 0, 0, 0
  end
  for i = 1, #OUTER_KEYS do
    local r = self.outerRecords[i]
    r.cur, r.calls = 0, 0
  end
  local tiles = self.cpuById.fieldTiles
  tiles.curRebuilds, tiles.curCached, self.fieldNativeToken = 0, 0, nil
  self:_bindOuterTiming()
  self:_bindTabletTiming()
  self:_bindRtcTiming()
  self:_bindLayerTiming()
  self:_bindXrTiming()
  for i=1,2 do
    local r=self.xrRecords[i]
    r.attempts,r.completed,r.errors,r.elapsed,r.delta,r.period=0,0,0,0,-1,-1
  end
  self.gcAttempts,self.gcCompleted,self.gcMaxStep,self.gcCyclesComplete=0,0,0,0
  -- _frameStart's incoming now precedes _closeFrame/reporting, so report work
  -- belongs to this new interval. Keep it explicit, inclusive, never subtract.
  self.reportCostCurrent,self.reportPending=self.reportPending,0
  self.frameT0 = now
  self.frameNo = self.frameNo + 1
  self:_ensureFineProbes()
  self:_ensureInnerCpuProbes()
  self:_ensureHostCpuProbes()
  if self.gcPaceAtFrameStart then self:gcPace() end -- desktop test hook for fix 1d
  local win = self.win
  if not win.t0 then win.t0 = now end
  -- heap
  local kb = gcount("count")
  if kb < win.heapMin then win.heapMin = kb end
  if kb > win.heapMax then win.heapMax = kb end
  if self.heapKB and kb > self.heapKB then win.grow = win.grow + (kb - self.heapKB) end
  self.heapKB = kb
  -- debug option (rising edge), polled every OPTION_POLL frames
  if self.option and self.frameNo % FramePacer.OPTION_POLL == 0 then
    local okO, on = pcall(self.option)
    on = okO and on and true or false
    if on and self.optionWas == false then self:pauseGC() end
    self.optionWas = on
  end
  if self.renderOption and self.frameNo % FramePacer.OPTION_POLL == 0 then
    local ok,on=pcall(self.renderOption)
    if ok and (on==true or on==false) then
      -- Lab 51: never arm the render test under GC MODE SLACK (mutually exclusive)
      if on==true and self.renderOptionWas==false and self.collector and not self.pause and self.gcMode~="slack" then self.collector:arm() end
      self.renderOptionWas=on
    else
      self.renderOptionWas=nil
      self:cancelCollector("option unavailable")
    end
  end
  -- fix 1d pacing budget from the optional options choice ("0" / "0.5" / "1")
  if self.stepOption and self.frameNo % FramePacer.OPTION_POLL == 0 then
    local okS, v = pcall(self.stepOption)
    if okS then self:setGcMode(v) end
  end
end

-- GC PACING value: "0" | "0.5" | "1" (fix 1d) or "slack" (Lab 51). Unknown
-- values are ignored (the mode stays). Leaving SLACK gives the collector back
-- at once; entering it cancels the render test (they are mutually exclusive).
function FramePacer:setGcMode(v)
  if v == "slack" then
    if self.gcMode ~= "slack" then
      self.gcMode, self.gcStepMs = "slack", 0
      self:cancelCollector("GC MODE SLACK")
      self.log("pacer gc mode SLACK: collector steps only before xrWaitFrame, sized to the idle time; automatic collector back whenever the stereo frame is not running")
    end
    return
  end
  local msv = tonumber(v)
  if not msv then return end
  local wasSlack = self.gcMode == "slack"
  if wasSlack then self:_slackRelease("GC mode changed") end
  self.gcMode = msv > 0 and "pace" or "off"
  if wasSlack or msv ~= (self.gcStepMs or 0) then
    self.gcStepMs = msv
    self.log(("pacer gc pacing %s"):format(msv > 0 and (("ON: %.1f ms after each xrEndFrame"):format(msv)) or "OFF"))
  end
end

-- ------------------------------------------------------------ GC MODE SLACK (Lab 51)
function FramePacer:_slackInstance()
  local s = self.slack
  if s then return s end
  if s == false then return nil end
  if type(V) == "table" and type(V.require) == "function" then
    local ok, M = pcall(V.require, "quest/GcSlack")
    if ok and type(M) == "table" and type(M.new) == "function" then
      local made, inst = pcall(M.new, { gc = gcount, clock = getTime })
      if made and type(inst) == "table" then self.slack = inst; return inst end
    end
  end
  self.slack = false
  self.log("pacer gc mode SLACK unavailable: GcSlack did not load; the normal collector stays")
  return nil
end

local function outerRegistry()
  local r = love and love._pacerOuterLoop
  if type(r) == "table" then return r end
  return nil
end

function FramePacer:_slackLease()
  local reg = outerRegistry()
  if not reg then return end
  local lease = self.slackLeaseRec
  if not lease then
    local pacer = self
    lease = { release = function(reason) pacer:_slackRelease(reason or "engine watchdog") end }
    self.slackLeaseRec = lease
  end
  lease.renewed = tonumber(rawget(reg, "loopIteration")) or 0
  lease.stepmul = self.slack and self.slack.savedStepmul or 200
  lease.limit = FramePacer.SLACK_LEASE_ITERATIONS
  reg.gcLease = lease
end

function FramePacer:_slackLeaseClear()
  local reg = outerRegistry()
  if reg and self.slackLeaseRec and rawget(reg, "gcLease") == self.slackLeaseRec then reg.gcLease = nil end
end

-- Gives the automatic collector back (idempotent; safe when SLACK never ran).
function FramePacer:_slackRelease(reason)
  local s = self.slack
  if s and s.owned then
    s:release(reason)
  end
  self:_slackLeaseClear()
end

-- main.lua, before r.xr:frame{}: will this frame be a stereo world frame?
function FramePacer:slackFrame(want)
  self.slackWant = want == true
end

-- main.lua, after every questFrame (also after an error or an early return):
-- `world` is true only when this frame really submitted the stereo world.
-- Anything else hands the collector back now.
function FramePacer:slackAfterFrame(world)
  self.slackWant = false
  if world ~= true then self:_slackRelease("no stereo frame") end
end

-- Inside the XR proxy, right before xrWaitFrame.
function FramePacer:_slackBeforeWait()
  if self.gcMode ~= "slack" then return end
  local s = self:_slackInstance()
  if not s then return end
  if s.overflow then s:pollOverflow() end
  local scope = self.collector
  if self.slackWant ~= true or self.pause or not self.cpuEnabled or (scope and (scope.stage ~= 0 or scope.lease)) then
    self:_slackRelease(self.pause and "GC pause test" or "not a stereo frame")
    return
  end
  if not s.owned and not s:acquire() then return end
  self:_slackLease()
  local spent = s:step()
  if s.owned then self:_slackLease() else self:_slackLeaseClear() end -- overflow hands it back
  if spent > 0 then
    self.cur.gc = self.cur.gc + spent / 1000
    local calls = s.lastCalls or 0
    self.gcAttempts, self.gcCompleted = self.gcAttempts + calls, self.gcCompleted + calls
    local chunk = (s.lastChunkMaxMs or 0) / 1000
    if chunk > self.gcMaxStep then self.gcMaxStep = chunk end
    if s.lastDone then self.gcCyclesComplete = self.gcCyclesComplete + 1 end
  end
end

local function percentile(sorted, n, p)
  if n == 0 then return 0 end
  local i = math.max(1, math.min(n, math.floor(p * n + 0.5)))
  return sorted[i]
end

function FramePacer:_logWindow()
  local reportT0=self.cpuEnabled and getTime() or nil
  local win, walls = self.win, self.walls
  local n = win.n
  for i = #walls, n + 1, -1 do walls[i] = nil end
  table.sort(walls)
  local span = math.max(1e-6, getTime() - (win.t0 or getTime()))
  local parts, other = {}, win.sum
  for i = 1, #PARTS do
    local k = PARTS[i]
    other = other - win.parts[k]
    parts[#parts + 1] = k .. "=" .. ("%.2f"):format(win.parts[k] * 1000 / n)
  end
  parts[#parts + 1] = "other=" .. ("%.2f"):format(other * 1000 / n)
  local s = self.slowest
  local sp, sother = {}, s.wall
  for i = 1, #PARTS do
    local k = PARTS[i]
    sother = sother - s.parts[k]
    if s.parts[k] >= 0.0005 then sp[#sp + 1] = k .. "=" .. ms(s.parts[k]) end
  end
  sp[#sp + 1] = "other=" .. ms(sother)
  local heapMB = (self.heapKB or 0) / 1024
  self.last = {
    frames = n, fps = n / span, avgMs = win.sum * 1000 / n,
    p50Ms = percentile(walls, n, 0.5) * 1000, p99Ms = percentile(walls, n, 0.99) * 1000,
    maxMs = win.max * 1000, slow = win.slow, hitch = win.hitch,
    heapMB = heapMB, heapMinMB = win.heapMin / 1024, heapMaxMB = win.heapMax / 1024,
    growKBPerFrame = win.grow / n, cycles = win.cycles, cyclesTotal = self.cyclesTotal,
    slowOnCycle = win.slowCycled, slowestMs = s.wall * 1000, slowestFrame = s.frame,
    slowestOnCycle = s.cycled,
  }
  local L = self.last
  self.log(("pacer n=%d fps=%.1f frame avg=%.1f p50=%.1f p99=%.1f max=%.1fms slow>%d=%d (on a gc-cycle end %d) hitch>%d=%d"
    .. " | avg ms %s | heap=%.1fMB (%.1f-%.1f) grow=%.0fKB/f gc-cycles=%d (total %d)"
    .. " | slowest #%d %.1fms%s: %s")
    :format(n, L.fps, L.avgMs, L.p50Ms, L.p99Ms, L.maxMs, FramePacer.SLOW_MS, L.slow, L.slowOnCycle,
      FramePacer.HITCH_MS, L.hitch, table.concat(parts, " "), heapMB, L.heapMinMB, L.heapMaxMB,
      L.growKBPerFrame, L.cycles, L.cyclesTotal, s.frame, L.slowestMs,
      s.cycled and " (a gc cycle ended in it)" or "", table.concat(sp, " ")))
  -- Lab 49: FLAT DRAW RATE counts for the same window (Display.present calls)
  if self.flatRate then
    local okF, d, sk, fb, ge, rate = pcall(self.flatRate)
    if okF then
      self.log(("pacer flat-rate n=%d rate=1/%s drawn=%d skipped=%d fallback=%d gateErrors=%d; Display.present calls this window")
        :format(n, tostring(rate), tonumber(d) or 0, tonumber(sk) or 0, tonumber(fb) or 0, tonumber(ge) or 0))
    else
      self.log("pacer flat-rate unavailable: " .. tostring(d))
    end
  end
  -- Lab 51: GC MODE SLACK telemetry for the same window
  local slack = self.slack
  if slack and (self.gcMode == "slack" or slack.win.frames > 0) then self.log(slack:windowLine(n)) end
  self:_logLayerTiming()
  self:_logPassTiming() -- Lab 55 (G0)
  self:_logOuterTiming()
  self:_logChronology(n)
  -- reset the window (reuse tables)
  win.n, win.sum, win.max, win.slow, win.hitch, win.cycles = 0, 0, 0, 0, 0, 0
  win.slowCycled = 0
  win.heapMin, win.heapMax, win.grow, win.t0 = math.huge, 0, 0, nil
  for i = 1, #PARTS do win.parts[PARTS[i]] = 0 end
  s.wall, s.frame = 0, 0
  for i = 1, #PARTS do s.parts[PARTS[i]] = 0 end
  self.reportPending=reportT0 and (getTime()-reportT0) or 0
end

-- ------------------------------------------------------------ GC pacing (fix 1d)
-- Bounded incremental collector work at a chosen point of the frame: right
-- after xrEndFrame on the Quest (the eyes are submitted; the next frame has
-- not started), at the frame start on a desktop test. Steps until the
-- budget is spent or a cycle finishes (a finished cycle never starts the
-- next one in the same call). OFF unless gcStepMs (or GC_STEP_MS) > 0 and
-- never while the GC-pause experiment runs. Its time is the "gc" part.
function FramePacer:gcPace()
  if self.collector and self.collector.lease then return end
  local budget = self.gcStepMs or FramePacer.GC_STEP_MS
  if not budget or budget <= 0 or self.pause then return end
  local t0 = getTime()
  local limit = t0 + budget / 1000
  local kb, n = FramePacer.GC_STEP_KB, 0
  repeat
    n = n + 1
    if self.cpuEnabled then
    self.gcAttempts=self.gcAttempts+1
    local stepStart=getTime()
    local complete=gcount("step", kb)
    local elapsed=getTime()-stepStart
    self.gcCompleted=self.gcCompleted+1
    if elapsed>self.gcMaxStep then self.gcMaxStep=elapsed end
    if complete then self.gcCyclesComplete=self.gcCyclesComplete+1;break end
    elseif gcount("step", kb) then break end
  until getTime() >= limit or n >= 4096
  self.cur.gc = self.cur.gc + (getTime() - t0)
end

-- ------------------------------------------------------------ GC pause (debug)
local function windowLine(tag, w)
  local n = math.max(1, w.n)
  return ("%s %.1fs frames=%d avg=%.1fms max=%.1fms slow>%d=%d hitch>%d=%d gc-cycles=%d heap %.1f->%.1fMB")
    :format(tag, w.span or 0, w.n, w.sum * 1000 / n, w.max * 1000, FramePacer.SLOW_MS, w.slow,
      FramePacer.HITCH_MS, w.hitch, w.cycles, (w.heap0 or 0) / 1024, (w.heap1 or 0) / 1024)
end

local function experimentWindow(keys)
  local w = newWindow()
  w.allocKB, w.allocCalls, w.allocAttempts = newHeapParts(keys), newHeapParts(keys), newHeapParts(keys)
  return w
end

local function allocationLine(tag, w)
  local parts = {}
  for i = 1, #HEAP_KEYS do
    local key = HEAP_KEYS[i]
    local calls = w.allocCalls[key]
    if calls > 0 then
      parts[#parts + 1] = ("%s=%.1fKB/call (n=%d, sum=%.1fKB)")
        :format(key, w.allocKB[key] / calls, calls, w.allocKB[key])
    end
  end
  for _,key in ipairs(HOST_HEAP_KEYS)do
    local attempts=(w.allocAttempts and w.allocAttempts[key]) or 0
    local completed=w.allocCalls[key] or 0
    local start=w.hostHeapStart and w.hostHeapStart[key] or false
    local finish=w.hostHeapEnd and w.hostHeapEnd[key] or false
    parts[#parts+1]=("%s-status ownedStart=%s ownedEnd=%s attempts=%d completed=%d incomplete=%d")
      :format(key,tostring(start),tostring(finish),attempts,completed,attempts-completed)
  end
  return "pacer heap-seams " .. tag .. ": " .. table.concat(parts, " ")
    .. " | inclusive nested calls overlap; do not sum seams"
end

-- Starts the experiment: BASE window (collector running) of `seconds`, then
-- the collector stopped for `seconds`. Returns false if one is running.
function FramePacer:pauseGC(seconds)
  if self.collector and self.collector.lease then return false end
  self:cancelCollector("GC pause requested")
  if self.pause then return false end
  self:_slackRelease("GC pause test") -- Lab 51: SLACK yields while the test runs (mutually exclusive)
  seconds = tonumber(seconds) or FramePacer.GC_PAUSE_S
  if seconds ~= seconds then seconds = FramePacer.GC_PAUSE_S end
  seconds = math.max(1, math.min(FramePacer.GC_PAUSE_S, seconds))
  self:_ensureFineProbes()
  self:_ensureInputHookProbes()
  self:_ensureCatchProbes()
  self:_ensureSeam51Probes() -- Lab 51 heap seams (installed only for the test)
  self.log(("pacer catch-subcall probes available=%s installed=%d; missing means unavailable, not zero")
    :format(tostring(self.catchProbeReady), self.catchProbeCount or 0))
  self:_logInputHookCoverage("BASE start")
  local now = getTime()
  self.pause = { stage = "base", seconds = seconds, t0 = now, win = experimentWindow(self.heapKeys), base = nil }
  self:_hostHeapCoverage(self.pause.win,"hostHeapStart")
  self.pause.win.heap0 = gcount("count")
  self.log(("pacer gc-pause: measuring %.0fs with the collector running, then %.0fs stopped"):format(seconds, seconds))
  self.log(("pacer heap-probes available fixedUpdate=%s nativeRuntime=%s audioUpdate=%s inputStep=%s; missing means unavailable, not zero")
    :format(tostring(self.probeReady.fixedUpdate), tostring(self.probeReady.nativeRuntime),
      tostring(self.probeReady.audioUpdate), tostring(self.probeReady.inputStep)))
  return true
end

function FramePacer:_pauseFrame(pz, wall)
  local w = pz.win
  w.n, w.sum = w.n + 1, w.sum + wall
  if wall > w.max then w.max = wall end
  if wall * 1000 > FramePacer.SLOW_MS then w.slow = w.slow + 1 end
  if wall * 1000 > FramePacer.HITCH_MS then w.hitch = w.hitch + 1 end
  local now = getTime()
  local kb = gcount("count")
  if pz.stage == "base" then
    if now - pz.t0 >= pz.seconds then
      w.span, w.heap1 = now - pz.t0, kb
      self:_hostHeapCoverage(w,"hostHeapEnd")
      pz.base = w
      pz.stage, pz.t0 = "stopped", now
      self:_logInputHookCoverage("BASE end / STOPPED start")
      pz.win = experimentWindow(self.heapKeys)
      self:_hostHeapCoverage(pz.win,"hostHeapStart")
      pz.win.heap0 = kb
      gcount("stop")
    end
  elseif pz.stage == "stopped" then
    local capped = (kb - (w.heap0 or kb)) / 1024 > FramePacer.GC_PAUSE_HEAP_MB
    if capped or now - pz.t0 >= pz.seconds then
      w.span, w.heap1 = now - pz.t0, kb
      self:_hostHeapCoverage(w,"hostHeapEnd")
      gcount("restart")
      self.pause = nil
      self.log("pacer gc-pause result: " .. windowLine("running", pz.base) .. " | "
        .. windowLine("STOPPED", w) .. (capped and " (ended early: heap cap)" or ""))
      self.log(allocationLine("BASE net heap (GC running)", pz.base))
      self.log(allocationLine("STOPPED inclusive heap delta", w))
      self:_logInputHookAllocations("BASE net heap", pz.base)
      self:_logInputHookAllocations("STOPPED", w)
      self:_logInputHookCoverage("STOPPED end")
      self:_logCatchAllocations("BASE net heap", pz.base)
      self:_logCatchAllocations("STOPPED", w)
      self:_logSeam51("BASE net heap (GC running)", pz.base)
      self:_logSeam51("STOPPED inclusive heap delta", w)
      self.lastPause = { base = pz.base, stopped = w, capped = capped }
    end
  end
end

-- Never leave the collector stopped (teardown, a rebuilt renderer).
function FramePacer:cancelPause(reason)
  local pz = self.pause
  if not pz then return end
  self.pause = nil
  if pz.stage == "stopped" then gcount("restart") end
  self.log("pacer gc-pause cancelled (" .. tostring(reason) .. ")")
end

-- ------------------------------------------------------------ install
-- r = main.lua's renderer table (view, hostApi, xr). opts = { log, game =
-- fn() -> game instance, android = bool, option = fn() -> bool, exports =
-- mod.exports }. Returns the pacer.
function FramePacer.install(r, opts)
  opts = opts or {}
  if active then
    active:cancelPause("renderer rebuilt")
    active:detach()
  end
  local self = FramePacer.new(opts)
  self.getGame = opts.game
  self.renderer = r
  if type(r) == "table" then
    local view = r.view
    if view then
      -- the pump wrapper also (re)attaches the game update wrapper lazily:
      -- the game instance can be created after the renderer
      if type(view.pump) == "function" then
        local target, raw = resolver(view, "pump")
        local pacer = self
        view.pump = function(v, game, ...)
          if game ~= pacer.game and type(game) == "table" then
            pacer.game = game
            FramePacer.attachGame(game)
          end
          local window, heap0 = pacer:_heapStart()
          local t0 = getTime()
          return pacer:_addMeasured("pump", t0, window, heap0, target()(v, game, ...))
        end
        self.wrapped[#self.wrapped + 1] = { obj = view, name = "pump", raw = raw, fn = view.pump }
      end
      self:_wrap(view, "prepare", "prepare")
      self:_wrap(view, "renderEye", "eyes")
      view._pacerPass = self.passObserver -- Lab 55 (G0)
    end
    if type(r.scene) == "table" then r.scene._pacerPass = self.passObserver end -- Lab 55 (G0)
    if r.hostApi then
      self.hostApi = r.hostApi
      self:_bindLayerTiming()
      self:_wrap(r.hostApi, "beginFrame", "layers", "hostBeginFrame")
      self:_wrap(r.hostApi, "updateLayers", "layers", "hostUpdateLayers")
    end
    if opts.android and r.xr then self:_wrapXR(r.xr) end
  end
  if type(self.getGame) == "function" then
    local okG, game = pcall(self.getGame)
    if okG and type(game) == "table" then
      self.game = game
      FramePacer.attachGame(game)
    end
  end
  if type(opts.exports) == "table" then opts.exports.framePacer = self end
  active = self
  return self
end

-- Undo this pacer's instance wrappers (only where they are still ours).
function FramePacer:detach()
  self:cancelCollector("renderer detached")
  self:_slackRelease("renderer detached") -- Lab 51: never leave the collector stopped
  self.cpuEnabled = false
  local xr=self.xrRegistry
  if xr and xr.xrObserver==self.xrObserver then xr.xrObserver=self.xrPrevious end
  self.xrRegistry,self.xrPrevious=nil,nil
  local rtc=self.rtcRegistry
  if type(rtc)=="table" and rtc.rtcObserver==self.rtcObserver then rtc.rtcObserver=self.rtcPrevious end
  self.rtcRegistry,self.rtcPrevious=nil,nil
  local tablet=self.tabletRegistry
  if tablet and tablet.tabletObserver==self.tabletObserver then tablet.tabletObserver=self.tabletPrevious end
  self.tabletRegistry,self.tabletPrevious=nil,nil
  self:_bindFieldInnerTiming(nil)
  local outer = self.outerRegistry
  if outer and outer.observer == self.outerObserver then outer.observer = self.outerPrevious end
  self.outerRegistry, self.outerPrevious = nil, nil
  self.outerPendingTime, self.outerPendingToken = nil, nil
  local registry = self.cpuRegistry
  if registry and registry._pacerUpdateTiming == self.cpuObserver then
    registry._pacerUpdateTiming = self.cpuPreviousObserver
  end
  self.cpuRegistry, self.cpuPreviousObserver = nil, nil
  self:cancelPause("renderer detached")
  local r = type(self.renderer) == "table" and self.renderer or nil -- Lab 55 (G0)
  if r and type(r.view) == "table" and rawget(r.view, "_pacerPass") == self.passObserver then r.view._pacerPass = nil end
  if r and type(r.scene) == "table" and rawget(r.scene, "_pacerPass") == self.passObserver then r.scene._pacerPass = nil end
  for i = #self.wrapped, 1, -1 do
    local w = self.wrapped[i]
    if rawget(w.obj, w.name) == w.fn then rawset(w.obj, w.name, w.raw) end
    self.wrapped[i] = nil
  end
  if active == self then active = nil end
end

function FramePacer.active() return active end

return FramePacer
