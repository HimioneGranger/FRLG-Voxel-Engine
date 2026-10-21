local H={}
local expected={{["sourceMap"]="FR_FIVE_ISLAND",["sourceX"]=20,["sourceY"]=5,["x"]=20,["y"]=5,["mid"]=407,["collision"]=7,["elevation"]=0,["behavior"]=0,["walkable"]=false,["layerType"]=0,["category"]="BLOCKED"},{["sourceMap"]="FR_FIVE_ISLAND",["sourceX"]=21,["sourceY"]=5,["x"]=21,["y"]=5,["mid"]=9,["collision"]=7,["elevation"]=0,["behavior"]=0,["walkable"]=false,["layerType"]=1,["category"]="BLOCKED"},{["sourceMap"]="FR_FIVE_ISLAND",["sourceX"]=22,["sourceY"]=5,["x"]=22,["y"]=5,["mid"]=30,["collision"]=7,["elevation"]=0,["behavior"]=0,["walkable"]=false,["layerType"]=1,["category"]="TREE"},{["sourceMap"]="FR_FIVE_ISLAND",["sourceX"]=23,["sourceY"]=5,["x"]=23,["y"]=5,["mid"]=29,["collision"]=7,["elevation"]=0,["behavior"]=0,["walkable"]=false,["layerType"]=1,["category"]="TREE"},{["sourceMap"]="FR_FIVE_ISLAND_MEADOW",["sourceX"]=0,["sourceY"]=5,["x"]=24,["y"]=5,["mid"]=28,["collision"]=7,["elevation"]=0,["behavior"]=0,["walkable"]=false,["layerType"]=1,["category"]="TREE"},{["sourceMap"]="FR_FIVE_ISLAND_MEADOW",["sourceX"]=1,["sourceY"]=5,["x"]=25,["y"]=5,["mid"]=29,["collision"]=7,["elevation"]=0,["behavior"]=0,["walkable"]=false,["layerType"]=1,["category"]="TREE"},{["sourceMap"]="FR_FIVE_ISLAND_MEADOW",["sourceX"]=2,["sourceY"]=5,["x"]=26,["y"]=5,["mid"]=28,["collision"]=7,["elevation"]=0,["behavior"]=0,["walkable"]=false,["layerType"]=1,["category"]="TREE"},{["sourceMap"]="FR_FIVE_ISLAND",["sourceX"]=20,["sourceY"]=6,["x"]=20,["y"]=6,["mid"]=415,["collision"]=7,["elevation"]=0,["behavior"]=0,["walkable"]=false,["layerType"]=1,["category"]="BLOCKED"},{["sourceMap"]="FR_FIVE_ISLAND",["sourceX"]=21,["sourceY"]=6,["x"]=21,["y"]=6,["mid"]=641,["collision"]=7,["elevation"]=0,["behavior"]=0,["walkable"]=false,["layerType"]=0,["category"]="BUILDING"},{["sourceMap"]="FR_FIVE_ISLAND",["sourceX"]=22,["sourceY"]=6,["x"]=22,["y"]=6,["mid"]=776,["collision"]=0,["elevation"]=0,["behavior"]=0,["walkable"]=true,["layerType"]=0,["category"]="TOWN_PATH"},{["sourceMap"]="FR_FIVE_ISLAND",["sourceX"]=23,["sourceY"]=6,["x"]=23,["y"]=6,["mid"]=644,["collision"]=7,["elevation"]=0,["behavior"]=0,["walkable"]=false,["layerType"]=0,["category"]="BUILDING"},{["sourceMap"]="FR_FIVE_ISLAND_MEADOW",["sourceX"]=0,["sourceY"]=6,["x"]=24,["y"]=6,["mid"]=643,["collision"]=7,["elevation"]=0,["behavior"]=0,["walkable"]=false,["layerType"]=0,["category"]="BUILDING"},{["sourceMap"]="FR_FIVE_ISLAND_MEADOW",["sourceX"]=1,["sourceY"]=6,["x"]=25,["y"]=6,["mid"]=656,["collision"]=7,["elevation"]=0,["behavior"]=0,["walkable"]=false,["layerType"]=0,["category"]="BUILDING"},{["sourceMap"]="FR_FIVE_ISLAND_MEADOW",["sourceX"]=2,["sourceY"]=6,["x"]=26,["y"]=6,["mid"]=36,["collision"]=7,["elevation"]=0,["behavior"]=0,["walkable"]=false,["layerType"]=1,["category"]="TREE"},{["sourceMap"]="FR_FIVE_ISLAND",["sourceX"]=20,["sourceY"]=7,["x"]=20,["y"]=7,["mid"]=9,["collision"]=0,["elevation"]=3,["behavior"]=0,["walkable"]=true,["layerType"]=1,["category"]="TOWN_PATH"},{["sourceMap"]="FR_FIVE_ISLAND",["sourceX"]=21,["sourceY"]=7,["x"]=21,["y"]=7,["mid"]=649,["collision"]=7,["elevation"]=0,["behavior"]=0,["walkable"]=false,["layerType"]=0,["category"]="BUILDING"},{["sourceMap"]="FR_FIVE_ISLAND",["sourceX"]=22,["sourceY"]=7,["x"]=22,["y"]=7,["mid"]=650,["collision"]=7,["elevation"]=0,["behavior"]=0,["walkable"]=false,["layerType"]=0,["category"]="BUILDING"},{["sourceMap"]="FR_FIVE_ISLAND",["sourceX"]=23,["sourceY"]=7,["x"]=23,["y"]=7,["mid"]=651,["collision"]=7,["elevation"]=0,["behavior"]=0,["walkable"]=false,["layerType"]=0,["category"]="BUILDING"},{["sourceMap"]="FR_FIVE_ISLAND_MEADOW",["sourceX"]=0,["sourceY"]=7,["x"]=24,["y"]=7,["mid"]=652,["collision"]=7,["elevation"]=0,["behavior"]=0,["walkable"]=false,["layerType"]=0,["category"]="BUILDING"},{["sourceMap"]="FR_FIVE_ISLAND_MEADOW",["sourceX"]=1,["sourceY"]=7,["x"]=25,["y"]=7,["mid"]=653,["collision"]=7,["elevation"]=0,["behavior"]=0,["walkable"]=false,["layerType"]=0,["category"]="BUILDING"},{["sourceMap"]="FR_FIVE_ISLAND_MEADOW",["sourceX"]=2,["sourceY"]=7,["x"]=26,["y"]=7,["mid"]=8,["collision"]=0,["elevation"]=3,["behavior"]=0,["walkable"]=true,["layerType"]=1,["category"]="TOWN_PATH"},{["sourceMap"]="FR_FIVE_ISLAND",["sourceX"]=20,["sourceY"]=8,["x"]=20,["y"]=8,["mid"]=2,["collision"]=130,["elevation"]=0,["behavior"]=132,["walkable"]=false,["layerType"]=1,["category"]="SIGN"},{["sourceMap"]="FR_FIVE_ISLAND",["sourceX"]=21,["sourceY"]=8,["x"]=21,["y"]=8,["mid"]=657,["collision"]=7,["elevation"]=0,["behavior"]=0,["walkable"]=false,["layerType"]=0,["category"]="BUILDING"},{["sourceMap"]="FR_FIVE_ISLAND",["sourceX"]=22,["sourceY"]=8,["x"]=22,["y"]=8,["mid"]=658,["collision"]=7,["elevation"]=0,["behavior"]=0,["walkable"]=false,["layerType"]=0,["category"]="BUILDING"},{["sourceMap"]="FR_FIVE_ISLAND",["sourceX"]=23,["sourceY"]=8,["x"]=23,["y"]=8,["mid"]=659,["collision"]=7,["elevation"]=0,["behavior"]=0,["walkable"]=false,["layerType"]=0,["category"]="BUILDING"},{["sourceMap"]="FR_FIVE_ISLAND_MEADOW",["sourceX"]=0,["sourceY"]=8,["x"]=24,["y"]=8,["mid"]=660,["collision"]=7,["elevation"]=0,["behavior"]=0,["walkable"]=false,["layerType"]=0,["category"]="BUILDING"},{["sourceMap"]="FR_FIVE_ISLAND_MEADOW",["sourceX"]=1,["sourceY"]=8,["x"]=25,["y"]=8,["mid"]=661,["collision"]=7,["elevation"]=0,["behavior"]=0,["walkable"]=false,["layerType"]=0,["category"]="BUILDING"},{["sourceMap"]="FR_FIVE_ISLAND_MEADOW",["sourceX"]=2,["sourceY"]=8,["x"]=26,["y"]=8,["mid"]=16,["collision"]=0,["elevation"]=3,["behavior"]=0,["walkable"]=true,["layerType"]=1,["category"]="TOWN_PATH"},{["sourceMap"]="FR_FIVE_ISLAND",["sourceX"]=20,["sourceY"]=9,["x"]=20,["y"]=9,["mid"]=8,["collision"]=0,["elevation"]=3,["behavior"]=0,["walkable"]=true,["layerType"]=1,["category"]="TOWN_PATH"},{["sourceMap"]="FR_FIVE_ISLAND",["sourceX"]=21,["sourceY"]=9,["x"]=21,["y"]=9,["mid"]=665,["collision"]=7,["elevation"]=0,["behavior"]=0,["walkable"]=false,["layerType"]=1,["category"]="BUILDING"},{["sourceMap"]="FR_FIVE_ISLAND",["sourceX"]=22,["sourceY"]=9,["x"]=22,["y"]=9,["mid"]=666,["collision"]=113,["elevation"]=0,["behavior"]=105,["walkable"]=true,["layerType"]=1,["category"]="DOOR"},{["sourceMap"]="FR_FIVE_ISLAND",["sourceX"]=23,["sourceY"]=9,["x"]=23,["y"]=9,["mid"]=667,["collision"]=7,["elevation"]=0,["behavior"]=0,["walkable"]=false,["layerType"]=1,["category"]="BUILDING"},{["sourceMap"]="FR_FIVE_ISLAND_MEADOW",["sourceX"]=0,["sourceY"]=9,["x"]=24,["y"]=9,["mid"]=668,["collision"]=7,["elevation"]=0,["behavior"]=0,["walkable"]=false,["layerType"]=1,["category"]="BUILDING"},{["sourceMap"]="FR_FIVE_ISLAND_MEADOW",["sourceX"]=1,["sourceY"]=9,["x"]=25,["y"]=9,["mid"]=669,["collision"]=7,["elevation"]=0,["behavior"]=0,["walkable"]=false,["layerType"]=1,["category"]="BUILDING"},{["sourceMap"]="FR_FIVE_ISLAND_MEADOW",["sourceX"]=2,["sourceY"]=9,["x"]=26,["y"]=9,["mid"]=8,["collision"]=0,["elevation"]=3,["behavior"]=0,["walkable"]=true,["layerType"]=1,["category"]="TOWN_PATH"},{["sourceMap"]="FR_FIVE_ISLAND",["sourceX"]=20,["sourceY"]=10,["x"]=20,["y"]=10,["mid"]=9,["collision"]=0,["elevation"]=3,["behavior"]=0,["walkable"]=true,["layerType"]=1,["category"]="TOWN_PATH"},{["sourceMap"]="FR_FIVE_ISLAND",["sourceX"]=21,["sourceY"]=10,["x"]=21,["y"]=10,["mid"]=9,["collision"]=0,["elevation"]=3,["behavior"]=0,["walkable"]=true,["layerType"]=1,["category"]="TOWN_PATH"},{["sourceMap"]="FR_FIVE_ISLAND",["sourceX"]=22,["sourceY"]=10,["x"]=22,["y"]=10,["mid"]=16,["collision"]=0,["elevation"]=3,["behavior"]=0,["walkable"]=true,["layerType"]=1,["category"]="TOWN_PATH"},{["sourceMap"]="FR_FIVE_ISLAND",["sourceX"]=23,["sourceY"]=10,["x"]=23,["y"]=10,["mid"]=178,["collision"]=7,["elevation"]=0,["behavior"]=0,["walkable"]=false,["layerType"]=1,["category"]="CLIFF"},{["sourceMap"]="FR_FIVE_ISLAND_MEADOW",["sourceX"]=0,["sourceY"]=10,["x"]=24,["y"]=10,["mid"]=121,["collision"]=7,["elevation"]=0,["behavior"]=0,["walkable"]=false,["layerType"]=1,["category"]="BLOCKED"},{["sourceMap"]="FR_FIVE_ISLAND_MEADOW",["sourceX"]=1,["sourceY"]=10,["x"]=25,["y"]=10,["mid"]=121,["collision"]=7,["elevation"]=0,["behavior"]=0,["walkable"]=false,["layerType"]=1,["category"]="BLOCKED"},{["sourceMap"]="FR_FIVE_ISLAND_MEADOW",["sourceX"]=2,["sourceY"]=10,["x"]=26,["y"]=10,["mid"]=145,["collision"]=0,["elevation"]=3,["behavior"]=42,["walkable"]=true,["layerType"]=1,["category"]="STAIR"},{["sourceMap"]="FR_FIVE_ISLAND",["sourceX"]=20,["sourceY"]=11,["x"]=20,["y"]=11,["mid"]=121,["collision"]=7,["elevation"]=0,["behavior"]=0,["walkable"]=false,["layerType"]=1,["category"]="BLOCKED"},{["sourceMap"]="FR_FIVE_ISLAND",["sourceX"]=21,["sourceY"]=11,["x"]=21,["y"]=11,["mid"]=121,["collision"]=7,["elevation"]=0,["behavior"]=0,["walkable"]=false,["layerType"]=1,["category"]="BLOCKED"},{["sourceMap"]="FR_FIVE_ISLAND",["sourceX"]=22,["sourceY"]=11,["x"]=22,["y"]=11,["mid"]=121,["collision"]=7,["elevation"]=0,["behavior"]=0,["walkable"]=false,["layerType"]=1,["category"]="BLOCKED"},{["sourceMap"]="FR_FIVE_ISLAND",["sourceX"]=23,["sourceY"]=11,["x"]=23,["y"]=11,["mid"]=170,["collision"]=7,["elevation"]=0,["behavior"]=0,["walkable"]=false,["layerType"]=1,["category"]="BLOCKED"},{["sourceMap"]="FR_FIVE_ISLAND_MEADOW",["sourceX"]=0,["sourceY"]=11,["x"]=24,["y"]=11,["mid"]=277,["collision"]=0,["elevation"]=3,["behavior"]=33,["walkable"]=true,["layerType"]=1,["category"]="SAND"},{["sourceMap"]="FR_FIVE_ISLAND_MEADOW",["sourceX"]=1,["sourceY"]=11,["x"]=25,["y"]=11,["mid"]=277,["collision"]=0,["elevation"]=3,["behavior"]=33,["walkable"]=true,["layerType"]=1,["category"]="SAND"},{["sourceMap"]="FR_FIVE_ISLAND_MEADOW",["sourceX"]=2,["sourceY"]=11,["x"]=26,["y"]=11,["mid"]=277,["collision"]=0,["elevation"]=3,["behavior"]=33,["walkable"]=true,["layerType"]=1,["category"]="SAND"}}
local art={[407]={["under"]=2811027456,["over"]=2167550126,["underRect"]={0.0001220703125,0.4445167824074074,0.0623779296875,0.48140914351851855},["overRect"]={0.0001220703125,0.4445167824074074,0.0623779296875,0.48140914351851855},["hasOver"]=true,["coverage"]=1},[9]={["under"]=363769266,["over"]=-2,["underRect"]={0.3751220703125,7.233796296296296e-05,0.4373779296875,0.03696469907407408},["overRect"]=nil,["hasOver"]=false,["coverage"]=0},[30]={["under"]=3891617254,["over"]=-2,["underRect"]={0.3751220703125,0.037109375,0.4373779296875,0.0740017361111111},["overRect"]=nil,["hasOver"]=false,["coverage"]=0},[29]={["under"]=1193981579,["over"]=-2,["underRect"]={0.3126220703125,0.037109375,0.3748779296875,0.0740017361111111},["overRect"]=nil,["hasOver"]=false,["coverage"]=0},[28]={["under"]=569434451,["over"]=-2,["underRect"]={0.2501220703125,0.037109375,0.3123779296875,0.0740017361111111},["overRect"]=nil,["hasOver"]=false,["coverage"]=0},[415]={["under"]=3921902569,["over"]=-2,["underRect"]={0.0626220703125,0.4445167824074074,0.1248779296875,0.48140914351851855},["overRect"]=nil,["hasOver"]=false,["coverage"]=0},[641]={["under"]=1704558350,["over"]=760777582,["underRect"]={0.0626220703125,0.6297019675925926,0.1248779296875,0.6665943287037037},["overRect"]={0.0626220703125,0.6297019675925926,0.1248779296875,0.6665943287037037},["hasOver"]=true,["coverage"]=0.4609375},[776]={["under"]=1492616205,["over"]=3841950208,["underRect"]={0.1876220703125,0.9259982638888888,0.2498779296875,0.962890625},["overRect"]={0.1876220703125,0.9259982638888888,0.2498779296875,0.962890625},["hasOver"]=true,["coverage"]=0.46875},[644]={["under"]=874358900,["over"]=3841950208,["underRect"]={0.2501220703125,0.6297019675925926,0.3123779296875,0.6665943287037037},["overRect"]={0.2501220703125,0.6297019675925926,0.3123779296875,0.6665943287037037},["hasOver"]=true,["coverage"]=0.46875},[643]={["under"]=2104209306,["over"]=3841950208,["underRect"]={0.1876220703125,0.6297019675925926,0.2498779296875,0.6665943287037037},["overRect"]={0.1876220703125,0.6297019675925926,0.2498779296875,0.6665943287037037},["hasOver"]=true,["coverage"]=0.46875},[656]={["under"]=874358900,["over"]=702028818,["underRect"]={0.0001220703125,0.6667390046296297,0.0623779296875,0.7036313657407407},["overRect"]={0.0001220703125,0.6667390046296297,0.0623779296875,0.7036313657407407},["hasOver"]=true,["coverage"]=0.4609375},[36]={["under"]=2104209306,["over"]=-2,["underRect"]={0.5626220703125,0.037109375,0.6248779296875,0.0740017361111111},["overRect"]=nil,["hasOver"]=false,["coverage"]=0},[649]={["under"]=2626827344,["over"]=1501498177,["underRect"]={0.5626220703125,0.6297019675925926,0.6248779296875,0.6665943287037037},["overRect"]={0.5626220703125,0.6297019675925926,0.6248779296875,0.6665943287037037},["hasOver"]=true,["coverage"]=1},[650]={["under"]=366599120,["over"]=175082752,["underRect"]={0.6251220703125,0.6297019675925926,0.6873779296875,0.6665943287037037},["overRect"]={0.6251220703125,0.6297019675925926,0.6873779296875,0.6665943287037037},["hasOver"]=true,["coverage"]=1},[651]={["under"]=2626827344,["over"]=175082752,["underRect"]={0.6876220703125,0.6297019675925926,0.7498779296875,0.6665943287037037},["overRect"]={0.6876220703125,0.6297019675925926,0.7498779296875,0.6665943287037037},["hasOver"]=true,["coverage"]=1},[652]={["under"]=366599120,["over"]=175082752,["underRect"]={0.7501220703125,0.6297019675925926,0.8123779296875,0.6665943287037037},["overRect"]={0.7501220703125,0.6297019675925926,0.8123779296875,0.6665943287037037},["hasOver"]=true,["coverage"]=1},[653]={["under"]=2626827344,["over"]=2247105279,["underRect"]={0.8126220703125,0.6297019675925926,0.8748779296875,0.6665943287037037},["overRect"]={0.8126220703125,0.6297019675925926,0.8748779296875,0.6665943287037037},["hasOver"]=true,["coverage"]=1},[8]={["under"]=1704558350,["over"]=-2,["underRect"]={0.3126220703125,7.233796296296296e-05,0.3748779296875,0.03696469907407408},["overRect"]=nil,["hasOver"]=false,["coverage"]=0},[2]={["under"]=2257146360,["over"]=-2,["underRect"]={0.1251220703125,7.233796296296296e-05,0.1873779296875,0.03696469907407408},["overRect"]=nil,["hasOver"]=false,["coverage"]=0},[657]={["under"]=1704558350,["over"]=3971945758,["underRect"]={0.0626220703125,0.6667390046296297,0.1248779296875,0.7036313657407407},["overRect"]={0.0626220703125,0.6667390046296297,0.1248779296875,0.7036313657407407},["hasOver"]=true,["coverage"]=0.98828125},[658]={["under"]=363769266,["over"]=3259369472,["underRect"]={0.1251220703125,0.6667390046296297,0.1873779296875,0.7036313657407407},["overRect"]={0.1251220703125,0.6667390046296297,0.1873779296875,0.7036313657407407},["hasOver"]=true,["coverage"]=1},[659]={["under"]=1704558350,["over"]=47487104,["underRect"]={0.1876220703125,0.6667390046296297,0.2498779296875,0.7036313657407407},["overRect"]={0.1876220703125,0.6667390046296297,0.2498779296875,0.7036313657407407},["hasOver"]=true,["coverage"]=1},[660]={["under"]=363769266,["over"]=3624450560,["underRect"]={0.2501220703125,0.6667390046296297,0.3123779296875,0.7036313657407407},["overRect"]={0.2501220703125,0.6667390046296297,0.3123779296875,0.7036313657407407},["hasOver"]=true,["coverage"]=1},[661]={["under"]=1704558350,["over"]=1614148593,["underRect"]={0.3126220703125,0.6667390046296297,0.3748779296875,0.7036313657407407},["overRect"]={0.3126220703125,0.6667390046296297,0.3748779296875,0.7036313657407407},["hasOver"]=true,["coverage"]=1},[16]={["under"]=2626827344,["over"]=-2,["underRect"]={0.7501220703125,7.233796296296296e-05,0.8123779296875,0.03696469907407408},["overRect"]=nil,["hasOver"]=false,["coverage"]=0},[665]={["under"]=4220391066,["over"]=-2,["underRect"]={0.5626220703125,0.6667390046296297,0.6248779296875,0.7036313657407407},["overRect"]=nil,["hasOver"]=false,["coverage"]=0},[666]={["under"]=1250125271,["over"]=-2,["underRect"]={0.6251220703125,0.6667390046296297,0.6873779296875,0.7036313657407407},["overRect"]=nil,["hasOver"]=false,["coverage"]=0},[667]={["under"]=2895760843,["over"]=-2,["underRect"]={0.6876220703125,0.6667390046296297,0.7498779296875,0.7036313657407407},["overRect"]=nil,["hasOver"]=false,["coverage"]=0},[668]={["under"]=2770087890,["over"]=-2,["underRect"]={0.7501220703125,0.6667390046296297,0.8123779296875,0.7036313657407407},["overRect"]=nil,["hasOver"]=false,["coverage"]=0},[669]={["under"]=4271287832,["over"]=-2,["underRect"]={0.8126220703125,0.6667390046296297,0.8748779296875,0.7036313657407407},["overRect"]=nil,["hasOver"]=false,["coverage"]=0},[178]={["under"]=995138713,["over"]=-2,["underRect"]={0.8126220703125,0.18525752314814814,0.8748779296875,0.22214988425925927},["overRect"]=nil,["hasOver"]=false,["coverage"]=0},[121]={["under"]=1037494172,["over"]=-2,["underRect"]={0.3126220703125,0.1482204861111111,0.3748779296875,0.1851128472222222},["overRect"]=nil,["hasOver"]=false,["coverage"]=0},[145]={["under"]=2893955624,["over"]=-2,["underRect"]={0.1251220703125,0.18525752314814814,0.1873779296875,0.22214988425925927},["overRect"]=nil,["hasOver"]=false,["coverage"]=0},[170]={["under"]=3709188434,["over"]=-2,["underRect"]={0.6251220703125,0.18525752314814814,0.6873779296875,0.22214988425925927},["overRect"]=nil,["hasOver"]=false,["coverage"]=0},[277]={["under"]=3903724672,["over"]=-2,["underRect"]={0.5626220703125,0.3334056712962963,0.6248779296875,0.3702980324074074},["overRect"]=nil,["hasOver"]=false,["coverage"]=0}}
local aw,ah=256,432
local function finite(v)return type(v)=="number"and v==v and math.abs(v)~=math.huge end
local function hash(t)
 if t==nil then return -2 end
 if type(t)~="table"then return nil end
 local h=0
 for i=1,256 do local v=t[i];if not finite(v)or v~=math.floor(v)or v< -1 or v>16777215 then return nil end
  h=(h*65599+v+2)%4294967296
 end
 return h
