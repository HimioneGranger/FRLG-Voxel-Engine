-- CPU-intermediate envelope helpers. Caller owns the isolated store lifetime.
-- Never accepted as FRPC; canonical Scene GPU phases must still execute.
local F,Geometry=...
local M={MAX_BYTES=48*1024*1024}
local function sha(s)return love.data.encode('string','hex',love.data.hash('sha256',s))end
function M.encode(value,tick)local w=F.writer();w:value(value,tick);return w:result()end
function M.decode(bytes,tick)
 assert(type(bytes)=='string'and #bytes<=M.MAX_BYTES,'CPU byte budget')
 local r=F.reader(bytes);local value=r:value(tick);assert(r:left()==0,'trailing CPU payload');return value
end
function M.sourceKey(sources,retroGrass,voxelTrees)
 -- Full source bytes, not mod version strings. CPU input includes all sampled
 -- native art, grid, border callbacks, labels and native semantic metadata.
 local names={};for name in pairs(sources)do names[#names+1]=name end;table.sort(names)
 local pieces={'fr-cpu-prepare/2',retroGrass and 'retro'or 'base',voxelTrees==true and 'vt1'or 'vt0'}
 for _,name in ipairs(names)do pieces[#pieces+1]=name..':'..sha(sources[name])end
 return sha(table.concat(pieces,'\n'))
end
function M.keyWithSource(snapshotBytes,sourceKey)
 assert(type(sourceKey)=='string'and #sourceKey==64,'frozen source identity')
 return sha('fr-cpu-input/1\n'..sourceKey..'\n'..sha(snapshotBytes))
end
function M.key(snapshotBytes,sources,retroGrass,voxelTrees)return M.keyWithSource(snapshotBytes,M.sourceKey(sources,retroGrass,voxelTrees))end
function M.read(bytes,expectedKey,tick)
 assert(type(expectedKey)=='string'and expectedKey:match('^[a-f0-9]+$')and #expectedKey==64,'CPU identity')
 assert(type(bytes)=='string'and #bytes<=M.MAX_BYTES,'CPU envelope budget')
 assert(bytes:sub(1,7)=='FRCPU1\n','CPU envelope schema')
 assert(bytes:sub(8,71)==expectedKey and bytes:sub(72,72)=='\n','CPU input identity')
 local hash=bytes:sub(73,136);assert(bytes:sub(137,137)=='\n','CPU checksum delimiter')
 local body=bytes:sub(138);assert(sha(body)==hash,'CPU checksum')
 local raw=love.data.decompress('string','lz4',body)
 return Geometry.restore(M.decode(raw,tick),tick)
end
return M
