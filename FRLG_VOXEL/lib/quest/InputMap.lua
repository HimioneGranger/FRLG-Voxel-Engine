-- FRLG_VOXEL: Quest Touch controls -> the game's own Input buttons, used
-- only while this mod owns the OpenXR session (the native launcher's input
-- bridge goes quiet once its session is handed over).
--
-- Same game buttons as the stock panel path (QuestOpenXRDisplay: A=A, B/back
-- =B, stick=d-pad) plus START on the left menu button. Presses go through
-- Input:sourcePress/sourceRelease with this mod's own source names, so they
-- never clear a key, pad or touch hold (src/core/Input.lua:262-285).
--
--   left stick     d-pad. In the 3D field with no menu open it is
--                  LOOK-RELATIVE (push forward = walk where you look,
--                  quantised to the 4 grid directions); in menus, battles,
--                  panel mode and the north-up 3/4 VIEW it is absolute
--                  (up = up / north).
--   A / X          A          B / Y        B
--   left menu      START      left trigger SELECT (press 0.6 / release 0.35)
--   left grip      L          right grip   R      (press 0.7 / release 0.45)
--   left stick click   toggle voxel view <-> flat panel
--   right stick L/R    turn (first/third person only): actions.snap on a
--                      flick, actions.turn = the analog value past TURN_DEAD
--                      for the SMOOTH style (Camera:turnInput picks one)
--
-- Lab 8 (P0-2): the left stick ALSO reports its analog push to FreeMove as a
-- world direction (look yaw + stick angle) and a 0..1 magnitude, every frame,
-- for free walking. The d-pad presses above stay exactly as they were: menus,
-- scripts and the phase-1 grid fallbacks (surf, bike) still read them.
local V = ...

local okFM, FreeMove = pcall(V.require, "quest/FreeMove")
if not okFM or type(FreeMove) ~= "table" then FreeMove = nil end

local InputMap = {}
InputMap.__index = InputMap
InputMap.TURN_DEAD = 0.25 -- right stick dead zone for the smooth turn

local SOURCE = "frlgvoxel:xr:"
local DIRS = { [0] = "up", "left", "down", "right" } -- by quarter-turns CCW from north

-- W4 review fix #8a (REVIEW_VRITK_P2.md): which game button each claimable
-- control maps to, for the release-on-claim below. A control that was
-- ALREADY pressed (held[btn] true) the moment a layer claims it must be
-- released THIS frame, not left stuck pressed until its analog value later
-- drifts below the release threshold on its own -- DESIGN 1 says a claim
-- releases once, immediately.
local CLAIM_BTN = { gripL = "l", gripR = "r", triggerL = "select" }

function InputMap.new()
  return setmetatable({ held = {}, suppressed = {}, dir = nil, dirKey = nil,
    snapArmed = true, toggleWas = false, srcRef = nil }, InputMap)
end

-- Analog trigger/grip as a button with hysteresis (review item 7): press
-- above `on`, release only below `off`, so chatter around one threshold
-- cannot repeat presses (Bicycle mount/dismount, Help open/close).
local function analog(held, v, on, off)
  v = tonumber(v) or 0
  if held then return v > off end
  return v > on
end
InputMap.analog = analog

local InputModule
local function input()
  if InputModule then return InputModule end
  local ok, Input = pcall(require, "src.core.Input")
  if ok and type(Input) == "table" then InputModule = Input; return Input end
  return nil
end

function InputMap:_set(Input, btn, down)
  if self.suppressed[btn] then
    -- dropped by an engine Input:reset while held: wait for a real release
    if down then return end
    self.suppressed[btn] = nil
  end
  if down and not self.held[btn] then
    self.held[btn] = true
    pcall(Input.sourcePress, Input, btn, SOURCE .. btn)
  elseif not down and self.held[btn] then
    self.held[btn] = nil
    pcall(Input.sourceRelease, Input, btn, SOURCE .. btn)
  end
