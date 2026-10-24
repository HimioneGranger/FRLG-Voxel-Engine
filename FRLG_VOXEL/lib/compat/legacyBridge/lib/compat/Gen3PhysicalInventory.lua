-- Gen3 VR item ownership, physical containers and native tablet teaching.
-- Installed into the shared kit's module tables; no loose compatibility mod.
local Host=...
local State=Host.require('compat/PhysicalInventoryState')
local Visuals=Host.require('compat/PhysicalInventoryVisuals')
local M={};local live
function M.happy(mon)
 if not live then return end
 local V=live.V;local found=V.mod.find('wilds_of_hoenn');local ex=found and found.exports
 if not(ex and ex.followerInteraction and ex.enginePatch)then return end
 if ex.nativeProviderEnabled and ex.nativeProviderEnabled()~=true then return end
 local interaction=ex.followerInteraction
 if interaction:companionMon()~=mon then return end
 local untilAt=love.timer.getTime()+2.2
 if not live.happyRestore or live.happyInteraction~=interaction then
  if live.happyRestore then live.happyRestore()end
  local old=interaction.moodKind
  local fn=function(self,...)
   local current=old(self,...)
   if current then return current end
   if live and live.happyMon==self:companionMon()and love.timer.getTime()<live.happyUntil then return 'hearts'end
  end
  interaction.moodKind=fn;live.happyInteraction=interaction
  live.happyRestore=function()if interaction.moodKind==fn then interaction.moodKind=old end end
 end
 live.happyMon=mon;live.happyUntil=untilAt
 if ex.enginePatch.playCry then pcall(ex.enginePatch.playCry,mon.species)end
