-- Adapt the existing Catch public library seam, entirely inside FRLG_VOXEL.
-- The Catch mod remains the owner of prompt lifetime and its canvas.
local Host=...
local Style=Host.require('compat/NativeDialogue')
local M={};local bound,original,wrapped,lastMode,lastText,lastCanvas
local function restore()
 if bound and bound.render==wrapped then bound.render=original end
 bound,original,wrapped,lastMode,lastText,lastCanvas=nil,nil,nil,nil,nil,nil
end
function M.prepare()
 local found=Host.mod.find('FRLG_CATCH');local ex=found and found.exports
 if not(ex and ex.lib and type(ex.lib.require)=='function')then restore();return false end
 local ok,card=pcall(ex.lib.require,'DialogueCard')
 if not(ok and card and type(card.render)=='function')then return false end
 if bound~=card then
  restore();bound=card;original=card.render
  local previous=original
  wrapped=function(canvas,text)
   if bound~=card then return previous(canvas,text)end
   local battle=Style.battleActive()
   local good,done=pcall(Style.render,canvas,text,battle)
   done=good and done==true
   if done then lastCanvas,lastText,lastMode=canvas,text,battle;return true end
   return previous(canvas,text)
  end
  card.render=wrapped
 end
 -- Refresh a still-visible prompt when it crosses into/out of a battle.
 local d=ex.debug
 if d and type(d.messageCanvas)=='function'and type(d.message)=='function'then
  local good,canvas=pcall(d.messageCanvas);local textOk,text=pcall(d.message)
  if good and textOk and canvas and text then
   local mode=Style.battleActive()
   if canvas~=lastCanvas or text~=lastText or mode~=lastMode then
    local drawn,styled=pcall(Style.render,canvas,text,mode)
    if drawn and styled then lastCanvas,lastText,lastMode=canvas,text,mode end
   end
  end
 end
 return true
end
function M.uninstall()restore()end
return M