end

function InputMap:releaseAll()
  if FreeMove then pcall(FreeMove.setIntent, 0, 0, 0, { panel = true }) end -- Lab 8
  local Input = input()
  if not Input then self.held = {}; return end
  for btn in pairs(self.held) do
    pcall(Input.sourceRelease, Input, btn, SOURCE .. btn)
    self.held[btn] = nil
  end
  self.suppressed = {}
  self.dir, self.dirKey = nil, nil
end

-- Input:reset() (focus, visibility, resume, low memory) swaps Input.sources
-- for a fresh table and forgets every hold (src/core/Input.lua:182). Re-press
-- the held direction and B (walking / running continue); A, START, SELECT, L
-- and R wait for a real release, since pressing them again would be a fresh
-- tap (review item 10).
function InputMap:_reconcile(Input)
  local ref = Input.sources
  if self.srcRef == nil then self.srcRef = ref; return end
  if ref == self.srcRef then return end
  self.srcRef = ref
  for btn in pairs(self.held) do
    self.held[btn] = nil
    if not (btn == "b" or btn == "up" or btn == "down" or btn == "left" or btn == "right") then
      self.suppressed[btn] = true
    end
  end
end

local function quantise(yaw)
  local q = math.floor(yaw / (math.pi / 2) + 0.5) % 4
  return DIRS[q]
end

