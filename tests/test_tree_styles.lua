local O='FRLG_VOXEL/'
local checks=0
local function check(v,why) checks=checks+1;assert(v,why)end
local function read(p)local f=assert(io.open(p,'rb'));local s=f:read('*a');f:close();return(s:gsub('\r\n','\n'))end
local uniforms,draws={},{}
local created,released=0,0
local g={getSupported=function()return{instancing=true}end}
function g.newMesh(format,vertices)
 created=created+1
 local m={}
 function m:setVertexMap(v)self.indices=v end
 function m:getTexture()return self.texture end
 function m:setTexture(t)self.texture=t end
 function m:attachAttribute(_,instances)self.instances=instances end
 function m:detachAttribute()end
 function m:setVertices(rows,first,count)self.count=count;self.rows=rows end
 function m:release()released=released+1 end
 return m
end
function g.drawInstanced(mesh,count)draws[#draws+1]={count=count,coverage=uniforms.u_treeLod[1],mesh=mesh}end
love={graphics=g,data={pack=function(_,_,...)local a={...};for i,v in ipairs(a)do a[i]=string.format('%.17g',v)end;return table.concat(a,':')end}}
local S={send=function(_,name,value)if type(value)=='table'then local copy={};for k,v in pairs(value)do copy[k]=v end;uniforms[name]=copy else uniforms[name]=value end end}
for _,n in ipairs{'dark','ao','emissive','shadow','texSize'}do S[n]=function()end end
local tree={enabled=true}
local function loadRenderer(path)
 return assert(loadfile(path))({require=function(n)
  if n=='render/Shaders'then return S elseif n=='grass/GrassDeform'then return{disable=function()end}
  elseif n=='mesh/FrlgVoxelTree'then return tree end;error(n)
 end})
end
local M=loadRenderer(O..'lib/render/FrlgVoxelTrees.lua')
check(not M.lowQuality(),'default preserves detailed mode')
check(not M.setLowQuality(false),'unchanged quality is idempotent')
local generation=M.generation()
local function stamp(tris)
 local a={};for i=1,tris*3 do a[i]={i%3,0,0,0,0,0,1,0,0,0,0,0,1}end
 return{under=a,over={},tris=tris,radius=1,height=3}
end
local output={pair='test',stamps={near=stamp(10),far=stamp(2)},trees={}}
for _,x in ipairs{0,17,23,60}do output.trees[#output.trees+1]={x=x,y=0,z=0,near='near',far='far'}end
local renderer=M.new();local rec={ox=0,oz=0,mvp={},liveTex={}}
renderer:build(rec,output)
local countCreated=created
local scene={visible={rec}}
local env={camX=0,camZ=0,far=30}
local shader={hasUniform=function()return true end}
local function render(module,low,legacy)
 module.setLowQuality(low)
 draws={};local counters={tris=0,calls=0}
 renderer:draw(scene,env,nil,function(_,x0) return x0<40 end,legacy and{hasUniform=function()return false end}or shader,counters)
 return counters,draws
end
local high,a=render(M,false)
check(high.tris==24,'detailed near10 + transition12 + distant2; outside tree culled')
check(#a==2,'detailed draws one near and one far group')
check(a[1].coverage==1 and a[2].coverage==-1,'original complementary transition masks')
local low,b=render(M,true)
check(low.tris==6 and #b==1 and b[1].count==3,'low uses only far for all three visible trees')
check(b[1].coverage==0,'nearby coarse trees must be fully covered, never distance-discarded')
check(created==countCreated,'quality change creates no meshes or record rebuild')
check(M.generation()==generation,'quality change does not invalidate world generation')
local highAgain=render(M,false)
check(highAgain.tris==high.tris and highAgain.calls==high.calls,'detail restores immediately')
local legacy=render(M,true,true)
check(legacy.tris==low.tris,'older shader still gets coarse only')
local legacyHigh=render(M,false,true)
check(legacyHigh.tris==22,'original fallback near18-cell selection retained')
env.camX=23;local moved=render(M,true)
check(moved.tris==6,'low works from changed viewer position with unchanged culling')
env.far=1;env.camX=0;local close=render(M,true)
check(close.tris==2,'draw range still culls distant tree bounds')
local mirrored=render(M,true);check(mirrored.tris==close.tris,'second eye shares selected quality')
renderer:release();check(released==created,'all template and instance resources released')
local options=assert(loadfile(O..'lib/quest/VrControls.lua'))()
local spec
for _,s in ipairs(options.LOOK_SPECS)do check(s.key~='fr_tree_low','retired row is absent');if s.key=='fr_trees'then spec=s end end
check(spec and spec.kind=='choice'and spec.default=='sheet'and spec.label=='TREES','one native TREES choice')
check(options.current({get=function()end},spec)=='sheet','default preserves original Cards')
local value='sheet'
for i,label in ipairs{'VOXEL','VOXEL LOW RES','CARDS'}do
 value=options.stepped(spec,value,1,{})
 check(options.display(spec,value)==label,'native choices cycle in requested order '..i)
end
local written
local original=require
require=function(n)
 if n=='src.mods.ManagerState'then return{new=function(game)return{setOption=function(_,id,key,value)
  written={id,key,value};if game.refuse then return false end
  if game.mods.modOptions then game.mods.modOptions[id][key]=value end
  return true
 end}end}end
 return original(n)
end
check(options.write({id='FRLG_VOXEL'},{mods={}},spec.key,'voxel_low'),'native writer accepts low mode')
check(written[1]=='FRLG_VOXEL'and written[2]=='fr_trees'and written[3]=='voxel_low','same persistent options writer')
for _,case in ipairs{{'voxel',true,'voxel_low'},{'voxel',false,'voxel'},{'sheet',true,'sheet'},{'voxel_low',true,'voxel_low'}}do
 local stored={fr_trees=case[1],fr_tree_low=case[2]};local game={mods={modOptions={FRLG_VOXEL=stored}}}
 check(options.migrateTrees({id='FRLG_VOXEL'},game),'legacy pair migrated')
 check(stored.fr_trees==case[3]and stored.fr_tree_low==nil,'migration preserves requested effective mode')
 check(not options.migrateTrees({id='FRLG_VOXEL'},game),'migration is one-time')
end
local stored={fr_trees='voxel',fr_tree_low=true}
check(not options.migrateTrees({id='FRLG_VOXEL'},{mods={modOptions={FRLG_VOXEL=stored}},refuse=true})and stored.fr_tree_low==true and stored.fr_trees=='voxel','failed writer retains previous pair')
require=original
local main=read(O..'main.lua')
local branch=assert(main:match('elseif p.key == "fr_trees" then\n(.-)    elseif p.key == "voxel_view"'))
local changed,active
local chunk=assert(loadstring('return function(V,p,R) '..branch..' end'))()
for _,case in ipairs{{'sheet',false,false},{'voxel',false,true},{'voxel_low',true,true}}do
 chunk({require=function(n)check(n=='render/FrlgVoxelTrees');return{setLowQuality=function(on)changed=on end}end},{value=case[1]},{scene={setVoxelTrees=function(_,on)active=on end}})
 check(changed==case[2]and active==case[3],'live mode routes geometry and quality '..case[1])
end
chunk({require=function()return{setLowQuality=function(on)changed=on end}end},{value='voxel_low'},nil)
check(changed==true,'selection works before renderer exists')
M.setActive(true);local oldGen=M.generation();M.setLowQuality(false);check(not M.setActive(true),'Voxel remains active')
M.setLowQuality(true);check(not M.setActive(true)and M.generation()==oldGen,'switching Voxel modes never changes map generation')
local schema=assert(main:match('(frlgOptionRows%[#frlgOptionRows%+1%]={key="fr_trees".-})\nfrlgOptionRows'))
local row=assert(loadstring('local frlgOptionRows={};'..schema..';return frlgOptionRows[1]'))()
check(row.key==spec.key and row.default==spec.default and row.type==spec.kind,'Mods schema and native row agree')
for i,c in ipairs(row.choices)do check(c[1]==spec.choices[i][1]and c[2]==spec.choices[i][2],'Mods/native choice parity '..i)end
print('PASS '..checks..' tree-quality assertions; actual production draw selection and native option writer. No headset FPS claim.')
