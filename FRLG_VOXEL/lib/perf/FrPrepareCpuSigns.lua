-- Pure prediction only; any foreground GPU-acquire failure changes the exact
-- input key, rejects this geometry and rebuilds native through the normal path.
local Font,Profiles=...
local M={}
function M.apply(input,sign)
 input.signCompat=sign.signCompat or nil
 if not input.signCompat then input.signLabels=nil;return end
 local labels=sign.signLabels and {}or nil
 for key,label in pairs(sign.signLabels or {})do
  local xs,ys=key:match('^(%d+),(%d+)$');local x,y=tonumber(xs),tonumber(ys)
  local cell=x and y and input.cellAt(x,y)
  if cell and Profiles.style(input,cell.mid)then labels[key]=label end
 end
 for y=0,input.height-1 do for x=0,input.width-1 do local c=input.cellAt(x,y)
  if c and (c.mid==360 or c.mid==780)and c.behavior==0x84 and Profiles.style(input,c.mid)=='fr-gym'then
   labels=labels or {};local key=x..','..y
   if not labels[key]then labels[key]={gymOnly=true,reason='no-event'}end
  end
 end end
 input.signLabels=labels
 if not labels then return end
 if not sign.predictReady then input.signLabelsReady=sign.signLabelsReady;return end
 local ready={};input.signLabelsReady=ready
 for key,label in pairs(labels)do
  local xs,ys=key:match('^(%d+),(%d+)$');local x,y=tonumber(xs),tonumber(ys)
  local cell=x and input.cellAt(x,y);local style=cell and Profiles.style(input,cell.mid)
  local usable=label.title and Font.supports(label.title)
  if style=='fr-gym'and not usable then usable=true end
  if style and usable then
   local ok,p=pcall(input.atlas.signTexels or input.atlas.texels,cell.mid,'under')
   if ok and p then
    ready[key]=true
    if style~='fr-mailbox' then ready[key..'#back']=true end
    if style=='fr-gym'then local north=input.cellAt(x,y-1)
     local po=north and input.atlas.signOverTexels and input.atlas.signOverTexels(north.mid)
     if po then ready[key..'#crest']=true;if type(p[2])=='number'and p[2]>=0 then ready[key..'#crestback']=true end end
    end
   end
  end
 end
end
return M
