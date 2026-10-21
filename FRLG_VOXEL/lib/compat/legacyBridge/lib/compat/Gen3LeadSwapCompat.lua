-- FireRed: party-belt lead swap (user rule Q10, 2026-09-28). Hover a
-- holstered belt ball and press A+B (X+Y merges into controls.a/controls.b
-- before any consumer sees them, FRLG_VOXEL's InputMap.lua) -> that mon
-- becomes the party lead. This file only loads on generation 3 (this mod's
-- manifest), so it never runs on Crystal/Yellow; VRITK's own
-- PartyBeltComponent.lua reaches it only through Gen3HostCompat's mod.find
-- lookup, never directly.
--
-- Originally W5_LEAD_SWAP_PATCH.md's two inline hunks in PartyBeltComponent
-- and main.lua; moved here unchanged apart from the split into
-- active()/trySwap() so PartyBeltComponent's own seam is a single gated
-- call. FRLG_CATCH does the actual reorder (follower:setLead) and every
-- refusal (battle, script, warp, ...); this module only decides whether to
-- ask it to.
local M={}

-- Gen1/2's Wilds follower has no setLead at all, so this is false there even
-- if this module were ever reachable on those generations (it isn't).
function M.active(ex)
  return ex and ex.follower and type(ex.follower.setLead)=='function'
end

function M.trySwap(ex, game, belt, leadIndex, side, onQueued)
  local slot=belt.slots[leadIndex]
  local ok,queued=pcall(ex.follower.setLead,ex.follower,game,slot and slot.mon,leadIndex)
  if ok and queued and type(onQueued)=='function' then onQueued(side) end
  return ok and queued or false
end

return M