end
local function same(c,e)
 if type(c)~="table"then return false end
 for _,k in ipairs{"mid","collision","elevation","behavior","walkable","layerType","category"}do if c[k]~=e[k]then return false end end
 return true
end
function H.guard(input,atlas,tick)
 local id=input.mapId;local q=input.connectedHouseSource
 if input.isBorder or(id~="FR_FIVE_ISLAND"and id~="FR_FIVE_ISLAND_MEADOW")or input.width~=24
  or input.height~=(id=="FR_FIVE_ISLAND"and 20 or 40)or input.pair~="general__rom_082d5064"
  or type(q)~="table"or q.name~="five-island-connected-house"or q.owner~="FR_FIVE_ISLAND"
  or q.mapId~=id or q.pair~=input.pair or q.atlas~=atlas or q.ownerOffsetY~=0
  or q.ownerOffsetX~=(id=="FR_FIVE_ISLAND_MEADOW"and -24 or 0)
  or q.minX~=20 or q.maxX~=26 or q.minY~=5 or q.maxY~=11 or type(q.cells)~="table"or #q.cells~=49
  or type(input.cellAt)~="function"or type(atlas)~="table"or atlas.w~=aw or atlas.h~=ah
  or not finite(atlas.w)or not finite(atlas.h)or atlas.w<=0 or atlas.h<=0 then return nil end
 for _,k in ipairs{"texels","underRect","overRect","hasOver","overCoverage"}do if type(atlas[k])~="function"then return nil end end
 for i,e in ipairs(expected)do local c=q.cells[i]
  if not same(c,e)then return nil end
  for _,k in ipairs{"sourceMap","sourceX","sourceY","x","y"}do if c[k]~=e[k]then return nil end end
  if e.sourceMap==id and not same(input.cellAt(e.sourceX,e.sourceY),e)then return nil end
 end
 local g=q.groundDonor;local e=expected[37]
 -- Global(21,10) is element37 in the row-major49-cell context.
 if not same(g,e)or g.sourceMap~="FR_FIVE_ISLAND"or g.sourceX~=21 or g.sourceY~=10 or g.x~=21 or g.y~=10 then return nil end
 for mid,p in pairs(art)do
  if hash(atlas.texels(mid,"under"))~=p.under or hash(atlas.texels(mid,"over"))~=p.over
   or atlas.hasOver(mid)~=p.hasOver or atlas.overCoverage(mid)~=p.coverage then return nil end
  for _,ly in ipairs{"under","over"}do local rect={atlas[ly.."Rect"](mid)};local want=p[ly.."Rect"]
   if want==nil then if rect[1]~=nil then return nil end
   else for j=1,4 do if not finite(rect[j])or rect[j]~=want[j]then return nil end end end
  end
  if tick then tick()end
 end
 if type(q.sourceVersions)~="table"or #q.sourceVersions~=2 then return nil end
 for k in pairs(q.sourceVersions)do if k~=1 and k~=2 then return nil end end
 for i=1,2 do local v=q.sourceVersions[i];if type(v)~="string"and not finite(v)then return nil end end
 return q
