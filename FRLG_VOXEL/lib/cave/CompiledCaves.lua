-- Accepted FireRed cave geometry. No source maps, artwork or ROM bytes.
-- All IO/graphics is injected by the engine mod; unsupported sources defer.
local M={VERSION='firered-accepted-caves/1'}
local floor,min,max,sqrt=math.floor,math.min,math.max,math.sqrt
local function byte(n)return string.char(n%256)end
local function rawCell(c)
 if not c or type(c.mid)~='number' or type(c.elevation)~='number' or type(c.collision)~='number' or type(c.behavior)~='number' then return nil end
 if c.mid<0 or c.mid>1023 or c.elevation<0 or c.elevation>15 or c.collision<0 or c.collision>255 then return nil end
 -- Host import exposes transformed COLL_* instead of original two-bit collision.
 -- Keep that host byte in the separate exact observable-source SHA guard.
 -- The query loader's raw identity is adapter-local mid/elevation only.
 return c.mid+c.elevation*4096
end
function M.sourceFingerprint(input,deps)
 local rows={}
 for y=0,input.height-1 do
  for x=0,input.width-1 do
   local c=input.cellAt(x,y);local raw=rawCell(c)
   if not raw then return nil,'incomplete source cell' end
   rows[#rows+1]=byte(c.mid)..byte(floor(c.mid/256))..byte(c.elevation)..byte(c.behavior)..byte(c.collision)
  end
 end
 return deps.sha256(table.concat(rows))
end
local function pixels(atlas,mid)
 local under,over=atlas.texels(mid,'under'),atlas.texels(mid,'over')
 if not under or #under~=256 then return nil end
 local rgba={}
 for i=1,256 do
  local rgb=over and over[i] and over[i]>=0 and over[i] or under[i]
  if type(rgb)~='number' or rgb<0 then return nil end
  rgba[i]=string.char(floor(rgb/65536)%256,floor(rgb/256)%256,rgb%256,255)
 end
 return table.concat(rgba)
end
local function checked(deps,meta)
 local packed=assert(deps.read(meta.file),'missing cave payload '..meta.file)
 assert(deps.sha256(packed)==meta.sha256,'cave payload hash mismatch')
 return assert(deps.inflate(packed),'invalid compressed cave payload')
end
local function decoder(deps,s)
 local pos=5
 local function read(fmt)local v;v,pos=deps.unpack(fmt,s,pos);return v end
 assert(s:sub(1,4)=='CAV1','invalid cave mesh schema')
 local nv,nt=read('<I4'),read('<I4');local verts={}
 for i=1,nv do
  verts[i]={read('<d'),read('<d'),read('<d'),read('<d'),read('<d'),read('<I4')}
  if deps.yieldSafe and i%256==0 then deps.yieldSafe() end
 end
 return read,verts,nt,function()assert(pos==#s+1,'extra or truncated cave geometry bytes')end
end
function M.build(input,deps)
 if input.kind~='cave' or input.isBorder or type(input.mapId)~='string' or input.mapId:sub(1,3)~='FR_' then return nil,'unsupported cave mode' end
 if input.caveMode and input.caveMode~='accepted' then return nil,'unsupported cave mode' end
 if not input.atlas or type(input.atlas.texels)~='function' then return nil,'source artwork unavailable' end
 local candidates={}
 for _,v in ipairs(deps.index)do if v.w==input.width and v.h==input.height then candidates[#candidates+1]=v end end
 if #candidates==0 then return nil,'no accepted dimensions' end
 local fingerprint,reason=M.sourceFingerprint(input,deps)
 if not fingerprint then return nil,reason end
 local entry
 for _,v in ipairs(candidates)do if v.hostSourceSHA256==fingerprint then entry=v;break end end
 if not entry then return nil,'changed or unsupported native source' end
 -- Verify every donor, including fixture donors not visible in the map.
 -- A live atlas can freely relocate its slots. Geometry uses its own compact
 -- original donor placements, constructed in memory only from verified pixels.
 local donors={}
 for i,d in ipairs(entry.donors)do
  if d.required then
  local rgba=pixels(input.atlas,d.mid)
  local observed=rgba and deps.sha256(rgba);local allowed=observed==d.sha256
  for _,digest in ipairs(d.allowedSHA256 or {})do if observed==digest then allowed=true end end
  if not rgba or not allowed then return nil,'changed or missing native artwork '..tostring(d.mid) end
  donors[#donors+1]={x=d.x,y=d.y,rgba=rgba}
  if deps.yieldSafe and i%32==0 then deps.yieldSafe() end
  end
 end
 local queryPacked=assert(deps.read(entry.queries.file),'missing cave query payload')
 assert(deps.sha256(queryPacked)==entry.queries.sha256,'cave query payload hash mismatch')
 assert(entry.queries.codec=='CBQ1-segmented/1','unsupported cave query codec')
 local manifest=deps.QueryCodec.decode(queryPacked,deps)
 local cells,raw,behavior={},{},{}
 for y=0,input.height-1 do for x=0,input.width-1 do
  local c=input.cellAt(x,y);local k=y*input.width+x+1
  raw[k]=rawCell(c);behavior[k]=c.behavior;cells[k]={x=x,y=y,raw=raw[k],behavior=c.behavior}
 end end
 local mat={w=input.width,h=input.height,layout=entry.layout,cells=cells}
 -- Explicit local acceptance is distinct from the compiler's provisional
 -- generation gate. No compiler data or reviewed query is rewritten.
 local compiled={ready=true,identity={w=entry.w,h=entry.h,layout=entry.layout,raw=raw,behavior=behavior},manifest=manifest,mesh={units='native-pixels',tris={}}}
 local _,queryStats,q=deps.CompiledCave.load(compiled,mat,{allowDraft=true,yieldSafe=deps.yieldSafe})
 assert(queryStats.unknownCells==0,'accepted cave query is incomplete')
 local read,verts,nt,finish=decoder(deps,checked(deps,entry.mesh))
 local opaque,ao={},{};local bounds={minX=math.huge,minY=math.huge,minZ=math.huge,maxX=-math.huge,maxY=-math.huge,maxZ=-math.huge}
 for i=1,nt do
  local a,b,c=verts[read('<I4')],verts[read('<I4')],verts[read('<I4')];local shade=read('<d')
  local ux,uy,uz=b[1]-a[1],b[2]-a[2],b[3]-a[3]
  local vx,vy,vz=c[1]-a[1],c[2]-a[2],c[3]-a[3]
  local nx,ny,nz=uy*vz-uz*vy,uz*vx-ux*vz,ux*vy-uy*vx;local len=sqrt(nx*nx+ny*ny+nz*nz)
  if len>1e-12 then nx,ny,nz=nx/len,ny/len,nz/len else nx,ny,nz=0,1,0 end
  for _,v in ipairs{a,b,c}do
   local d=entry.donors[v[6]];assert(d,'invalid cave texture donor')
   local x,y,z=v[1]/16,v[2]/16,v[3]/16
   opaque[#opaque+1]={x,y,z,(d.x+v[4])/entry.textureWidth,(d.y+v[5])/entry.textureHeight,nx,ny,nz}
   ao[#ao+1]=shade
   bounds.minX,bounds.minY,bounds.minZ=min(bounds.minX,x),min(bounds.minY,y),min(bounds.minZ,z)
   bounds.maxX,bounds.maxY,bounds.maxZ=max(bounds.maxX,x),max(bounds.maxY,y),max(bounds.maxZ,z)
  end
  if deps.yieldSafe and i%4096==0 then deps.yieldSafe() end
 end
 finish()
 local image=assert(deps.makeAtlas(entry.textureWidth,entry.textureHeight,donors),'cave atlas upload failed')
 return {opaque=opaque,cutoutUnder={},cutoutOver={},cutoutKeyed={},southWalls={},treeOccluders={},signFaces={},
  ao={opaque=ao},heightAt=q.surfaceAt,bounds=bounds,compiledCaveQuery=q,compiledCaveImage=image,compiledCaveAnimation={donors=entry.donors},
  stats={tris=nt,kind='cave',cave={accepted=entry.id,canonical=entry.canonical,sourceFingerprint=fingerprint,query=queryStats,note=entry.note},lists={opaque=nt,cutoutUnder=0,cutoutOver=0,cutoutKeyed=0,southWalls=0}}},entry.id
end
return M
