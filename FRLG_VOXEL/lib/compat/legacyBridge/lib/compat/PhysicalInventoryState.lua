-- Presentation ownership is independent of the bag's worn/open state.
-- Inventory remains authoritative: props never remove stock when grabbed.
local M={};M.__index=M
function M.new()return setmetatable({index={berry=1,tm=1},stick={},trigger={},aux=nil},M)end
function M:reset()self.aux=nil;self.insert=nil;self.pending=nil;self.socketBlocked=false;self.stick={};self.trigger={}end
function M.kind(id)
 if id=='TM_CASE' then return 'tm_case' end
 if id=='BERRY_POUCH' then return 'berry_pouch' end
end
function M:flick(side,value)
 value=tonumber(value)or 0
 if value~=value then value=0 end
 if math.abs(value)<.25 then self.stick[side]=false end
 if math.abs(value)>.65 and self.stick[side]==false then
  self.stick[side]=true;return value<0 and -1 or 1
 end
 -- A pouch picked up with the stick already tilted must not switch/turn.
 if self.stick[side]==nil then self.stick[side]=true end
end
function M:squeeze(side,value)
 value=tonumber(value)or 0
 if value<.35 then self.trigger[side]=false end
 if value>.75 and self.trigger[side]==false then self.trigger[side]=true;return true end
 if self.trigger[side]==nil then self.trigger[side]=true end
 return false
end
function M:select(kind,rows,step)
 local n=#rows;if n==0 then self.index[kind]=1;return end
 local i=math.min(n,math.max(1,self.index[kind]or 1))
 if step then i=(i-1+step)%n+1 end
 self.index[kind]=i;return rows[i]
end
function M.validHeld(held,tracking,available)
 return held and tracking[held.hand]==true and available(held)==true
end
function M.take(row,hand,kind)
 if not row then return end
 return {id=row.id,name=row.name,count=row.count,icon=row.icon,hand=hand,
  physicalKind=kind,itemId=row.itemId or row.id,slot=row.slot or 1}
end
function M.near(a,b,r)
 if not(a and b)then return false end
 local sum=0
 for i=1,3 do local d=a[i]-b[i];if d~=d or math.abs(d)==math.huge then return false end;sum=sum+d*d end
 return sum<=r*r
end
return M
