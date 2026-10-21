-- FRLG_VOXEL Lab 60: the inputs of the Loading screen (FireRed's own file, pure logic, no globals).
--
-- Lab 58 headset log: the Loading hold never started on a warp. The only trigger there is the one-shot "hard re-root"
-- flag, and on that exact frame the engine's screen Fade (a door exit starts a fade-in in the same callback that loads
-- the map) made menuOpen() true, so VoxelLoading:update dropped the trigger and never saw it again. Three small fixes
-- live here so they can be tested without main.lua:
--   1. menuOpenNoFade: the same question as menuOpen(), but a running screen Fade alone is not a menu.
--   2. effectiveHard: the hard flag is latched for HARD_LATCH_S so one dropped frame cannot lose a warp.
--   3. a state-change log (show / hide with a reason).
-- Nothing here allocates per frame (strings are built only when the screen appears or disappears).
local G = {}

G.HARD_LATCH_S = 1.5 -- a hard re-root keeps asking for the hold this long, until the hold has started

-- Is a menu / dialogue / battle / wait-button open, IGNORING the screen Fade? `engine(name)` returns an engine module
-- table or nil (main.lua's cached require); `fullMenuOpen()` is main.lua's menuOpen(). Without a running Fade this is
-- exactly fullMenuOpen(). With one, Hud.busy() is true for the Fade alone, so each other cause it ORs is asked for
-- directly (Hud.busy: Battle.isActive, Message.isOpen, Choice.active, Hud.isMenuOpen, Hud._waitButton), then main.lua's
-- own extra checks (Stack.busy, Help.isOpen).
function G.menuOpenNoFade(engine, fullMenuOpen)
  local Fade = engine("src.ui.game3.fade")
  if not (Fade and Fade.isActive) then return fullMenuOpen() end
  local okF, fading = pcall(Fade.isActive)
  if not (okF and fading) then return fullMenuOpen() end
  local Battle = engine("src.core.game3.battle")
  if Battle and Battle.isActive then
    local ok, v = pcall(Battle.isActive); if ok and v then return true end
  end
  local Message = engine("src.ui.game3.message")
  if Message and Message.isOpen then
    local ok, v = pcall(Message.isOpen); if ok and v then return true end
  end
  local Choice = engine("src.ui.game3.choice")
  if Choice and Choice.active then return true end
  local Hud = engine("src.ui.game3.hud")
  if Hud then
    if Hud.isMenuOpen then
      local ok, v = pcall(Hud.isMenuOpen); if ok and v then return true end
    end
    if Hud._waitButton ~= nil then return true end
  end
  local Stack = engine("src.ui.game3.stack")
  if Stack and Stack.busy then
    local ok, v = pcall(Stack.busy); if ok and v then return true end
  end
  local Help = engine("src.ui.game3.help_system")
  if Help and Help.isOpen then
    local ok, v = pcall(Help.isOpen); if ok and v then return true end
  end
  return false
end

-- The hard flag the Loading logic sees. st = a table kept by the caller (st.hardAt). `t` is a clock in seconds.
-- True on the frame the hard re-root happened and for HARD_LATCH_S afterwards, or until G.consumed(st).
function G.effectiveHard(st, pumpHard, t)
  if pumpHard then st.hardAt = t; return true end
  local at = st.hardAt
  if at then
    if t - at < G.HARD_LATCH_S then return true end
    st.hardAt = nil
  end
  return false
end

function G.consumed(st) st.hardAt = nil end

-- Should this frame's build pump leave a hard re-root's new root queued (so a Loading frame goes out before the long build)?
-- Only with the Loading switch on, VRITK active, and either a 3D frame wanted or a hold already running.
function G.wantDefer(switchOn, vritkActive, want3d, holding)
  return switchOn == true and vritkActive == true and (want3d == true or holding == true)
end

-- Show / hide transitions. st.shown is the last state; `shown` is this frame's. Returns the log line on a change, else nil.
-- `startWhy` / `endWhy` come from VoxelLoading (hold start / end reason); `buildingWhy` when only the "building" panel shows.
function G.transition(st, shown, startWhy, endWhy)
  if shown == (st.shown == true) then return nil end
  st.shown = shown
  if shown then return "loading screen show reason=" .. tostring(startWhy or "building") end
  return "loading screen hide reason=" .. tostring(endWhy or "ended")
end

return G
