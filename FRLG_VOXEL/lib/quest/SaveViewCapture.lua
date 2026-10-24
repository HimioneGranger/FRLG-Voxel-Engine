-- FRLG-owned clean save thumbnails. GPU canvases only; no readback or encoding.
local M={};M.__index=M
local function same(a,b)
 return a and b and a.game==b.game and a.session==b.session and a.map==b.map
  and a.x==b.x and a.y==b.y
end
local function changed(a,b)
 if not a or not b then return 'context-missing' end
 if a.game~=b.game then return 'changed-game' end
 if a.session~=b.session then return 'changed-session' end
 if a.map~=b.map then return 'changed-map' end
 if a.x~=b.x or a.y~=b.y then return 'changed-cell' end
 return 'changed-body'
end
local safeReasons={startup=true,['context-missing']=true,['changed-game']=true,['changed-session']=true,
 ['changed-map']=true,['changed-cell']=true,['changed-body']=true}
for _,key in ipairs({'no-game','no-session','game-mismatch','not-field','runtime-inactive','battle-transition',
 'renderer','not-prepared','root','xr-inactive','host-failed','transition-error','transition-active'})do safeReasons['ctx-'..key]=true end
for _,key in ipairs({'ineligible','world-missing','holding','warming','preparing','battle','mr','eye-missing'})do safeReasons['frame-'..key]=true end
local function safe(reason,fallback)return safeReasons[reason] and reason or fallback end
local function eyeCopy(e)
 if not(e and e.pose and e.pose.pos and e.pose.quat and e.fov)then return nil end
 local out={pose={pos={},quat={}},fov={}}
 for i=1,3 do out.pose.pos[i]=e.pose.pos[i]end
 for i=1,4 do out.pose.quat[i]=e.pose.quat[i]end
 for k,v in pairs(e.fov)do out.fov[k]=v end
 return out
end
local function release(c)if c and c.release then pcall(c.release,c)end end
function M.new(deps)return setmetatable({deps=deps,tokens={},count=0,inXR=false,lastRejected='startup'},M)end
function M:setInXR(on)self.inXR=on==true end
function M:_capture(ctx)
 if self.inXR or not same(ctx,self.last)then return nil,'stale-view'end
 local ok,canvas=pcall(self.deps.capture,self.last.eye,384,256)
 if not ok or not canvas then return nil,'capture-unavailable'end
 local copied,owned=pcall(self.deps.copy,canvas)
 if not copied or not owned then return nil,'copy-failed'end
 release(self.frozen);self.frozen=owned;self.frozenContext=ctx
 return owned
end
function M:afterFrame(ctx,eye,world,menu,eligible,frame,rejection)
 if self.inXR then return end
 if not ctx or not ctx.session then self:reset();self.lastRejected=safe(rejection,'context-missing');return end
 if self.last and not same(ctx,self.last)then
  self.lastRejected=changed(ctx,self.last)
  self.last=nil;release(self.frozen);self.frozen=nil;self.frozenContext=nil
 end
 if not eligible or (not world and not menu) then
  self.lastRejected=not eligible and safe(rejection,'frame-ineligible') or 'frame-world-missing'
  self.last=nil;release(self.frozen);self.frozen=nil;self.frozenContext=nil
  self.menu=menu==true;return
 end
 -- Retain the latest presented world pose even while menus are open. Native
 -- free-body settling within this logical tile does not invalidate that view.
 -- Pixels are still captured only at the menu edge or when SAVE is armed.
 if world and eligible then
  local e=eyeCopy(eye)
  if e then
   self.last={game=ctx.game,session=ctx.session,map=ctx.map,x=ctx.x,y=ctx.y,px=ctx.px,py=ctx.py,eye=e,frame=frame}
   release(self.frozen);self.frozen=nil;self.frozenContext=nil
   self.lastRejected='startup'
  elseif not self.last then self.lastRejected='frame-eye-missing'
  end
 elseif menu and not self.menu and self.last and eligible then self:_capture(ctx)end
 self.menu=menu==true
end
function M:arm(game,attemptId)
 if self.inXR then return nil,'inside-xr'end
 if attemptId==nil then return nil,'missing-attempt'end
 if self.count>=2 then return nil,'capture-slots-full'end
 local ctx,eligible,rejection=self.deps.context(game)
 if not eligible then return nil,safe(rejection,'frame-ineligible')end
 if not self.last then return nil,'no-view-'..safe(self.lastRejected,'startup')end
 if not same(ctx,self.last)then return nil,changed(ctx,self.last)end
 if not self.frozen or not same(ctx,self.frozenContext)then
  local c,why=self:_capture(ctx);if not c then return nil,why end
 end
 local ok,canvas=pcall(self.deps.copy,self.frozen)
 if not ok or not canvas then return nil,'copy-failed'end
 local token={};self.tokens[token]={canvas=canvas,attemptId=attemptId,context=ctx,frame=self.last.frame}
 self.count=self.count+1;return token
end
function M:take(token)
 if self.inXR then return nil,'inside-xr'end
 local slot=self.tokens[token];if not slot then return nil,'unknown-token'end
 return slot.canvas
end
function M:release(token)
 local slot=self.tokens[token];if not slot then return false end
 release(slot.canvas);self.tokens[token]=nil;self.count=self.count-1;return true
end
function M:reset()
 for token in pairs(self.tokens)do self:release(token)end
 release(self.frozen);self.frozen=nil;self.frozenContext=nil;self.last=nil;self.menu=false
 self.lastRejected='startup'
end
return M
