-- Choose only a verified release's identical producer identity. Existing record
-- keys and integrity checks are kept intact; this never writes or deletes cache.
local M={}
local function hex(s) return love.data.encode('string','hex',love.data.hash('md5',s)) end
local function validHex(s) return type(s)=='string' and #s==32 and not s:find('[^0-9a-f]') end
function M.decode(s)
 if type(s)~='string' or #s<40 or #s>8*1024*1024 then return nil end
 local body=s:sub(1,-17)
 if love.data.hash('md5',body)~=s:sub(-16) then return nil end
 local pos=1
 local function bytes(n)
  assert(n>=0 and pos+n-1<=#body,'short');local v=body:sub(pos,pos+n-1);pos=pos+n;return v
 end
 local function u8() return bytes(1):byte() end
 local function u32() local a,b,c,d=bytes(4):byte(1,4);return a+b*256+c*65536+d*16777216 end
 local function str(max) local n=u32();assert(n<=max,'long');return bytes(n) end
 local ok,result=pcall(function()
  assert(bytes(4)=='FRPS' and u32()==1,'format')
  local seq=u32();local token=str(32);assert(validHex(token),'token')
  u8();local n=u32();assert(n<=20000,'count')
  local seen={}
  for _=1,n do
   local k=str(65536);assert(not seen[k],'duplicate');seen[k]=true
   local status=u8();u8();bytes(16);assert(status>=1 and status<=4,'status')
  end
  assert(pos==#body+1,'trailing');return{seq=seq,token=token}
 end)
 return ok and result or nil
end
function M.select(mod,scoped,engine,game,legacy)
 if not(validHex(scoped) and validHex(engine)) then return scoped end
 local aliases=type(legacy)=='table' and legacy[scoped]
 if type(aliases)~='table' or not(mod and mod.cache and type(mod.cache.read)=='function') then return scoped end
 local codes={}
 for i,code in ipairs(aliases) do
  if i>128 then return scoped end
  if validHex(code) then codes[#codes+1]=code end
 end
 local matched={}
 -- Each mode owns its own sequence. Never compare sequence numbers across
 -- modes or fall back to an older token when the newest valid copy differs.
 for _,variant in ipairs{'vt0','vt1','default'} do
  local prefix='fr-precache/v1/prep'..(variant=='default'and''or'.'..variant)..'.'
  local best
  for _,which in ipairs{'a','b'} do
   local ok,s=pcall(mod.cache.read,mod.cache,prefix..which)
   local m=ok and M.decode(s)
   if m and (not best or m.seq>best.seq) then best=m end
  end
  if best then
   local function matches(code)
    local parts={'frpp1',tostring(game),code,engine}
    -- Older unpartitioned manifests used four fields. New default and mode
    -- manifests include the fifth field exactly as FrPrepare:_token does.
    if variant=='default'and best.token==hex(table.concat(parts,'|'))then return true end
    parts[5]=variant
    return best.token==hex(table.concat(parts,'|'))
   end
   -- Prefer an already prepared current release over any historical alias.
   if matches(scoped)then return scoped end
   for _,code in ipairs(codes)do if matches(code)then matched[code]=true end end
  end
 end
 for _,code in ipairs(codes)do if matched[code]then return code end end
 return scoped
end
return M
