-- Shadow-only RTC buckets. No geometry remesh, render target or GPU readback.
-- 20 minute buckets plus a 2.6-degree sampled-vector drift guard. Pending/stalled
-- bucket suppresses direct sun/casts, rather than displaying mismatched masks.
--
-- Lab 55 (build-e), OutdoorPerf.sunShadows:
--   "moving" Lab 52 (masks follow the clock). With buildSlice on, a map that
--            arrives while the committed direction is still current is
--            marched alone in that direction instead of re-marching every
--            placed map (and the other maps keep their shadows meanwhile).
--   "fixed"  one direction (M.FIXED) baked into each mask at build by
--            Scene:_mask; no buckets, no re-march when the clock moves or a
--            map arrives. Strength still follows the clock: Light.solarWeight
--            eases toward the native sun's alpha (no pop), and View keeps
--            multiplying atmos shadowFade/terms by it.
--   "off"    no sun masks (Scene builds pools-only records); the sun term
--            still follows the native sun's direction and alpha.
local V = ...
local Light = V.require('render/Light')
local M = { FIELD_CAP = 32 * 1024 * 1024, STAGE_CAP = 8 * 1024 * 1024 }
local okPerf, Perf = pcall(V.require, 'render/OutdoorPerf')
if not (okPerf and type(Perf) == 'table') then Perf = { buildSlice = false, sunShadows = 'moving' } end
M._perf = Perf -- test seam
function M.mode()
  local m = Perf.sunShadows
  if m == 'fixed' or m == 'off' then return m end
  return 'moving'
end
-- The fixed sun (sunShadows = "fixed"). World axes: x east, y up, z south,
-- 1 unit = 1 cell. dx/dy/dz is the unit vector FROM the ground TOWARD the
-- sun (light travels the opposite way); x/z is its horizontal part
-- normalised. Bearing 306.87 deg (clockwise from north = -z, i.e. the sun
-- stands north-west, a little more west than north) and elevation 42 deg:
-- the historical FRLG_VOXEL default (Light.DEFAULT_SUN), so cast shadows fall
-- east-south-east, the same way as the shadows drawn into the GBA art.
do
  local el = math.rad(42)
  local hx, hz = -0.8, -0.6
  M.FIXED = { dx = hx * math.cos(el), dy = math.sin(el), dz = hz * math.cos(el), x = hx, z = hz,
    tan = math.tan(el), cast = true, alpha = 1, bucket = -1, fixed = true,
    azimuthDeg = 306.8699, elevationDeg = 42 }
  -- published for the weather mod's sun/moon placement (read-only use)
  if Perf.fixedSunDir == nil then Perf.fixedSunDir = { M.FIXED.dx, M.FIXED.dy, M.FIXED.dz } end
  -- compass bearing (clockwise from north = -z); NOT the weather mod heading (main.lua converts fixedSunDir)
  if Perf.fixedSunBearingDeg == nil then Perf.fixedSunBearingDeg = M.FIXED.azimuthDeg end
  if Perf.fixedSunElevation == nil then Perf.fixedSunElevation = M.FIXED.elevationDeg end
end
M.WEIGHT_RATE = 0.5 -- fixed/off: Light.solarWeight change per second (no pop on clock jumps)
local stats = { enabled=false, weight=0, commits=0, masks=0, fieldBytes=0, stagedBytes=0 }
local handle, sim, cachedLib
local retryAt=0
local lastVP
local clear
local function finite(x) return type(x)=='number' and x==x and math.abs(x)<math.huge end
local function release(x) if x and x.release then pcall(x.release,x) end end
function M.direction(s)
  if not s or not finite(s.dx) or not finite(s.dy) or not finite(s.dz) then return nil end
  local n=math.sqrt(s.dx*s.dx+s.dy*s.dy+s.dz*s.dz)
  if n<.99 or n>1.01 then return nil end
  local h=math.sqrt(s.dx*s.dx+s.dz*s.dz)
  local cast=s.above==true and finite(s.alpha) and s.alpha>0 and s.dy>.10 and h>.0001
  return {dx=s.dx,dy=s.dy,dz=s.dz,x=h>.0001 and s.dx/h or 0,
    z=h>.0001 and s.dz/h or 0,tan=h>.0001 and math.max(0,s.dy)/h or 10000,
    cast=cast,alpha=s.above and finite(s.alpha) and math.max(0,math.min(1,s.alpha)) or 0}
