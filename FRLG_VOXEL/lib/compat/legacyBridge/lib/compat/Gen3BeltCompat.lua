-- FireRed party-belt polish (Lab 8, plan P1-3 a/b). Gen3 compat layer
-- (standing rule 2026-09-28): installed into VRITK's own V from the same
-- single gated seam as Gen3ChooseYouCompat, so Crystal/Yellow keep the
-- shared PartyBeltComponent / QuestGearSprites exactly as they are.
--
-- 1. Stall tolerance. PartyBeltComponent drops a held ball when one frame
--    takes longer than 0.2 s (update: dt > .2 -> reset) and when its own
--    layer has not run for 0.25 s (fixedStep: fresh <= 0 -> reset). The Lab 7
--    headset log shows a 350-460 ms stall about every 2.4 s, so on FireRed a
--    held ball fell back to the belt every couple of seconds. Here a frame up
--    to STALL_MAX long is clamped to 0.2 s (the same step the juggle
--    integrator accepts) and the layer counts as live for FRESH seconds.
--    Longer gaps (a real suspend, a warp) still reset as before.
-- 2. Hover picture. The hover card asks QuestGearSprites for the species by
--    NAME (its atlas keys: BULBASAUR, MR_MIME, NIDORAN_F ...); FireRed party
--    mons carry the species NUMBER, so the card had a name and no picture.
--    Numbers become game3's own key names (src.core.game3.pokemon.keyName)
--    before the lookup; a string species passes through untouched.
-- 3. A while holding. A held belt ball grows with A (PartyBallPresentation);
--    on Crystal PartyBeltComponent also strips that A from the game's input
--    queue, which FireRed's input does not have, so A also talked to
--    whoever stood in front of you. holding() tells FRLG_CATCH to claim A
--    from the game (vrHost input claim) while a belt ball is in a hand.
--    Crystal works its A strip out afresh every tick, so it can never go
--    stale; holding() must not either (Lab 8 review, defect 2): it is true
--    only while VRITK's belt is usable (the seam's enabled() gate: no
--    disableParty, no layer error), that belt still has a ball in a hand
--    right now, and its update saw that hand within FRESH seconds. A belt
--    that stops updating while a ball is in a hand (disabled after an
--    error, a dead layer) gives A back at once, or within FRESH at worst.
local HostV = ...
local M = {}

M.STALL_MAX = 1.0
M.FRESH = 1.0

local installed = nil

local function installStall(ctx)
  local PBC = ctx.V.require("PartyBeltComponent")
  local orig = PBC.update
  PBC.update = function(self, context, ...)
    local dt = type(context) == "table" and tonumber(context.dt) or nil
    if dt and dt > .2 and dt <= M.STALL_MAX then
      local c = {}
      for k, v in pairs(context) do c[k] = v end
      c.dt = .2
      context = c
      ctx.clamped = (ctx.clamped or 0) + 1
    end
    -- cleared first, so an update that throws (VRITK then disables the
    -- belt) leaves no stale claim behind
    ctx.holding = false
    ctx.live.belt = self
    local out = orig(self, context, ...)
    -- update() leaves fresh at .25 only when it ran through (every reset path
    -- sets it to 0 first): widen that liveness window for fixedStep.
    if (tonumber(self.fresh) or 0) > 0 then self.fresh = math.max(self.fresh, M.FRESH) end
    ctx.holding = type(self.belt) == "table" and type(self.belt.hands) == "table" and next(self.belt.hands) ~= nil
    ctx.holdingAt = ctx.now()
    return out
  end
  return true, function() if PBC.update ~= orig then PBC.update = orig end end
end

local function installHover(ctx)
  local Sprites = ctx.V.require("QuestGearSprites")
  local orig = Sprites.draw
  local names = {}
  local function keyName(n)
    local cached = names[n]
    if cached ~= nil then return cached or nil end
    local ok, P = pcall(ctx.require, "src.core.game3.pokemon")
    local name
    if ok and type(P) == "table" and type(P.keyName) == "function" then
      local okN, k = pcall(P.keyName, n)
      if okN and type(k) == "string" and k ~= "" then name = k end
    end
    names[n] = name or false
    return name
  end
  Sprites.draw = function(self, spec)
    if type(spec) == "table" and type(spec.species) == "number" then
      local name = keyName(spec.species)
      if name then
        local copy = {}
        for k, v in pairs(spec) do copy[k] = v end
        copy.species = name
        spec = copy
      end
    end
    return orig(self, spec)
  end
  return true, function() if Sprites.draw ~= orig then Sprites.draw = orig end end
end

local function wallClock()
  return love and love.timer and love.timer.getTime and love.timer.getTime() or os.clock()
end

--- install(V[, deps]); deps = { enabled = VRITK's seam gate (the bridge
--- passes it), require/log/now (tests) }.
function M.install(V, deps)
  if installed and installed.V == V then return true, "already installed" end
  if installed then M.uninstall() end
  deps = deps or {}
  local ctx = { V = V, require = deps.require or require, log = deps.log or function() end, restore = {},
    enabled = type(deps.enabled) == "function" and deps.enabled or nil, now = deps.now or wallClock,
    live = setmetatable({}, { __mode = "v" }), holdingAt = -math.huge }
  local all = true
  for _, part in ipairs({ { "stall", installStall }, { "hover", installHover } }) do
    local ok, done, undo = pcall(part[2], ctx)
    if ok and done then ctx.restore[#ctx.restore + 1] = undo
    else all = false; ctx.log("belt " .. part[1] .. " fix off: " .. tostring(ok and undo or done)) end
  end
  if HostV and HostV.require then HostV.require("compat/EmeraldPokedexScanCompat").installInto(ctx) end
  installed = ctx
  return all
end

function M.uninstall()
  if not installed then return false end
  for i = #installed.restore, 1, -1 do pcall(installed.restore[i]) end
  installed = nil
  return true
end

function M.status()
  return { installed = installed ~= nil, clamped = installed and installed.clamped or 0,
    holding = M.holding() }
end

--- A belt ball is in a hand now, on a belt VRITK still runs (see 3. above).
--- No allocation.
function M.holding()
  local c = installed
  if not (c and c.holding == true) then return false end
  if c.now() - c.holdingAt > M.FRESH then return false end
  local b = c.live.belt
  b = b and b.belt
  if not (type(b) == "table" and type(b.hands) == "table" and next(b.hands) ~= nil) then return false end
  if c.enabled then
    local ok, on = pcall(c.enabled)
    if not (ok and on) then return false end
  end
  return true
end

return M
