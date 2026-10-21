-- Native FR/LG lateral stair assemblies. Never edits raw map collision,
-- warp coordinates or native elevation tags. Exact PC landing plans also
-- align the renderer heightAt with the corrected visual floor.
local M = { VERSION = 'native-stairs-flush-20261004' }
-- dx/dy are measured from the native warp mouth. Require every tile to match:
-- a near-warp solid is NOT sufficient evidence for claiming another prop.
local PROFILES = {
 {name='house_up',pair='player_house',anchor=29,beh=0x6C,ox=1,oy=-1,w=2,h=3,
  mids={{22,23},{30,31},{38,39}},kind='stairs',rise=1.35,high='east',down=false},
 {name='house_down',pair='player_house',anchor=7,beh=0x6F,ox=-2,oy=0,w=2,h=2,
  mids={{5,6},{13,14}},kind='stairs',rise=1.35,high='east',down=true},
 {name='center_up',pair='network',anchor=729,beh=0x6A,ox=-1,oy=-1,w=2,h=3,
  mids={{720,721},{728,729},{736,737}},kind='escalator',rise=1.15,high='west',down=false},
 {name='center_down',pair='network',anchor=740,beh=0x6B,ox=-1,oy=-1,w=2,h=3,
  mids={{731,732},{739,740},{747,748}},kind='escalator',rise=1.15,high='east',down=true},
}
M.PROFILES=PROFILES
-- at(x,y) returns mesher cell {mid,beh,...}; no mutation here.
function M.find(pair,W,H,at)
 local out={}
 for y=0,H-1 do for x=0,W-1 do
  local c=at(x,y)
  if c then for _,p in ipairs(PROFILES) do
   if pair==p.pair and c.mid==p.anchor and c.beh==p.beh then
    local ok=true;local cells={}
    for dy=0,p.h-1 do for dx=0,p.w-1 do
     local q=at(x+p.ox+dx,y+p.oy+dy)
     if not q or q.mid~=p.mids[dy+1][dx+1] then ok=false end
     cells[#cells+1]=q
    end end
    if ok then out[#out+1]={profile=p,x=x+p.ox,y=y+p.oy,anchor=c,cells=cells} end
   end
  end end
 end end
 return out
end
-- Exact native PC landing tags are collision-layer selectors, not raised floor.
-- Return a fail-closed render correction plan; never mutate source cells here.
function M.landingPlan(a,at,mapId,unit)
 local p=a.profile
 if p.pair~='network' then return nil end
 local anchor=a.anchor;local ax,ay=a.x+1,a.y+1
 unit=unit or .25;local from,to=4*unit,3*unit
 if anchor.elev~=4 or anchor.coll~=114 or anchor.hgt~=from then return nil end
 local island=mapId=='SEVII_ONE_ISLAND_POKECENTER' and p.name=='center_up'
 local signature={{0,0,p.anchor,4,114},{-1,0,p.down and 739 or 728,0,7},
  {1,0,641,4,0},{1,-1,island and 675 or 641,0,0},{1,1,641,0,0},{2,0,641,0,0}}
 if island then signature[#signature+1]={1,-2,697,0,7} end
 local cells,allowed={},{}
 for _,r in ipairs(signature)do
  local c=at(ax+r[1],ay+r[2])
  if not c or c.mid~=r[3] or c.elev~=r[4] or c.coll~=r[5] or c.hgt~=from then return nil end
  cells[#cells+1]=c;allowed[c]=true
 end
 -- Top and bottom native art rows prove the surrounding platform's datum.
 for _,dy in ipairs({-1,1})do for dx=-1,0 do
  local c=at(ax+dx,ay+dy)
  if not c or c.elev~=3 or c.coll~=0 or c.hgt~=to then return nil end
 end end
 -- Refuse an unexpectedly larger connected raised component.
 local queue,seen={anchor},{[anchor]=true};local i=1
 while queue[i]do
  local c=queue[i];i=i+1
  if not allowed[c]then return nil end
  for _,d in ipairs({{-1,0},{1,0},{0,-1},{0,1}})do
   local n=at(c.x+d[1],c.y+d[2])
   if n and n.hgt==from and not seen[n]then seen[n]=true;queue[#queue+1]=n end
  end
 end
 if #queue~=#cells then return nil end
 return {cells=cells,from=from,to=to,island=island,profile=p.name}
end
-- Shared body/floor-cut contract. Rails lie 0.095 cells outside the central
-- tread. A 0.10 shoulder supports them on upward flights and keeps downward
-- rails inside the opening; retaining walls end exactly at the floor cut.
-- Downward opening bounds are unchanged. No adjacent tile is claimed.
function M.bounds(a,originX,originZ)
 local x=(originX or 0)+a.x;local z=(originZ or 0)+a.y
 local z0=z+(a.profile.h==3 and 1 or 0)+.18;local z1=z0+.82
 local margin=.10
 return {x0=x,x1=x+2,z0=z0,z1=z1,openingZ0=z0-margin,openingZ1=z1+margin}
end
-- ctx.emitQuad(points,mid,layer,uvrect,normal): points TL,TR,BR,BL;
-- uvrect={u0,v0,u1,v1} in local TILE fractions, layer='under' or 'over'.
-- PC top-row rail/panel donors are OVER art on floor tiles721/732;
-- middle-row tread donors729/740 are UNDER. Never sample composite-only
-- color coordinates from the wrong atlas page.
-- ctx.ground is the anchor's render ground in cell units; ctx.originX/Z optional.
-- Points are already map-world cell coordinates. Caller scales as usual.
function M.emit(a,ctx)
 local p=a.profile;local g=ctx.ground or 0
 local ox=(ctx.originX or 0)+a.x;local oz=(ctx.originZ or 0)+a.y
 local function sample(px,py)
  px=math.max(0,math.min(31,px));py=math.max(0,math.min(p.h*16-1,py))
  local tx,ty=math.floor(px/16),math.floor(py/16)
  return p.mids[ty+1][tx+1],{(px%16+.1)/16,(py%16+.1)/16,(px%16+.9)/16,(py%16+.9)/16}
 end
 local function q(pts,px,py,n,layer)
  local mid,uv=sample(px,py);ctx.emitQuad(pts,mid,layer or 'under',uv,n)
 end
 -- Preserve native multi-texel artwork on treads, splitting UVs at atlas-tile
 -- boundaries rather than stretching one sampled color over an entire stair.
 local function patch(pts,x0,y0,x1,y1,normal,layer)
  y0=math.max(0,y0);y1=math.min(p.h*16,y1)
  if y1<=y0 then return end
  local function lerp(u,v)
   local out={}
   for k=1,3 do out[k]=(1-v)*((1-u)*pts[1][k]+u*pts[2][k])+v*((1-u)*pts[4][k]+u*pts[3][k]) end
   return out
  end
  local yy=y0
  while yy<y1 do
   local ey=math.min(y1,(math.floor(yy/16)+1)*16);local xx=x0
   while xx<x1 do
    local ex=math.min(x1,(math.floor(xx/16)+1)*16)
    local u0,u1=(xx-x0)/(x1-x0),(ex-x0)/(x1-x0)
    local v0,v1=(yy-y0)/(y1-y0),(ey-y0)/(y1-y0)
    local tx,ty=math.floor(xx/16),math.floor(yy/16)
    local uv={(xx-tx*16+.02)/16,(yy-ty*16+.02)/16,(ex-tx*16-.02)/16,(ey-ty*16-.02)/16}
    ctx.emitQuad({lerp(u0,v0),lerp(u1,v0),lerp(u1,v1),lerp(u0,v1)},p.mids[ty+1][tx+1],layer or 'under',uv,normal)
    xx=ex
   end
   yy=ey
  end
 end
 local bounds=M.bounds(a,ctx.originX,ctx.originZ)
 local z0,z1=bounds.z0,bounds.z1
 local edge0,edge1=bounds.openingZ0,bounds.openingZ1
 local n=8;local heights={}
 for i=0,n do
  local t=i/n
  if p.high=='west' then t=1-t end
  heights[i]=g+p.rise*t-(p.down and p.rise or 0)
 end
 -- Eight discrete treads; directional reversal uses heights, never mirrored UVs.
 for i=0,n-1 do
  local x0=ox+i*2/n;local x1=ox+(i+1)*2/n
  local h=math.max(heights[i],heights[i+1]);local base=p.down and h or g
  local sideTop=p.down and g or h
  local px=i*4+2
  local sy
  if p.kind=='stairs' then
   sy=p.down and (15-math.floor(px/4)*2) or (14-math.floor(px/4)*2)
  else sy=20 end
  if p.kind=='escalator' then
   -- The neutral eastern landing has the same step material without the
   -- one-view diagonal rail. Reuse that native stripe patch on each tread;
   -- sampling across the original sloped silhouette bakes mint/red onto it.
   patch({{x0,h,edge0},{x1,h,edge0},{x1,h,edge1},{x0,h,edge1}},18,18,22,30,{0,1,0})
  else
   patch({{x0,h,edge0},{x1,h,edge0},{x1,h,edge1},{x0,h,edge1}},i*4,sy+2,(i+1)*4,sy+14,{0,1,0})
  end
  -- Step face at the lower end, sampled from native step shading.
  local fx=p.high=='east' and x0 or x1;local low=math.min(heights[i],heights[i+1])
  q({{fx,h,edge0},{fx,h,edge1},{fx,low,edge1},{fx,low,edge0}},p.kind=='escalator' and 18 or px,p.kind=='escalator' and 20 or sy+3,{p.high=='east' and -1 or 1,0,0})
  -- Continuous body along both sides, with a level datum to avoid gaps.
  if sideTop>base then
   q({{x0,sideTop,edge1},{x1,sideTop,edge1},{x1,base,edge1},{x0,base,edge1}},p.kind=='escalator' and 18 or px,p.kind=='stairs' and p.h*16-10 or 14,{0,0,p.down and -1 or 1},p.kind=='escalator' and 'over' or 'under')
   q({{x1,sideTop,edge0},{x0,sideTop,edge0},{x0,base,edge0},{x1,base,edge0}},p.kind=='escalator' and 18 or px,p.kind=='stairs' and p.h*16-10 or 14,{0,0,p.down and 1 or -1},p.kind=='escalator' and 'over' or 'under')
  end
 end
 -- Close the two transverse ends of the volume / descending opening.
 for _,i in ipairs({0,n}) do
  local x=ox+i*2/n;local h=heights[i]
  -- Descending end retainers meet the actual end tread, not the lower
  -- ideal slope vertex: otherwise the retainer overlaps its final riser.
  if p.down then h=math.max(h,heights[i==0 and 1 or n-1]) end
  local lo,hi=math.min(g,h),math.max(g,h)
  if hi>lo then q({{x,hi,edge0},{x,hi,edge1},{x,lo,edge1},{x,lo,edge0}},p.kind=='escalator' and 18 or (i==0 and 0 or 31),p.kind=='escalator' and 14 or p.h*16-10,{(i==0 and -1 or 1)*(p.down and -1 or 1),0,0},p.kind=='escalator' and 'over' or 'under') end
 end
 -- Narrow fixed balustrades follow the continuous flight. Native color bands
 -- (dark rim/light wood or red escalator rail) remain in their native order.
 -- Keep at least 0.60 cells above EVERY tread, including the lower edge
 -- of a tread where a sloping rail would otherwise lose one riser of height.
 -- Level the final high tread rail into its landing: the unused riser allowance
 -- must not push a house rail through the 2.0-cell room ceiling.
  local highTread=g+(p.down and 0 or p.rise)
 local function railY(h) return math.min(h+p.rise/n,highTread)+.60 end
 -- Native UNDER donors inside the actual banister, not the wallpaper/treads:
 -- 1F diagonal yellow cap (15,24), ochre edge (15,25), post (7,32).
 -- 2F horizontal white cap (12,23), dark edge (12,26), post (12,27).
 local railPx=p.kind=='escalator' and 18 or (p.down and 12 or 15)
 local railTop=p.kind=='escalator' and 9 or (p.down and 23 or 24)
 local railEdge=p.kind=='escalator' and 10 or (p.down and 26 or 25)

 for _,z in ipairs({z0-.06,z1+.06}) do
  for i=0,n-1 do
   local x0=ox+i*2/n;local x1=ox+(i+1)*2/n
   local h0=railY(heights[i]);local h1=railY(heights[i+1])
   local px=i*4+2
   if p.kind=='escalator' then
    -- Seat each panel on the discrete tread. A continuous slope base sinks
    -- into the steps and makes terminal caps coplanar with their risers.
    local panelBase=math.max(heights[i],heights[i+1])
    patch({{x0,h0-.08,z+.035},{x1,h1-.08,z+.035},{x1,panelBase,z+.035},{x0,panelBase,z+.035}},18,11,22,15,{0,0,1},'over')
    patch({{x1,h1-.08,z-.035},{x0,h0-.08,z-.035},{x0,panelBase,z-.035},{x1,panelBase,z-.035}},18,11,22,15,{0,0,-1},'over')
   end
   local sy=p.kind=='escalator' and (p.down and math.max(8,16-math.floor(px/2)) or math.min(8,math.floor(px/2))) or (p.down and math.max(0,15-math.floor(px/4)*2) or math.max(0,14-math.floor(px/4)*2))
   q({{x0,h0,z-.035},{x1,h1,z-.035},{x1,h1,z+.035},{x0,h0,z+.035}},railPx,railTop,{0,1,0},p.kind=='escalator' and 'over' or 'under')
   q({{x0,h0,z+.035},{x1,h1,z+.035},{x1,h1-.08,z+.035},{x0,h0-.08,z+.035}},railPx,railEdge,{0,0,1},p.kind=='escalator' and 'over' or 'under')
   q({{x1,h1,z-.035},{x0,h0,z-.035},{x0,h0-.08,z-.035},{x1,h1-.08,z-.035}},railPx,railEdge,{0,0,-1},p.kind=='escalator' and 'over' or 'under')
   q({{x0,h0-.08,z+.035},{x1,h1-.08,z+.035},{x1,h1-.08,z-.035},{x0,h0-.08,z-.035}},railPx,railEdge,{0,-1,0},p.kind=='escalator' and 'over' or 'under')
  end
  -- Square, closed handrail ends meet the entrance/exit cross-sections.
  for _,i in ipairs({0,n}) do
   local x=ox+i*2/n;local h=railY(heights[i])
   local px=i==0 and 2 or 30
   local sy=p.kind=='escalator' and 10 or 18
   q({{x,h,z-.035},{x,h,z+.035},{x,h-.08,z+.035},{x,h-.08,z-.035}},railPx,railEdge,{i==0 and -1 or 1,0,0},p.kind=='escalator' and 'over' or 'under')
   if p.kind=='escalator' then
    local panelBase=math.max(heights[i],heights[i==0 and 1 or n-1])
    patch({{x,h-.08,z-.035},{x,h-.08,z+.035},{x,panelBase,z+.035},{x,panelBase,z-.035}},18,11,22,15,{i==0 and -1 or 1,0,0},'over')
   end
  end
  if p.kind=='stairs' then
   -- Include the far-end post and seat each post on its actual tread; rail
   -- tops use the same slope at the clamped post center, not a lower datum.
   for i=0,n,2 do
    local r=.025;local shift=p.high=='east' and r or -r
    local postX=math.max(ox+r,math.min(ox+2-r,ox+i*2/n+shift))
    local u=(postX-ox)/2;local slope=p.high=='west' and 1-u or u
    local center=g+p.rise*slope-(p.down and p.rise or 0)
    local tilt=(p.high=='east' and 1 or -1)*p.rise*r/2
    local tl,tr=railY(center-tilt)-.08,railY(center+tilt)-.08
    local step=math.max(0,math.min(n-1,math.floor(u*n)))
    local b=math.max(heights[step],heights[step+1])
    local px,py=p.down and 12 or 7,p.down and 27 or 32
    q({{postX-r,tl,z+r},{postX+r,tr,z+r},{postX+r,b,z+r},{postX-r,b,z+r}},px,py,{0,0,1})
    q({{postX+r,tr,z-r},{postX-r,tl,z-r},{postX-r,b,z-r},{postX+r,b,z-r}},px,py,{0,0,-1})
    q({{postX-r,tl,z-r},{postX-r,tl,z+r},{postX-r,b,z+r},{postX-r,b,z-r}},px+1,py,{-1,0,0})
    q({{postX+r,tr,z+r},{postX+r,tr,z-r},{postX+r,b,z-r},{postX+r,b,z+r}},px+1,py,{1,0,0})
   end
  end
 end
 return {name=p.name,steps=n,collisionChanged=false,minimumRailClearance=.60}
end
return M