end
local function sample()
  if not handle then
    if os.clock()<retryAt then return nil,'weather unavailable' end
    retryAt=os.clock()+1
    local ok,h=pcall(function() return V.mod.find('the_world_weather_quest_lite_private') end)
    if ok then handle=h end
  end
  if not handle then return nil,'weather unavailable' end
  local h=handle
  local e=h.exports or {}; local gen=e.gen3 or (e.wx and e.wx.gen3)
  local lib=e.lib or (e.wx and e.wx.lib)
  if lib~=cachedLib then
    cachedLib,sim=lib,nil
    if lib and lib.require then local yes,s=pcall(lib.require,'CelestialSim');if yes then sim=s end end
  end
  if not gen or not gen.status or not sim or not sim.sample then return nil,'native API unavailable' end
  local yes,status=pcall(gen.status)
  if not yes then handle,sim,cachedLib=nil,nil,nil;return nil,'native status failed' end
  local c=yes and status and status.clock
  if not c or not finite(c.hour) or c.hour<0 or c.hour>=24 then return nil,'native clock unavailable' end
  local clockHour=c.hour
  if c.source=='rtc' or c.source=='rtc-os' or c.source=='tws' then
    if not finite(c.minute) or c.minute<0 or c.minute>=60 then return nil,'native clock unavailable' end
    clockHour=c.hour+c.minute/60
  elseif c.source~='emerald-rtc' then
    return nil,'native clock unavailable'
  end
  if status.outdoor~=true then return nil,'indoors' end
  local good,s=pcall(sim.sample) -- EXACT visible bodies sampler; no hour override
  if not good or not s or not finite(s.hour) then return nil,'sun sampler failed' end
  -- Legacy FRLG reports integer hours plus minutes; never bind a stale or
  -- unrelated clock to the actual no-override visible celestial sampler.
  local delta=math.abs((s.hour-clockHour+12)%24-12)
  if delta>.05 then return nil,'visible clock mismatch' end
  local d=M.direction(s.sun); if not d then return nil,'invalid sun vector' end
  d.hour=s.hour; d.bucket=math.floor((s.hour%24)*3+.5)%72
  return d
end
function M.status() return stats end
function M.invalidate(scene)
  handle,sim,cachedLib=nil,nil,nil;retryAt=0
  scene._solarSample=nil
  if clear then clear(scene) end
  M.cancelReservations(scene)
  scene._solarTarget=nil
  Light.solarWeight=0;stats.weight=0;stats.cast=false
end
function M.available(scene) return scene._solarSample~=nil end
function M.bypass(ms)
  stats.prebakeBypasses=(stats.prebakeBypasses or 0)+1
  stats.initialBuildMs=(stats.initialBuildMs or 0)+(ms or 0)
end
function M.initialBuild(ms) stats.initialBuildMs=(stats.initialBuildMs or 0)+ms end
function M.poll(scene)
  stats.maskBindings=0;stats.drawPasses=0;lastVP=nil
  M.fieldAllowance(scene)
  local d,err=sample();scene._solarSample=d
  stats.enabled=d~=nil;stats.error=err
  stats.pending=false
  if M.mode()~='moving' then return M._stillPoll(scene,d) end -- Lab 55 fixed/off
  scene._solarWeightT=nil
  local c=scene._solarDirection
  if not d or d.alpha<=0 or not c or c.bucket~=d.bucket or
    c.cast~=d.cast or c.dx*d.dx+c.dy*d.dy+c.dz*d.dz<math.cos(math.rad(2.6)) then
    stats.weight=0;Light.solarWeight=0;stats.cast=false
    stats.pending=d~=nil and d.cast and d.alpha>0
  end
end
function M.noteMask(vp)
  stats.maskBindings=stats.maskBindings+1
  if vp~=lastVP then stats.drawPasses=stats.drawPasses+1;lastVP=vp end
end
local function committed(d)
  stats.committedBucket=d.bucket
  stats.committedX,stats.committedY,stats.committedZ=d.dx,d.dy,d.dz
