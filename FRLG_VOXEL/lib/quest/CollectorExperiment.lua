-- One-shot callback-scoped diagnostic; never replaces global collectgarbage.
local M={};M.__index=M
M.STAGES={IDLE=0,SETTLE=1,SHAM_A1=2,STOP_B=3,SHAM_A2=4}
local function safe(fn,...)if type(fn)~='function'then return false,'missing capability' end;return pcall(fn,...)end
local function finite(n)return type(n)=='number'and n==n and math.abs(n)<math.huge end
local function time(clock)local ok,t=safe(clock);if ok and finite(t)then return t end end
local function heap(gc)local ok,n=safe(gc,'count');if ok and finite(n)then return n end end
local function running(gc)local ok,r=safe(gc,'isrunning');if ok and type(r)=='boolean'then return r and 1 or 0 end;return -1 end
function M.new(opts)
 opts=opts or {};local self=setmetatable({clock=opts.clock,gc=opts.gc,log=opts.log,stage=0,lease=false,
  entered=0,ended=0,stopCount=0,restartCount=0,reason='idle'},M);self:beginFrame();return self
end
function M:beginFrame()
 if self.lease then return false end
 self.callStage=self.stage;self.calls=0;self.spanMs=-1;self.callMs=-1;self.heapDeltaKiB=0
 self.stopAttempts=0;self.stopOK=0;self.restartAttempts=0;self.restartOK=0
 self.entryRunning=-1;self.duringRunning=-1;self.exitRunning=-1;self.renderOK=-1
 self.recordValid=false
 return true
end
M.resetFrame=M.beginFrame
function M:_edge(reason,err)
 self.stage=0;self.reason=reason;self.error=err;self.settleAt=nil
 if self.lease then self.pendingReason=reason;self.pendingError=err;return end
 safe(self.log,reason,self.callStage,self.spanMs,self.experimentHeapDeltaKiB)
end
function M:cancel(reason)self:_edge(reason or 'cancelled')end
function M:arm()
 if self.stage~=0 or self.lease then return false end
 local t=time(self.clock);if not t then self.reason='clock capability';return false end
 self.stage=1;self.armAt=t;self.lastFrameAt=nil;self.settleAt=nil;self.identity=nil;self.startHeap=nil
 self.entered=0;self.ended=0;self.stopCount=0;self.restartCount=0;self.error=nil;self.pendingReason=nil
 self.reason='armed';self:beginFrame();safe(self.log,'armed',1,t);return true
end
function M:frame(eligible,budget,pauseActive,identity,frameToken)
 if self.lease then self.frameToken=frameToken;self:_edge('reentrant frame');return end
 if self.stage==0 then return end
 local t=time(self.clock);if not t then self:_edge('clock capability');return end
 if t-self.armAt>=45 then self:_edge('deadline');return end
 if self.lastFrameAt and t-self.lastFrameAt>.250 then self:_edge('frame gap');return end
 self.lastFrameAt=t
 self.frameToken=frameToken
 if budget~=.5 or pauseActive then self:_edge('collector settings conflict');return end
 if self.stage==1 then
  if t-self.armAt>=20 then self:_edge('settling deadline');return end
  if not eligible then self.settleAt=nil;self.identity=nil;return end
  if self.settleAt==nil or self.identity~=identity then self.settleAt=t;self.identity=identity end
  if t-self.settleAt>=2 then self.stage=2;self.phaseAt=t;self.reason='SHAM_A1';safe(self.log,self.reason,2,t)end
  return
 end
 if not eligible then self:_edge('eligibility lost');return end
 if self.identity~=identity then self:_edge('identity changed');return end
 if t-self.phaseAt>=8 then
  if self.stage==4 then self:_edge('complete');return end
  self.stage=self.stage+1;self.phaseAt=t;self.reason=self.stage==3 and 'STOP_B'or'SHAM_A2';safe(self.log,self.reason,self.stage,t)
 end
end
function M:_cap(n)
 if not self.startHeap then self.startHeap=n end
 self.experimentHeapDeltaKiB=n-self.startHeap
 return n>=384*1024 or self.experimentHeapDeltaKiB>=32*1024
end
local function restore(self,gc)
 -- First collector operation after protected callback. Readback is required.
 for i=1,2 do
  local ok,err=safe(gc,'restart')
  self.restartAttempts=self.restartAttempts+1;self.restartCount=self.restartCount+1
  if ok then self.restartOK=self.restartOK+1 end
  self.exitRunning=running(gc)
  if ok and self.exitRunning==1 then return true end
  self.cleanupError=err or 'restart readback failed'
 end
 return false
end
function M:call(fn,views)
 if self.lease then self:_edge('reentrant callback');return pcall(fn,views)end
 local stage=self.stage;self.callStage=stage
 if stage<2 then return pcall(fn,views)end
 if self.calls~=0 then self:_edge('duplicate frame callback');return pcall(fn,views)end
 local token=self.frameToken
 self.callFrameToken=token
 local gc,clock=self.gc,self.clock
 self.entryRunning=running(gc)
 if self.entryRunning~=1 then self:_edge('collector ownership/capability');return pcall(fn,views)end
 local startHeap=heap(gc)
 if not startHeap then self:_edge('heap capability');return pcall(fn,views)end
 if self:_cap(startHeap)then self:_edge('heap cap');return pcall(fn,views)end
 local before=time(clock)
 if not before then self:_edge('clock capability');return pcall(fn,views)end
 self.lease=true;self.calls=self.calls+1
 local policyOK=true
 if stage==3 then
  self.stopAttempts=self.stopAttempts+1
  local ok,err=safe(gc,'stop');if ok then self.stopOK=self.stopOK+1;self.stopCount=self.stopCount+1 end
  self.duringRunning=running(gc)
  if not ok or self.duringRunning~=0 then policyOK=false;self.pendingReason='stop capability';self.pendingError=err end
 else
  self.duringRunning=running(gc)
  if self.duringRunning~=1 then policyOK=false;self.pendingReason='collector readback' end
 end
 -- Failed entry mutation is restored before invoking the real callback.
 if not policyOK then
  local cleaned=restore(self,gc);self.lease=false
  self:_edge(cleaned and (self.pendingReason or 'entry failure')or'restart capability',self.pendingError or self.cleanupError)
  self.pendingReason=nil;return pcall(fn,views)
 end
 self.entered=self.entered+1
 local ok,canvases,why=pcall(fn,views)
 local cleaned=restore(self,gc)
 self.lease=false;self.ended=self.ended+1;self.renderOK=ok and canvases and 1 or 0
 local after=time(clock)
 if after then self.spanMs=(after-before)*1000;self.callMs=self.spanMs end
 local endHeap=heap(gc)
 if endHeap then self.heapDeltaKiB=endHeap-startHeap end
 local cap=endHeap and self:_cap(endHeap)
 self.recordValid=cleaned and self.frameToken==token and self.gc==gc and not self.pendingReason
 if not cleaned then self:_edge('restart capability',self.cleanupError)
 elseif self.pendingReason then self:_edge(self.pendingReason,self.pendingError)
 elseif self.frameToken~=token then self:_edge('frame token changed')
 elseif self.gc~=gc then self:_edge('collector owner changed')
 elseif not ok or not canvases then self:_edge('callback error',canvases or why)
 elseif not after then self:_edge('clock capability')
 elseif not endHeap then self:_edge('heap capability')
 elseif self.spanMs>100 then self:_edge('callback exceeded 100ms')
 elseif cap then self:_edge('heap cap')end
 if not self.recordValid then self.calls=0 end
 self.pendingReason=nil;self.pendingError=nil
 return ok,canvases,why
end
return M
