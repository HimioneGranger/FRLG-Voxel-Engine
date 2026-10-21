-- Track C (Lab 54): OVERWORLD MONS on the Gen 3 OPTION screen. Same seam as
-- FRLG_VOXEL's VR CONTROLS (lib/quest/VrControls.lua): wrap option_rows'
-- Rows.build, add one Rows.GROUPS entry and name it in Rows.ORDER. The choice is
-- written only through the mod's persisted option writer (ManagerState:
-- setOption), never by the router itself.
--   PROVIDER  AUTO / WILDS / UNTAMED / OFF   (the stored choice)
--   IN USE    the provider running now        (read-only)
--   REASON    why, in a short code            (read-only; status() has the text)
-- uninstall(Rows) puts Rows.ORDER / Rows.GROUPS back and turns the wrapper inert.
local M = {}

M.GROUP = { id = "group.owprovider", label = "OVERWORLD MONS" }
M.ROW_CHOICE = "vritk:ow-provider"
M.ROW_ACTIVE = "vritk:ow-active"
M.ROW_REASON = "vritk:ow-reason"
local KEY = "_vritkOwProviderRows"

local LABEL = { wilds_of_hoenn = "WILDS", untamed_advanced = "UNTAMED", none = "NONE" }
local AUTO_TEXT = { wilds_of_hoenn = "AUTO>WILDS", untamed_advanced = "AUTO>UNTAMED", none = "AUTO>NONE" }
local WAIT_TEXT = { wilds_of_hoenn = "WILDS*", untamed_advanced = "UNTAMED*", none = "NONE*" }
local CHOICE_TEXT = { auto = "AUTO", wilds = "WILDS", untamed = "UNTAMED", off = "OFF" }

local function isOurs(id)
  return id == M.GROUP.id or id == M.ROW_CHOICE or id == M.ROW_ACTIVE or id == M.ROW_REASON
end

local function removeOurs(Rows)
  for i = #Rows.ORDER, 1, -1 do if isOurs(Rows.ORDER[i]) then table.remove(Rows.ORDER, i) end end
  for i = #Rows.GROUPS, 1, -1 do if Rows.GROUPS[i].id == M.GROUP.id then table.remove(Rows.GROUPS, i) end end
end

-- The stored choice shown with what AUTO resolves to, e.g. "AUTO>WILDS".
function M.choiceText(choice, activeId)
  local c = CHOICE_TEXT[choice or "auto"] and (choice or "auto") or "auto"
  if c == "auto" then return AUTO_TEXT[activeId] or AUTO_TEXT.none end
  return CHOICE_TEXT[c]
end

-- env: { get(key), router (activeId / pending / reasonCode read directly: the
--        OPTION page redraws every frame, so no status table is built here),
--        write(game, key, value) -> ok,
--        choices = { {label, value}, ... }, optionKey }
function M.install(env)
  local Rows = env and env.Rows
  if type(Rows) ~= "table" or type(Rows.build) ~= "function" or type(Rows.GROUPS) ~= "table"
      or type(Rows.ORDER) ~= "table" then
    return false, "no Gen3 option rows"
  end
  local state = Rows[KEY]
  if state then
    state.env, state.active = env, true
  else
    state = { env = env, active = true, vanilla = Rows.build }
    Rows[KEY] = state
    Rows.build = function(ctx)
      local rows = state.vanilla(ctx)
      local e = state.env
      if not state.active or type(rows) ~= "table" then return rows end
      local have = {}
      for _, row in ipairs(rows) do if row.id then have[row.id] = true end end
      if not have[M.ROW_CHOICE] then
        rows[#rows + 1] = {
          id = M.ROW_CHOICE, label = "PROVIDER",
          value = function()
            local stored = e.get and e.get(e.optionKey) or "auto"
            return M.choiceText(stored, e.router and e.router.activeId)
          end,
          step = function(c, dir)
            local cur = e.get and e.get(e.optionKey) or "auto"
            local list = e.choices
            local at = 1
            for i, ch in ipairs(list) do if ch[2] == cur then at = i end end
            dir = (dir and dir < 0) and -1 or 1
            local nv = list[(at - 1 + dir) % #list + 1][2]
            if nv == cur then return false end
            return e.write and e.write(c and c.game, e.optionKey, nv) or false
          end,
        }
      end
      if not have[M.ROW_ACTIVE] then
        rows[#rows + 1] = {
          id = M.ROW_ACTIVE, label = "IN USE",
          value = function()
            local r = e.router
            local id = r and r.activeId or "none"
            -- * = a switch waits for a battle / capture to end
            if r and r.pending then return WAIT_TEXT[id] or "NONE*" end
            return LABEL[id] or "NONE"
          end,
          step = function() return false end,
        }
      end
      if not have[M.ROW_REASON] then
        rows[#rows + 1] = {
          id = M.ROW_REASON, label = "REASON",
          value = function()
            local r = e.router
            if r and r.pending then return "SWITCH WAITS" end
            return r and r.reasonCode or "?"
          end,
          step = function() return false end,
        }
      end
      return rows
    end
  end
  removeOurs(Rows)
  Rows.GROUPS[#Rows.GROUPS + 1] = { id = M.GROUP.id, label = M.GROUP.label,
    members = { M.ROW_CHOICE, M.ROW_ACTIVE, M.ROW_REASON } }
  local at = #Rows.ORDER + 1
  for i, id in ipairs(Rows.ORDER) do
    if id == "mods" then at = i end
  end
  for i, id in ipairs(Rows.ORDER) do
    if id == "group.vrperf" then at = i + 1 end
  end
  table.insert(Rows.ORDER, at, M.GROUP.id)
  return true
end

function M.uninstall(Rows)
  local state = Rows and Rows[KEY]
  if not state then return end
  state.active = false
  removeOurs(Rows)
end

return M
