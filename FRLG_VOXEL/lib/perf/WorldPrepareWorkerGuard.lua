-- CPU-worker-only lifetime. Main mod keeps its normal sandbox; no raw paths,
-- JNI or filesystem handles are exposed back through the mod API.
local G={}
local JOURNAL='quest_world_prepare_owner.txt'
local MARKER='quest_world_prepare_active.flag'
local ACK='quest_world_prepare_guard.status'
local function valid(s)return type(s)=='string'and #s>=1 and #s<=128 and s:match('^[A-Za-z0-9_.:-]+$')~=nil end
local function exactRemove(fs,path,token)if fs.read(path)==token then fs.remove(path)end end
function G.start(token,Native,fs)
 assert(valid(token),'invalid preparation owner')
 local process,why=Native.processToken();assert(valid(process),why or 'native process identity unavailable')
 local previous=fs.read(JOURNAL)
 if previous then
  local p,t=previous:match('^([^\n]+)\n([^\n]+)$')
  assert(valid(p)and valid(t),'foreign owner journal')
  -- Same-process predecessor may still execute. Only its own finally block
  -- clears this journal; cancellation is delivered over the old channel.
  assert(p~=process,'same-process preparation owner unresolved')
  exactRemove(fs,MARKER,t);exactRemove(fs,ACK,t)
  if fs.read(JOURNAL)==previous then fs.remove(JOURNAL)end
 end
 assert(not fs.read(MARKER)and not fs.read(ACK),'foreign preparation owner')
 local journal=process..'\n'..token
 assert(fs.write(JOURNAL,journal),'owner journal write failed')
 local armInvoked=false
 local function close()
  -- Serialize with the native poll before clearing durable ownership. An
  -- already-running poll must not publish a late ACK after journal removal.
  if armInvoked then
   local ok,disarmed=pcall(Native.disarm,token)
   if not(ok and disarmed==true)then return false,'native guard teardown unconfirmed'end
  end
  exactRemove(fs,MARKER,token);exactRemove(fs,ACK,token)
  if fs.read(JOURNAL)==journal then fs.remove(JOURNAL)end
  return true
 end
 local ok,reason=pcall(function()
  assert(fs.write(MARKER,token),'heartbeat write failed')
  armInvoked=true
  local armed,error=Native.arm(fs.getSaveDirectory());assert(armed,error or 'native guard rejected')
 end)
 if not ok then close();error(reason,0)end
 return close
end
G.JOURNAL=JOURNAL;G.MARKER=MARKER;G.ACK=ACK
return G
