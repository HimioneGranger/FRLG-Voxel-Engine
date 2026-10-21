-- FireRed reads its existing real-time gameplay clock authority through injection.
-- readClock is RealTimeClockTest.exports.readLightingCalendar; never os.date here.
local V=...
local Policy=V.require('lighting/BuildingLightPolicy')
local M={REVISION='firered-lighting-context-1'}
local function finite(v)return type(v)=='number'and v==v and v~=math.huge and v~=-math.huge end
local unavailable=Policy.calendar(nil,nil)
local lastClock,lastSession,lastHour,lastMinute,lastDay,lastTid,lastSid,lastSource,lastFrame
local function readFrame(game,readClock,getSession)
 if type(readClock)~='function'then return unavailable end
 local session=getSession and getSession()or require('src.core.game3.runtime').getSession()
 local c=readClock()
 if type(c)~='table'or not(finite(c.hour)and c.hour>=0 and c.hour<24 and finite(c.minute)and c.minute>=0 and c.minute<60 and finite(c.days))then return unavailable end
 local tid=session and tonumber(session.trainerId);local sid=session and tonumber(session.secretId)
 if not(finite(tid)and finite(sid))then return unavailable end
 if readClock==lastClock and session==lastSession and c.hour==lastHour and c.minute==lastMinute and c.days==lastDay
  and tid==lastTid and sid==lastSid and c.source==lastSource then return lastFrame end
 lastFrame=Policy.calendar({hour=c.hour+c.minute/60,days=c.days,source=c.source or'firered-gameplay-rtc'},session)
 lastClock,lastSession,lastHour,lastMinute,lastDay,lastTid,lastSid,lastSource=readClock,session,c.hour,c.minute,c.days,tid,sid,c.source
 return lastFrame
end
function M.frame(game,readClock,getSession)
 local ok,frame=pcall(readFrame,game,readClock,getSession)
 if ok and frame~=unavailable then return frame end
 lastClock,lastFrame=nil,nil
 return unavailable
end
function M.clear()lastClock,lastFrame=nil,nil end
function M.indoor(mapId,def)
 def=def or{}
 local kinds={MAP_TYPE_INDOOR=8,MAP_TYPE_SECRET_BASE=9,MAP_TYPE_UNDERGROUND=4,MAP_TYPE_UNDERWATER=5}
 return{id=mapId,mapId=mapId,mapType=tonumber(def.mapType)or kinds[def.mapType],indoor=def.indoor}
end
-- Footprint ownership is supplied by FrlgMesher, never inferred from an AABB.
-- Each building owns exact cells; parent must resolve entrance/warp cells there.
function M.descriptor(mapId,record)
 assert(type(mapId)=='string'and type(record)=='table','native FR building identity required')
 assert(finite(record.x)and finite(record.z),'native FR building placement required')
 local destinations={}
 for _,id in ipairs(record.destinations or{})do assert(type(id)=='string','native destination ID required');destinations[#destinations+1]=id end
 return{id=record.id,mapId=mapId,x=record.x,z=record.z,modelId=record.modelId,destinations=destinations}
end
return M
