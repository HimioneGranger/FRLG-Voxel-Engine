-- VR-only, session-local placement. Native party, health and renderer stay authoritative.
local M={LEASH=4,SEARCH=8,HOLD=1.5,STEP_TICKS=8}
local installed
local dirs={{1,0,'right'},{-1,0,'left'},{0,1,'down'},{0,-1,'up'}}
local function finite(n)return type(n)=='number'and n==n and math.abs(n)<math.huge end
local function member(s,m)for _,v in ipairs(s and s.party or{})do if v==m then return true end end end
local function healthy(m)return type(m)=='table'and not m.egg and not m.isEgg and (tonumber(m.hp)or 0)>0 end
local function key(x,y)return x..':'..y end
local function copyPose(n)return{x=n.cellX,y=n.cellY,px=n.px,py=n.py,facing=n.facing,elev=n.elevation,moving=false}end
local function put(n,p)
 n.cellX,n.cellY,n.px,n.py=p.x,p.y,p.px,p.py;n.facing=p.facing;n.elevation=p.elev
 n.moving=p.moving;n.goalX,n.goalY=nil,nil
 n.targetX,n.targetY=p.tx or p.x,p.ty or p.y;n.progress=p.progress or 0
 -- Native.update runs first next tick. Keep its interpolation inputs complete;
 -- the adapter prelude then restores the single authoritative leased progress.
 n.fromX,n.fromY,n.stepFrames=p.x*16,p.y*16,M.STEP_TICKS
end
-- Native canEnterWhy sets the mod's probe flag, so searching never starts an encounter.
local function nextCell(d,node,dir)
 local x,y=node.x+dir[1],node.y+dir[2]
 if d.player and x==d.player.cellX and y==d.player.cellY then return end
 local ok,warp=pcall(d.patch.isWarpCell,x,y)
 if not ok or warp then return end
 local good,allowed=pcall(d.patch.canEnterWhy,d.game,x,y,{fromX=node.x,fromY=node.y,dir=dir[3],surfing=false,elevation=node.elev})
 if not good or allowed~=true then return end
 local elev=node.elev
 if d.collision.nextElevation then
  local e,v=pcall(d.collision.nextElevation,d.collision._mapDef,elev or 0,x,y,node.x,node.y)
  if not e then return end;if v~=nil then elev=v end
 end
 return{x=x,y=y,elev=elev,parent=node,dir=dir[3],depth=(node.depth or 0)+1}
end
local function search(d,start,score)
 local queue,seen={start},{[key(start.x,start.y)]=true};local head,best,value=1
 while head<=#queue and head<=169 do
  local n=queue[head];head=head+1
  local v=score(n)
  if v and(not value or v<value)then best,value=n,v end
  if(n.depth or 0)<M.SEARCH*2 then
   for _,dir in ipairs(dirs)do
    local x,y=n.x+dir[1],n.y+dir[2];local k=key(x,y)
    if not seen[k]and math.abs(x-start.x)<=M.SEARCH and math.abs(y-start.y)<=M.SEARCH then
     seen[k]=true;local other=nextCell(d,n,dir);if other and #queue<169 then queue[#queue+1]=other end
    end
   end
  end
 end
 return best
