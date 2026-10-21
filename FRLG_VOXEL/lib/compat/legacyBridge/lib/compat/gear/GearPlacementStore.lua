-- Device-wide mod-owned placement; the current sandbox has no love.filesystem.
local M={}
function M.new(mod)
 local Json=require('src.link.Json')
 local scope={save={version='vritk_settings',meta={playthroughId='hip_gear'}}}
 local keys={['hip-gear-placement.json']='gear/hip', ['floating-gear-placement.json']='gear/legacy'}
 return {
  read=function(file)
   local key=keys[file];local storage=mod.storage
   if not(key and storage and storage.read)then return nil end
   local value=storage:read(scope,key)
   return type(value)=='table' and Json.encode(value) or nil
  end,
  write=function(file,bytes)
   if file~='hip-gear-placement.json' or type(bytes)~='string' or #bytes>=4096 then return false end
   local storage=mod.storage
   if not(storage and storage.write)then return false end
   local value=Json.decode(bytes)
   if type(value)~='table' or value.version~=2 then return false end
   return storage:write(scope,keys[file],value)==true
  end
 }
end
return M
