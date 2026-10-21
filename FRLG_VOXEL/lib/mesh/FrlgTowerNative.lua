local T={}
local expected={
{"FR_ROUTE_10",15,72,-8,16,0,3,0,1,1,"TOWN_PATH"},
{"FR_ROUTE_10",16,72,-8,17,0,3,0,1,1,"TOWN_PATH"},
{"FR_ROUTE_10",17,72,-8,677,0,3,0,0,1,"TOWN_PATH"},
{"FR_ROUTE_10",18,72,-8,678,0,3,0,0,1,"TOWN_PATH"},
{"FR_ROUTE_10",19,72,-8,679,0,3,0,0,1,"TOWN_PATH"},
{"FR_ROUTE_10",20,72,-8,16,0,3,0,1,1,"TOWN_PATH"},
{"FR_ROUTE_10",21,72,-8,17,0,3,0,1,1,"TOWN_PATH"},
{"FR_ROUTE_10",15,73,-7,681,0,3,0,0,1,"TOWN_PATH"},
{"FR_ROUTE_10",16,73,-7,682,0,3,0,0,1,"TOWN_PATH"},
{"FR_ROUTE_10",17,73,-7,683,0,3,0,0,1,"TOWN_PATH"},
{"FR_ROUTE_10",18,73,-7,684,0,3,0,0,1,"TOWN_PATH"},
{"FR_ROUTE_10",19,73,-7,685,0,3,0,0,1,"TOWN_PATH"},
{"FR_ROUTE_10",20,73,-7,686,0,3,0,0,1,"TOWN_PATH"},
{"FR_ROUTE_10",21,73,-7,687,0,3,0,0,1,"TOWN_PATH"},
{"FR_ROUTE_10",15,74,-6,689,7,0,0,1,0,"BUILDING"},
{"FR_ROUTE_10",16,74,-6,690,7,0,0,1,0,"BUILDING"},
{"FR_ROUTE_10",17,74,-6,691,7,0,0,1,0,"BUILDING"},
{"FR_ROUTE_10",18,74,-6,692,7,0,0,1,0,"BUILDING"},
{"FR_ROUTE_10",19,74,-6,693,7,0,0,1,0,"BUILDING"},
{"FR_ROUTE_10",20,74,-6,694,7,0,0,1,0,"BUILDING"},
{"FR_ROUTE_10",21,74,-6,695,7,0,0,1,0,"BUILDING"},
{"FR_ROUTE_10",15,75,-5,697,7,0,0,1,0,"BUILDING"},
{"FR_ROUTE_10",16,75,-5,698,7,0,0,1,0,"BUILDING"},
{"FR_ROUTE_10",17,75,-5,699,7,0,0,1,0,"BUILDING"},
{"FR_ROUTE_10",18,75,-5,700,7,0,0,1,0,"BUILDING"},
{"FR_ROUTE_10",19,75,-5,701,7,0,0,1,0,"BUILDING"},
{"FR_ROUTE_10",20,75,-5,702,7,0,0,1,0,"BUILDING"},
{"FR_ROUTE_10",21,75,-5,703,7,0,0,1,0,"BUILDING"},
{"FR_ROUTE_10",15,76,-4,705,7,0,0,1,0,"BUILDING"},
{"FR_ROUTE_10",16,76,-4,706,7,0,0,1,0,"BUILDING"},
{"FR_ROUTE_10",17,76,-4,707,7,0,0,1,0,"BUILDING"},
{"FR_ROUTE_10",18,76,-4,708,7,0,0,1,0,"BUILDING"},
{"FR_ROUTE_10",19,76,-4,709,7,0,0,1,0,"BUILDING"},
{"FR_ROUTE_10",20,76,-4,710,7,0,0,1,0,"BUILDING"},
{"FR_ROUTE_10",21,76,-4,711,7,0,0,1,0,"BUILDING"},
{"FR_ROUTE_10",15,77,-3,713,7,0,0,1,0,"BUILDING"},
{"FR_ROUTE_10",16,77,-3,714,7,0,0,1,0,"BUILDING"},
{"FR_ROUTE_10",17,77,-3,715,7,0,0,1,0,"BUILDING"},
{"FR_ROUTE_10",18,77,-3,716,7,0,0,1,0,"BUILDING"},
{"FR_ROUTE_10",19,77,-3,717,7,0,0,1,0,"BUILDING"},
{"FR_ROUTE_10",20,77,-3,718,7,0,0,1,0,"BUILDING"},
{"FR_ROUTE_10",21,77,-3,719,7,0,0,1,0,"BUILDING"},
{"FR_ROUTE_10",15,78,-2,688,7,0,0,1,0,"BUILDING"},
{"FR_ROUTE_10",16,78,-2,722,7,0,0,1,0,"BUILDING"},
{"FR_ROUTE_10",17,78,-2,723,7,0,0,1,0,"BUILDING"},
{"FR_ROUTE_10",18,78,-2,723,7,0,0,1,0,"BUILDING"},
{"FR_ROUTE_10",19,78,-2,723,7,0,0,1,0,"BUILDING"},
{"FR_ROUTE_10",20,78,-2,726,7,0,0,1,0,"BUILDING"},
{"FR_ROUTE_10",21,78,-2,696,7,0,0,1,0,"BUILDING"},
{"FR_ROUTE_10",15,79,-1,704,7,0,0,1,0,"BUILDING"},
{"FR_ROUTE_10",16,79,-1,722,7,0,0,1,0,"BUILDING"},
{"FR_ROUTE_10",17,79,-1,723,7,0,0,1,0,"BUILDING"},
{"FR_ROUTE_10",18,79,-1,723,7,0,0,1,0,"BUILDING"},
{"FR_ROUTE_10",19,79,-1,723,7,0,0,1,0,"BUILDING"},
{"FR_ROUTE_10",20,79,-1,726,7,0,0,1,0,"BUILDING"},
{"FR_ROUTE_10",21,79,-1,712,7,0,0,1,0,"BUILDING"},
{"FR_LAVENDER_TOWN",15,0,0,721,7,0,0,1,0,"BUILDING"},
{"FR_LAVENDER_TOWN",16,0,0,722,7,0,0,1,0,"BUILDING"},
{"FR_LAVENDER_TOWN",17,0,0,723,7,0,0,1,0,"BUILDING"},
{"FR_LAVENDER_TOWN",18,0,0,723,7,0,0,1,0,"BUILDING"},
{"FR_LAVENDER_TOWN",19,0,0,723,7,0,0,1,0,"BUILDING"},
{"FR_LAVENDER_TOWN",20,0,0,726,7,0,0,1,0,"BUILDING"},
{"FR_LAVENDER_TOWN",21,0,0,727,7,0,0,1,0,"BUILDING"},
{"FR_LAVENDER_TOWN",15,1,1,729,7,0,0,1,0,"BUILDING"},
{"FR_LAVENDER_TOWN",16,1,1,722,7,0,0,1,0,"BUILDING"},
{"FR_LAVENDER_TOWN",17,1,1,723,7,0,0,1,0,"BUILDING"},
{"FR_LAVENDER_TOWN",18,1,1,723,7,0,0,1,0,"BUILDING"},
{"FR_LAVENDER_TOWN",19,1,1,723,7,0,0,1,0,"BUILDING"},
{"FR_LAVENDER_TOWN",20,1,1,726,7,0,0,1,0,"BUILDING"},
{"FR_LAVENDER_TOWN",21,1,1,735,7,0,0,1,0,"BUILDING"},
{"FR_LAVENDER_TOWN",15,2,2,729,7,0,0,1,0,"BUILDING"},
{"FR_LAVENDER_TOWN",16,2,2,722,7,0,0,1,0,"BUILDING"},
{"FR_LAVENDER_TOWN",17,2,2,723,7,0,0,1,0,"BUILDING"},
{"FR_LAVENDER_TOWN",18,2,2,723,7,0,0,1,0,"BUILDING"},
{"FR_LAVENDER_TOWN",19,2,2,723,7,0,0,1,0,"BUILDING"},
{"FR_LAVENDER_TOWN",20,2,2,726,7,0,0,1,0,"BUILDING"},
{"FR_LAVENDER_TOWN",21,2,2,735,7,0,0,1,0,"BUILDING"},
{"FR_LAVENDER_TOWN",15,3,3,737,7,0,0,1,0,"BUILDING"},
{"FR_LAVENDER_TOWN",16,3,3,738,7,0,0,1,0,"BUILDING"},
{"FR_LAVENDER_TOWN",17,3,3,739,7,0,0,1,0,"BUILDING"},
{"FR_LAVENDER_TOWN",18,3,3,739,7,0,0,1,0,"BUILDING"},
{"FR_LAVENDER_TOWN",19,3,3,739,7,0,0,1,0,"BUILDING"},
{"FR_LAVENDER_TOWN",20,3,3,742,7,0,0,1,0,"BUILDING"},
{"FR_LAVENDER_TOWN",21,3,3,743,7,0,0,1,0,"BUILDING"},
{"FR_LAVENDER_TOWN",15,4,4,745,7,0,0,1,0,"BUILDING"},
{"FR_LAVENDER_TOWN",16,4,4,746,7,0,0,1,0,"BUILDING"},
{"FR_LAVENDER_TOWN",17,4,4,747,7,0,0,1,0,"BUILDING"},
{"FR_LAVENDER_TOWN",18,4,4,747,7,0,0,1,0,"BUILDING"},
{"FR_LAVENDER_TOWN",19,4,4,747,7,0,0,1,0,"BUILDING"},
{"FR_LAVENDER_TOWN",20,4,4,750,7,0,0,1,0,"BUILDING"},
{"FR_LAVENDER_TOWN",21,4,4,751,7,0,0,1,0,"BUILDING"},
{"FR_LAVENDER_TOWN",15,5,5,807,7,0,0,1,0,"BUILDING"},
{"FR_LAVENDER_TOWN",16,5,5,767,7,0,0,1,0,"BUILDING"},
{"FR_LAVENDER_TOWN",17,5,5,824,7,0,0,1,0,"BUILDING"},
{"FR_LAVENDER_TOWN",18,5,5,825,7,0,0,0,0,"BUILDING"},
{"FR_LAVENDER_TOWN",19,5,5,826,7,0,0,1,0,"BUILDING"},
{"FR_LAVENDER_TOWN",20,5,5,767,7,0,0,1,0,"BUILDING"},
{"FR_LAVENDER_TOWN",21,5,5,820,7,0,0,1,0,"BUILDING"},
{"FR_LAVENDER_TOWN",15,6,6,815,7,0,0,1,0,"BUILDING"},
{"FR_LAVENDER_TOWN",16,6,6,775,7,0,0,1,0,"BUILDING"},
{"FR_LAVENDER_TOWN",17,6,6,832,7,0,0,1,0,"BUILDING"},
{"FR_LAVENDER_TOWN",18,6,6,783,113,3,96,1,1,"DOOR"},
{"FR_LAVENDER_TOWN",19,6,6,834,7,0,0,1,0,"BUILDING"},
{"FR_LAVENDER_TOWN",20,6,6,775,7,0,0,1,0,"BUILDING"},
{"FR_LAVENDER_TOWN",21,6,6,821,7,0,0,1,0,"BUILDING"},
}
local art={
[1]={1178158764,87157625},
[16]={1847008231,87157625},
[17]={1919699102,87157625},
[677]={556348727,1026899094},
[678]={1832243108,1461625510},
[679]={556348727,1269963909},
[681]={1919699102,215585521},
[682]={1847008231,913121672},
[683]={1919699102,86111158},
[684]={1847008231,1005983723},
[685]={1919699102,806409619},
[686]={1847008231,1236754845},
[687]={1919699102,435134591},
[688]={1348665812,87157625},
[689]={1337394745,87157625},
[690]={54157178,87157625},
[691]={1209505602,87157625},
[692]={225817182,87157625},
[693]={1619869325,87157625},
[694]={996490659,87157625},
[695]={234616419,87157625},
[696]={2114861973,87157625},
[697]={755392190,87157625},
[698]={468503616,87157625},
[699]={1125394836,87157625},
[700]={1095352572,87157625},
[701]={556310892,87157625},
[702]={694872464,87157625},
[703]={105249819,87157625},
[704]={154863911,87157625},
[705]={1597709702,87157625},
[706]={733896311,87157625},
[707]={106465814,87157625},
[708]={30872798,87157625},
[709]={26569667,87157625},
[710]={1841142813,87157625},
[711]={643529536,87157625},
[712]={1770867902,87157625},
[713]={482459284,87157625},
[714]={1561639817,87157625},
[715]={1706347553,87157625},
[716]={534806083,87157625},
[717]={1075674417,87157625},
[718]={1484851925,87157625},
[719]={748811680,87157625},
[721]={2130368993,87157625},
[722]={1229437112,87157625},
[723]={642318524,87157625},
[726]={1277482956,87157625},
[727]={1620703244,87157625},
[729]={2106002777,87157625},
[735]={2048421861,87157625},
[737]={283048566,87157625},
[738]={1191465372,87157625},
[739]={1891378934,87157625},
[742]={1788618782,87157625},
[743]={1336740424,87157625},
[745]={532464896,87157625},
[746]={725593136,87157625},
[747]={537116516,87157625},
[750]={754909138,87157625},
[751]={2028854514,87157625},
[767]={2138356796,87157625},
[775]={1396585255,87157625},
[783]={1658901628,87157625},
[807]={51379993,87157625},
[815]={1363111119,87157625},
[820]={2028978043,87157625},
[821]={1191262923,87157625},
[824]={779519158,87157625},
[825]={1369142683,1264125499},
[826]={1325034975,87157625},
[832]={1794461588,87157625},
[834]={24906152,87157625},
}
local layers={
[1]={false,0},
[16]={false,0},
[17]={false,0},
[677]={true,0.24609375},
[678]={true,0.625},
[679]={true,0.24609375},
[681]={true,0.234375},
[682]={true,0.9609375},
[683]={true,1},
[684]={true,1},
[685]={true,1},
[686]={true,0.9609375},
[687]={true,0.234375},
[688]={false,0},
[689]={false,0},
[690]={false,0},
[691]={false,0},
[692]={false,0},
[693]={false,0},
[694]={false,0},
[695]={false,0},
[696]={false,0},
[697]={false,0},
[698]={false,0},
[699]={false,0},
[700]={false,0},
[701]={false,0},
[702]={false,0},
[703]={false,0},
[704]={false,0},
[705]={false,0},
[706]={false,0},
[707]={false,0},
[708]={false,0},
[709]={false,0},
[710]={false,0},
[711]={false,0},
[712]={false,0},
[713]={false,0},
[714]={false,0},
[715]={false,0},
[716]={false,0},
[717]={false,0},
[718]={false,0},
[719]={false,0},
[721]={false,0},
[722]={false,0},
[723]={false,0},
[726]={false,0},
[727]={false,0},
[729]={false,0},
[735]={false,0},
[737]={false,0},
[738]={false,0},
[739]={false,0},
[742]={false,0},
[743]={false,0},
[745]={false,0},
[746]={false,0},
[747]={false,0},
[750]={false,0},
[751]={false,0},
[767]={false,0},
[775]={false,0},
[783]={false,0},
[807]={false,0},
[815]={false,0},
[820]={false,0},
[821]={false,0},
[824]={false,0},
[825]={true,1},
[826]={false,0},
[832]={false,0},
[834]={false,0},
}
local function hash(t)
 local h=0
 for i=1,256 do local v=t and t[i]or -1;h=(h*31+(v>=0 and v+2 or 1))%2147483647 end
 return h
