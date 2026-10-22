-- Engine-owned pre-onboarding barrier. No session/phase spoof, XR takeover or save writes.
local B = {}; B.__index = B
local buttons = {"a", "b", "start", "select", "up", "down", "left", "right", "l", "r"}
local function isDown(input, key)
  return input and input.isDown and input:isDown(key) == true
end
local function pressed(input, key)
  return input and input.wasPressed and input:wasPressed(key) == true
end
function B.new(ctx)
  local self = setmetatable({ctx=ctx}, B)
  self:reset()
  return self
end
function B:reset()
  if self.host then pcall(self.host.release,self.host,self.r) end
  if self.screen then self.screen:release() end
  self.screen, self.game, self.boot, self.host, self.r, self.lastCanvas = nil, nil, nil, nil, nil, nil
  self.selected,self.lastComposedFrame = nil,nil
  self.painted, self.finished, self.done, self.bPressed, self.lastFrame = false, false, false, false, nil
  self.error,self.errorWas,self.bBlocked=nil,nil,nil
  self.ctx.ready(false)
end
function B:_complete()
  self.done = true
  self.ctx.ready(true)
  if self.screen then self.screen:release(); self.screen=nil end
end
function B:hold(game)
  if not game or game.phase ~= "boot" then return false end
  if self.game ~= game or self.boot ~= game.boot then
    self:reset(); self.game,self.boot=game,game.boot
  end
  if self.done then return false end
  if not self.selected then
    local boot=game.boot
    local action=boot and boot.phase=="menu" and boot.fadeThen
    if action~="new_game" and action~="continue" then return false end
    self.selected=action
  end
  if not self.ctx.enabled() then
    if self.host then pcall(self.host.release,self.host,self.r) end
    self:_complete(); return false
  end
  local input = game.input
  if self.error then
    local b = isDown(input,"b") or pressed(input,"b")
    if self.errorWas ~= nil and b and not self.errorWas then
      self.error,self.finished,self.bPressed=nil,true,false
    end
    self.errorWas=b == true
    return true
  end
  if self.finished then
    -- Do not let an A/B held during loading skip the first native instruction.
    -- Preserve source ownership: wait for neutral rather than resetting Input.
    for _,key in ipairs(buttons) do if isDown(input,key) or pressed(input,key) then return true end end
    self:_complete()
    return false
  end
  local b = isDown(input,"b") or pressed(input,"b")
  if not self.painted then self.bBlocked = b == true
  elseif self.bBlocked then
    if not b then self.bBlocked=false end
  elseif pressed(input,"b") then self.bPressed=true end
  return true
end
function B:_paint(canvas,w,h)
  local g=love.graphics
  g.push("all")
  local ok,err=pcall(function()
    g.origin();g.setShader();g.setScissor();g.setStencilTest();g.setDepthMode();g.setMeshCullMode("none")
    g.setColorMask(true,true,true,true);g.setWireframe(false);g.setBlendMode("alpha")
    g.setColor(1,1,1,1);g.draw(canvas,0,0,0,w/canvas:getWidth(),h/canvas:getHeight())
  end)
  g.pop()
  if not ok then error(err,0) end
end
function B:draw(game,w,h,frame)
  if not self:hold(game) then return false end
  self.screen=self.screen or self.ctx.screen.new()
  local canvas
  if self.error then
    canvas=self.screen:canvas(960,640,{phase="failed",done=0,total=0,frac=0,
      continueHint="Press B to continue with on-demand loading."},self.ctx.clock())
  elseif self.finished then
    canvas=self.screen:canvas(960,640,{phase="finish",done=0,total=0,frac=0,
      continueHint="Release buttons to continue."},self.ctx.clock())
  elseif self.lastFrame == frame and self.lastCanvas then
    canvas=self.lastCanvas
  elseif not self.painted then
    -- No world resources, scene, cache validation or map planning before this first paint.
    canvas=self.screen:canvas(960,640,{phase="check",done=0,total=0,frac=0},self.ctx.clock())
  else
    local ok,err=pcall(function()
    self.r=self.r or self.ctx.renderer()
    self.host=self.host or self.ctx.host()
    if not self.host then
      -- The normal field path remains available if first-load caching is unavailable.
      error("First-load cache driver unavailable",0)
    else
      local b = self.bPressed or isDown(game.input,"b")
      local active=self.host:frame(self.r,game,false,false,false,{preintro=true,bootB=b,bootPressed=self.bPressed})
      self.bPressed=false
      if active then canvas=self.host:canvas(960,640)
      else self.finished=true end
    end
    end)
    if not ok then
      self.error,self.errorWas=tostring(err),nil
      self.ctx.log("Boot preparation failed: " .. self.error)
      if not self.host then
        local got,h=pcall(self.ctx.host)
        if got then self.host=h end
      end
      if self.host then pcall(self.host.skipSession,self.host,self.r) end
      canvas=self.screen:canvas(960,640,{phase="failed",done=0,total=0,frac=0,
        continueHint="Press B to continue with on-demand loading."},self.ctx.clock())
    elseif self.finished then
      canvas=self.screen:canvas(960,640,{phase="finish",done=0,total=0,frac=0,
        continueHint="Release buttons to continue."},self.ctx.clock())
    end
  end
  if not canvas then error("Boot preparation screen unavailable",0) end
  self:_paint(canvas,w,h)
  self.lastFrame,self.lastCanvas=frame,canvas
  -- Native artwork uses a 240x160 canvas. It is only a backing placeholder;
  -- the final render.compose pass paints this same screen at panel resolution.
  return true
end
-- Paint the retained screen directly into the final window/native panel.
-- Never update the cache here: render.boot already chose this frame's screen.
function B:needsComposite(game,frame)
  return game and game.phase=="boot" and self.game==game and self.boot==game.boot
    and self.selected~=nil and not self.done and self.lastFrame==frame
    and self.lastCanvas~=nil and self.lastComposedFrame~=frame
end
function B:composeCurrent(game,w,h,frame)
  if not game or game.phase~="boot" or self.game~=game or self.boot~=game.boot
      or not self.selected or self.done or self.lastFrame~=frame or not self.lastCanvas then return false end
  self:_paint(self.lastCanvas,w,h)
  self.painted,self.lastComposedFrame=true,frame
  if self.host and self.host.shown then self.host:presentedFrame() end
  return true
end
return B

