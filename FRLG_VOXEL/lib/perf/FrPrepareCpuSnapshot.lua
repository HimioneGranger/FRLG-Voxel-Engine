-- CPU preparation transport, not a renderer/cache-key replacement.
-- Unknown callable/resource state fails closed to the foreground build.
local M={VERSION=1,HALO=4,MAX_CELLS=65536}
local unpack_=unpack or table.unpack
local function plain(v,seen)
 local t=type(v)
 if t=='nil'or t=='string'or t=='boolean'then return v end
 if t=='number'then assert(v==v and math.abs(v)~=math.huge,'nonfinite number');return v end
 assert(t=='table','unsupported '..t)
 assert(not getmetatable(v),'metatable');seen=seen or {};assert(not seen[v],'cycle');seen[v]=true
 local out={};for k,a in pairs(v)do assert(type(k)=='number'or type(k)=='string','key');out[k]=plain(a,seen)end
 seen[v]=nil;return out
end
M.plain=plain
local methods={'underRect','overRect','hasOver','overCoverage','isVoid','isRock','isLeafy','leafFrac','waterFrac','colors','posts','signOverTexels','signTexels'}
local callbacks={outsideMidAt=true,boundaryBorderAt=true,nativeTerrainBorderAt=true,edgeWaterBank=true}
local function packed(...)return {n=select('#',...),...}end
function M.capture(input,tick,sharedAtlas)
 tick=tick or function()end
 assert(input.kind~='cave','accepted caves require foreground resource ownership')
 local w,h=input.width,input.height
 assert(type(w)=='number'and type(h)=='number'and w%1==0 and h%1==0 and w>0 and h>0 and w*h<=M.MAX_CELLS,'dimensions')
 local out={fields={},grid={},atlas=sharedAtlas or {fields={},methods={},texels={}},callbacks={},w=w,h=h,version=M.VERSION,connected={}}
 for k,v in pairs(input)do
  if k=='connectedHouseSource'or k=='connectedBuildingSource'then
   if v then local c={};for name,value in pairs(v)do
    if name=='atlas'then assert(value==input.atlas,'connected atlas identity')else c[name]=plain(value)end
   end;out.connected[k]=c end
  elseif k~='atlas'and k~='cellAt'and k~='grid'and k~='_pcSignDigest'and k~='sig'and not callbacks[k]then out.fields[k]=plain(v)end
 end
 for y=0,h-1 do for x=0,w-1 do out.grid[y*w+x+1]=plain(input.cellAt(x,y))end;tick()end
 if not sharedAtlas then
 local known={texels=true,image=true,overImage=true}
 for _,name in ipairs(methods)do known[name]=true
  if input.atlas[name]then
   assert(type(input.atlas[name])=='function','atlas method')
   local list={};out.atlas.methods[name]=list
   for mid=-1,1023 do list[mid]=plain(packed(input.atlas[name](mid)));if mid%32==0 then tick()end end
  end
 end
 for k,v in pairs(input.atlas)do if not known[k]then out.atlas.fields[k]=plain(v)end end
 if input.atlas.texels then
  for _,layer in ipairs{'under','over'}do local list={};out.atlas.texels[layer]=list
   for mid=-1,1023 do list[mid]=plain(input.atlas.texels(mid,layer));if mid%16==0 then tick()end end
  end
 end
 end -- shared canonical pair-atlas snapshot captured once
 for name in pairs(callbacks)do if input[name]then
  assert(type(input[name])=='function','neighbor callback')
  local rows={};out.callbacks[name]=rows
  for y=-M.HALO,h+M.HALO-1 do local row={};rows[y]=row
   for x=-M.HALO,w+M.HALO-1 do row[x]=plain(packed(input[name](x,y)))end;tick()
  end
 end end
 return out
end
function M.restore(s)
 assert(s.version==M.VERSION,'snapshot version')
 local input=plain(s.fields);input.grid=plain(s.grid)
 input.cellAt=function(x,y)
  assert(x%1==0 and y%1==0,'fractional cell lookup')
  if x<0 or y<0 or x>=s.w or y>=s.h then return nil end
  return input.grid[y*s.w+x+1]
 end
 local atlas=plain(s.atlas.fields);input.atlas=atlas
 for name,list in pairs(s.atlas.methods)do local values=list
  atlas[name]=function(mid)assert(type(mid)=='number'and mid%1==0 and mid>=-1 and mid<=1023,'atlas domain '..name..' '..tostring(mid));local p=assert(values[mid],'missing atlas response');return unpack_(p,1,p.n)end
 end
 if s.atlas.texels.under then atlas.texels=function(mid,layer)
  assert(mid%1==0 and mid>=-1 and mid<=1023,'texel domain')
  return s.atlas.texels[layer=='over'and'over'or'under'][mid]
 end end
 for name,value in pairs(s.connected or {})do input[name]=plain(value);input[name].atlas=atlas end
 for name,rows in pairs(s.callbacks)do local response=rows
  input[name]=function(x,y)
   assert(x%1==0 and y%1==0 and response[y]and response[y][x],'neighbor lookup outside captured domain')
   local p=response[y][x];return unpack_(p,1,p.n)
  end
 end
 return input
end
return M

