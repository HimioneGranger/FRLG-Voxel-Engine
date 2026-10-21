-- Run from the repository root: luajit tests/test_local_loader.lua
local root='FRLG_VOXEL/'
local V,cache={},{}
function V.has(n)local f=io.open(root..n,'rb');if f then f:close();return true end;return false end
function V.require(n)
 if cache[n]~=nil then return cache[n]end
 local f=assert(loadfile(root..'lib/'..n..'.lua'))
 local env=setmetatable({require=function(name)error('Unexpected external module '..name)end},{__index=_G})
 setfenv(f,env);local value=f(V);if value==nil then value=false end
 cache[n]=value;return value
end
local P=V.require('mesh/FrlgBuildingProfiles')
for _,name in ipairs{'match','ownership','connected','terrain'}do assert(type(P[name])=='function',name)end
assert(P.match({mapId='unrecognized',width=1,height=1},{},{})==nil)
local M=V.require('mesh/FrlgMesher');assert(type(M.build)=='function')
print('PASS mod-local building profile and mesher loading with external mods absent')
