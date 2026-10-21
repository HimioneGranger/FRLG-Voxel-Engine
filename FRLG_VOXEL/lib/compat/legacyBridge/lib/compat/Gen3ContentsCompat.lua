-- FireRed: BackpackContents.snapshot's bag rows, read through this mod's
-- own game3.bag.rows() bridge (VRITK_FRLG_HOST/lib/Game3Data.lua) instead
-- of the Gen1/2 save.bagOrder + pairs(save.inventory) walk, which sees an
-- empty bag on the Gen3Compat facade (no bagOrder, pairs() yields
-- nothing). This file only loads on generation 3, so it never runs on
-- Crystal/Yellow; VRITK's own BackpackContents.lua reaches it only through
-- Gen3HostCompat's mod.find lookup, never directly.
--
-- Moved from VR_INTERACTIONS_BACKPACK_LAB/lib/Gen3Contents.lua (originally
-- W4 P2/E4a); iconFor's cross-reference into BackpackContents (its alias
-- table + slug rule, so a name that gets a friendlier icon alias on
-- Gen1/Gen2 gets the same one here) now goes cross-mod, since this file no
-- longer lives inside VR_INTERACTIONS_BACKPACK_LAB -- VRITK exports
-- iconFor for exactly this reason (main.lua: `mod.exports.iconFor = ...`).
local V = ...
local M = {}

local function iconFor(id)
  local finder = V.mod and V.mod.find
  local host = type(finder) == "function" and finder("VR_INTERACTIONS_BACKPACK_LAB")
  local fn = host and host.exports and host.exports.iconFor
  if type(fn) == "function" then
    local ok, icon = pcall(fn, id)
    if ok and type(icon) == "string" and icon ~= "" then return icon end
  end
  -- VRITK absent or not yet loaded: the same plain slug BackpackContents
  -- itself falls back to for an id with no alias table entry.
  return tostring(id):lower():gsub("_", "-")
end

-- Returns rows, available -- the exact shape BackpackContents.snapshot
-- returns, so VRITK's item view/grab/release code needs no gen3 branch of
-- its own. `bagRows` is Game3Data.bagRows, passed in by the caller (this
-- mod's own main.lua) rather than looked up here, since we ARE the host
-- now and don't need a mod.find round trip back to ourselves.
function M.snapshot(bagRows)
  if type(bagRows) ~= "function" then return {}, false end
  local ok, rows = pcall(bagRows)
  if not (ok and type(rows) == "table") then return {}, false end
  local out = {}
  for _, row in ipairs(rows) do
    if row and row.itemId then
      local id = row.key or tostring(row.itemId)
      -- TM/HM rows have no per-move-type icon available on this path (no
      -- game.data.moves lookup here, unlike BackpackContents' own Gen1/2
      -- machine branch) -- fall back to the same generic 'tm-normal'
      -- Gen1/2 already uses when a move's type can't be resolved.
      local icon = (row.pocket == "TM_CASE") and "tm-normal" or iconFor(id)
      out[#out + 1] = {
        id = id,
        name = tostring(row.name or row.itemId),
        count = tonumber(row.count) or 0,
        icon = icon,
      }
    end
  end
  return out, true
end

return M