end
function H.claims(q,id,x,y)
 if id~="FR_FIVE_ISLAND"and id~="FR_FIVE_ISLAND_MEADOW"then return false end
 local gx=x+(id=="FR_FIVE_ISLAND_MEADOW"and 24 or 0)
 return gx>=21 and gx<=25 and y>=6 and y<=9
end
-- Native front source with a symmetric pitched depth reconstruction.
-- Facade height1.25 matches the native16+4 source rows and existing left unit.
function H.geometry(q,atlas,base,tick,sevii)
 local out={opaque={},cutoutUnder={},cutoutOver={},cutoutKeyed={},nativeWindowTriangles={}}
 local src={};for _,c in ipairs(q.cells)do src[c.x..','..c.y]=c end
 local function uv(mid,ly,a,b,c,d)
  local u0,v0,u1,v1=atlas[ly..'Rect'](mid)
  return {u0+(u1-u0)*a,v0+(v1-v0)*b,u0+(u1-u0)*c,v0+(v1-v0)*d}
 end
 local function emit(pts,uvs,n,layer,palette)
  for _,ix in ipairs{#pts==3 and {1,2,3}or{1,2,3},#pts==4 and {1,3,4}or false}do if ix then
   local a,b,c=pts[ix[1]],pts[ix[2]],pts[ix[3]]
   local x,y,z=b[1]-a[1],b[2]-a[2],b[3]-a[3];local u,v,w=c[1]-a[1],c[2]-a[2],c[3]-a[3]
   if (y*w-z*v)*n[1]+(z*u-x*w)*n[2]+(x*v-y*u)*n[3]<0 then ix[2],ix[3]=ix[3],ix[2]end
   local vs={}
   for _,i in ipairs(ix)do local p,t=pts[i],uvs[i];local vertex={p[1],p[2],p[3],t[1],t[2],n[1],n[2],n[3]};out[layer][#out[layer]+1]=vertex;vs[#vs+1]=vertex end
   if palette and #palette>0 then out.nativeWindowTriangles[#out.nativeWindowTriangles+1]={vertices=vs,glassColors=palette,layer=layer=='cutoutOver'and'over'or'under'}end
  end end
 end
 local function quad(a,b,c,d,r,n,ly,pal)
  emit({a,b,c,d},{{r[1],r[2]},{r[3],r[2]},{r[3],r[4]},{r[1],r[4]}},n,ly,pal)
 end
 local function palette(mid,ly,a,b,c,d)
  if mid==666 then return nil end
  local t=atlas.texels(mid,ly);local out,seen={},{}
  for y=math.floor(b*16),math.ceil(d*16)-1 do for x=math.floor(a*16),math.ceil(c*16)-1 do local v=t[y*16+x+1]
   if v and v>=0 then local r,g,b=math.floor(v/65536)%256,math.floor(v/256)%256,v%256
    if b-g>=16 and b-r>=24 and r<128 and not seen[v]then seen[v]=true;out[#out+1]=v end
   end
  end end
  return out
 end
 local top=base+(sevii and 19/16 or 1.25);local peak=top+1.25
 -- The upper4 native facade pixels retain their OVER alpha; lower16 are UNDER.
 for x=21,25 do
  local upper,lower=src[x..',8'],src[x..',9']
  quad({x,top,10},{x+1,top,10},{x+1,base+1,10},{x,base+1,10},uv(upper.mid,'over',0,sevii and 13/16 or .75,1,1),{0,0,1},'cutoutOver',palette(upper.mid,'over',0,sevii and 13/16 or .75,1,1))
  quad({x,base+1,10},{x+1,base+1,10},{x+1,base,10},{x,base,10},uv(lower.mid,'under',0,0,1,1),{0,0,1},'opaque',palette(lower.mid,'under',0,0,1,1))
 end
 -- Explicit hidden surfaces: use the native plain left wall strip, not new windows.
 -- Native665 interior columns4..7: alternating pale wall stripes, mint base
 -- and horizontal foundation. Exclude left outline0..3 and front frame8+.
 local wall=uv(665,'under',4/16,0,8/16,1)
 quad({21,top,7},{26,top,7},{26,base,7},{21,base,7},wall,{0,0,-1},'opaque')
 for _,x in ipairs{21,26}do
  local n={x==21 and -1 or 1,0,0}
  quad({x,top,7},{x,top,10},{x,base,10},{x,base,7},wall,n,'opaque')
  local sw=uv(650,'over',7.5/16,5.5/16,7.5/16,5.5/16)
  emit({{x,top,7},{x,peak,8.5},{x,top,10}},{{sw[1],sw[2]},{sw[1],sw[2]},{sw[1],sw[2]}},n,'cutoutOver')
 end
 -- Full native roof source6.5..8.75 on front slope; symmetric rear repeats
 -- that guarded roof source. No tree UNDER pixels are copied into the roof.
 for x=21,25 do for sy=6,8 do
  local lo,hi=math.max(sy,6.5),math.min(sy+1,8.75)
  local c=src[x..','..sy];local a,b=(lo-6.5)/2.25,(hi-6.5)/2.25
  local x0,x1=20.8+(x-21)*1.08,20.8+(x-20)*1.08
  local r=uv(c.mid,'over',0,lo-sy,1,hi-sy)
  for _,sg in ipairs{-1,1}do
   local z0,z1=8.5+sg*a*1.7,8.5+sg*b*1.7
   local h0,h1=peak-a*1.25,peak-b*1.25
   local len=math.sqrt(1.7^2+1.25^2);local n={0,1.7/len,sg*1.25/len}
   quad({x0,h0,z0},{x1,h0,z0},{x1,h1,z1},{x0,h1,z1},r,n,'cutoutOver')
  end
 end end
 out.stats={wallRows=1.25,bodyTop=top,roofTop=peak,bounds={21,7,26,10},sourceBounds={21,6,25,9},
  reconstruction='five-by-three footprint; symmetric pitched rear depth and native plain-wall side/rear donors'}
 return out
end

H.expected=expected
return H
