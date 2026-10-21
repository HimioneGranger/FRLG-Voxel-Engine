-- Generated native guards; geometry/ownership acceptance pending.
-- Exact landmark source guards; ordinary PC and Mart families are unaffected.
local native={mapId="SEVII_ONE_ISLAND",pair="sevii_outdoor",x0=11,y0=0,cells={{{704,7,0,0,0,0,-1,"BUILDING"},{706,7,0,0,0,0,-1,"BUILDING"},{706,7,0,0,0,0,-1,"BUILDING"},{707,7,0,0,0,0,-1,"BUILDING"},{708,7,0,0,0,0,-1,"BUILDING"},{708,7,0,0,0,0,-1,"BUILDING"},{710,7,0,0,0,0,-1,"BUILDING"}},{{712,7,0,0,0,0,-1,"BUILDING"},{714,7,0,0,0,0,-1,"BUILDING"},{714,7,0,0,0,0,-1,"BUILDING"},{715,7,0,0,0,0,-1,"BUILDING"},{716,7,0,0,0,0,-1,"BUILDING"},{716,7,0,0,0,0,-1,"BUILDING"},{718,7,0,0,0,0,-1,"BUILDING"}},{{720,7,0,0,0,0,-1,"BUILDING"},{714,7,0,0,0,0,-1,"BUILDING"},{722,7,0,0,0,0,-1,"BUILDING"},{723,7,0,0,0,0,-1,"BUILDING"},{724,7,0,0,0,0,-1,"BUILDING"},{716,7,0,0,0,0,-1,"BUILDING"},{726,7,0,0,0,0,-1,"BUILDING"}},{{728,7,0,0,0,0,-1,"BUILDING"},{729,7,0,0,0,0,-1,"BUILDING"},{730,7,0,0,0,0,-1,"BUILDING"},{731,7,0,0,0,0,-1,"BUILDING"},{732,7,0,0,0,0,-1,"BUILDING"},{733,7,0,0,0,0,-1,"BUILDING"},{734,7,0,0,0,0,-1,"BUILDING"}},{{736,7,0,0,0,0,-1,"BUILDING"},{737,7,0,0,0,0,-1,"BUILDING"},{738,7,0,0,1,0,-1,"BUILDING"},{739,7,0,0,1,0,-1,"BUILDING"},{740,7,0,0,1,0,-1,"BUILDING"},{741,7,0,0,0,0,-1,"BUILDING"},{742,7,0,0,0,0,-1,"BUILDING"}},{{744,7,0,0,1,0,-1,"BUILDING"},{745,7,0,0,1,0,-1,"BUILDING"},{746,7,0,0,1,0,-1,"BUILDING"},{747,113,0,105,1,1,-1,"DOOR"},{748,7,0,0,1,0,-1,"BUILDING"},{749,7,0,0,1,0,-1,"BUILDING"},{750,7,0,0,1,0,-1,"BUILDING"}},{{179,7,0,0,1,0,-1,"CLIFF"},{16,0,3,0,1,1,-1,"TOWN_PATH"},{721,0,3,0,1,1,-1,"TOWN_PATH"},{16,0,3,0,1,1,-1,"TOWN_PATH"},{2,130,0,132,1,0,-1,"SIGN"},{16,0,3,0,1,1,-1,"TOWN_PATH"},{178,7,0,0,1,0,-1,"CLIFF"}}},art={
[2]={1603335353,0},
[16]={1847008231,0},
[178]={357145300,0},
[179]={1211832017,0},
[704]={357145300,738729510},
[706]={1369142683,2021304831},
[707]={1369142683,1035906164},
[708]={1369142683,251171296},
[710]={1666285478,5027834},
[712]={1847008231,1567692810},
[714]={1847008231,1425687245},
[715]={1919699102,2084847570},
[716]={1847008231,1034323034},
[718]={1847008231,189814041},
[720]={1832243108,20729899},
[721]={10265679,0},
[722]={1832243108,1701603502},
[723]={556348727,103474783},
[724]={1832243108,832078248},
[726]={1832243108,2074361282},
[728]={1847008231,875623515},
[729]={1919699102,138978783},
[730]={1847008231,2034903720},
[731]={1919699102,1076799499},
[732]={1847008231,1635110442},
[733]={1919699102,1517748107},
[734]={1847008231,2095800514},
[736]={1832243108,91503273},
[737]={556348727,137681613},
[738]={1497433558,0},
[739]={740754897,0},
[740]={467180685,0},
[741]={556348727,940847198},
[742]={1832243108,1879971531},
[744]={15403189,0},
[745]={387126275,0},
[746]={1358945387,0},
[747]={483571575,0},
[748]={503320059,0},
[749]={1050678091,0},
[750]={1542692809,0},
},hasOver={[2]=false,[16]=false,[178]=false,[179]=false,[704]=true,[706]=true,[707]=true,[708]=true,[710]=true,[712]=true,[714]=true,[715]=true,[716]=true,[718]=true,[720]=true,[721]=false,[722]=true,[723]=true,[724]=true,[726]=true,[728]=true,[729]=true,[730]=true,[731]=true,[732]=true,[733]=true,[734]=true,[736]=true,[737]=true,[738]=false,[739]=false,[740]=false,[741]=true,[742]=true,[744]=false,[745]=false,[746]=false,[747]=false,[748]=false,[749]=false,[750]=false}}

local P={}
local function hash(t)
 if not t then return 0 end
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
  or input.width~=24 or input.height~=20 or type(atlas.w)~='number' or atlas.w<=0 or atlas.w~=atlas.w or atlas.w==math.huge or type(atlas.h)~='number' or atlas.h<=0 or atlas.h~=atlas.h or atlas.h==math.huge or type(atlas.texels)~='function'
  or type(atlas.hasOver)~='function' or type(atlas.underRect)~='function'
  or type(atlas.overRect)~='function' then return false end
 for yi,row in ipairs(native.cells)do for xi,s in ipairs(row)do
  local c=input.cellAt(native.x0+xi-1,native.y0+yi-1)
  if not c or c.mid~=s[1]or c.collision~=s[2]or c.elevation~=s[3]
   or c.behavior~=(s[4]~=-1 and s[4]or nil)or c.layerType~=s[5]
   or c.walkable~=(s[6]==1)or c.category~=s[8]then return false end
 end end
 for mid,h in pairs(native.art)do
  if atlas.hasOver(mid)~=native.hasOver[mid] or not rect(atlas.underRect,mid)
   or (native.hasOver[mid] and not rect(atlas.overRect,mid))then return false end
  if hash(atlas.texels(mid,'under'))~=h[1]or hash(atlas.texels(mid,'over'))~=h[2]then return false end
 end
 return true
end
function P.match(input,comp,atlas)
 if comp.minX==11 and comp.maxX==17 and comp.minY==0 and comp.maxY==5 and guard(input,atlas)then
  return {name='one-island-network-center',wallRows=2,nativeNetworkRoof=true,topArtVerified=true}
 end
end
return P
