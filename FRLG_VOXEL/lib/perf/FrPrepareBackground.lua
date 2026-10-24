-- Sandboxed main-thread channel controller. All native/file operations live
-- in the engine-owned CPU worker; existing mod permissions remain unchanged.
local M={};M.__index=M
local live;local sequence=0
local function jobKey(input)
 return tostring(input.mapId or ''):gsub('#border$','')..(input.isBorder and ':ring' or ':map')
end
function M.new(env)
 assert(env.thread and env.clock,'CPU coordinator dependencies')
 return setmetatable({env=env,phase='idle',records={},done=0,total=0,failures=0},M)
end
function M:start(config,jobs,workerSource)
 if self.phase~='idle'then return false,'already-started'end
 if live and live.worker and live.worker:isRunning()then return false,'previous-worker-running'end
 sequence=sequence+1
 local token='cpu-'..math.floor(self.env.clock()*1000000)..'-'..sequence
 self.token=token
 local T=self.env.thread
 self.input=T.getChannel('fr-cpu-input-'..token);self.output=T.getChannel('fr-cpu-output-'..token)
 self.cancelChannel=T.getChannel('fr-cpu-cancel-'..token)
 self.acks=T.getChannel('fr-cpu-acks-'..token);self.acks:clear()
 self.jobs={};self.released={}
 for _,job in ipairs(jobs)do self.jobs[jobKey(job)]='pending'end
 self.input:clear();self.output:clear();self.cancelChannel:clear();config.requireGuard=true
 local ok,err=pcall(function()
  self.worker=T.newThread(workerSource)
  self.input:push(config)
  for _,job in ipairs(jobs)do self.input:push(job)end
  self.input:push(false)
  self.worker:start('fr-cpu-input-'..token,'fr-cpu-output-'..token,'fr-cpu-cancel-'..token,token)
 end)
 if not ok then self.phase='fallback';return false,tostring(err)end
 self.total=#jobs;self.phase='cpu';live=self
 return true
end
function M:poll()
 if not self.worker then return self.phase end
 while true do
  local item=self.output:pop();if not item then break end
  if item.phase=='cpu-ready'then
   local id=tostring(item.mapId or ''):gsub('#border$','')
   if self.released[id]then self.acks:push({path=item.path});self.jobs[jobKey(item)]='fallback'
   else
    self.records[id]=self.records[id]or {};self.records[id][item.isBorder and 'ring'or 'map']=item
    self.jobs[jobKey(item)]='ready'
   end
   self.done=self.done+1
  elseif item.phase=='cpu-sources'then self.sourceKey=item.sourceKey
  elseif item.phase=='cpu-guarded'then self.guarded=true
  elseif item.phase=='foreground-fallback'then self.jobs[jobKey(item)]='fallback';self.done=self.done+1;self.failures=self.failures+1
  elseif item.phase=='cpu-failed'then self.reason=item.reason;self.terminal='fallback'
  elseif item.phase=='cpu-stopped'then self.terminal=self.cancelled and 'cancelled'or 'cpu-ready'end
 end
 if not self.worker:isRunning()then
  local err=self.worker:getError()
  if err then self.reason=tostring(err);self.phase='fallback'
  elseif self.terminal then self.phase=self.terminal
  elseif self.phase=='cpu'then self.reason='worker-ended-without-status';self.phase='fallback'end
 end
 return self.phase
end
function M:cancel()
 self.cancelled=true
 if self.worker and self.worker:isRunning()then self.cancelChannel:push(true)
 else self.phase='cancelled'end
end
function M:status(input)
 self:poll()
 local status=self.jobs and self.jobs[jobKey(input)]
 if status=='pending'and(self.cancelled or self.phase~='cpu')then return 'fallback'end
 return status or 'unrequested'
end
-- Map geometry can be reused for the FAR canonical record, so release at the
-- whole-map boundary rather than on the first consume.
function M:releaseJob(id)
 self.released[tostring(id)]=true
 self:poll()
 local records=self.records[tostring(id)]
 if records then
  for _,item in pairs(records)do self.acks:push({path=item.path})end
  self.records[tostring(id)]=nil
 end
end
function M:record(input)
 self:poll()
 local records=self.records[tostring(input.mapId or ''):gsub('#border$','')]
 return records and records[input.isBorder and 'ring'or 'map']or nil
end
return M
