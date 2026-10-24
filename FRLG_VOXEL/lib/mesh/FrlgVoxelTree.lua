local V=...
local Flora=V.require("mesh/FrlgFlora")
local Models=V.require("mesh/FrlgTreeModels")
local M={VERSION="fr-voxel-tree 1"}

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
  {axis=2,step=-1,u=1,v=3,source="projected",normal={0,1,0}},
  {axis=2,step=1,u=1,v=3,source="wrapped",normal={0,-1,0}},
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
    if M.fingerprint(atlas,model.fingerprint.mid)==model.fingerprint.hash then found[#found+1]=model end
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
  local grid={width=width,height=#rows,colour={},source={},lx={},ly={},layer={},radius=model.radius,bodyTop=#rows}
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
  local width,trunk=grid.width,{}
  local outline=trunkOutline(grid,bottom)
  for py=bottom+1,grid.height-1 do
    for px=0,width-1 do
      local colour=grid.colour[py*width+px+1]
      if colour and not isGreen(colour) and not outline[colour] then
        trunk[px]=trunk[px] or {top=py,bottom=py}
        trunk[px].bottom=py
      end
    end
  end
  if next(trunk)==nil then return end
  local artLength=0
  for _,column in pairs(trunk) do artLength=max(artLength,column.bottom-column.top+1) end
  local trunkLength=artLength+M.TRUNK_EXTRA_PIXELS
  local copy={colour={},source={},lx={},ly={},layer={}}
  for key,list in pairs(copy) do for index,value in pairs(grid[key]) do list[index]=value end end
  for py=bottom+1,max(grid.height-1,bottom+trunkLength) do
    for px=0,width-1 do
      local index,column=py*width+px+1,trunk[px]
      local step=py-bottom-1
      local from=column and step<trunkLength and min(column.top+floor(step*artLength/trunkLength),column.bottom)
      if from then
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
  grid.trunk={art=artLength,shown=trunkLength,columns=columns,outline=outlineColours}
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

local function litColumn(shades,dx,dz)
  local length=sqrt(dx*dx+dz*dz)
  local facing=length>0 and (dx*M.LIGHT[1]+dz*M.LIGHT[2])/length or 0
  local index=floor((facing+1)/2*#shades)+1
  return shades[max(1,min(#shades,index))].column
end

local function volume(grid,size)
  local inset=floor(size/2)
  local radius=grid.radius/size
  local dims={ceil(grid.width/size),ceil(grid.height/size),ceil(2*radius)}
  local axis=dims[1]/2
  local function pixel(vx,vy) return (vy*size+inset)*grid.width+vx*size+inset+1 end
  local function solidAt(vx,vy) return grid.colour[pixel(vx,vy)]~=nil end
  local halves={}
  for vy=0,dims[2]-1 do
    halves[vy]=0
    for vx=0,dims[1]-1 do
      if solidAt(vx,vy) then halves[vy]=max(halves[vy],abs(vx+0.5-axis)+0.5) end
    end
  end
  local depths=filledProfile(halves,dims[2],M.PROFILE_ROWS)
  local sources={wrapped={},projected={}}
  for vy=0,dims[2]-1 do
    local half=halves[vy]
    if half>0 then
      local shades,nearest={},{}
      for vx=0,dims[1]-1 do
        if solidAt(vx,vy) then shades[#shades+1]={column=vx,light=brightness(grid.colour[pixel(vx,vy)])} end
      end
      table.sort(shades,function(a,b) if a.light~=b.light then return a.light<b.light end return a.column<b.column end)
      for vx=0,dims[1]-1 do
        nearest[vx]=vx
        for step=0,dims[1] do
          if vx-step>=0 and solidAt(vx-step,vy) then nearest[vx]=vx-step;break end
          if vx+step<dims[1] and solidAt(vx+step,vy) then nearest[vx]=vx+step;break end
        end
      end
      local halfDepth=min(depths[vy],radius)
      for column=max(0,floor(axis-half)),min(dims[1]-1,ceil(axis+half)-1) do
        local dx=(column+0.5-axis)/half
        for vz=0,dims[3]-1 do
          local dz=(vz+0.5-radius)/halfDepth
          if dx*dx+dz*dz<=1 then
            local index=(vz*dims[2]+vy)*dims[1]+column+1
            local wrapped=litColumn(shades,dx,dz)
            sources.wrapped[index]=pixel(wrapped,vy)
            sources.projected[index]=abs(dz)>=M.FACING_SPREAD*abs(dx) and pixel(nearest[column],vy) or pixel(wrapped,vy)
          end
        end
      end
    end
  end
  return sources,dims,radius
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
  local grid=modelGrid(atlas,model,backdrop or Flora.KEY)
  splitShadow(grid)
  local ring=dropGroundRing(grid)
  local sources,dims,radius=volume(grid,size)
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
  local lists,quads={under={},over={}},0
  local function corner(face,plane,u,v)
    local point={}
    point[face.axis],point[face.u],point[face.v]=plane,u,v
    return point[1]*size-grid.width/2,foot-point[2]*size,point[3]*size-radius*size
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
    trunk=grid.trunk}
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
