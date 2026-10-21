local P={}
local function hash(t)
 if t then for i=1,256 do local v=t[i];if type(v)~="number"or v~=v or math.abs(v)==math.huge then return nil end end end
 local q=0
 for i=1,256 do q=(q*31+((t and type(t[i])=='number'and t[i]>=0)and t[i]+2 or 1))%2147483647 end
 return q
end
local function validRect(fn,mid,optional)
 local a,b,c,d=fn(mid)
 if a==nil and b==nil and c==nil and d==nil then return optional end
 for _,v in ipairs({a,b,c,d})do if type(v)~='number'or v~=v or v<0 or v>1 then return false end end
 return type(a)=='number'and type(b)=='number'and type(c)=='number'and type(d)=='number'and a<c and b<d
end
function P.match()return nil end
local partitionNative={pair="general__rom_082d4b3c",cells={
{792,793,794,795,796,797,798,30,31,30,31,8,9,30,31,30,31,30,31},
{736,737,737,737,737,738,739,36,37,36,39,16,17,38,37,36,37,36,37},
{736,737,737,737,737,737,740,358,358,358,358,358,358,358,358,358,358,358,359},
{744,768,769,746,770,771,748,749,750,750,758,749,750,735,757,749,750,750,742},
{752,776,777,754,778,779,756,736,737,737,740,736,737,738,739,736,737,737,740},
{752,776,777,754,778,779,756,744,745,747,748,744,745,747,748,744,745,747,748},
{752,776,772,767,773,779,756,752,753,755,756,752,753,755,756,752,753,755,756},
{760,765,780,61,781,766,764,760,761,763,764,760,761,763,764,760,761,763,764},
},art={
[8]={1832243108,87157625},
[9]={556348727,87157625},
[16]={1847008231,87157625},
[17]={1919699102,87157625},
[30]={235759344,87157625},
[31]={743845522,87157625},
[36]={1975529659,87157625},
[37]={1867260125,87157625},
[38]={1920219321,87157625},
[39]={1171012476,87157625},
[61]={500236739,87157625},
[358]={898154733,87157625},
[359]={1131370034,87157625},
[735]={2026021402,695905386},
[736]={174315250,106954207},
[737]={1847008231,483516039},
[738]={1919699102,712403795},
[739]={1847008231,1080561824},
[740]={1919699102,1035132515},
[742]={84860712,2041438446},
[744]={1669623459,1092242829},
[745]={1777740419,1830333733},
[746]={1125564981,1689115873},
[747]={1669623459,512075584},
[748]={1777740419,1341571263},
[749]={2026021402,955779674},
[750]={2026021402,194199385},
[752]={1908518559,226415862},
[753]={1293883226,2142609313},
[754]={880602888,349441898},
[755]={1908518559,1108249190},
[756]={1293883226,1356811946},
[757]={2026021402,494897051},
[758]={2026021402,2041438446},
[760]={305034219,87157625},
[761]={1571275518,87157625},
[763]={332749955,87157625},
[764]={779000552,87157625},
[765]={1552421979,87157625},
[766]={1764561877,87157625},
[767]={739348400,493408359},
[768]={1777740419,2102149265},
[769]={174315250,1266242940},
[770]={174315250,380191388},
[771]={1669623459,782531940},
[772]={174315250,1043637473},
[773]={174315250,287975207},
[776]={1293883226,1449458012},
[777]={174315250,1306019866},
[778]={174315250,1391319979},
[779]={1908518559,766565336},
[780]={1120830140,87157625},
[781]={776974695,87157625},
[792]={1660505550,1036749458},
[793]={1919699102,181789585},
[794]={1906559468,747706561},
[795]={394276289,143543328},
[796]={1465240883,68617580},
[797]={1267765388,776875170},
[798]={1995076784,482487251},
},layers={
[8]={false,0},
[9]={false,0},
[16]={false,0},
[17]={false,0},
[30]={false,0},
[31]={false,0},
[36]={false,0},
[37]={false,0},
[38]={false,0},
[39]={false,0},
[61]={false,0},
[358]={false,0},
[359]={false,0},
[735]={true,0.5},
[736]={true,1},
[737]={true,1},
[738]={true,1},
[739]={true,1},
[740]={true,1},
[742]={true,0.49609375},
[744]={true,0.83203125},
[745]={true,0.8203125},
[746]={true,0.65234375},
[747]={true,0.83203125},
[748]={true,0.8203125},
[749]={true,0.49609375},
[750]={true,0.5},
[752]={true,0.80078125},
[753]={true,0.7578125},
[754]={true,0.55859375},
[755]={true,0.80078125},
[756]={true,0.7578125},
[757]={true,0.49609375},
[758]={true,0.49609375},
[760]={false,0},
[761]={false,0},
[763]={false,0},
[764]={false,0},
[765]={false,0},
[766]={false,0},
[767]={true,0.90625},
[768]={true,0.8203125},
[769]={true,1},
[770]={true,1},
[771]={true,0.83203125},
[772]={true,1},
[773]={true,1},
[776]={true,0.7578125},
[777]={true,1},
[778]={true,1},
[779]={true,0.80078125},
[780]={false,0},
[781]={false,0},
[792]={true,0.90234375},
[793]={true,0.90625},
[794]={true,0.65625},
[795]={true,0.75},
[796]={true,0.65625},
[797]={true,0.90625},
[798]={true,0.90234375},
},states={
{{7,0,0,0,0,"BUILDING"},{7,0,0,0,0,"BUILDING"},{0,3,0,0,1,"TOWN_PATH"},{113,3,101,0,1,"DOOR"},{0,3,0,0,1,"TOWN_PATH"},{7,0,0,0,0,"BUILDING"},{7,0,0,0,0,"BUILDING"},{7,0,0,1,0,"TREE"},{7,0,0,1,0,"TREE"},{7,0,0,1,0,"TREE"},{7,0,0,1,0,"TREE"},{0,3,0,1,1,"TOWN_PATH"},{0,3,0,1,1,"TOWN_PATH"},{7,0,0,1,0,"TREE"},{7,0,0,1,0,"TREE"},{7,0,0,1,0,"TREE"},{7,0,0,1,0,"TREE"},{7,0,0,1,0,"TREE"},{7,0,0,1,0,"TREE"}},
{{7,0,0,0,0,"BUILDING"},{7,0,0,0,0,"BUILDING"},{7,0,0,0,0,"BUILDING"},{7,0,0,0,0,"BUILDING"},{7,0,0,0,0,"BUILDING"},{7,0,0,0,0,"BUILDING"},{7,0,0,0,0,"BUILDING"},{7,0,0,1,0,"TREE"},{7,0,0,1,0,"TREE"},{7,0,0,1,0,"TREE"},{7,0,0,1,0,"TREE"},{0,3,0,1,1,"TOWN_PATH"},{0,3,0,1,1,"TOWN_PATH"},{7,0,0,1,0,"TREE"},{7,0,0,1,0,"TREE"},{7,0,0,1,0,"TREE"},{7,0,0,1,0,"TREE"},{7,0,0,1,0,"TREE"},{7,0,0,1,0,"TREE"}},
{{7,0,0,0,0,"BUILDING"},{7,0,0,0,0,"BUILDING"},{7,0,0,0,0,"BUILDING"},{7,0,0,0,0,"BUILDING"},{7,0,0,0,0,"BUILDING"},{7,0,0,0,0,"BUILDING"},{7,0,0,0,0,"BUILDING"},{0,3,0,1,1,"TOWN_PATH"},{0,3,0,1,1,"TOWN_PATH"},{0,3,0,1,1,"TOWN_PATH"},{0,3,0,1,1,"TOWN_PATH"},{0,3,0,1,1,"TOWN_PATH"},{0,3,0,1,1,"TOWN_PATH"},{0,3,0,1,1,"TOWN_PATH"},{0,3,0,1,1,"TOWN_PATH"},{0,3,0,1,1,"TOWN_PATH"},{0,3,0,1,1,"TOWN_PATH"},{0,3,0,1,1,"TOWN_PATH"},{0,3,0,1,1,"TOWN_PATH"}},
{{7,0,0,0,0,"BUILDING"},{7,0,0,0,0,"BUILDING"},{7,0,0,0,0,"BUILDING"},{7,0,0,0,0,"BUILDING"},{7,0,0,0,0,"BUILDING"},{7,0,0,0,0,"BUILDING"},{7,0,0,0,0,"BUILDING"},{0,3,0,0,1,"TOWN_PATH"},{0,3,0,0,1,"TOWN_PATH"},{0,3,0,0,1,"TOWN_PATH"},{0,3,0,0,1,"TOWN_PATH"},{0,3,0,0,1,"TOWN_PATH"},{0,3,0,0,1,"TOWN_PATH"},{0,3,0,0,1,"TOWN_PATH"},{0,3,0,0,1,"TOWN_PATH"},{0,3,0,0,1,"TOWN_PATH"},{0,3,0,0,1,"TOWN_PATH"},{0,3,0,0,1,"TOWN_PATH"},{0,3,0,0,1,"TOWN_PATH"}},
{{7,0,0,0,0,"BUILDING"},{7,0,0,0,0,"BUILDING"},{7,0,0,0,0,"BUILDING"},{7,0,0,0,0,"BUILDING"},{7,0,0,0,0,"BUILDING"},{7,0,0,0,0,"BUILDING"},{7,0,0,0,0,"BUILDING"},{7,0,0,0,0,"BUILDING"},{7,0,0,0,0,"BUILDING"},{7,0,0,0,0,"BUILDING"},{7,0,0,0,0,"BUILDING"},{7,0,0,0,0,"BUILDING"},{7,0,0,0,0,"BUILDING"},{7,0,0,0,0,"BUILDING"},{7,0,0,0,0,"BUILDING"},{7,0,0,0,0,"BUILDING"},{7,0,0,0,0,"BUILDING"},{7,0,0,0,0,"BUILDING"},{7,0,0,0,0,"BUILDING"}},
{{7,0,0,0,0,"BUILDING"},{7,0,0,0,0,"BUILDING"},{7,0,0,0,0,"BUILDING"},{7,0,0,0,0,"BUILDING"},{7,0,0,0,0,"BUILDING"},{7,0,0,0,0,"BUILDING"},{7,0,0,0,0,"BUILDING"},{7,0,0,0,0,"BUILDING"},{7,0,0,0,0,"BUILDING"},{7,0,0,0,0,"BUILDING"},{7,0,0,0,0,"BUILDING"},{7,0,0,0,0,"BUILDING"},{7,0,0,0,0,"BUILDING"},{7,0,0,0,0,"BUILDING"},{7,0,0,0,0,"BUILDING"},{7,0,0,0,0,"BUILDING"},{7,0,0,0,0,"BUILDING"},{7,0,0,0,0,"BUILDING"},{7,0,0,0,0,"BUILDING"}},
{{7,0,0,0,0,"BUILDING"},{7,0,0,0,0,"BUILDING"},{7,0,0,0,0,"BUILDING"},{7,0,0,0,0,"BUILDING"},{7,0,0,0,0,"BUILDING"},{7,0,0,0,0,"BUILDING"},{7,0,0,0,0,"BUILDING"},{7,0,0,0,0,"BUILDING"},{7,0,0,0,0,"BUILDING"},{7,0,0,0,0,"BUILDING"},{7,0,0,0,0,"BUILDING"},{7,0,0,0,0,"BUILDING"},{7,0,0,0,0,"BUILDING"},{7,0,0,0,0,"BUILDING"},{7,0,0,0,0,"BUILDING"},{7,0,0,0,0,"BUILDING"},{7,0,0,0,0,"BUILDING"},{7,0,0,0,0,"BUILDING"},{7,0,0,0,0,"BUILDING"}},
{{7,0,0,1,0,"BUILDING"},{7,0,0,1,0,"BUILDING"},{7,0,0,1,0,"BUILDING"},{113,0,105,1,1,"DOOR"},{7,0,0,1,0,"BUILDING"},{7,0,0,1,0,"BUILDING"},{7,0,0,1,0,"BUILDING"},{7,0,0,1,0,"BUILDING"},{7,0,0,1,0,"BUILDING"},{7,0,0,1,0,"BUILDING"},{7,0,0,1,0,"BUILDING"},{7,0,0,1,0,"BUILDING"},{7,0,0,1,0,"BUILDING"},{7,0,0,1,0,"BUILDING"},{7,0,0,1,0,"BUILDING"},{7,0,0,1,0,"BUILDING"},{7,0,0,1,0,"BUILDING"},{7,0,0,1,0,"BUILDING"},{7,0,0,1,0,"BUILDING"}},
}}

