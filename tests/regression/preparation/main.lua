-- Run through run_tests.py with --repo pointing to the repository.
local O=assert(os.getenv('FRLG_ENGINE_ROOT'),'set FRLG_ENGINE_ROOT to FRLG_VOXEL')..'/lib/'
local S=O
local checks=0
local function check(v,msg)assert(v,msg);checks=checks+1 end
local function read(p)local f=assert(io.open(p,'rb'));local s=f:read('*a');f:close();return s end
local function path(n)
 local f=io.open(O..n..'.lua','rb');if f then f:close();return O..n..'.lua' end
 return S..n..'.lua'
end
local function module(n,...)return assert(loadstring(read(path(n)),'@'..path(n)))(...)end
local function eq(a,b,seen)
 if type(a)~=type(b)then return false end
 if type(a)~='table'then return a==b end
 seen=seen or {};if seen[a]then return seen[a]==b end;seen[a]=b
 for k,v in pairs(a)do if not eq(v,b[k],seen)then return false end end
 for k in pairs(b)do if a[k]==nil then return false end end
 return true
end
local function test()
 for _,n in ipairs{'PrepareHost','FrPrepare','FrPrepareCpuHost','FrPrepareCpuStore','FrPrepareCpuWorker'}do
  check(loadstring(read(O..'perf/'..n..'.lua'))~=nil,'syntax '..n)
 end
 local F=module('perf/FrPrecacheFormat')
 local K={md5hex=function(s)return love.data.encode('string','hex',love.data.hash('md5',s))end}
 local Store={DIR='fr-precache/v1/'}
 local V={require=function(n)
  if n=='perf/FrPrecacheFormat'then return F end
  if n=='perf/FrPrecacheKey'then return K end
  if n=='perf/FrPrecacheStore'then return Store end
  error('optional unavailable '..n)
 end}
 local P=module('perf/FrPrepare',V)
 local files,index={},{}
 local cache={read=function(_,n)return files[n]end,write=function(_,n,s)files[n]=s;return true end}
 local store={dirty=false,count=2,flush=function()end,has=function(_,k)return index[k]end}
 local pc={game='firered',code='flower3251',engine='love115',cache=cache,store=store,ready=true}
 local function driver(mode)
  local p=P.new{pc=pc,variant=mode};p.token=p:_token();return p
 end
 local sheet,voxel=driver('vt0'),driver('vt1')
 check(sheet.token~=voxel.token,'preparation mode tokens must differ')
 local rk0,rk1=string.rep('1',32),string.rep('2',32)
 index[rk0],index[rk1]={},{}
 sheet:_note('m:A',P.ST.OK,rk0);check(sheet:_saveManifest(),'sheet manifest commit')
 voxel:_note('m:B',P.ST.OK,rk1);check(voxel:_saveManifest(),'voxel manifest commit')
 check(files['fr-precache/v1/prep.vt0.a'] and files['fr-precache/v1/prep.vt1.a'],'mode manifests coexist')
 local s2,v2=driver('vt0'),driver('vt1')
 check(s2:_loadManifest() and v2:_loadManifest(),'independent mode resume')
 check(s2:_isDone('m:A') and not s2:_isDone('m:B'),'sheet resume owns only sheet records')
 check(v2:_isDone('m:B') and not v2:_isDone('m:A'),'voxel resume owns only voxel records')
 index[rk1]=nil;check(not v2:_isDone('m:B'),'missing indexed record is unfinished');index[rk1]={}
 pc.code='newflower';local changed=driver('vt1');check(not changed:_loadManifest(),'producer edit invalidates preparation')
 pc.code='flower3251';pc.engine='changed';check(not driver('vt1'):_loadManifest(),'engine change invalidates preparation');pc.engine='love115'
 check(not pcall(function()driver('../bad'):_manifestPath('a')end),'invalid namespace rejected')
 local discarded,saved=0,0
 v2._cleanup=function()discarded=discarded+1 end;v2._saveManifestSafe=function()saved=saved+1 end
 local before=v2.entries
 v2.phase='run';v2:invalidateMode()
 check(discarded==1 and saved==1 and v2.entries==before and v2.phase=='off','mode cancellation preserves completed entries')
 local trees,gen=true,1
 local Tree={active=function()return trees end,generation=function()return gen end}
 local H=module('perf/PrepareHost')
 local fakePrep={new=function(env)return {env=env}end}
 local ctx={V={require=function(n)
  if n=='perf/FrPrepare'then return fakePrep elseif n=='render/FrlgVoxelTrees'then return Tree end
  error('optional unavailable '..n)
 end},OutdoorPerf={precacheFirstLoad=true,worldCache=true},android=false,
  vritk={active=function()return true end},log=function()end,worldCache=function()return pc end,
  grass=function()return nil end,Mods={Scene={},WorldSource={}}}
 local h=H.new(ctx)
 check(h:allowed(),'voxel preparation allowed')
 trees=false;check(h:allowed(),'sheet preparation allowed');trees=true
 ctx.OutdoorPerf.worldCache=false;check(not h:allowed(),'world cache off respected');ctx.OutdoorPerf.worldCache=true
 ctx.OutdoorPerf.precacheFirstLoad=false;check(not h:allowed(),'preparation option respected');ctx.OutdoorPerf.precacheFirstLoad=true
 local r={source={},scene={},xr={}}
 check(h:frame(r,{phase='boot'},false,false,false,{preintro=true}) and h.shown and not h.prep,'voxel mode announces before work')
 local e=h:ensure(r).env
 check(e.variant=='vt1' and e.gate(),'driver freezes voxel variant')
 gen=gen+1;check(not e.gate(),'frozen plan gate rejects newer mode generation')
 local cancelled,released=0,0
 h.prep={invalidateMode=function()cancelled=cancelled+1 end}
 local cpu={release=function()released=released+1 end};h.cpu=cpu
 h.presented=true
 check(h:frame(r,{phase='boot'},false,false,false,{preintro=true}),'toggle restarts announcement')
 check(cancelled==1 and released==1 and h.cpu==cpu and h.prep==nil,'toggle retires unfinished work without dropping running worker owner')
 local Snapshot=module('perf/FrPrepareCpuSnapshot')
 local Geometry=module('perf/FrPrepareCpuGeometry',Snapshot)
 local CpuStore=module('perf/FrPrepareCpuStore',F,Geometry)
 local a=CpuStore.sourceKey({producer='same'},true,false)
 local b=CpuStore.sourceKey({producer='same'},true,true)
 check(a~=b and a==CpuStore.sourceKey({producer='same'},true,false),'CPU source identity stable and mode-specific')
 check(a~=CpuStore.sourceKey({producer='edited'},true,false),'CPU producer changes invalidate identity')
 check(CpuStore.key('same',{},false,false)~=CpuStore.key('same',{},false,true),'CPU snapshot key partitions modes')
 local CpuHost=module('perf/FrPrepareCpuHost',{})
 local ch=CpuHost.new{voxelTrees=function()return true end}
 ch.treeMode=false;ch.background=setmetatable({},{__index=function()error('stale worker queried')end})
 check(ch:consume({kind='outdoor'})==nil and ch.stats.rejected==1,'stale mode rejected before waiting/querying worker')
 -- Real packaged compiler/profile create the native tree stamp. Only atlas
 -- packing is synthetic; no GPU objects, copied mesh fixtures or hand vertices.
 local loaded={}
 local NativeV={require=function(n)
  if not loaded[n]then loaded[n]=module(n,NativeV)end
  return loaded[n]
 end}
 -- Lua 5.1 local initializer scope requires explicit self reference.
 NativeV.require=function(n)if not loaded[n]then loaded[n]=module(n,NativeV)end;return loaded[n]end
 local profile=NativeV.require('mesh/FrlgGeneralFoliage')
 local tiles={}
 for _,v in ipairs(profile.native.addresses)do
  local key=v.metatile..':'..v.layer;tiles[key]=tiles[key]or{}
  tiles[key][v.localY*16+v.localX+1]=tonumber(v.rgb,16)
 end
 local atlas={texels=function(mid,layer)return tiles[mid..':'..layer]end,
  underRect=function()return 0,0,1,1 end,overRect=function()return 0,0,1,1 end}
 local compiler=NativeV.require('mesh/FrlgCompiledTree')
 local descriptor={pair='test/native',trees={{x=4,y=.2,z=6,near='general@1',far='general@4'}},stamps={}}
 local vertexCount=0
 for _,lod in ipairs{1,4}do
  local stamp=compiler.build(atlas,lod)
  local d={tris=stamp.tris,radius=stamp.pixels/32,height=stamp.height/16,under={},over={}}
  for _,layer in ipairs{'under','over'}do for _,v in ipairs(stamp[layer])do
   d[layer][#d[layer]+1]={v[1]/16,v[2]/16,v[3]/16,v[4],v[5],v[6],v[7],v[8],0,0,0,0,1};vertexCount=vertexCount+1
  end end
  descriptor.stamps['general@'..lod]=d
 end
 local geom={frVoxelTrees=descriptor,heightAt=function()return .25 end,opaque={},cutoutUnder={},cutoutOver={}}
 local captured=Geometry.capture(geom,2,2)
 local raw=CpuStore.encode(captured)
 local body=love.data.compress('string','lz4',raw)
 local key=CpuStore.key('fixture',{producer='same'},true,true)
 local hash=love.data.encode('string','hex',love.data.hash('sha256',body))
 local restored=CpuStore.read('FRCPU1\n'..key..'\n'..hash..'\n'..body,key)
 check(eq(descriptor,restored.frVoxelTrees),'genuine compiled tree descriptors/stamps exact after CPU binary/compression roundtrip')
 check(restored.heightAt(0,0)==.25 and restored.heightAt(1,1)==.25,'CPU terrain heights preserved')
 check(not pcall(CpuStore.read,'FRCPU1\n'..key..'\n'..hash..'\n'..body,a),'wrong CPU source key rejected')
 local bad={frVoxelTrees={resource=function()end},heightAt=function()return 0 end}
 check(not pcall(Geometry.capture,bad,1,1),'GPU/callable descriptors fail closed')
 print(('PREPARATION MODE TESTS PASS checks=%d genuineVertices=%d cpuBytes=%d compressed=%d'):format(checks,vertexCount,#raw,#body))
end
function love.load()
 local ok,err=xpcall(test,debug.traceback)
 if not ok then print(err)end
 love.event.quit(ok and 0 or 1)
end
