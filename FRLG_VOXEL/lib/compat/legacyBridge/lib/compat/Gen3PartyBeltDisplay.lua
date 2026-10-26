-- FireRed's native modal stack contains UI layers, not world/battle states.
-- This predicate owns presentation only: no input, opening lease or Catch APIs.
local M={}
function M.allowed(game)
 local ok,live=pcall(require,'src.core.Game')
 if not ok or live~=game or not game or game.phase~='field' then return false end
 local save,world=game.save,game.overworld
 if not(save and type(save.party)=='table' and #save.party>0 and world and world.map and world.player)then return false end
 local stack=game.stack
 if not(stack and type(stack.top)=='function')then return false end
 -- The ordinary field and battle have no modal stack layer. Start menu,
 -- party/bag/options, dialog overlays and title transitions must hide holsters.
 if stack.top()~=nil then return false end
 local found,B=pcall(require,'src.battle.BattleState')
 if not(found and type(B)=='table' and type(B.isActive)=='function')then return false end
 if B.isActive() then
  local state=type(B.current)=='function' and B.current()
  return type(state)=='table' and not(state.demo or state.link or state.oldManTutorial
   or state.pokedude or (state.kinds and state.kinds.recordedLink)) and true or false
 end
 return true
end
return M
