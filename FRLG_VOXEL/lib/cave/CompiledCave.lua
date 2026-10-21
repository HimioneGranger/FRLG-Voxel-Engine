-- Adapter for compiler-produced native-pixel meshes and surface manifests.
-- Native collision stays engine authority. Raw elevation bits are identity
-- metadata, NEVER a physical height. Actor and camera height use this one query.
local M = { VERSION = 'compiled-cave/2' }
local EPS, EMPTY = 1e-7, {}
local function finite(v) return type(v) == 'number' and v == v and math.abs(v) < math.huge end
local function integer(v) return finite(v) and v == math.floor(v) end
local function same(a,b) return math.abs(a-b) <= EPS end
local function point(p)
  assert(type(p) == 'table' and finite(p[1]) and finite(p[2]), 'invalid native-pixel point')
  return {p[1], p[2]}
end
local function cross(a,b,x,z) return (b[1]-a[1])*(z-a[2])-(b[2]-a[2])*(x-a[1]) end
local function inside(p,x,z)
  local sign = 0
  for i,a in ipairs(p) do
    local d = cross(a,p[i%#p+1],x,z)
    if math.abs(d) > EPS then
      local s = d > 0 and 1 or -1
      if sign ~= 0 and sign ~= s then return false end
      sign = s
    end
  end
  return true
end
local function height(p,x,z)
  if p.plane then return p.plane.a*x+p.plane.b*z+p.plane.c end
  if p.ramp then
    local r=p.ramp; local t=((r.axis=='x' and x or z)-r.startPx)/(r.endPx-r.startPx)
    return r.fromPx+(r.toPx-r.fromPx)*t
  end
  return p.heightPx
end
local function contactAt(c,x,z)
  local dx,dz=c.b[1]-c.a[1],c.b[2]-c.a[2]
  local length=math.sqrt(dx*dx+dz*dz)
  if math.abs(cross(c.a,c.b,x,z)) > EPS*length or
      x < math.min(c.a[1],c.b[1])-EPS or x > math.max(c.a[1],c.b[1])+EPS or
      z < math.min(c.a[2],c.b[2])-EPS or z > math.max(c.a[2],c.b[2])+EPS then return nil end
  local t=((x-c.a[1])*dx+(z-c.a[2])*dz)/(length*length)
  return c.topHeights[1]+t*(c.topHeights[2]-c.topHeights[1]),
         c.bottomHeights[1]+t*(c.bottomHeights[2]-c.bottomHeights[1])
end

-- Returns mesh, statistics, query, matching NativeCaveGeometry.build's API.
-- opts.allowDraft is an explicit diagnostics-only escape hatch. A draft remains
-- draft in statistics and query metadata even when the caller opts to inspect it.
function M.load(compiled,mat,opts)
  opts=opts or {}
  -- Beta transport adapter: bound validation/index construction work without
  -- changing geometry, surface mathematics or the canonical compiler module.
  local work=0
  local function checkpoint()
    work=work+1
    if work>=64 then work=0;if opts.yieldSafe then opts.yieldSafe()end end
  end
  assert(type(compiled)=='table' and type(mat)=='table','compiled data and native materials required')
  local manifest=assert(compiled.manifest,'compiled surface manifest required')
  -- Exported mesh XZ is already projected. Keep numeric copies here so caller
  -- edits cannot silently move actors relative to the rendered candidate.
  local projection
  if manifest.projection~=nil then
    local source=manifest.projection
    assert(type(source)=='table' and (source.schema=='south-row-run/1' or source.schema=='south-row-run/2'),'unsupported compiled projection')
    assert(source.meshApplied==true,'projected manifest needs an already projected mesh')
    projection={schema=source.schema,meshApplied=true}
    local isRow=source.schema=='south-row-run/1' or source.schema=='south-row-run/2'
    local keys={'startZ','extraRunPerNativePx'}
    if source.schema=='south-row-run/2' then keys[#keys+1]='outerShelfStartZ';keys[#keys+1]='outerShelfExtraRate' end
    for _,key in ipairs(keys) do
      assert(finite(source[key]),'invalid projection '..key);projection[key]=source[key]
    end
    assert(projection.startZ>=0,'invalid projection start')
    if isRow then
      assert(projection.extraRunPerNativePx>=0,'invalid projection row rate')
      if source.schema=='south-row-run/2' then assert(projection.outerShelfStartZ>projection.startZ and projection.outerShelfExtraRate>=0,'invalid projection outer shelf interval/rate') end
    end
    if source.worldBoundsPx then
      assert(type(source.worldBoundsPx)=='table' and #source.worldBoundsPx==4,'invalid projected bounds')
      projection.worldBoundsPx={}
      for i,v in ipairs(source.worldBoundsPx) do assert(finite(v),'invalid projected bounds');projection.worldBoundsPx[i]=v end
      assert(projection.worldBoundsPx[3]>projection.worldBoundsPx[1] and projection.worldBoundsPx[4]>projection.worldBoundsPx[2],'empty projected bounds')
    end
  end
  local identity=assert(compiled.identity,'compiled native identity required')
  local ready=compiled.ready==true and manifest.complete==true
  assert(ready or opts.allowDraft==true,'compiled cave is not ready; allowDraft is diagnostics only')
  local w,h=identity.w,identity.h
  assert(integer(w) and integer(h) and w>0 and h>0,'invalid compiled dimensions')
  if projection then assert(projection.startZ<h*16,'projection starts outside native map') end
  if projection and projection.schema=='south-row-run/2' then assert(projection.outerShelfStartZ<h*16,'outer shelf starts outside native map') end
  assert(mat.w==w and mat.h==h,'compiled/native dimensions mismatch')
  if identity.layout then assert(identity.layout==mat.layout,'compiled/native layout mismatch') end
  if manifest.layout then assert(manifest.layout==mat.layout,'manifest/native layout mismatch') end
  assert(type(mat.cells)=='table' and #mat.cells==w*h,'native cell count mismatch')
  assert(type(identity.raw)=='table' and #identity.raw==w*h,'compiled raw identity count mismatch')
  assert(type(identity.behavior)=='table' and #identity.behavior==w*h,'compiled behavior identity count mismatch')
  for k=1,w*h do
    checkpoint()
    local c=mat.cells[k]
    assert(type(c)=='table' and c.x==(k-1)%w and c.y==math.floor((k-1)/w),'native cells must be contiguous row-major')
    assert(integer(c.raw) and c.raw>=0 and c.raw<=65535 and c.raw==identity.raw[k],'compiled/native raw mismatch at cell '..k)
    assert(integer(c.behavior) and c.behavior>=0 and c.behavior<=255 and c.behavior==identity.behavior[k],'compiled/native behavior mismatch at cell '..k)
  end
  local fingerprint=identity.artFingerprint or identity.atlasSHA256
  if fingerprint then assert(opts.artFingerprint==fingerprint,'compiled/native art fingerprint mismatch or missing fingerprint') end
  local mesh=assert(compiled.mesh,'compiled mesh required')
  if mesh.projection then
    assert(projection and mesh.projection.schema==projection.schema and mesh.projection.meshApplied==true,'mesh/manifest projection mismatch')
    for _,key in ipairs{'startZ','extraRunPerNativePx','outerShelfStartZ','outerShelfExtraRate'} do
      assert(mesh.projection[key]==projection[key],'mesh/manifest projection mismatch: '..key)
    end
  end
  if projection and projection.worldBoundsPx then
    local expected=h*16+math.max(0,h*16-projection.startZ)*projection.extraRunPerNativePx
    if projection.schema=='south-row-run/2' then expected=expected+math.max(0,h*16-projection.outerShelfStartZ)*projection.outerShelfExtraRate end
    local b=projection.worldBoundsPx
    assert(same(b[1],0) and same(b[2],0) and same(b[3],w*16) and same(b[4],expected),'projected bounds disagree with native map')
  end
  assert(mesh.units=='native-pixels' and type(mesh.tris)=='table','compiled mesh must use native-pixels')
  for k,t in ipairs(mesh.tris) do
    checkpoint()
    for i=1,3 do
      assert(type(t[i])=='table','invalid compiled triangle '..k)
      for j=1,5 do assert(finite(t[i][j]),'non-finite compiled vertex '..k) end
    end
  end
  local ox,oz,base=opts.originX or 0,opts.originZ or 0,opts.basePx or 0
  assert(finite(ox) and finite(oz) and finite(base),'invalid compiled origin/base')
  -- A nonzero map base is an explicit placement transform, applied equally to
  -- rendered vertices and height queries. The compiler's mesh stays untouched.
  if base~=0 then
    local transformed={}
    for k,v in pairs(mesh) do transformed[k]=v end
    transformed.tris={}
    for k,t in ipairs(mesh.tris) do
      checkpoint()
      local nt={}; for key,v in pairs(t) do nt[key]=v end
      for i=1,3 do
        local nv={}; for key,v in pairs(t[i]) do nv[key]=v end
        nv[2]=nv[2]+base; nt[i]=nv
      end
      transformed.tris[k]=nt
    end
    mesh=transformed
  end
  local byCell,contactCells,allContacts={},{},{}
  local top=-math.huge
  local stats={surfaces=0,walls=#(manifest.walls or {}),unknownCells=0,complete=ready,draft=not ready,projectionMinimumJacobian=1}
  for _,source in ipairs(manifest.surfaces or {}) do
    checkpoint()
    local cell=source.cell
    assert(integer(cell) and cell>=1 and cell<=w*h,'invalid surface owner cell')
    local p={cell=cell,polygon={}}
    local modes=(source.heightPx~=nil and 1 or 0)+(source.plane~=nil and 1 or 0)+(source.ramp~=nil and 1 or 0)
    assert(modes==1,'surface needs exactly one height definition')
    if source.plane then
      local plane=source.plane
      assert(finite(plane.a) and finite(plane.b) and finite(plane.c),'invalid surface plane')
      p.plane={a=plane.a,b=plane.b,c=plane.c}
    elseif source.ramp then
      local r=source.ramp
      assert((r.axis=='x' or r.axis=='z') and finite(r.startPx) and finite(r.endPx) and r.endPx>r.startPx and finite(r.fromPx) and finite(r.toPx),'invalid surface ramp')
      p.ramp={axis=r.axis,startPx=r.startPx,endPx=r.endPx,fromPx=r.fromPx,toPx=r.toPx}
    else
      assert(finite(source.heightPx),'invalid surface height'); p.heightPx=source.heightPx
    end
    assert(type(source.polygon)=='table' and #source.polygon>=3,'surface polygon required')
    local cx,cz=(cell-1)%w*16,math.floor((cell-1)/w)*16
    for i,v in ipairs(source.polygon) do
      p.polygon[i]=point(v)
      assert(v[1]>=cx-EPS and v[1]<=cx+16+EPS and v[2]>=cz-EPS and v[2]<=cz+16+EPS,'surface footprint outside owner cell')
      local elevation=height(p,v[1],v[2]); assert(finite(elevation),'non-finite surface height')
      top=math.max(top,elevation)
    end
    local sign=0
    for i,a in ipairs(p.polygon) do
      local b,c=p.polygon[i%#p.polygon+1],p.polygon[(i+1)%#p.polygon+1]
      local d=cross(a,b,c[1],c[2])
      if math.abs(d)>EPS then
        local s=d>0 and 1 or -1
        assert(sign==0 or sign==s,'compiled surface polygon must be convex')
        sign=s
      end
    end
    assert(sign~=0,'degenerate compiled surface polygon')
    byCell[cell]=byCell[cell] or {}; table.insert(byCell[cell],p)
    stats.surfaces=stats.surfaces+1
  end
  for _,source in ipairs(manifest.cliffContacts or {}) do
    checkpoint()
    local c={a=point(source.a),b=point(source.b)}
    assert(c.a[1]~=c.b[1] or c.a[2]~=c.b[2],'zero-length cliff contact')
    local t=source.topHeights or {source.topPx,source.topPx}
    local b=source.bottomHeights or {source.bottomPx,source.bottomPx}
    assert(finite(t[1]) and finite(t[2]) and finite(b[1]) and finite(b[2]),'invalid contact endpoint levels')
    assert(t[1]>=b[1] and t[2]>=b[2] and (t[1]>b[1] or t[2]>b[2]),'inverted or empty cliff contact')
    c.topHeights={t[1],t[2]}; c.bottomHeights={b[1],b[2]}
    allContacts[#allContacts+1]=c
    for z=math.max(0,math.floor(math.min(c.a[2],c.b[2])/16)-1),math.min(h-1,math.floor(math.max(c.a[2],c.b[2])/16)) do
      for x=math.max(0,math.floor(math.min(c.a[1],c.b[1])/16)-1),math.min(w-1,math.floor(math.max(c.a[1],c.b[1])/16)) do
        checkpoint()
        local key=z*w+x+1; contactCells[key]=contactCells[key] or {}; table.insert(contactCells[key],c)
      end
    end
  end
  for k=1,w*h do checkpoint();if not byCell[k] then stats.unknownCells=stats.unknownCells+1 end end
  if ready then assert(stats.unknownCells==0,'ready manifest has unowned native cells') end

  -- Include all owners at an exact cell border. Only a declared cliff contact
  -- connecting both actual surface levels can select the higher one there.
  local function pixelHeight(px,pz)
    local cx,cz=math.floor(px/16),math.floor(pz/16)
    local xmin=same(px,cx*16) and cx-1 or cx
    local zmin=same(pz,cz*16) and cz-1 or cz
    local levels={}
    for y=zmin,cz do for x=xmin,cx do
      if x>=0 and x<w and y>=0 and y<h then
        for _,p in ipairs(byCell[y*w+x+1] or EMPTY) do
          if inside(p.polygon,px,pz) then
            local v=height(p,px,pz); local present=false
            for _,other in ipairs(levels) do if same(v,other) then present=true; break end end
            if not present then levels[#levels+1]=v end
          end
        end
      end
    end end
    if #levels==0 then return nil,'unresolved' end
    if #levels==1 then return levels[1] end
    local ownerX,ownerZ=math.min(w-1,math.max(0,cx)),math.min(h-1,math.max(0,cz))
    local neighbors=contactCells[ownerZ*w+ownerX+1] or EMPTY
    local connected={[1]=true}
    for pass=1,#levels do
      local changed=false
      for _,c in ipairs(neighbors) do
        local high,low=contactAt(c,px,pz)
        if high then
          local hi,lo
          for i,v in ipairs(levels) do if same(v,high) then hi=i end; if same(v,low) then lo=i end end
          if hi and lo and (connected[hi] or connected[lo]) then
            if not connected[hi] or not connected[lo] then changed=true end
            connected[hi],connected[lo]=true,true
          end
        end
      end
      if not changed then break end
    end
    local maximum=-math.huge
    for i,v in ipairs(levels) do
      if not connected[i] then return nil,'conflicting surfaces without an owning cliff contact' end
      maximum=math.max(maximum,v)
    end
    return maximum
  end
  local q={base=base/16,layout={w=w,h=h,index=mat.layoutIndex,base=base},originX=ox,originZ=oz,
           cave=true,projection=projection and projection.schema or 'cave-unsheared',identity=M.VERSION..':'..tostring(manifest.version or 'unversioned'),
           complete=ready,draft=not ready,slopeStats={eligible=0,applied=0,rejectedGroups=0}}
  local function pixelShift(pz)
    if not projection then return 0 end
    local shift=math.max(0,pz-projection.startZ)*projection.extraRunPerNativePx
    if projection.schema=='south-row-run/2' then shift=shift+math.max(0,pz-projection.outerShelfStartZ)*projection.outerShelfExtraRate end
    return shift
  end
  function q.contains(x,z) return finite(x) and finite(z) and x>=ox and z>=oz and x<ox+w and z<oz+h end
  function q.surfaceAt(x,z)
    if not q.contains(x,z) then return nil,'outside' end
    local v,why=pixelHeight((x-ox)*16,(z-oz)*16)
    if v==nil then return nil,why end
    return v/16
  end
  function q.liftAt(x,z) local v,why=q.surfaceAt(x,z); if v==nil then return nil,why end; return v+q.base end
  -- Height/collision lookups continue to accept native map coordinates.
  -- Only project/unproject cross the explicit native/world XZ boundary.
  function q.shiftAt(x,z)
    local v,why=q.surfaceAt(x,z);if v==nil then return nil,why end
    return pixelShift((z-oz)*16,v*16)/16
  end
  function q.cellShift(x,z) return q.shiftAt(x,z) end
  function q.slopeOffset() return 0 end
  function q.cellLift(x,z)
    if not q.contains(x,z) then return nil,'outside' end
    return q.surfaceAt(ox+math.floor(x-ox)+.5,oz+math.floor(z-oz)+.5)
  end
  function q.project(x,z)
    local v,why=q.liftAt(x,z);if v==nil then return nil,why end
    local shift,reason=q.shiftAt(x,z);if shift==nil then return nil,reason end
    return x,v,z+shift
  end
  function q.unproject(x,z)
    if not projection then local v,why=q.surfaceAt(x,z);if v==nil then return nil,why end;return x,z end
    if not finite(x)or not finite(z)or x<ox or x>=ox+w then return nil,'outside' end
    local px,target=(x-ox)*16,(z-oz)*16
    if projection.schema=='south-row-run/1' or projection.schema=='south-row-run/2' then
      local native=target
      if target>projection.startZ then native=projection.startZ+(target-projection.startZ)/(1+projection.extraRunPerNativePx) end
      if projection.schema=='south-row-run/2' then
        local shelf=projection.outerShelfStartZ
        local worldShelf=shelf+(shelf-projection.startZ)*projection.extraRunPerNativePx
        if target>worldShelf then native=shelf+(target-worldShelf)/(1+projection.extraRunPerNativePx+projection.outerShelfExtraRate) end
      end
      if native<0 or native>=h*16 then return nil,'outside' end
      local value,why=pixelHeight(px,native);if value==nil then return nil,why end
      return x,oz+native/16
    end
    return nil,'unsupported projection'
  end
  function q.containsWorld(x,z) local native=q.unproject(x,z);return native~=nil end
  function q.worldBounds()
    if projection and projection.worldBoundsPx then local b=projection.worldBoundsPx;return ox+b[1]/16,oz+b[2]/16,ox+b[3]/16,oz+b[4]/16 end
    return ox,oz,ox+w,oz+h
  end
  function q.surfaceTop(x,z)
    if not q.contains(x,z) then return nil,'outside' end
    local k=math.floor(z-oz)*w+math.floor(x-ox)+1; local maximum
    for _,p in ipairs(byCell[k] or EMPTY) do for _,v in ipairs(p.polygon) do maximum=math.max(maximum or -math.huge,height(p,v[1],v[2])) end end
    if maximum==nil then return nil,'unresolved' end
    return maximum/16
  end
  function q.drawnTop() return top>-math.huge and top/16 or nil end
  local grids={}
  function q.cell(x,z)
    if not q.contains(x,z) then return nil,'outside' end
    local cx,cz=math.floor(x-ox),math.floor(z-oz); local k=cz*w+cx+1
    if grids[k]==false then return nil,'unresolved or conflicting boundary' end
    if grids[k] then return grids[k] end
    local grid={}
    for j=0,4 do for i=0,4 do
      local v,why=pixelHeight(cx*16+i*4,cz*16+j*4)
      if v==nil then grids[k]=false; return nil,why end
      grid[#grid+1]=v
    end end
    grids[k]=grid; return grid
  end
  return mesh,stats,q
end
return M
