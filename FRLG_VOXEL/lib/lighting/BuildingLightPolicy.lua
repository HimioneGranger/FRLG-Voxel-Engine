-- Pure native-calendar policy. No wall clock, RNG, event execution or save writes.
local M={REVISION='building-light-policy-1'}
local Policy={};Policy.__index=Policy
local services={gym=true,mart=true,center=true}
local defaults={duskMinute=1080,duskFade=30,dawnMinute=360,dawnFade=30,
 lampDuskMinute=1080,lampDuskFade=30,lampDawnMinute=360,lampDawnFade=30,
 shutdownStart=1320,shutdownEnd=1490,shutdownFade=10,variation=10,
 profiles={house={1,.83,.60},service={.87,.94,1},other={1,.89,.73},streetlamp={1,.76,.28}},exceptions={},
 indoorProfiles={house={mul={1,.97,.91},add={.015,.010,.003}},service={mul={.98,.99,1},add={.025,.025,.030}}},indoorExceptions={}}
local function finite(n)return type(n)=='number' and n==n and n~=math.huge and n~=-math.huge end
local function clamp(x,a,b)return math.max(a,math.min(b,x))end
local function copy(t)local o={}for k,v in pairs(t)do o[k]=type(v)=='table'and copy(v)or v end;return o end
local function hash(s)
 local h=17;for i=1,#s do h=(h*131+s:byte(i))%2147483647 end;return h
end
local function stable(n)assert(finite(n),'finite placement coordinate required');return string.format('%.12g',n)end
local function destinationKind(id)
 if type(id)~='string' then return nil end
 id=id:upper()
 -- Delimited native destination IDs, not substrings of exterior town names.
 if id:match('_POKEMON_CENTER_')or id:match('_POKEMON_CENTER$')or id:match('_POKECENTER_')or id:match('_POKECENTER$') then return 'center' end
 if id:match('_MART_')or id:match('_MART$') then return 'mart' end
 if id:match('_GYM_')or id:match('_GYM$') then return 'gym' end
 if id:match('_HOUSE_')or id:match('_HOUSE$')or id:match('_HOUSE%d+$')or id:match('_HOUSE%d+_') then return 'house' end
 return 'other'
