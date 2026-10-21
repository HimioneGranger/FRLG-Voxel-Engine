local V=...
local Panes=V.require('render/FrPaneCollector')
local Metadata=V.require('render/FrPaneMetadata')
local Lamps=V.require('render/NativeStreetLamps')
local Config=V.require('lighting/NativeLightingConfig')
local MB=V.require('mesh/MB')
local M={}
function M.collect(Scene,scene,geom,input,key,checkpoint)
 Metadata.apply(geom,input)
 local payload={schema=1,records={}};local byOwner={}
 local buildings=geom.stats and geom.stats.buildingInfo or{}
 for _,b in ipairs(buildings)do
  local destinations,seen={},{}
  for _,d in ipairs(b.doors or{})do for _,w in ipairs(input.warps or{})do
   if w.x==d.x and (w.y or w.z)==d.z and type(w.destMap)=='string'and not seen[w.destMap]then
    seen[w.destMap]=true;destinations[#destinations+1]=w.destMap
   end
  end end
  table.sort(destinations)
  local id=tostring(input.mapId or key)
  local descriptor=b.lightingDescriptor or{id=id..'/'..b.minX..','..b.minY,mapId=id,x=b.minX,z=b.minY,modelId=b.roofMid,destinations=destinations}
  local r={building=descriptor,triangles={},pools={}}
  payload.records[#payload.records+1]=r;byOwner[b]=r
  for _,p in ipairs(b.nativeLightPanes or{})do Panes.append(r,p.vertices,p.rects)end
  for _,d in ipairs(b.doors or{})do r.pools[#r.pools+1]={x=d.x+.5,z=d.z+1.1,rx=1.25,rz=.8}end
 end
 local under,over=scene:_atlasData(input.pair)
 local atlases={under=under,over=over}
 local wins=Scene._windowList(buildings)
 for _,spec in ipairs{{'opaque','under'},{'cutoutUnder','under'},{'cutoutOver','over'}}do
  local vs=geom[spec[1]]or{};local hits={}
  Scene._windowFlagsFor(vs,nil,hits,wins,128)
  for _,h in ipairs(hits)do
   local owner=h.win.owner;local r=byOwner[owner]
   if r and not owner.lightingPaneOverride then
    local glass=Scene._glassTexels({{key=spec[2],verts=vs,hits={h}}},atlases)
    local w,hh=glass[spec[2]..'W'],glass[spec[2]..'H']
    if w and hh then Panes.append(r,{vs[h.tri],vs[h.tri+1],vs[h.tri+2]},Panes.texelRects(glass[spec[2]],w,hh))end
   end
   if checkpoint then checkpoint()end
  end
 end
 return payload
end
function M.build(Scene,scene,geom,input,key,checkpoint,onResource)
 local payload=M.collect(Scene,scene,geom,input,key,checkpoint)
 local function water(x,z)
  local c=input.cellAt(x,z);local b=c and c.behavior
  return not c or b and MB.WATER_DEEP[b] or c.collision==MB.COLL_WATER or b and MB.WATER_SHALLOW[b]and c.elevation==1
 end
 local function admit(x,z)
  if x<0 or z<0 or x>=input.width or z>=input.height then return false end
  local c=input.cellAt(x,z)
  return c and c.collision==0 and not water(x,z) and type(geom.heightAt)=='function' and type(geom.heightAt(x,z))=='number'
 end
 local function project(x,z)return x,assert(geom.heightAt(x,z),'missing terrain height'),z end
 if Config.streetLampsEnabled~=true then
  return scene.lighting:build(payload,project,admit,checkpoint,onResource)
 end
 local reserved={};local preferred={}
 for _,events in ipairs{input.warps or{},input.objects or{},input.objectEvents or{},input.bgEvents or{}}do
  for _,e in ipairs(events)do local x,z=e.x,e.y or e.z;if x and z then
   for dz=-1,1 do for dx=-1,1 do reserved[(z+dz)*input.width+x+dx]=true end end
  end end
 end
 for _,b in ipairs(geom.stats and geom.stats.buildingInfo or{})do for _,d in ipairs(b.doors or{})do preferred[#preferred+1]={x=d.x,z=d.z,entrance=true}end end
 table.sort(preferred,function(a,b)return a.z==b.z and a.x<b.x or a.z<b.z end)
 local mapId=tostring(input.mapId or key)
 local lamps=Lamps.collect({w=input.width,h=input.height}, {project=project}, {mapId=mapId,mapType=input.mapType,admit=admit,water=water,
  blocked=function(x,z)return not admit(x,z)or reserved[z*input.width+x]==true end,preferredSites=preferred,sites=Config.lampSites[mapId]})
 for _,r in ipairs(lamps.records)do payload.records[#payload.records+1]=r end
 return scene.lighting:build(payload,project,admit,checkpoint,onResource)
end
return M
