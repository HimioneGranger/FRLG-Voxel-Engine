-- W4 gear-hook (DESIGN.md 2d): copied verbatim from
-- BATTLE_ART_QUEST_COMPAT/lib/QuestSecondScreen.lua (self-contained, no
-- Gen2/Battle-Art dependency -- just a memoising view over
-- src/render/SecondScreen.lua) so FireRed gets the same per-frame
-- setEnabled-suppression BATTLE_ART_QUEST_COMPAT already gives Gen2.
-- No logic changes.

-- The companion-display handle kanto_gear is handed on the compose context.
--
-- Official Kanto Gear opens its render.compose wrapper (kanto_gear/main.lua
-- 12273-12277) with companion.setEnabled(active and not inline) and repeats
-- that call on every composed frame with the same value. On the headset
-- SecondScreen.setEnabled crosses JNI into love_android_secondary_enable,
-- which walks DisplayManager and logs "GameActivity: no secondary display
-- found" -- 3380 of those lines in one five-minute capture, one per frame.
-- Nothing downstream of the native call is edge-triggered, so forwarding only
-- a changed value is behaviourally identical and costs one comparison.
--
-- This is a view over the real module, never a replacement for it: push,
-- detected, pollTouch and everything else reach src/render/SecondScreen.lua
-- unwrapped through __index, so the present and touch paths keep the function
-- identities and the return values they have today.
local M = {}
M.__index = M

function M.new(module)
  local self = setmetatable({
    module = module,
    -- nil means "the native flag is unknown": the next call forwards whatever
    -- it is handed rather than assuming the last value survived.
    enabled = nil,
    forwarded = 0,
    suppressed = 0,
    failures = 0,
  }, M)
  local view = setmetatable({}, { __index = module })
  view.setEnabled = function(on)
    local value = on and true or false
    if value == self.enabled then
      self.suppressed = self.suppressed + 1
      return
    end
    -- The native side is absent on desktop and can be torn down under us on
    -- Android, so a throw here degrades to today's behaviour (the value is
    -- forgotten and re-sent next frame) instead of leaving the chain.
    local ok = pcall(module.setEnabled, on)
    if not ok then
      self.enabled = nil
      self.failures = self.failures + 1
      return
    end
    self.enabled = value
    self.forwarded = self.forwarded + 1
  end
  self.view = view
  return self
end

-- Android hands the activity a fresh Presentation surface after a resume, and
-- the enable flag the native layer remembers is not ours to trust across that
-- gap. Forget the memo so the next compose re-asserts it.
function M:invalidate()
  self.enabled = nil
end

function M:status()
  return { enabled = self.enabled, forwarded = self.forwarded,
    suppressed = self.suppressed, failures = self.failures }
end

function M:reset()
  self.forwarded, self.suppressed, self.failures = 0, 0, 0
end

return M
