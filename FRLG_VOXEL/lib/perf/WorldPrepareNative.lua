-- Capability arm for an engine-owned CPU worker or main thread. Exact3232 SDL
-- obtains/attaches a thread-local JNIEnv; never transfer JNI refs across threads.
-- Worker must require('love.system') before use. It owns its separate heartbeat.
local M = {}
M.MARKER = 'quest_world_prepare_active.flag'
M.STATUS = 'quest_world_prepare_guard.status'
-- Calling-thread process identity for recovery journals. Stable across Activity
-- recreation; changes after process death. Never substitute a Lua timestamp.
function M.processToken()
  if not (love and love.system and love.system.getOS and love.system.getOS() == 'Android') then
    return nil, 'not-android'
  end
  local loaded, ffi = pcall(require, 'ffi')
  if not loaded then return nil, 'ffi-unavailable' end
  if not pcall(ffi.cdef, [[void *SDL_AndroidGetJNIEnv(void); void *SDL_AndroidGetActivity(void);]]) then
    return nil, 'jni-definition-unavailable'
  end
  local env, activity, cls, str, chars, deleteRef, releaseChars, check, clear
  local function failed()
    if check(env) ~= 0 then clear(env); return true end
    return false
  end
  local ok, token, reason = pcall(function()
    env = ffi.C.SDL_AndroidGetJNIEnv()
    if env == nil then return nil, 'no-jni-environment' end
    local fns = ffi.cast('void***', env)[0]
    check = ffi.cast('unsigned char (*)(void*)', fns[228])
    clear = ffi.cast('void (*)(void*)', fns[17])
    deleteRef = ffi.cast('void (*)(void*,void*)', fns[23])
    releaseChars = ffi.cast('void (*)(void*,void*,const char*)', fns[170])
    if check(env) ~= 0 then return nil, 'preexisting-jni-exception' end
    activity = ffi.C.SDL_AndroidGetActivity()
    if failed() or activity == nil then return nil, 'no-activity' end
    cls = ffi.cast('void* (*)(void*,void*)', fns[31])(env, activity)
    if failed() or cls == nil then return nil, 'no-activity-class' end
    local method = ffi.cast('void* (*)(void*,void*,const char*,const char*)', fns[33])(
      env, cls, 'worldPrepareProcessToken', '()Ljava/lang/String;')
    if failed() or method == nil then return nil, 'host-process-token-unavailable' end
    str = ffi.cast('void* (*)(void*,void*,void*,const void*)', fns[36])(env, activity, method, nil)
    if failed() or str == nil then return nil, 'no-process-token' end
    chars = ffi.cast('const char* (*)(void*,void*,unsigned char*)', fns[169])(env, str, nil)
    if failed() or chars == nil then return nil, 'no-process-token-bytes' end
    local copied = ffi.string(chars)
    if #copied ~= 36 or not copied:match('^[a-f0-9%-]+$') then return nil, 'invalid-process-token' end
    return copied, 'native-process-token'
  end)
  if env ~= nil and deleteRef then
    if chars ~= nil and releaseChars then releaseChars(env, str, chars) end
    if str ~= nil then deleteRef(env, str) end
    if cls ~= nil then deleteRef(env, cls) end
    if activity ~= nil then deleteRef(env, activity) end
  end
  if not ok then return nil, 'jni-call-unavailable' end
  return token, reason
end
local function booleanStringCall(methodName, saveDir)
  if not (love and love.system and love.system.getOS and love.system.getOS() == 'Android') then
    return false, 'not-android'
  end
  if type(saveDir) ~= 'string' or saveDir == '' or saveDir:find('%z') then
    return false, 'invalid-save-directory'
  end
  local loaded, ffi = pcall(require, 'ffi')
  if not loaded then return false, 'ffi-unavailable' end
  local defined = pcall(ffi.cdef, [[
    typedef union { unsigned char z; signed char b; unsigned short c;
      short s; int i; long long j; float f; double d; void *l;
    } fr_world_prepare_jvalue;
    void *SDL_AndroidGetJNIEnv(void);
    void *SDL_AndroidGetActivity(void);
  ]])
  if not defined then return false, 'jni-definition-unavailable' end
  local env, activity, cls, str, fns
  local deleteRef, exceptionCheck, exceptionClear
  local function failed()
    if exceptionCheck(env) ~= 0 then exceptionClear(env); return true end
    return false
  end
  local ok, reached, reason = pcall(function()
    env = ffi.C.SDL_AndroidGetJNIEnv()
    if env == nil then return false, 'no-jni-environment' end
    fns = ffi.cast('void***', env)[0]
    exceptionCheck = ffi.cast('unsigned char (*)(void*)', fns[228])
    exceptionClear = ffi.cast('void (*)(void*)', fns[17])
    deleteRef = ffi.cast('void (*)(void*,void*)', fns[23])
    -- Do not consume an exception owned by another caller.
    if exceptionCheck(env) ~= 0 then return false, 'preexisting-jni-exception' end
    activity = ffi.C.SDL_AndroidGetActivity()
    if failed() or activity == nil then return false, 'no-activity' end
    local getClass = ffi.cast('void* (*)(void*,void*)', fns[31])
    cls = getClass(env, activity)
    if failed() or cls == nil then return false, 'no-activity-class' end
    local getMethod = ffi.cast('void* (*)(void*,void*,const char*,const char*)', fns[33])
    local method = getMethod(env, cls, methodName, '(Ljava/lang/String;)Z')
    if failed() or method == nil then return false, 'host-guard-unavailable' end
    local newString = ffi.cast('void* (*)(void*,const char*)', fns[167])
    str = newString(env, saveDir)
    if failed() or str == nil then return false, 'save-string-unavailable' end
    local args = ffi.new('fr_world_prepare_jvalue[1]'); args[0].l = str
    local callBoolean = ffi.cast('unsigned char (*)(void*,void*,void*,const fr_world_prepare_jvalue*)', fns[39])
    local armed = callBoolean(env, activity, method, args) ~= 0
    if failed() then return false, 'guard-arm-exception' end
    if methodName == 'disarmWorldPrepare' then
      return armed, armed and 'disarmed-serial-barrier' or 'disarm-unconfirmed-retain-journal'
    end
    return armed, armed and 'armed-awaiting-heartbeat-ack' or 'guard-rejected-directory'
  end)
  -- SDL_AndroidGetActivity returns a local reference, as do GetObjectClass and NewStringUTF.
  if env ~= nil and deleteRef then
    if str ~= nil then deleteRef(env, str) end
    if cls ~= nil then deleteRef(env, cls) end
    if activity ~= nil then deleteRef(env, activity) end
  end
  if not ok then return false, 'jni-call-unavailable' end
  return reached == true, reason
end
function M.arm(saveDir) return booleanStringCall('watchWorldPrepare', saveDir) end
function M.disarm(token)
  if type(token) ~= 'string' or #token < 1 or #token > 128 or not token:match('^[A-Za-z0-9_.:-]+$') then
    return false, 'invalid-owner-token'
  end
  return booleanStringCall('disarmWorldPrepare', token)
end
return M