end
function M.classify(record)
 assert(type(record)=='table'and type(record.mapId)=='string','native building map identity required')
 local id=record.id
 if type(id)~='string'or id==''then id=record.mapId..'/'..stable(record.x)..','..stable(record.z)..'/'..tostring(record.modelId or '?')end
 local kinds,seen={},{};local destinations={}
 for _,d in ipairs(record.destinations or{})do
  local name=type(d)=='table'and(d.mapId or d.map or d.target)or d
  if type(name)=='string'and not seen[name]then seen[name]=true;destinations[#destinations+1]=name;kinds[destinationKind(name)]=true end
 end
 table.sort(destinations)
 local kind,count='other',0
 for k in pairs(kinds)do kind=k;count=count+1 end
 if count~=1 then kind='other' end -- ambiguous/mixed ownership must not gain late lights
 return{id=id,mapId=record.mapId,x=record.x,z=record.z,modelId=record.modelId,
  destinations=destinations,kind=kind,profile=services[kind]and'service'or kind,
  lateEligible=services[kind]==true,classification=count==1 and'destination' or count==0 and'unknown' or'ambiguous',
  policyRevision=M.REVISION}
end
function M.calendar(clock,session)
 -- RseClock.read publishes calcLocalTime(session).days/hour; IDs are saved by
 -- the native Gen3 save schema. Host wall time is never substituted here.
 local h=clock and clock.hour;local day=clock and clock.days
 local tid=session and tonumber(session.trainerId);local sid=session and tonumber(session.secretId)
 if not(finite(h)and finite(day)and finite(tid)and finite(sid))then
  return{available=false,reason='native-calendar-or-save-identity-unavailable'}
 end
 return{available=true,hour=h%24,days=math.floor(day),seed=hash(tostring(math.floor(tid))..':'..tostring(math.floor(sid))),
  source=clock.source or'native-calendar',persistent=true}
end
local function configuration(input)
 local c=copy(defaults);input=input or{}
 for k,v in pairs(input)do
  assert(c[k]~=nil,'unknown policy setting '..tostring(k))
  if k=='profiles' then assert(type(v)=='table','invalid profiles');for name,rgb in pairs(v)do c.profiles[name]=copy(rgb)end
  elseif k=='indoorProfiles' then assert(type(v)=='table','invalid indoor profiles');for name,p in pairs(v)do c.indoorProfiles[name]=copy(p)end
  else c[k]=type(v)=='table'and copy(v)or v end
 end
 for _,k in ipairs{'duskMinute','duskFade','dawnMinute','dawnFade','shutdownStart','shutdownEnd','shutdownFade','variation','lampDuskMinute','lampDuskFade','lampDawnMinute','lampDawnFade'}do assert(finite(c[k])and c[k]%1==0,'invalid '..k)end
 assert(c.duskMinute>=720 and c.duskMinute<1320 and c.duskFade>0 and c.duskFade<=120,'invalid dusk')
 assert(c.dawnMinute>=240 and c.dawnMinute<=480 and c.dawnFade>0 and c.dawnFade<=120,'invalid dawn')
 assert(c.lampDuskMinute>=720 and c.lampDuskMinute<1440 and c.lampDuskFade>0 and c.lampDuskFade<=120,'invalid lamp dusk')
 assert(c.lampDawnMinute>=0 and c.lampDawnMinute<=720 and c.lampDawnFade>0 and c.lampDawnFade<=120,'invalid lamp dawn')
 assert(c.lampDuskMinute+c.lampDuskFade<=1440,'lamp dusk fade must finish by midnight')
 assert(c.lampDawnFade<=c.lampDawnMinute,'lamp dawn fade must start after midnight')
 assert(c.shutdownStart>=1320 and c.shutdownStart<=c.shutdownEnd and c.shutdownEnd<=1490,'shutdown outside22:00-00:50')
 assert(c.shutdownFade>0 and c.shutdownFade<=10 and c.variation>=0 and c.variation<=30,'invalid shutdown fade/variation')
 for _,name in ipairs{'house','service','other','streetlamp'}do assert(type(c.profiles[name])=='table','missing profile '..name)end
 for name,rgb in pairs(c.profiles)do
  assert(type(name)=='string'and type(rgb)=='table','invalid profile')
  for i=1,3 do assert(finite(rgb[i])and rgb[i]>=0 and rgb[i]<=1,'invalid profile color')end
 end
 for name,p in pairs(c.indoorProfiles)do
  assert(type(p)=='table','invalid indoor profile')
  for _,field in ipairs{'mul','add'}do assert(type(p[field])=='table','missing indoor '..field);for i=1,3 do assert(finite(p[field][i])and p[field][i]>=0 and p[field][i]<=(field=='mul'and 1.5 or .2),'invalid indoor grade')end end
 end
 assert(type(c.indoorExceptions)=='table','invalid indoor exceptions')
 for id,profile in pairs(c.indoorExceptions)do assert(type(id)=='string'and c.indoorProfiles[profile],'invalid indoor exception')end
 assert(type(c.exceptions)=='table','invalid exceptions')
 for id,e in pairs(c.exceptions)do
  assert(type(id)=='string'and type(e)=='table','invalid building exception')
  if e.profile then assert(c.profiles[e.profile],'unknown exception profile')end
  if e.lateEligible~=nil then assert(type(e.lateEligible)=='boolean','invalid late exception')end
 end
 return c
end
function M.new(config)
 local self=setmetatable({generation=0},Policy);self:configure(config);return self
end
function Policy:configure(config)
 self.config=configuration(config);self.lampConfig={duskMinute=self.config.lampDuskMinute,duskFade=self.config.lampDuskFade,dawnMinute=self.config.lampDawnMinute,dawnFade=self.config.lampDawnFade};self.generation=self.generation+1
 self.buildings=setmetatable({},{__mode='k'});self.schedules={};self.results={};self.lampKey=nil;self.lampResult=nil;self.indoors={};self.stats={classifications=0,schedules=0,evaluations=0}
end
function Policy:register(record)
 if record.policyRevision==M.REVISION then return record end
 local prior=self.buildings[record];if prior then return prior end
 local b=M.classify(record);self.buildings[record]=b;self.stats.classifications=self.stats.classifications+1;return b
end
function Policy:clear()
 self.buildings=setmetatable({},{__mode='k'});self.schedules={};self.results={};self.lampKey=nil;self.lampResult=nil;self.indoors={}
end
local function frameContext(frame,c)
 if not(frame and frame.available==true and finite(frame.hour)and finite(frame.days)and finite(frame.seed))then return nil end
 local minute=math.floor((frame.hour%24)*60+1e-7)
 local day=math.floor(frame.days)
 local nightId=day-(minute<c.dawnMinute and 1 or 0)
 local nightMinute=minute<c.dawnMinute and minute+1440 or minute
 return minute,nightId,nightMinute
end
local function smooth(t)t=clamp(t,0,1);return t*t*(3-2*t)end
local function nightLevel(minute,c)
 if minute>=c.duskMinute then return smooth((minute-c.duskMinute)/c.duskFade)end
 if minute<c.dawnMinute then return 1-smooth((minute-(c.dawnMinute-c.dawnFade))/c.dawnFade)end
 return 0
end
function Policy:evaluate(building,frame)
 assert(building and building.policyRevision==M.REVISION,'register native building once before evaluating')
 local c=self.config;local minute,nightId,nm=frameContext(frame,c)
 local exception=c.exceptions[building.id]or{}
 local profile=exception.profile or building.profile
 local rgb=c.profiles[profile]or c.profiles.other
 if not minute then return{level=0,rgb=rgb,kind=building.kind,profile=profile,available=false,id=building.id}end
 local key=table.concat({building.id,frame.seed,nightId,self.generation},'|')
 local schedule=self.schedules[building.id]
 if not schedule or schedule.key~=key then
  local base=c.shutdownStart+hash(building.id..':'..frame.seed)%(c.shutdownEnd-c.shutdownStart+1)
  local variation=hash(building.id..':'..frame.seed..':'..nightId)%(c.variation*2+1)-c.variation
  schedule={key=key,off=clamp(base+variation,c.shutdownStart,c.shutdownEnd)};self.schedules[building.id]=schedule
  self.stats.schedules=self.stats.schedules+1
 end
 local resultKey=key..':'..minute
 local cached=self.results[building.id];if cached and cached.key==resultKey then return cached.value end
 local late=building.lateEligible
 if exception.lateEligible~=nil then late=exception.lateEligible end
 local level=nightLevel(minute,c)
 if not late then
  level=level*(1-smooth((nm-schedule.off)/c.shutdownFade))
  if nm>=1500 then level=0 end --01:00 hard cutoff regardless of configuration
 end
 local out={level=level,rgb=rgb,id=building.id,kind=building.kind,profile=profile,lateEligible=late,
  offMinute=schedule.off,nightId=nightId,available=true}
 self.results[building.id]={key=resultKey,value=out};self.stats.evaluations=self.stats.evaluations+1;return out
end
function Policy:evaluateStreetlamp(frame)
 local c=self.config;local minute,nightId=frameContext(frame,c)
 local key=minute and table.concat({minute,nightId,frame.seed,self.generation},':')or'unavailable'
 if self.lampKey==key then return self.lampResult end
 self.lampKey=key;self.lampResult={level=minute and nightLevel(minute,self.lampConfig)or 0,rgb=c.profiles.streetlamp,available=minute~=nil,nightId=nightId}
 return self.lampResult
end
function Policy:indoor(mapDef)
 mapDef=mapDef or{}
 local id=mapDef.mapId or mapDef.id
 local mapType=tonumber(mapDef.mapType)
 local kind=destinationKind(id)or'other'
 local profile=services[kind]and'service'or(kind=='house'and'house'or nil)
 if type(id)=='string'and self.config.indoorExceptions[id]then profile=self.config.indoorExceptions[id]end
 if mapType==4 or mapType==5 or not(mapType==8 or mapDef.indoor==true)then profile=nil end
 local key=tostring(id)..':'..tostring(mapType)..':'..tostring(profile)
 if self.indoors[key]then return self.indoors[key]end
 local p=profile and self.config.indoorProfiles[profile]
 local out={mul=p and copy(p.mul)or{1,1,1},add=p and copy(p.add)or{0,0,0},active=p~=nil,
  revision=M.REVISION..'/indoor/'..self.generation,kind=kind,profile=profile}
 self.indoors[key]=out;return out
end
M.hash=hash
return M
