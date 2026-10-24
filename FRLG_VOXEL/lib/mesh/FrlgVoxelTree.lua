local V=...
local Flora=V.require("mesh/FrlgFlora")
local Models=V.require("mesh/FrlgTreeModels")
local Compiled=V.require("mesh/FrlgCompiledTree")
local M={VERSION="fr-voxel-tree 2"}

M.PROFILE_ROWS=2
M.FACING_SPREAD=0.5
M.LIGHT={-0.6,0.8}
M.RING_EDGE_SHARE=0.75
M.ART_PIXELS_PER_TILE=16
M.GREEN_MARGIN=8
M.TALL_GRASS_BEHAVIOR=0x02
M.BACKDROP_SHARE=0.1
M.TRUNK_EXTRA_PIXELS=4
M.NEAR_VOXEL=1
M.FAR_VOXEL=4
M.CHANNEL_STEP=8
M.HASH_MODULUS=2147483647

M.enabled=false
M.stampCache={}

local floor,ceil,abs,sqrt,max,min=math.floor,math.ceil,math.abs,math.sqrt,math.max,math.min

local FACES={
  {axis=3,step=1,u=1,v=2,source="projected",normal={0,0,1}},
  {axis=3,step=-1,u=1,v=2,source="projected",normal={0,0,-1}},
  {axis=1,step=1,u=3,v=2,source="wrapped",normal={1,0,0}},
  {axis=1,step=-1,u=3,v=2,source="wrapped",normal={-1,0,0}},
  {axis=2,step=-1,u=1,v=3,source="top",normal={0,1,0}},
  {axis=2,step=1,u=1,v=3,source="bottom",normal={0,-1,0}},
}

local function channels(colour) return floor(colour/65536)%256,floor(colour/256)%256,colour%256 end
local function brightness(colour) local r,g,b=channels(colour);return r+g+b end
local function isGreen(colour) local r,g,b=channels(colour);return g>r+M.GREEN_MARGIN and g>b+M.GREEN_MARGIN end

local function quantise(colour)
  local r,g,b=channels(colour)
  local step=M.CHANNEL_STEP
  return floor(r/step)*1024+floor(g/step)*32+floor(b/step)
end

local function tileColours(atlas,mid)
  local under=atlas.texels(mid,"under")
  if not under then return nil end
  local over=atlas.hasOver and atlas.hasOver(mid) and atlas.texels(mid,"over")
  local colours={}
  for i=1,256 do
    local top=over and over[i]
    colours[i]=top and top>=0 and top or under[i]
  end
  return colours
end

function M.fingerprint(atlas,mid)
  local colours=tileColours(atlas,mid)
  if not colours then return nil end
  local hash=0
  for _,colour in ipairs(colours) do hash=(hash*31+quantise(colour))%M.HASH_MODULUS end
  return hash
end

