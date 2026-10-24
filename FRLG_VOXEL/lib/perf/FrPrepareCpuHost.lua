-- Main-thread bridge to an independent CPU worker. Never uploads graphics in
-- the worker and never commits a CPU intermediate as a finished world cache.
local V=...
local H={};H.__index=H
local engineModules={'src.core.CollPermissions','src.core.GameVersion','src.core.game3.cache_paths',
 'src.core.game3.connections','src.core.game3.layout_native','src.core.game3.palette','src.core.game3.profile',
 'src.core.game3.scripting.collision','src.core.game3.scripting.collision_frlg','src.core.game3.void_fill',
 'src.import.gba.family','src.import.gba.families.frlg','src.import.gba.lz77','src.import.gba.metatile','src.import.gba.native_pack',
 'src.import.gba.tileset','src.import.gba.versions','src.import.gba.versions_game',
 'src.import.gba.versions_frlg','src.import.gba.versions_text','src.import.gba.map_catalog','src.import.gba.editions.leafgreen_1_0',
 'src.core.game3.constants','src.core.game3.movement_types','src.core.game3.scripting.gfx_ids',
 'src.core.game3.scripting.opcodes','src.core.game3.scripting.opcodes_common','src.import.gba.extract_map_events','src.import.gba.map_tree'}
local extraModules={'grass/NativeGround','data/WorldSource','data/SignProfiles','data/SignMetadata','data/SignLabels',
 'render/SignPixelFont','perf/FrPrecacheFormat','perf/Speed58','perf/FrPrepareCpuSnapshot',
 'perf/FrPrepareCpuGeometry','perf/FrPrepareCpuSigns','perf/FrPrepareCpuStore','perf/FrPrepareCpuNative','perf/FrPrepareCpuWorker','perf/WorldPrepareWorkerGuard','perf/WorldPrepareNative'}
local function compile(src,name,...)return assert((loadstring or load)(src,'@'..name))(...)end
function H.new(ctx)
 return setmetatable({ctx=ctx,log=ctx.log or print,atlasMemo=setmetatable({},{__mode='k'}),stats={hits=0,misses=0,rejected=0}},H)
end
function H:_sources()
 local mod=self.ctx.V.mod;local sources={}
 for _,file in ipairs(mod:list('lib/mesh')or {})do
  if file:sub(-4)=='.lua'then local name='mesh/'..file:sub(1,-5);sources[name]=assert(mod:read('lib/'..name..'.lua'))end
 end
 for _,name in ipairs(extraModules)do sources[name]=assert(mod:read('lib/'..name..'.lua'),'CPU module '..name)end
 return sources
