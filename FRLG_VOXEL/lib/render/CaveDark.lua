-- FireRed native Flash state. Reused frame contract also consumed by host layers.
-- Capability can be queried before the first 3D prepare (no bootstrap dependency).
local M={};M.__index=M
local function finite(v)return type(v)=='number' and v==v and v~=math.huge and v~=-math.huge end
function M.new(engine,shaders,host,gate)
 return setmetatable({engine=engine,shaders=shaders,host=host,gate=gate,
  frame={enabled=false,center={0,0},radiusTiles=0},handled=false},M)
end
function M:coverage()
 local host=self.host
 if host and host.layers then
  local ls=host.layers
  if type(ls.order)~='table' or type(ls.byId)~='table' then return false,'unknown host coverage' end
  for _,id in ipairs(ls.order)do local e=ls.byId[id];local p=e and e.layer
   if not(e and e.failed) then
    if not p or p.nativeFlashCovered~=true then return false,'unmasked host layer: '..tostring(id) end
    if p.flashCoverage then local ok,on,why=pcall(p.flashCoverage);if not ok or on~=true then return false,'host coverage unavailable: '..tostring(id)..': '..tostring(ok and why or on) end end
   end
  end
 elseif host and host.drawEye then return false,'unknown host draw' end
 local S=self.shaders
 for _,kind in ipairs(S.DARK_KINDS)do local shader=S.get(kind)
  if not shader or not shader.hasUniform or not shader:hasUniform('u_darkOn') or not shader:hasUniform('u_darkC') or not shader:hasUniform('u_darkR') then return false,'world shader unavailable: '..tostring(kind) end
 end
 return true
end
function M:update(game,player,battle,healer)
 local f=self.frame;f.enabled=false;self.handled=false;self.required=false
 local E=self.engine;local FV=E('src.core.game3.field_view');local RT=E('src.core.game3.runtime')
 local session=RT and RT.getSession and RT.getSession()
 local world=game and (game.overworld or game.world)
 local pos=game and game.save and game.save.position
 local mapId=session and session.map or world and world.map and world.map.id or pos and pos.map
 if not FV or not FV.flashRadius or not FV.setDefaultFlashLevel or type(mapId)~='string' or not mapId:match('^FR_') then return false,'missing native Flash state' end
 -- Matches FieldView.draw; runs before the flat/3D decision, including exit.
 if FV._flashMapId~=mapId then FV.setDefaultFlashLevel(game,mapId) end
 local radius=FV.flashRadius()
 self.required=radius~=nil
 if radius==nil then self.handled=true;return true end
 if not finite(radius) or radius<0 or radius>255 then return false,'invalid native radius' end
 if not(self.gate and self.gate()) or battle or healer or not game or game.phase~='field' then return false,'non-field capability: gatePresent='..tostring(self.gate~=nil)..', phase='..tostring(game and game.phase)..', battle='..tostring(battle)..', healer='..tostring(healer) end
 if not player or not finite(player.x) or not finite(player.z) then return false,'missing world player' end
 local covered,why=self:coverage();if not covered then return false,why end
 f.center[1],f.center[2]=player.x,player.z;f.radiusTiles=radius/16;f.enabled=true
 self.handled=true;return true
end
return M