-- A touching native complex is not one roof. Preserve its four independently
-- drawn boxes before the aggregate repeated-art diversity fallback can fold
-- window rows onto a per-column top. Exact native art/ownership is required.
function P.ownership(input,comp,atlas)
 if input.mapId~='FR_CELADON_CITY' or input.pair~=partitionNative.pair or input.isBorder
  or input.width~=60 or input.height~=40 or comp.minX~=27 or comp.maxX~=45
  or comp.minY~=4 or comp.maxY~=11 or type(atlas.texels)~='function' then return nil end
 if type(atlas.w)~='number'or atlas.w~=atlas.w or atlas.w<=0 or atlas.w==math.huge
  or type(atlas.h)~='number'or atlas.h~=atlas.h or atlas.h<=0 or atlas.h==math.huge then return nil end
 for y,row in ipairs(partitionNative.cells)do for x,mid in ipairs(row)do
  local c=input.cellAt(x+26,y+3);local st=partitionNative.states[y][x]
  if not c or c.mid~=mid or c.collision~=st[1]or c.elevation~=st[2]
   or c.behavior~=(st[3]~=-1 and st[3]or nil)or c.layerType~=st[4]
   or c.walkable~=(st[5]==1)or c.category~=st[6]then return nil end
 end end
 for mid,v in pairs(partitionNative.art)do
  if hash(atlas.texels(mid,'under'))~=v[1] or hash(atlas.texels(mid,'over'))~=v[2] then return nil end
  local ls=partitionNative.layers[mid]
  if type(atlas.underRect)~='function'or type(atlas.overRect)~='function'
   or type(atlas.hasOver)~='function'or type(atlas.overCoverage)~='function'then return nil end
  local u=atlas.underRect(mid);local o=atlas.overRect(mid)
  if u==nil or (o~=nil)~=ls[1]or atlas.hasOver(mid)~=ls[1]or atlas.overCoverage(mid)~=ls[2]
   or not validRect(atlas.underRect,mid,false)or not validRect(atlas.overRect,mid,not ls[1])then return nil end
 end
 return {{27,5,33,11,4},{34,8,37,11,2},{38,8,41,11,2},{42,8,45,11,2}}
end
local towerMatch=P.match
function P.match(input,comp,atlas)
 local q=towerMatch(input,comp,atlas);if q then return q end
 -- The ownership guard is checked against the original complex bbox.
 local original={minX=27,maxX=45,minY=4,maxY=11}
 local pieces=P.ownership(input,original,atlas)
 if pieces then for _,b in ipairs(pieces)do
  if comp.minX==b[1]and comp.minY==b[2]and comp.maxX==b[3]and comp.maxY==b[4]then
   return {name='celadon-native-green-slab',wallRows=b[5],flatRoof=true,partialFacadePixels=4,roofSourceYMin=b[1]==27 and 4.5 or nil,topArtVerified=true}
  end
 end end
end
return P
