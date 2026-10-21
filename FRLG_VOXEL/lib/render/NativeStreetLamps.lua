-- Modern Gen3 utility streetlight. Placement and light policy remain native.
local V=...
local M={REVISION='native-streetlamps-modern-r3-road-facing',ASSET='assets/lighting/lamppost.mesh.bin',MAX_SITES=3,MAX_TRIANGLES=5400}
local cached
local function u16(s,o)local a,b=s:byte(o+1,o+2);return b and a+b*256 end
local function u32(s,o)local a,b,c,d=s:byte(o+1,o+4);return d and a+b*256+c*65536+d*16777216 end
local function f32(s,o)
 local u=u32(s,o);if not u then return end;local sign=1;if u>=2147483648 then sign,u=-1,u-2147483648 end
 local e=math.floor(u/8388608)%256;local m=u%8388608;if e==255 then return end
 if e==0 then return sign*m/8388608*2^-126 end;return sign*(1+m/8388608)*2^(e-127)
end
function M.decode(blob)
 assert(type(blob)=='string'and blob:sub(1,4)=='TPR2','accepted lamp TPR2 required')
 local nv,ni,nb=u32(blob,4),u32(blob,8),u32(blob,12)
 assert(nv==2898 and ni==5400 and nb==5229 and #blob==32+nv*24+ni*2,'accepted lamp geometry identity')
 local verts,inds={},{};local o=32
 for i=1,nv do local v={};for j=0,5 do v[j+1]=assert(f32(blob,o+j*4),'invalid native lampfloat')end;verts[i]=v;o=o+24 end
 for i=1,ni do local n=assert(u16(blob,o));assert(n<nv);inds[i]=n+1;o=o+2 end
 return{vertices=verts,indices=inds,body=nb,triangles=ni/3}
end
-- Keep decode/ASSET for callers inspecting the legacy donor; runtime geometry is
-- local to this Gen3 module and never changes the shared Gen2 asset.
local function asset()
 if cached then return cached end
 local verts,inds={},{}
 local function quad(a,b,c,d)
  local n=#verts;for _,v in ipairs{a,b,c,d}do verts[#verts+1]=v end
  for _,i in ipairs{1,2,3,1,3,4}do inds[#inds+1]=n+i end
 end
 local function box(x0,y0,z0,x1,y1,z1)
  -- Outward counterclockwise winding on all six faces.
  quad({x0,y0,z0},{x0,y0,z1},{x0,y1,z1},{x0,y1,z0})
  quad({x1,y0,z1},{x1,y0,z0},{x1,y1,z0},{x1,y1,z1})
  quad({x0,y0,z1},{x0,y0,z0},{x1,y0,z0},{x1,y0,z1})
  quad({x0,y1,z0},{x0,y1,z1},{x1,y1,z1},{x1,y1,z0})
  quad({x1,y0,z0},{x0,y0,z0},{x0,y1,z0},{x1,y1,z0})
  quad({x0,y0,z1},{x1,y0,z1},{x1,y1,z1},{x0,y1,z1})
 end
 -- Pixel-space dimensions: restrained plinth, slim square shaft, short arm,
 -- flat downlight. Total height stays within the former 28-pixel silhouette.
 box(-1.2,0,-1.2,1.2,.7,1.2)
 box(-.7,.7,-.7,.7,26.2,.7)
 box(.7,25.1,-.7,3.1,26.2,.7)
 box(2.3,24.9,-1.7,6.9,26.3,1.7)
 local body=#inds
 -- A single recessed-looking cream underside; only these two faces emit.
 -- The existing streetlamp policy supplies warm night color and timing.
 quad({2.7,24.88,-1.3},{6.5,24.88,-1.3},{6.5,24.88,1.3},{2.7,24.88,1.3})
 cached={vertices=verts,indices=inds,body=body,triangles=#inds/3}
 return cached
end
local function eligible(mat,c,x,z,chosen)
 if x<1 or z<1 or x>=mat.w-1 or z>=mat.h-1 or not c.admit(x,z)or c.water(x,z)or c.blocked(x,z)then return false end
 local edge=false;for _,v in ipairs{{1,0},{-1,0},{0,1},{0,-1}}do if not c.admit(x+v[1],z+v[2])and not c.water(x+v[1],z+v[2])then edge=true;break end end
 if not edge then return false end
 for _,p in ipairs(chosen)do if(p.x-x)^2+(p.z-z)^2<64 then return false end end;return true
end
-- The asymmetric head points along a clear cardinal approach, never by site index.
local function facing(mat,c,x,z)
 local best,score=0,-1
 for _,d in ipairs{{1,0,0},{0,1,math.pi/2},{-1,0,math.pi},{0,-1,-math.pi/2}}do
  local n=0
  for step=1,3 do
   local px,pz=x+d[1]*step,z+d[2]*step
   if px<1 or pz<1 or px>=mat.w-1 or pz>=mat.h-1 or not c.admit(px,pz) or c.water(px,pz) or c.blocked(px,pz) then break end
   n=n+1
  end
  if n>score then best,score=d[3],n end
 end
 return best
end
-- FR imported map metadata is authoritative; suffixes omit Sevii settlements.
function M.isSettlement(mapType)
 return tonumber(mapType)==1 or mapType=='MAP_TYPE_TOWN' or mapType=='MAP_TYPE_CITY'
end
function M.collect(mat,q,c)
 local out={records={},sites={},diagnostics={status='not-town',triangles=0}}
 if mat.indoor or not M.isSettlement(c.mapType)then return out end
 if type(c.admit)~='function'or type(c.water)~='function'or type(c.blocked)~='function'then out.diagnostics.status='missing-native-placement-predicates';return out end
 local candidates=c.sites
  if not candidates then
  candidates={}
  for _,anchor in ipairs(c.preferredSites or{})do
   local x,z=math.floor(anchor.x),math.floor(anchor.z)
   local offsets=anchor.entrance and {{-2,1},{2,1},{-3,1},{3,1},{-2,2},{2,2}}
    or {{-2,0},{2,0},{-3,0},{3,0},{-2,1},{2,1},{-1,0},{1,0}}
   for _,off in ipairs(offsets)do candidates[#candidates+1]={x=x+off[1],z=z+off[2]}end
  end
 end
 for _,p in ipairs(candidates)do local x,z=p.x or p[1],p.z or p[2];if eligible(mat,c,x,z,out.sites)then out.sites[#out.sites+1]={x=x,z=z};if #out.sites==M.MAX_SITES then break end end end
 if #out.sites==0 then out.diagnostics.status='no-safe-sites';return out end
 local src=asset()
 for n,site in ipairs(out.sites)do
  local x,y,z=q.project(site.x+.5,site.z+.5);local yaw=facing(mat,c,site.x,site.z);local cs,sn=math.cos(yaw),math.sin(yaw)
  local vertices={};for _,v in ipairs(src.vertices)do vertices[#vertices+1]={x*16+v[1]*cs-v[3]*sn,y*16+v[2],z*16+v[1]*sn+v[3]*cs}end
  local rec={kind='streetlamp',building={id=tostring(c.mapId)..':streetlamp:'..site.x..':'..site.z},bodyTriangles={},triangles={},pools={{x=site.x+.5,z=site.z+.5,rx=1.6,rz=1.6}}}
  for i=1,#src.indices,3 do local t={vertices[src.indices[i]],vertices[src.indices[i+1]],vertices[src.indices[i+2]]};t.color=i<=src.body and{.12,.15,.17}or{1,.92,.72};rec.bodyTriangles[#rec.bodyTriangles+1]=t;if i>src.body then rec.triangles[#rec.triangles+1]=t end end
  out.records[#out.records+1]=rec
 end
 out.diagnostics={status='modern-procedural',triangles=#out.sites*src.triangles,sites=#out.sites};return out
end
return M