end
local terrainExpected={
{12,73,9,0,3,0,1,true,"TOWN_PATH"},
{13,73,8,0,3,0,1,true,"TOWN_PATH"},
{14,73,9,0,3,0,1,true,"TOWN_PATH"},
{15,73,681,0,3,0,0,true,"TOWN_PATH"},
{16,73,682,0,3,0,0,true,"TOWN_PATH"},
{17,73,683,0,3,0,0,true,"TOWN_PATH"},
{18,73,684,0,3,0,0,true,"TOWN_PATH"},
{19,73,685,0,3,0,0,true,"TOWN_PATH"},
{20,73,686,0,3,0,0,true,"TOWN_PATH"},
{21,73,687,0,3,0,0,true,"TOWN_PATH"},
{22,73,112,7,0,0,1,false,"CLIFF"},
{23,73,113,7,0,0,1,false,"CLIFF"},
{12,74,177,163,0,59,1,true,"LEDGE"},
{13,74,1,0,3,0,1,true,"TOWN_PATH"},
{14,74,104,7,0,0,1,false,"BLOCKED"},
{15,74,689,7,0,0,1,false,"BUILDING"},
{16,74,690,7,0,0,1,false,"BUILDING"},
{17,74,691,7,0,0,1,false,"BUILDING"},
{18,74,692,7,0,0,1,false,"BUILDING"},
{19,74,693,7,0,0,1,false,"BUILDING"},
{20,74,694,7,0,0,1,false,"BUILDING"},
{21,74,695,7,0,0,1,false,"BUILDING"},
{22,74,187,7,0,0,1,false,"BLOCKED"},
{23,74,113,7,0,0,1,false,"CLIFF"},
{12,75,16,0,3,0,1,true,"TOWN_PATH"},
{13,75,17,0,3,0,1,true,"TOWN_PATH"},
{14,75,112,7,0,0,1,false,"CLIFF"},
{15,75,697,7,0,0,1,false,"BUILDING"},
{16,75,698,7,0,0,1,false,"BUILDING"},
{17,75,699,7,0,0,1,false,"BUILDING"},
{18,75,700,7,0,0,1,false,"BUILDING"},
{19,75,701,7,0,0,1,false,"BUILDING"},
{20,75,702,7,0,0,1,false,"BUILDING"},
{21,75,703,7,0,0,1,false,"BUILDING"},
{22,75,113,7,0,0,1,false,"CLIFF"},
{23,75,113,7,0,0,1,false,"CLIFF"},
{12,76,8,0,3,0,1,true,"TOWN_PATH"},
{13,76,9,0,3,0,1,true,"TOWN_PATH"},
{14,76,112,7,0,0,1,false,"CLIFF"},
{15,76,705,7,0,0,1,false,"BUILDING"},
{16,76,706,7,0,0,1,false,"BUILDING"},
{17,76,707,7,0,0,1,false,"BUILDING"},
{18,76,708,7,0,0,1,false,"BUILDING"},
{19,76,709,7,0,0,1,false,"BUILDING"},
{20,76,710,7,0,0,1,false,"BUILDING"},
{21,76,711,7,0,0,1,false,"BUILDING"},
{22,76,113,7,0,0,1,false,"CLIFF"},
{23,76,113,7,0,0,1,false,"CLIFF"},
{12,77,16,0,3,0,1,true,"TOWN_PATH"},
{13,77,17,0,3,0,1,true,"TOWN_PATH"},
{14,77,112,7,0,0,1,false,"CLIFF"},
{15,77,713,7,0,0,1,false,"BUILDING"},
{16,77,714,7,0,0,1,false,"BUILDING"},
{17,77,715,7,0,0,1,false,"BUILDING"},
{18,77,716,7,0,0,1,false,"BUILDING"},
{19,77,717,7,0,0,1,false,"BUILDING"},
{20,77,718,7,0,0,1,false,"BUILDING"},
{21,77,719,7,0,0,1,false,"BUILDING"},
{22,77,113,7,0,0,1,false,"CLIFF"},
{23,77,113,7,0,0,1,false,"CLIFF"},
{12,78,8,0,3,0,1,true,"TOWN_PATH"},
{13,78,104,7,0,0,1,false,"BLOCKED"},
{14,78,187,7,0,0,1,false,"BLOCKED"},
{15,78,688,7,0,0,1,false,"BUILDING"},
{16,78,722,7,0,0,1,false,"BUILDING"},
{17,78,723,7,0,0,1,false,"BUILDING"},
{18,78,723,7,0,0,1,false,"BUILDING"},
{19,78,723,7,0,0,1,false,"BUILDING"},
{20,78,726,7,0,0,1,false,"BUILDING"},
{21,78,696,7,0,0,1,false,"BUILDING"},
{22,78,113,7,0,0,1,false,"CLIFF"},
{23,78,113,7,0,0,1,false,"CLIFF"},
{12,79,16,0,3,0,1,true,"TOWN_PATH"},
{13,79,112,7,0,0,1,false,"CLIFF"},
{14,79,107,7,0,0,1,false,"BLOCKED"},
{15,79,704,7,0,0,1,false,"BUILDING"},
{16,79,722,7,0,0,1,false,"BUILDING"},
{17,79,723,7,0,0,1,false,"BUILDING"},
{18,79,723,7,0,0,1,false,"BUILDING"},
{19,79,723,7,0,0,1,false,"BUILDING"},
{20,79,726,7,0,0,1,false,"BUILDING"},
{21,79,712,7,0,0,1,false,"BUILDING"},
{22,79,109,7,0,0,1,false,"BLOCKED"},
{23,79,113,7,0,0,1,false,"CLIFF"},
}
local terrainArt={
[1]={1178158764,87157625,false,0,{0.0626220703125,6.7349137931034482e-05,0.1248779296875,0.034415409482758619,},{}},
[8]={1832243108,87157625,false,0,{0.3751220703125,6.7349137931034482e-05,0.4373779296875,0.034415409482758619,},{}},
[9]={556348727,87157625,false,0,{0.4376220703125,6.7349137931034482e-05,0.4998779296875,0.034415409482758619,},{}},
[16]={1847008231,87157625,false,0,{0.8126220703125,6.7349137931034482e-05,0.8748779296875,0.034415409482758619,},{}},
[17]={1919699102,87157625,false,0,{0.8751220703125,6.7349137931034482e-05,0.9373779296875,0.034415409482758619,},{}},
[104]={1676959548,87157625,false,0,{0.1876220703125,0.17248114224137931,0.2498779296875,0.20682920258620691,},{}},
[107]={344490853,87157625,false,0,{0.3751220703125,0.17248114224137931,0.4373779296875,0.20682920258620691,},{}},
[109]={426694511,87157625,false,0,{0.5001220703125,0.17248114224137931,0.5623779296875,0.20682920258620691,},{}},
[112]={1310232517,87157625,false,0,{0.5626220703125,0.17248114224137931,0.6248779296875,0.20682920258620691,},{}},
[113]={1321427390,87157625,false,0,{0.6251220703125,0.17248114224137931,0.6873779296875,0.20682920258620691,},{}},
[177]={1802195176,87157625,false,0,{0.1876220703125,0.24144665948275862,0.2498779296875,0.27579471982758619,},{}},
[187]={91768754,87157625,false,0,{0.5626220703125,0.24144665948275862,0.6248779296875,0.27579471982758619,},{}},
[681]={1919699102,215585521,true,0.234375,{0.4376220703125,0.62075700431034486,0.4998779296875,0.65510506465517238,},{0.4376220703125,0.62075700431034486,0.4998779296875,0.65510506465517238,}},
[682]={1847008231,913121672,true,0.9609375,{0.5001220703125,0.62075700431034486,0.5623779296875,0.65510506465517238,},{0.5001220703125,0.62075700431034486,0.5623779296875,0.65510506465517238,}},
[683]={1919699102,86111158,true,1,{0.5626220703125,0.62075700431034486,0.6248779296875,0.65510506465517238,},{0.5626220703125,0.62075700431034486,0.6248779296875,0.65510506465517238,}},
[684]={1847008231,1005983723,true,1,{0.6251220703125,0.62075700431034486,0.6873779296875,0.65510506465517238,},{0.6251220703125,0.62075700431034486,0.6873779296875,0.65510506465517238,}},
[685]={1919699102,806409619,true,1,{0.6876220703125,0.62075700431034486,0.7498779296875,0.65510506465517238,},{0.6876220703125,0.62075700431034486,0.7498779296875,0.65510506465517238,}},
[686]={1847008231,1236754845,true,0.9609375,{0.7501220703125,0.62075700431034486,0.8123779296875,0.65510506465517238,},{0.7501220703125,0.62075700431034486,0.8123779296875,0.65510506465517238,}},
[687]={1919699102,435134591,true,0.234375,{0.8126220703125,0.62075700431034486,0.8748779296875,0.65510506465517238,},{0.8126220703125,0.62075700431034486,0.8748779296875,0.65510506465517238,}},
[688]={1348665812,87157625,false,0,{0.8751220703125,0.62075700431034486,0.9373779296875,0.65510506465517238,},{}},
[689]={1337394745,87157625,false,0,{0.9376220703125,0.62075700431034486,0.9998779296875,0.65510506465517238,},{}},
[690]={54157178,87157625,false,0,{0.0001220703125,0.65523976293103448,0.0623779296875,0.6895878232758621,},{}},
[691]={1209505602,87157625,false,0,{0.0626220703125,0.65523976293103448,0.1248779296875,0.6895878232758621,},{}},
[692]={225817182,87157625,false,0,{0.1251220703125,0.65523976293103448,0.1873779296875,0.6895878232758621,},{}},
[693]={1619869325,87157625,false,0,{0.1876220703125,0.65523976293103448,0.2498779296875,0.6895878232758621,},{}},
[694]={996490659,87157625,false,0,{0.2501220703125,0.65523976293103448,0.3123779296875,0.6895878232758621,},{}},
[695]={234616419,87157625,false,0,{0.3126220703125,0.65523976293103448,0.3748779296875,0.6895878232758621,},{}},
[696]={2114861973,87157625,false,0,{0.3751220703125,0.65523976293103448,0.4373779296875,0.6895878232758621,},{}},
[697]={755392190,87157625,false,0,{0.4376220703125,0.65523976293103448,0.4998779296875,0.6895878232758621,},{}},
[698]={468503616,87157625,false,0,{0.5001220703125,0.65523976293103448,0.5623779296875,0.6895878232758621,},{}},
[699]={1125394836,87157625,false,0,{0.5626220703125,0.65523976293103448,0.6248779296875,0.6895878232758621,},{}},
[700]={1095352572,87157625,false,0,{0.6251220703125,0.65523976293103448,0.6873779296875,0.6895878232758621,},{}},
[701]={556310892,87157625,false,0,{0.6876220703125,0.65523976293103448,0.7498779296875,0.6895878232758621,},{}},
[702]={694872464,87157625,false,0,{0.7501220703125,0.65523976293103448,0.8123779296875,0.6895878232758621,},{}},
[703]={105249819,87157625,false,0,{0.8126220703125,0.65523976293103448,0.8748779296875,0.6895878232758621,},{}},
[704]={154863911,87157625,false,0,{0.8751220703125,0.65523976293103448,0.9373779296875,0.6895878232758621,},{}},
[705]={1597709702,87157625,false,0,{0.9376220703125,0.65523976293103448,0.9998779296875,0.6895878232758621,},{}},
[706]={733896311,87157625,false,0,{0.0001220703125,0.68972252155172409,0.0623779296875,0.72407058189655171,},{}},
[707]={106465814,87157625,false,0,{0.0626220703125,0.68972252155172409,0.1248779296875,0.72407058189655171,},{}},
[708]={30872798,87157625,false,0,{0.1251220703125,0.68972252155172409,0.1873779296875,0.72407058189655171,},{}},
[709]={26569667,87157625,false,0,{0.1876220703125,0.68972252155172409,0.2498779296875,0.72407058189655171,},{}},
[710]={1841142813,87157625,false,0,{0.2501220703125,0.68972252155172409,0.3123779296875,0.72407058189655171,},{}},
[711]={643529536,87157625,false,0,{0.3126220703125,0.68972252155172409,0.3748779296875,0.72407058189655171,},{}},
[712]={1770867902,87157625,false,0,{0.3751220703125,0.68972252155172409,0.4373779296875,0.72407058189655171,},{}},
[713]={482459284,87157625,false,0,{0.4376220703125,0.68972252155172409,0.4998779296875,0.72407058189655171,},{}},
[714]={1561639817,87157625,false,0,{0.5001220703125,0.68972252155172409,0.5623779296875,0.72407058189655171,},{}},
[715]={1706347553,87157625,false,0,{0.5626220703125,0.68972252155172409,0.6248779296875,0.72407058189655171,},{}},
[716]={534806083,87157625,false,0,{0.6251220703125,0.68972252155172409,0.6873779296875,0.72407058189655171,},{}},
[717]={1075674417,87157625,false,0,{0.6876220703125,0.68972252155172409,0.7498779296875,0.72407058189655171,},{}},
[718]={1484851925,87157625,false,0,{0.7501220703125,0.68972252155172409,0.8123779296875,0.72407058189655171,},{}},
[719]={748811680,87157625,false,0,{0.8126220703125,0.68972252155172409,0.8748779296875,0.72407058189655171,},{}},
[722]={1229437112,87157625,false,0,{0.0001220703125,0.72420528017241381,0.0623779296875,0.75855334051724133,},{}},
[723]={642318524,87157625,false,0,{0.0626220703125,0.72420528017241381,0.1248779296875,0.75855334051724133,},{}},
[726]={1277482956,87157625,false,0,{0.2501220703125,0.72420528017241381,0.3123779296875,0.75855334051724133,},{}},
}
local function terrainGuard(input,atlas,q,tick)
 if type(q.terrainContext)~="table"or #q.terrainContext~=#terrainExpected then return false end
 for i,e in ipairs(terrainExpected)do
  local c=q.terrainContext[i]
  if not c or c.sourceMap~="FR_ROUTE_10"or c.sourceX~=e[1]or c.sourceY~=e[2]or c.x~=e[1]or c.y~=e[2]-80
   or c.mid~=e[3]or c.collision~=e[4]or c.elevation~=e[5]or c.behavior~=e[6]or c.layerType~=e[7]
   or c.walkable~=e[8]or c.category~=e[9]then return false end
  if input.mapId=="FR_ROUTE_10"then
   local n=input.cellAt(c.sourceX,c.sourceY)
   if not n then return false end
   for _,k in ipairs{"mid","collision","elevation","behavior","layerType","walkable","category"}do if n[k]~=c[k]then return false end end
  end
 end
 for mid,e in pairs(terrainArt)do
  if hash(atlas.texels(mid,"under"))~=e[1]or hash(atlas.texels(mid,"over"))~=e[2]
   or atlas.hasOver(mid)~=e[3]or atlas.overCoverage(mid)~=e[4]then return false end
  for i,fn in ipairs{atlas.underRect,atlas.overRect}do
   local uv={fn(mid)};local pin=e[i+4]
   if #uv~=#pin then return false end
   for j,v in ipairs(pin)do if uv[j]~=v then return false end end
  end
  if tick then tick()end
 end
 return true
