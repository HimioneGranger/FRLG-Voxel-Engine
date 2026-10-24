-- Capture-only compatibility: preserve live UV artwork and native caught audio.
local M={}
local stats={snapshots=0,snapshotFailures=0,caught=0,degraded=0,restored=0}
function M.status()local out={};for k,v in pairs(stats)do out[k]=v end;return out end
local function dispose(value)if value and value.release then pcall(value.release,value)end end
function M.snapshot(api,spec,g,facing)
 local old=spec and spec.subject
 if not(api and api.cardImage and old and spec.key and g)then return nil end
 local image,u0,v0,u1,v1=api.cardImage(spec.key,facing or 'down')
 if not(image and u0 and v0 and u1 and v1)then return nil end
 local iw,ih=image:getDimensions()
 local w,h=math.floor(math.abs(u1-u0)*iw+.5),math.floor(math.abs(v1-v0)*ih+.5)
 if w<1 or h<1 then return nil end
 local canvas,quad,prior,pushed
 local ok=pcall(function()
  prior=g.getCanvas();canvas=g.newCanvas(w,h,{dpiscale=1})
  canvas:setFilter('nearest','nearest')
  quad=g.newQuad(math.min(u0,u1)*iw,math.min(v0,v1)*ih,w,h,iw,ih)
  g.push('all');pushed=true;g.setCanvas(canvas);g.origin();g.setShader()
  g.setScissor();g.setStencilTest();g.setColorMask(true,true,true,true);g.setDepthMode()
  g.clear(0,0,0,0);g.setBlendMode('replace','premultiplied');g.setColor(1,1,1,1)
  g.draw(image,quad,u1<u0 and w or 0,v1<v0 and h or 0,0,u1<u0 and -1 or 1,v1<v0 and -1 or 1)
 end)
 if pushed then pcall(g.pop)end
 pcall(g.setCanvas,prior);dispose(quad)
 if not ok then dispose(canvas);return nil end
 local sub={};for k,v in pairs(old)do sub[k]=v end
 sub.texture,sub.owned=canvas,true
 return sub
end
local function apiFor(V,Host)
 local exports=Host and Host.mod and Host.mod.exports
 if exports and exports.owMons then return exports.owMons end
 local find=V.mod and V.mod.find
 if not find then return nil end
 local voxel=find('FRLG_VOXEL');local get=voxel and voxel.exports and voxel.exports.getCompatibilityHost
 local bridge=type(get)=='function'and get()or find('VRITK_FRLG_HOST')
 local api=bridge and bridge.exports and bridge.exports.owMons
 if api then return api end
 local owner=find('FRLG_OW_MONS');return owner and owner.exports and owner.exports.owMons
end
local function facingFor(V,key)
 local voxel=V.mod and V.mod.find and V.mod.find('FRLG_VOXEL')
 local host=voxel and voxel.exports and voxel.exports.vrHost
 local targets=host and host.actors and host.actors.targets
 if type(targets)=='function'then
  local snap=targets()
  for _,t in ipairs(snap and snap.list or {})do if t.key==key then return t.facing end end
 end
