-- Fixed four swept segments; call once per frame with feet in map-cell units.
-- positions = start XYZ/strength; directions = end XYZ/reserved. No allocations
-- per update, per-leaf state or per-eye simulation. Exact time buckets avoid a
-- high-speed walk overwriting a still-visible footstep.
local M={VERSION="grass-motion-2-segments"}
local State={};State.__index=State
local min,max,sqrt,exp,floor=math.min,math.max,math.sqrt,math.exp,math.floor
local function finite(v)return type(v)=="number" and v==v and v>-math.huge and v<math.huge end
local function clamp(v,a,b)return max(a,min(b,v)) end
local function smooth(v)v=clamp(v,0,1);return v*v*(3-2*v) end
local function opt(o,k,d,a,b)if not finite(o[k])then return d end;return clamp(o[k],a,b)end
function M.new(o)
 o=type(o)=="table" and o or {};local self=setmetatable({},State)
 self.capacity=4;self.interval=opt(o,"interval",.2,.1,.3);self.lifetime=3*self.interval
 self.rise=min(.06,self.interval/2);self.smoothing=opt(o,"smoothing",.09,.01,1)
 self.teleport=opt(o,"teleport",1.25,.5,10);self.maxDt=opt(o,"maxDt",.25,.05,1)
 self.maxSpeed=opt(o,"maxSpeed",4,.2,12);self.motionScale=opt(o,"motionScale",.8,.1,5)
 self.minSpeed=opt(o,"minSpeed",.035,.001,.3)
 self.u={positions={},directions={},body={0,0,0,0},velocity={0,0,0,0},count=4,
  radius=opt(o,"radius",.4,.34,.45),verticalGate=opt(o,"verticalGate",.55,.1,2)}
 self.samples={};for i=1,4 do self.samples[i]={} end;self:clear();return self
end
function State:clear()
 for i=1,16 do self.u.positions[i]=0;self.u.directions[i]=0 end
 for i=1,4 do self.u.body[i]=0;self.u.velocity[i]=0;local s=self.samples[i];s.bucket=nil;s.begin=0;s["end"]=0;s.peak=0;s.level=0 end
 self.px=nil;self.py=nil;self.pz=nil;self.context=nil;self.vx=0;self.vz=0;self.time=0;return self.u
end
function State:uniforms()return self.u end
local function anchor(self,x,y,z,key)
 self.px=x;self.py=y;self.pz=z;self.context=key
 self.u.body[1]=x;self.u.body[2]=y;self.u.body[3]=z;self.u.body[4]=1
end
function State:shift(dx,dz,key)
 if not finite(dx) or not finite(dz) then return self:clear() end
 if self.px==nil then return self.u end
 self.px=self.px+dx;self.pz=self.pz+dz;self.u.body[1]=self.u.body[1]+dx;self.u.body[3]=self.u.body[3]+dz
 for j=1,13,4 do self.u.positions[j]=self.u.positions[j]+dx;self.u.positions[j+2]=self.u.positions[j+2]+dz;self.u.directions[j]=self.u.directions[j]+dx;self.u.directions[j+2]=self.u.directions[j+2]+dz end
 if key~=nil then self.context=key end;return self.u
end
local function weights(self)
 for i=1,4 do local s=self.samples[i];self.u.positions[(i-1)*4+4]=s.level*(1-smooth((self.time-s["end"])/self.lifetime)) end
end
function State:update(dt,x,y,z,key,enabled)
 if enabled==false or not finite(dt) or dt<0 or not finite(x) or not finite(y) or not finite(z) then return self:clear() end
 if self.px==nil or key~=self.context then self:clear();anchor(self,x,y,z,key);return self.u end
 local dx,dy,dz=x-self.px,y-self.py,z-self.pz
 if dx*dx+dz*dz>self.teleport*self.teleport or math.abs(dy)>1 then self:clear();anchor(self,x,y,z,key);return self.u end
 local t0=self.time;self.time=self.time+dt
 if dt>self.maxDt then self.vx=0;self.vz=0;for i=1,4 do self.u.velocity[i]=0 end;weights(self);anchor(self,x,y,z,key);return self.u end
 if dt==0 then anchor(self,x,y,z,key);return self.u end
 local distance=sqrt(dx*dx+dz*dz);local rawSpeed=min(self.maxSpeed,distance/dt)
 local rawX,rawZ=0,0;if distance>0 then rawX=dx/distance*rawSpeed;rawZ=dz/distance*rawSpeed end
 local blend=1-exp(-dt/self.smoothing);self.vx=self.vx+(rawX-self.vx)*blend;self.vz=self.vz+(rawZ-self.vz)*blend
 local speed=sqrt(self.vx*self.vx+self.vz*self.vz)
 self.u.velocity[1]=speed>1e-9 and self.vx/speed or 0;self.u.velocity[3]=speed>1e-9 and self.vz/speed or 0;self.u.velocity[4]=speed
 if rawSpeed>self.minSpeed then
  local cursor=t0;local strength=min(1,rawSpeed/self.motionScale)
  while cursor<self.time-1e-12 do
   local bucket=floor((cursor+1e-10)/self.interval);local finish=min(self.time,(bucket+1)*self.interval)
   local i=bucket%4+1;local j=(i-1)*4;local s=self.samples[i]
   if s.bucket~=bucket then
    local f=(cursor-t0)/dt;s.bucket=bucket;s.begin=cursor;s.peak=0;s.level=0
    self.u.positions[j+1]=self.px+dx*f;self.u.positions[j+2]=self.py+dy*f;self.u.positions[j+3]=self.pz+dz*f
   end
   local f=(finish-t0)/dt;self.u.directions[j+1]=self.px+dx*f;self.u.directions[j+2]=self.py+dy*f;self.u.directions[j+3]=self.pz+dz*f
   local current=s.level*(1-smooth((cursor-s["end"])/self.lifetime));s.peak=max(s.peak,strength)
   s.level=current+(s.peak-current)*(1-exp(-(finish-cursor)/self.rise));s["end"]=finish;cursor=finish
  end
 end
 weights(self);anchor(self,x,y,z,key);return self.u
end
return M
