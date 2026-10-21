-- Original native atlas ground only; never copies a path or plant sprite.
local M={MAX_MID=1023}
local stores=setmetatable({}, {__mode='k'})
local function mode(counts)
 local v,n=nil,0;for rgb,k in pairs(counts)do if k>n or(k==n and(v==nil or rgb<v))then v,n=rgb,k end end;return v
end
local function counts(p,keys,edge)
 local out={};if p then for i=1,256 do local v=p[i];local x,z=(i-1)%16,math.floor((i-1)/16)
  if type(v)=='number'and v>=0 and(not keys or keys[v])and(not edge or x==0 or x==15 or z==0 or z==15)then out[v]=(out[v]or 0)+1 end
 end end;return out
end
local function rect(ctx,mid)
 local a,b,c,d=ctx.underRect(mid);if type(a)=='table'then return a end
 if a~=nil then return {a,b,c,d}end
end
function M.resolve(ctx,cell,mid)
 local atlas=ctx.atlas or {};local keys=ctx.groundKeys or {};mid=mid or(cell and cell.mid)
 local palette={};for v,on in pairs(keys)do if on then palette[#palette+1]=v end end;table.sort(palette)
 local signature=table.concat(palette,',');local byAtlas=stores[atlas]
 if not byAtlas then byAtlas={};stores[atlas]=byAtlas end
 local store=byAtlas[signature]
 if not store then store={tex={},candidates={},byColor={},source={},scans=0};byAtlas[signature]=store end
 local function tex(id)
  if type(id)~='number'then return nil end
  local p=store.tex[id];if p~=nil then return p or nil end;p=false
  if type(ctx.texels)=='function'then p=ctx:texels(id)or false
  elseif type(atlas.texels)=='function'then local ok,t=pcall(atlas.texels,id,'under');if ok and type(t)=='table'and #t>=256 then p=t end end
  store.tex[id]=p;return p or nil
 end
 local source=store.source[mid]
 if not source then
  local p=tex(mid);local accepted=keys;local keyBackground=mode(counts(p,keys));local background=keyBackground
  if not background then background=mode(counts(p,nil,true))or mode(counts(p));accepted=background and {[background]=true}or {} end
  source={pixels=p,background=background,keys=accepted,keyed=keyBackground~=nil};store.source[mid]=source
 end
 local background=source.background
 if not background then return {mode='unavailable',reason='original CPU background texels unavailable'}end
 local identity=signature..':'..tostring(background)
 local function candidate(id)
  if type(id)~='number'or id==mid then return nil end
  local ck=identity..':'..id;local v=store.candidates[ck];if v~=nil then return v or nil end
  v=false;local p=tex(id);local over=type(atlas.hasOver)=='function'and atlas.hasOver(id)
  if p and not over then
   local clean=true;for i=1,256 do if not source.keys[p[i]]then clean=false;break end end
   if clean and mode(counts(p))==background and rect(ctx,id)then v=id end
  end
  store.candidates[ck]=v;return v or nil
 end
 local donor=candidate(cell and cell.nearMid)or candidate(cell and cell.groundMid)or candidate(8)or candidate(9)
 if not donor then
  local remembered=store.byColor[identity]
  if remembered==nil then
   remembered=false;store.scans=store.scans+1
   for id=0,M.MAX_MID do local found=candidate(id);if found then remembered=found;break end end
   store.byColor[identity]=remembered
  end
  donor=remembered or nil
 end
 if donor then return {uv=rect(ctx,donor),mid=donor,background=background,mode='native-tile',reason='native background-palette tile; matching modal RGB'}end
 local uv=rect(ctx,mid)
 if uv and source.pixels then for i=1,256 do if source.pixels[i]==background then
  local x,z=((i-1)%16+.5)/16,(math.floor((i-1)/16)+.5)/16
  local u,v=uv[1]+(uv[3]-uv[1])*x,uv[2]+(uv[4]-uv[2])*z
  return {uv={u,v,u,v},background=background,mode='source-background-texel',reason='no verified native plain tile; exact original background texel'}
 end end end
 return {mode='unavailable',reason='original native background UV unavailable'}
end
return M
