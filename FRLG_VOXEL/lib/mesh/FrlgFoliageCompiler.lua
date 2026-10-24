-- Profile-driven native-art foliage compiler. See PROVENANCE.md.
-- No game globals, map IDs, legacy model catalogs or prebuilt geometry.
local C={VERSION='gen3-foliage-runtime/1'}
local floor,ceil,sqrt,abs,min,max=math.floor,math.ceil,math.sqrt,math.abs,math.min,math.max
local function finite(n)return type(n)=='number'and n==n and abs(n)<math.huge end
local function check(ok,msg)assert(ok,'foliage compiler: '..msg)end
local function rgb(p)return p[1]*65536+p[2]*256+p[3]end
local function set(a)local s={};for _,v in ipairs(a or{})do s[v]=true end;return s end
local function polygon(x,y,p)
 local inside=false;local j=#p
 for i=1,#p do local a,b=p[i],p[j]
  if (a[2]>y)~=(b[2]>y)and x<(b[1]-a[1])*(y-a[2])/(b[2]-a[2])+a[1]then inside=not inside end;j=i
 end
 return inside
end
local function prepare(g,n)
 check(g.schema=='gen3-foliage-geometry/1','unknown geometry schema')
 check(type(g.id)=='string'and #g.id>0,'missing id')
 check(n.width>0 and n.height>0 and #n.pixels==n.width*n.height,'native crop dimensions/pixel count')
 check(finite(g.radius)and g.radius>0,'invalid radius')
 local f=assert(g.boughModel,'missing boughModel')
 check(finite(f.apex)and f.apex>0,'missing physical apex')
 check(finite(f.rootRadius)and finite(f.rootTop)and finite(f.stemVisible),'missing authored root/stem')
 check(f.rootRadius>0 and f.rootRadius<=g.radius and f.rootTop>0 and f.rootTop<=f.apex and f.stemVisible>0 and f.stemVisible<=f.rootTop,'invalid physical root/stem dimensions')
 check(finite(f.artBase)and finite(f.artVertical)and finite(f.artDepth),'missing material projection')
 check(f.artVertical>0 and f.artDepth>=0,'invalid declared material projection')
 check(type(f.masses)=='table'and(#f.masses>0 or type(g.scallopedRows)=='table'and #g.scallopedRows>0),'missing semantic masses/rows; generic fallback prohibited')
 if g.materialSampling~=nil then
  local policy=g.materialSampling
  check(type(g.scallopedRows)=='table'and #g.scallopedRows>0 and type(policy)=='table','materialSampling requires nonempty scallopedRows and an explicit object')
  for key in pairs(policy)do check(key=='nearest'or key=='underside'or key=='projection'or key=='undersideFoldY'or key=='undersideReturnRow'or key=='undersideReturnBlend','unknown materialSampling field '..tostring(key))end
  check(policy.nearest=='euclidean'and policy.underside=='projected'and(policy.projection==nil or policy.projection=='coherent-cardinal'),'materialSampling supports euclidean/projected with optional coherent-cardinal projection')
  check(policy.undersideFoldY==nil or finite(policy.undersideFoldY)and policy.undersideFoldY>=0 and policy.undersideFoldY<=f.apex/2,'invalid physical undersideFoldY attachment')
  check((policy.undersideReturnRow~=nil)==(policy.undersideReturnBlend~=nil),'underside return requires an explicit row and blend')
  if policy.undersideReturnRow~=nil then
   local found=false
   for _,row in ipairs(g.scallopedRows)do if row.name==policy.undersideReturnRow then found=true end end
   check(type(policy.undersideReturnRow)=='string'and found,'underside return must name an existing leaf row')
   check(finite(policy.undersideReturnBlend)and policy.undersideReturnBlend>=0 and policy.undersideReturnBlend<=1,'invalid underside return blend')
   check(policy.undersideFoldY==nil,'row return and global underside fold are separate alternatives')
  end
 end
 local o=assert(g.ownership,'missing ownership')
 check(type(o.barkPalette)=='table'and #o.barkPalette>0,'missing explicit bark palette')
 check(type(o.leafPalette)=='table'and #o.leafPalette>0,'missing explicit native leaf palette')
 for _,palette in ipairs{o.barkPalette,o.leafPalette}do for _,value in ipairs(palette)do check(finite(value)and value>=0 and value<=16777215 and value==floor(value),'invalid native RGB palette entry')end end
 local bark,leaf=set(o.barkPalette),set(o.leafPalette)
 check(type(n.addresses)=='table'and #n.addresses>0,'missing exact original native address records')
 local address={}
 for _,record in ipairs(n.addresses)do
  check(record.x>=0 and record.x<n.width and record.y>=0 and record.y<n.height,'original native address outside crop')
  local i=record.y*n.width+record.x+1;check(not address[i],'duplicate original native address')
  check(tonumber(record.rgb,16)==rgb(n.pixels[i])and n.pixels[i][4]>=128,'original native address RGB/alpha mismatch')
  check((record.layer=='under'or record.layer=='over')and type(record.metatile)=='number'and record.metatile>=0,'invalid original metatile/layer address')
  check(record.localX>=0 and record.localX<16 and record.localY>=0 and record.localY<16,'invalid native local XY')
  address[i]=record
 end
 check(type(o.leafMask)=='table'and #o.leafMask>0,'missing explicit native leaf mask')
 local leafMask={}
 for _,row in ipairs(o.leafMask)do
  check(row.y>=0 and row.y<n.height and row.y==floor(row.y),'leaf mask row outside crop')
  for _,span in ipairs(row.spans)do
   check(span[1]>=0 and span[2]<n.width and span[1]<=span[2]and span[1]==floor(span[1])and span[2]==floor(span[2]),'leaf mask span outside crop')
   for x=span[1],span[2]do local i=row.y*n.width+x+1
    check(n.pixels[i][4]>=128 and leaf[rgb(n.pixels[i])],'leaf mask includes nonleaf/transparent native pixel')
    leafMask[i]=true
   end
  end
 end
 local samples,leaves,barks={},{},{}
 local counts={leaf=0,bark=0,shadowOrExcluded=0,transparent=0};local darkest,darkValue
 for i,p in ipairs(n.pixels)do
  check(type(p)=='table'and #p==4,'native pixels require RGBA byte quadruples')
  for _,v in ipairs(p)do check(finite(v)and v>=0 and v<=255 and v==floor(v),'native RGBA must be byte integers')end
  local x,y=(i-1)%n.width,floor((i-1)/n.width);local col=rgb(p);local kind
  if p[4]>=128 then check(address[i]~=nil,'opaque crop pixel has no original native address')end
  if p[4]<128 then counts.transparent=counts.transparent+1
  else
   local hem=g.hemColumns or{};local last=hem[tostring(x)]or hem[x]or g.canopyLastRow
   local inLeaf=leafMask[i]and leaf[col]and type(last)=='number'and y<=last
   check(not leafMask[i]or inLeaf,'leaf mask disagrees with declared cutoff/hem')
   if inLeaf and o.applyLeafSourceRegions and o.leafSourceRegions and #o.leafSourceRegions>0 then
    inLeaf=false;for _,poly in ipairs(o.leafSourceRegions)do if polygon(x+.5,y+.5,poly)then inLeaf=true;break end end
   end
   if inLeaf then kind='leaf'
   elseif bark[col]and(not o.barkStartRow or y>=o.barkStartRow)then kind='bark'
   else counts.shadowOrExcluded=counts.shadowOrExcluded+1 end
  end
  if kind then
   counts[kind]=counts[kind]+1
   samples[i]={index=i,x=x,y=y,rgb=col,rgba=p,kind=kind,u=(x+.5)/n.width,v=(y+.5)/n.height,nativeAddress=address[i]}
   local list=kind=='leaf'and leaves or barks;list[#list+1]=i
   local value=p[1]+p[2]+p[3]
   if kind=='leaf'and(not darkest or value<darkValue)then darkest,darkValue=i,value end
  end
 end
 check(#leaves>0 and #barks>0,'native ownership leaves no foliage or bark')
 local known={name=true,x=true,z=true,h=true,rx=true,rz=true,upper=true,lower=true,drape=true,pointed=true,radialDrape=true,drapeX=true,drapeZ=true,quarter=true}
 for _,m in ipairs(f.masses)do
  check(type(m.name)=='string','mass missing evidence name')
  for k in pairs(m)do check(known[k],'unknown mass field '..tostring(k))end
  for _,k in ipairs{'x','z','h','rx','rz','upper','lower'}do check(finite(m[k]),m.name..' invalid '..k)end
  check(m.rx>0 and m.rz>0 and m.upper>=0 and m.lower>=0,m.name..' invalid dimensions')
  check(m.h+m.upper<=f.apex+1e-8,m.name..' exceeds declared apex')
  check(not m.quarter or m.quarter>=0 and m.quarter<=3 and m.quarter==floor(m.quarter),'quarter must be0..3')
  check(not m.drapeX or finite(m.drapeZ),'drape direction incomplete')
  local refs=g.massEvidence and g.massEvidence[m.name]
  check(type(refs)=='table'and #refs>0,m.name..' has no semantic evidence binding')
 end
 if g.scallopedRows~=nil then
  check(type(g.scallopedRows)=='table'and #g.scallopedRows>0 and #g.scallopedRows<=16,'scallopedRows must be an array of1..16 entries')
  local names={};for _,m in ipairs(f.masses)do names[m.name]=true end
  local fields={name=true,sourcePolyline=true,evidenceRefs=true,rx=true,rz=true,rimY=true,upperRise=true,undercutRise=true,lipDepth=true,rootDepth=true,undersideLobeDepth=true,undersideLobeStart=true,undersideLobeMode=true,lipValleyInset=true,scallops=true}
  local scallopFields={count=true,phase=true,drop=true,radialAmplitude=true,falloff=true}
  for _,row in ipairs(g.scallopedRows)do
   check(type(row.name)=='string'and #row.name>0 and not names[row.name],'missing/duplicate scalloped row name');names[row.name]=true
   for key in pairs(row)do check(fields[key],'unknown scalloped row field '..tostring(key))end
   for _,key in ipairs{'rx','rz','rimY','upperRise','undercutRise','lipDepth'}do check(finite(row[key]),row.name..' invalid '..key)end
   check(row.rx>0 and row.rz>0 and row.upperRise>0 and row.undercutRise>=0 and row.undercutRise<row.upperRise and row.lipDepth>=0,row.name..' invalid curved row envelope')
   check(row.rootDepth==nil or finite(row.rootDepth)and row.rootDepth>=0,row.name..' invalid authored root depth')
   check(row.undersideLobeDepth==nil or finite(row.undersideLobeDepth)and row.undersideLobeDepth>=0 and row.undersideLobeDepth<=8,row.name..' invalid underside lobe depth')
   check(row.undersideLobeStart==nil or row.undersideLobeDepth~=nil and finite(row.undersideLobeStart)and row.undersideLobeStart>=0 and row.undersideLobeStart<=.9,row.name..' invalid underside lobe start; requires depth and finite start within0..0.9')
   check(row.undersideLobeMode==nil or row.undersideLobeMode=='balanced'and row.undersideLobeStart~=nil and row.undersideLobeDepth~=nil,row.name..' invalid underside lobe mode; balanced requires explicit start and depth')
   check(row.lipValleyInset==nil or finite(row.lipValleyInset)and row.lipValleyInset>=0 and row.lipValleyInset<=2,row.name..' invalid lip valley inset; must be finite within0..2')
   check(row.rimY+row.upperRise<=f.apex+1e-8,row.name..' exceeds declared apex')
   local s=assert(row.scallops,row.name..' missing scallops')
   for key in pairs(s)do check(scallopFields[key],'unknown scallop field '..tostring(key))end
   for _,key in ipairs{'count','phase','drop','radialAmplitude','falloff'}do check(finite(s[key]),row.name..' invalid scallop '..key)end
   check(s.count>=4 and s.count<=64 and s.count%4==0,row.name..' scallop count must be multiple4 within4..64')
   check(s.drop>=0 and s.drop<=8 and s.radialAmplitude>=0 and s.radialAmplitude<=.2 and s.falloff>=2 and s.falloff<=8,row.name..' invalid scallop envelope')
   check(row.rx*(1+s.radialAmplitude)<=n.width/2+1e-8 and row.rz*(1+s.radialAmplitude)<=g.radius+1e-8,row.name..' row envelope exceeds declared footprint')
   check(row.rimY-s.drop-row.lipDepth-(row.rootDepth or 0)-(row.undersideLobeDepth or 0)>=0,row.name..' row envelope may cross ground')
   check(type(row.sourcePolyline)=='table'and #row.sourcePolyline>=3 and #row.sourcePolyline<=256,row.name..' native row polyline requires3..256 points')
   for _,point in ipairs(row.sourcePolyline)do check(type(point)=='table'and #point==2 and finite(point[1])and finite(point[2])and point[1]>=0 and point[1]<n.width and point[2]>=0 and point[2]<n.height,row.name..' native row polyline outside crop')end
   check(type(row.evidenceRefs)=='table'and #row.evidenceRefs>0,row.name..' missing native observation references')
   for _,ref in ipairs(row.evidenceRefs)do check(type(ref)=='string'and #ref>0,row.name..' invalid observation reference')end
   local refs=g.massEvidence and g.massEvidence[row.name]
   check(type(refs)=='table'and #refs>0,row.name..' has no semantic evidence binding')
  end
 end
 local function nearest(px,py,kind)
  local list=kind=='bark'and barks or leaves;local best,bestY,bestX
  if g.materialSampling and kind=='leaf'then
   local bestDistance
   for _,i in ipairs(list)do local p=samples[i];local dy,dx=abs(p.y-py),abs(p.x-px);local distance=dx*dx+dy*dy
    if not best or distance<bestDistance or distance==bestDistance and(dy<bestY or dy==bestY and(dx<bestX or dx==bestX and i<best))then best,bestDistance,bestY,bestX=i,distance,dy,dx end
   end
   return best
  end
  for _,i in ipairs(list)do local p=samples[i];local dy,dx=abs(p.y-py),abs(p.x-px)
   if not best or dy<bestY or dy==bestY and dx<bestX then best,bestY,bestX=i,dy,dx end
  end
  return best
 end
 return samples,counts,nearest,darkest
end
-- Public cheap entrypoint: same preparation/guards used by every compilation.
function C.validate(g,n)
 prepare(g,n)
 return{valid=true,id=g.id,schema=g.schema}
end
local function index(x,y,z,d)return(z*d[2]+y)*d[1]+x+1 end
local function coords(i,d)local k=i-1;return k%d[1],floor(k/d[1])%d[2],floor(k/(d[1]*d[2]))end
local STEPS={{1,0,0},{-1,0,0},{0,1,0},{0,-1,0},{0,0,1},{0,0,-1}}
local function neighbours(i,d,visit)
 local x,y,z=coords(i,d)
 for _,s in ipairs(STEPS)do local a,b,c=x+s[1],y+s[2],z+s[3]
  if a>=0 and a<d[1]and b>=0 and b<d[2]and c>=0 and c<d[3]then visit(index(a,b,c,d))end
 end
end
local function topology(cells,d)
 local visited,components={},{}
 for seed=1,d[1]*d[2]*d[3]do if cells[seed]and not visited[seed]then
  local q={seed};visited[seed]=true;local at=1
  while at<=#q do neighbours(q[at],d,function(n)if cells[n]and not visited[n]then visited[n]=true;q[#q+1]=n end end);at=at+1 end
  components[#components+1]={count=#q,firstIndex=seed}
 end end
 local outside,q={},{}
 local function air(i)if not cells[i]and not outside[i]then outside[i]=true;q[#q+1]=i end end
 for z=0,d[3]-1 do for y=0,d[2]-1 do for x=0,d[1]-1 do
  if x==0 or y==0 or z==0 or x==d[1]-1 or y==d[2]-1 or z==d[3]-1 then air(index(x,y,z,d))end
 end end end
 local at=1;while at<=#q do neighbours(q[at],d,air);at=at+1 end
 local sealed={};for i=1,d[1]*d[2]*d[3]do if not cells[i]and not outside[i]then local x,y,z=coords(i,d);sealed[#sealed+1]={x=x,y=y,z=z,index=i}end end
 return{componentCount=#components,components=components,sealedEmptyCount=#sealed,sealedEmptyCells=sealed,rawOccupancyPreserved=true,automaticCleanup=false}
end
local FACES={
 {axis=3,step=1,u=1,v=2,channel='projected',normal={0,0,1}},
 {axis=3,step=-1,u=1,v=2,channel='projected',normal={0,0,-1}},
 {axis=1,step=1,u=3,v=2,channel='wrapped',normal={1,0,0}},
 {axis=1,step=-1,u=3,v=2,channel='wrapped',normal={-1,0,0}},
 {axis=2,step=1,u=1,v=3,channel='top',normal={0,1,0}},
 {axis=2,step=-1,u=1,v=3,channel='bottom',normal={0,-1,0}},
}
function C.compile(g,n,size)
 check(size==1 or size==4,'only declared near1/far4 LOD supported')
 local samples,ownership,nearest,darkest=prepare(g,n);local f=g.boughModel
 local bounds={minX=-n.width/2,maxX=n.width/2,minY=0,maxY=f.apex,minZ=-g.radius,maxZ=g.radius}
 local d={ceil(n.width/size),ceil(f.apex/size),ceil(2*g.radius/size)}
 check(d[1]*d[2]*d[3]<=1000000,'voxel budget exceeded')
 local origin={bounds.minX,0,bounds.minZ};local finish={bounds.maxX,bounds.maxY,bounds.maxZ}
 local function plane(axis,k)return min(finish[axis],origin[axis]+k*size)end
 local function center(axis,k)return(plane(axis,k)+plane(axis,k+1))*.5 end
 local function span(m,x,z)
  local dx,dz=x-m.x,z-m.z
  if m.quarter==1 then dx,dz=-dz,dx elseif m.quarter==2 then dx,dz=-dx,-dz elseif m.quarter==3 then dx,dz=dz,-dx end
  local xx,zz=dx/m.rx,dz/m.rz;local rho=sqrt(xx*xx+zz*zz)
  if rho>1 then return end
  -- Explicit policy parameter; this preserves small leading features at coarse LOD.
  local tip=min(.45,size*(g.lodTipRadiusFactor or .75)/min(m.rx,m.rz))
  local r=max(0,(rho-tip)/(1-tip));local round=sqrt(max(0,1-r*r));local front=max(0,zz)
  if m.radialDrape then front=r elseif m.drapeX then front=max(0,xx*m.drapeX+zz*m.drapeZ)end
  local middle=m.h-(m.drape or 0)*front*front*r
  return middle-m.lower*round,middle+m.upper*(m.pointed and 1-r^.9 or round)
 end
 local function rowSpan(row,x,z)
  local xx,zz=x/row.rx,z/row.rz
  local angle=math.atan2(xx,zz);local scallop=row.scallops
  local wave=math.cos(scallop.count*angle+scallop.phase)
  local rho=sqrt(xx*xx+zz*zz)/(1+scallop.radialAmplitude*wave)
  if rho>1 then return end
  local tip=min(.45,size*(g.lodTipRadiusFactor or .75)/min(row.rx,row.rz))
  local r=max(0,(rho-tip)/(1-tip));local round=sqrt(max(0,1-r*r))
  local droop=scallop.drop*(.5+.5*wave)*r^scallop.falloff
  -- One continuous course: convex upper surface and raised inner underside
  -- roll into the same scalloped outer rim. No independent lobe union.
  local upper=row.rimY+row.upperRise*round-droop
  -- Authored interior attachment tapers to zero at the rolled rim. This is
  -- part of the primitive, never a topology-driven cavity repair.
  local lower=row.rimY+row.undercutRise*round-row.lipDepth*round*r*r-droop-(row.rootDepth or 0)*(1-r*r)^2
  -- Continue each existing scallop below the row. Its valley, inner attachment
  -- and rim stay at their original heights; the lower bellies remain distinct.
  -- This lower-only control leaves the approved upper surface and radius exact.
  if row.undersideLobeDepth then
   -- Do not let new leaf depth recolor the existing stem at its attachment.
   local rootBlend=min(1,max(0,(sqrt(x*x+z*z)-f.rootRadius)/f.rootRadius))
   rootBlend=rootBlend*rootBlend*(3-2*rootBlend)
   local returnWeight=4*r*r*(1-r*r)
   if row.undersideLobeStart~=nil then
    -- Keep the connected interior unchanged. Roll only the existing leaf
    -- end back underneath, with zero value and slope at both attachments.
    -- The original angular scallops still determine each section's phase.
    local t=max(0,(r-row.undersideLobeStart)/(1-row.undersideLobeStart))
    returnWeight=16*t*t*(1-t)*(1-t)
   end
   local angular=row.undersideLobeMode=='balanced'and wave or(.5+.5*wave)
   lower=lower-row.undersideLobeDepth*returnWeight*angular*rootBlend
  end
  if row.lipValleyInset and row.lipValleyInset>0 then
   -- A small lower-lip undercut exposes the same original scallop valleys
   -- at eye level. It does not widen the canopy or invent another leaf phase.
   -- The authored two-unit vertical band blends to zero at the inset boundary.
   local width=row.lipValleyInset*(.5-.5*wave)
   local distance=(1-rho)*min(row.rx,row.rz)*(1+scallop.radialAmplitude*wave)
   if width>0 and distance<width then
    local t=1-distance/width;t=t*t*(3-2*t)
    lower=max(lower,row.rimY-droop+2*t)
   end
  end
  return lower,upper
 end
 local rowDiagnostics
 local undersideReturnIndex,undersideReturnRow
 if g.materialSampling and g.materialSampling.undersideReturnRow then
  for i,row in ipairs(g.scallopedRows)do
   if row.name==g.materialSampling.undersideReturnRow then undersideReturnIndex,undersideReturnRow=i,row end
  end
 end
 if g.scallopedRows then
  rowDiagnostics={}
  for i,row in ipairs(g.scallopedRows)do rowDiagnostics[i]={name=row.name,sourcePolyline=row.sourcePolyline,evidenceRefs=row.evidenceRefs,occupiedVoxelCenters=0,exclusiveVoxelCenters=0,boundaryVoxelFaces=0,exclusiveBoundaryVoxelFaces=0,undersideVoxelFaces=0}end
 end
 local unitCoverage,coarseCoverageAudit
 if g.scallopedRows and size==4 then
  -- Conservative, grid-aligned OR of the authored unit volume. No arbitrary
  -- component connection, cavity fill or deletion is performed.
  local unit=C.compile(g,n,1);unitCoverage={}
  for _,cell in ipairs(unit.occupied)do
   local x,y,z=floor(cell.x/4),floor(cell.y/4),floor(cell.z/4)
   local i=index(x,y,z,d);local cover=unitCoverage[i]
   if not cover then cover={rows={},massInside=false,stem=false};unitCoverage[i]=cover end
   cover.massInside=cover.massInside or cell.massInside
   cover.stem=cover.stem or cell.stemInside
   for _,ri in ipairs(cell.rowIndices)do cover.rows[ri]=true end
  end
  coarseCoverageAudit={policy='aligned OR of actual authored unit-center occupancy, including rows, masses and root',unitVoxels=#unit.occupied,unitComponents=unit.audit.componentCount,unitSealedEmptyCells=unit.audit.sealedEmptyCount,blockSize=4,automaticCleanup=false}
 end
 local cells,occupied={},{};local count=0;local sourceCache={}
 local function sample(px,py,kind)
  px=max(0,min(n.width-1,floor(px)));py=max(0,min(n.height-1,floor(py)))
  local key=kind..':'..px..':'..py
  if not sourceCache[key]then sourceCache[key]=nearest(px,py,kind)end
  return sourceCache[key]
 end
 for z=0,d[3]-1 do for y=0,d[2]-1 do for x=0,d[1]-1 do
  local wx,wy,wz=center(1,x),center(2,y),center(3,z);local inside=false
  local massInside,rowIndices,stem
  if unitCoverage then
   local cover=unitCoverage[index(x,y,z,d)];rowIndices={};massInside=cover and cover.massInside or false;stem=cover and cover.stem or false;inside=massInside
   if cover then for ri=1,#g.scallopedRows do if cover.rows[ri]then rowIndices[#rowIndices+1]=ri;inside=true end end end
  else
   for _,m in ipairs(f.masses)do local lo,hi=span(m,wx,wz);if lo and wy>=lo and wy<=hi then inside=true;break end end
   massInside=inside
   if g.scallopedRows then
    rowIndices={}
    for ri,row in ipairs(g.scallopedRows)do local lo,hi=rowSpan(row,wx,wz)
     if lo and wy>=lo and wy<=hi then inside=true;rowIndices[#rowIndices+1]=ri end
    end
   end
   stem=wx*wx+wz*wz<=f.rootRadius*f.rootRadius and wy<=f.rootTop
  end
  if rowIndices then for _,ri in ipairs(rowIndices)do rowDiagnostics[ri].occupiedVoxelCenters=rowDiagnostics[ri].occupiedVoxelCenters+1 end end
  if inside or stem then
   local p,s,t,b,kind
   if inside then
    -- A rounded lower coat returns beneath the visible rim. Continue its
    -- native leaf pattern around that inferred return instead of stretching
    -- the source's tiny central fringe across the entire unseen underside.
    -- Source Y includes projected depth; it is not a geometry cutoff.
    local sampleY=wy
    local foldY=g.materialSampling and g.materialSampling.undersideFoldY
    if foldY and wy<foldY then sampleY=2*foldY-wy end
    p=sample(n.width/2+wx,f.artBase-sampleY*f.artVertical+abs(wz)*f.artDepth,'leaf')
    local aspect=n.width/(2*g.radius)
    s=sample(n.width/2+wz*aspect,f.artBase-sampleY*f.artVertical+abs(wx/aspect)*f.artDepth,'leaf')
    t=f.cardinalTop and abs(wx)>abs(wz)and s or p;b=g.materialSampling and t or darkest;kind='leaf'
    if g.materialSampling and g.materialSampling.projection=='coherent-cardinal'then p,s,b=t,t,t end
    -- Continue the selected course's own native leaf pattern onto its lower
    -- surface. This changes only the downward material channel: the original
    -- volume, front/side/top samples and bark stay exact. Hidden return mapping
    -- is authored explicitly between that course's existing envelopes.
    if undersideReturnRow then
     local owned=false
     for _,ri in ipairs(rowIndices or{})do if ri==undersideReturnIndex then owned=true end end
     if owned then
      local lo,hi=rowSpan(undersideReturnRow,wx,wz)
      if lo then
       local returnY=lo+(hi-lo)*g.materialSampling.undersideReturnBlend
       local rp=sample(n.width/2+wx,f.artBase-returnY*f.artVertical+abs(wz)*f.artDepth,'leaf')
       local rs=sample(n.width/2+wz*aspect,f.artBase-returnY*f.artVertical+abs(wx/aspect)*f.artDepth,'leaf')
       b=f.cardinalTop and abs(wx)>abs(wz)and rs or rp
      end
     end
    end
   else
    p=wy<f.stemVisible and sample(n.width/2+wx,(g.ownership.groundRow or f.artBase)-1-wy/f.stemVisible*5,'bark')or darkest
    s,t,b=p,p,p;kind=samples[p].kind
   end
   local i=index(x,y,z,d);cells[i]={projected=p,wrapped=s,top=t,bottom=b,kind=kind};count=count+1
   occupied[#occupied+1]={index=i,x=x,y=y,z=z,worldX=wx,worldY=wy,worldZ=wz,kind=kind,projected=p,wrapped=s,top=t,bottom=b}
   if rowIndices then
    local exclusive=#rowIndices==1 and not massInside and not stem
    cells[i].rowIndices=rowIndices;cells[i].exclusiveRow=exclusive and rowIndices[1]or nil
    occupied[#occupied].rowIndices=rowIndices;occupied[#occupied].massInside=massInside;occupied[#occupied].stemInside=stem
    if exclusive then rowDiagnostics[rowIndices[1]].exclusiveVoxelCenters=rowDiagnostics[rowIndices[1]].exclusiveVoxelCenters+1 end
   end
  end
 end end end
 check(count>0,'empty geometry')
 local vertices,faces={},{};local used={}
 for _,face in ipairs(FACES)do
  for slice=0,d[face.axis]-1 do
   local mask,looks={},{};local a={0,0,0};a[face.axis]=slice
   for v=0,d[face.v]-1 do for u=0,d[face.u]-1 do
    a[face.u],a[face.v]=u,v;local cell=cells[index(a[1],a[2],a[3],d)]
    if cell then local near={a[1],a[2],a[3]};near[face.axis]=near[face.axis]+face.step
     local adjacent=near[face.axis]>=0 and near[face.axis]<d[face.axis]and cells[index(near[1],near[2],near[3],d)]
     if not adjacent then
      if cell.rowIndices then for _,ri in ipairs(cell.rowIndices)do
       local rd=rowDiagnostics[ri];rd.boundaryVoxelFaces=rd.boundaryVoxelFaces+1
       if cell.exclusiveRow==ri then rd.exclusiveBoundaryVoxelFaces=rd.exclusiveBoundaryVoxelFaces+1 end
       if face.axis==2 and face.step==-1 then rd.undersideVoxelFaces=rd.undersideVoxelFaces+1 end
      end end
      local si=cell[face.channel];local native=samples[si]
      local key=native.rgb*2+(native.kind=='leaf'and 1 or 0)
      mask[v*d[face.u]+u+1]=key;looks[key]=looks[key]or si
     end
    end
   end end
   for v=0,d[face.v]-1 do for u=0,d[face.u]-1 do
    local k=v*d[face.u]+u+1;local key=mask[k]
    if key then
     local across=1;while u+across<d[face.u]and mask[k+across]==key do across=across+1 end
     local down=1;local extending=true
     while v+down<d[face.v]and extending do
      for j=0,across-1 do if mask[(v+down)*d[face.u]+u+j+1]~=key then extending=false;break end end
      if extending then down=down+1 end
     end
     for yy=v,v+down-1 do for xx=u,u+across-1 do mask[yy*d[face.u]+xx+1]=nil end end
     local sourceIndex=assert(looks[key]);local source=assert(samples[sourceIndex]);used[sourceIndex]=true
     local p=face.step>0 and slice+1 or slice
     local corners={}
     for _,q in ipairs{{u,v},{u+across,v},{u+across,v+down},{u,v+down}}do
      local pt={};pt[face.axis]=plane(face.axis,p);pt[face.u]=plane(face.u,q[1]);pt[face.v]=plane(face.v,q[2]);corners[#corners+1]=pt
     end
     local first=#vertices+1
     local winding=face.axis==3 and face.step or-face.step
     local order=winding>0 and{1,2,3,1,3,4}or{1,3,2,1,4,3}
     for _,j in ipairs(order)do local pt=corners[j];vertices[#vertices+1]={pt[1],pt[2],pt[3],source.u,source.v,face.normal[1],face.normal[2],face.normal[3]}end
     faces[#faces+1]={firstVertex=first,vertices=6,nativePixel=sourceIndex,sourceX=source.x,sourceY=source.y,rgb=source.rgb,kind=source.kind,channel=face.channel,axis=face.axis,step=face.step}
    end
   end end
  end
 end
 local audit=topology(cells,d);audit.occupiedVoxels=count;audit.vertices=#vertices;audit.quads=#faces;audit.triangles=#vertices/3
 audit.degenerateTriangles=0;audit.inwardWindingTriangles=0;audit.invalidNativeAddresses=0;audit.nonFiniteValues=0;audit.uvOutsideUnit=0
 audit.channelSamplesChecked=0;audit.emittedFaceAddressesChecked=0
 for _,cell in ipairs(occupied)do
  for _,channel in ipairs{'projected','wrapped','top','bottom'}do
   local si=cell[channel];local sample=samples[si];audit.channelSamplesChecked=audit.channelSamplesChecked+1
   if not sample or not sample.nativeAddress or sample.rgb~=rgb(n.pixels[si])then audit.invalidNativeAddresses=audit.invalidNativeAddresses+1 end
  end
 end
 for _,face in ipairs(faces)do
  local sample=samples[face.nativePixel];audit.emittedFaceAddressesChecked=audit.emittedFaceAddressesChecked+1
  if not sample or sample.rgb~=face.rgb or sample.x~=face.sourceX or sample.y~=face.sourceY then audit.invalidNativeAddresses=audit.invalidNativeAddresses+1
  else for j=face.firstVertex,face.firstVertex+5 do
   local v=vertices[j];if v[4]~=sample.u or v[5]~=sample.v then audit.invalidNativeAddresses=audit.invalidNativeAddresses+1 end
  end end
 end
 local vb={minX=math.huge,minY=math.huge,minZ=math.huge,maxX=-math.huge,maxY=-math.huge,maxZ=-math.huge}
 for _,v in ipairs(vertices)do
  for _,value in ipairs(v)do if not finite(value)then audit.nonFiniteValues=audit.nonFiniteValues+1 end end
  for j,axis in ipairs{'X','Y','Z'}do vb['min'..axis]=min(vb['min'..axis],v[j]);vb['max'..axis]=max(vb['max'..axis],v[j])end
  if v[4]<0 or v[4]>1 or v[5]<0 or v[5]>1 then audit.uvOutsideUnit=audit.uvOutsideUnit+1 end
 end
 for i=1,#vertices,3 do local p,q,r=vertices[i],vertices[i+1],vertices[i+2]
  local ax,ay,az=q[1]-p[1],q[2]-p[2],q[3]-p[3];local bx,by,bz=r[1]-p[1],r[2]-p[2],r[3]-p[3]
  local cx,cy,cz=ay*bz-az*by,az*bx-ax*bz,ax*by-ay*bx
  if cx*cx+cy*cy+cz*cz<1e-16 then audit.degenerateTriangles=audit.degenerateTriangles+1
  elseif cx*p[6]+cy*p[7]+cz*p[8]<=0 then audit.inwardWindingTriangles=audit.inwardWindingTriangles+1 end
 end
 local nativeUsed={};for i=1,#n.pixels do if used[i]then nativeUsed[#nativeUsed+1]=samples[i]end end
 audit.bounds=vb;audit.groundAligned=vb.minY==0;audit.apexMatches=vb.maxY==f.apex;audit.expectedApex=f.apex;audit.ownership=ownership
 if rowDiagnostics then audit.scallopedRows=rowDiagnostics end
 if coarseCoverageAudit then audit.scallopedRowsCoarseCoverage=coarseCoverageAudit end
 if g.materialSampling then audit.materialSampling={nearest='euclidean',underside='projected cardinal source, same as top',tieBreak='distance squared, vertical distance, horizontal distance, source index',bark='legacy unchanged'}end
 if g.materialSampling and g.materialSampling.projection then audit.materialSampling.projection=g.materialSampling.projection end
 if g.materialSampling and g.materialSampling.undersideFoldY then audit.materialSampling.undersideFoldY=g.materialSampling.undersideFoldY end
 if undersideReturnRow then
  audit.materialSampling.undersideReturnRow=undersideReturnRow.name
  audit.materialSampling.undersideReturnBlend=g.materialSampling.undersideReturnBlend
 end
 audit.pass=audit.componentCount==1 and audit.sealedEmptyCount==0 and audit.degenerateTriangles==0 and audit.inwardWindingTriangles==0 and audit.invalidNativeAddresses==0 and audit.nonFiniteValues==0 and audit.uvOutsideUnit==0 and audit.groundAligned and audit.apexMatches
 local materialProjection=g.materialSampling and'declared oblique source projection; euclidean-nearest eligible leaf sample; projected cardinal underside; legacy bark'or'declared oblique source projection; row-nearest then horizontal-nearest eligible native sample'
 if g.materialSampling and g.materialSampling.projection=='coherent-cardinal'then materialProjection='shared per-leaf-voxel existing dominant-cardinal top sample on all faces; legacy bark'end
 return{schema='gen3-foliage-mesh/1',compiler=C.VERSION,id=g.id,lod=size,dimensions=d,voxelSize=size,vertices=vertices,faces=faces,occupied=occupied,nativeSamples=nativeUsed,audit=audit,geometryPolicy={rawOccupancy=true,automaticCleanup=false,mergeBy='exact native RGB and ownership kind; first eligible source pixel retained per merged face',materialProjection=materialProjection,lodTipRadiusFactor=g.lodTipRadiusFactor or .75,prototypeAcceptance=false}}
end
function C.json(v)
 local t=type(v)
 if t=='nil'then return'null'elseif t=='boolean'or t=='number'then return tostring(v)
 elseif t=='string'then return'"'..v:gsub('[%z\1-\31\\"]',function(c)local e={['"']='\\"',['\\']='\\\\',['\n']='\\n',['\r']='\\r',['\t']='\\t'};return e[c]or string.format('\\u%04x',c:byte())end)..'"'end
 local total,array=0,true;for k in pairs(v)do total=total+1;if type(k)~='number'or k<1 or k%1~=0 then array=false end end
 if #v~=total then array=false end
 local out={};if array then for i=1,#v do out[#out+1]=C.json(v[i])end;return'['..table.concat(out,',')..']'end
 local keys={};for k in pairs(v)do keys[#keys+1]=k end;table.sort(keys,function(a,b)return tostring(a)<tostring(b)end)
 for _,k in ipairs(keys)do out[#out+1]=C.json(tostring(k))..':'..C.json(v[k])end
 return'{'..table.concat(out,',')..'}'
end
return C
