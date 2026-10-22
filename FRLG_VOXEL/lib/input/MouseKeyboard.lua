-- Engine-owned optional mouse camera and WASD. No global LOVE callbacks.
local M = {}; M.__index = M
local moves = {w=true,a=true,s=true,d=true}
local directions = {'up','left','down','right'}
local function wrap(a) return (a + math.pi) % (2*math.pi) - math.pi end
function M.new(o)
  return setmetatable({o=o, keys={}, held={}, consumed={}, focused=true},M)
end
function M:looking() return self.captured == true end
function M:release()
  if not self.captured and not next(self.keys) and not next(self.held) then return end
  if self.captured and self.o.mouse then
    pcall(self.o.mouse.setRelativeMode,false)
    if self.oldVisible ~= nil then pcall(self.o.mouse.setVisible,self.oldVisible) end
  end
  self.captured=false; self.keys={}; self.consumed={}
  if self.camera then
    self.camera.mousePitch=nil
    if self.oldSnapYaw ~= nil then self.camera.snapYaw=self.oldSnapYaw end
  end
  self.oldSnapYaw=nil
  if self.input then
    for key in pairs(self.held) do self.input:sourceRelease(key,'frlg-mouse:'..key) end
  end
  self.held={}
  if self.o.free then self.o.free.setMouseIntent(0,0,0,false) end
end
function M:focus(active)
  self.focused=active
  if not active then self:release() end
end
function M:context(allowed,camera,input,free)
  if self.o.window and self.o.window.hasFocus then
    local ok,f=pcall(self.o.window.hasFocus)
    if ok and not f then self.focused=false;self:release();return end
  end
  if self.camera ~= camera or self.input ~= input then self:release() end
  self.allowed=allowed; self.camera=camera;self.input=input;self.free=free
  if not allowed then self:release() end
end
function M:capture()
  if not (self.allowed and self.focused and self.camera and self.o.mouse
    and self.o.mouse.setRelativeMode) then return false end
  if self.o.mouse.getRelativeMode then
    local ok,already=pcall(self.o.mouse.getRelativeMode)
    if not ok or already then return false end -- another owner already captured it
  end
  local oldVisible=true
  if self.o.mouse.isVisible then
    local ok,v=pcall(self.o.mouse.isVisible)
    if ok then oldVisible=v end
  end
  local ok,result=pcall(self.o.mouse.setRelativeMode,true)
  if not ok or result==false then return false end
  if self.o.mouse.getRelativeMode then
    local got,on=pcall(self.o.mouse.getRelativeMode)
    if not got or not on then
      pcall(self.o.mouse.setRelativeMode,false)
      pcall(self.o.mouse.setVisible,oldVisible)
      return false
    end
  end
  self.oldVisible=oldVisible
  pcall(self.o.mouse.setVisible,false)
  self.captured=true
  -- Carry the actual current look into free mode, without a facing-dependent jump.
  self.oldSnapYaw=self.camera.snapYaw
  self.camera.snapYaw=self.camera.yaw or 0
  self.camera.follow=false
  self.camera.mousePitch=self.camera:monoPitch()
  -- Drop only keyboard sources held before capture, preserving other devices.
  if self.input and self.input.keyreleased then
    for k in pairs(moves) do self.input:keyreleased(k) end
  end
  return true
end
function M:pointer(ev)
  if not ev or ev.source~='mouse' then return false end
  if ev.phase=='pressed' and ev.button==1 then return self:looking() or self:capture() end
  if not self:looking() then return false end
  if ev.phase=='moved' then
    local sensitivity=tonumber(self.o.sensitivity()) or 100
    sensitivity=math.max(25,math.min(250,sensitivity))
    local dx,dy=tonumber(ev.dx) or 0,tonumber(ev.dy) or 0
    if dx~=dx or dy~=dy then return true end
    local k=0.002*sensitivity/100
    self.camera.snapYaw=wrap(self.camera.snapYaw-dx*k)
    self.camera.yaw=self.camera.snapYaw
    self.camera.mousePitch=math.max(-1.45,math.min(1.45,(self.camera.mousePitch or -0.12)-dy*k))
  end
  return true
end
function M:key(ev)
  if not ev then return false end
  local key=ev.key
  if key=='escape' and ev.phase=='pressed' and self:looking() then
    self:release(); return false -- START still opens the menu.
  end
  if not moves[key] then return false end
  if ev.phase=='released' then
    self.keys[key]=nil
    local used=self.consumed[key];self.consumed[key]=nil
    return used==true
  end
  if self:looking() and ev.phase=='pressed' then
    self.keys[key]=true;self.consumed[key]=true;return true
  end
  return false
end
function M:step()
  if not self:looking() then return end
  local sx=(self.keys.d and 1 or 0)-(self.keys.a and 1 or 0)
  local sy=(self.keys.w and 1 or 0)-(self.keys.s and 1 or 0)
  local mag=math.sqrt(sx*sx+sy*sy)
  local yaw=(self.camera.yaw or 0)+(mag>0 and math.atan2(-sx,sy) or 0)
  local x,z=-math.sin(yaw),-math.cos(yaw)
  if self.o.free then self.o.free.setMouseIntent(x,z,mag>0 and 1 or 0,true) end
  local dir=mag>0 and directions[(math.floor(yaw/(math.pi/2)+.5)%4)+1] or nil
  if self.input then
    for _,key in ipairs(directions) do
      -- Grid verbs are still needed when FreeMove hands off (bikes, warps, ledges).
      local down=dir==key
      if down and not self.held[key] then self.input:sourcePress(key,'frlg-mouse:'..key);self.held[key]=true
      elseif not down and self.held[key] then self.input:sourceRelease(key,'frlg-mouse:'..key);self.held[key]=nil end
    end
  end
end
return M
