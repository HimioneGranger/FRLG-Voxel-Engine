-- Engine-owned compatibility bootstrap. This module does not own an XR frame.
-- The tiny bundled legacy-ID shim owns its normal host event/hook lifecycle.
local B={}
function B.expose(V)
 local owner=assert(V and V.mod,'engine mod required')
 local exports=assert(owner.exports,'engine exports required')
 local installed
 local ROOT='lib/compat/legacyBridge/'
 exports.legacyBridgeModule=function(name)
  assert(name=='compat/HdSpritesCompat','unsupported compatibility bootstrap module')
  return V.require('compat/legacyBridge/lib/'..name)
 end
 exports.installLegacyBridge=function(shim)
  assert(type(shim)=='table'and shim.id=='VRITK_FRLG_HOST','legacy discovery mod required')
  if installed then
   assert(installed.shim==shim,'another legacy bridge instance is already installed')
   assert(not installed.failed,installed.failed)
   return installed.exports
  end
  -- Host loader rejects duplicate IDs. Also reject a competing active handle
  -- if an integration calls this bootstrap directly outside the normal shim.
  local active=owner.find and owner.find('VRITK_FRLG_HOST')
  assert(not active or active.exports==shim.exports,'separate legacy bridge already active')
  local proxy=setmetatable({path=owner.path..'/'..ROOT:sub(1,-2),
   read=function(_,rel)return owner:read(ROOT..rel)end,
   info=function(_,rel)return owner:info(ROOT..rel)end}, {__index=shim})
  local src=assert(owner:read(ROOT..'main.lua'),'engine-owned bridge source missing')
  local chunk=assert(load(src,'@'..proxy.path..'/main.lua'))
  -- Mark before execution to prevent reentrant duplicate hook registration.
  installed={shim=shim,exports=shim.exports}
  local ok,why=pcall(chunk,proxy)
  if not ok then
   -- The host loader will retire this failed shim's hook/event registrations.
   shim.exports.active=false
   installed.failed=why
   error(why,0)
  end
  return shim.exports
 end
 return exports
end
return B
