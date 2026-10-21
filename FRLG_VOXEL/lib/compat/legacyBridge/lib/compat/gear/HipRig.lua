-- Shared hip-space ellipse. Coordinates never modify tracked hands or world scale.
local M={}
local function finite(v)return type(v)=='number'and v==v and v~=math.huge and v~=-math.huge end
local function clamp(v,a,b)return math.max(a,math.min(b,v))end
function M.normalize(v)
 if type(v)~='table'or type(v.hip)~='table'or type(v.party)~='table'or type(v.pouch)~='table'then return nil end
 local h,p,q=v.hip,v.party,v.pouch
 for _,x in ipairs({'x','y','z','rx','rz'})do if not finite(h[x])then return nil end end
 if not finite(p.angle)or not finite(p.spread)or not finite(q.angle)then return nil end
 return {hip={x=clamp(h.x,-.35,.35),y=clamp(h.y,-1,-.20),z=clamp(h.z,-.30,.30),rx=clamp(h.rx,.24,.55),rz=clamp(h.rz,.18,.45)},
  party={angle=clamp(p.angle,-math.pi,math.pi),spread=clamp(p.spread,.80,2.20)},pouch={angle=clamp(q.angle,-math.pi,math.pi)}}
end
function M.migrate(v)
 if type(v)~='table'or type(v.party)~='table'or type(v.pouch)~='table'then return nil end
 local p,q=v.party,v.pouch
 for _,row in ipairs({p,q})do for _,k in ipairs({'x','y','z'})do if not finite(row[k])then return nil end end end
 if not finite(p.span)then return nil end
 local rx=clamp(p.span*.70,.24,.55);local rz=.25
 local x=clamp(p.x,-.35,.35);local z=clamp(p.z+rz,-.30,.30)
 return M.normalize({hip={x=x,y=p.y,z=z,rx=rx,rz=rz},party={angle=0,spread=1.60},
  pouch={angle=math.atan2((q.x-x)/rx,-(q.z-z)/rz)}})
end
function M.point(v,a)
 local h=v.hip;local s,c=math.sin(a),math.cos(a)
 return {h.x+h.rx*s,h.y,h.z-h.rz*c},math.atan2(s/h.rx,-c/h.rz)
end
function M.party(v,t)return M.point(v,v.party.angle+t*v.party.spread*.5)end
function M.angle(v,p)return math.atan2((p[1]-v.hip.x)/v.hip.rx,-(p[3]-v.hip.z)/v.hip.rz)end
return M
