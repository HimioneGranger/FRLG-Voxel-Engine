-- Recovered existing juggle system; original source retained in task spin-reference.
-- FRLG adapter keeps runtime changes inside FRLG_VOXEL. See SPIN_PROVENANCE.json.
-- Original cosmetic geometry; no gameplay randomness, scoring or inventory API.
local M={}
M.STREAK_SPEED=24 -- radians/second at the hidden peak-spin flourish
function M.reset(input)input.spinFlourish=nil;input.spinFlourishUsed=false end
function M.catch(input,charge,airtime,rise)
 if input.spinFlourishUsed or (charge or 0)<.97 or (airtime or 0)<.20 or (rise or 0)<.08 then return false end
 input.spinFlourishUsed=true;input.spinFlourish={age=0}
 return true
end
function M.step(input,dt,state)
 local e=input.spinFlourish;if not e then return end
 if not dt or dt~=dt or dt<=0 or dt>.2 or (state~='held' and state~='airborne') then input.spinFlourish=nil;return end
 e.age=e.age+dt
 if state=='airborne' then e.released=true end
 if e.released then e.tail=(e.tail or 0)+dt end
 if e.age>=3 or (e.tail and e.tail>=.7)then input.spinFlourish=nil end
end
local function clamp(x)return math.max(0,math.min(1,x))end
function M.geometry(e)
 local vertices,indices={},{}
 local depth=0
 local fade=clamp(e.age/.08)*clamp((3-e.age)/.45)*clamp(1-(e.tail or 0)/.7)
 local function triangle(a,b,c,color)
  local base=#vertices;local u=(color-.5)/5
  for _,p in ipairs({a,b,c})do vertices[#vertices+1]={p[1],p[2],p[3] or depth,u,.5,p[4] or 1}end
  indices[#indices+1]=base+1;indices[#indices+1]=base+2;indices[#indices+1]=base+3
 end
 local function softQuad(x,y,r,cell,angle,plane)
  local base=#vertices
  local c,s=math.cos(angle or 0),math.sin(angle or 0)
  for _,p in ipairs({{-1,-1},{1,-1},{1,1},{-1,1}})do
   local u=((cell-1)*32+1+(p[1]+1)*15)/160
   local v=(1+(p[2]+1)*15)/32
   local dx,dy=r*(p[1]*c-p[2]*s),r*(p[1]*s+p[2]*c)
   local px,py,pz=x+dx,y+dy,depth
   if plane==2 then py,pz=y,depth+dy elseif plane==3 then px,pz=x,depth+dx end
   vertices[#vertices+1]={px,py,pz,u,v,1}
  end
  for _,i in ipairs({1,2,3,1,3,4})do indices[#indices+1]=base+i end
 end
 -- Three short white arcs, not a full ring around the ball.
 for band=1,3 do
  local radius=.061+band*.004
  local start=e.age*M.STREAK_SPEED+(band==3 and math.pi or 0)+band*.12
  for segment=0,11 do
   local a=start+segment*.095;local b=a+.095
   local width=.0015*fade*(segment+1)/12
   local p={math.cos(a)*radius,math.sin(a)*radius}
   local q={math.cos(b)*radius,math.sin(b)*radius}
   local r={math.cos(a)*(radius+width),math.sin(a)*(radius+width)}
   local s={math.cos(b)*(radius+width),math.sin(b)*(radius+width)}
   triangle(p,q,r,1);triangle(q,s,r,1)
  end
 end
 for star=1,6 do
  local angle=star*2.39996+e.age*(2.4+star*.10)
  local radius=.095+(star%3)*.016+(e.tail or 0)*.06
  local x,y=math.cos(angle)*radius,math.sin(angle)*radius
  depth=.032*math.sin(angle*1.7+star)
  local size=(.007+.006*(.5+.5*math.sin(e.age*7+star*2))^2)*fade
  for plane=1,3 do softQuad(x,y,size*1.5,4,0,plane)end
  -- A translucent outer star and a pale-gold four-point core.
  for plane=1,3 do
  local function point(px,py)
   if plane==2 then return {px,y,depth+py-y}end
   if plane==3 then return {x,py,depth+px-x}end
   return {px,py,depth}
  end
  for layer=1,2 do
   local scale=layer==1 and 1.9 or 1
   for arm=0,7 do
    local a=arm*math.pi/4;local b=(arm+1)*math.pi/4
    local ra=(arm%2==0 and 1 or .18)*size*scale
    local rb=((arm+1)%2==0 and 1 or .18)*size*scale
    triangle(point(x,y),point(x+math.cos(a)*ra,y+math.sin(a)*ra),
      point(x+math.cos(b)*rb,y+math.sin(b)*rb),layer==1 and 3 or 2)
   end
  end
  end
  -- Tiny white-hot core, with a slow uneven pulse rather than a flashing dot.
  local pulse=1+.07*math.sin(e.age*6+star*1.7)
  local r=size*.27*pulse
  local function surface(lat,lon)
   local nx,ny,nz=math.cos(lat)*math.cos(lon),math.sin(lat),math.cos(lat)*math.sin(lon)
   return {x+nx*r,y+ny*r,depth+nz*r,.72+.28*math.max(0,nx*.3+ny*.5+nz*.8)}
  end
  for row=0,3 do for col=0,7 do
   local a,b=-math.pi/2+row*math.pi/4,-math.pi/2+(row+1)*math.pi/4
   local c,d=col*math.pi/4,(col+1)*math.pi/4
   triangle(surface(a,c),surface(b,c),surface(b,d),5)
   triangle(surface(a,c),surface(b,d),surface(a,d),5)
  end end
 end
 return vertices,indices
end
function M.new(voxel)
 local self={voxel=voxel}
 -- Cached atlas: three solid colors, a soft halo, and a tiny plasma-like core.
 local data=love.image.newImageData(160,32)
 local colors={{1,1,1,.65},{1,.97,.73,.95},{1,.92,.55,.20}}
 for y=0,31 do for x=0,159 do
  local cell=math.floor(x/32)+1
  local color=colors[cell]
  if color then data:setPixel(x,y,unpack(color))
  else
   local dx,dy=((x%32)-15.5)/14.5,(y-15.5)/14.5
   local radius=math.sqrt(dx*dx+dy*dy)
   if cell==4 then
    local alpha=.38*math.max(0,1-radius)^2
    data:setPixel(x,y,1,.89,.42,alpha)
   else
    local angle=math.atan2(dy,dx)
    local edge=radius*(1+.045*math.sin(angle*5+radius*13))
    local alpha=clamp((1-edge)*3)
    local hot=clamp(1-radius*1.35)
    data:setPixel(x,y,1,.89+.11*hot,.40+.60*hot,alpha)
   end
  end
 end end
 self.texture=love.graphics.newImage(data);data:release()
 self.texture:setFilter('linear','linear')
 function self:prepare(e)
  if self.event~=e or self.age~=e.age then
   local v,i=M.geometry(e)
   if self.mesh then self.mesh:setVertices(v)else self.mesh=self.voxel.newMesh(v,i)end
   self.event,self.age=e,e.age
  end
 end
 function self:draw(e,model)
  if self.event~=e or self.age~=e.age or not self.mesh then return false end
  -- Test against scene depth, but translucent halos must not occlude their cores.
  love.graphics.push('all');love.graphics.setDepthMode('lequal',false)
  local ok,err=pcall(self.voxel.draw,self.mesh,self.texture,model,0)
  love.graphics.pop()
  if not ok then error(err)end
 end
 function self:dispose()
  if self.mesh then self.mesh:release();self.mesh=nil end
  if self.texture then self.texture:release();self.texture=nil end
 end
 return self
end
return M
