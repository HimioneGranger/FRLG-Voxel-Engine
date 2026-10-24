-- Native gameplay seam only. Caller owns current follower/contact/input gates.
local M = {}

function M.apply(deps, token)
  if type(deps) ~= 'table' or type(token) ~= 'table' then return false, 'invalid' end
  if token.committed or token.attempted then return false, 'already_attempted' end
  local game = deps.runtime
  local session = game and game.session
  if not session or session ~= token.session or game.phase ~= 'field'
      or session.map ~= token.map then return false, 'stale_context' end
  local items, bag, use = deps.ItemsData, deps.Bag, deps.ItemUse
  if not (items and bag and use and type(session.party) == 'table'
      and session.bag and token.mon) then return false, 'unavailable' end
  local id = items.toNumericId(token.itemId)
  if not id then return false, 'unsupported_item' end
  local field, kind = items.fieldUseKind(id), items.medicineKind(id)
  if (field ~= 'heal' and field ~= 'status')
      or (kind ~= 'heal' and kind ~= 'full_restore' and kind ~= 'status')
      or (use.isFlute and use.isFlute(id)) then return false, 'unsupported_item' end
  local source, slot
  for i, mon in ipairs(session.party) do
    local match = mon == token.mon
    if not match and deps.adapter and type(deps.adapter.mon) == 'function' then
      match = deps.adapter:mon(mon) == token.mon
    end
    if match then
      if source then return false, 'ambiguous_target' end
      source, slot = mon, i
    end
  end
  if not source or (token.source and token.source ~= source) then return false, 'stale_party' end
  if source.isEgg or source.egg or (tonumber(source.hp) or 0) <= 0 then
    return false, 'fainted_or_egg'
  end
  if not bag.has(session.bag, id, 1) then return false, 'out_of_stock' end
  -- No yield between these checks and useField. useField owns consumption.
  if game.session ~= session or game.phase ~= 'field' or session.map ~= token.map
      or session.party[slot] ~= source then return false, 'stale_context' end
  token.attempted = true -- An exception can follow mutation; never retry blindly.
  local ok, applied, result, text = pcall(use.useField, session, session.bag, id, slot)
  if not ok then return false, 'native_error', tostring(applied) end
  if not applied then return false, result, text end
  token.committed = true
  if deps.adapter and type(deps.adapter.refresh) == 'function' then
    pcall(deps.adapter.refresh, deps.adapter)
  end
  return true, result, text
end

return M