end
function M.status()return live and {active=true,aux=live.state.aux and live.state.aux.id,inserted=live.state.insert~=nil}or {active=false}end
local function copy(t)local o={};for k,v in pairs(t or {})do o[k]=v end;return o end
local function p(m,v)return {m[1]*v[1]+m[2]*v[2]+m[3]*v[3]+m[4],m[5]*v[1]+m[6]*v[2]+m[7]*v[3]+m[8],m[9]*v[1]+m[10]*v[2]+m[11]*v[3]+m[12]}end
function M.install(V)
 if live then return live.undo end
 local Mat=V.require('Gen2GearCompat').matrix(V.require('Mat4'));local Rig=V.require('VRRig');local Grip=V.require('PhysicalItemGrip')
 local Models=V.require('PhysicalItemModels');local modelCache={}
 local function itemModel(id)if modelCache[id]==nil then modelCache[id]=Models.build(id)or false end;return modelCache[id]or nil end
 local Contents=V.require('BackpackContents')
 local Controller=V.require('QuestBackpackControl');local View=V.require('BackpackItemsView')
 local Rows=Host.require('compat/Gen3ContentsCompat')
 local Runtime=require('src.core.game3.runtime');local Bag=require('src.core.game3.bag')
 local Items=require('src.core.game3.items_data');local Pokemon=require('src.core.game3.pokemon');local Map=require('src.core.game3.map')
 local G3=Host.require('Game3Capture');local clock=function()return love.timer.getTime()end
 local K={state=State.new(),mist={},restores={},auxContents={},V=V};live=K
 local function wrap(t,k,make)
  local old=t[k];if type(old)~='function'then return end
  local fn=make(old);t[k]=fn;K.restores[#K.restores+1]=function()if t[k]==fn then t[k]=old end end
 end
 local function session()return Runtime.getSession()end
 local function ready()return G3.fieldReady(Runtime._game)and not G3.worldBusy()end
 local function stock(h)
  local s=session();if not(s and s.bag)then return false end
  if State.kind(h.id)then
   local c=Items.CONTAINERS[h.id=='TM_CASE'and'TM_CASE'or'BERRY_POUCH']
   return c and Bag.has(s.bag,c.item,1)==true or false
  end
  return Bag.has(s.bag,h.itemId or h.id,1)==true
 end
 local function claim(side,stick)
  local e=V.mod.find('FRLG_VOXEL');local api=e and e.exports and e.exports.vrHost
  if api and api.input and api.input.claim then
   local mask={[side=='left'and'gripL'or'gripR']=true,[side=='left'and'triggerL'or'triggerR']=true}
   if stick then mask[side=='left'and'moveStick'or'lookStick']=true end
   api.input.claim('FRLG_VOXEL.physicalItems',mask)
  end
 end
 local function pulse(side,ok)
  V.require('InteractionHaptics').pulse(side,ok and .22 or .08,ok and .06 or .025)
 end
 local function reserve(base,auxOnly)
  local out=copy(base)
  if K.state.aux then out[K.state.aux.hand]=true end
  if not auxOnly and K.controller and K.controller.contents.held then out[K.controller.contents.held.hand]=true end
  return out
 end
 local rowMeta={}
 local function rawRows(kind)
  local s=session();if not(s and s.bag)then return {}end
  local out={};local pocket=kind=='tm'and'TM_CASE'or'BERRY_POUCH'
  -- Native pocket order, including HMs-first. Bootstrap old bags once, then
  -- avoid native listPocket's full descriptions/ROM-text walk every VR frame.
  local slots=s.bag.pockets and s.bag.pockets[pocket]
  if not slots then slots=Bag.listPocket(s.bag,pocket)or {}end
  for _,row in ipairs(slots)do if (tonumber(row.qty or row.count)or 0)>0 then
   local id=row.id;local meta=rowMeta[id]
   if not meta then
    local name=Items.displayName(id);local info=Items.info(id)
    local key=(info and info.key)or tostring(name):upper():gsub('[%s%-]+','_')
    if kind=='tm'then
     local move=Pokemon.moveName(Pokemon.moveFromTmItem(id))
     if move and move~=''then name=name..'  '..move end
    end
    meta={id=key,itemId=id,name=name,
     icon=kind=='tm'and'tm-normal'or tostring(name):lower():gsub(' ','-'),
     physicalKind=kind=='tm'and(Items.isHm(id)and'usb'or'sd')or'berry'};rowMeta[id]=meta
   end
   local record=copy(meta);record.count=row.qty or row.count;out[#out+1]=record
  end end
  return out
 end
 wrap(Rows,'snapshot',function(old)return function(bagRows)
  local rows,available=old(bagRows);local out={};local s=session()
  local full=type(bagRows)=='function'and bagRows()or {}
  -- Retain the richer numeric identity before the old projection discards it.
  for _,row in ipairs(full)do
   if row.pocket~='TM_CASE'and row.pocket~='BERRY_POUCH'then
    out[#out+1]={id=row.key or tostring(row.itemId),itemId=row.itemId,name=tostring(row.name),count=row.count,
     icon=Contents.iconFor(row.key or row.itemId)}
   end
  end
  if s and s.bag then for _,kind in ipairs({'TM_CASE','BERRY_POUCH'})do
   local c=Items.CONTAINERS[kind]
   if c and Bag.has(s.bag,c.item,1)then out[#out+1]={id=kind,itemId=c.item,count=1,
    name=kind=='TM_CASE'and'TM Case'or'Berry Pouch',icon=kind:lower():gsub('_','-')}end
  end end
  return out,available
 end end)
 wrap(Contents,'refresh',function(old)return function(self,game,bagHand,accessible,tracking)
  local held=self.held;self.held=nil;old(self,game,bagHand,accessible,tracking)
  -- A different item disappearing from the bag must not cancel this prop.
  if State.validHeld(held,tracking,stock)then self.held=held end
 end end)
 wrap(Contents,'grab',function(old)return function(self,...)
  local ok=old(self,...)
  if ok and self.held then
   for _,row in ipairs(self.rows)do if row.id==self.held.id then self.held.itemId=row.itemId end end
   self.held.physicalKind=State.kind(self.held.id);self.held.open=false
  end
  return ok
 end end)
 function K:reset()
  self.state:reset();self.auxContents.held=nil;self.tablet=nil;self.controller=nil;self.context=nil;self.mist={}
 end
 local function handRoot(context,side)
  local h=context.hands and context.hands[side]
  if not(h and h.tracked and h.pose)then return end
  return Mat.mul(context.worldFromLocal,Rig.poseMatrix(h.pose))
 end
 local function root(context,held)
  local h=handRoot(context,held.hand);if not h then return end
  local kind=held.physicalKind or State.kind(held.id)
  if kind then return Mat.mul(h,Mat.translate(0,-.018,-.055))end
  local model=itemModel(held.id)
  return model and Grip.root(h,model,held.hand,K.controller and Grip.rotation(held.hand,K.controller.fits))or Mat.mul(h,Mat.translate(0,0,-.07))
 end
 -- Exactly the same shell transform used by QuestDeviceRenderer.
 local function tabletRoot(context)
  local t=K.tablet;if not(t and t.mode=='tablet'and clock()-K.tabletAt<.25)then return end
  local h=handRoot(context,'right');if not h then return end
  local a=t.tabletAnchor
  return Mat.mul(Mat.mul(Mat.mul(Mat.mul(h,Mat.translate(a[1],a[2],a[3])),Mat.rotateZ(t.tabletRotationZ or 0)),
   Mat.rotateX(t.tabletRotationX or 0)),Mat.rotateY(t.tabletRotationY or 0))
 end
 K.root=root;K.tabletRoot=tabletRoot
 local function source(held)
  return held and (held.physicalKind=='sd'or held.physicalKind=='usb')
 end
 local function insertion(context,held)
  local t=tabletRoot(context);local h=held and root(context,held)
  if not(t and h and held.hand=='left')then return end
  local isUsb=held.physicalKind=='usb';local at=p(t,{-.114,.013,isUsb and .035 or -.035})
  local tip=p(h,{0,0,isUsb and -.036 or -.0315})
  local scale=math.sqrt(t[1]^2+t[5]^2+t[9]^2)
  -- Card/plug travels -Z into the left side (+X). Both pose and distance count.
  local hs=math.sqrt(h[3]^2+h[7]^2+h[11]^2)
  local alignment=(-h[3]*t[1]-h[7]*t[5]-h[11]*t[9])/(scale*hs)
  if alignment>.45 and State.near(tip,at,.065*scale)then return at end
 end
 K.insertion=insertion
 wrap(Controller,'update',function(old)return function(self,context,...)
  K.controller=self;K.context=context
  local controls=context.controls or {};local tracking={};local edges={}
  K.previous=K.previous or {left=1,right=1}
  for _,side in ipairs({'left','right'})do
   tracking[side]=context.hands and context.hands[side]and context.hands[side].tracked==true
   local v=tonumber(controls[side=='left'and'gripL'or'gripR'])or 0
   edges[side]={press=v>=.65 and K.previous[side]<.65,release=v<=.35 and K.previous[side]>.35}
   K.previous[side]=tracking[side]and v or 1
  end
  local s=session()
  if K.session~=s or K.map~=(s and s.map)then K:reset();self.contents:reset('context_changed');K.session=s;K.map=s and s.map;rowMeta={};K.controller=self;K.context=context end
  if K.state.aux and not State.validHeld(K.state.aux,tracking,stock)then K.state.aux=nil end
  local ctx=copy(context);ctx.reservedHands=reserve(context.reservedHands)
  local scene=old(self,ctx,...)
  if not scene then K:reset();return end
  if K.auxContents.held==nil and K.auxLinked then K.state.aux=nil;K.auxLinked=false end
  local held=self.contents.held
  -- Grip release returns an unconsumed prop to storage, independent of bag state.
  if held and edges[held.hand].release then self.contents:release(held.hand);held=nil end
  local aux=K.state.aux
  if aux and edges[aux.hand].release then K.state.aux=nil;aux=nil end
  -- Transfer a card/berry to the newly free hand before taking out the tablet.
  if aux and not held then
   local other=aux.hand=='left'and'right'or'left';local h=handRoot(context,other);local ar=root(context,aux)
   local scale=ar and math.sqrt(ar[1]^2+ar[5]^2+ar[9]^2)or 1
   if edges[other].press and not(context.reservedHands or {})[other]and h and ar and State.near(p(h,{0,0,0}),p(ar,{0,0,0}),.12*scale)then aux.hand=other;pulse(other,true)end
  end
  if held then
   local kind=held.physicalKind
   local trigger=controls[held.hand=='left'and'triggerL'or'triggerR']
   if kind=='tm_case'and K.state:squeeze(held.hand,trigger)then held.open=not held.open;pulse(held.hand,true)end
   local browse=kind=='berry_pouch'or(kind=='tm_case'and held.open)
   claim(held.hand,browse)
   if browse then
    local list=rawRows(kind=='tm_case'and'tm'or'berry')
    local axis=controls[held.hand=='left'and'moveX'or'lookX']
    local step=K.state:flick(held.hand,axis);local row=K.state:select(kind=='tm_case'and'tm'or'berry',list,step)
    if step then pulse(held.hand,true)end
    scene.physicalSelection=row;scene.physicalRows=list
    local other=held.hand=='left'and'right'or'left';local hr=handRoot(context,other);local cr=root(context,held)
    local scale=cr and math.sqrt(cr[1]^2+cr[5]^2+cr[9]^2)or 1
    local hover=cr and p(cr,{0,.12,0})
    if row and not aux and other~=scene.state.hand and edges[other].press and not(context.reservedHands or {})[other]
     and hr and State.near(p(hr,{0,0,0}),hover,.12*scale)then
     aux=State.take(row,other,row.physicalKind);K.state.aux=aux;pulse(other,true)
    end
   end
   scene.itemHandRoot=handRoot(context,held.hand)
   scene.itemRoot=scene.itemHandRoot and Mat.mul(scene.itemHandRoot,Mat.mul(Mat.translate(0,0,-.07),Mat.rotateX(-math.pi/2)))
   if context.hands[held.hand].model then Grip.poseHand(context.hands[held.hand].model,held.id)end
  end
  if aux then
   claim(aux.hand,false);K.auxContents.held=aux;K.auxLinked=true
   scene.physicalMedicineContents=K.auxContents;scene.physicalMedicineRoot=root(context,aux)
   if context.hands[aux.hand].model then Grip.poseHand(context.hands[aux.hand].model,aux.id)end
   local dock=source(aux)and insertion(context,aux)
   if not dock then K.state.socketBlocked=false end
   if dock and ready()and not K.state.pending and not K.state.socketBlocked then
    K.state.socketBlocked=true;K.state.pending={held=aux,session=s,map=Map.current,at=clock()}
   end
  else K.auxContents.held=nil;K.auxLinked=false end
  scene.physicalKit=K;scene.physicalAux=aux;scene.physicalRoot=held and root(context,held)
  return scene
 end end)
 wrap(Controller,'invalidate',function(old)return function(self,...)K:reset();K.previous={left=1,right=1};return old(self,...)end end)
 -- Other hand systems receive both item reservations. Originals always see copies.
 for _,name in ipairs({'FishingRodComponent','FishingPlay','PouchView','KantoGearComponent'})do
  local ok,t=pcall(V.require,name)
  if ok and t then wrap(t,'update',function(old)return function(self,ctx,...)
   local c=copy(ctx);c.reservedHands=reserve(ctx and ctx.reservedHands);return old(self,c,...)
  end end)end
 end
 local Wear=V.require('QuestWearableInteraction')
 wrap(Wear,'update',function(old)return function(self,controls,hands,reserved,...)
  local scene=old(self,controls,hands,reserve(reserved),...)
  K.tablet=scene;K.tabletAt=clock();return scene
 end end)
 -- Prevent a held item from also auto-pointing/touching the tablet.
 local Belt=V.require('PartyBeltComponent')
 wrap(Belt,'update',function(old)return function(self,context,scene,pouch,reserved,...)
  return old(self,context,scene,pouch,reserve(reserved),...)
 end end)
 local function mesh(view,key,kind,open)
  view.physicalModels=view.physicalModels or {}
  local model=view.physicalModels[key]
  if not model then model=Visuals.build(kind,open);for _,part in ipairs(model.parts)do part.mesh=view:own(view.backend.mesh(part.vertices,part.indices))end;view.physicalModels[key]=model end
  return model
 end
 local function emit(view,out,model,at)
  for _,part in ipairs(model.parts)do out[#out+1]={mesh=part.mesh,model=at,material=part.material}end
 end
 local function billboard(at,context)
  local views=context and context.views;local pose=views and views[1]and views[1].pose
  local eye=pose and (pose.pos or pose.position)
  if not eye then return Mat.mul(at,Mat.rotateX(-math.pi/2))end
  eye=p(context.worldFromLocal,eye)
  local z={eye[1]-at[4],eye[2]-at[8],eye[3]-at[12]};local len=math.sqrt(z[1]^2+z[2]^2+z[3]^2)
  if len<1e-8 then return at end;for i=1,3 do z[i]=z[i]/len end
  local scale=math.sqrt(at[1]^2+at[5]^2+at[9]^2)
  local x={z[3],0,-z[1]};local xl=math.sqrt(x[1]^2+x[3]^2)
  if xl<1e-6 then x={1,0,0}else x={x[1]/xl,0,x[3]/xl}end
  local y={z[2]*x[3]-z[3]*x[2],z[3]*x[1]-z[1]*x[3],z[1]*x[2]-z[2]*x[1]}
  return {x[1]*scale,y[1]*scale,z[1]*scale,at[4],x[2]*scale,y[2]*scale,z[2]*scale,at[8],x[3]*scale,y[3]*scale,z[3]*scale,at[12],0,0,0,1}
 end
 local function quad(view,out,at,w,h,texture)
  out[#out+1]={mesh=view.mesh,model=Mat.mul(at,Mat.scale(w,h,1)),texture=texture,material={color={1,1,1,1}}}
 end
 local function drawHeld(view,out,held,at,context)
  local kind=held.physicalKind
  if kind and kind~='berry'then
   emit(view,out,mesh(view,kind..tostring(held.open),kind,held.open),at)
   if kind=='sd'or kind=='usb'then quad(view,out,Mat.mul(at,Mat.mul(Mat.translate(0,.004,.008),Mat.rotateX(-math.pi/2))),.032,.024,view:label('media:'..held.id,held.name))end
  elseif kind=='berry'then
   quad(view,out,billboard(at,context),.075,.075,view:icon(held.icon)or view:label('fruit',held.name))
  else
   local model=view.models[held.id]
   if model==nil then model=itemModel(held.id)or false;view.models[held.id]=model;if model then for _,part in ipairs(model.parts)do part.mesh=view:own(view.backend.mesh(part.vertices,part.indices))end end end
   if model then
    for _,part in ipairs(model.parts)do out[#out+1]={mesh=part.mesh,model=at,material=part.material,texture=part.label and view:icon(held.icon)or nil}end
   else quad(view,out,Mat.mul(at,Mat.rotateX(-math.pi/2)),.075,.075,view:icon(held.icon)or view:label('held',held.name))end
  end
 end
 wrap(View,'packets',function(old)return function(view,scene)
  local held=scene.contents.held;scene.contents.held=nil
  local ok,out=pcall(old,view,scene);scene.contents.held=held;if not ok then error(out)end
  local context=K.context;if not context then return out end
  if held and scene.physicalRoot then
   drawHeld(view,out,held,scene.physicalRoot,context)
   if scene.physicalSelection then
    local row=scene.physicalSelection;local r=Mat.mul(scene.physicalRoot,Mat.translate(0,.12,0))
    if held.physicalKind=='tm_case'then emit(view,out,mesh(view,row.physicalKind,row.physicalKind),r)
    else quad(view,out,billboard(r,context),.075,.075,view:icon(row.icon))end
    quad(view,out,billboard(Mat.mul(scene.physicalRoot,Mat.translate(0,.07,.065)),context),.20,.035,
     view:label('physical:selected',row.name..' x'..row.count))
   end
  end
  local aux=scene.physicalAux;if aux then local r=root(context,aux);if r then drawHeld(view,out,aux,r,context)end end
  local t=tabletRoot(context)
  if t then
   local ins=K.state.insert
   if ins and ins.session==session()then
    local card=ins.held;local z=card.physicalKind=='usb'and .035 or -.035
    emit(view,out,mesh(view,card.physicalKind,card.physicalKind),Mat.mul(t,Mat.mul(Mat.translate(-.132,.013,z),Mat.rotateY(-math.pi/2))))
   end
   emit(view,out,mesh(view,'ports','ports'),Mat.mul(t,Mat.translate(-.114,.013,0)))
   for _,v in ipairs({{-.035,'SD'},{.035,'USB'}})do
    quad(view,out,Mat.mul(t,Mat.mul(Mat.translate(-.09,.019,v[1]),Mat.rotateX(-math.pi/2))),.038,.016,view:label('port:'..v[2],v[2]))
   end
  end
  for i=#K.mist,1,-1 do
   local puff=K.mist[i];local age=clock()-puff.at
   if age>.48 then table.remove(K.mist,i)else
    if not view.physicalMistTexture then
     local data=love.image.newImageData(32,32)
     for y=0,31 do for x=0,31 do
      local rad=math.sqrt(((x-15.5)/16)^2+((y-15.5)/16)^2)
      data:setPixel(x,y,1,1,1,math.max(0,1-rad)^2)
     end end
     view.physicalMistTexture=view:own(love.graphics.newImage(data));data:release()
     view.physicalMistTexture:setFilter('linear','linear')
    end
    for j=1,24 do
     local f=(math.sin(j*127.1)*43758.5453)%1;local phase=(age-f*.14)/.34
     if phase>=0 and phase<=1 then
      local dist=(.025+.36*phase)*puff.scale
      local spread=(.008+.055*phase)*puff.scale;local ang=j*2.39996
      local radial=math.sqrt((math.sin(j*311.7)*96321.912)%1)
      local pos={}
      for k=1,3 do pos[k]=puff.point[k]+puff.direction[k]*dist end
      -- Spread around the nozzle direction, not around fixed screen axes.
      local d=puff.direction;local right={d[3],0,-d[1]};local rl=math.sqrt(right[1]^2+right[3]^2)
      if rl<.001 then right={1,0,0}else right={right[1]/rl,0,right[3]/rl}end
      local up={d[2]*right[3],d[3]*right[1]-d[1]*right[3],-d[2]*right[1]}
      for k=1,3 do pos[k]=pos[k]+(right[k]*math.cos(ang)+up[k]*math.sin(ang))*spread*radial end
      local radius=(.010+.018*phase)*puff.scale
      local at=Mat.mul(Mat.translate(pos[1],pos[2],pos[3]),Mat.scale(radius,radius,radius))
      out[#out+1]={mesh=view.mesh,model=billboard(at,context),texture=view.physicalMistTexture,material={color={.76,.88,1,.27*(1-phase)}},physicalMist=true}
     end
    end
   end
  end
  -- The existing backend writes opaque depth. Scope mist to read-only depth.
  if not view.physicalDrawWrapped then
   wrap(view.backend,'draw',function(draw)return function(packet,...)
    if not packet.physicalMist then return draw(packet,...)end
    local mode,write=love.graphics.getDepthMode();love.graphics.setDepthMode('lequal',false)
    local ok,why=pcall(draw,packet,...);love.graphics.setDepthMode(mode,write);if not ok then error(why)end
   end end)
   view.physicalDrawWrapped=true
   K.restores[#K.restores+1]=function()view.physicalDrawWrapped=false end
  end
  return out
 end end)
 function K:spray(held)
  if not(self.context and self.controller)then return end
  local model=itemModel(held.id);if not(model and model.nozzleDirection)then return end
  local at=root(self.context,held);if not at then return end
  local scale=math.sqrt(at[1]^2+at[5]^2+at[9]^2)
  local dir={-at[3]/scale,-at[7]/scale,-at[11]/scale}
  local def=Models.definitions[held.id];local size=def and def[3]or 1
  local tip=model.family=='canister'and{0,.026*size,-.048*size}or(model.family=='framed'and{0,.052*size,-.032*size}or{0,.059*size,-.04*size})
  self.mist[#self.mist+1]={at=clock(),point=p(at,tip),direction=dir,scale=scale}
  if #self.mist>3 then table.remove(self.mist,1)end
 end
 function K:step()
  local token=self.state.pending;self.state.pending=nil
  if not token then return end
  if token.held~=self.state.aux or clock()-token.at>.25 or session()~=token.session or Map.current~=token.map
   or not ready()or not stock(token.held)or not self.context or not insertion(self.context,token.held)then return end
  local Menu=require('src.ui.game3.party_menu')
  local s=token.session;if not(s.party and #s.party>0)then pulse(token.held.hand,false);return end
  -- Native party menu owns compatibility, overwrite prompts, consumption and HM reuse.
  token.closed=false;self.state.insert=token;self.state.aux=nil;self.auxContents.held=nil;self.auxLinked=false
  local ok,why=pcall(Menu.show,s.party,s.moveOverlay,{session=s,bag=s.bag,item=token.held.itemId,mode='use',onClose=function()token.closed=true end})
  if not ok then self.state.insert=nil;self.state.aux=token.held
   if Host.mod.log then Host.mod.log:warn('Physical TM teaching unavailable: %s',tostring(why))end
  end
 end
 local remove=Host.mod.hooks:wrap('input.step',function(nextFn,game,dt)K:step();return nextFn(game,dt)end)
 -- A canceled teaching operation returns the same card, never a duplicated inventory item.
 wrap(Controller,'update',function(old)return function(self,context,...)
  local ins=K.state.insert
  if ins and ins.closed then
   K.state.insert=nil
   local h=context.hands and context.hands[ins.held.hand]
   if session()==ins.session and stock(ins.held)and h and h.tracked and not self.contents.held and not K.state.aux then K.state.aux=ins.held end
  end
  return old(self,context,...)
 end end)
 function K.undo()
  K:reset();if K.happyRestore then K.happyRestore()end;if type(remove)=='function'then remove()end
  for i=#K.restores,1,-1 do K.restores[i]()end
  if live==K then live=nil end
 end
 return K.undo
end
function M.spray(held)if live then live:spray(held)end end
return M
