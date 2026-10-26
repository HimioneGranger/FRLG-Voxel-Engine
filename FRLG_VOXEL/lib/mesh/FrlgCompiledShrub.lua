-- Static native-art small shrubs. Separate from trees and unapproved coarse LODs.
local V=...
local Data=V.require('mesh/FrlgCompiledShrubData')
local M={VERSION='frlg-compiled-shrub/3-ground-centers'}
-- Generated29pixel ground-only cleanup. Original75background pixels remain.
-- Donors are nearest visible original ground witnesses, not newly painted colors.
local groundRemap={[128]=112,[144]=112,[160]=112,[176]=224,[192]=224,[194]=193,[207]=224,[208]=224,[211]=210,[222]=239,[223]=224,[228]=227,[229]=245,[230]=245,[231]=245,[232]=245,[233]=245,[234]=253,[235]=253,[236]=253,[237]=253,[238]=239,[246]=245,[247]=245,[248]=245,[249]=245,[250]=253,[251]=253,[252]=253}
local abs,floor=math.abs,math.floor
local function close(a,b)return type(a)=='number' and a==a and abs(a-b)<1e-12 end
function M.bind(input)
 local spec=Data.maps[input.mapId];local a=input.atlas
 if not spec or input.isBorder or input.pair~=spec.pair or input.width~=spec.width or input.height~=spec.height
  or type(a)~='table' or a.w~=spec.atlasW or a.h~=spec.atlasH or type(a.texels)~='function'
  or type(a.underRect)~='function' or type(a.hasOver)~='function' or type(input.cellAt)~='function' then return nil end
 local ctx={cells={},stats={nativeMatched=0,emitted=0,groundTriangles=0,crownTriangles=0,excluded={},placements={}}}
 local checked={}
 for key,p in pairs(spec.cells)do
  local x=(key-1)%spec.width;local y=floor((key-1)/spec.width);local c=input.cellAt(x,y)
  local valid=checked[p[2]]
  if valid==nil then
   local v=Data.variants[p[2]];local t=a.texels(p[1],'under');local r={a.underRect(p[1])}
   valid=type(t)=='table' and not a.hasOver(p[1]) and #r==4
   if valid then for i=1,4 do if not close(r[i],v.rect[i])then valid=false;break end end end
   if valid then for i=1,256 do if t[i]~=v.texels[i]then valid=false;break end end end
   checked[p[2]]=valid
  end
  if valid and type(c)=='table' and c.mid==p[1] and c.collision==7 and c.elevation==0 and c.behavior==0
    and c.layerType==1 and c.walkable==false and c.category==p[3] then ctx.cells[key]=p;ctx.stats.nativeMatched=ctx.stats.nativeMatched+1 end
 end
 function ctx.accept(c)
  local p=ctx.cells[c.y*spec.width+c.x+1]
  if not p or c.mid~=p[1] or c.coll~=7 or c.elev~=0 or c.beh~=0 or c.walkable or c.hasOver or c.isTreeArt
    or c.hgt~=.75 or c.hg or c.rampH or c.groundMid or c.nativeStructure or c.unit then return false end
  -- Exact native pixels prove these are shrubs even where the old prop
  -- heuristic called them fences or rocks. Mixed building blocks remain
  -- excluded until their leaf/structure ownership is separately reviewed.
  return c.propShape=='tree' or c.propShape=='fence' or c.propShape=='rock'
 end
 function ctx.ground(c,r,list,hQuad)
  local du,dv=r[3]-r[1],r[4]-r[2]
  local donor={r[1]+du/32,r[2]+dv/32,r[1]+du/32,r[2]+dv/32}
  local first=#list
  for y=0,15 do
   local row=Data.rows[y+1];local x=0
   while x<16 do
    local p=ctx.cells[c.y*spec.width+c.x+1]
    local texels=Data.variants[p[2]].texels
    local function sample(px)
      if row:sub(px+1,px+1)=='1' then return 1,true end
      local i=y*16+px+1
      return groundRemap[i] or i,false
    end
    local index,leaf=sample(x);local color=texels[index];local e=x+1
    while e<16 do
      local nextIndex,nextLeaf=sample(e)
      if nextLeaf~=leaf or texels[nextIndex]~=color then break end
      e=e+1
    end
    -- Constant pixel-center UV prevents adjacent source shadow bleeding at seams.
    local px,py=(index-1)%16,floor((index-1)/16)
    local u,v=r[1]+du*(px+.5)/16,r[2]+dv*(py+.5)/16
    local uv={u,v,u,v}
    hQuad(list,c.x+x/16,c.y+y/16,c.x+e/16,c.y+(y+1)/16,c.hgt,uv)
    x=e
   end
  end
  ctx.stats.groundTriangles=ctx.stats.groundTriangles+(#list-first)/3
 end
 function ctx.crown(c,r,list)
  local du,dv=r[3]-r[1],r[4]-r[2];local first=#list+1
  for _,q in ipairs(Data.vertices)do
   list[#list+1]={c.x+.5+q[1]/16,c.hgt+q[2]/16,c.y+.5+q[3]/16,
    r[1]+q[4]*du,r[2]+q[5]*dv,q[6],q[7],q[8]}
  end
  ctx.stats.emitted=ctx.stats.emitted+1;ctx.stats.crownTriangles=ctx.stats.crownTriangles+#Data.vertices/3
  ctx.stats.placements[#ctx.stats.placements+1]={x=c.x,y=c.y,mid=c.mid,first=first,last=#list,height=c.hgt,triangles=#Data.vertices/3}
 end
 return ctx
end
return M
