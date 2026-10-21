-- Native FR artwork on EM17-style gently bowed, point-facing crown sheets.
-- No Emerald species tiles, Moss recolor, jitter, deep-row thinning, or head pose.
local V=...
local Flora=V.require("mesh/FrlgFlora")
local M={VERSION="fr-native-foliage 1"}
local floor=math.floor
local function leaf(v)
  if not v or v<0 or Flora.KEY[v] then return false end
  local r,g,b=floor(v/65536)%256,floor(v/256)%256,v%256
  return g>r and g>b
end
local function rect(atlas,mid,layer)
  if layer=="over" then
    if type(atlas.overRect)~="function" then return nil end
    local a,b,c,d=atlas.overRect(mid);if type(a)=="table" then return a end
    if d then return {a,b,c,d} end
  else
    if type(atlas.underRect)~="function" then return nil end
    local a,b,c,d=atlas.underRect(mid);if type(a)=="table" then return a end
    if d then return {a,b,c,d} end
  end
end
local function samples(ctx,mid,layer)
  local key=layer..mid
  if ctx.cache[key]~=nil then return ctx.cache[key] or nil end
  local ok,t=pcall(ctx.atlas.texels,mid,layer)
  if not(ok and type(t)=="table" and #t>=256) then ctx.cache[key]=false;return nil end
  ctx.cache[key]=t;return t
end
function M.new(env)
  local f,err=Flora.new(env);if not f then return nil,err end
  -- Flora.new owns a fresh constants table; prefer the validated native upper OVER tip.
  f.C.FLORA_C88_TIP_OVER=1
  return setmetatable({flora=f,atlas=env.atlas,newV=env.newV,opaque=env.opaque,
    keyed=env.cutoutKeyed or env.keyed,over=env.cutoutOver or env.over,
    at=env.at,pair=env.pair,forest3=env.forest3,cache={},unitCache=setmetatable({},{__mode="k"}),blobCache=setmetatable({},{__mode="k"}),
    stats={units=0,blobs=0,ownedTips=0,intentionalNoCrown=0,fallbackUnits=0,fallbackBlobs=0,treeTris=0,reasons={}}},{__index=M})
end
function M:_decline(reason)
  self.stats.reasons[reason]=(self.stats.reasons[reason] or 0)+1
end
local function hashPixels(t)
  if not t then return nil end
  local n=0;for i=1,256 do n=(n*131+t[i]+1)%4294967296 end;return n
end
local function crownEnd(d)
  local last=0
  for _,s in ipairs(d.sources) do for y=0,15 do for x=0,15 do
    local b=s.box;local v=s.t[y*16+x+1]
    if s.y+y<d.shadow and (not b or(x>=b[1] and x<b[3] and y>=b[2] and y<b[4]))
        and v and v>=0 and not Flora.KEY[v] then last=math.max(last,s.y+y+1) end
  end end end
  d.crownEnd=last;return d
end
-- Isolated native upper-side tiles separate this crown from baked neighboring
-- forest paint. The mask changes geometry ownership only; UV/color stay source.
function M:_forestMask(col,row)
  if row~=0 or (col~=1 and col~=3) then return nil end
  local mid=col==1 and 648 or 650;local key="forestMask"..mid
  if self.cache[key]~=nil then return self.cache[key] or false end
  local t=samples(self,mid,"under");if not t then self.cache[key]=false;return false end
  local authored
  if type(self.atlas.hasOver)=="function" then
    local ok,v=pcall(self.atlas.hasOver,mid);if not ok then self.cache[key]=false;return false end;authored=v==true
  else authored=rect(self.atlas,mid,"over")~=nil end
  local over=authored and samples(self,mid,"over") or nil
  if authored and not over then self.cache[key]=false;return false end
  local mask,n={},0
  for i=1,256 do
    local u,v=t[i],over and over[i]
    mask[i]=(u and u>=0 and not Flora.KEY[u]) and u or ((v and v>=0 and not Flora.KEY[v]) and v or -1)
    if mask[i]>=0 then n=n+1 end
  end
  if n==0 then self.cache[key]=false;return false end
  self.cache[key]=mask;return mask
end
function M:_forest(u)
  local f=self.forest3
  if type(f)~="table" or type(u.cells)~="table" then return nil end
  local d={w=48,h=36,foot=36,shadow=32,neckEnd=32,scale=1/16,sources={},height=36/16}
  local bounds=f.broad or Flora.BROAD
  for _,c in ipairs(u.cells) do
    local col=(f.upper or {})[c.mid];local row=0
    if not col then col=(f.lower or {})[c.mid];row=1 end
    local base=(f.base or {})[c.mid]
    if not col and base then
      local t=samples(self,c.mid,"under");local r=rect(self.atlas,c.mid,"under")
      if not(t and r) then return nil end
      if #u.cells>1 then
        d.baseCells=d.baseCells or {};d.baseCells[#d.baseCells+1]={cell=c,rect=r,col=base}
      else
      d.ax=c.x-(base-1)+1.5;d.az=c.y+.25;d.scale=1/16;d.h=36;d.foot=36;d.shadow=36
      d.baseCell=c;d.baseRect=r;d.baseCol=base
      if base==2 then
        local b=f.bark
        if not(b and b.mid==c.mid) then return nil end
        d.sources[1]={mid=c.mid,layer="under",t=t,r=r,x=16,y=32,
          box={b.u0*16,b.v0*16,b.u1*16,b.v1*16}}
      end
      return crownEnd(d)
      end
    elseif not col then return nil end
    if col then
    local mask=self:_forestMask(col,row);if mask==false then return nil end
    if not u.forest3 then
      if #u.cells~=1 then return nil end
      d.ax=c.x-(col-1)+1.5;d.az=c.y-row+36/16;d.partial=true
    end
    -- Native hasOver is authoritative: an absent authored layer is not a missing
    -- resource. All original UNDER is keyed; blank grass centres stay transparent.
    local rt=samples(self,c.mid,"under");local rr=rect(self.atlas,c.mid,"under")
    if not(rt and rr) then return nil end
    local expectedOver
    if type(self.atlas.hasOver)=="function" then
      local ok,v=pcall(self.atlas.hasOver,c.mid);if not ok then return nil end;expectedOver=v==true
    else expectedOver=rect(self.atlas,c.mid,"over")~=nil end
    for _,layer in ipairs({"under","over"}) do
      if layer=="under" or expectedOver then
        local r=rect(self.atlas,c.mid,layer);local t=samples(self,c.mid,layer)
        if not(r and t) then return nil end
        local box
        -- Whole native keyed hem belongs on the sheet; volumetric body crops omit it.
        d.sources[#d.sources+1]={mid=c.mid,layer=layer,t=t,r=r,x=(col-1)*16,y=row*16,box=box,mask=mask}
      end
    end
    end
  end
  if #d.sources==0 then return nil end
  -- Berry crown peaks are native OVER in the source row above the formed unit.
  local first=u.cells[1]
  local centrePartial=d.partial and first and (f.upper or {})[first.mid]==2
  if (u.forest3 or centrePartial) and type(self.at)=="function" then
    local fx,fy=u.forest3 and u.x or d.ax-1.5,u.forest3 and u.y or d.az-36/16
    for col=0,2 do local c=self.at(fx+col,fy-1)
      local nativePair=self.pair=="general__rom_082d4dc4"
      local knownPeak=c and nativePair and (c.mid==641 or c.mid==643 or c.mid==644 or c.mid==646 or c.mid==647)
      local peakHash=c and nativePair and hashPixels(samples(self,c.mid,"over"))
      -- Known authored peaks remain required even if their layer goes missing;
      -- absence must reject takeover rather than silently erase source artwork.
      if knownPeak and peakHash~=608291524 then return nil end
      local exactPeak=nativePair and peakHash==608291524
      if c and ((f.tips and f.tips[c.mid]) or knownPeak or exactPeak) then
        local t=samples(self,c.mid,"over");local r=rect(self.atlas,c.mid,"over")
        if not(t and r) then return nil end
        d.sources[#d.sources+1]={mid=c.mid,layer="over",t=t,r=r,x=col*16,y=-16}
        -- Same build-local ownership as the mesher's formed-unit tip seam;
        -- native UNDER terrain/warp flags are untouched.
        d.peakCells=d.peakCells or {};d.peakCells[#d.peakCells+1]=c
        d.height=52/16
      end
    end
  end
  -- Connected forest body variants include neighboring canopy behind their
  -- upper corners but omit the isolated native centre crest. Restore the exact
  -- same-pair authored crest only for a complete frame or its central owner.
  if (u.forest3 or centrePartial) and (self.pair=="general__rom_082d4dc4" or self.pair=="general__rom_082d5004") then
    local hasCentre=false
    for _,s in ipairs(d.sources)do if s.layer=="over" and s.x==16 and s.y==-16 then hasCentre=true end end
    if not hasCentre then
      local t=samples(self,641,"over");local r=rect(self.atlas,641,"over")
      local expected=self.pair=="general__rom_082d5004" and 3785212196 or 608291524
      if not(t and r) or hashPixels(t)~=expected then return nil end
      d.sources[#d.sources+1]={mid=641,layer="over",t=t,r=r,x=16,y=-16,canonicalCrest=true}
      d.height=52/16
    end
  end
  -- Commit only after every requested peak resource passed validation.
  for _,c in ipairs(d.peakCells or {})do c.suppressDecal=true end
  -- Full units get one native stem; partial source panels never invent another trunk.
  if u.forest3 then local a=self.flora:broadArt();if a and a.bark then d.art=a;d.trunk={26,31} end end
  return crownEnd(d)
end
function M:_unit(u)
  local known=self.unitCache[u];if known~=nil then return known or nil end
  if u.noCrown then self.stats.intentionalNoCrown=self.stats.intentionalNoCrown+1;self.unitCache[u]=false;return nil end
  if type(self.atlas.texels)~="function" then self:_decline("missing-texels");self.unitCache[u]=false;return nil end
  -- c88Art validates source samples in the immutable pair, preventing house-ID aliases.
  if u.forest3 or (self.forest3 and u.cells and u.cells[1] and
      ((self.forest3.upper or {})[u.cells[1].mid] or (self.forest3.lower or {})[u.cells[1].mid] or (self.forest3.base or {})[u.cells[1].mid])) then
    local d=self:_forest(u)
    if d then self.unitCache[u]=d;return d end
    self:_decline("unvalidated-forest-source");self.unitCache[u]=false;return nil
  end
  local a=self.flora:c88Art()
  if not a or not a.tip then self:_decline("unvalidated-native-tree");self.unitCache[u]=false;return nil end
  local desc={w=32,h=48,sources={},shadow=a.shadowRow or 48,trunk=a.trunkRows,art=a,roundHem=true}
  for row=0,2 do
    local mids=row==0 and (a.mids.tip or {14,15}) or(row==1 and a.mids.top or a.mids.bot)
    local layer=row==0 and(a.tipLayer or "under") or "under"
    for col=0,1 do
      local t=samples(self,mids[col+1],layer);local r=rect(self.atlas,mids[col+1],layer)
      if not(t and r) then self:_decline("missing-tree-layer");self.unitCache[u]=false;return nil end
      desc.sources[#desc.sources+1]={mid=mids[col+1],layer=layer,t=t,r=r,x=col*16,y=row*16}
    end
  end
  if desc.trunk then
    desc.foot=desc.trunk[2]+1
    local lo,hi=32,-1
    for _,q in ipairs(desc.sources) do if q.y==32 then
      for y=desc.trunk[1]-32,desc.trunk[2]-32 do for x=0,15 do
        local v=q.t[y*16+x+1]
        if v and v>=0 and not Flora.KEY[v] and floor(v/65536)%256>=floor(v/256)%256 then
          lo=math.min(lo,q.x+x);hi=math.max(hi,q.x+x)
        end
      end end
    end end
    if hi>=lo then desc.barkWidth=hi-lo+1 end
  end
  crownEnd(desc);self.unitCache[u]=desc;return desc
end
function M:canUnit(u)
  local fresh=self.unitCache[u]==nil;local d=self:_unit(u)
  if fresh and not d and not u.noCrown then self.stats.fallbackUnits=self.stats.fallbackUnits+1 end
  return d~=nil
end
function M:_forestMixed(c)
  if self.pair~="general__rom_082d4dc4" or not self.forest3 or type(self.at)~="function" then return nil end
  local hU,hO=hashPixels(samples(self,c.mid,"under")),hashPixels(samples(self,c.mid,"over"))
  local kind=hU==3904785307 and hO==1175618853 and 1 or(hU==3334185508 and hO==40072845 and 2)
  if not kind then return nil end
  local f=self.forest3;local x,y=c.x,c.y-(kind-1)
  local function role(px,py,which,col)
    local a=self.at(px,py);return a and (not c.hgt or not a.hgt or math.abs(a.hgt-c.hgt)<1e-9) and (f[which] or {})[a.mid]==col
  end
  -- Actual A/B neighbouring original source frames, not a generic donor tree.
  if not(role(x-2,y-1,"upper",1) and role(x-1,y-1,"upper",2) and role(x,y-1,"upper",3)
    and role(x-2,y,"lower",1) and role(x-1,y,"lower",2)
    and role(x+1,y,"upper",2) and role(x+2,y,"upper",3)
    and role(x+1,y+1,"lower",2) and role(x+2,y+1,"lower",3)) then return nil end
  local function part(layer,sx,sy,fx,fy)
    local r=rect(self.atlas,c.mid,layer);local t=samples(self,c.mid,layer);if not(r and t) then return nil end
    local mask=self:_forestMask(sx/16+1,sy/16);if mask==false then return nil end
    return {w=48,h=36,foot=36,shadow=32,neckEnd=32,crownEnd=32,ax=fx+1.5,az=fy+36/16,
      sources={{mid=c.mid,layer=layer,t=t,r=r,x=sx,y=sy,mask=mask}}}
  end
  local d={forestParts={}}
  if kind==1 then local a=part("under",32,16,x-2,y-1);if not a then return nil end;d.forestParts[1]=a end
  local b=part("over",0,(kind-1)*16,x,y);if not b then return nil end;d.forestParts[#d.forestParts+1]=b
  if kind==2 then d.forestGround=true end
  for _,a in ipairs(d.forestParts)do if not a then return nil end end
  return d
end
function M:_forestTip(c)
  if not self.forest3 or type(self.at)~="function" then return nil end
  local t=samples(self,c.mid,"over");if not t then return nil end
  local known=(self.forest3.tips or {})[c.mid]
    or(self.pair=="general__rom_082d4dc4" and hashPixels(t)==608291524)
  if not known then return nil end
  local below=self.at(c.x,c.y+1);local u=below and below.unit
  if not u then return nil end
  local d=self:_unit(u);if not d then return nil end
  for _,s in ipairs(d.sources)do if s.y==-16 and s.layer=="over" and s.mid==c.mid then
    local same=true;for i=1,256 do if s.t[i]~=t[i]then same=false;break end end
    if same then return {ownedTip=true,unit=u} end
  end end
end
function M:_blob(c)
  local known=self.blobCache[c];if known~=nil then return known or nil end
  if type(self.atlas.texels)~="function" then self.blobCache[c]=false;return nil end
  local ft=self:_forestTip(c);if ft then self.blobCache[c]=ft;return ft end
  local mixed=self:_forestMixed(c);if mixed then self.blobCache[c]=mixed;return mixed end
  local donor=c.nativeB14LeafDonor or c.nativeR16LeafDonor or c.nativeSharedLeafDonor
  -- A mixed rail's true OVER leaf pixels belong to the source cell; never stretch a whole tree.
  if (donor or c.hasOver) and type(self.at)=="function" then
    local below=self.at(c.x,c.y+1);local u=below and below.unit
    if u and u.w==2 and (u.h or u.w)==2 and u.y==c.y+1 and c.x>=u.x and c.x<u.x+2 then
      local d=self:_unit(u)
      if d and not d.height then
        local expected=d.sources[c.x-u.x+1]
        local actual=samples(self,c.mid,"over")
        local same=actual and expected and expected.layer=="over"
        if same then for i=1,256 do if actual[i]~=expected.t[i] then same=false;break end end end
        if same then
          local tip={ownedTip=true,unit=u};self.blobCache[c]=tip;return tip
        end
      end
    end
  end
  local mid=c.mid;local layer=(donor or c.hasOver) and "over" or "under"
  local t=samples(self,mid,layer);local r=rect(self.atlas,mid,layer)
  if not(t and r) then self:_decline("missing-blob-layer");self.blobCache[c]=false;return nil end
  local n=0
  for i=1,256 do if leaf(t[i]) then n=n+1 end end
  if n<8 then self:_decline("no-native-leaf-silhouette");self.blobCache[c]=false;return nil end
  local shadow=16
  if layer=="under" and (mid==20 or mid==21 or mid==36 or mid==37 or mid==38 or mid==39) then
    local a=self.flora:c88Art();if a and a.shadowRow then shadow=math.max(0,a.shadowRow-32) end
  end
  local bottom=0
  for y=0,shadow-1 do for x=0,15 do
    local v=t[y*16+x+1];if v and v>=0 and not Flora.KEY[v] then bottom=y+1 end
  end end
  local d={w=16,h=16,foot=bottom,shadow=shadow,sources={{mid=mid,layer=layer,t=t,r=r,x=0,y=0}},pixels=n}
  local role=donor or mid
  if (role==20 or role==21) and type(self.at)=="function" then
    local neighbor=self.at(c.x+(role==20 and 1 or -1),c.y)
    local other=neighbor and (neighbor.nativeB14LeafDonor or neighbor.nativeR16LeafDonor or neighbor.nativeSharedLeafDonor or neighbor.mid)
    if other==(role==20 and 21 or 20) then
      d.w=32;d.sources[1].x=role==20 and 0 or 16;d.anchorX=c.x+(role==20 and 1 or 0)
      local nt=samples(self,neighbor.mid,layer)
      if nt then for y=0,shadow-1 do for x=0,15 do
        local v=nt[y*16+x+1];if v and v>=0 and not Flora.KEY[v] then d.foot=math.max(d.foot,y+1) end
      end end end
    end
  end
  self.blobCache[c]=d;return d
end
function M:canBlob(c)
  local fresh=self.blobCache[c]==nil;local d=self:_blob(c)
  if fresh and not d then self.stats.fallbackBlobs=self.stats.fallbackBlobs+1 end
  return d~=nil
end
local function quad(ctx,list,x0,x1,y00,y01,y10,y11,z0,z1,zb0,zb1,u0,v0,u1,v1,ax,az)
  local a=ctx.newV(x0,y10,z0,u0,v0,0,1,0);local b=ctx.newV(x1,y11,z1,u1,v0,0,1,0)
  local c=ctx.newV(x1,y01,zb1,u1,v1,0,1,0);local d=ctx.newV(x0,y00,zb0,u0,v1,0,1,0)
  local anchor={ax,az};a.frTree=anchor;b.frTree=anchor;c.frTree=anchor;d.frTree=anchor
  local n=#list;list[n+1],list[n+2],list[n+3],list[n+4],list[n+5],list[n+6]=a,b,c,a,c,d
end
function M:_sheet(desc,ax,az,gy,scale,trunked)
  local tris=0
  for _,s in ipairs(desc.sources) do
    local list=s.layer=="over" and self.over or self.keyed
    local rectangles,active={},{}
    for y=0,15 do
      local sy=s.y+y
      if sy==28 or sy==(desc.neckEnd or desc.crownEnd or desc.shadow)-2 then active={} end
      local seen={};local x=0
      while x<16 and s.y+y<desc.shadow do
        local box=s.box
        local function occupied(px)
          local v=s.t[y*16+px+1]
          local inside=not box or(px>=box[1] and px<box[3] and y>=box[2] and y<box[4])
          if s.mask then
            local mv=s.mask[y*16+px+1]
            if not mv or mv<0 or Flora.KEY[mv] then return false end
          end
          -- Existing keyed/alpha textures discard empty pixels. Keep the curved lower
          -- occupancy geometry unchanged, but use coherent planar upper bands.
          if inside and sy<(desc.neckEnd or desc.crownEnd or desc.shadow)-2 and (not desc.roundHem or sy<28) then return true end
          return inside and v and v>=0 and not Flora.KEY[v]
        end
        if occupied(x) then
          local last=x+1
          -- Split only at the gentle bend's centre; all interior paint remains original.
          local limit=trunked and math.min(16,desc.w/2-s.x) or 16
          if limit<=x then limit=16 end
          if desc.roundHem and sy>=28 then limit=math.min(limit,x+2) end
          while last<limit and occupied(last) do last=last+1 end
          local key=x*32+last;local r=active[key]
          if r and r[4]==y then r[4]=y+1 else r={x,y,last,y+1};rectangles[#rectangles+1]=r end
          seen[key]=r;x=last
        else x=x+1 end
      end
      active=seen
    end
    for _,r in ipairs(rectangles) do
      local native0,native1=s.x+r[1],s.x+r[3]
      local x0=ax+(native0-desc.w/2)*scale;local x1=ax+(native1-desc.w/2)*scale
      local function height(srcY,nativeX)
        if desc.roundHem and srcY>28 then
          local q=(nativeX-desc.w/2)/(desc.w/2)
          local last=35+6*math.sqrt(math.max(0,1-q*q))
          srcY=28+(srcY-28)*(last-28)/(desc.shadow-28)
        end
        return gy+((desc.foot or desc.h)-srcY)*scale
      end
      local y10,y11=height(s.y+r[2],native0),height(s.y+r[2],native1)
      local y00,y01=height(s.y+r[4],native0),height(s.y+r[4],native1)
      local function z(px,sy)
        if not trunked then return az+.06 end
        local radius=(desc.barkWidth and desc.barkWidth*scale*.5 or math.max(scale,self.flora.C.FLORA_TRUNK_W or .11))/math.cos(math.pi/8)
        local base=radius+.04-.08*math.abs((px-desc.w/2)*scale)
        -- Native baked-shadow removal may precede the visible bark row: close that junction.
        local endY=desc.neckEnd or desc.crownEnd or desc.shadow
        local k=math.max(0,math.min(1,(sy-(endY-2))/2))
        return az+base*(1-k)+radius*k
      end
      local du,dv=(s.r[3]-s.r[1])/16,(s.r[4]-s.r[2])/16
      quad(self,list,x0,x1,y00,y01,y10,y11,z(native0,s.y+r[2]),z(native1,s.y+r[2]),z(native0,s.y+r[4]),z(native1,s.y+r[4]),
        s.r[1]+r[1]*du,s.r[2]+r[2]*dv,
        s.r[1]+r[3]*du,s.r[2]+r[4]*dv,ax,az)
      tris=tris+2
    end
  end
  return tris
end
function M:unit(u,gy)
  local d=self:_unit(u);if not d then return false end
  local ax,az=d.ax or u.x+u.w*.5,d.az or (u.forest3 and u.y+36/16 or u.y+(u.h or u.w)*.5)
  local h=d.height or self.flora.C.FLORA_CONIFER_H or 2.8
  if u.single and not d.partial and not d.baseCell then h=h*(self.flora.C.FLORA_SINGLE or .6) end
  local scale=d.scale or h/(d.height and d.h or 45)
  local n=self:_sheet(d,ax,az,gy,scale,true)
  if d.baseCell or d.baseCells then
    -- Native ground shadow is retained as a keyed horizontal decal, not upright foliage.
    local bases=d.baseCells or {{cell=d.baseCell,rect=d.baseRect,col=d.baseCol}}
    for _,base in ipairs(bases)do
    local c,r=base.cell,base.rect;local boxes={{0,0,16,16}}
    if base.col==2 then local b=self.forest3.bark;boxes={{0,0,b.u0*16,b.v1*16},{b.u1*16,0,16,b.v1*16},{0,b.v1*16,16,16}} end
    for _,b in ipairs(boxes)do
      local du,dv=(r[3]-r[1])/16,(r[4]-r[2])/16
      local a=self.newV(c.x+b[1]/16,gy+.006,c.y+b[2]/16,r[1]+b[1]*du,r[2]+b[2]*dv,0,1,0)
      local z=self.newV(c.x+b[3]/16,gy+.006,c.y+b[2]/16,r[1]+b[3]*du,r[2]+b[2]*dv,0,1,0)
      local v=self.newV(c.x+b[3]/16,gy+.006,c.y+b[4]/16,r[1]+b[3]*du,r[2]+b[4]*dv,0,1,0)
      local w=self.newV(c.x+b[1]/16,gy+.006,c.y+b[4]/16,r[1]+b[1]*du,r[2]+b[4]*dv,0,1,0)
      local list=self.keyed;local k=#list;list[k+1],list[k+2],list[k+3],list[k+4],list[k+5],list[k+6]=a,v,z,a,w,v;n=n+2
    end
    end
  end
  local trunk=false
  if d.trunk then
    local top=gy+((d.foot or d.h)-(d.roundHem and d.trunk[1] or d.crownEnd or d.shadow))*scale
    local radius=(d.barkWidth and d.barkWidth*scale*.5 or math.max(scale,self.flora.C.FLORA_TRUNK_W or .11))/math.cos(math.pi/8)
    local uv=d.art.bark;local list=self.opaque;local nv=self.newV
    for k=0,7 do
      local a,b=k*math.pi/4,(k+1)*math.pi/4
      local nx,nz=math.cos((a+b)/2),math.sin((a+b)/2)
      local p=nv(ax+radius*math.cos(a),gy,az+radius*math.sin(a),uv[1],uv[4],nx,0,nz)
      local q=nv(ax+radius*math.cos(b),gy,az+radius*math.sin(b),uv[3],uv[4],nx,0,nz)
      local r=nv(q[1],top,q[3],uv[3],uv[2],nx,0,nz);local s=nv(p[1],top,p[3],uv[1],uv[2],nx,0,nz)
      local i=#list;list[i+1],list[i+2],list[i+3],list[i+4],list[i+5],list[i+6]=p,q,r,p,r,s;n=n+2
    end
    trunk=true
  end
  self.stats.units=self.stats.units+1;self.stats.treeTris=self.stats.treeTris+n
  return true,{x=ax,z=az,r=d.w*scale*.5,y0=gy,y1=gy+h},trunk,n
end
function M:blob(c,gy)
  local d=self:_blob(c);if not d then return false end
  if d.forestParts then
    local n=0;for _,part in ipairs(d.forestParts)do n=n+self:_sheet(part,part.ax,part.az,gy,1/16,true) end
    if d.forestGround then
      local r=rect(self.atlas,c.mid,"under");local nv=self.newV;local y=gy+.006
      local a=nv(c.x,y,c.y,r[1],r[2],0,1,0);local b=nv(c.x+1,y,c.y,r[3],r[2],0,1,0)
      local z=nv(c.x+1,y,c.y+1,r[3],r[4],0,1,0);local w=nv(c.x,y,c.y+1,r[1],r[4],0,1,0)
      local l=self.keyed;local k=#l;l[k+1],l[k+2],l[k+3],l[k+4],l[k+5],l[k+6]=a,z,b,a,w,z;n=n+2
    end
    self.stats.blobs=self.stats.blobs+1;self.stats.treeTris=self.stats.treeTris+n;return true,n
  end
  if d.ownedTip then self.stats.ownedTips=self.stats.ownedTips+1;return true,0 end
  local n=self:_sheet(d,d.anchorX or c.x+.5,c.y+.5,gy,1/16,false)
  self.stats.blobs=self.stats.blobs+1;self.stats.treeTris=self.stats.treeTris+n
  return true,n
end
return M