-- ctx = { lookYaw = world yaw the head looks along (nil = absolute),
--         menuOpen = bool,
--         suppress = W4 vrHost claim mask {gripL,gripR,triggerL,triggerR,
--           a,b,moveStick,lookStick = bool}, from HostApi:suppressMask(),
--         faceLook = bool (Lab 8: first person, an idle trainer faces the look),
--         battleWalk = bool (battle-move: the left stick walks the player in a battle, so it
--           presses no d-pad direction; nil/false = exactly as before) }
-- Returns actions: { toggle = true } and/or { snap = +1 | -1 } and
-- { turn = -1..1 } (Lab 8, the right stick's analog push; nil at rest).
--
-- W4: `suppress` lets a stereo layer (VRITK, the P1 probe, ...) grab a
-- control for its own use -- grabbing with the grips, reeling with a stick
-- -- without the game also seeing that same physical input as an L/R press
-- or a walk. START and the toggle never consult `suppress` at all (not
-- merely ignored: no line below even reads sup.start/sup.toggle), matching
-- vritk-hook/DESIGN.md 1 "Never claimable". A suppressed analog control
-- reuses the existing `suppressed` bookkeeping (already here for the
-- Input:reset() case above) so it gets the same held-style hysteresis: once
-- suppressed while held, it does not un-suppress until the control itself
-- drops below the RELEASE threshold, not the press one (CRITIQUE #2).
function InputMap:apply(controls, ctx)
  local Input = input()
  local actions = {}
  if not (Input and controls) then self:releaseAll(); return actions end
  self:_reconcile(Input)
  local held = self.held
  local sup = (ctx and ctx.suppress) or {}
  for key, btn in pairs(CLAIM_BTN) do
    if sup[key] then
      if held[btn] then
        held[btn] = nil
        pcall(Input.sourceRelease, Input, btn, SOURCE .. btn)
      end
      self.suppressed[btn] = true
    end
  end
  self:_set(Input, "a", (not sup.a) and controls.a == true)
  self:_set(Input, "b", (not sup.b) and controls.b == true)
  self:_set(Input, "start", controls.start == true)
  self:_set(Input, "select",
    analog(held.select or self.suppressed.select, controls.triggerL, 0.6, 0.35))
  self:_set(Input, "l", analog(held.l or self.suppressed.l, controls.gripL, 0.7, 0.45))
  self:_set(Input, "r", analog(held.r or self.suppressed.r, controls.gripR, 0.7, 0.45))

  -- battle-move: while the left stick walks the player in a battle (ctx.battleWalk) it is not the d-pad
  local padOff = sup.moveStick or (ctx and ctx.battleWalk == true)
  if not padOff then
    local sx, sy = tonumber(controls.moveX) or 0, tonumber(controls.moveY) or 0
    local mag = math.sqrt(sx * sx + sy * sy)
    local want = self.dir
    if mag < 0.35 then
      want, self.dirKey = nil, nil
    elseif mag > 0.55 then
      -- stick quadrant in the controller's own frame (fwd/back/left/right)
      local key
      if math.abs(sy) >= math.abs(sx) then key = sy > 0 and "f" or "b"
      else key = sx > 0 and "r" or "l" end
      local relative = ctx and ctx.lookYaw and not ctx.menuOpen
      key = (relative and "rel:" or "abs:") .. key
      if key ~= self.dirKey then
        self.dirKey = key
        if relative then
          -- latched at press time so a turning world cannot spin the player
          local stickYaw = math.atan2(-sx, sy)
          want = quantise(ctx.lookYaw + stickYaw)
        else
          if math.abs(sy) >= math.abs(sx) then want = sy > 0 and "up" or "down"
          else want = sx > 0 and "right" or "left" end
        end
      end
    end
    if want ~= self.dir then
      if self.dir then self:_set(Input, self.dir, false) end
      self.dir = want
    end
    for _, d in ipairs({ "up", "down", "left", "right" }) do
      self:_set(Input, d, d == self.dir)
    end
  elseif self.dir then
    self:_set(Input, self.dir, false)
    self.dir = nil
    self.dirKey = nil
  end
  self:_freeIntent(controls, ctx, sup)

  local toggle = controls.toggle == true
  if toggle and not self.toggleWas then actions.toggle = true end
  self.toggleWas = toggle

  if not sup.lookStick then
    local look = tonumber(controls.lookX) or 0
    if math.abs(look) > 0.65 then
      if self.snapArmed then
        self.snapArmed = false
        actions.snap = look > 0 and 1 or -1
      end
    elseif math.abs(look) < 0.35 then
      self.snapArmed = true
    end
    -- Lab 8: analog turn for the SMOOTH style, rescaled past the dead zone
    local dead = InputMap.TURN_DEAD
    if math.abs(look) > dead then
      local t = (math.abs(look) - dead) / (1 - dead)
      actions.turn = (look > 0 and 1 or -1) * math.min(1, t)
    end
  end
  return actions
end

-- Lab 8: the left stick's analog push as a world direction for FreeMove.
-- Look-relative in the 3D field (stick forward = where the head looks);
-- north-up when there is no look yaw (the 3/4 table-top). Zero while a VR
-- layer claims the stick. panel = the 3D field is not what the player sees
-- (menus, the flat panel), so FreeMove keeps the grid walk.
function InputMap:_freeIntent(controls, ctx, sup)
  if not FreeMove then return end
  local x, z, m = 0, 0, 0
  if not sup.moveStick then
    local sx, sy = tonumber(controls.moveX) or 0, tonumber(controls.moveY) or 0
    local mag = math.sqrt(sx * sx + sy * sy)
    local dead = FreeMove.DEAD or 0.2
    if mag > dead then
      m = math.min(1, (mag - dead) / (1 - dead))
      local yaw = ((ctx and ctx.lookYaw) or 0) + math.atan2(-sx, sy)
      x, z = -math.sin(yaw), -math.cos(yaw)
    end
  end
  self.freeX, self.freeZ, self.freeM = x, z, m -- diagnostics
  local o = self.freeOpts -- reused: this runs every frame
  if not o then o = {}; self.freeOpts = o end
  o.look = ctx and ctx.lookYaw or nil
  o.faceLook = ctx and ctx.faceLook == true
  o.panel = not (ctx and ctx.menuOpen == false)
  pcall(FreeMove.setIntent, x, z, m, o)
end

return InputMap
