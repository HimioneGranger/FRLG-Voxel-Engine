-- Emerald National Dex entries above 251 have text and cries, but no bundled voice clip.
-- Install from VRITK_FRLG_HOST; leave the shared scanner source untouched.
local M = {}
local installed
local function emerald()
  local okR, Runtime = pcall(require, "src.core.game3.runtime")
  local okP, Profile = pcall(require, "src.core.game3.profile")
  if not (okR and okP and type(Runtime.getSession) == "function"
      and type(Profile.family) == "function") then return false end
  local okS, session = pcall(Runtime.getSession)
  if not okS then return false end
  local okF, family = pcall(Profile.family, session)
  return okF and family == "rse"
end
function M.install(V)
  if installed then return true end
  if not (V and type(V.require) == "function") then return false end
  local ok, Scan = pcall(V.require, "QuestPokedexScan")
  if not (ok and type(Scan) == "table" and type(Scan._voice) == "function") then return false end
  local original = Scan._voice
  local function voice(self, entry)
    local dex = type(entry) == "table" and tonumber(entry.dex or entry.number)
    if emerald() and dex and dex == math.floor(dex) and dex > 251 and dex < math.huge then
      self.lastVoice = nil
      return false, "ENTRY IDENTIFIED"
    end
    return original(self, entry)
  end
  Scan._voice = voice
  installed = { scan = Scan, original = original, wrapper = voice }
  return true
end
function M.installInto(ctx)
  if not emerald() then return false end
  local ok, active = pcall(M.install, ctx.V)
  if ok and active then ctx.restore[#ctx.restore + 1] = M.uninstall; return true end
  ctx.log("Emerald scan wrapper unavailable: " .. tostring(active))
  return false
end
function M.uninstall()
  if installed and installed.scan._voice == installed.wrapper then
    installed.scan._voice = installed.original
  end
  installed = nil
end
return M