end
function T.guard(input,atlas,tick)
 local q=input.connectedBuildingSource
 if input.isBorder or(input.mapId~="FR_LAVENDER_TOWN"and input.mapId~="FR_ROUTE_10")
  or input.width~=24 or input.height~=(input.mapId=="FR_ROUTE_10"and 80 or 20)
  or input.pair~="general__rom_082d4b0c"or type(q)~="table"or q.name~="pokemon-tower-connected-native"
  or q.owner~="FR_LAVENDER_TOWN"or q.pair~=input.pair or q.mapId~=input.mapId
  or q.ownerOffsetY~=(input.mapId=="FR_ROUTE_10"and 80 or 0)
  or q.minX~=15 or q.maxX~=21 or q.minY~=-8 or q.maxY~=6
  or type(q.cells)~="table"or #q.cells~=#expected or type(atlas.texels)~="function"then return nil end
 local g=q.groundDonor
 if not g or g.sourceMap~="FR_ROUTE_10"or g.sourceX~=18 or g.sourceY~=71
  or g.mid~=1 or g.collision~=0 or g.elevation~=3 or g.behavior~=0
  or g.layerType~=1 or g.walkable~=true or g.category~="TOWN_PATH"then return nil end
 for i,e in ipairs(expected)do
  local c=q.cells[i]
  if not c or c.sourceMap~=e[1]or c.sourceX~=e[2]or c.sourceY~=e[3]
   or c.x~=e[2]or c.y~=e[4]or c.mid~=e[5]or c.collision~=e[6]or c.elevation~=e[7]
   or c.behavior~=(e[8]~=-1 and e[8]or nil)or c.layerType~=e[9]
   or c.walkable~=(e[10]==1)or c.category~=e[11]then return nil end
  if e[1]==input.mapId then
   local current=input.cellAt(e[2],e[3])
   if not current or current.mid~=c.mid or current.collision~=c.collision
    or current.elevation~=c.elevation or current.behavior~=c.behavior
    or current.layerType~=c.layerType or current.walkable~=c.walkable
    or current.category~=c.category then return nil end
  end
 end
 if type(atlas.underRect)~="function"or type(atlas.overRect)~="function"
  or type(atlas.hasOver)~="function"or type(atlas.overCoverage)~="function"then return nil end
 for mid,pins in pairs(art)do
  local u0,v0,u1,v1=atlas.underRect(mid)
  if not(u0 and v0 and u1 and v1)or u0~=u0 or v0~=v0 or u1~=u1 or v1~=v1
   or u0<0 or v0<0 or u1>1 or v1>1 then return nil end
  local ls=layers[mid];local o=atlas.overRect(mid)
  if (o~=nil)~=ls[1]or atlas.hasOver(mid)~=ls[1]or atlas.overCoverage(mid)~=ls[2]then return nil end
  if hash(atlas.texels(mid,"under"))~=pins[1]or hash(atlas.texels(mid,"over"))~=pins[2]then return nil end
  if tick then tick()end
 end
 if not terrainGuard(input,atlas,q,tick)then return nil end
 return q
