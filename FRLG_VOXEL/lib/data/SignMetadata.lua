-- Read imported data only. Never calls an event or changes interaction state.
local V=...
local Labels=V.require('data/SignLabels')
local M={VERSION='firered-sign-metadata-2'}
local function get(t,k)
 if type(t)~='table' then return nil end
 local ok,v=pcall(function()return t[k]end);if ok then return v end
end
local function normalize(s)
 if type(s)~='string' then return nil end
 s=s:gsub('é','E'):gsub('É','E'):gsub('’',"'"):gsub('‘',"'"):gsub('“',"'"):gsub('”',"'"):gsub('"',"'"):gsub('…','...'):gsub('–','-'):upper():gsub('_',' '):gsub(' +',' ')
 if s:find('[^A-Z0-9 .,!?%-%/:%(%)\'&]') then return nil end
 return s
end
local function mapName(id,def)
 local s=type(id)=='string' and id:gsub('^FR_',''):gsub('_CONNECTION$',''):gsub('_',' '):gsub('ROUTE(%d)','ROUTE %1')
 return normalize(s)
end
local function conns(C,def)
 if not(C and C.each and def) then return {} end
 local ok,v=pcall(C.each,def);return ok and type(v)=='table' and v or {}
end
local function directions(mapId,def,maps,C)
 local out,seen={},{}
 for _,c in ipairs(conns(C,def)) do
  local dd=get(maps,c.map);local mt=dd and tonumber(dd.mapType)
  if dd and (mt==1 or mt==2 or mt==3 or mt==6) and ({north=true,south=true,east=true,west=true})[c.dir] then
   local label=mapName(c.map,dd)
   -- The heading already names this island/area; avoid repeating that exact
   -- prefix on its connected named subareas (e.g. SEVEN ISLAND TRAINER TOWER).
   local area=mapName(mapId,def)
   if label and area and label:sub(1,#area+1)==area..' ' then label=label:sub(#area+2) end
   if label and not seen[c.dir..label] then
    local nextName
    if mt==3 or mt==6 then
     for _,nc in ipairs(conns(C,dd)) do
      local nd=get(maps,nc.map);local nt=nd and tonumber(nd.mapType)
      if nc.map~=mapId and (nt==1 or nt==2) then
       local candidate=mapName(nc.map,nd)
       if nextName and nextName~=candidate then nextName=false;break end
       nextName=candidate
      end
     end
    end
    out[#out+1]={arrow=c.dir,label=label,nextTown=nextName or nil};seen[c.dir..label]=true
   end
  end
 end
 return out
end
function M.collect(mapId,def,game,C,isSupported)
 local okSpace,Space=pcall(require,'src.core.game3.scripting.space')
 if not okSpace then Space=nil end
 local bundle=Space and Space.bundle
 local events=def and def.bgEvents
 if not events then local ev=get(bundle and bundle.events,mapId);events=ev and ev.bgEvents end
 if type(events)~='table' then return nil end
 local out={};local maps=game and game.data and game.data.maps
 local dirs=directions(mapId,def,maps,C)
 for _,ev in ipairs(events) do
  if type(ev)=='table' and type(ev.scriptKey)=='string' and ev.type=='sign' and type(ev.x)=='number' and type(ev.y)=='number'
    and (not isSupported or isSupported(ev.x,ev.y)) then
   local localBundle={scripts={},text={}}
   for _,std in ipairs({'std:3','std:4'}) do localBundle.scripts[std]=get(bundle and bundle.scripts,std) end
   local seen,count={},0
   local function snapshot(key)
    if seen[key] or count>=16 then return end;seen[key]=true;count=count+1
    local rows=get(bundle and bundle.scripts,key);localBundle.scripts[key]=rows
    if type(rows)~='table' then return end
    for i=1,math.min(#rows,64) do local row=rows[i]
     if type(row)=='table' then
      if row.op=='loadword' then local tk=row.value or row[2];if type(tk)=='string' then localBundle.text[tk]=get(bundle and bundle.text,tk) end
      elseif (row.op=='goto_if' or row.op=='call_if') and type(row.target)=='string' then snapshot(row.target) end
     end
    end
   end
   snapshot(ev.scriptKey)
   local label,reason=Labels.resolve(localBundle,ev)
   local key=ev.x..','..ev.y
   -- Duplicate background events at a single cell are ambiguous.
   if out[key] then out[key]={reason='ambiguous-background-events'}
   elseif label then
    local title=normalize(label.title)
    local authored={}
    local full=(label.fullText or ''):gsub('{UP_ARROW}','^'):gsub('{DOWN_ARROW}','v'):gsub('{LEFT_ARROW}','<'):gsub('{RIGHT_ARROW}','>')
    for line in full:gmatch('[^\n]+') do
     local symbol,destination=line:match('^%s*([%^v<>])%s*(.+)$')
     if symbol then
      local text=normalize(destination)
      if text then authored[#authored+1]={arrow=({['^']='north',v='south',['<']='west',['>']='east'})[symbol],label=text} end
     end
    end
    local isAreaTitle=title and title:gsub('ROUTE(%d)','ROUTE %1')==mapName(mapId,def)
    out[key]={title=title,scriptKey=ev.scriptKey,directions=#authored>0 and authored or (isAreaTitle and dirs or {}),reason=(not title) and 'unsupported-glyph' or nil}
   else out[key]={reason=reason,scriptKey=ev.scriptKey} end
  end
 end
 return next(out) and out or nil
end
M.normalize=normalize;M.directions=directions
M.Labels=Labels -- test seam
return M
