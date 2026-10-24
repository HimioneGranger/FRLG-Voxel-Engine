-- Presentation-only ground cue. Cell coordinates match BattlePass.frameCards.
local M={SEGMENTS=32,COLOR={.72,.91,.75},ALPHA=.42}
local function finite(x)return type(x)=='number'and x==x and math.abs(x)<1e6 end
function M.select(slots,pendingIds)
 local out,ids={},{}
 for _,id in ipairs(pendingIds or {})do if id==0 or id==2 then ids[id]=true end end
 for _,s in ipairs(slots or {})do
  -- The destination exists before the player's sprite becomes visible.
  if ids[s.id] and finite(s.x)and finite(s.z)and finite(s.ground)then
   local width=finite(s.w) and s.w or 1
   out[#out+1]={id=s.id,x=s.x,z=s.z,y=s.ground+.018,radius=math.max(.32,math.min(.65,width*.30))}
  end
 end
 return out
end
function M.vertices(c)
 local vertices={};local inner=c.radius*.78
 for i=0,M.SEGMENTS-1 do
  local a,b=i*math.pi*2/M.SEGMENTS,(i+1)*math.pi*2/M.SEGMENTS
  local function p(angle,r)return{c.x+math.cos(angle)*r,c.y,c.z+math.sin(angle)*r,.5,.5,0,0,0}end
  local o1,i1,o2,i2=p(a,c.radius),p(a,inner),p(b,c.radius),p(b,inner)
  -- Upward winding, same flat-ground convention as BattlePass.blobVerts.
  for _,v in ipairs({o1,i1,o2,o2,i1,i2})do vertices[#vertices+1]=v end
 end
 return vertices
end
return M
