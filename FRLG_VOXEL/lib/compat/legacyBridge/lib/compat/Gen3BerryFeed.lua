-- Physical feeding uses the live native party/bag; a prop is not inventory.
local M={}
function M.apply(deps,token)
 if not token or token.attempted or token.committed then return false,'already_attempted'end
 local game=deps.runtime;local s=game and game.session
 if not(s and s==token.session and game.phase=='field'and s.map==token.map)then return false,'stale_context'end
 local Items,Bag,Use=deps.ItemsData,deps.Bag,deps.ItemUse
 local id=Items.toNumericId(token.itemId)or tonumber(token.itemId)
 if not(id and Items.pocketOf(id)=='BERRY_POUCH')then return false,'not_berry'end
 local slot
 for i,mon in ipairs(s.party or {})do if mon==token.mon then if slot then return false,'ambiguous_target'end;slot=i end end
 local mon=slot and s.party[slot]
 if not(mon and (not token.source or mon==token.source))then return false,'stale_party'end
 if mon.isEgg or mon.egg or (tonumber(mon.hp)or 0)<=0 then return false,'fainted_or_egg'end
 if not Bag.has(s.bag,id,1)then return false,'out_of_stock'end
 token.attempted=true
 local kind=Items.fieldUseKind(id)
 if kind=='heal'or kind=='status'or kind=='pp'or kind=='vitamin'then
  local moveSlot
  if kind=='pp'then
   -- Reuse the native PP maxima and eligibility calculation, not a guessed cap.
   for i=1,4 do
    if Use.ppItemHasEffect and Use.ppItemHasEffect(mon,id,i)then moveSlot=i;break end
   end
   -- A berry can still be eaten as food when all moves have full PP.
  end
  if kind~='pp'or moveSlot then
   local ok,applied,why,text=pcall(Use.useField,s,s.bag,id,slot,moveSlot)
   if not ok then return false,'native_error',tostring(applied)end
   if applied then token.committed=true;return true,why,text end
   if why~='noeffect'then return false,why,text end
  end
 end
 -- Feeding is distinct from a medicine attempt: a healthy partner may eat a
 -- berry as food. No invented stat/friendship buffs or held-item battle effect.
 if game.session~=s or s.party[slot]~=mon or not Bag.has(s.bag,id,1)then return false,'stale_context'end
 if not Bag.remove(s.bag,id,1)then return false,'out_of_stock'end
 token.committed=true;return true,'fed'
end
return M
