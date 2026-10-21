-- Transaction ownership lives in the provider; no provider lookup occurs after begin.
local M={}
local function copy(v)if type(v)~='table'then return v end;local o={};for k,x in pairs(v)do o[k]=copy(x)end;return o end
function M.begin(router,key,session)
 local e=router:resolveWild(key);if not e or e._vrCapture then return nil,'target unavailable'end
 local manager,epoch,map=router.manager,router.epoch,router.map
 local descriptor=copy({species=e.species,level=e.level,personality=e.personality,ivs=e.ivs,moves=e.moves,pp=e.pp,hp=e.hp,status=e.status,item=e.heldItem or e.item})
 if e.roamer then
  local roam=session and session.roamer
  if not roam or not roam.active or roam.species~=e.species or (roam.pid or roam.personality)~=e.personality then return nil,'roamer identity changed'end
  for _,field in ipairs({'level','ivs','moves','pp','hp','status'})do descriptor[field]=copy(roam[field])end
 end
 if not descriptor.species or descriptor.personality==nil then return nil,'native identity incomplete'end
 local tx={session=session,key=key,provider='wilds_of_hoenn',state='prepared'}
 local function same()return manager.mapId==map and manager:get(e.id)==e end
 function tx.valid()
  router:refresh()
  return router.selected=='wilds_of_hoenn'and router.manager==manager and router.epoch==epoch and same()and(tx.state=='prepared'and e.state=='available'and not e.engaged or tx.state=='reserved'and e._vrCapture==tx and e.state=='vr_capture'and not e.engaged)
 end
 function tx.describe()return copy(descriptor)end
 function tx.reserve()
  if not tx.valid()or tx.state~='prepared'then return false end
  tx.state='reserved';e._vrCapture=tx;e.state='vr_capture';router.hidden[key]=true;return true
 end
 function tx.cancel()
  if tx.state=='stored'then return false end
  if same()and e._vrCapture==tx then e._vrCapture=nil;e.state='available' end
  router.hidden[key]=nil;tx.state='cancelled';return true
 end
 function tx.hide(on)router.hidden[key]=on and true or nil;return true end
 function tx.store(Catching,target,ball)
  if tx.state~='reserved'or not tx.valid()then return nil,'capture owner changed'end
  if Catching.vrTransactionalStore~=1 then return nil,'transactional storage boundary missing'end
  local committed
  local ok,res=pcall(Catching.storeCaught,session,target,ball,{onStored=function(result)
   -- Native insertion has completed. Retire only the exact reserved entity.
   if same()and e._vrCapture==tx then
    manager.entities[e.id]=nil
    for i=#manager.order,1,-1 do if manager.order[i]==e.id then table.remove(manager.order,i);break end end
   end
   e._vrCapture=nil;tx.state='stored';router.hidden[key]=nil;committed=result
  end})
  if committed then return committed end
  if not ok then return nil,tostring(res)end
  return nil,res and res.reason or'store refused'
 end
 function tx.battle(mon)
  if not tx.valid()then tx.cancel();return false,'capture owner changed'end
  tx.cancel();return router.api.startBattle(key,mon or copy(descriptor))
 end
 return tx
end
return M
