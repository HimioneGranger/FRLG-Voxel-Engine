-- Read-only static analysis. Never invokes a lazy loader or executes script IR.
local M={VERSION='static-sign-labels-graph-2'}
local function plain(t) return type(t)=='table' and getmetatable(t)==nil end
local function dense(t,limit)
 if not plain(t) then return nil end
 local n=0;for k in pairs(t) do if type(k)~='number' or k%1~=0 or k<1 or k>limit then return nil end;n=n+1 end
 for i=1,n do if rawget(t,i)==nil then return nil end end;return n
end
local function arg(r,k,i)
 if r[k]~=nil and r[i]~=nil and r[k]~=r[i] then return nil end
 if r[k]~=nil then return r[k] end;return r[i]
end
local arrows={['{UP_ARROW}']=true,['{DOWN_ARROW}']=true,['{LEFT_ARROW}']=true,['{RIGHT_ARROW}']=true}
local inert={lockall=true,releaseall=true,checkflag=true,checkplayergender=true,compare_var_to_value=true,copyvar=true,setvar=true,special=true,specialvar=true}
local function standard(bundle,id)
 if id~=3 and id~=4 then return false end
 local rows=rawget(bundle.scripts,'std:'..id)
 local ops=id==3 and {'lockall','message','waitmessage','waitbuttonpress','releaseall','return'} or id==4 and {'message','waitmessage','waitbuttonpress','return'}
 if not ops or dense(rows,6)~=#ops then return false end
 for i,op in ipairs(ops) do if not plain(rows[i]) or rows[i].opaque or rows[i].op~=op then return false end end
 return arg(rows[id==3 and 2 or 1],'ptr',1)==0
end
local function textInfo(rows)
 local n=dense(rows,128);if not n or n<2 then return nil end
 -- lines of the message: { text, brk } where brk is the break that ENDS the line ('nl'|'para'|'scroll'|nil)
 local parts,lines,cur={},{},{};local headDone=false;local dynamic=false
 for i=1,n do
  local r=rows[i];if not plain(r) then return nil end
  local t=r.t
  if t=='text' then
   if type(r.s)~='string' or #r.s>2048 or r.s:find('[%z\1-\31\127]') or r.s:find('[{}]') then return nil end
   parts[#parts+1]=r.s;if not headDone then cur[#cur+1]=r.s end
  elseif t=='nl' or t=='para' or t=='scroll' then
   parts[#parts+1]='\n'
   if not headDone then lines[#lines+1]={table.concat(cur),t};cur={} end
   if t=='para' then headDone=true end
  elseif t=='tag' and arrows[r.tag] then
   -- Native Mt. Chimney starts its first heading with a downward arrow.
   -- Preserve it in the full message for authored direction extraction;
   -- heading text stays glyph-free and contains the destination words.
   parts[#parts+1]=r.tag
  elseif t=='eos' then if i~=n then return nil end
  else if #lines==0 then return nil end;headDone=true;dynamic=true end
 end
 if rows[n].t~='eos' then return nil end
 if #cur>0 and not headDone then lines[#lines+1]={table.concat(cur),nil} end
 if #lines==0 then return nil end
 -- Heading = the first line, unless it is a wrapped sentence (lower case in the source and no closing
 -- punctuation): then the following lines of the same paragraph complete it. Never a half sentence.
 local function trim(x)return (x:gsub('^%s+',''):gsub('%s+$',''))end
 local head=trim(lines[1][1]);local k=1
 local wrapped=head:find('%l') and not head:find('[%.!%?]$')
 while wrapped and k<4 and lines[k][2]~='para' and lines[k+1] do
  k=k+1;head=head..' '..trim(lines[k][1])
  wrapped=not head:find('[%.!%?]$')
 end
 if wrapped then return nil end
 local title=head:gsub(' +',' '):upper()
 if title=='' or #title>160 then return nil end
 return {title=title,fullText=not dynamic and table.concat(parts) or nil}
end
function M.resolve(bundle,event)
 if not plain(event) or event.type~='sign' or type(event.scriptKey)~='string' then return nil,'not-sign' end
 if not plain(bundle) or type(bundle.scripts)~='table' or type(bundle.text)~='table' then return nil,'missing-bundle' end
 local seen,active,found={},{},{};local count=0
 local function visit(key)
  if active[key] then return false end;if seen[key] then return true end
  count=count+1;if count>16 then return false end
  local rows=rawget(bundle.scripts,key);local n=dense(rows,64);if not n or n<1 then return false end
  for _,r in ipairs(rows) do if not plain(r) or r.opaque then return false end end
  active[key]=true
  for i,r in ipairs(rows) do
   if not plain(r) or r.opaque then return false end
   local op=r.op
   if op=='loadword' then
    if arg(r,'dest',1)~=0 or type(arg(r,'value',2))~='string' or not rows[i+1] or rows[i+1].op~='callstd' then return false end
   elseif op=='callstd' then
    if i==1 or rows[i-1].op~='loadword' or not standard(bundle,arg(r,'std',1)) then return false end
    local tk=arg(rows[i-1],'value',2);local info=textInfo(rawget(bundle.text,tk));if not info then return false end
    info.textKey=tk;found[#found+1]=info
   elseif op=='goto_if' or op=='call_if' then
    -- Exported target strings coexist with numeric pointer operands, so only
    -- the named target is authoritative here. No comparison is evaluated.
    if type(r.target)~='string' or not visit(r.target) then return false end
   elseif op=='end' or op=='return' then if i~=n then return false end
   elseif not inert[op] then return false end
  end
  if rows[n].op~='end' and rows[n].op~='return' then return false end
  active[key]=nil;seen[key]=true;return true
 end
 if not visit(event.scriptKey) or #found==0 then return nil,'unsupported-script-or-heading' end
 local first=found[1];local full=first.fullText
 for i=2,#found do if found[i].title~=first.title then return nil,'variable-heading' end;if found[i].fullText~=full then full=nil end end
 return {title=first.title,fullText=full,titleOnly=not full,textKey=#found==1 and first.textKey or nil,scriptKey=event.scriptKey},nil
end
return M