function M.models(atlas)
  local found={}
  for _,model in ipairs(Models) do
    if M.fingerprint(atlas,model.fingerprint.mid)==model.fingerprint.hash
      and (not model.compilerProfile or Compiled.matches(atlas)) then found[#found+1]=model end
  end
  return found
end

function M.modelFor(models,cells)
  for _,cell in ipairs(cells) do
    for _,model in ipairs(models) do
      if model.tiles[cell.mid] then return model end
    end
  end
end

function M.backdrop(input,models)
  local cellsWith,openCells={},0
  local atlas=input.atlas
  for y=0,input.height-1 do
    for x=0,input.width-1 do
      local cell=input.cellAt(x,y)
      local open=cell and cell.walkable and cell.behavior~=M.TALL_GRASS_BEHAVIOR and cell.category~="TREE"
        and not M.modelFor(models,{cell}) and not (atlas.hasOver and atlas.hasOver(cell.mid))
      local texels=open and atlas.texels(cell.mid,"under")
      if texels then
        openCells=openCells+1
        local seen={}
        for _,colour in ipairs(texels) do
          if not seen[colour] then seen[colour]=true;cellsWith[colour]=(cellsWith[colour] or 0)+1 end
        end
      end
    end
  end
  local colours={}
  for colour,count in pairs(cellsWith) do
    if count>=openCells*M.BACKDROP_SHARE then colours[colour]=true end
  end
  for colour in pairs(Flora.KEY) do colours[colour]=true end
  return colours
end

local function setPixel(grid,index,colour,source,lx,ly,layer)
  grid.colour[index],grid.source[index],grid.lx[index],grid.ly[index],grid.layer[index]=colour,source,lx,ly,layer
end

local function rectOf(atlas,mid,layer)
  local a,b,c,d
  if layer=="over" then
    if not (atlas.hasOver and atlas.hasOver(mid)) then return nil end
    a,b,c,d=atlas.overRect(mid)
  else a,b,c,d=atlas.underRect(mid) end
  if type(a)=="table" then return a end
  return d and {a,b,c,d} or nil
end

local function modelRows(model)
  local rows={}
  for index,part in ipairs(model.rows) do
    local first=part.from or 0
    for ly=index==1 and 0 or first,part.to or 15 do
      rows[#rows+1]={mids=part.mids,ly=ly,layer=part.layer or "full",above=ly<first}
    end
  end
  return rows
end

local function tileSource(atlas,mid)
  local overR=rectOf(atlas,mid,"over")
  return {mid=mid,under=atlas.texels(mid,"under"),over=overR and atlas.texels(mid,"over"),r=rectOf(atlas,mid,"under"),
    overR=overR}
end

local function pixelOf(source,layer,index,backdrop)
  local top=source.over and source.over[index]
  if top and top>=0 then return top,"over" end
  if layer=="over" then return nil end
  local colour=source.under and source.under[index]
  if colour and not backdrop[colour] then return colour,"under" end
end

local function addTip(grid,tips)
  local threshold=grid.threshold
  for py=grid.bodyTop-1,0,-1 do
    for px=0,grid.width-1 do
      local index=py*grid.width+px+1
      local tip=tips[index]
      if tip and grid.colour[index+grid.width] and isGreen(tip.colour) and brightness(tip.colour)>=threshold then
        setPixel(grid,index,tip.colour,tip.source,tip.lx,tip.ly,tip.layer)
      end
    end
  end
end

local function litThreshold(colours)
  local darkest,brightest=math.huge,-math.huge
  for _,colour in pairs(colours) do
    if isGreen(colour) then
      darkest=min(darkest,brightness(colour))
      brightest=max(brightest,brightness(colour))
    end
  end
  return (darkest+brightest)/2
end

local function modelGrid(atlas,model,backdrop)
  local rows=modelRows(model)
  local width=#model.rows[1].mids*M.ART_PIXELS_PER_TILE
  local grid={width=width,height=#rows,colour={},source={},lx={},ly={},layer={},radius=model.radius,bodyTop=#rows,canopyLastRow=model.canopyLastRow,undersideRise=model.undersideRise,hemColumns=model.hemColumns,boughModel=model.boughModel}
  local sources,tips,colours={},{},{}
  for py,row in ipairs(rows) do
    if not row.above and grid.bodyTop==#rows then grid.bodyTop=py-1 end
    for px=0,width-1 do
      local mid=row.mids[floor(px/16)+1]
      sources[mid]=sources[mid] or tileSource(atlas,mid)
      local lx=px%16
      local colour,layer=pixelOf(sources[mid],row.layer,row.ly*16+lx+1,backdrop)
      if colour then
        local index=(py-1)*width+px+1
        colours[index]=colour
        if row.above then
          tips[index]={colour=colour,source=sources[mid],lx=lx,ly=row.ly,layer=layer}
        else
          setPixel(grid,index,colour,sources[mid],lx,row.ly,layer)
        end
      end
    end
  end
  grid.threshold=litThreshold(colours)
  addTip(grid,tips)
  local lastRow=0
  for index in pairs(grid.colour) do lastRow=max(lastRow,floor((index-1)/width)+1) end
  grid.height=lastRow
  return grid
end

local function crownBottom(grid,threshold)
  for py=grid.height-1,0,-1 do
    for px=0,grid.width-1 do
      local colour=grid.colour[py*grid.width+px+1]
      if colour and isGreen(colour) and brightness(colour)>=threshold then return py end
    end
  end
end

local function trunkOutline(grid,bottom)
  local width,height=grid.width,grid.height
  local function empty(px,py)
    local colour=px>=0 and px<width and py<height and grid.colour[py*width+px+1]
    return not colour or isGreen(colour)
  end
  local total,touching,bark={},{},false
  for py=bottom+1,height-1 do
    for px=0,width-1 do
      local colour=grid.colour[py*width+px+1]
      if colour and not isGreen(colour) then
        total[colour]=(total[colour] or 0)+1
        if empty(px-1,py) or empty(px+1,py) or empty(px,py+1) then touching[colour]=(touching[colour] or 0)+1 end
      end
    end
  end
  local outline={}
  for colour,count in pairs(total) do
    if (touching[colour] or 0)/count>=M.RING_EDGE_SHARE then outline[colour]=true else bark=true end
  end
  return bark and outline or {}
end

local function splitShadow(grid)
  local bottom=crownBottom(grid,litThreshold(grid.colour))
  if not bottom or bottom==grid.height-1 then return end
  grid.crownBottom=bottom
  grid.hemStart=max(grid.bodyTop or 0,bottom-M.ART_PIXELS_PER_TILE+1)
  local width,trunk=grid.width,{}
  local outline=trunkOutline(grid,bottom)
  for py=bottom+1,grid.height-1 do
    for px=0,width-1 do
      local colour=grid.colour[py*width+px+1]
      if colour and not isGreen(colour) and not outline[colour] then
        trunk[px]=trunk[px] or {top=py,bottom=py,samples={}}
        trunk[px].bottom=py
        trunk[px].samples[#trunk[px].samples+1]=py
      end
    end
  end
  if next(trunk)==nil then return end
  local artLength=0
  local firstBark=grid.height
  for _,column in pairs(trunk) do
    artLength=max(artLength,column.bottom-column.top+1)
    firstBark=min(firstBark,column.top)
  end
  for py=bottom+1,firstBark do
    local found=false
    for px=floor(width/4),ceil(3*width/4)-1 do
      local colour=grid.colour[py*width+px+1]
      if colour then local r,g=channels(colour);if g<=r then firstBark=py;found=true;break end end
    end
    if found then break end
  end
  -- Find the baked ground-shadow band using its dominant leaf colour beside
  -- the first bark row, as the native foliage pass does. Dark hanging leaves
  -- above that band must not be discarded along with the ground shadow.
  local counts,dark,darkCount={},nil,0
  for px=0,width-1 do
    local colour=grid.colour[firstBark*width+px+1]
    if colour and isGreen(colour) then
      counts[colour]=(counts[colour] or 0)+1
      if counts[colour]>darkCount then dark,darkCount=colour,counts[colour] end
    end
  end
  local shadowStart=firstBark
  local function shadowShare(py)
    local count,total=0,0
    for px=0,width-1 do
      local colour=grid.colour[py*width+px+1]
      if colour and isGreen(colour) then total=total+1;if colour==dark then count=count+1 end end
    end
    return total>0 and count/total or 0
  end
  if dark then
    while shadowStart>bottom+1 and shadowShare(shadowStart-1)>=.5 do shadowStart=shadowStart-1 end
  end
  -- Fingerprinted families supply an art-reviewed leaf/shadow boundary. Keep
  -- every native opaque leaf inside it; dark color alone is not an alpha hole.
  if grid.canopyLastRow then shadowStart=grid.canopyLastRow+1 end
  local function leafAt(index)
    local leaf,above=grid.colour[index],grid.colour[index-width]
    return leaf and isGreen(leaf) and (grid.canopyLastRow or leaf~=dark or (above and above~=dark and isGreen(above)))
  end
  local hemBottom=bottom
  for py=bottom+1,shadowStart-1 do for px=0,width-1 do
    if leafAt(py*width+px+1) then hemBottom=max(hemBottom,py) end
  end end
  -- Preserve the installed model height. The authored canopy boundary removes
  -- the baked ground shadow; the bottom surface provides stem clearance.
  local trunkLength=artLength+M.TRUNK_EXTRA_PIXELS
  local copy={colour={},source={},lx={},ly={},layer={}}
  for key,list in pairs(copy) do for index,value in pairs(grid[key]) do list[index]=value end end
  for py=bottom+1,max(grid.height-1,bottom+trunkLength) do
    for px=0,width-1 do
      local index,column=py*width+px+1,trunk[px]
      local step=py-bottom-1
      -- Source bark rows may have leaf/shadow gaps between them. Stretch
      -- actual bark texels, never those intervening green shadow texels.
      local from=column and step<trunkLength and column.samples[min(#column.samples,floor(step*#column.samples/trunkLength)+1)]
      -- The dark leaf hem hangs below the bright crown. It is canopy art,
      -- not part of the ground shadow being separated from the trunk.
      local leaf=copy.colour[index]
      local above=copy.colour[index-width]
      local leafEdge=leaf and isGreen(leaf) and (grid.canopyLastRow or leaf~=dark or (above and above~=dark and isGreen(above)))
      if (py<shadowStart or (grid.hemColumns and py<=(grid.hemColumns[px]or -1))) and leafEdge then
        setPixel(grid,index,copy.colour[index],copy.source[index],copy.lx[index],copy.ly[index],copy.layer[index])
      elseif from then
        local fromIndex=from*width+px+1
        setPixel(grid,index,copy.colour[fromIndex],copy.source[fromIndex],copy.lx[fromIndex],copy.ly[fromIndex],
          copy.layer[fromIndex])
      else
        setPixel(grid,index,nil,nil,nil,nil,nil)
      end
    end
  end
  grid.height=bottom+1+trunkLength
  local columns,outlineColours=0,{}
  for _ in pairs(trunk) do columns=columns+1 end
  for colour in pairs(outline) do outlineColours[#outlineColours+1]=string.format("%06x",colour) end
  table.sort(outlineColours)
  grid.trunk={art=artLength,shown=trunkLength,columns=columns,outline=outlineColours,
    crownBottom=bottom,hemBottom=hemBottom,firstBark=firstBark,shadowStart=shadowStart}
end

local function dropGroundRing(grid)
  local width,height=grid.width,grid.height
  local total,touching={},{}
  local function empty(px,py)
    return px<0 or py<0 or px>=width or py>=height or not grid.colour[py*width+px+1]
  end
  for py=0,height-1 do
    for px=0,width-1 do
      local colour=grid.colour[py*width+px+1]
      if colour then
        total[colour]=(total[colour] or 0)+1
        if empty(px-1,py) or empty(px+1,py) or empty(px,py-1) or empty(px,py+1) then
          touching[colour]=(touching[colour] or 0)+1
        end
      end
    end
  end
  local ring={}
  for colour,count in pairs(total) do
    if isGreen(colour) and (touching[colour] or 0)/count>=M.RING_EDGE_SHARE then ring[colour]=true end
  end
  for index,colour in pairs(grid.colour) do
    if ring[colour] then grid.colour[index]=nil end
  end
  return ring
end

local function filledProfile(halves,rows,reach)
  local depths={}
  for vy=0,rows-1 do
    local above,below=halves[vy],halves[vy]
    for step=1,reach do
      above=max(above,halves[vy-step] or 0)
      below=max(below,halves[vy+step] or 0)
    end
    depths[vy]=halves[vy]>0 and min(above,below) or 0
  end
  return depths
end

-- Semantic bough lofts: convex leafy tops, draped rims, raised inner undersides.
-- Source image y is sampled through an inferred oblique projection, not used
-- as the physical height of a painted leaf cap.
-- Semantic bough lofts: convex leafy tops, draped rims, raised inner undersides.
-- Source image y is sampled through an inferred oblique projection, not used
-- as the physical height of a painted leaf cap.
-- Semantic bough lofts: convex leafy tops, draped rims, raised inner undersides.
-- Source image y is sampled through an inferred oblique projection, not used
-- as the physical height of a painted leaf cap.
local function volume(grid,size)
  local radius=grid.radius/size
  local dims={ceil(grid.width/size),ceil(grid.height/size),ceil(2*radius)}
  local sources={projected={},wrapped={},top={},bottom={}}
  local form=grid.boughModel
  -- Move the existing canopy assembly only; evaluate native leaf samples
  -- in its original coordinates so the leaf artwork follows the geometry.
  local canopyOffset=form.canopyOffsetY
  if canopyOffset==nil then canopyOffset=0 end
  assert(type(canopyOffset)=="number" and canopyOffset==canopyOffset and canopyOffset>=-8 and canopyOffset<=0,"invalid canopyOffsetY")
  local green,bark,leafPalette={},{},{}
  local darkest,darkValue=nil,math.huge
  for py=0,grid.height-1 do
    green[py]={};bark[py]={}
    for px=0,grid.width-1 do
      local k=py*grid.width+px+1;local colour=grid.colour[k]
      if colour then
        local list=isGreen(colour)and green[py]or bark[py]
        list[#list+1]=k
        if isGreen(colour)then leafPalette[colour]=true end
        if isGreen(colour)and brightness(colour)<darkValue then darkest,darkValue=k,brightness(colour)end
      end
    end
  end
  local cache={}
  local function sourceAt(px,py,isBark)
    px=max(0,min(grid.width-1,floor(px)));py=max(0,min(grid.height-1,floor(py)))
    local key=(isBark and grid.width*grid.height or 0)+py*grid.width+px+1
    if cache[key]then return cache[key]end
    local lists=isBark and bark or green
    for dy=0,grid.height do
      for _,sy in ipairs{py-dy,py+dy}do
        if lists[sy]and #lists[sy]>0 then
          local best,distance=nil,math.huge
          for _,k in ipairs(lists[sy])do
            local d=abs((k-1)%grid.width-px)
            if d<distance then best,distance=k,d end
          end
          cache[key]=best;return best
        end
      end
    end
  end
  -- Forest hidden underside uses one existing native leaf palette step of
  -- shade. The light/dark pattern stays on the same original mass, and the
  -- output still points to a real retained leaf pixel, never ground shadow.
  local shadedCache={}
  local function shadedNativeLeaf(pixel)
    if not form.undersideShadeStep or not pixel then return pixel end
    if shadedCache[pixel]then return shadedCache[pixel]end
    local colour=grid.colour[pixel]
    local level=brightness(colour);local targetLevel=-math.huge
    local targetColour
    for c in pairs(leafPalette)do
      local b=brightness(c)
      if b<level and b>targetLevel then targetLevel,targetColour=b,c end
    end
    if not targetColour then shadedCache[pixel]=pixel;return pixel end
    local x=(pixel-1)%grid.width;local y=floor((pixel-1)/grid.width)
    local best,distance=pixel,math.huge
    for py=0,grid.height-1 do for _,k in ipairs(green[py])do
      if grid.colour[k]==targetColour then
        local dx=(k-1)%grid.width-x;local dy=py-y;local d=dx*dx+dy*dy
        if d<distance then best,distance=k,d end
      end
    end end
    shadedCache[pixel]=best;return best
  end
  local function rimAt(points,angle)
    for i=1,#points-1 do
      local a,b=points[i],points[i+1]
      if angle>=a[1]and angle<=b[1]then
        local t=(angle-a[1])/(b[1]-a[1])
        return a[2]*(1-t)+b[2]*t,a[3]*(1-t)+b[3]*t
      end
    end
    return 1,0
  end
  local columns={}
  for vx=0,dims[1]-1 do for vz=0,dims[3]-1 do
    local xp=(vx+.5)*size-grid.width/2
    local zp=(vz+.5-radius)*size
    local spans={}
    for _,bough in ipairs(form.boughs or {})do
      local xx,zz=xp/bough.rx,zp/bough.rz
      local angle=math.atan2(xx,zz)*180/math.pi
      local reach,hang=rimAt(bough.rimShape,angle)
      local rho=sqrt(xx*xx+zz*zz)/reach
      if rho<=1 then
        local tip=min(.45,size*.75/min(bough.rx,bough.rz))
        local r=max(0,(rho-tip)/(1-tip))
        local round=sqrt(max(0,1-r*r))
        local q=bough.pointed and 1-r^.9 or round
        -- Both surfaces roll into the same outer edge. The whole curved rim
        -- droops, instead of ending a nonzero-thickness slab in a vertical wall.
        local middle=bough.rim-hang*r^3
        local upper=middle+(bough.apex-bough.rim)*q
        local lower=middle-bough.lowerDepth*round
        spans[#spans+1]={lower=lower,upper=max(lower,upper)}
      end
    end
    -- Explicit native-facing cap, shoulders, central drape and pendant ends.
    -- Each has a convex top and underside. They meet at a rolled outer edge;
    -- their overlaps provide hidden connections without a whole-tree shell.
    for _,mass in ipairs(form.masses or {})do
      local dx,dz=xp-mass.x,zp-mass.z
      -- Optional quarter-turn is an inverse local transform. Legacy masses
      -- have no turn, so General retains its exact previous calculation.
      if mass.quarter==1 then dx,dz=-dz,dx
      elseif mass.quarter==2 then dx,dz=-dx,-dz
      elseif mass.quarter==3 then dx,dz=dz,-dx end
      local xx,zz=dx/mass.rx,dz/mass.rz
      local rho=sqrt(xx*xx+zz*zz)
      if rho<=1 then
        local tip=min(.45,size*.75/min(mass.rx,mass.rz))
        local r=max(0,(rho-tip)/(1-tip))
        local round=sqrt(max(0,1-r*r))
        local front=max(0,zz)
        if mass.radialDrape then front=r
        elseif mass.drapeX then
          front=max(0,xx*mass.drapeX+zz*mass.drapeZ)
        end
        local middle=mass.h-(mass.drape or 0)*front*front*r
        spans[#spans+1]={lower=middle-mass.lower*(mass.lowerCurvePower and round^mass.lowerCurvePower or round),materialQuarter=mass.quarter,
                        upper=middle+mass.upper*(mass.pointed and 1-r^.9 or round)}
      end
    end
    columns[vz*dims[1]+vx+1]={x=xp,z=zp,spans=spans}
  end end
  for vy=0,dims[2]-1 do
    local height=grid.height-(vy+.5)*size
    local canopyHeight=height-canopyOffset
    if height>=0 then for vx=0,dims[1]-1 do for vz=0,dims[3]-1 do
      local col=columns[vz*dims[1]+vx+1]
      local inside=false
      local undersideSpan
      for _,span in ipairs(col.spans)do
        if canopyHeight>=span.lower and canopyHeight<=span.upper then
          inside=true
          if not form.undersideMassReturn then break end
          -- Lowest containing span owns this union's downward boundary.
          if not undersideSpan or span.lower<undersideSpan.lower then undersideSpan=span end
        end
      end
      local stem=col.x*col.x+col.z*col.z<=form.rootRadius*form.rootRadius and height<=form.rootTop
      local index=(vz*dims[2]+vy)*dims[1]+vx+1
      if inside then
        local sy=form.artBase-canopyHeight*form.artVertical+abs(col.z)*form.artDepth
        local front=sourceAt(grid.width/2+col.x,sy,false)
        local aspect=grid.width/(2*grid.radius)
        local sideY=form.artBase-canopyHeight*form.artVertical+abs(col.x/aspect)*form.artDepth
        local side=sourceAt(grid.width/2+col.z*aspect,sideY,false)
        sources.projected[index]=front;sources.wrapped[index]=side
        -- Continue native top artwork toward the nearest cardinal side.
        -- Forest opts in; the legacy/General top channel stays unchanged.
        local top=front
        if form.cardinalTop and abs(col.x)>abs(col.z) then top=side end
        sources.top[index]=top
        local bottom=darkest or front
        if form.undersideMassReturn and undersideSpan then
          -- Continue the original mass's native leaf coat around its existing
          -- underside. Use that mass's local envelope, never another bough's
          -- top or a globally folded hem. Hidden texture return is inferred.
          local sampleHeight=undersideSpan.lower+(undersideSpan.upper-undersideSpan.lower)*form.undersideMassReturn
          local materialX,materialZ=col.x,col.z
          local quarter=undersideSpan.materialQuarter
          if quarter==1 then materialX,materialZ=-col.z,col.x
          elseif quarter==2 then materialX,materialZ=-col.x,-col.z
          elseif quarter==3 then materialX,materialZ=col.z,-col.x end
          local sideFacing=quarter==nil and abs(col.x)>abs(col.z)
          local u=sideFacing and (grid.width/2+col.z*aspect)or(grid.width/2+materialX)
          local depth=sideFacing and abs(col.x/aspect)or abs(materialZ)
          local v=form.artBase-sampleHeight*form.artVertical+depth*form.artDepth
          bottom=shadedNativeLeaf(sourceAt(u,v,false))or bottom
        end
        sources.bottom[index]=bottom
      elseif stem then
        local sample
        if height<form.stemVisible then
          sample=sourceAt(grid.width/2+col.x,grid.height-1-height/form.stemVisible*5,true)
        else sample=darkest end
        if sample then
          sources.projected[index]=sample;sources.wrapped[index]=sample
          sources.top[index]=sample;sources.bottom[index]=sample
        end
      end
    end end end
  end
  return sources,dims,radius
end

local function connectedTree(sources,dims)
  local cells=sources.projected
  local visited,largest={},{}
  local stride=dims[1]*dims[2]
  for seed in pairs(cells) do if not visited[seed] then
    local queue={seed};visited[seed]=true;local head=1
    local function visit(n) if cells[n] and not visited[n] then visited[n]=true;queue[#queue+1]=n end end
    while head<=#queue do
      local index=queue[head];head=head+1
      local k=index-1;local x=k%dims[1];local y=floor(k/dims[1])%dims[2];local z=floor(k/stride)
      if x>0 then visit(index-1) end;if x<dims[1]-1 then visit(index+1) end
      if y>0 then visit(index-dims[1]) end;if y<dims[2]-1 then visit(index+dims[1]) end
      if z>0 then visit(index-stride) end;if z<dims[3]-1 then visit(index+stride) end
    end
    if #queue>#largest then largest=queue end
  end end
  local keep={};for _,index in ipairs(largest) do keep[index]=true end
  local removed=0
  for index in pairs(cells) do if not keep[index] then
    for _,list in pairs(sources) do list[index]=nil end;removed=removed+1
  end end
  return removed
end

local function greedyFaces(keys,dims,face,slice)
  local axis,uAxis,vAxis=face.axis,face.u,face.v
  local width,height=dims[uAxis],dims[vAxis]
  local point={}
  local function keyAt()
    if point[1]<0 or point[2]<0 or point[3]<0 or point[1]>=dims[1] or point[2]>=dims[2] or point[3]>=dims[3] then return nil end
    return keys[(point[3]*dims[2]+point[2])*dims[1]+point[1]+1]
  end
  local mask={}
  for v=0,height-1 do
    for u=0,width-1 do
      point[axis],point[uAxis],point[vAxis]=slice,u,v
      local key=keyAt()
      if key then
        point[axis]=slice+face.step
        if not keyAt() then mask[v*width+u+1]=key end
      end
    end
  end
  local rects={}
  for v=0,height-1 do
    local u=0
    while u<width do
      local key=mask[v*width+u+1]
      if key then
        local across=1
        while u+across<width and mask[v*width+u+across+1]==key do across=across+1 end
        local down,grows=1,true
        while grows and v+down<height do
          for k=0,across-1 do
            if mask[(v+down)*width+u+k+1]~=key then grows=false;break end
          end
          if grows then down=down+1 end
        end
        for dv=0,down-1 do for k=0,across-1 do mask[(v+dv)*width+u+k+1]=nil end end
        rects[#rects+1]={u=u,v=v,across=across,down=down,key=key}
        u=u+across
      else u=u+1 end
    end
  end
  return rects
end

function M.build(atlas,model,size,backdrop)
  size=size or 1
  if model.compilerProfile=="general-tree" then return Compiled.build(atlas,size) end
  local grid=modelGrid(atlas,model,backdrop or Flora.KEY)
  splitShadow(grid)
  local ring=dropGroundRing(grid)
  local sources,dims,radius=volume(grid,size)
  local detached=connectedTree(sources,dims)
  local keys,looks={},{}
  for name,list in pairs(sources) do
    keys[name],looks[name]={},{}
    for index,pixelIndex in pairs(list) do
      local colour=grid.colour[pixelIndex]
      keys[name][index]=colour
      looks[name][colour]=looks[name][colour] or pixelIndex
    end
  end
  local foot=grid.height
  local bottomPlane=0
  for index in pairs(sources.projected) do bottomPlane=max(bottomPlane,floor((index-1)/dims[1])%dims[2]+1) end
  local lists,quads={under={},over={}},0
  local function corner(face,plane,u,v)
    local point={}
    point[face.axis],point[face.u],point[face.v]=plane,u,v
    -- Partial last voxels in the far LOD must end at the same ground anchor.
    local y=point[2]>=bottomPlane and 0 or max(0,foot-point[2]*size)
    return point[1]*size-grid.width/2,y,point[3]*size-radius*size
  end
  for _,face in ipairs(FACES) do
    local n=face.normal
    for slice=0,dims[face.axis]-1 do
      local plane=face.step>0 and slice+1 or slice
      for _,rect in ipairs(greedyFaces(keys[face.source],dims,face,slice)) do
        local pixelIndex=looks[face.source][rect.key]
        local source,lx,ly,layer=grid.source[pixelIndex],grid.lx[pixelIndex],grid.ly[pixelIndex],grid.layer[pixelIndex]
        local r=layer=="over" and source.overR or source.r
        local u=r[1]+(lx+0.5)/M.ART_PIXELS_PER_TILE*(r[3]-r[1])
        local v=r[2]+(ly+0.5)/M.ART_PIXELS_PER_TILE*(r[4]-r[2])
        local u0,u1,v0,v1=rect.u,rect.u+rect.across,rect.v,rect.v+rect.down
        local corners={{corner(face,plane,u0,v0)},{corner(face,plane,u1,v0)},{corner(face,plane,u1,v1)},{corner(face,plane,u0,v1)}}
        local verts=lists[layer]
        for _,i in ipairs({1,2,3,1,3,4}) do
          local c=corners[i]
          verts[#verts+1]={c[1],c[2],c[3],u,v,n[1],n[2],n[3]}
        end
        quads=quads+1
      end
    end
  end
  local ringColours={}
  for colour in pairs(ring) do ringColours[#ringColours+1]=string.format("%06x",colour) end
  table.sort(ringColours)
  return {under=lists.under,over=lists.over,quads=quads,tris=quads*2,pixels=grid.width,ring=ringColours,height=grid.height,
    trunk=grid.trunk,detached=detached}
end

local Context={};Context.__index=Context

function M.context(input)
  local models=M.models(input.atlas)
  if #models==0 then return nil end
  return setmetatable({input=input,models=models,trees={},stamps={}},Context)
end

local function placedStamp(stamp,scale)
  local layers={}
  for _,layer in ipairs({"under","over"}) do
    local out={}
    for i,v in ipairs(stamp[layer]) do out[i]={v[1]*scale,v[2]*scale,v[3]*scale,v[4],v[5],v[6],v[7],v[8],0,0,0,0,1} end
    layers[layer]=out
  end
  return {under=layers.under,over=layers.over,tris=stamp.tris,radius=stamp.pixels*scale/2,height=stamp.height*scale}
end

function Context:stamp(model,size,scale)
  local key=("%s@%d@%.4f"):format(model.name,size,scale)
  local cached=M.stampCache[self.input.pair]
  if not cached then cached={};M.stampCache[self.input.pair]=cached end
  if not cached[key] then
    self.backdrop=self.backdrop or M.backdrop(self.input,self.models)
    cached[key]=placedStamp(M.build(self.input.atlas,model,size,self.backdrop),scale)
  end
  self.stamps[key]=cached[key]
  return key
end

function Context:take(u,occ,foliage,lists)
  local model=M.modelFor(self.models,u.cells)
  local desc=model and foliage:_unit(u)
  if not desc then return false end
  for i,list in ipairs(lists) do
    for k=#list,u.frVoxelStarts[i]+1,-1 do list[k]=nil end
  end
  local scale=2*occ.r/desc.w
  self.trees[#self.trees+1]={x=occ.x,y=occ.y0,z=occ.z,near=self:stamp(model,M.NEAR_VOXEL,scale),
    far=self:stamp(model,M.FAR_VOXEL,scale)}
  return true
end

function Context:output()
  return {pair=self.input.pair,stamps=self.stamps,trees=self.trees}
end

return M
