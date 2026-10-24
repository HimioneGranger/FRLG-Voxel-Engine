-- One record per worker. Fixed FRLG cache ownership; never loads mod code.
require('love.filesystem')
require('love.thread')
require('love.timer')
local inputName, outputName, cancelName, rk, expectedRoute = ...
local input, output, cancel = love.thread.getChannel(inputName), love.thread.getChannel(outputName), love.thread.getChannel(cancelName)
local PREFIX = 'mod_cache/FRLG_VOXEL/fr-precache/v1/'
local MAX = 64 * 1024 * 1024
local owned, header, nextPart = {}, false, 1
local fs
local function removeIfPresent(path)
 if not fs.getInfo(path) then return true end
 return fs.remove(path)==true and fs.getInfo(path)==nil
end
local function cleanup()
 -- Invalidate the record before removing any data part. If invalidation
 -- fails, preserve the parts and let the host report failed cleanup.
 local headerPath=PREFIX .. rk .. '.h'
 if owned[headerPath] and not removeIfPresent(headerPath) then return false end
 local ok=true
 for path in pairs(owned) do
  if path~=headerPath and not removeIfPresent(path) then ok=false end
 end
 return ok
end
local function run()
 local SaveData=require('src.core.SaveData')
 local base=SaveData.portableBaseDir()
 fs=assert(SaveData.persistenceFs(love.filesystem),'cache filesystem unavailable')
 local route=base and ('portable:'..base) or ('love:'..love.filesystem.getSaveDirectory())
 assert(route==expectedRoute,'cache persistence root mismatch')
 assert(type(rk)=='string' and #rk==32 and rk:match('^[0-9a-f]+$'), 'invalid cache key')
 while true do
  if cancel:pop() then return 'cancelled' end
  local command = input:demand(0.1)
  if command then
   if command.kind=='commit' then assert(header, 'commit before header'); return 'committed' end
   assert(command.kind=='write' and not header, 'invalid writer command')
   local suffix = command.rel:match('^fr%-precache/v1/' .. rk .. '(%..+)$')
   assert(suffix=='.h' or suffix=='.p'..nextPart, 'invalid or out-of-order cache path')
   assert(type(command.bytes)=='string' and #command.bytes<=MAX, 'invalid cache payload')
   assert(type(command.id)=='number', 'invalid write id')
   if cancel:peek() then return 'cancelled' end
   local path=PREFIX .. rk .. suffix
   local headerPath=PREFIX .. rk .. '.h'
   if not owned[headerPath] then
    owned[headerPath]=true
    assert(removeIfPresent(headerPath),'cache header invalidation failed')
   end
   -- Claim before calling the filesystem: partial writes must also be removed.
   owned[path]=true
   local t=love.timer and love.timer.getTime and love.timer.getTime() or 0
   assert(fs.createDirectory('mod_cache/FRLG_VOXEL/fr-precache/v1') ~= false, 'cache directory failed')
   assert(fs.write(path, command.bytes), 'cache write failed')
   command.bytes=nil
   if cancel:peek() then return 'cancelled' end
   header=suffix=='.h'
   if not header then nextPart=nextPart+1 end
   output:push{kind='ack',id=command.id,ms=(love.timer and love.timer.getTime and (love.timer.getTime()-t)*1000 or 0)}
  end
 end
end
local ok, state=pcall(run)
local clean=true
if not ok or state~='committed' then
 local cleaned, result=pcall(cleanup);clean=cleaned and result
end
input:clear() -- Drop queued strings promptly on cancellation.
output:push{kind='terminal',state=ok and state or 'failed',reason=not ok and tostring(state) or nil,clean=clean}