end
function H:start(game,todo,prep)
 if self.ctx.android~=true or not love.thread then return nil,'not-android'end
 if self.background then
  -- A previous skipped/off preparation may still be retiring. Never reuse
  -- its cancelled coordinator or start another worker over its ownership.
  self.background:poll()
  if self.background.worker and self.background.worker:isRunning()then
   return nil,'previous-worker-running'
  end
  self:release()
 end
 local source=self.ctx.source
 if not source.paintFree or source.paintFree()~=true then return nil,'canonical-art-unavailable'end
 local GV=require('src.core.GameVersion')
 local gameId=GV.get and GV.get()or nil
 if gameId~='firered'and gameId~='leafgreen'then return nil,'not-FRLG'end
 local Extract=require('src.import.gba.extract_island1')
 local root=assert(Extract.NATIVE_ROOT,'native cache root')
 local Cache=require('src.import.CacheFs')
 local rel=root..'/manifest.lua';local canonical=assert(Cache.readActive(rel),'native manifest')
 local cachePrefixes={GV.cachePrefix(),Cache.prefix or ''}
 local manifestHash=love.data.encode('string','hex',love.data.hash('sha256',canonical))
 local sources=self:_sources();self.sources=sources
 local Snapshot=V.require('perf/FrPrepareCpuSnapshot');self.Snapshot=Snapshot
 local Geometry=compile(sources['perf/FrPrepareCpuGeometry'],'CPU geometry',Snapshot)
 self.Store=compile(sources['perf/FrPrepareCpuStore'],'CPU store',V.require('perf/FrPrecacheFormat'),Geometry)
 local maps={};local original=game.data.maps
 for id,def in pairs(original)do
  local copy={};for _,k in ipairs{'id','name','width','height','kind','environment','pair','warps','connections','mapType','objects','bgEvents'}do copy[k]=Snapshot.plain(def[k])end
  maps[id]=copy
 end
 local signInputs={};local signOn=source.signGate and source.signGate()==true
 if signOn then
  local Metadata=V.require('data/SignMetadata');local Connections=source.Connections
  for id,def in pairs(original)do
   signInputs[id]={signCompat=true,signLabels=Metadata.collect(id,def,game,Connections,nil),predictReady=true}
  end
 end
 local jobs={}
 for _,job in ipairs(todo)do
  local def=original[job.id]
  if self.ctx.WorldSource.mapKind(def)~='cave'then
   if not prep:_isDone('m:'..job.id)or(job.outdoor and not prep:_isDone('f:'..job.id))then jobs[#jobs+1]={mapId=job.id,isBorder=false}end
   if not prep:_isDone('r:'..job.id)then
    local entries=assert(source:worldEntries(game,job.id,self.ctx.Scene.REACH))
    local rects={}
    for _,entry in ipairs(entries)do if entry.id~=job.id then
     local L=entry.def and entry.def.midLayout
     if L then rects[#rects+1]={entry.ox,entry.oy,entry.ox+L.width,entry.oy+L.height}end
    end end
    jobs[#jobs+1]={mapId=job.id,isBorder=true,border=self.ctx.Scene.BORDER,coveredRects=rects}
   end
  end
 end
 if #jobs==0 then return nil,'no-CPU-jobs'end
 local Background=V.require('perf/FrPrepareBackground')
 local b=Background.new{thread=love.thread,clock=love.timer.getTime}
 local behaviors=source.Interaction and source.Interaction.behaviors
 self.treeMode=self.ctx.voxelTrees and self.ctx.voxelTrees()==true or false
 local config={sources=sources,outputPrefix='mod_cache/FRLG_VOXEL/',engineModuleNames=engineModules,retroGrass=self.ctx.retroGrass==true,voxelTrees=self.treeMode,capBytes=128*1024*1024,
  native={game=gameId,maps=maps,behaviors=Snapshot.plain(behaviors or {}),nativeRoot=root,cachePrefixes=cachePrefixes,manifestHash=manifestHash,signInputs=signInputs}}
 local ok,why=b:start(config,jobs,sources['perf/FrPrepareCpuWorker'])
 if not ok then return nil,why end
 self.background=b;self.log('background CPU preparation queued '..#jobs..' jobs')
 return b
end
function H:consume(input)
 if input.kind=='cave'or not self.background then return nil end
 -- A toggle must never consume or wait on geometry from the other tree mode.
 local mode=self.ctx.voxelTrees and self.ctx.voxelTrees()==true or false
 if mode~=self.treeMode then self.stats.rejected=self.stats.rejected+1;return nil end
 local b=self.background
 local status=b:status(input)
 if status=='pending'then
  -- Never spin or yield from a synchronous/main-thread scene build. Bulk
  -- preparation always supplies this seam; unexpected sync callers defer.
  if not(self.ctx.Scene._hasDeadline and self.ctx.Scene._hasDeadline()and coroutine.running())then
   error('CPU preparation pending outside sliced scene build',0)
  end
  local clock=love.timer.getTime
  local untilTime=clock()+180
  while status=='pending' do
   if clock()>=untilTime then
    b:cancel()
    local stopBy=clock()+10
    while b.worker:isRunning()do
     if clock()>=stopBy then error('CPU worker did not stop after timeout',0)end
     coroutine.yield();b:poll()
    end
    status='fallback';break
   end
   coroutine.yield()
   status=b:status(input)
  end
 end
 local item=b:record(input)
 if not item then self.stats.misses=self.stats.misses+1;return nil end
 local ok,geom=pcall(function()
  local snapshot=self.Snapshot.capture(input,self.ctx.Scene._yieldPointSafe,self.atlasMemo[input.atlas])
  self.atlasMemo[input.atlas]=snapshot.atlas
  local bytes=self.Store.encode(snapshot,self.ctx.Scene._yieldPointSafe)
  local key=self.Store.keyWithSource(bytes,assert(self.background.sourceKey,'CPU source identity unavailable'))
  assert(key==item.key,'CPU input changed; use original foreground mesher')
  local raw=assert(V.mod.cache:read(item.path),'CPU intermediate missing')
  return self.Store.read(raw,key,self.ctx.Scene._yieldPointSafe)
 end)
 if ok then self.stats.hits=self.stats.hits+1;return geom,'FrlgMesher'end
 self.stats.rejected=self.stats.rejected+1
 if self.stats.rejected<=4 then self.log('CPU intermediate rejected: '..tostring(geom))end
 return nil
end
function H:release()
 if self.background then
  self.background:cancel();self.background:poll()
  -- A live worker exclusively owns scratch cleanup after cancellation.
  -- Never delete its files/directory while it might still publish a result.
  if self.background.worker and self.background.worker:isRunning()then return end
  for _,parts in pairs(self.background.records)do for _,item in pairs(parts)do
   local prefix='fr_cpu_prepare/'..self.background.token..'/'
   if type(item.path)=='string'and item.path:sub(1,#prefix)==prefix then V.mod.cache:delete(item.path)end
  end end
  V.mod.cache:delete('fr_cpu_prepare/'..self.background.token)
  self.background=nil
  self.atlasMemo=setmetatable({},{__mode='k'})
 end
end
return H
