-- Separate provider arbitration; never owns encounter spawning or capture writes.
local M={}
function M.new(find,capture,emit,visuals,actionCards,hostReady)
 local self={find=find,epoch=0,serial=0,handles={},identities=setmetatable({},{__mode='k'}),hidden={}}
 function self:reset()self.epoch=self.epoch+1;self.handles={};self.identities=setmetatable({},{__mode='k'});self.hidden={};self.handoff=nil end
 function self:refresh()
  local w=find('wilds_of_hoenn');local ex=w and w.exports
  local okEnabled,on=false,false
  if ex and type(ex.vrProviderEnabled)=='function'then okEnabled,on=pcall(ex.vrProviderEnabled)end
  local hostOK=true;if hostReady then local ok,v=pcall(hostReady);hostOK=ok and v==true end
  local ready=hostOK and w and({['1.5.0']=true,['1.7.1']=true})[w.version or(ex and ex.version)]and ex and ex.engineReady==true and ex.vrProviderReady==true and okEnabled and on==true
   and ex.spawnManager and type(ex.spawnManager.get)=='function'and type(ex.spawnManager.collectActors)=='function'
  local oldNative=find('untamed_advanced');oldNative=oldNative and oldNative.exports
  -- The bridge exports its facade even when Untamed is absent. An idle
  -- adapter is not a native provider and must not block Wilds activation.
  local legacy=find('FRLG_OW_MONS');local old=oldNative and legacy and legacy.exports and legacy.exports.owMons
  local nextId=ready and'wilds_of_hoenn'or(old and'untamed_advanced'or nil)
  local target=nextId=='wilds_of_hoenn'and ex or nextId=='untamed_advanced'and oldNative or nil
  if nextId~=self.selected then
   local current=self.nativeSelected
   local function busy(e)
    if not e then return false end
    if type(e.nativeProviderBusy)~='function'then return true end
    local ok,v=pcall(e.nativeProviderBusy);return not ok or v==true
   end
   if nextId=='wilds_of_hoenn'and (type(ex.setNativeProviderEnabled)~='function'or(old and not oldNative))then
    self.switchError='native provider gate unavailable';return self.selected
   end
   if busy(current)or busy(target)then self.switchError='native provider busy';return self.selected end
   if current and current.setNativeProviderEnabled then local ok,v=pcall(current.setNativeProviderEnabled,false);if not ok or v~=true then self.switchError='native disable refused';return self.selected end end
   if target and target.setNativeProviderEnabled then
    local ok,v=pcall(target.setNativeProviderEnabled,true)
    if not ok or v~=true then
     if current and current.setNativeProviderEnabled then
      local back,restored=pcall(current.setNativeProviderEnabled,true)
      if not back or restored~=true then self:reset();self.selected=nil;self.manager=nil;self.nativeSelected=nil;self.switchError='native rollback refused';return nil end
     end
     self.switchError='native activation refused';return self.selected
    end
   end
   self.nativeSelected=target;self.switchError=nil
  end
  local manager=ready and ex.spawnManager or nil;local map=manager and manager.mapId
  if nextId~=self.selected or manager~=self.manager or map~=self.map then self:reset()end
  self.selected,self.manager,self.map,self.wild,self.old=nextId,manager,map,ex,old
  if old and old._debug and old._debug.setProviderEnabled then old._debug.setProviderEnabled(nextId~='wilds_of_hoenn')end
  return nextId
 end
 function self:key(e)
  local k=self.identities[e]
  if not k then self.serial=self.serial+1;k='wilds_of_hoenn:'..self.epoch..':'..self.serial;self.identities[e]=k;self.handles[k]={entity=e,manager=self.manager,epoch=self.epoch,id=e.id}end
  return k
 end
 function self:resolveWild(k)
  self:refresh();local h=self.handles[k]
  if self.selected~='wilds_of_hoenn'or not h or h.epoch~=self.epoch or h.manager~=self.manager then return nil end
  local e=self.manager:get(h.id);if e~=h.entity or e.state~='available'or e.engaged then return nil end
  return e
 end
 local api={api=1,providerRouting=true,captureTransactions=capture and 1 or nil}
 function api.captureOwner()self:refresh();if self.selected=='untamed_advanced'then return self.old end;return api end
 function api.beginCapture(k,session)
  self:refresh();if self.selected=='wilds_of_hoenn'then return capture.begin(self,k,session)end
  return nil,'legacy'
 end
 function api.list()
  self:refresh();if self.selected~='wilds_of_hoenn'then return self.old and self.old.list()or{}end
  local out={};for _,id in ipairs(self.manager.order)do local e=self.manager:get(id)
   if e and e.state=='available'then local key=self:key(e);out[#out+1]={key=key,slot=e.id,kind='wild',provider='wilds_of_hoenn',x=(e.px+8)/16,z=(e.py+8)/16,engineSpecies=e.species,level=e.level,personality=e.personality,shiny=e.shiny==true,roamer=e.roamer==true,facing=e.facing,hidden=self.hidden[key]==true,catchable=capture~=nil and not e.engaged,captureReason=capture and nil or'Wilds capture adapter unavailable'}end
  end;return out
 end
 function api.resolve(k)
  self:refresh();if type(k)~='string'then return nil end
  if k:match('^wilds_of_hoenn:')then return self:resolveWild(k)end
  if self.selected=='untamed_advanced'and self.old then return self.old.resolve(k)end
 end
 -- Capture reserves/hides the entity before it asks for an owned sprite snapshot.
 -- Read the pinned handle for that transaction without making it catchable again.
 function api.cardImage(record,facing)
  self:refresh();if self.selected~='wilds_of_hoenn'then return self.old and self.old.cardImage(record,facing)end
  local key=type(record)=='table'and record.key or record
  local h=self.handles[key];local e=h and h.entity
  if not(h and h.epoch==self.epoch and h.manager==self.manager and self.manager:get(h.id)==e
   and(e.state=='available'or(e.state=='vr_capture'and e._vrCapture)))then return nil,'native card unavailable'end
  local renderer=e.renderer;if not(renderer and renderer.vrSnapshot)then return nil,'native pose unavailable'end
  local ok,p=pcall(renderer.vrSnapshot,renderer,e.px or 0,e.py or 0,0,0,facing or e.facing,e.walkPhase or 0,false)
  if not ok or not p or not p.image or not p.quad or(p.rotation or 0)~=0 then return nil,'native pose unavailable'end
  local u,v,w,h=p.quad:getViewport();local iw,ih=p.image:getDimensions();local sx,sy=p.sx or 1,p.sy or 1
  -- The consumer copies atlas texels; world-sized scaling belongs to the target card.
  return p.image,(sx<0 and u+w or u)/iw,(sy<0 and v+h or v)/ih,
   (sx<0 and u or u+w)/iw,(sy<0 and v or v+h)/ih,w,h,1,h-1
 end
 function api.busy()self:refresh();if self.selected=='wilds_of_hoenn'then return self.wild.battleTrigger and self.wild.battleTrigger.pendingId~=nil end;if self.old then return self.old.busy()end;return true end
 function api.hide(k,on)
  self:refresh()
  if self.selected=='untamed_advanced'and type(k)=='string'and not k:match('^wilds_of_hoenn:')then return self.old.hide(k,on)end
  if not self:resolveWild(k)then return false,'gone or wrong provider' end
  self.hidden[k]=on and true or nil;return true
 end
 function api.startBattle(k,preparedMon)
  self:refresh()
  if self.selected=='untamed_advanced'and type(k)=='string'and not k:match('^wilds_of_hoenn:')then return self.old.startBattle(k)end
  local e=self:resolveWild(k);if not e then return false,'gone or wrong provider'end
  local trigger=self.wild.battleTrigger
  if not(trigger and type(trigger.startForVR)=='function')then return false,'native VR battle acknowledgment unavailable'end
  local snap=self:battleSnapshotOf(k,e)
  local ok,accepted,why=pcall(trigger.startForVR,trigger,e,preparedMon)
  if not ok then return false,tostring(accepted)end
  if accepted==true then self.hidden[k]=nil;self.handoff=snap;if emit then pcall(emit,snap)end;return true end
  return false,why or'native battle refused'
 end
 for _,name in ipairs({'despawnCaught'})do
  local method=name;api[method]=function(k,...)
   self:refresh();if self.selected=='untamed_advanced'and type(k)=='string'and not k:match('^wilds_of_hoenn:')then return self.old[method](k,...)end
   -- No fake caught success, entity deletion, item use or old-provider fallback.
   return false,'Wilds capture/battle transaction integration pending'
  end
 end
 function self:battleSnapshotOf(key,e)
  local snap={key=key,provider='wilds_of_hoenn',slot=e.id,engineSpecies=e.species,species=e.species,level=e.level,personality=e.personality,shiny=e.shiny==true,x=((e.px or 0)+8)/16,z=((e.py or 0)+8)/16,cellX=e.cellX,cellY=e.cellY,facing=e.facing,water=e.terrain=='water',startedAt=(love and love.timer and love.timer.getTime and love.timer.getTime() or os.clock())}
  local poses={};local renderer=e.renderer;local phase=e.walkPhase or 0
  local raw={};self.manager:collectActors(raw);for _,actor in ipairs(raw)do if actor.kind=='wild_mon'and actor.i==e.id then phase=actor.walkPhase or phase;break end end
  if renderer and renderer.vrSnapshot then
   for _,facing in ipairs({'up','down','left','right'})do
    local ok,p=pcall(renderer.vrSnapshot,renderer,e.px or 0,e.py or 0,0,0,facing,phase,false)
    if ok and p then local u,v,w,h=p.quad:getViewport();local iw,ih=p.image:getDimensions();local sx,sy=p.sx or 1,p.sy or 1
     local u0,u1,v0,v1=u/iw,(u+w)/iw,v/ih,(v+h)/ih
     if sx<0 then u0,u1=u1,u0 end;if sy<0 then v0,v1=v1,v0 end
     poses[facing]={p.image,u0,v0,u1,v1,math.abs(w*sx),math.abs(h*sy),1,math.abs(h*sy)-1}
    end
   end
  end
  snap.cardImage=function(facing)local p=poses[facing or 'down'];if p then return unpack(p)end;return nil,'native pose unavailable'end
  return snap
 end
 function api.battleSnapshot()
  self:refresh();if self.selected=='untamed_advanced'then return self.old.battleSnapshot and self.old.battleSnapshot()end
  if self.handoff and not api.busy()then self.handoff.ended=true;self.handoff=nil end
  return self.handoff
 end
 function self:collect()
  self:refresh();if self.selected~='wilds_of_hoenn'or not visuals then return{}end
  local raw={};if self.wild.vrCollectActors then self.wild.vrCollectActors(raw)else self.manager:collectActors(raw)end
  self.visualFrame=(self.visualFrame or 0)+1;if actionCards then actionCards:beginFrame(self.visualFrame)end
  local epoch=self.epoch
  return visuals.collect(raw,{actionCards=actionCards,onUnsupported=function(a,why)self.visualError=tostring(a.kind)..': '..tostring(why)end,
   identity=function(a)return tostring(a.kind)..':'..tostring(a.i or a.renderer or a)end,
   options=function(a)
    if a.kind=='wild_mon'then
     local e=self.manager:get(a.i);if not e or e.state~='available'then return false end
     local key=self:key(e);if self.hidden[key]then return false end
     -- Engagement blocks capture, not drawing: the native Fight role owns
     -- its target pose until defeat/release. Keep identity/state guards.
     return{key=key,kind='wild',catchable=capture~=nil and not e.engaged,alive=function()
      self:refresh();local h=self.handles[key]
      return self.selected=='wilds_of_hoenn'and h~=nil and h.epoch==self.epoch
       and h.manager==self.manager and self.manager:get(h.id)==e
       and e.state=='available'and not self.hidden[key]
     end}
    end
    return{kind=a.kind,catchable=false,alive=function()return self.epoch==epoch and self.selected=='wilds_of_hoenn'end}
   end})
 end
 function api.status()self:refresh();return{provider=self.selected,epoch=self.epoch,oldSupported=true,captureReady=self.selected=='untamed_advanced'or(self.selected=='wilds_of_hoenn'and capture~=nil),nativeActivationGated=true,switchError=self.switchError,visualError=self.visualError}end
 setmetatable(api,{__index=function(_,name)
  return function(...)
   self:refresh();local fn=self.selected=='untamed_advanced'and self.old and self.old[name]
   if type(fn)=='function'then return fn(...)end
   return nil,'Wilds optional API not implemented: '..tostring(name)
  end
 end})
 self.api=api;return self
end
function M.install(mod,V)
 local visuals=V.require('compat/WildsVisuals');local actions=love and love.graphics and V.require('compat/WildsActionCards').new(love.graphics)
 local function hostReady()
  local f=mod.find('FRLG_VOXEL');local h=f and f.exports and f.exports.vrHost
  local c=h and h.actors and h.actors.capabilities
  if not(c and c.nativePixelScale and c.color and c.premultiplied and c.providerFrameShared)then return false end
  local ok,C=pcall(require,'src.core.game3.battle.catching')
  return ok and C.vrTransactionalStore==1 and actions~=nil
 end
 local router=M.new(mod.find,V.require("compat/WildsCapture"),function(snap)mod.events:emit("mod.FRLG_OW_MONS.battle_handoff",snap)end,visuals,actions,hostReady);mod.exports.overworldProvider=router;mod.exports.owMons=router.api
 local diagnosticCount=0
 local lastProvider,lastMap,lastPopulated,lastError
 local function refresh()
  router:refresh();local f=mod.find('FRLG_VOXEL');local h=f and f.exports and f.exports.vrHost
  if h and h.actors and router.registeredActors~=h.actors then h.actors.registerProvider('wilds_of_hoenn',{collect=function()return router:collect()end});router.registeredActors=h.actors end
  local count=router.manager and router.manager.order and #router.manager.order or 0
  local populated=count>0
  if diagnosticCount<24 and (diagnosticCount==0 or lastProvider~=router.selected or lastMap~=router.map or lastPopulated~=populated or lastError~=router.switchError) then
   diagnosticCount=diagnosticCount+1
   lastProvider,lastMap,lastPopulated,lastError=router.selected,router.map,populated,router.switchError
   if mod.log and mod.log.info then mod.log:info('[overworld-provider] provider=%s map=%s entities=%s reason=%s',tostring(router.selected),tostring(router.map),tostring(count),tostring(router.switchError)) end
  end
 end
 mod.events:on('mods.loaded',refresh)
 for _,event in ipairs({'map.entered','map.exited','save.loaded','checkpoint.restored'})do mod.events:on(event,function()router:reset();refresh()end)end
 mod.hooks:wrap('input.step',function(nextFn,...)local function done(...)refresh();return...end;return done(nextFn(...))end)
 refresh();return router
end
return M
