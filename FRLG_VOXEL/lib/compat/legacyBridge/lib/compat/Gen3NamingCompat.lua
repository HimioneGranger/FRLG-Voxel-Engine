-- FireRed: route the native naming screen (src/ui/game3/naming.lua, pushed
-- as Stack.push("naming", Naming, {...})) to kanto_gear's real keyboard, the
-- same treatment Gen1/Gen2 already get from kanto_gear's own
-- NamingScreen/Gen2NamingScreen branches. This file only loads on
-- generation 3 (this mod's manifest), so it never runs on Crystal/Yellow;
-- kanto_gear's namingGrid() reaches it only through a mod.find lookup,
-- never directly, and carries none of this FireRed-specific keyboard data
-- itself.
--
-- Moved verbatim from kanto_gear/main.lua's gen3NamingGrid (W4 gear-hook
-- round, THEME.hgss:naming); only the function name changed (grid). See
-- that history for the original review evidence.
--
-- Keyboard layout copied verbatim from gen3_ui.lua's own local `keyboard`
-- table (the same one FireRed's generic list-menu mirror already uses),
-- not re-derived, so both stay in sync if that file changes.
local GEN3_NAMING_KEYBOARD = {
  { { "A", "B", "C", "D", "E", "F", " ", "." }, { "G", "H", "I", "J", "K", "L", " ", "," },
    { "M", "N", "O", "P", "Q", "R", "S" }, { "T", "U", "V", "W", "X", "Y", "Z" } },
  { { "a", "b", "c", "d", "e", "f", " ", "." }, { "g", "h", "i", "j", "k", "l", " ", "," },
    { "m", "n", "o", "p", "q", "r", "s" }, { "t", "u", "v", "w", "x", "y", "z" } },
  { { "0", "1", "2", "3", "4" }, { "5", "6", "7", "8", "9" },
    { "!", "?", "♂", "♀", "/", "-" }, { "…", "“", "”", "‘", "'" } },
}
-- gen3_ui.lua's own footer-button row/btn correspondence (UI:naming's
-- __newindex: `state.row, state.btn = ({1,2,4})[item.btn], item.btn`),
-- copied exactly rather than re-derived.
local GEN3_NAMING_ROW_FOR_BTN = { 1, 2, 4 }

local M = {}

function M.grid(state)
  local native = state.mod
  if type(native) ~= "table" or not native.openFlag then return nil end
  local st = native._state
  if type(st) ~= "table" or st.finished then return nil end
  local page = GEN3_NAMING_KEYBOARD[st.page]
  if not page then return nil end
  if not state.__gen3NamingProxied then
    state.__gen3NamingProxied = true
    setmetatable(state, {
      __index = function(t, k)
        if k == "screenId" then return nil end -- deliberately NOT "NamingScreen"/"Gen2NamingScreen"; only THIS proxy's own consumers (drawNaming/tapNaming's generic branch) need row/col/glyphs
        if k == "row" or k == "col" then
          local onButton = st.col > #(GEN3_NAMING_KEYBOARD[st.page] and GEN3_NAMING_KEYBOARD[st.page][st.row] or {})
          if k == "row" then return onButton and 5 or st.row end
          return onButton and (st.btn or 1) or st.col
        end
        if k == "glyphs" then
          local out, name = {}, st.name or ""
          for i = 1, #name do out[i] = name:sub(i, i) end
          return out
        end
        return nil
      end,
      __newindex = function(t, k, v)
        if k == "row" then rawset(t, "_gen3PendingRow", v); return end
        if k == "col" then
          local row = rawget(t, "_gen3PendingRow") or st.row
          local rowChars = GEN3_NAMING_KEYBOARD[st.page] and GEN3_NAMING_KEYBOARD[st.page][row]
          if row == 5 then
            local btn = v
            local realRow = GEN3_NAMING_ROW_FOR_BTN[btn] or 1
            local realPage = GEN3_NAMING_KEYBOARD[st.page]
            st.row, st.btn = realRow, btn
            st.col = realPage and #(realPage[realRow] or {}) + 1 or 1
          elseif rowChars and v <= #rowChars then
            st.row, st.col = row, v
          end
          return
        end
        rawset(t, k, v)
      end,
    })
  end
  local grid = {}
  for r = 1, 4 do
    local row, chars = {}, page[r]
    for c, ch in ipairs(chars) do row[c] = ch end
    grid[r] = row
  end
  grid[5] = { ({ "abc", "123", "ABC" })[st.page] or "abc", "BACK", "OK" }
  return grid
end

return M
