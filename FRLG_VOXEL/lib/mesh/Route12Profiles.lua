local specs={
{name="route12-glazing",mapId="FR_ROUTE_12",pair="general__rom_082d4b0c",width=24,height=120,x0=11,y0=14,cells={{{299,41,1,21,1,0,-1,"BLOCKED"},{299,41,1,21,1,0,-1,"BLOCKED"},{755,0,3,0,1,1,-1,"TOWN_PATH"},{756,0,3,0,1,1,-1,"TOWN_PATH"},{757,0,3,0,1,1,-1,"TOWN_PATH"},{768,0,3,0,1,1,-1,"TOWN_PATH"},{769,0,3,0,1,1,-1,"TOWN_PATH"}},{{299,41,1,21,1,0,-1,"BLOCKED"},{299,41,1,21,1,0,-1,"BLOCKED"},{784,0,3,0,0,1,-1,"TOWN_PATH"},{785,113,3,101,0,1,-1,"DOOR"},{786,0,3,0,0,1,-1,"TOWN_PATH"},{776,41,1,21,1,0,-1,"BLOCKED"},{777,41,1,21,1,0,-1,"BLOCKED"}},{{299,41,1,21,1,0,-1,"BLOCKED"},{68,0,1,0,0,1,-1,"TOWN_PATH"},{69,7,0,0,0,0,-1,"BLOCKED"},{69,7,0,0,0,0,-1,"BLOCKED"},{69,7,0,0,0,0,-1,"BLOCKED"},{70,0,1,0,0,1,-1,"TOWN_PATH"},{299,41,1,21,1,0,-1,"BLOCKED"}},{{273,7,0,21,1,0,-1,"BLOCKED"},{76,7,0,0,0,0,-1,"BLOCKED"},{77,7,0,0,0,0,-1,"BLOCKED"},{77,7,0,0,0,0,-1,"BLOCKED"},{77,7,0,0,0,0,-1,"BLOCKED"},{78,7,0,0,0,0,-1,"BLOCKED"},{272,7,0,21,1,0,-1,"BLOCKED"}},{{281,7,0,21,1,0,-1,"BLOCKED"},{387,7,0,0,0,0,-1,"BLOCKED"},{388,7,0,0,0,0,-1,"BLOCKED"},{388,7,0,0,0,0,-1,"BLOCKED"},{388,7,0,0,0,0,-1,"BLOCKED"},{389,7,0,0,0,0,-1,"BLOCKED"},{280,7,0,21,1,0,-1,"BLOCKED"}},{{299,41,1,21,1,0,-1,"BLOCKED"},{438,7,0,0,0,0,-1,"BLOCKED"},{437,7,0,0,0,0,-1,"BLOCKED"},{437,7,0,0,0,0,-1,"BLOCKED"},{437,7,0,0,0,0,-1,"BLOCKED"},{439,7,0,0,0,0,-1,"BLOCKED"},{299,41,1,21,1,0,-1,"BLOCKED"}},{{299,41,1,21,1,0,-1,"BLOCKED"},{92,7,0,0,0,0,-1,"BLOCKED"},{392,7,0,0,1,0,-1,"BLOCKED"},{393,7,0,0,0,0,-1,"BLOCKED"},{394,7,0,0,1,0,-1,"BLOCKED"},{94,7,0,0,0,0,-1,"BLOCKED"},{299,41,1,21,1,0,-1,"BLOCKED"}},{{299,41,1,21,1,0,-1,"BLOCKED"},{100,7,0,0,1,0,-1,"BLOCKED"},{400,7,0,0,1,0,-1,"BLOCKED"},{401,113,3,96,1,1,-1,"DOOR"},{402,7,0,0,1,0,-1,"BLOCKED"},{102,7,0,0,1,0,-1,"BLOCKED"},{299,41,1,21,1,0,-1,"BLOCKED"}},{{299,41,1,21,1,0,-1,"BLOCKED"},{776,41,1,21,1,0,-1,"BLOCKED"},{787,0,3,0,1,1,-1,"TOWN_PATH"},{788,0,3,0,1,1,-1,"TOWN_PATH"},{789,0,3,0,1,1,-1,"TOWN_PATH"},{778,41,1,21,1,0,-1,"BLOCKED"},{299,41,1,21,1,0,-1,"BLOCKED"}},{{299,41,1,21,1,0,-1,"BLOCKED"},{299,41,1,21,1,0,-1,"BLOCKED"},{755,0,3,0,1,1,-1,"TOWN_PATH"},{756,0,3,0,1,1,-1,"TOWN_PATH"},{757,0,3,0,1,1,-1,"TOWN_PATH"},{299,41,1,21,1,0,-1,"BLOCKED"},{299,41,1,21,1,0,-1,"BLOCKED"}}},owner={13,16,15,21},body={13,16,15,21},wallRows=3,partial=0,flat=true,art={[68]={1449897259,584997343,true},[69]={1449897259,1929591673,true},[70]={1449897259,2391732,true},[76]={997930961,997930961,true},[77]={1699766040,1699766040,true},[78]={942050587,942050587,true},[92]={1147223811,1147223811,true},[94]={852281276,852281276,true},[100]={999919132,0,false},[102]={1855461555,0,false},[272]={948889538,0,false},[273]={2054578701,0,false},[280]={1505469018,0,false},[281]={1354409293,0,false},[299]={1139965285,0,false},[387]={700548537,700548537,true},[388]={471440039,471440039,true},[389]={1700168634,1700168634,true},[392]={1384865569,0,false},[393]={1047765935,515138532,true},[394]={638977267,0,false},[400]={542487895,0,false},[401]={14165515,0,false},[402]={554376469,0,false},[437]={948122548,1332558416,true},[438]={1759066995,564297582,true},[439]={1776012766,1463931243,true},[755]={1270490326,0,false},[756]={2060718677,0,false},[757]={364599404,0,false},[768]={703543776,0,false},[769]={148967511,0,false},[776]={233696371,0,false},[777]={1772637922,0,false},[778]={1355419075,0,false},[784]={932973688,2048632771,true},[785]={1951169072,1811847405,true},[786]={1312840625,1650915757,true},[787]={1391741625,0,false},[788]={1000911478,0,false},[789]={283001808,0,false}}},
}
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
local function guard(native,input,atlas)
 if input.mapId~=native.mapId or input.pair~=native.pair or input.isBorder
  or input.width~=native.width or input.height~=native.height or type(atlas.texels)~='function'
  or type(atlas.hasOver)~='function' or type(atlas.underRect)~='function'
  or type(atlas.overRect)~='function' then return false end
 for yi,row in ipairs(native.cells)do for xi,s in ipairs(row)do
  local c=input.cellAt(native.x0+xi-1,native.y0+yi-1)
  if not c or c.mid~=s[1]or c.collision~=s[2]or c.elevation~=s[3]
   or c.behavior~=(s[4]~=-1 and s[4]or nil)or c.layerType~=s[5]
   or c.walkable~=(s[6]==1)or c.category~=s[8]then return false end
 end end
 for mid,h in pairs(native.art)do
  if atlas.hasOver(mid)~=h[3] or not rect(atlas.underRect,mid)
   or (h[3] and not rect(atlas.overRect,mid))then return false end
  if hash(atlas.texels(mid,'under'))~=h[1]or hash(atlas.texels(mid,'over'))~=h[2]then return false end
 end
 return true
end
local P={}
local function same(c,b)return c.minX==b[1]and c.minY==b[2]and c.maxX==b[3]and c.maxY==b[4]end
function P.match(input,comp,atlas)
 for _,s in ipairs(specs)do if same(comp,s.body)and guard(s,input,atlas)then
  return {name=s.name,wallRows=s.wallRows,flatRoof=s.flat,topArtVerified=true,nativeRoute12Exterior=true}
 end end
end
return P
