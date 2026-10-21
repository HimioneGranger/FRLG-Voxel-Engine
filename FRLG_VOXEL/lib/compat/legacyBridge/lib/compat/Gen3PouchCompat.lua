-- FireRed: VRITK's pouch as one pocket that cycles through the bag's balls
-- (the Gen2 layout), for a catch provider that asks for it (FRLG_CATCH's
-- catching.pouchCycling == true). This file only loads on generation 3
-- (VRITK_FRLG_HOST's manifest), so it never runs on Crystal/Yellow; VRITK's
-- own PouchView.lua/PouchNativeBridge.lua reach it only through
-- Gen3HostCompat's mod.find lookup, never directly.
--
-- From untamed-hook/W5_POUCH_BALLS_PATCH.md (W5 round 3), unchanged.
local M={}
function M.active(c,game)
 return type(c)=='table' and c.pouchCycling==true and type(c.cycleSelectedBall)=='function'
end
function M.slots(c,game)
 local id=c:getSelectedBall(game) or 'POKE_BALL'
 return {{id=id,name=(id:gsub('_',' ')),x=0,z=.082}}
end
-- Only an idle hovered pocket consumes the A edge (as Gen2PouchCompat.cycle).
function M.cycle(bridge,c,game,raw,eligible)
 local down=raw.a==true or raw.catchHold==true;local edge=down and bridge._gen3A==false
 bridge._gen3A=down
 if eligible and edge then c:cycleSelectedBall(game,1);return true end
 return false
end
function M.texture(c,id) -- 64x32 lining: top colour over the white lower half
 local rgb=(type(c.ballColor)=='function' and c:ballColor(id)) or {.88,.08,.12}
 local out={}
 for y=0,31 do for x=0,63 do
  local k=y>17 and {.94,.94,.91} or y>=14 and {.08,.09,.12} or rgb
  out[#out+1]=string.char(math.floor(k[1]*255),math.floor(k[2]*255),math.floor(k[3]*255),255)
 end end
 return {w=64,h=32,rgba=table.concat(out)}
end
-- A single pocket has no dividers. Stock balls have world radius .021 m
-- and the pouch scale is .65, so the local radius is .021/.65.
-- Keep the lower balls above the lining top (-.072) and all centres far
-- enough apart that the ball shells never overlap each other.
function M.stock(slot,count)
 local out={};if count<=0 then return out end
 out[1]={slot.x,.020,slot.z}
 local floorY=-.072+.021/.65+.001
 if count>=2 then out[2]={slot.x-.034,floorY,slot.z}end
 if count>=3 then out[3]={slot.x+.034,floorY,slot.z}end
 return out
end
return M
