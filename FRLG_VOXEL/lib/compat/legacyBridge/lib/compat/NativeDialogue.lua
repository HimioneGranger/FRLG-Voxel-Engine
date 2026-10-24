-- Native typography/chrome for added VR prompts. No default-font replacement
-- and no message queue, pacing, input or gameplay changes.
local M={}
local function get(path)
 local ok,m=pcall(require,path);if ok and type(m)=='table'then return m end
end
function M.font()
 local Runtime=get('src.core.game3.runtime');local Profile=get('src.core.game3.profile')
 local s=Runtime and Runtime.getSession and Runtime.getSession()
 local profile
 if Profile and Profile.forSession then local ok,p=pcall(Profile.forSession,s);if ok then profile=p end end
 return get(profile and profile.font and profile.font.module or 'src.ui.game3.frlg_font')
end
function M.battleActive()
 local B=get('src.core.game3.battle')
 if not(B and B.isActive)then return false end
 local ok,active=pcall(B.isActive);return ok and active==true
end
function M.showOverlay(info,tabletOwns,tabletShown,enabled)
 if not tabletOwns then return true end
 info=info or {}
 if tabletShown then
  -- Preserve the established opening announcement above the tablet.
  return enabled~=false and info.battleDialogue==true and info.battleDialoguePhase=='intro'
 end
 -- A holstered tablet must not hide results, native choices or growth windows.
 return (enabled~=false and info.battleDialogue==true)or (info.window~=nil and info.window~=false)or (info.fullscreen~=nil and info.fullscreen~=false)or info.choice==true
end
function M.render(canvas,text,battle)
 local F=M.font();local C=get(battle and 'src.ui.game3.battle_chrome'or'src.ui.game3.chrome')
 if not(canvas and F and F.draw and C and love and love.graphics)then return false end
 if battle then
  if C.manifest then local ok=pcall(C.manifest);if not ok then return false end end
  if not(C._textbox and C.drawPanel)then return false end
 elseif not C.dialogueFrame then return false end
 local g=love.graphics;g.push('all')
 local ok,why=pcall(function()
  g.setCanvas(canvas);g.origin();g.setShader();g.setScissor();g.setDepthMode();g.setStencilTest()
  g.setBlendMode('alpha');g.setColor(1,1,1,1);g.clear(0,0,0,0)
  local w,h=canvas:getDimensions();g.scale(w/240,h/48);g.translate(0,-112)
  local x,y,width,colors
  if battle then
   C.drawPanel('message');if C.drawMenuFrames then C.drawMenuFrames('message')end
   x,y,width=C.messageOrigin();colors=C.textboxColors(1,6)
  else
   C.dialogueFrame();local l,t,tw=C.dialogueWindow();x,y,width=l*8,t*8+1,tw*8
   colors=F.COLOR and F.COLOR.NORMAL
  end
  local value=tostring(text or '')
  if F.wrap then value=F.wrap(value,width)end
  F.draw(value,x,y,{maxWidth=width,colors=colors})
 end)
 g.pop();return ok,why
end
-- Use the native menu window for added small controls; the same border tiles
-- used by native battle choices, with the active profile's own glyphs.
function M.button(g,x,y,w,h,text)
 local F=M.font();local W=get('src.ui.game3.window')
 if not(F and F.draw and W and W.stdFrame and W.template)then return false end
 g.push('all');local ok,why=pcall(function()
  W.stdFrame(W.template((x+8)/8,(y+8)/8,math.max(1,(w-16)/8),math.max(1,(h-16)/8)))
  local tw=F.measure and F.measure(text)or #text*6
  F.draw(text,math.floor(x+(w-tw)/2),math.floor(y+(h-14)/2),{maxWidth=w-16,colors=F.COLOR and F.COLOR.NORMAL})
 end);g.pop();return ok,why
end
function M.hint()
 local F=M.font();if not(F and F.draw and love and love.graphics)then return end
 local g=love.graphics;local c=g.newCanvas(24,32,{dpiscale=1})
 g.push('all');local ok=pcall(function()
  g.setCanvas(c);g.origin();g.setShader();g.setScissor();g.setDepthMode();g.clear(0,0,0,0)
  assert(M.button(g,0,0,24,32,'A'))
 end);g.pop()
 if not ok then c:release();return end
 c:setFilter('nearest','nearest');return c
end
return M
