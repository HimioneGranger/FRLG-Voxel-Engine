-- Physical follower medicine. Pose callbacks only sample; native writes run
-- on input.step. All identities and contact are checked again at commit.
local Host=...
local M={CONTACT_METRES=.40,MAX_AGE=.25}
local live
local function finite(x)return type(x)=='number'and x==x and math.abs(x)<math.huge end
function M.contact(point,target,scale)
 if not(point and target and finite(scale)and scale>0)then return false end
 local sum=0
 for i,k in ipairs({'x','y','z'})do
  if not(finite(point[i])and finite(target[k]))then return false end
  local size=i==2 and target.h or (i==1 and target.w or 0)
  if size~=nil and not finite(size)then return false end
  local half=math.max(0,size or 0)/2
  local d=math.max(0,math.abs(point[i]-target[k])-half);sum=sum+d*d
 end
 return sum<=(M.CONTACT_METRES*scale)^2
end
function M.new(deps)
 return setmetatable({deps=deps,armed=false,last={}}, {__index=M})
end
function M:reset()self.pending=nil;self.scene=nil;self.held=nil;self.armed=false end
function M:observe(scene,context)
 local held=scene and scene.contents and scene.contents.held
 local hand=held and held.hand
 local tracked=hand and context.hands and context.hands[hand]
 local root=scene and scene.itemHandRoot
 if not(held and (hand=='left'or hand=='right')and root and tracked and tracked.tracked
   and scene.state and scene.state.itemsAccessible
   and not(context.reservedHands and context.reservedHands[hand])
   and self.deps.supported(held.id) and self.deps.ready())then self:reset();return end
 local value=tonumber((context.controls or {})[hand=='left'and'triggerL'or'triggerR'])or 1
 if not finite(value)then value=1 end
 if self.held~=held then self.pending=nil;self.armed=false;self.held=held end
 local scale=math.sqrt(root[1]^2+root[5]^2+root[9]^2)
 local point={root[4],root[8],root[12]}
 local shown,entity,target=self.deps.target()
 local now=self.deps.now()
 self.scene={contents=scene.contents,held=held,point=point,scale=scale,at=now}
 if self.deps.claim then self.deps.claim(hand)end
 if value<=.35 then self.armed=true end
 if value>=.75 and self.armed then
  self.armed=false -- one attempt per squeeze, even when out of range
  if shown and entity and M.contact(point,target,scale)then
   local token=self.deps.token(shown,held.id)
   if token then token.entity=entity;token.held=held;token.at=now;self.pending=token end
  end
 end
end
function M:step()
 local token=self.pending;self.pending=nil
 if not token then return end
 local scene=self.scene;local age=scene and self.deps.now()-scene.at
 if not(scene and age>=0 and age<=M.MAX_AGE and self.deps.now()-token.at<=M.MAX_AGE
  and scene.contents.held==token.held and self.deps.ready())then return end
 local mon,entity,target=self.deps.target()
 if mon~=token.mon or entity~=token.entity or not M.contact(scene.point,target,scene.scale)then return end
 local ok,why,text=self.deps.apply(token)
 self.last={ok=ok==true,reason=why,item=token.itemId}
 if ok then scene.contents.held=nil;scene.contents.reason='used';self.held=nil end
 if self.deps.feedback then self.deps.feedback(token.held.hand,ok,why,text)end
end
function M.status()return live and live.last or {reason='not_installed'}end
function M.install(V)
 local Controller=V.require('QuestBackpackControl')
 local original,invalid=Controller.update,Controller.invalidate
 local Runtime=require('src.core.game3.runtime')
 local Items=require('src.core.game3.items_data')
 local Bag=require('src.core.game3.bag')
 local Use=require('src.core.game3.item_use')
 local Map=require('src.core.game3.map')
 local G3=Host.require('Game3Capture')
 local Medicine=Host.require('compat/Gen3FollowerMedicine')
 local function exports()
  local found=V.mod.find('FRLG_CATCH');return found and found.exports
 end
 local function ready()
  local game=Runtime._game
  if not G3.fieldReady(game)or G3.worldBusy()then return false end
  local ex=exports();local c=ex and ex.catching
  return c and c.canAcceptVRInput and c:canAcceptVRInput(game)==true or false
 end
 local function target()
  local ex=exports();local f=ex and ex.follower
  if not(f and f.getActiveFollowerMon and f.entityFor)then return end
  local mon=f:getActiveFollowerMon(nil,true)
  local e=mon and f:entityFor(nil,mon)
  local prop=ex.catching and ex.catching.vrThrowInput and ex.catching.vrThrowInput.ballProp
  if not(e and prop and prop.targetWorldPoint)then return end
  local x,y,z,w,h=prop:targetWorldPoint(e)
  if not x then return end
  return mon,e,{x=x,y=y,z=z,w=w,h=h}
 end
 local function supported(id)
  local n=Items.toNumericId(id);if not n then return false end
  local kind,field=Items.medicineKind(n),Items.fieldUseKind(n)
  return (kind=='heal'or kind=='status'or kind=='full_restore')
    and(field=='heal'or field=='status')and not Use.isFlute(n)
 end
 local state=M.new{
  supported=supported,ready=ready,target=target,now=function()return love.timer.getTime()end,
  token=function(mon,id)
   local s=Runtime.getSession()
   if not(s and s.map==Map.current)then return end
   return {session=s,map=s.map,mon=mon,source=mon,itemId=id}
  end,
  apply=function(token)
   if Map.current~=token.map or Runtime.getSession()~=token.session then return false,'stale_context'end
   return Medicine.apply({runtime=Runtime._game,ItemsData=Items,Bag=Bag,ItemUse=Use},token)
  end,
  claim=function(side)
   local engine=V.mod.find('FRLG_VOXEL');local vh=engine and engine.exports and engine.exports.vrHost
   if vh and vh.input and vh.input.claim then
    vh.input.claim('FRLG_VOXEL.medicine',{[side=='left'and'triggerL'or'triggerR']=true})
   end
  end,
  feedback=function(side,ok,why,text)
   V.require('InteractionHaptics').pulse(side,ok and .3 or .10,ok and .10 or .03)
   local ex=exports();local hud=ex and ex.catching and ex.catching.hud
   if hud and hud.showFeedback then
    -- Native messages include pen bytes; use plain world text for this card.
    hud:showFeedback(ok and 'Medicine used.'or 'That medicine had no effect.',2)
   end
   if Host.mod.log then Host.mod.log:info('Follower medicine: %s (%s)',tostring(ok),tostring(why))end
  end,
 }
 local update=function(self,context,...)
  local scene=original(self,context,...);state:observe(scene,context);return scene
 end
 local invalidate=function(self,...)state:reset();return invalid(self,...)end
 Controller.update=update;Controller.invalidate=invalidate;live=state
 local remove=Host.mod.hooks:wrap('input.step',function(nextFn,game,dt)
  state:step();return nextFn(game,dt)
 end)
 return function()
  state:reset();if live==state then live=nil end
  if Controller.update==update then Controller.update=original end
  if Controller.invalidate==invalidate then Controller.invalidate=invalid end
  if type(remove)=='function'then remove()end
 end
end
return M
