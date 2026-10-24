-- General-only bridge from the approved authoring core to native atlas stamps.
-- Geometry is regenerated from the profile. No saved mesh or preview is loaded.
local V=...
local Compiler=V.require('mesh/FrlgFoliageCompiler')
local Profile=V.require('mesh/FrlgGeneralFoliage')
local M={VERSION='frlg-compiled-foliage/1'}
local floor=math.floor
local nativeCache=setmetatable({},{__mode='k'})

local function rect(atlas,address)
 local a,b,c,d
 if address.layer=='over' then a,b,c,d=atlas.overRect(address.metatile)
 else a,b,c,d=atlas.underRect(address.metatile) end
 return type(a)=='table'and a or assert(d and{a,b,c,d},'missing native foliage atlas rectangle')
end

function M.native(atlas)
 local cached=nativeCache[atlas];if cached then return cached end
 local spec=Profile.native
 local native={schema=spec.schema,width=spec.width,height=spec.height,sha256=spec.sha256,pixels={},addresses=spec.addresses}
 for i=1,spec.width*spec.height do native.pixels[i]={0,0,0,0} end
 local tiles={}
 for _,a in ipairs(spec.addresses)do
  local key=a.metatile..':'..a.layer
  local tile=tiles[key]
  if not tile then tile=assert(atlas.texels(a.metatile,a.layer),'missing original foliage metatile');tiles[key]=tile end
  local color=tile[a.localY*16+a.localX+1]
  assert(color==tonumber(a.rgb,16),'original foliage pixel changed: '..key..' '..a.localX..','..a.localY)
  native.pixels[a.y*spec.width+a.x+1]={floor(color/65536)%256,floor(color/256)%256,color%256,255}
 end
 nativeCache[atlas]=native
 return native
end

-- Fingerprints identify the family; exact bindings decide whether this reviewed
-- profile owns the live artwork. Mismatches remain on the existing sheet path.
function M.matches(atlas)
 local ok,value=pcall(M.native,atlas)
 return ok,not ok and tostring(value)or nil
end

-- Kept accessible for bounded production-vs-authoring parity fixtures.
function M.compile(atlas,size)
 local mesh=Compiler.compile(Profile.geometry,M.native(atlas),size)
 assert(mesh.audit.pass,'compiled foliage geometry audit failed')
 return mesh
end

function M.build(atlas,size)
 local native=M.native(atlas)
 local mesh=M.compile(atlas,size)
 local lists={under={},over={}}
 local addresses={}
 for _,record in ipairs(native.addresses)do addresses[record.y*native.width+record.x+1]=record end
 for _,face in ipairs(mesh.faces)do
  -- Addresses are sparse source-crop records; vertices use original crop index.
  local address=assert(addresses[face.nativePixel],'mesh lost original native address')
  local r=rect(atlas,address)
  local u=r[1]+(address.localX+.5)/16*(r[3]-r[1])
  local v=r[2]+(address.localY+.5)/16*(r[4]-r[2])
  local vertices=lists[address.layer]
  for i=face.firstVertex,face.firstVertex+face.vertices-1 do
   local q=mesh.vertices[i]
   vertices[#vertices+1]={q[1],q[2],q[3],u,v,q[6],q[7],q[8]}
  end
 end
 return{under=lists.under,over=lists.over,quads=#mesh.faces,tris=#mesh.vertices/3,pixels=native.width,
        height=Profile.geometry.boughModel.apex,ring={},detached=0,
        compiler=Compiler.VERSION,compilerProfile=Profile.geometry.id,audit=mesh.audit}
end

return M
