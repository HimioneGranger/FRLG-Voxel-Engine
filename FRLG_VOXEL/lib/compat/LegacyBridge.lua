-- Engine-owned compatibility: one lifecycle, no second mod folder required.
local B={}
local ROOT='lib/compat/legacyBridge/'
local LEGACY='VRITK_FRLG_HOST'
function B.expose(V)
 local owner=assert(V and V.mod,'engine mod required')
 local exports=assert(owner.exports,'engine exports required')
 if exports.compatibility then return exports.compatibility end
 local bridge={}
 exports.compatibility=bridge
 local state={exports=bridge}
 V._compatibility=state
 local find=assert(owner.find,'mod discovery required')
 -- Resolve the historical name inside this engine only. Never alter another
 -- mod's lookup or invent a loaded entry in the host's private registry.
 owner.find=function(first,second)
  local id=second==nil and first or second
  local real=find(id)
  if real then return real end
  if id==LEGACY and state.started and not state.failed then
   return {id=LEGACY,version=owner.version,exports=bridge}
  end
 end
 exports.legacyBridgeModule=function(name)
  assert(name=='compat/HdSpritesCompat','unsupported compatibility bootstrap module')
  return V.require('compat/legacyBridge/lib/'..name)
 end
 -- Old beta discovery shims may still call this. Attach the same exports
 -- without executing the implementation or registering hooks a second time.
 exports.installLegacyBridge=function(shim)
  assert(type(shim)=='table'and shim.id==LEGACY,'legacy discovery mod required')
  B.start(V)
  for key,value in pairs(bridge)do shim.exports[key]=value end
  return shim.exports
 end
 return bridge
end
function B.start(V)
 B.expose(V)
 local state=V._compatibility
 if state.started then assert(not state.failed,state.failed);return state.exports end
 local owner=V.mod
 local proxy=setmetatable({id=owner.id,exports=state.exports,
  path=owner.path..'/'..ROOT:sub(1,-2),
  read=function(_,rel)return owner:read(ROOT..rel)end,
  info=function(_,rel)return owner:info(ROOT..rel)end}, {__index=owner})
 local src=assert(owner:read(ROOT..'main.lua'),'engine-owned compatibility source missing')
 local chunk=assert(load(src,'@'..proxy.path..'/main.lua'))
 state.started=true
 local ok,why=pcall(chunk,proxy)
 if not ok then
  state.exports.active=false
  state.failed=tostring(why)
  error(why,0)
 end
 return state.exports
end
return B