end
-- Isolated shape trial. Source art is used directly on facade courses;
-- curved roof and spire use exact native single-texel swatches. The rear
-- footprint and repeated side courses are documented symmetric reconstruction.
function T.emit(q,atlas,base,emit,tick)
 local source={};for _,c in ipairs(q.cells)do source[c.x..","..c.y]=c end
 local function rect(mid,layer,a,b,c,d)
  local fn=layer=="over"and atlas.overRect or atlas.underRect
  local u0,v0,u1,v1=fn(mid);assert(u0 and v0 and u1 and v1,'missing native UV')
  return {u0+(u1-u0)*a,v0+(v1-v0)*b,u0+(u1-u0)*c,v0+(v1-v0)*d}
 end
 local function pixel(mid,x,y,layer)return rect(mid,layer,(x+.5)/16,(y+.5)/16,(x+.5)/16,(y+.5)/16)end
 local greens={pixel(677,15,9,"over"),pixel(682,13,2,"over"),pixel(678,7,0,"over"),pixel(677,15,10,"over")}
 local white=pixel(678,6,2,"over");local pale=pixel(678,7,4,"over");local dark=pixel(677,15,15,"over")
 local function quad(a,b,c,d,uv,n,layer,palette)emit(a,b,c,d,uv,n,layer or"opaque",palette)end
 local function glassPalette(src,ua,ub,sy0)
  if src.category=="DOOR"or src.y>=5 then return nil end
  local tex=atlas.texels(src.mid,"under");local over=src.layerType~=1 and atlas.texels(src.mid,"over")or nil
  local palette,seen={},{}
  for y=math.floor(sy0*16),15 do for x=math.floor(ua*16),math.ceil(ub*16)-1 do
   local i=y*16+x+1;local v=tex and tex[i]
   if v and v>=0 and not(over and over[i]and over[i]>=0)then
    local r,g,b=math.floor(v/65536)%256,math.floor(v/256)%256,v%256
    -- Tower glass is the native dark slate-blue, unlike ordinary bright
    -- blue house glass. Publish only exact source colours, never the frame.
    if b-g>=16 and b-r>=24 and g>=r and not seen[v]then seen[v]=true;palette[#palette+1]=v end
   end
  end end
  return #palette>0 and palette or nil
 end
 local top=base+9.25
 -- Counterclockwise octagon in plan: 5-wide major faces and native 1x1
 -- clipped corners. Body source rows77py12..15 +78..Lavender6 =9.25.
 local ring={{16,7},{21,7},{22,6},{22,1},{21,0},{16,0},{15,1},{15,6}}
 for face=1,8 do
  local a,b=ring[face],ring[face%8+1]
  local dx,dz=b[1]-a[1],b[2]-a[2];local len=math.sqrt(dx*dx+dz*dz)
  local n={-dz/len,0,dx/len}
  local cols=face%2==1 and 5 or 1
  for k=0,cols-1 do
   local x0,z0=a[1]+dx*k/cols,a[2]+dz*k/cols
   local x1,z1=a[1]+dx*(k+1)/cols,a[2]+dz*(k+1)/cols
   local sx=face==1 and(16+k)or(face==2 and 21 or(face==8 and 15 or 16+k))
   for row=-3,6 do
    if tick then tick()end
    local sy0=row==-3 and .75 or 0
    local lo=base+6-row;local hi=lo+1-sy0
    local emitCourse=quad
    local function quad(a,b,c,d,uv,normal,layer,palette)
     if row==3 then
      -- The bottom four pixels are horizontal base trim, not another
      -- projected corner. Separate them from the window course above.
      local boundary=lo+4/16
      local cut=uv[2]+(uv[4]-uv[2])*12/16
      emitCourse(a,b,{c[1],boundary,c[3]},{d[1],boundary,d[3]},
       {uv[1],uv[2],uv[3],cut},normal,layer,palette)
      local donor=assert(source["18,3"],'missing native lower trim')
      emitCourse({a[1],boundary,a[3]},{b[1],boundary,b[3]},c,d,
       rect(donor.mid,"under",8.5/16,12/16,8.5/16,1),normal)
     elseif row==4 then
      -- Straight central front course carries the same native bands around
      -- every major wall and bevel. Sprite-edge diagonal offsets are omitted.
      local donor=assert(source["18,4"],'missing native lower fascia')
      emitCourse(a,b,c,d,rect(donor.mid,"under",8.5/16,0,8.5/16,1),normal)
     else emitCourse(a,b,c,d,uv,normal,layer,palette)end
    end
    local src=source[sx..","..row]
    -- The source's only doorway stays on the front. Side/back bottom
    -- courses use its native solid base strip, never duplicate the door.
    if face~=1 and row>=5 then src=source["15,"..row]end
    assert(src,'missing Tower facade source')
    local ua,ub=0,1
    if face%2==0 then
     -- One complete native window column, centered on the bevel. Its
     -- eight-pixel pane crosses the original metatile boundary: column16
     -- pixels8..15 plus column17 pixels0..7. Preserve the two native halves
     -- instead of repeating a tile (two half-windows) or using a solid post.
     for half=0,1 do
      local donor=assert(source[(16+half)..","..row],'missing native Tower corner window')
      local u0,u1=half==0 and .5 or 0,half==0 and 1 or .5
      local ax,az=x0+(x1-x0)*half/2,z0+(z1-z0)*half/2
      local bx,bz=x0+(x1-x0)*(half+1)/2,z0+(z1-z0)*(half+1)/2
      quad({ax,hi,az},{bx,hi,bz},{bx,lo,bz},{ax,lo,az},
       rect(donor.mid,"under",u0,sy0,u1,1),n,nil,glassPalette(donor,u0,u1,sy0))
     end
    elseif face~=1 and row>=5 then ua,ub=.75,1 end
    if face%2==1 then
    if row>=-2 and row<=3 and(k==0 or k==4)then
     -- Outer three native pixels encode the original oblique corner return.
     -- The physical bevel already owns that window column. Keep the main
     -- wall's window art and replace only its baked return with adjacent trim.
     local edge=k==0 and 3/16 or 13/16
     for part=0,1 do
      local ta,tb=part==0 and 0 or edge,part==0 and edge or 1
      local patch=(k==0 and part==0)or(k==4 and part==1)
      local u0,u1=ta,tb
      if patch then u0=(k==0 and 3.5 or 12.5)/16;u1=u0 end
      local ax,az=x0+(x1-x0)*ta,z0+(z1-z0)*ta
      local bx,bz=x0+(x1-x0)*tb,z0+(z1-z0)*tb
      quad({ax,hi,az},{bx,hi,bz},{bx,lo,bz},{ax,lo,az},
       rect(src.mid,"under",u0,sy0,u1,1),n,nil,not patch and glassPalette(src,u0,u1,sy0)or nil)
     end
    else
    local uv=rect(src.mid,"under",ua,sy0,ub,1)
    quad({x0,hi,z0},{x1,hi,z1},{x1,lo,z1},{x0,lo,z0},uv,n,nil,glassPalette(src,ua,ub,sy0))
    if face==1 and src.layerType~=1 and atlas.hasOver(src.mid)then
     local over=rect(src.mid,"over",ua,sy0,ub,1)
     local e=.002
     quad({x0+n[1]*e,hi,z0+n[3]*e},{x1+n[1]*e,hi,z1+n[3]*e},
      {x1+n[1]*e,lo,z1+n[3]*e},{x0+n[1]*e,lo,z0+n[3]*e},over,n,"cutoutOver")
    end
    end -- native main-face edge repair / unchanged course
    end -- major faces; bevel window halves emitted above
   end
  end
 end
 -- Native octagonal roof rim: a solid projecting cornice, pale vertical
 -- fascia, white upper bevel and an inset deck carrying the green dome.
 local cx,cz=18.5,3.5
 local rimBottom,rimShoulder,roofDeck=top,top+6/16,top+8/16
 local rimOuter={};local outerScale=(3.5+2/16)/3.5
 local rimFace=pixel(714,0,0,"under")
 for i,a in ipairs(ring)do rimOuter[i]={cx+(a[1]-cx)*outerScale,cz+(a[2]-cz)*outerScale}end
 for i=1,8 do
  local a,b=rimOuter[i],rimOuter[i%8+1]
  local wa,wb=ring[i],ring[i%8+1]
  local dx,dz=b[1]-a[1],b[2]-a[2];local len=math.sqrt(dx*dx+dz*dz)
  local n={-dz/len,0,dx/len}
  quad({wa[1],rimBottom,wa[2]},{wb[1],rimBottom,wb[2]},
   {b[1],rimBottom,b[2]},{a[1],rimBottom,a[2]},rimFace,{0,-1,0})
  quad({a[1],rimBottom,a[2]},{b[1],rimBottom,b[2]},
   {b[1],rimShoulder-1/16,b[2]},{a[1],rimShoulder-1/16,a[2]},rimFace,n)
  quad({a[1],rimShoulder-1/16,a[2]},{b[1],rimShoulder-1/16,b[2]},
   {b[1],rimShoulder,b[2]},{a[1],rimShoulder,a[2]},white,n,"cutoutOver")
  local ia,ib={cx+(a[1]-cx)*.86,cz+(a[2]-cz)*.86},{cx+(b[1]-cx)*.86,cz+(b[2]-cz)*.86}
  local inset=math.sqrt((ib[1]-b[1])^2+(ib[2]-b[2])^2)
  local slope=(roofDeck-rimShoulder)/inset;local norm=math.sqrt(1+slope*slope)
  quad({a[1],rimShoulder,a[2]},{b[1],rimShoulder,b[2]},
   {ib[1],roofDeck,ib[2]},{ia[1],roofDeck,ia[2]},white,{n[1]*slope/norm,1/norm,n[3]*slope/norm},"cutoutOver")
  quad({ia[1],roofDeck,ia[2]},{ib[1],roofDeck,ib[2]},
   {cx,roofDeck,cz},{cx,roofDeck,cz},white,{0,1,0},"cutoutOver")
 end
 local radius,rise=2.95,3.1
 for lat=0,7 do
  local la,lb=math.pi*.5*lat/8,math.pi*.5*(lat+1)/8
  local ca,cb=math.cos(la),math.cos(lb)
  local ya,yb=roofDeck+rise*math.sin(la),roofDeck+rise*math.sin(lb)
  local uv=greens[math.min(4,1+math.floor(lat/2))]
  for seg=0,15 do
   local a,b=2*math.pi*seg/16,2*math.pi*(seg+1)/16
   local p1={cx+radius*ca*math.cos(a),ya,cz+radius*ca*math.sin(a)}
   local p2={cx+radius*ca*math.cos(b),ya,cz+radius*ca*math.sin(b)}
   local p3={cx+radius*cb*math.cos(b),yb,cz+radius*cb*math.sin(b)}
   local p4={cx+radius*cb*math.cos(a),yb,cz+radius*cb*math.sin(a)}
   local mid=(a+b)/2;local lm=(la+lb)/2
   quad(p1,p2,p3,p4,uv,{math.cos(lm)*math.cos(mid),math.sin(lm),math.cos(lm)*math.sin(mid)},"cutoutOver")
  end
 end
 local poleBase=roofDeck+rise
 local profile={{.43,poleBase-.08},{.36,poleBase+.1},{.2,poleBase+.22},{.12,poleBase+.32},{.12,poleBase+1.35},{.06,poleBase+1.43}}
 for k=1,#profile-1 do for seg=0,7 do
  local a,b=2*math.pi*seg/8,2*math.pi*(seg+1)/8;local p,q=profile[k],profile[k+1]
  quad({cx+p[1]*math.cos(a),p[2],cz+p[1]*math.sin(a)},{cx+p[1]*math.cos(b),p[2],cz+p[1]*math.sin(b)},
   {cx+q[1]*math.cos(b),q[2],cz+q[1]*math.sin(b)},{cx+q[1]*math.cos(a),q[2],cz+q[1]*math.sin(a)},
   k==1 and dark or(k==3 and pale or white),{math.cos((a+b)/2),0,math.sin((a+b)/2)},"cutoutOver")
 end end
 for seg=0,7 do
  local a,b=2*math.pi*seg/8,2*math.pi*(seg+1)/8
  local cap=profile[#profile]
  quad({cx+cap[1]*math.cos(a),cap[2],cz+cap[1]*math.sin(a)},
   {cx+cap[1]*math.cos(b),cap[2],cz+cap[1]*math.sin(b)},
   {cx,cap[2],cz},{cx,cap[2],cz},white,{0,1,0},"cutoutOver")
 end
 return {wallRows=9.25,bodyTop=top,roofRimBottom=rimBottom,roofRimShoulder=rimShoulder,roofDeck=roofDeck,domeTop=poleBase,spireTop=poleBase+1.43,
  bounds={15,0,22,7},nativeSourceRows={-8,6},reconstruction="symmetric octagonal footprint and side/back native facade donors"}
end
function T.geometry(q,atlas,base,tick)
 local out={opaque={},cutoutUnder={},cutoutOver={},cutoutKeyed={},nativeWindowTriangles={}}
 local function emit(a,b,c,d,uv,n,layer,palette)
  local pts={a,b,c,d};local uvs={{uv[1],uv[2]},{uv[3],uv[2]},{uv[3],uv[4]},{uv[1],uv[4]}}
  for _,ids in ipairs{{1,2,3},{1,3,4}}do
   local p,r,t=pts[ids[1]],pts[ids[2]],pts[ids[3]]
   local ax,ay,az=r[1]-p[1],r[2]-p[2],r[3]-p[3]
   local bx,by,bz=t[1]-p[1],t[2]-p[2],t[3]-p[3]
   local nx,ny,nz=ay*bz-az*by,az*bx-ax*bz,ax*by-ay*bx
   if nx*nx+ny*ny+nz*nz>1e-18 then
    if nx*n[1]+ny*n[2]+nz*n[3]<0 then ids[2],ids[3]=ids[3],ids[2]end
    local first=#out[layer]+1
    for _,i in ipairs(ids)do local v,t=pts[i],uvs[i];out[layer][#out[layer]+1]={v[1],v[2],v[3],t[1],t[2],n[1],n[2],n[3]}end
    if palette then out.nativeWindowTriangles[#out.nativeWindowTriangles+1]={vertices={out[layer][first],out[layer][first+1],out[layer][first+2]},glassColors=palette,layer=layer=="cutoutOver"and"over"or"under"}end
   end
  end
 end
 out.stats=T.emit(q,atlas,base,emit,tick)
 return out
end
function T.claims(q,mapId,x,y)
 if mapId~="FR_LAVENDER_TOWN"and mapId~="FR_ROUTE_10"then return false end
 local z=mapId=="FR_ROUTE_10"and y-80 or y
 if x<15 or x>21 or z< -8 or z>6 then return false end
 return z~=-8 or(x>=17 and x<=19)
end
T.expected=expected
return T
