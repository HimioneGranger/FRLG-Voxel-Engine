-- Recovered existing juggle system; original source retained in task spin-reference.
-- FRLG adapter keeps runtime changes inside FRLG_VOXEL. See SPIN_PROVENANCE.json.
-- Deterministic, release-only curve. No targeting, inventory or RNG ownership.
local M={}
local function clamp(x,a,b)return math.max(a,math.min(b,x))end
function M.decay(charge,dt)return math.max(0,(charge or 0)-math.max(0,dt or 0)*.035)end
function M.catch(charge,age,rise)
 if (age or 0)<.12 or (rise or 0)<.035 then return charge or 0,false end
 local nextCharge=math.min(1,(charge or 0)+.35)
 return nextCharge,nextCharge>=1 and (charge or 0)<1
end
-- Room-space release curve in any direction, bounded independently of visual spin.
function M.acceleration(v,charge,gesture)
 local function finite(n)return type(n)=='number' and n==n and math.abs(n)<math.huge end
 if type(v)~='table' then return nil end
 for i=1,3 do if not finite(v[i])then return nil end end
 local speed=math.sqrt(v[1]^2+v[2]^2+v[3]^2)
 local c=finite(charge) and clamp(charge,0,1) or 0
 local horizontal=math.sqrt(v[1]^2+v[3]^2)
 if speed<.9 or c<.25 or horizontal<speed*.55 then return nil end
 local x,y,z
 if type(gesture)=='table' then
  x,y,z=gesture[1] or 0,gesture[2] or 0,gesture[3] or 0
 else x,y,z=0,gesture or 0,0 end
 if not (finite(x)and finite(y)and finite(z))then return nil end
 -- Retain the existing wrist direction convention. Parallel spin cannot curve.
 local ax,ay,az=v[2]*z-v[3]*y,v[3]*x-v[1]*z,v[1]*y-v[2]*x
 local length=math.sqrt(ax*ax+ay*ay+az*az)
 local perpendicular=length/speed
 if perpendicular<.8 then return nil end
 local strength=10*(.30+.70*c)*clamp(perpendicular/6,0,1)*clamp(speed/4,.2,1)
 return {ax/length*strength,ay/length*strength,az/length*strength}
end
function M.perfect(charge,a,age,centered)
 return (charge or 0)>=.97 and a~=nil and
   math.sqrt(a[1]^2+(a[2] or 0)^2+a[3]^2)*(age or 0)>=.45 and centered==true
end
function M.rate(rate,perfect)
 if not perfect then return rate end
 return math.min(255,math.floor(rate*1.10+.5))
end
-- Analytic position shared by the visible flight arc and runtime integrator.
local function profile(t,duration)
 local T=duration or .9
 if t<=0 or t>=T then return 0,0 end
 local w=2*math.pi/T
 return (1-math.cos(w*t))/(w*w),math.sin(w*t)/w
end
function M.point(p,v,a,t,age,duration)
 local x,dx=profile(age or 0,duration);local y=profile((age or 0)+t,duration)
 local k=y-x-dx*t
 return {p[1]+v[1]*t+(a and a[1] or 0)*k,
 p[2]+v[2]*t-4.905*t*t+(a and a[2] or 0)*k,
 p[3]+v[3]*t+(a and a[3] or 0)*k}
end
function M.velocityDelta(age,dt,duration)
 local _,a=profile(age,duration);local _,b=profile(age+dt,duration)
 return b-a
end
local cue
function M.peakCue()
 if not (love and love.sound and love.audio) then return end
 pcall(function()
  if not cue then
   -- A soft cluster of glassy sparkles with gently beating upper partials.
   -- No pitch sweep: this is a light tinkle rather than an electronic chirp.
   local rate,n=44100,68355
   local strikes={{0,2637,1},{.042,3951,.55},{.097,3136,.42},{.155,5274,.25},{.235,4699,.16}}
   local data=love.sound.newSoundData(n,rate,16,1)
   for i=0,n-1 do
    local t=i/rate;local sample=0
    for _,strike in ipairs(strikes) do
     local age=t-strike[1]
     if age>=0 then
      local frequency,weight=strike[2],strike[3]
      local attack=1-math.exp(-age/.012)
      local bell=math.exp(-age/.340)*math.sin(2*math.pi*frequency*age)
       +.26*math.exp(-age/.210)*math.sin(2*math.pi*frequency*2.01*age)
       +.08*math.exp(-age/.110)*math.sin(2*math.pi*frequency*3.02*age)
       +.19*math.exp(-age/.400)*math.sin(2*math.pi*(frequency+9)*age)
      sample=sample+.105*weight*attack*bell
     end
    end
    local fade=math.min(1,(n-1-i)/(rate*.180))
    data:setSample(i,sample*fade)
   end
   cue=love.audio.newSource(data,'static');cue:setVolume(.135)
   data:release()
  end
  cue:stop();cue:play()
 end)
end
return M
