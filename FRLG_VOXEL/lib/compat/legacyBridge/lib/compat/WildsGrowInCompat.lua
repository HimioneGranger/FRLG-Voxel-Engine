-- WildsGrowInCompat (Lab 60, item 4): wild Pokemon grow in instead of popping in.
--
-- The user saw wild Pokemon pop in: the spawn manager places up to 8 in one tick (right after the reachability job),
-- and a VR card was at full size from its first frame. This module changes what the VR cards LOOK like, nothing else:
--   * stagger: the cards of one burst are revealed one after the other, STAGGER_S apart (25 logic ticks, about 0.42 s
--     at 60 ticks per second, inside the 20-30 tick request) instead of all at once;
--   * grow-in: a card that becomes visible grows from MIN_SCALE to full size about its feet over GROW_S (0.30 s) with
--     an ease-out curve.
-- Why full-size growth and not "0.85 + 0.15 * ease" plus alpha (design C3): the card shader discards below an alpha of
-- 0.5 (CUTOUT, u_alphaCut = 0.5), so an alpha ramp cannot fade; it would hide the card for the first half and pop it
-- in half transparent. A 15 percent size change from nothing still pops. Scale 0.05 -> 1 reads as growing in.
--
-- How it is wired (purely visual, no dependence on how the spawn manager is patched, so it works the same on the
-- Lab 58 edited Wilds and on the compat60 layer):
--   * the adapter's existing spawn decorator calls stamp(entity, mapId) when an entity is created: the entity gets
--     vrRevealAt (its slot in the stagger). Nothing about the entity's logic, cell, RNG or timers changes;
--   * the adapter's collect() skips an entity while pending(entity) is true (no card, so nothing to see, aim at or
--     catch), calls touch(entity) when its card is first emitted, and the pose function multiplies the card size by
--     scale(entity). With this module not installed (adapter.GrowIn == nil) the adapter behaves as before.
--   * A not-yet-visible wild is NOT targetable through the VR layer (no card, owMons list reports it hidden and not
--     catchable, resolve() refuses it). The engine's own logic is untouched: it exists, walks and blocks its cell from
--     the first tick. If the player walks into that cell in the (at most ~3 s) window the engine starts the encounter as
--     it always did; such an entity is shown at once (pending() is false for an engaged one).
--
-- Switch: mod option "wilds_grow_in" (default ON) read through the host's getOption; ENABLED = false or the option off
-- makes stamp() a no-op and pending()/scale() answer "visible, full size", i.e. the Lab 58 look.
-- Hot paths (beginFrame, pending, touch, scale) allocate nothing.
local M = {}

M.ENABLED = true
M.OPTION_KEY = "wilds_grow_in"
M.STAGGER_S = 25 / 60  -- seconds between two reveals of one burst
M.GROW_S = 0.30
M.MIN_SCALE = 0.05
M.OPTION_POLL_FRAMES = 30

local function defaultClock()
  if love and love.timer and love.timer.getTime then return love.timer.getTime() end
  return os.clock()
end

--- Card scale for a card shown `age` seconds ago: MIN_SCALE .. 1, ease-out cubic.
function M.curve(age)
  local grow = M.GROW_S
  if age >= grow then return 1 end
  if age <= 0 then return M.MIN_SCALE end
  local k = 1 - age / grow
  local ease = 1 - k * k * k
  return M.MIN_SCALE + (1 - M.MIN_SCALE) * ease
end
local curve = M.curve

--- opts: clock (fn -> seconds), getOption (fn -> boolean|nil, nil = default on), log (fn).
function M.new(opts)
  opts = opts or {}
  local clock = opts.clock or defaultClock
  local getOption = opts.getOption
  local G = {
    enabled = M.ENABLED, now = clock(), nextReveal = 0, lastMap = nil, frames = 0,
    stamped = 0, shown = 0, maxPending = 0,
  }

  local function refreshOption()
    local on = M.ENABLED
    if on and getOption then
      local ok, v = pcall(getOption)
      if ok and v == false then on = false end
    end
    G.enabled = on
  end
  refreshOption()

  --- Spawn decorator step. Idempotent (a second call on the same entity changes nothing).
  function G.stamp(e, mapId)
    if not G.enabled or e.vrRevealAt ~= nil then return end
    local t = clock()
    if mapId ~= G.lastMap then G.lastMap = mapId; G.nextReveal = t end -- a new map starts its own burst
    local at = G.nextReveal
    if at < t then at = t end
    e.vrRevealAt = at
    e.vrShown = false
    G.nextReveal = at + M.STAGGER_S
    G.stamped = G.stamped + 1
  end

  --- Once per frame, before the collect loop: the frame clock, and the option now and then.
  function G.beginFrame()
    G.now = clock()
    local f = G.frames + 1
    G.frames = f
    if f % M.OPTION_POLL_FRAMES == 1 then refreshOption() end
  end

  --- True while the entity's card must not be shown yet.
  function G.pending(e)
    local at = e.vrRevealAt
    if at == nil or not G.enabled or e.engaged then return false end
    return G.now < at
  end

  --- The card of `e` is being emitted: its grow-in clock starts at the first frame it is drawn.
  function G.touch(e)
    if e.vrShown == false then
      e.vrShown = G.now
      G.shown = G.shown + 1
    end
  end

  --- Size factor for the card of `e` this frame (1 = full size).
  function G.scale(e)
    local t = e.vrShown
    if not t or not G.enabled then return 1 end
    return curve(G.now - t)
  end

  function G.status()
    return { enabled = G.enabled, stamped = G.stamped, shown = G.shown, frames = G.frames }
  end
  return G
end

--- The VRITK_FRLG_HOST seam. env: V (module loader), log, layout (fn), active (fn), getOption (fn), clock (tests).
--- Hooks the FireRed Wilds adapter module (adapter.GrowIn); returns the handle or nil + reason.
function M.installForHost(env)
  env = env or {}
  if not M.ENABLED then return nil, "disabled" end
  if not (env.active and env.active()) then return nil, "VRITK not active" end
  if not (env.layout and env.layout() == "frlg") then return nil, "layout is not frlg" end
  local Adapter = env.V.require("compat/WildsFireRedAdapter")
  if type(Adapter) ~= "table" then return nil, "no adapter" end
  local G = M.new({ clock = env.clock, getOption = env.getOption })
  Adapter.GrowIn = G
  G.uninstall = function()
    if Adapter.GrowIn == G then Adapter.GrowIn = nil end
  end
  if env.log then env.log(("[wilds grow-in] installed (stagger %.2fs, grow %.2fs, enabled=%s)"):format(M.STAGGER_S, M.GROW_S, tostring(G.enabled))) end
  return G
end

return M