end
function M.status()return installed and{installed=true,leased=installed.lease~=nil,reason=installed.reason,placements=installed.placements,steps=installed.steps}or{installed=false}end
function M.install(V,Host)
 if installed then return installed.undo end
 local found=V.mod.find('FRLG_CATCH');local lib=found and found.exports and found.exports.lib
 if not(lib and lib.require)then return function()end end
 local F=lib.require('FollowerSendOut')
 local Native=require('src.world.game3.Follower');local Runtime=require('src.core.game3.runtime')
 local Player=require('src.core.game3.player');local Collision=require('src.core.game3.collision')
 local Field=require('src.core.game3.field')
 local Battle=require('src.core.game3.battle.init');local Transition=require('src.core.game3.battle_transition')
 if not(F and F.wildsDeploy and Native and Native.current)then return function()end end
 local rec={reason='idle',placements=0,steps=0};installed=rec
 local function now()return love.timer.getTime()end
 local function clear(why)rec.lease=nil;rec.reason=why end
 local function active(l)
  local s=Runtime.getSession();local w=V.mod.find('wilds_of_hoenn')
  local api=l.owner.deps.owMons and l.owner.deps.owMons()
  return s==l.session and s.map==l.map and Runtime._game==l.game and l.game.phase=='field'
   and w and w.exports==l.ex and api and api.providerId and api.providerId()=='wilds_of_hoenn'
   and (not l.npc or Native.current()==l.npc)and member(s,l.mon)and healthy(l.mon)
   and not(Battle.isActive and Battle.isActive())and not(Transition.isActive and Transition.isActive())
   and l.owner.override and l.owner.override.mon==l.mon and not l.owner.override.recalled
   and l.fa.override and l.fa.override.mon==l.mon and l.fa.override.role=='follow'
 end
 local function step(l)
  if not active(l)then clear('context changed');return end
  if not l.npc then l.npc=Native.current();if not l.npc then return end end
  local p=l.pose;put(l.npc,p)
  -- Preserve the native swap/action/role lifecycle; a busy companion stays put.
  if l.fa:isBusy()then l.hold=now()+M.HOLD;return end
  if Field.locked or not Field.running then return end
  if l.fa.role and l.fa.role~='follow'then clear('role changed');return end
  if l.fa.action or l.fa.away or l.fa.homeRun or Player.surfing or Player.underwater then clear('native behavior');return end
  if now()<l.hold then return end
  if p.moving then
   -- Revalidate the edge before every interpolation; a new NPC may block it.
   local edge=nextCell(l,{x=p.x,y=p.y,elev=p.elev,depth=0},p.dir)
   if not edge then p.moving=false;p.px,p.py=p.x*16,p.y*16;l.path=nil;put(l.npc,p);return end
   p.progress=p.progress+1;local t=math.min(1,p.progress/M.STEP_TICKS)
   p.px,p.py=(p.x+(p.tx-p.x)*t)*16,(p.y+(p.ty-p.y)*t)*16
   if t==1 then p.x,p.y,p.elev,p.moving=p.tx,p.ty,p.nextElev,false end
   put(l.npc,p);return
  end
  local px,py=Player.cellX,Player.cellY
  if not(finite(px)and finite(py))or math.abs(px-p.x)+math.abs(py-p.y)<=M.LEASH then return end
  if l.pathX~=px or l.pathY~=py then l.path=nil;l.pathX,l.pathY=px,py end
  if not l.path or #l.path==0 then
   if now()<(l.nextSearch or 0)then return end
   l.nextSearch=now()+.25
   local dest=search(l,{x=p.x,y=p.y,elev=p.elev,depth=0},function(n)
    local distance=math.abs(n.x-px)+math.abs(n.y-py)
    if distance>=1 and distance<=2 then return(n.depth or 0)end
   end)
   if not dest then rec.reason='route blocked';return end
   local reverse={};while dest.parent do reverse[#reverse+1]=dest;dest=dest.parent end
   l.path={};for i=#reverse,1,-1 do l.path[#l.path+1]=reverse[i]end
  end
  local dest=table.remove(l.path,1);if not dest then return end
  for _,dir in ipairs(dirs)do if dest.x-p.x==dir[1]and dest.y-p.y==dir[2]then p.dir=dir;break end end
  p.tx,p.ty,p.nextElev,p.progress,p.moving,p.facing=dest.x,dest.y,dest.elev,0,true,dest.dir
  rec.steps=rec.steps+1;put(l.npc,p)
 end
 local function attach(fa)
  if rec.fa==fa then return true end
  if rec.fa then return false end -- lifecycle teardown owns the one pinned adapter
  local previous=rawget(fa,'tick');local original=fa.tick
  if type(original)~='function'then return false end
  local function wrapped(self,...)
   local l=rec.lease;if l then step(l)end
   return original(self,...)
  end
  rec.fa,rec.previous,rec.wrapped=fa,previous,wrapped;fa.tick=wrapped;return true
 end
 local original=F.wildsDeploy
 local function deploy(self,W,mon,target)
  local s=self:session();local game=Runtime._game;local w=V.mod.find('wilds_of_hoenn')
  if not(w and w.version=='1.10.1'and w.exports==W and s and s.version=='firered'and game and game.phase=='field')then return original(self,W,mon,target)end
  local fa,patch=W.followerAdapter,W.enginePatch;local n=Native.current();local origin=target and target.origin
  if not(fa and patch and type(patch.canEnterWhy)=='function'and type(patch.isWarpCell)=='function'
   and origin and finite(origin[1])and finite(origin[3])and healthy(mon)and member(s,mon)
   and finite(Player.cellX)and finite(Player.cellY)and not Player.surfing and not Player.underwater)then return false,'no_safe_throw_destination'end
  local d={game=game,patch=patch,collision=Collision,player=Player}
  -- Wilds' VR feet are (npc.px+8,npc.py+8), at the cell centre.
  local tx,ty=origin[1]/16-.5,origin[3]/16-.5
  if math.abs(tx-Player.cellX)>M.SEARCH or math.abs(ty-Player.cellY)>M.SEARCH then return false,'no_safe_throw_destination'end
  local dest=search(d,{x=Player.cellX,y=Player.cellY,elev=Player.currentElevation,depth=0},function(node)
   local distance=(node.x-tx)^2+(node.y-ty)^2
   if(node.depth or 0)>0 and distance<=4 then return distance+(node.depth or 0)*.0001 end
  end)
  if not dest or not attach(fa)then return false,'no_safe_throw_destination'end
  local ok,why=original(self,W,mon,target);if ok~=true then return ok,why end
  local p=n and copyPose(n)or{facing=Player.facing};p.x,p.y,p.px,p.py,p.elev,p.moving=dest.x,dest.y,dest.x*16,dest.y*16,dest.elev,false
  rec.lease={owner=self,ex=W,fa=fa,session=s,map=s.map,game=game,mon=mon,npc=n,pose=p,
   patch=patch,collision=Collision,player=Player,hold=now()+M.HOLD}
  if n then put(n,p)end;if self.deployed then self.deployed.cell={x=dest.x,y=dest.y}end
  -- Approach checks must use the same actual safe cell as the beam/follower.
  self:armApproach(mon,{x=dest.x,y=dest.y},s)
  rec.reason='placed';rec.placements=rec.placements+1;return ok,why
 end
 F.wildsDeploy=deploy
 local function undo()
  clear('uninstalled');if F.wildsDeploy==deploy then F.wildsDeploy=original end
  if rec.fa and rawget(rec.fa,'tick')==rec.wrapped then rec.fa.tick=rec.previous end
  if installed==rec then installed=nil end
 end
 rec.undo=undo;return undo
end
return M