end
local function records(scene)
  local out={}
  for _,p in ipairs(scene.placed) do
    local r=p.border and scene.borders[p.key] or scene.cache[p.key]
    if r and r.shadowKind=='sun' and not r.failed and not r.empty then out[#out+1]=r end
  end
  return out
end
clear=function(scene)
  for _,p in ipairs(scene._solarStaged or {}) do release(p.image);release(p.data) end
  scene._solarStaged=nil; scene._solarCo=nil;stats.stagedBytes=0
  M._clearInc(scene) -- Lab 55: the single-map (incremental / fixed) march, if any
end
function M.fieldAllowance(scene)
  local bytes=0
  for _,store in ipairs({scene.cache,scene.borders}) do
    for _,r in pairs(store) do if r.solarField then bytes=bytes+r.w*r.h*Light.RES*Light.RES*16 end end
  end
  for _,v in pairs(scene._solarReservations or {}) do bytes=bytes+v end
  stats.fieldBytes=bytes
  return math.max(0,math.min(4*1024*1024,M.FIELD_CAP-bytes))
end
function M.reserve(scene,rec,bytes)
  if bytes>M.fieldAllowance(scene) then bytes=0 end
  scene._solarReservations=scene._solarReservations or {}
  scene._solarReservations[rec]=bytes;rec.solarOwner=scene;rec.solarCoroutine=coroutine.running()
  return bytes
end
function M.unreserve(scene,rec)
  if scene and scene._solarReservations then scene._solarReservations[rec]=nil end
end
function M.cancelReservations(scene,co)
  for r in pairs(scene._solarReservations or {}) do
    if not co or r.solarCoroutine==co then
      release(r.solarField);r.solarField=nil
      release(r.solarInitialData);r.solarInitialData=nil
      release(r.solarInitialImage);r.solarInitialImage=nil
      scene._solarReservations[r]=nil
    end
  end
end
function M.recovery(kind)stats['recovery'..kind]=(stats['recovery'..kind] or 0)+1 end
-- ------------------------------------------------------------ Lab 55
-- One record's directional mask from its retained field, `dir` the commit
-- direction, the pools (B) copied from its current shadowData: exactly the
-- body of the Lab 52 staged loop below. -> { record, data, image }
local function marchOne(r,dir,yieldPoint,owned)
  local data=Light.shadowMask(nil,r.w,r.h,{field=r.solarField,direction=dir,yield=yieldPoint,rowsPerYield=4,want=r.solarWant,
    ownData=function(v)owned.data=v;stats.stagedBytes=stats.stagedBytes+r.w*r.h*Light.RES*Light.RES*8 end})
  local W,H=data:getDimensions()
  for y=0,H-1 do
    if y%4==0 then yieldPoint() end
    for x=0,W-1 do
      local a,b,_,v=data:getPixel(x,y)
      local _,_,pool=r.shadowData:getPixel(x,y)
      data:setPixel(x,y,a,b,pool,v)
    end
  end
  local image=love.graphics.newImage(data);owned.image=image
  image:setFilter('linear','linear');image:setWrap('clamp','clamp')
  return owned
end
M._marchOne=marchOne -- test seam
function M._clearInc(scene)
  local inc=scene._solarInc
  if not inc then return end
  for _,p in ipairs(inc.staged) do release(p.image);release(p.data) end
  scene._solarInc=nil
end
-- March `stale` (records whose solarBucket ~= dir.bucket, each with a field)
-- one at a time in `dir` and commit each as soon as it is done: every record
-- is coherent on its own because `dir` is the direction already committed
-- for the others (moving) or the one fixed sun. -> true when nothing is left.
local function marchStale(scene,dir,stale,yieldPoint)
  local inc=scene._solarInc
  if inc and inc.dir~=dir then M._clearInc(scene);inc=nil end
  if not inc then
    inc={dir=dir,staged={},list=stale}
    inc.co=coroutine.create(function()
      for _,r in ipairs(stale) do
        local owned={record=r};inc.staged[#inc.staged+1]=owned
        marchOne(r,dir,yieldPoint,owned)
      end
    end)
    scene._solarInc=inc
  end
  local ok,why=coroutine.resume(inc.co)
  if not ok then stats.error=tostring(why);M._clearInc(scene);return true end
  if coroutine.status(inc.co)~='dead' then return false end
  local live={}
  for _,r in ipairs(records(scene)) do live[r]=true end
  for _,p in ipairs(inc.staged) do
    local r=p.record
    if live[r] and r.solarBucket~=dir.bucket and p.image then
      release(r.shadow);release(r.shadowData)
      r.shadow,r.shadowData,r.solarBucket=p.image,p.data,dir.bucket
      stats.incrementalMasks=(stats.incrementalMasks or 0)+1
    else
      release(p.image);release(p.data)
    end
  end
  scene._solarInc=nil;stats.stagedBytes=0
  return true
end
-- moving + buildSlice: the committed direction is still current and only
-- some records lack it (a map just arrived). Returns true when it handled
-- this pump; false hands the pump to the Lab 52 path unchanged.
local function incrementalPump(scene,yieldPoint)
  local d,c=scene._solarSample,scene._solarDirection
  if scene._solarCo or not d or not c or c.fixed or not d.cast or not c.cast or d.alpha<=0
    or c.bucket~=d.bucket or c.dx*d.dx+c.dy*d.dy+c.dz*d.dz<math.cos(math.rad(2.6)) then
    M._clearInc(scene);return false
  end
  local list=records(scene)
  local stale={}
  for _,r in ipairs(list) do
    if r.solarBucket~=c.bucket then
      if not r.solarField then M._clearInc(scene);return false end
      stale[#stale+1]=r
    end
  end
  if #stale==0 or #stale==#list then M._clearInc(scene);return false end
  -- the current masks stay on while the newcomers are marched in c
  stats.weight=d.alpha;Light.solarWeight=d.alpha;stats.cast=c.cast;stats.pending=true
  stats.masks=#list-#stale
  if marchStale(scene,c,scene._solarInc and scene._solarInc.list or stale,yieldPoint) then
    stats.pending=false;stats.masks=#list
  end
  return true
end
-- fixed/off: strength eases toward the native sun's alpha; fail closed (0)
-- without a native sample, like Lab 52.
local function easeWeight(scene,d)
  local target=d and d.alpha or 0
  local t=(love and love.timer and love.timer.getTime and love.timer.getTime()) or os.clock()
  local w=scene._solarWeightNow
  if w==nil or scene._solarWeightT==nil then w=target
  else
    local step=math.max(0,t-scene._solarWeightT)*M.WEIGHT_RATE
    if w<target then w=math.min(target,w+step) else w=math.max(target,w-step) end
  end
  scene._solarWeightNow,scene._solarWeightT=w,t
  return w
end
function M._stillPoll(scene,d)
  local mode=M.mode()
  local w=easeWeight(scene,d)
  if mode=='fixed' then
    if scene._solarDirection~=M.FIXED then
      clear(scene);scene._solarTarget=nil
      Light.commitSolar(M.FIXED);scene._solarDirection=M.FIXED;committed(M.FIXED)
    end
    stats.weight=w;Light.solarWeight=w;stats.cast=w>0;stats.masks=#records(scene)
  else -- off: no masks; the sun term follows the native sun
    if scene._solarDirection and scene._solarDirection.fixed then scene._solarDirection=nil end
    if scene._solarStaged or scene._solarCo then clear(scene) end
    if d then Light.commitSolar(d);committed(d) end
    stats.weight=w;Light.solarWeight=w;stats.cast=false;stats.masks=0
  end
  stats.pending=false
end
-- fixed: records still carrying a moving-sun mask (a runtime switch) are
-- re-marched from their fields in M.FIXED; the ones without a field are
-- rebuilt by Scene (Scene:_maskUpgrade).
local function stillPump(scene,yieldPoint)
  if scene._solarStaged or scene._solarCo then
    for _,p in ipairs(scene._solarStaged or {}) do release(p.image);release(p.data) end
    scene._solarStaged=nil;scene._solarCo=nil;stats.stagedBytes=0
  end
  if M.mode()~='fixed' then M._clearInc(scene);return end
  local stale={}
  for _,r in ipairs(records(scene)) do
    if r.solarBucket~=M.FIXED.bucket and r.solarField then stale[#stale+1]=r end
  end
  if #stale==0 and not scene._solarInc then return end
  marchStale(scene,M.FIXED,scene._solarInc and scene._solarInc.list or stale,yieldPoint)
end

function M.pump(scene,yieldPoint)
  if M.mode()~='moving' then return stillPump(scene,yieldPoint) end -- Lab 55 fixed/off
  if Perf.buildSlice==true and incrementalPump(scene,yieldPoint) then return end -- Lab 55
  local d=scene._solarSample
  stats.weight=0;Light.solarWeight=0
  if not d then clear(scene);return end
  stats.hour=d.hour;stats.bucket=d.bucket;stats.sunX=d.dx;stats.sunY=d.dy;stats.sunZ=d.dz
  local list=records(scene)
  local ready=not scene._solarCo and scene._solarDirection and scene._solarDirection.bucket==d.bucket and scene._solarDirection.cast==d.cast
  for _,r in ipairs(list) do if r.solarBucket~=d.bucket then ready=false end end
  if ready then
    local c=scene._solarDirection
    local dot=c.dx*d.dx+c.dy*d.dy+c.dz*d.dz
    if dot>=math.cos(math.rad(2.6)) then
      stats.weight=d.alpha;Light.solarWeight=d.alpha;stats.committedBucket=c.bucket
      stats.committedX=c.dx;stats.committedY=c.dy;stats.committedZ=c.dz
      stats.cast=c.cast
      stats.masks=c.cast and #list or 0;stats.pending=false
      return
    end
    clear(scene);scene._solarTarget=nil
  end
  if not d.cast then -- night/horizon/noon: direction is valid, but no elongated cast
    clear(scene);Light.commitSolar(d);scene._solarDirection=d
    stats.weight=d.alpha;Light.solarWeight=d.alpha
    committed(d);stats.masks=0
    -- Do not label old directional masks current; View disables casts separately.
    stats.cast=false;return
  end
  stats.cast=false
  stats.pending=true
  if scene._solarTarget~=d.bucket then clear(scene);scene._solarTarget=d.bucket end
  if not scene._solarCo then
    scene._solarBuildDirection=d
    local total=0
    for _,r in ipairs(list) do
      if not r.solarField then stats.error='height field unavailable';return end
      total=total+r.w*r.h*Light.RES*Light.RES*8 -- CPU data + GPU rgba8 estimate
    end
    if total>M.STAGE_CAP then stats.error='staged mask byte cap';return end
    local staged={};scene._solarStaged=staged
    scene._solarCo=coroutine.create(function()
      for _,r in ipairs(list) do
        local owned={record=r};staged[#staged+1]=owned
        local data=Light.shadowMask(nil,r.w,r.h,{field=r.solarField,direction=d,yield=yieldPoint,rowsPerYield=4,want=r.solarWant,
          ownData=function(v)owned.data=v;stats.stagedBytes=stats.stagedBytes+r.w*r.h*Light.RES*Light.RES*8 end})
        local W,H=data:getDimensions()
        for y=0,H-1 do
          if y%4==0 then yieldPoint() end
          for x=0,W-1 do
            local a,b,_,v=data:getPixel(x,y)
            local _,_,pool=r.shadowData:getPixel(x,y)
            data:setPixel(x,y,a,b,pool,v)
          end
        end
        local image=love.graphics.newImage(data);owned.image=image
        image:setFilter('linear','linear');image:setWrap('clamp','clamp')
      end
    end)
  end
  local ok,why=coroutine.resume(scene._solarCo)
  if not ok then stats.error=tostring(why);clear(scene);return end
  if coroutine.status(scene._solarCo)~='dead' then return end
  local built=scene._solarBuildDirection
  if built.bucket~=d.bucket or built.cast~=d.cast or built.dx*d.dx+built.dy*d.dy+built.dz*d.dz<math.cos(math.rad(2.6)) then
    clear(scene);scene._solarTarget=nil;return
  end
  local current=records(scene); local staged=scene._solarStaged
  if #current~=#staged then clear(scene);return end
  for i,r in ipairs(current) do if r~=staged[i].record then clear(scene);return end end
  for _,p in ipairs(staged) do
    local r=p.record;release(r.shadow);release(r.shadowData)
    r.shadow,r.shadowData,r.solarBucket=p.image,p.data,built.bucket
  end
  Light.commitSolar(built);scene._solarDirection=built
  committed(built)
  scene._solarStaged=nil;scene._solarCo=nil;stats.stagedBytes=0
  stats.commits=stats.commits+1;stats.masks=#staged;stats.error=nil;stats.cast=true
  stats.pending=false
end
function M.casts(scene)
  return stats.cast==true and stats.weight>0 and scene._solarDirection and scene._solarDirection.cast
end
return M
