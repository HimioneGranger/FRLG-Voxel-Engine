-- One invisible elliptical hip rig; mounted equipment keeps its authored anchors.
local V=...
local Hip=V.require('HipRig')
local M={rx=.28,rz=.25,z=.035,y=-.66,height=.046,thickness=.006}
local mounted
local adjustment
function M.setAdjustment(value)
 adjustment=Hip.normalize(value)
end
local function number(key,default,min,max)
 local options=V and V.mod and V.mod.options
 local value=options and options.get and tonumber((options:get(key))) or default
 if not value or value~=value then value=default end
 return math.max(min,math.min(max,value))
end
local function gearHeight(key)return -1.2+number(key,60,35,85)/100 end
function M.defaults()
 return {hip={x=0,y=gearHeight('party_height'),z=.035,rx=number('party_width',50,40,65)/100*.70,rz=.25},
  party={angle=0,spread=1.60},pouch={angle=M.side()*1.35}}
end
function M.setMount(value)
 mounted=nil
 if not(value and value.root)then return end
 if value.key=='112-ground' and value.party and value.pouch then mounted=value
 elseif value.key=='018-flight' then
  local hip=Hip.normalize(value.hipRig)
  if hip then mounted={key=value.key,root=value.root,hipRig=hip}end
 end
end
function M.mounted()return mounted~=nil end
function M.root(fallback)return mounted and mounted.root or fallback end
function M.side()
 local options=V and V.mod and V.mod.options
 return options and options.get and options:get('swap_belt_sides')==true and -1 or 1
end
function M.point(angle,standOff)
 local a=math.rad(angle);local x,z=math.sin(a),-math.cos(a)
 local nx,nz=x/M.rx,z/M.rz;local length=math.sqrt(nx*nx+nz*nz)
 nx,nz=nx/length,nz/length
 return {M.rx*x+nx*(standOff or 0),M.y,M.z+M.rz*z+nz*(standOff or 0)},math.atan2(nx,nz)
end
-- Legacy angular helpers remain for the separate Safari accessory.
function M.partyAngle(i)return M.side()*(-15-(i-1)*9.5)end
function M.pouchAngle()return M.side()*22 end
function M.safariAngle()return M.side()*-25 end
function M.safari()
 local p,yaw=M.point(M.safariAngle(),.008)
 p[2]=p[2]+M.height*.5
 return p,yaw
end
function M.party(i)
 if mounted and mounted.hipRig then return Hip.party(mounted.hipRig,(i-3.5)/2.5)end
 if mounted then local p=mounted.party[i];return {p[1],p[2],p[3]},0 end
 return Hip.party(adjustment or M.defaults(),(i-3.5)/2.5)
end
function M.partyClip()
 if mounted and mounted.hipRig then return Hip.normalize(mounted.hipRig)end
 if mounted then return nil end
 return Hip.normalize(adjustment or M.defaults())
end
function M.pouch()
 if mounted and mounted.hipRig then return Hip.point(mounted.hipRig,mounted.hipRig.pouch.angle)end
 if mounted then local p=mounted.pouch;return {p[1],p[2],p[3]},0 end
 local p=adjustment or M.defaults();return Hip.point(p,p.pouch.angle)
end
return M
