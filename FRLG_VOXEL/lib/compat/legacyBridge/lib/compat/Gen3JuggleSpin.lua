-- Restore the existing juggle -> spin -> curve/flourish -> physical catch chain.
-- No inventory, RNG, capture storage, or new XR session ownership.
local Host=...
local Curve=Host.require('compat/JuggleCurve')
local Flourish=Host.require('compat/JuggleFlourish')
local M={};local ctx
local function pack(...)return{n=select('#',...),...}end
local function on(c)
 if not(c and type(c.enabled)=='function')then return false end
 local ok,value=pcall(c.enabled);return ok and value==true
end
local function scoped(c,key,value,fn,...)
 local before=c[key];c[key]=value;local out=pack(pcall(fn,...));c[key]=before
 if not out[1]then error(out[2],0)end;return unpack(out,2,out.n)
end
local function clear(c)
 c.t.curveCharge,c.t.curveGesture,c.t.curvePeakLatched=0,0,false
 Flourish.reset(c.t)
end
local function wrap(c,owner,key,fn)
 local old=owner[key];assert(type(old)=='function','missing spin seam '..key)
 local new=fn(old);owner[key]=new;c.undo[#c.undo+1]=function()if owner[key]==new then owner[key]=old end end
end
local function number(n)return type(n)=='number'and n==n and math.abs(n)<math.huge end
local function gesture(c,j)
 local snapshot=c.snapshot;local pose=snapshot and snapshot[j.hand=='left'and'handl'or'handr']
 local a=pose and pose.angularVelocity
 if type(a)=='table'and number(a[1])and number(a[2])and number(a[3])then return{a[1],a[2],a[3]}end
 local v=pose and pose.linearVelocity;local g=snapshot and snapshot.gaze and snapshot.gaze.direction
 local world=c.t.ballProp.worldFromRoom
 if v and g and world then
  local w=c.Free.vector(world,v);local n=math.sqrt(g[1]^2+g[3]^2)
  local scale=math.sqrt(world[1]^2+world[5]^2+world[9]^2)
  if n>.01 and scale>0 then return(-g[3]*w[1]+g[1]*w[3])/(n*scale)end
 end
 return 0
end
local function readyMessage(c)
 local hud=c.catching.hud
 if hud and type(hud.showFeedback)=='function'then pcall(hud.showFeedback,hud,'SPIN READY!',1.4)end
end
local function attach(c,owner)
 local ex=owner and owner.exports;local lib=ex and ex.lib
 local catching=ex and ex.catching;local t=catching and catching.vrThrowInput
 if not(lib and type(lib.require)=='function'and t and t.juggle and t._pouchLoftAttached==true and t._startFreeFlight and t._finishFreeContact)then return false end
 local E=c.engine
 local Catch=E('src.core.game3.battle.catching');local B=E('src.core.game3.battle');local Ui=E('src.core.game3.battle.ui');local Runtime=E('src.core.game3.runtime')
 if not(Catch and Catch.catchOdds and Catch.tryCatch and B and B.getState and B.isActive and Ui and Ui.takeCommand and Runtime and Runtime.getSession)then return false end
 local Tail=lib.require('CaptureTail');if not(Tail and Tail.request and Tail._commit)then return false end
 c.t,c.catching,c.Catch,c.B,c.Ui,c.Runtime=t,catching,Catch,B,Ui,Runtime
 c.Free=lib.require('FreeThrow');c.Juggle=lib.require('Juggle')
 c.owRequests=setmetatable({},{__mode='k'});c.G3=Host.require('Game3Capture');c.Math=lib.require('CatchMath')
 clear(c)
 wrap(c,t,'_snapshot',function(old)return function(self,...)
  local s=old(self,...);c.snapshot=s;return s
 end end)
 wrap(c,t.juggle,'reset',function(old)return function(self,...)
  clear(c);return old(self,...)
 end end)
 wrap(c,t.juggle,'step',function(old)return function(j,dt,...)
  if not on(c)then clear(c);return old(j,dt,...)end
  if j.state=='held'and number(dt)and dt>0 and dt<=.2 then
   t.curveCharge=Curve.decay(t.curveCharge,dt);t.curveGesture=gesture(c,j)
   if t.curveCharge<.8 then t.curvePeakLatched=false end
  end
  local result=pack(old(j,dt,...));local event=result[1]
  Flourish.step(t,dt,j.state)
  if event=='caught'then
   local flourish=Flourish.catch(t,t.curveCharge,j.age,j.maxRise)
   local peak;t.curveCharge,peak=Curve.catch(t.curveCharge,j.age,j.maxRise)
   if (peak and not t.curvePeakLatched)or flourish then readyMessage(c);t.curvePeakLatched=true end
   j.curveAcceleration=nil;j.curveProfile=nil
   c.stats.recatches=c.stats.recatches+1
  elseif event=='pocketed'then clear(c)end
  return unpack(result,1,result.n)
 end end)
 wrap(c,t,'_startFreeFlight',function(old)return function(self,...)
  local live=self.freeBall and self.freeBall._juggleSpin
  if on(c)and live and self.juggle.state=='airborne'and live.spinSerial==self.juggle.spinSerial then return end
  local result=pack(old(self,...));local j,flight=self.juggle,self.freeBall
  if on(c)and flight and j and j.state=='airborne'and j.velocity and not flight._juggleSpin then
   local charge=math.max(0,math.min(1,self.curveCharge or 0))
   local acceleration=Curve.acceleration(j.velocity,charge,self.curveGesture)
   j.curveAcceleration,j.curveProfile,j.curveDuration=acceleration,Curve,.9
   -- Same target-time bound as the existing curve integrator, no new aim target.
   if acceleration and j.world and j.frame then
    local origin=c.Free.point(j.world,{j.frame[4],j.frame[8],j.frame[12]})
    local v=c.Free.vector(j.world,j.velocity);local speed=math.sqrt(v[1]^2+v[3]^2);local best
    local deps=self.deps;local scale=math.sqrt(j.world[1]^2+j.world[5]^2+j.world[9]^2)
    local targets=deps.battleTargets and deps.battleTargets(scale)
    if targets==nil then local candidates,player=deps.candidates();targets=c.Free.targets(candidates,player,scale)end
    for _,target in ipairs(targets or{})do
     if target.kind=='wild'and target.center then
      local dx,dz=target.center[1]-origin[1],target.center[3]-origin[3];local d=math.sqrt(dx*dx+dz*dz)
      if d>0 and speed>0 and(dx*v[1]+dz*v[3])/(d*speed)>.82 and(not best or d<best)then best=d end
     end
    end
    if best then j.curveDuration=math.max(.4,math.min(1.4,best/speed))end
   end
   flight._juggleSpin={serial=flight.serial,spinSerial=j.spinSerial,charge=charge};flight.curveCharge=charge
   j.spin=(j.spin or 0)+charge*6;c.stats.releases=c.stats.releases+1
  end
  return unpack(result,1,result.n)
 end end)
 wrap(c,t,'_prepareFreeStep',function(old)return function(self,...)
  local before=self.juggle.world;local result=pack(old(self,...));local after=self.juggle.world
  local a=self.juggle.curveAcceleration
  if a and before and after then
   local changed=false;for i=1,16 do if math.abs(before[i]-after[i])>1e-8 then changed=true;break end end
   if changed then
    local inverse=c.Free.inverse(after)
    if inverse then self.juggle.curveAcceleration=c.Free.vector(c.Juggle.mul(inverse,before),a)end
   end
  end
  return unpack(result,1,result.n)
 end end)
 wrap(c,t,'_finishFreeContact',function(old)return function(self,...)
  local j,flight=self.juggle,self.freeBall;local hit=j and j.contact
  local receipt=flight and flight._juggleSpin
  local perfect=on(c)and hit and hit.kind=='wild'and receipt and receipt.serial==flight.serial
   and Curve.perfect(receipt.charge,j.curveAcceleration,j.age,hit.centered)==true
  if hit then hit.perfectCurve=perfect==true end
  local proof=perfect and{serial=flight.serial,ball=flight.ball,hit=hit}or nil
  return scoped(c,'contact',proof,old,self,...)
 end end)
 wrap(c,Tail,'request',function(old)return function(self,request,...)
  local proof=c.contact
  local accepted=pack(old(self,request,...))
  if accepted[1]==true and proof and request.serial==proof.serial and request.ball==proof.ball then
   c.owRequests[request]=proof
  end
  return unpack(accepted,1,accepted.n)
 end end)
 wrap(c,Tail,'_commit',function(old)return function(self,request,...)
  local proof=on(c)and c.owRequests[request]
  return scoped(c,'roll',proof and{kind='overworld',proof=proof}or nil,old,self,request,...)
 end end)
 -- Keep native spending and RNG authoritative. Scale freshly computed odds once
 -- during only the proven physical attempt; ordinary menu balls pass through.
 wrap(c,Catch,'catchOdds',function(old)return function(...)
  local base=old(...)
  if on(c)and c.Math.FIRERED_BONUS~=false and c.roll and c.roll.kind=='battle'then c.stats.lastBase,c.stats.lastBonus=base,Curve.rate(base,true);return c.stats.lastBonus end
  return base
 end end)
 wrap(c,c.Math,'bonusOdds',function(old)return function(...)
  local base=old(...)
  if on(c)and c.Math.FIRERED_BONUS~=false and c.roll and c.roll.kind=='overworld'then
   c.stats.lastBase,c.stats.lastBonus=base,Curve.rate(base,true);return c.stats.lastBonus
  end
  return base
 end end)
 wrap(c,Catch,'tryCatch',function(old)return function(item,foe,st,session,...)
  local p=c.pending;c.pending=nil
  local physical=p and p.taken and on(c)and p.st==st and p.session==session and p.foe==foe
   and p.item==c.G3.ballId(item)and(st.turn==p.turn or st.turn==p.turn+1)
  local roll=physical and{kind='battle',proof=p.proof}or c.roll
  if roll and on(c)and c.Math.FIRERED_BONUS~=false then c.stats.bonusRolls=c.stats.bonusRolls+1 end
  return scoped(c,'roll',roll,old,item,foe,st,session,...)
 end end)
 wrap(c,Ui,'takeCommand',function(old)return function(...)
  local cmd=old(...)
  if cmd and c.pending then
   if c.pending.cmd==cmd then c.pending.taken=true else c.pending=nil end
  end
  return cmd
 end end)
 c.bindBattle=function()
 local bt=catching.battleThrow
 if bt and bt~=c.battleSeam and type(bt.contact)=='function'then
  c.battleSeam=bt
  wrap(c,bt,'contact',function(old)return function(hit,ball,...)
   c.pending=nil;local result=pack(old(hit,ball,...));local proof=c.contact
   local st=B.getState and B.getState();local cmd=Ui._pendingCommand
   local info=type(bt.lastThrow)=='function'and bt.lastThrow();local blocked=info and info.blockedBy
   if result[1]==true and proof and proof.hit==hit and proof.ball==ball and st and st.wild and not st.ghostBattle
    and not st.link and not st.pokedude and not st.oldManTutorial and not blocked and cmd
    and(cmd.kind=='bag'or(cmd.kind=='safari'and cmd.action=='ball'))then
    c.pending={cmd=cmd,proof=proof,st=st,session=Runtime.getSession(),item=c.G3.ballId(ball),
     foe=Catch.targetFor and Catch.targetFor(st,cmd.battler)or st.enemy,turn=st.turn or 0}
   end
   return unpack(result,1,result.n)
  end end)
 end
 end
 c.bindBattle()
 c.error=nil;c.attached=true;return true
end
function M.install(V,enabled,deps)
 if ctx and ctx.V==V then return true end
 M.uninstall();ctx={V=V,enabled=enabled or function()return false end,engine=deps and deps.engine or require,
  undo={},stats={recatches=0,releases=0,bonusRolls=0}}
 return true
end
function M.tick()
 local c=ctx;if not c then return end
 if not c.attached then
  local owner=Host.mod and Host.mod.find and Host.mod.find('FRLG_CATCH')
  if not owner then return end
  local ok,value=pcall(attach,c,owner)
  if not ok then for i=#c.undo,1,-1 do c.undo[i]()end;c.undo={};c.error=tostring(value)end
  return
 end
 c.bindBattle()
 local p=c.pending
 if p and(not on(c)or not c.B.isActive or not c.B.isActive()or c.B.getState()~=p.st
  or c.Runtime.getSession()~=p.session or (p.taken and c.B._phase=='command')
  or(not p.taken and c.Ui._pendingCommand~=p.cmd))then c.pending=nil end
 if not on(c)then clear(c)end
end
function M.prepare(frame)
 local c=ctx;if not(c and c.attached and on(c))then return nil end
 local t,j=c.t,c.t.juggle;local e=t.spinFlourish
 if not(e and j.frame and(j.state=='held'or j.state=='airborne'))then return nil end
 local world=j.state=='airborne'and j.world or t.ballProp.worldFromRoom
 world=world or frame.worldFromLocal;if not world then return nil end
 local Mat=Host.require('Mat4');local posed=Mat.mul(world,j.frame)
 local scale=math.sqrt(posed[1]^2+posed[5]^2+posed[9]^2)
 local basis=math.sqrt(world[1]^2+world[5]^2+world[9]^2)
 if basis<=0 then return nil end
 local model=Mat.scale(scale,scale,scale)
 for _,i in ipairs{1,2,3,5,6,7,9,10,11}do model[i]=world[i]*scale/basis end
 model[4],model[8],model[12]=posed[4],posed[8],posed[12]
 if not c.renderer then c.renderer=Flourish.new(Host.require('Voxel3D'))end
 c.renderer:prepare(e)
 return{event=e,model=model,renderer=c.renderer}
end
function M.draw(record)if record then record.renderer:draw(record.event,record.model)end end
function M.status()
 local c=ctx;return c and{installed=true,attached=c.attached==true,error=c.error,
  charge=c.t and c.t.curveCharge or 0,flourish=c.t and c.t.spinFlourish~=nil,stats=c.stats}or{installed=false}
end
function M.uninstall()
 local c=ctx;if not c then return end
 for i=#c.undo,1,-1 do c.undo[i]()end
 if c.t then clear(c);local j=c.t.juggle;j.curveAcceleration=nil;j.curveProfile=nil end
 if c.renderer then c.renderer:dispose()end
 ctx=nil
end
return M
