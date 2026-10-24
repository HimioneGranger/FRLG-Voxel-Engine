-- Dedicated CPU thread. No love.graphics/window/OpenXR, no scene or world-cache writer.
-- Initial args: input channel, result channel, cancellation channel, owned token.
require('love.data');require('love.timer');require('love.filesystem');require('love.thread');require('love.image');require('love.system')
local incomingName,resultName,cancelName,token=...
assert(type(token)=='string'and token:match('^[%w_-]+$')and #token<=80,'owner token')
local incoming=love.thread.getChannel(incomingName)
local results=love.thread.getChannel(resultName)
local cancel=love.thread.getChannel(cancelName)
local acks=love.thread.getChannel('fr-cpu-acks-'..token)
local marker='quest_world_prepare_active.flag'
local lastBeat=-math.huge
local guardRequired=false
local closeGuard
local outputPrefix=''
local function guardHeld()
 local status=love.filesystem.read('quest_world_prepare_guard.status')
 local info=love.filesystem.getInfo('quest_world_prepare_guard.status')
 local age=info and type(info.modtime)=='number'and os.time()-info.modtime or -1
 return status==token and age>=0 and age<=60
end
local function ownership()
 local s=love.filesystem.read(marker)
 return s==token
end
local function checkpoint(force)
 assert(cancel:peek()==nil,'cancelled')
 assert(ownership(),'preparation ownership lost')
 if guardRequired then assert(guardHeld(),'CPU wake guard acknowledgement lost')end
 local now=love.timer.getTime()
 if force or now-lastBeat>=5 then
  assert(love.filesystem.write(marker,token),'heartbeat write failed')
  lastBeat=now
 end
end
local function wrapFlora(base,NativeGround)
 local W={};for k,v in pairs(base)do W[k]=v end
 function W.new(env)
  local c,e=base.new(env);if not c then return c,e end
  c.retroGrassCells={};c.groundKeys=c.groundKeys or base.KEY
  function c:nativeGroundUv(cell,mid)
   local ground=NativeGround.resolve(self,cell,mid);assert(ground.uv,ground.reason)
   self.stats.nativeGroundDonors=self.stats.nativeGroundDonors or {}
   local key=ground.mid or ground.mode
   self.stats.nativeGroundDonors[key]=(self.stats.nativeGroundDonors[key]or 0)+1
   if ground.mode~='native-tile'then self.stats.nativeGroundFallbacks=(self.stats.nativeGroundFallbacks or 0)+1;self.stats.nativeGroundFallbackReason=ground.reason end
   return ground.uv
  end
  function c:grass(x,z,gy,uv,mid)
   self.retroGrassCells[#self.retroGrassCells+1]={x=x,z=z,y=gy,kind='tall'}
   self.stats.grassCells=self.stats.grassCells+1;return true,0
  end
  return c
 end
 return W
end
local function run()
 local config=incoming:demand(1)
 assert(type(config)=='table'and type(config.sources)=='table','source bundle')
 assert(cancel:peek()==nil,'cancelled')
 outputPrefix=config.outputPrefix or ''
 assert(outputPrefix==''or outputPrefix=='mod_cache/FRLG_VOXEL/','CPU output namespace')
 if config.requireGuard then
  local Native=assert(loadstring(assert(config.sources['perf/WorldPrepareNative']),'@cpu/WorldPrepareNative'))()
  local Guard=assert(loadstring(assert(config.sources['perf/WorldPrepareWorkerGuard']),'@cpu/WorkerGuard'))()
  closeGuard=Guard.start(token,Native,love.filesystem)
 end
 checkpoint(true)
 for _,name in ipairs(config.engineModuleNames or {})do
  assert(type(name)=='string'and name:match('^src%.[A-Za-z0-9_.]+$'),'CPU engine module name')
  config.sources['@engine/'..name]=assert(love.filesystem.read(name:gsub('%.','/')..'.lua'),'CPU host source '..name)
 end
 if config.requireGuard then
  local untilTime=love.timer.getTime()+10
  while not guardHeld()and love.timer.getTime()<untilTime do checkpoint();love.timer.sleep(.1)end
  assert(guardHeld(),'CPU wake guard not acknowledged')
  guardRequired=true
  results:push({phase='cpu-guarded'})
 end
 local loaded={};local V={};local engineLoaded={}
 local engineEnv=setmetatable({},{__index=_G})
 local function engineRequire(name)
  if engineLoaded[name]~=nil then return engineLoaded[name]end
  local raw=config.sources['@engine/'..name]
  assert(type(raw)=='string','unbundled CPU engine dependency '..tostring(name))
  local chunk=assert(loadstring(raw,'@cpu-engine/'..name))
  setfenv(chunk,engineEnv);local value=chunk();engineLoaded[name]=value;return value
 end
 engineEnv.require=engineRequire
 function V.require(name)
  if loaded[name]~=nil then return loaded[name]end
  local src=assert(config.sources[name],'unbundled dependency '..tostring(name))
  assert(type(src)=='string','module bytes')
  local chunk=assert(loadstring(src,'@cpu/'..name..'.lua'))
  setfenv(chunk,engineEnv)
  local value=chunk(V);assert(value~=nil,'nil module');loaded[name]=value;return value
 end
 local Snapshot=V.require('perf/FrPrepareCpuSnapshot')
 local Geometry=assert(loadstring(config.sources['perf/FrPrepareCpuGeometry'],'@cpu/Geometry'))(Snapshot)
 local F=V.require('perf/FrPrecacheFormat')
 local Store=assert(loadstring(config.sources['perf/FrPrepareCpuStore'],'@cpu/Store'))(F,Geometry)
 assert(type(config.voxelTrees)=='boolean','CPU tree mode missing')
 -- Thread modules have independent state; match the frozen foreground mode
 -- before producing geometry, including native tree ownership/flat-card skips.
 V.require('mesh/FrlgVoxelTree').enabled=config.voxelTrees
 local sourceKey=Store.sourceKey(config.sources,config.retroGrass,config.voxelTrees)
 results:push({phase='cpu-sources',sourceKey=sourceKey}) -- immutable configuration for this thread lifetime
 local function decode(raw)local r=F.reader(raw);local v=r:value();assert(r:left()==0,'trailing payload');return v end
 local function encode(v)local w=F.writer();w:value(v);return w:result()end
 local deps={MB=V.require('mesh/MB'),Constants=V.require('mesh/Constants'),
  BuildingProfiles=V.require('mesh/FrlgBuildingProfiles'),NativeFoliage=V.require('mesh/FrlgNativeFoliage'),
  NativeGrayGate=V.require('mesh/NativeGrayGate'),ConnectedHouseNative=V.require('mesh/FrlgConnectedHouseNative'),
  TowerNative=V.require('mesh/FrlgTowerNative'),require=V.require,log=function()end,
  yield=checkpoint,yieldSafe=checkpoint}
 if config.retroGrass then deps.Flora=wrapFlora(V.require('mesh/FrlgFlora'),V.require('grass/NativeGround'))
 else deps.Flora=V.require('mesh/FrlgFlora')end
 local Mesher=V.require('mesh/FrlgMesher')
 local native,atlasSnapshots
 local Signs
 if config.native then
  local n=config.native
  assert(n.game=='firered'or n.game=='leafgreen','FRLG CPU game identity')
  assert(engineRequire('src.core.GameVersion').set(n.game)==n.game,'CPU engine identity')
  local Native=assert(loadstring(config.sources['perf/FrPrepareCpuNative'],'@cpu/Native'))()
  Signs=assert(loadstring(config.sources['perf/FrPrepareCpuSigns'],'@cpu/Signs'))(V.require('render/SignPixelFont'),V.require('data/SignProfiles'))
  local cache
  if n.cacheReader=='active'then cache=engineRequire('src.import.CacheFs')end
  local function readNative(path)
   if cache then return cache.readActive(path)end
   assert(type(n.cachePrefix)=='string','explicit native read mount required')
   return love.filesystem.read(n.cachePrefix..path)
  end
  if n.cachePrefixes then
   n.cachePrefix=nil
   for _,prefix in ipairs(n.cachePrefixes)do
    assert(type(prefix)=='string'and not prefix:find('..',1,true)and prefix:sub(1,1)~='/','native cache prefix')
    local manifest=love.filesystem.read(prefix..n.nativeRoot..'/manifest.lua')
    if manifest and love.data.encode('string','hex',love.data.hash('sha256',manifest))==n.manifestHash then n.cachePrefix=prefix;break end
   end
   assert(n.cachePrefix~=nil,'active native cache mount unavailable')
  end
  native=Native.new{read=readNative,nativeRoot=n.nativeRoot,maps=n.maps,behaviors=n.behaviors,
   NativePack=engineRequire('src.import.gba.native_pack'),Palette=engineRequire('src.core.game3.palette'),
   LayoutNative=engineRequire('src.core.game3.layout_native'),Connections=engineRequire('src.core.game3.connections'),
   CollPermissions=engineRequire('src.core.CollPermissions'),ScriptCollision=engineRequire('src.core.game3.scripting.collision_frlg'),
   WorldSource=V.require('data/WorldSource'),checkpoint=checkpoint}
  atlasSnapshots={}
 end
 local writtenBytes=0
 local owned={}
 local function recycle()
  while true do
   local ack=acks:pop();if not ack then break end
   local size=type(ack)=='table'and owned[ack.path]
   if size and love.filesystem.remove(outputPrefix..ack.path)then
    writtenBytes=writtenBytes-size;owned[ack.path]=nil
   end
  end
 end
 local capBytes=math.min(128*1024*1024,tonumber(config.capBytes)or 128*1024*1024)
 while true do
  checkpoint();recycle()
  local job=incoming:demand(1)
  if job==false then
   -- Stay available to reclaim successful intermediates, including the last
   -- map, until the foreground acknowledges them (or cancels).
   while next(owned)do checkpoint();recycle();if next(owned)then love.timer.sleep(.02)end end
   break
  end
  if job then
   local ok,value=pcall(function()
    assert(type(job)=='table','CPU job')
    if job.mapId then
     assert(native,'native input mode not configured')
     local def=assert(native.maps[job.mapId],'native map')
     local input
     if job.isBorder then
      assert(type(job.coveredRects)=='table'and type(job.border)=='number','exact border coverage required')
      local function covered(x,y)for _,r in ipairs(job.coveredRects)do if x>=r[1]and y>=r[2]and x<r[3]and y<r[4]then return true end end;return false end
      input=assert(native.source:borderInput(job.mapId,def,job.border,covered))
     else input=assert(native.source:mapInput(job.mapId,def))end
     assert(input.kind~='cave','accepted cave foreground path')
     local sign=config.native.signInputs and config.native.signInputs[job.mapId]
     if sign and not job.isBorder then Signs.apply(input,sign)end
     local snapshot=Snapshot.capture(input,checkpoint,atlasSnapshots[input.pair])
     atlasSnapshots[input.pair]=snapshot.atlas
     job.snapshot=encode(snapshot);job.key=Store.keyWithSource(job.snapshot,sourceKey)
    end
    assert(type(job.key)=='string'and job.key:match('^[a-f0-9]+$')and #job.key==64,'job key')
    assert(type(job.snapshot)=='string'and #job.snapshot<=32*1024*1024,'snapshot size')
    assert(job.key==Store.keyWithSource(job.snapshot,sourceKey),'CPU identity mismatch')
    local input=Snapshot.restore(decode(job.snapshot))
    local geom=Mesher.build(input,deps)
    local bytes=encode(Geometry.capture(geom,input.width,input.height,checkpoint))
    assert(#bytes<=48*1024*1024,'geometry budget')
    checkpoint(true)
    -- Separate intermediate, not a FRPC record. Only foreground code may
    -- upload it and commit the ordinary verified world-cache manifest.
    local folder='fr_cpu_prepare/'..token
    assert(love.filesystem.createDirectory(outputPrefix..folder),'intermediate directory')
    local body=love.data.compress('string','lz4',bytes)
    local size=#body+137
    assert(size<=capBytes,'single CPU intermediate exceeds storage budget')
    while writtenBytes+size>capBytes do
     checkpoint();recycle()
     if writtenBytes+size>capBytes then love.timer.sleep(.02)end
    end
    local hash=love.data.encode('string','hex',love.data.hash('sha256',body))
    local path=folder..'/'..job.key..'.cpu'
    assert(love.filesystem.write(outputPrefix..path,'FRCPU1\n'..job.key..'\n'..hash..'\n'..body),'intermediate write')
    writtenBytes=writtenBytes+size;owned[path]=size
    return {key=job.key,mapId=job.mapId,isBorder=job.isBorder,path=path,bytes=#body,phase='cpu-ready'}
   end)
   if ok then results:push(value)else results:push({key=job.key,mapId=job.mapId,isBorder=job.isBorder,phase='foreground-fallback',reason=tostring(value)})end
   collectgarbage('collect')
  end
 end
end
local ok,why=pcall(run)
-- Never remove the genuine importer sentinel or somebody else's heartbeat.
if closeGuard then
 local closed,confirmed=pcall(closeGuard)
 if not(closed and confirmed==true)then ok=false;why='native preparation guard teardown unconfirmed'end
elseif ownership()then love.filesystem.remove(marker)end
-- Failed/cancelled workers own their isolated scratch files; no successful
-- result is deleted while the foreground GPU continuation may still use it.
if not ok or cancel:peek()~=nil then
 local folder=outputPrefix..'fr_cpu_prepare/'..token
 for _,file in ipairs(love.filesystem.getDirectoryItems(folder)or {})do
  if file:match('^[a-f0-9]+%.cpu$')and #file==68 then love.filesystem.remove(folder..'/'..file)end
 end
 love.filesystem.remove(folder)
end
results:push({phase=ok and 'cpu-stopped'or 'cpu-failed',reason=ok and nil or tostring(why)})
