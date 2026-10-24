local V=...
local Guide=V.require('quest/ControlGuide')
local M={}
local showing=false
local helpModule,live
local image,drawnPage,drawnW,drawnH,currentPage
function M.installed()return M.undo~=nil end
function M.isOpen()return showing and helpModule and helpModule.open==true and live()end
function M.canvas(w,h)
 if not M.isOpen()then return nil end
 local g=love.graphics
 if image and (drawnW~=w or drawnH~=h)then image:release();image=nil end
 if not image then image=g.newCanvas(w,h,{dpiscale=1});image:setFilter('linear','linear');drawnPage=nil end
 if drawnPage~=currentPage then
  g.push('all');local ok,why=pcall(function()
   g.setCanvas(image);g.origin();g.setShader();g.setScissor();g.clear(.015,.025,.035,1)
   Guide.draw(w*.025,h*.025,w*.95,h*.95,currentPage,'A / X: NEXT     B / Y: CLOSE')
  end);g.pop();if not ok then error(why,0)end
  drawnPage,drawnW,drawnH=currentPage,w,h
 end
 return image
end
function M.install(Help,active,audio)
 if not Help or M.undo then return false end
 local originals={show=Help.show,handleInput=Help.handleInput,draw=Help.draw,close=Help.close}
 local page=1;showing=false;helpModule,live=Help,active
 local wrappers={}
 wrappers.show=function(...)
  if not active()then return originals.show(...)end
  page=1;currentPage=page;drawnPage=nil;showing=true;Help.open=true
  Help._held=nil;Help._heldFrames=0
  if audio then
   if audio.setHelpActive then pcall(audio.setHelpActive,true)end
   if audio.playSe then pcall(audio.playSe,250)end
  end
  return true
 end
 wrappers.close=function(...)
  showing=false;return originals.close(...)
 end
 wrappers.handleInput=function(input,...)
  if not showing then return originals.handleInput(input,...)end
  if not active() or input:wasPressed('b')or input:wasPressed('l')or input:wasPressed('r')then Help.close();return end
  if input:wasPressed('right')or input:wasPressed('down')or input:wasPressed('a')then page=page%#Guide.pages+1
  elseif input:wasPressed('left')or input:wasPressed('up')then page=(page-2)%#Guide.pages+1 end
  currentPage=page
 end
 wrappers.draw=function(...)
  if not showing then return originals.draw(...)end
  -- Same native modal target/coordinate system as Help, no new XR session.
  Guide.draw(0,0,240,160,page,'A: NEXT   B: CLOSE')
 end
 for k,fn in pairs(wrappers)do Help[k]=fn end
 M.undo=function()
  if showing then originals.close()end
  for k,fn in pairs(wrappers)do if Help[k]==fn then Help[k]=originals[k]end end
  showing=false;helpModule,live=nil,nil
  if image then image:release();image=nil end
  Guide.release()
  M.undo=nil
 end
 return true
end
function M.uninstall()if M.undo then M.undo()end end
return M
