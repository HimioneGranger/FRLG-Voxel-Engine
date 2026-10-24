-- Sandboxed coordinator. At most one payload is in flight; never joins a worker.
local IO={};IO.__index=IO
local live, sequence
sequence=0
IO.TIMEOUT=30
local function reap()
 if not live then return true end
 live:poll()
 if live.worker:isRunning() then return false end
 -- A native/thread failure can bypass the worker's Lua cleanup. Only clean
 -- after it is stopped, so it cannot recreate a file after deletion.
 if not live.committed and not (live.terminal and live.terminal.clean) then
  if live.cleanupBlocked then return false end
  local function remove(rel)
   local ok,present=pcall(live.cache.exists,live.cache,rel)
   if not ok then return false end
   if not present then return true end
   local removed,result=pcall(live.cache.delete,live.cache,rel)
   local checked,left=pcall(live.cache.exists,live.cache,rel)
   return removed and result==true and checked and not left
  end
  local header='fr-precache/v1/'..live.rk..'.h'
  local clean=not live.owned[header] or remove(header)
  if clean then
   for path in pairs(live.owned) do if path~=header and not remove(path) then clean=false end end
  end
  if not clean then live.cleanupBlocked=true;live.error='cache worker cleanup failed';return false end
 end
 live.input:clear();live.output:clear();live.cancelChannel:clear()
 live=nil
 return true
end
function IO.available()return reap()end
function IO.new(mod,rk,clock)
 if not reap() then return nil,'previous cache writer still stopping' end
 if not (love and love.thread and mod and mod.cache and mod.read) then return nil,'cache worker unavailable' end
 if type(rk)~='string' or #rk~=32 or not rk:match('^[0-9a-f]+$') then return nil,'invalid cache key' end
 local ok,result=pcall(function()
  sequence=sequence+1
  local token='fr-cache-io-'..math.floor(clock()*1000000)..'-'..sequence
  local SaveData=require('src.core.SaveData')
  local base=SaveData.portableBaseDir()
  local route=base and ('portable:'..base) or ('love:'..assert(SaveData.persistenceFs().getSaveDirectory()))
  local T=love.thread
  local self=setmetatable({rk=rk,cache=mod.cache,clock=clock,owned={},id=0},IO)
  self.input=T.getChannel(token..'-in');self.output=T.getChannel(token..'-out');self.cancelChannel=T.getChannel(token..'-cancel')
  self.input:clear();self.output:clear();self.cancelChannel:clear()
  self.worker=T.newThread(assert(mod:read('lib/perf/FrPrecacheIOWorker.lua'),'cache worker source missing'))
  self.worker:start(token..'-in',token..'-out',token..'-cancel',rk,route)
  return self
 end)
 if not ok then return nil,tostring(result) end
 live=result
 return result
end
function IO:poll()
 while true do
  local item=self.output:pop();if not item then break end
  if item.kind=='ack' and self.pending and item.id==self.pending.id then self.ack=item;self.pending=nil
  elseif item.kind=='terminal' then self.terminal=item end
 end
 if not self.worker:isRunning() then
  local err=self.worker:getError()
  if err then self.error=tostring(err)
  elseif not self.terminal then self.error='cache worker ended without status'
  elseif self.terminal.state=='failed' then self.error=self.terminal.reason end
 end
 if self.pending and self.clock()-self.pending.started>=IO.TIMEOUT then
  self.error='cache worker timeout';self:cancel()
 end
 return self.error
end
function IO:submit(rel,bytes)
 assert(not self.pending and not self.cancelled and not self.committed,'cache writer is busy or closed')
 assert(type(rel)=='string' and (rel=='fr-precache/v1/'..self.rk..'.h' or rel:match('^fr%-precache/v1/'..self.rk..'%.p[1-9][0-9]*$')),'invalid cache path')
 assert(type(bytes)=='string' and #bytes<=64*1024*1024,'invalid cache payload')
 self:poll();assert(not self.error and self.worker:isRunning(),self.error or 'cache worker stopped')
 self.id=self.id+1;self.ack=nil
 self.pending={id=self.id,started=self.clock()};self.owned[rel]=true
 self.owned['fr-precache/v1/'..self.rk..'.h']=true
 self.input:push{kind='write',id=self.id,rel=rel,bytes=bytes}
 return self.id
end
function IO:cancel()
 if self.cancelled or self.committed then return end
 self.cancelled=true;self.cancelChannel:push(true)
end
function IO:commit()
 assert(not self.pending and not self.cancelled and not self.error,'cache commit before successful writes')
 self.committed=true;self.input:push{kind='commit'}
end
return IO
