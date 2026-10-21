-- Native Gen3 menus and selected authored rig modules, loaded only by the Gen3 host.
local V=...
local M={}
local allowed={HipRig=true,GearAdjustment=true,GearPlacementStore=true,GearPlacementView=true,PartyClipView=true,UtilityBeltLayout=true}
function M.require(name,vkV)
 if not allowed[name]then return nil end
 local path='lib/compat/gear/'..name..'.lua'
 local source=assert(V.mod:read(path),'missing Gen3 rig module '..name)
 return assert(load(source,'@'..V.mod.path..'/'..path))(vkV)
end
function M.canBegin(game)
 local Runtime=require('src.core.game3.runtime');local Stack=require('src.ui.game3.stack')
 local Battle=require('src.core.game3.battle')
 local session=Runtime.getSession()
 if not session then return false,'requires a Gen3 field' end
 if Battle.isActive() then return false,'leave battle first' end
 for _,layer in ipairs(Stack._layers or {})do
  if layer.id~='option' and layer.id~='start' then return false,'close other screens first' end
 end
 return true
end
function M.closeMenus()
 local Stack=require('src.ui.game3.stack')
 local option,start
 for _,layer in ipairs(Stack._layers or {})do
  if layer.id=='option' then option=layer.mod elseif layer.id=='start' then start=layer.mod end
 end
 if option and option.close then option.close()end
 if start and start.close then start.close(true)end
end
function M.interrupted()
 local Runtime=require('src.core.game3.runtime')
 local Battle=require('src.core.game3.battle')
 local Stack=require('src.ui.game3.stack')
 return Runtime.getSession()==nil or Battle.isActive() or Stack.busy()
end
return M