end
function M.install(V,Host)
 local owner=V.mod and V.mod.find and V.mod.find('FRLG_CATCH')
 local lib=owner and owner.exports and owner.exports.lib
 if not(lib and type(lib.require)=='function')then return nil,'capture-library-unavailable'end
 local FX,Tail=lib.require('CaptureFX'),lib.require('CaptureTail')
 if not(FX and type(FX.begin)=='function'and Tail and type(Tail._caught)=='function'and type(Tail.step)=='function')then
  return nil,'capture-seams-unavailable'
 end
 local originalBegin,originalCaught,originalStep=FX.begin,Tail._caught,Tail.step
 local seen=setmetatable({},{__mode='k'});local pending=setmetatable({},{__mode='k'});local live=true
 local function audio()
  local requireEngine=Host and Host.engine or require
  local ok,a=pcall(requireEngine,'src.core.game3.audio');return ok and a or nil
 end
 local function valid(t,p)
  return live and t.deps and t.deps.session and t.deps.session()==p.session
   and p.session.map==p.map
 end
 local function current(a)local c=a.currentSong and a.currentSong();return c and c.id end
 local function restore(t,p)
  if p.started and valid(t,p)and current(p.audio)==p.song and p.audio.restoreMapSong then
   pcall(p.audio.restoreMapSong,{restart=true});stats.restored=stats.restored+1
  end
 end
 local begin=function(self,spec,...)
  -- Battle subjects have no overworld provider key and keep their native path.
  local ok,sub=pcall(function()
   return M.snapshot(apiFor(V,Host),spec,love and love.graphics,facingFor(V,spec and spec.key))
  end)
  if not ok or not sub then
   if spec and spec.subject then stats.snapshotFailures=stats.snapshotFailures+1 end
   return originalBegin(self,spec,...)
  end
  local adjusted={};for k,v in pairs(spec)do adjusted[k]=v end;adjusted.subject=sub
  local called,result=pcall(originalBegin,self,adjusted,...)
  if called and result==true and spec.subject.owned then dispose(spec.subject.texture)end
  local cap=self.cap or(self.useNative and self.native and self.native.cap)
  if not(cap and cap.subject and cap.subject.texture==sub.texture)then dispose(sub.texture)end
  if not called then error(result,0)end
  stats.snapshots=stats.snapshots+1;return result
 end
 local caught=function(self,cur,...)
  local before=self.last
  local result=originalCaught(self,cur,...)
  if result==true and not seen[cur]and self.last~=before and self.last and self.last.outcome=='caught'then
   seen[cur]=true;stats.caught=stats.caught+1
   local audioOk=pcall(function()
   local a=audio();local session=cur.session or(self.deps.session and self.deps.session())
   if a and session and a.playSe then
    local song=a.resolveSong and a.resolveSong('MUS_CAUGHT')or nil
    local intro=a.resolveSong and a.resolveSong('MUS_CAUGHT_INTRO')or nil
    local previous=pending[self];if previous then restore(self,previous)end
    local player=Host and Host.engine and Host.engine('src.core.game3.player')or require('src.core.game3.player')
    local function uiBusy()
     local d=self.deps
     if d.Choice and d.Choice.active then return true end
     if d.Message and d.Message.isOpen and d.Message.isOpen()then return true end
     local r=Host and Host.engine and Host.engine('src.core.game3.runtime')or require('src.core.game3.runtime')
     return r and r.uiBusy and r.uiBusy()==true or false
    end
    local p={audio=a,session=session,map=session.map,song=song,previous=current(a),cur=cur,
     player=player,x=player and player.cellX,y=player and player.cellY,uiBusy=uiBusy,hadUI=uiBusy()}
    pending[self]=p
    local function start()
     local startedOk=pcall(function()
     if pending[self]~=p or not valid(self,p)or current(a)~=p.previous then return end
     if type(song)=='number'and a.playSong then
      local played,value=pcall(a.playSong,song)
      if played and value~=false then p.started=true end
     else stats.degraded=stats.degraded+1;pending[self]=nil end
     end)
     if not startedOk then pending[self]=nil;stats.degraded=stats.degraded+1 end
    end
    if type(intro)=='number'then
     pcall(a.playSe,intro)
     if a.waitSe then pcall(a.waitSe,intro,start)else start()end
    else stats.degraded=stats.degraded+1;pending[self]=nil end
   end
   end)
   if not audioOk then pending[self]=nil;stats.degraded=stats.degraded+1 end
  end
  return result
 end
 local step=function(self,dt,...)
  local result=originalStep(self,dt,...)
  local audioOk=pcall(function()
  local p=pending[self]
  if p then
   if not valid(self,p)then pending[self]=nil
   else
     local busy=p.uiBusy();if busy then p.hadUI=true end
     local player=p.player
     local moved=player and (player.moving or player.cellX~=p.x or player.cellY~=p.y)
     local nextCatch=self.cur and self.cur~=p.cur
     if p.started and current(p.audio)~=p.song then pending[self]=nil
     elseif (p.hadUI and not busy)or moved or nextCatch then restore(self,p);pending[self]=nil end
   end
  end
  end)
  if not audioOk then pending[self]=nil;stats.degraded=stats.degraded+1 end
  return result
 end
 FX.begin,Tail._caught,Tail.step=begin,caught,step
 return function()
  for t,p in pairs(pending)do pcall(restore,t,p)end;live=false
  if FX.begin==begin then FX.begin=originalBegin end
  if Tail._caught==caught then Tail._caught=originalCaught end
  if Tail.step==step then Tail.step=originalStep end
 end
end
return M
