-- Bounded render-to-texture adapter for native action draw closures.
-- No graphics monkeypatching. Caller collects/renders once per frame, before eyes.
local M={}
function M.new(g,maxCards,size)
 maxCards=maxCards or 12;size=size or 256
 assert(maxCards>=1 and maxCards<=32 and size>=64 and size<=512)
 local self={slots={},count=0,frame=nil}
 function self:beginFrame(frame)
  assert(frame~=nil);if frame~=self.frame then self.frame=frame;self.count=0 end
 end
 function self:snapshot(a)
  if type(a.draw)~='function'then return nil,'no native draw closure'end
  assert(self.frame~=nil,'beginFrame required')
  if self.count>=maxCards then return nil,'native action card budget exceeded'end
  self.count=self.count+1
  local canvas=self.slots[self.count]
  if not canvas then canvas=g.newCanvas(size,size);canvas:setFilter('nearest','nearest');self.slots[self.count]=canvas end
  g.push('all')
  local ok,err=xpcall(function()
   g.setCanvas(canvas);g.origin();g.setShader();g.setScissor();g.setDepthMode();g.setColor(1,1,1,1)
   g.setBlendMode('alpha','alphamultiply');g.clear(0,0,0,0)
   a:draw(a.x-size/2,a.y-size/2)
  end,tostring) -- Quest mods intentionally have no debug library.
  g.pop()
  if not ok then return nil,err end
  return {image=canvas,quad=g.newQuad(0,0,size,size,size,size),x=a.x-size/2,y=a.y-size/2,sx=1,sy=1,color={1,1,1,1},premultiplied=true}
 end
 function self:card(a,Visuals,opts)
  local p,why=self:snapshot(a);if not p then return nil,why end
  local proxy={x=a.x,y=a.y,kind=a.kind,facing=a.facing,renderer={vrSnapshot=function()return p end}}
  opts=opts or{};opts.shadow=false;opts.catchable=false
  local card=Visuals.card(proxy,opts);card.premultiplied=true;return card
 end
 function self:close()for _,canvas in ipairs(self.slots)do if canvas.release then canvas:release()end end;self.slots={};self.count=0 end
 return self
end
return M
