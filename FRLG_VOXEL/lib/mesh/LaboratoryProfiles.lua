local native={["mapId"]="FR_CINNABAR_ISLAND",["pair"]="general__rom_082d4b6c",["x0"]=5,["y0"]=6,["width"]=24,["height"]=20,["atlasW"]=256,["atlasH"]=224,["cells"]={{{672,0,3,0,0,1,-1,"TOWN_PATH"},{701,0,3,0,0,1,-1,"TOWN_PATH"},{702,0,3,0,0,1,-1,"TOWN_PATH"},{683,0,3,0,0,1,-1,"TOWN_PATH"},{673,0,3,0,0,1,-1,"TOWN_PATH"},{674,0,3,0,0,1,-1,"TOWN_PATH"},{684,0,3,0,0,1,-1,"TOWN_PATH"}},{{680,7,0,0,0,0,-1,"BUILDING"},{681,7,0,0,0,0,-1,"BUILDING"},{682,7,0,0,0,0,-1,"BUILDING"},{691,7,0,0,0,0,-1,"BUILDING"},{681,7,0,0,0,0,-1,"BUILDING"},{682,7,0,0,0,0,-1,"BUILDING"},{692,7,0,0,0,0,-1,"BUILDING"}},{{688,7,0,0,0,0,-1,"BUILDING"},{689,7,0,0,0,0,-1,"BUILDING"},{690,7,0,0,0,0,-1,"BUILDING"},{699,7,0,0,0,0,-1,"BUILDING"},{689,7,0,0,0,0,-1,"BUILDING"},{690,7,0,0,0,0,-1,"BUILDING"},{700,7,0,0,0,0,-1,"BUILDING"}},{{696,7,0,0,1,0,-1,"BUILDING"},{697,7,0,0,1,0,-1,"BUILDING"},{698,7,0,0,1,0,-1,"BUILDING"},{685,113,0,105,1,1,-1,"DOOR"},{686,130,0,132,1,0,-1,"SIGN"},{687,130,0,132,1,0,-1,"SIGN"},{693,7,0,0,1,0,-1,"BUILDING"}}},["art"]={[672]={203406242,1666734224},[701]={1271337250,1669348022},[702]={1832243108,162260368},[683]={174315250,221167290},[673]={1832243108,1669348022},[674]={1832243108,162260368},[684]={1832243108,1742652993},[680]={203406242,784466430},[681]={203406242,1451084806},[682]={203406242,1770119173},[691]={174315250,1079494682},[692]={1832243108,674417225},[688]={203406242,2119311895},[689]={203406242,80982866},[690]={203406242,53989171},[699]={174315250,1847863254},[700]={1832243108,266443871},[696]={800814820,0},[697]={1018383239,0},[698]={441495477,0},[685]={1952799776,0},[686]={1513498939,0},[687]={1561716469,0},[693]={1521345382,0}},["hasOver"]={[672]=true,[701]=true,[702]=true,[683]=true,[673]=true,[674]=true,[684]=true,[680]=true,[681]=true,[682]=true,[691]=true,[692]=true,[688]=true,[689]=true,[690]=true,[699]=true,[700]=true,[696]=false,[697]=false,[698]=false,[685]=false,[686]=false,[687]=false,[693]=false},["coverage"]={[672]=0.59765625,[701]=0.9375,[702]=0.9375,[683]=1,[673]=0.9375,[674]=0.9375,[684]=0.59765625,[680]=0.99609375,[681]=1,[682]=1,[691]=1,[692]=0.99609375,[688]=1,[689]=1,[690]=1,[699]=1,[700]=1,[696]=0,[697]=0,[698]=0,[685]=0,[686]=0,[687]=0,[693]=0}}
local P={}
local function hash(t)
 if not t then return 0 end
 if type(t)~='table' then return nil end
 local h=0
 for i=1,256 do local v=t[i]
  if type(v)~='number' or v~=v or v==math.huge or v==-math.huge then return nil end
  h=(h*31+(v>=0 and v+2 or 1))%2147483647
 end
 return h
end
local function rect(fn,mid)
 local a,b,c,d=fn(mid)
 for _,v in ipairs({a,b,c,d})do if type(v)~='number' or v~=v or v<0 or v>1 then return false end end
 return type(a)=='number' and type(b)=='number' and type(c)=='number' and type(d)=='number' and a<c and b<d
end
local function guard(input,atlas)
 if input.mapId~=native.mapId or input.pair~=native.pair or input.isBorder
  or input.width~=native.width or input.height~=native.height or atlas.w~=native.atlasW or atlas.h~=native.atlasH or type(atlas.w)~='number' or atlas.w<=0 or atlas.w~=atlas.w or atlas.w==math.huge or type(atlas.h)~='number' or atlas.h<=0 or atlas.h~=atlas.h or atlas.h==math.huge or type(atlas.texels)~='function'
  or type(atlas.overCoverage)~='function' or type(atlas.hasOver)~='function' or type(atlas.underRect)~='function'
  or type(atlas.overRect)~='function' then return false end
 for yi,row in ipairs(native.cells)do for xi,s in ipairs(row)do
  local c=input.cellAt(native.x0+xi-1,native.y0+yi-1)
  if not c or c.mid~=s[1]or c.collision~=s[2]or c.elevation~=s[3]
   or c.behavior~=(s[4]~=-1 and s[4]or nil)or c.layerType~=s[5]
   or c.walkable~=(s[6]==1)or c.category~=s[8]then return false end
 end end
 for mid,h in pairs(native.art)do
  if atlas.hasOver(mid)~=native.hasOver[mid] or atlas.overCoverage(mid)~=native.coverage[mid] or not rect(atlas.underRect,mid)
   or (native.hasOver[mid] and not rect(atlas.overRect,mid))then return false end
  if hash(atlas.texels(mid,'under'))~=h[1]or hash(atlas.texels(mid,'over'))~=h[2]then return false end
 end
 return true
end
function P.match(input,comp,atlas)
 if comp.minX==5 and comp.maxX==11 and comp.minY==7 and comp.maxY==9 and guard(input,atlas)then
  return {name='cinnabar-laboratory-native',wallRows=1,partialFacadePixels=8,nativeRowHeight=true,
   flatRoof=true,roofOverBacking=true,topArtVerified=true,nativeLabRoof=true,
   roofSourceYMin=6,nativeSideSample={mid=681,x=1,y=8,layer="over"}}
 end
end
return P
