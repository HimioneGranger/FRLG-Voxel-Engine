-- Run through run_tests.py with --repo pointing to the repository.
local OVER=assert(os.getenv('FRLG_ENGINE_ROOT'),'set FRLG_ENGINE_ROOT to FRLG_VOXEL')..'/lib/'
local BASE=OVER
local function read(p)local f=assert(io.open(p,'rb'));local s=f:read('*a');f:close();return s end
local function module(path,...)return assert(loadstring(read(path),'@'..path))(... )end
local function equal(a,b)
 if type(a)~=type(b)then return false end
 if type(a)~='table'then return a==b end
 for k,v in pairs(a)do if not equal(v,b[k])then return false end end
 for k in pairs(b)do if a[k]==nil then return false end end;return true
end
local function copy(t)if type(t)~='table'then return t end;local o={};for k,v in pairs(t)do o[k]=copy(v)end;return o end
local passed=0
local function check(name,fn)fn();passed=passed+1;print('PASS '..name)end
local function rejects(fn)local ok,why=pcall(fn);assert(not ok and tostring(why):find('frpc:',1,true),tostring(why))end
local function run()
 local C=module(OVER..'perf/FrVoxelTreeCache.lua')
 local function row(x)return{x,2.125,-3.5,.123456789012,.9,0,1,0,0,0,0,0,1}end
 local raw={pair='1:0',stamps={near={under={row(0),row(1),row(2)},over={},tris=1,radius=2,height=5},far={under={},over={row(0),row(2),row(4)},tris=1,radius=2,height=5}},trees={{x=4.25,y=1,z=8,near='near',far='far'},{x=9,y=2,z=10,near='near',far='far'}}}
 local blobs,parts={},{}
 local function add(s)blobs[#blobs+1]=s;parts[#parts+1]={raw=#s,stored=#s,md5=love.data.hash('md5',s)};return{part=#blobs,off=0,len=#s}end
 local stored=C.capture(raw,raw.pair,add)
 local function rb(ref)return blobs[ref.part]:sub(ref.off+1,ref.off+ref.len)end
 local restored
 check('exact doubles, vertices, placements and template references roundtrip',function()restored=C.restore(stored,raw.pair,parts,rb);assert(equal(raw,restored))end)
 check('capture leaves source immutable',function()assert(raw.stamps.near.under[1][4]==.123456789012 and #raw.trees==2)end)
 check('only shared templates stored, not per-instance copies',function()assert(#blobs==2 and #stored.trees==2 and stored.trees[1].near==stored.trees[2].near)end)
 check('zero-tree map roundtrip',function()local e={pair=raw.pair,stamps={},trees={}};local s=C.capture(e,e.pair,add);assert(equal(e,C.restore(s,e.pair,parts,rb)))end)
 local mutations={
  {'pair mismatch',function(x)x.pair='other'end},
  {'missing template',function(x)x.trees[1].near='missing'end},
  {'unknown placement field',function(x)x.trees[1].gpu=true end},
  {'nonfinite position',function(x)x.trees[1].x=0/0 end},
  {'sparse placements',function(x)x.trees[4]=x.trees[1]end},
  {'nonfinite vertex',function(x)x.stamps.near.under[1][3]=math.huge end},
  {'wrong vertex width',function(x)x.stamps.near.under[1][14]=1 end},
  {'wrong triangles',function(x)x.stamps.near.tris=2 end},
  {'negative radius',function(x)x.stamps.near.radius=-1 end},
  {'unreferenced template',function(x)x.stamps.extra=copy(x.stamps.near)end},
  {'metatable input',function(x)setmetatable(x,{})end},
 }
 for _,m in ipairs(mutations)do check('reject raw '..m[1],function()local x=copy(raw);m[2](x);rejects(function()C.validate(x,raw.pair)end)end)end
 local encodedMutations={
  {'schema version',function(x)x.version=2 end},
  {'reference out of range',function(x)x.stamps.near.under.refs[1].off=1 end},
  {'reference wrong stride',function(x)x.stamps.near.under.refs[1].len=1 end},
  {'reference bad part',function(x)x.stamps.near.under.refs[1].part=999 end},
  {'infinite stored count',function(x)x.stamps.near.under.count=math.huge end},
  {'wrong stored triangles',function(x)x.stamps.near.tris=2 end},
  {'missing far reference',function(x)x.trees[1].far='missing'end},
 }
 for _,m in ipairs(encodedMutations)do check('reject stored '..m[1],function()local x=copy(stored);m[2](x);rejects(function()C.validateStored(x,raw.pair,parts)end)end)end
 check('reject truncated blob',function()rejects(function()C.restore(stored,raw.pair,parts,function(ref)return rb(ref):sub(2)end)end)end)
 check('reject NaN embedded in blob',function()rejects(function()C.restore(stored,raw.pair,parts,function(ref)local s=rb(ref);return love.data.pack('string','<d',0/0)..s:sub(9)end)end)end)
 local F=module(OVER..'perf/FrPrecacheFormat.lua')
 local V={require=function(name)
  if name=='perf/FrPrecacheFormat'then return F end
  if name=='perf/FrVoxelTreeCache'then return C end
  if name=='render/FrShrubView'then return{upload=function()end}end
  if name=='perf/FrPrecacheStore'then return{DIR='fr-precache/v1/'}end
  return{}
 end}
 local PC=module(OVER..'perf/FrPrecache.lua',V)
 local pc=setmetatable({},PC)
 local meta={full='fixture|vt=1',key='fixture',w=2,h=2,originX=0,originY=0,pair=raw.pair,mesher='FrlgMesher',tris=0,maskKind=0,alphaState=0,layers={},voxelTreeMode=true,voxelTrees=stored,parts=parts}
 local function header(m)local s=pc:_encodeHeader(m);return s..love.data.hash('md5',s)end
 check('actual header roundtrip includes voxel payload',function()local m=pc:_decodeHeader(header(meta),meta.full);assert(m.voxelTreeMode and equal(m.voxelTrees,stored))end)
 check('actual header rejects voxel data marked sheets',function()local x=copy(meta);x.voxelTreeMode=false;rejects(function()pc:_decodeHeader(header(x),x.full)end)end)
 check('actual header rejects malformed template metadata',function()local x=copy(meta);x.voxelTrees.stamps.near.tris=2;rejects(function()pc:_decodeHeader(header(x),x.full)end)end)
 check('format6 rejects version5 before loading',function()local s=pc:_encodeHeader(meta);s=s:sub(1,4)..love.data.pack('string','<I4',5)..s:sub(9);rejects(function()pc:_decodeHeader(s..love.data.hash('md5',s),meta.full)end)end)
 check('actual load rejects tree mode mismatch before GPU work',function()rejects(function()pc:_load({},'key',meta.full,{width=2,height=2,pair=raw.pair,atlas={image={}}},nil,{yield=function()end,voxelTreeMode=false},header(meta))end)end)
 -- Run the unmodified renderer's record constructor with counted GPU stubs.
 local allocations,releases=0,0
 love.graphics={newMesh=function(fmt,rows)
  allocations=allocations+1;return{release=function()releases=releases+1 end}
 end}
 local R=module(BASE..'render/FrlgVoxelTrees.lua',{require=function()return{}end})
 local renderer=R.new();local rec={}
 check('actual batch reconstruction preserves placements and LOD references',function()
  assert(renderer:build(rec,restored)==2);assert(#rec.frVoxelTrees==2 and #rec.frVoxelTreeGroups==2)
  local n=0;for _,b in ipairs(rec.frVoxelTrees)do n=n+b.count;assert(b.near.tris==1 and b.far.tris==1)end
  assert(n==#raw.trees and allocations==4)
 end)
 check('rebuild releases old instances without duplicate trees/templates',function()
  renderer:build(rec,restored);assert(releases==2 and allocations==6 and #rec.frVoxelTrees==2)
  renderer:release();assert(releases==6 and next(renderer.records)==nil)
 end)
 local closes,viewReleases=0,0
 pc._partReader=function()return{close=function()closes=closes+1 end,view=function(_,ref)return{getString=function()return rb(ref)end,release=function()viewReleases=viewReleases+1 end}end}end
 local loadedRenderer=R.new()
 local loadHost={yield=function()end,voxelTreeMode=true}
 check('actual record load reconstructs live batched trees exactly once',function()
  local rec=pc:_load({voxelTrees=loadedRenderer},'fixture',meta.full,{width=2,height=2,pair=raw.pair,atlas={image={}}},nil,loadHost,header(meta))
  assert(rec.tris==2 and #rec.frVoxelTrees==2 and #rec.frVoxelTreeGroups==2 and closes==1 and viewReleases==2)
  loadedRenderer:release()
 end)
 check('actual tryLoad discards corrupt payload and closes partial ownership',function()
  pc.cache={read=function()return header(meta)end};pc.clock=function()return 0 end
  pc.stats={miss=0,hit=0,corrupt=0,bytesRead=0};pc._say=function()end;pc._event=function()end
  local forgotten,partial=0,0
  pc.store={remove=function()return nil end,queueDelete=function()forgotten=forgotten+1 end}
  pc._partReader=function()return{close=function()closes=closes+1 end,view=function(_,ref)return{getString=function()local b=rb(ref);return love.data.pack('string','<d',0/0)..b:sub(9)end,release=function()viewReleases=viewReleases+1 end}end}end
  loadHost.releaseRecord=function()partial=partial+1 end
  local rec,why=pc:tryLoad({voxelTrees=R.new()},'fixture',meta.full,{width=2,height=2,pair=raw.pair,atlas={image={}}},nil,loadHost)
  assert(rec==nil and why:find('corrupt',1,true)and pc.stats.corrupt==1 and forgotten==1 and partial==1 and closes==2 and viewReleases==4)
 end)
 check('temporary DataView releases even if copying fails',function()
  pc._partReader=function()return{close=function()closes=closes+1 end,view=function()return{getString=function()error('synthetic DataView copy failure')end,release=function()viewReleases=viewReleases+1 end}end}end
  local rec=pc:tryLoad({voxelTrees=R.new()},'fixture',meta.full,{width=2,height=2,pair=raw.pair,atlas={image={}}},nil,loadHost)
  assert(rec==nil and viewReleases==5 and closes==3 and pc.stats.corrupt==2)
 end)
 check('pending budget counts fresh CPU template arrays',function()
  local function record(count)
   local list={};for i=1,count do list[i]={}end
   return{pcInfo={voxelTrees={trees={},stamps={one={under=list,over={}}}}}}
  end
  pc.pending={};pc.stats.dropped=0
  local a,b=record(20000),record(20000);pc:submit({},a);pc:submit({},b)
  assert(#pc.pending==1 and pc.stats.dropped==1 and a.pcInfo==nil and b.pcInfo.pendBytes==5120000)
  local big=record(30000);pc:submit({},big)
  assert(#pc.pending==1 and pc.pending[1].rec==big and pc.stats.dropped==2)
 end)
 -- Exercise exact Scene method bodies with controlled mode/generation seams.
 local src=read(OVER..'render/Scene.lua')
 local function method(name)local first=assert(src:find('function Scene:'..name..'(',1,true));local last=assert(src:find('\nend\n',first,true));return src:sub(first,last+4)end
 local mode,gen=false,1;local S={};local rejected,submitted=0,0
 local env=setmetatable({Scene=S,VoxelTrees={active=function()return mode end,generation=function()return gen end},PCmod={M={NONE=0}},sunless=function()return true end},{__index=_G})
 for _,name in ipairs{'_pcSettings','_pcFinish'}do local c=assert(loadstring(method(name)));setfenv(c,env);c()end
 local scene=setmetatable({shadows=false,_pcSignDigest=function()return'-'end},{__index=S})
 check('actual settings partition both modes',function()local a=scene:_pcSettings({},nil);mode=true;local b=scene:_pcSettings({},nil);assert(a~=b and a:find(';vt=0',1,true)and b:find(';vt=1',1,true))end)
 local fake={unclean=function()rejected=rejected+1 end,submit=function()submitted=submitted+1 end,paintToken=function()return'clean'end,samplePaint=function()end,pairTainted=function()return false end}
 scene.precache=fake
 local function context()return{treeGeneration=gen,voxelTreeMode=mode,settings=scene:_pcSettings({},nil),paint='clean'}end
 check('generation flip rejects queued capture',function()local c=context();gen=gen+1;scene:_pcFinish(c,{mesher='FrlgMesher'},{},nil);assert(rejected==1 and submitted==0)end)
 check('mode flip rejects capture',function()local c=context();mode=not mode;scene:_pcFinish(c,{mesher='FrlgMesher'},{},nil);assert(rejected==2 and submitted==0)end)
 check('sheet context rejects stray voxel ownership',function()local c=context();scene:_pcFinish(c,{mesher='FrlgMesher',frVoxelTrees={}},{},nil);assert(rejected==3)end)
 check('valid voxel capture submits without broad bypass',function()mode=true;local c=context();scene:_pcFinish(c,{mesher='FrlgMesher',frVoxelTrees={}},{},nil);assert(submitted==1)end)
 print('VOXEL_CACHE_TESTS_PASS '..passed)
end
function love.load()
 local ok,why=xpcall(run,debug.traceback)
 if not ok then print('VOXEL_CACHE_TESTS_FAIL '..tostring(why));love.event.quit(1)else love.event.quit(0)end
end
