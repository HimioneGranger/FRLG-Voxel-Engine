-- Packet D: Emerald-only capture/fishing adapters. Native engine rules; no save writes.
local V = ...
local M = {}

function M.rollFishing(engineRequire, Encounters, mapId, rodId, Field, Player, delta)
  local Profile = engineRequire("src.core.game3.profile")
  if Profile and Profile.family(Field._session) == "rse" then
    -- Native fishing uses the adjacent facing tile, including the Feebas check.
    local d = delta[Player.facing]
    return pcall(Encounters.rollFishing, mapId, rodId,
      { x = Player.cellX + d[1], y = Player.cellY + d[2] })
  end
  return pcall(Encounters.rollFishing, mapId, rodId)
end

function M.safariState(opts, meta, Rules, modules)
  local Profile = modules("BattleProfile")
  local profile = Profile and Profile.get(opts.session)
  if profile and profile.family == "rse" and profile.safari then
    return Rules.safari.newStateRse(meta and meta.catchRate, profile.safari)
  end
  return nil
end

return M
