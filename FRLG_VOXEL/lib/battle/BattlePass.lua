-- FRLG_VOXEL (W6, battle phase P-B1): the 3D battle presenter.
--
-- FireRed battles play IN the voxel world, like Crystal's VR battles. User
-- rule (2026-09-28): a battle NEVER shows the flat 2D battle panel. While the
-- voxel view is on, frame() returns true for the whole battle, whatever
-- happens; only the player turning the voxel view off shows the flat game.
-- Per frame (main.lua):
--   frame(ctx)          state machine; true while a battle (or its wipe) is on.
--   pin(headPose)       pins the seat to the camera (before View:prepare).
--   viewOpts()          { hideActors, cullX, cullZ } for View:prepare, or nil.
--   prepareFrame(view, uiCanvas)  draws the card canvases, builds meshes
--                       (after View:prepare, outside the eye pass).
--   beginCut(env) / endCut()  the cutaway around Scene:draw (BattleCut.lua).
--   drawEye(env)        world cards + synthetic platform per eye.
--   drawOverlay(P, eyeLocal)  the command card per eye (depth off).
--   veil(engineVeil)    the eye veil: the engine's fade or our own.
--   blankCanvas(w, h)   black quad for a frame whose world view failed.
-- States: idle -> wipe (transition; field still shown) -> fadeout (0.25 s
-- to black) -> [stage + seat chosen while black] -> fadein (0.25 s) ->
-- seated -> (battle over) idle, with a 0.25 s fade back in.
-- Errors: logged once, then the battle is rebuilt on the synthetic compact
-- stage (BattleStage.synthetic) and continues in 3D. After ERRORS_TO_VEIL
-- failing frames in a row the battle's visuals hide behind the veil
-- ("veiled") until it ends -- still never the flat panel. Nothing here
-- writes game state.
local V = ...
local Mat4 = V.require("render/Mat4")
local Shaders = V.require("render/Shaders")
local Light = V.require("render/Light")
local BattleStage = V.require("battle/BattleStage")
local BattleCards = V.require("battle/BattleCards")
local BattleSource = V.require("battle/BattleSource")
local BattleCut = V.require("battle/BattleCut")
local BattleCatch = V.require("battle/BattleCatch")
local BattleThrow = V.require("battle/BattleThrow")
local BattleOccluders = V.require("battle/BattleOccluders")
-- battle-move (2026-10-01): visual movement inside the battle (BATTLE MOVE option). Optional: without it
-- the seat stays exactly as pinned.
local okMove, BattleMove = pcall(V.require, "battle/BattleMove")
if not okMove or type(BattleMove) ~= "table" then BattleMove = nil end

local BattlePass = {}
BattlePass.__index = BattlePass
local hintImage -- wild-message: defined with the command card helpers below

BattlePass.FADE_S = 0.25          -- Crystal's fade to black and back
BattlePass.WIPE_VEIL = 0.0        -- veil reached during the wipe (0 = field stays clear)
BattlePass.WIPE_VEIL_S = 1.0
BattlePass.WIPE_TIMEOUT_S = 12    -- a transition that never becomes a battle (CRITIQUE #17)
BattlePass.ERRORS_TO_VEIL = 3     -- failing frames in a row before the visuals are veiled
BattlePass.ALPHA_CUT = 0.02
BattlePass.MAX_DT = 0.1
BattlePass.CUTAWAY = true         -- cut world geometry between the seat and the battlers
BattlePass.BG_DIM_VEIL = 0.45     -- veil per unit of the battle's stage.bgDim
BattlePass.SCREEN_FX = true       -- per-eye full-screen move effects (invert, greyscale, ...)
BattlePass.PLATFORM_COLOR = { 0.66, 0.63, 0.55 }
BattlePass.PLATFORM_EDGE = { 0.45, 0.42, 0.36 }
BattlePass.PLATFORM_SKIRT = 0.8   -- cells the platform side reaches down
BattlePass.PLATFORM_SEGMENTS = 28
-- Desktop 3/4 debug view (setDebugView("34")): eye this many cells behind,
-- to the right of and above the focus; the real seat is marked.
BattlePass.DEBUG_34 = { back = 7.5, side = 4.5, up = 6.5 }
BattlePass.MARKER_SIZE = 0.35     -- cells
-- battle-ui (2026-10-01). User (Lab 6): "I'm still seeing the battle menu in the overworld, and it's still messing
-- with my tablets." The VRITK tablet (Kanto Gear) owns the battle UI in a 3D battle: its battle page shows the
-- engine's messages, the action menu, the bag and party screens and every yes/no. "auto" = the floating command
-- card (the game's text box + FIGHT/BAG/POKeMON/RUN strip, or the whole frame for a full-screen screen) is not
-- drawn while VRITK_FRLG_HOST reports the tablet available (Gen3TabletCompat.available: the Gear tablet surface
-- is adopted); without a tablet (no Gear, desktop without VRITK) the card stays, so a battle is never left without
-- a UI. "always" = the old card; "never" = no card at all.
BattlePass.COMMAND_CARD = "auto"
-- wild-message: the opening dialogue ("A wild X appeared!") shows on the command card's text strip even while the
-- tablet owns the rest of the battle UI (BattleSource.info().battleDialogue). false = the tablet keeps it.
BattlePass.DIALOGUE_CARD = true
-- A small "A" marker beside the strip, only while the native box waits for A and shows no continue arrow of its own.
-- (Both only act while the tablet owns the battle UI: without the tablet the card is drawn exactly as before.)
BattlePass.DIALOG_HINT = true
BattlePass.HINT_SIZE = 0.11       -- metres
BattlePass.COMPAT_REFRESH = 120   -- frames between VRITK_FRLG_HOST compat lookups (mod.find allocates)
-- The user's own opening send-out (VRITK_FRLG_HOST Gen3PartyActionFX battleVisuals): from the moment the user's
-- beam leaves the ball, the battler's picture is the user's -- it grows as a white silhouette and turns to its
-- colours on the release_energy clock (GROW_SEC / SETTLE_SEC, sent with each beam) -- and it stays the user's
-- until the engine's own picture of that battler is fully shown (the engine's send-out plays no ball: the
-- release is physical). OPENING_MAX_S caps a latch whose engine picture never comes.
BattlePass.OPENING_MAX_S = 60
-- battle-move (user 2026-10-01: "I want movement in battle now."). The VR CONTROLS option BATTLE MOVE
-- (main.lua battle_move, default ON) walks / turns / room-scale-walks the seat inside the battle area
-- (BattleMove.lua). MOVE_STICK: "auto" = the left stick walks only while the VRITK tablet owns the battle
-- UI (otherwise the same stick is the d-pad of the command card and must stay so); "always" = walk with
-- the stick whatever owns the UI; "never" = no stick walking (turning and room-scale still work).
BattlePass.MOVE_STICK = "auto"
BattlePass.CARD_FOLLOW_POS = 6    -- 1/s: the floating command card follows the head's position
BattlePass.CARD_FOLLOW_YAW = 3    -- 1/s: ... and, past CARD_YAW_DEAD, the head's yaw
BattlePass.CARD_YAW_DEAD = math.rad(35)

local STAGED = { fadein = true, seated = true }
local SHOWN = { wipe = true, fadeout = true, fadein = true, seated = true, veiled = true }

local function wrapPi(a) return (a + math.pi) % (2 * math.pi) - math.pi end
local function clamp01(v) return math.max(0, math.min(1, v)) end

-- opts = { camera, hostApi, log, engine = fn(name) (tests), source (tests) }
function BattlePass.new(opts)
  opts = opts or {}
  local self = setmetatable({
    camera = opts.camera, hostApi = opts.hostApi, log = opts.log or print,
    engine = opts.engine,
    source = opts.source or BattleSource.new({ engine = opts.engine }),
    state = "idle", t = 0, exitT = nil, frameNo = 0,
    stage = nil, pendingPin = false, pinned = false, savedYaw = nil,
    cardBase = { 0, 0, 0 }, cardYaw = 0,
    battles = 0, staged = 0, synthetics = 0, veils = 0, failures = 0,
    errorsInRow = 0, frameFailed = false,
    lastError = nil, warned = {},
    forceNoArena = false, forceError = nil, debugView = nil, want = false,
    meshes = {}, frameCards = nil, info = nil, uiCanvas = nil, stats = {},
    veilBuf = { 0, 0, 0, 0 }, blackBuf = { 0, 0, 0, 1 },
  }, BattlePass)
  self.cards = BattleCards.new({ log = self.log })
  self.cut = BattleCut.new({ log = self.log })
  -- W6 r2: the in-battle physical throw (FRLG_CATCH catching.battleThrow)
  self.catch = BattleCatch.new({ engine = opts.engine, log = self.log })
  self.throw = BattleThrow.new({ pass = self, catch = self.catch, findMod = opts.findMod,
    engine = opts.engine, log = self.log })
  self.throwSlots = {}
  self.findMod = opts.findMod
  self.forced = {}        -- battle-ui: opening send-out latches, [battlerId] = { serial, age, ... }
  self.tabletUi = false
  -- battle-move
  self.moveEnabled = opts.battleMove ~= false and BattleMove ~= nil
  self.move = BattleMove and BattleMove.new({ log = self.log, enabled = self.moveEnabled }) or nil
  self.walkPct = opts.walkPct             -- fn() -> VR CONTROLS walk speed percent
  return self
end

-- battle-ui: VRITK_FRLG_HOST's compat table (tablet, chooseYou), looked up every COMPAT_REFRESH frames.
function BattlePass:vritkCompat()
  if self.compatAt and self.frameNo - self.compatAt < BattlePass.COMPAT_REFRESH then return self.compatCache end
  self.compatAt = self.frameNo
  self.compatCache = nil
  local find = self.findMod
  if type(find) ~= "function" then return nil end
  local ok, m = pcall(find, "VRITK_FRLG_HOST")
  local c = ok and type(m) == "table" and m.exports and m.exports.compat or nil
  if type(c) == "table" then self.compatCache = c end
  return self.compatCache
end

-- True when the tablet owns the battle UI (COMMAND_CARD "auto"): the floating command card is not drawn.
function BattlePass:tabletOwnsUi()
  local mode = BattlePass.COMMAND_CARD
  if mode == "always" then return false end
  if mode == "never" then return true end
  local c = self:vritkCompat()
  local t = c and c.tablet
  if not (t and type(t.available) == "function") then return false end
  local ok, on = pcall(t.available)
  return ok and on == true
end

-- The user's opening beams this frame: list of { battler, serial, age, growSec, settleSec } (plain data).
function BattlePass:openingBeams()
  local c = self:vritkCompat()
  local cy = c and c.chooseYou
  if not (cy and type(cy.battleVisuals) == "function") then return nil end
  local ok, list = pcall(cy.battleVisuals)
  return ok and type(list) == "table" and list or nil
end

local function ease01(x)
  x = math.max(0, math.min(1, x))
  return x * x * x * (x * (x * 6 - 15) + 10)
end

-- Opening latches: start one per new beam serial; returns { [battlerId] = latch }.
function BattlePass:updateOpeningLatches(dt)
  local forced = self.forced
  for _, b in ipairs(self:openingBeams() or {}) do
    local id = tonumber(b.battler)
    if id and b.serial ~= nil then
      local l = forced[id]
      -- belt-switch (2026-10-02): a battler can have a recall beam and then a send-out beam in one battle (BELT
      -- SWITCH); both stay listed for a moment, so a latch only ever moves on to a NEWER beam serial.
      if not l or (l.serial ~= b.serial and (tonumber(b.serial) or 0) > (tonumber(l.serial) or 0)) then
        if not (self.doneSerials and self.doneSerials[b.serial]) then
          l = { serial = b.serial, age = tonumber(b.age) or 0, growSec = tonumber(b.growSec) or 1.0,
            kind = b.kind, recallSec = tonumber(b.recallSec) or 1.555,
            settleSec = tonumber(b.settleSec) or 0.35, held = 0 }
          forced[id] = l
          self.stats.openingLatches = (self.stats.openingLatches or 0) + 1
        end
      elseif l.serial == b.serial then -- belt-switch review fix 2: an older listed beam never touches a newer latch
        l.age = math.max(l.age, tonumber(b.age) or l.age)
      end
      if l and l.serial == b.serial then l.seen = self.frameNo end
    end
  end
  for id, l in pairs(forced) do
    if l.seen ~= self.frameNo then l.age = l.age + (dt or 0) end
    l.held = (l.held or 0) + (dt or 0)
    if l.held > BattlePass.OPENING_MAX_S then self:endLatch(id, "max") end
  end
  return forced
end

-- A latch ends once: its beam serial is remembered for the battle, so a beam still reported afterwards
-- (VRITK keeps a finished beam a moment) cannot start it again.
function BattlePass:endLatch(id, why)
  local l = self.forced[id]
  if not l then return end
  self.forced[id] = nil
  self.doneSerials = self.doneSerials or {}
  self.doneSerials[l.serial] = true
  self.stats.lastLatchEnd = { id = id, why = why, age = l.age }
end

-- The user's look for a latched battler: grow (white silhouette) then colour, release_energy's own curves.
-- belt-switch: the user's recall look for a latched battler -- it turns white and shrinks into the red beam on
-- release_energy's recall curves (capture_plasma intake from 0.77 s: convert over 0.42 s from +0.13 s, pull over
-- 0.855 s from +0.70 s).
local function styleRecall(desc, l)
  local t = l.age or 0
  local convert = ease01((t - 0.13) / 0.42)
  local pull = ease01((t - 0.70) / 0.855)
  local size = math.max(0.001, (1 - pull) ^ 1.9)
  desc.sx, desc.sy = (desc.sx or 1) * size, (desc.sy or 1) * size
  if convert > 0.001 then desc.tint = { mode = "blend", coeff = 16 * convert, r = 31, g = 31, b = 31 } end
  desc.alpha, desc.flash, desc.shade = 1, 0, 1
  return desc
end

local function styleForced(desc, l)
  local t = l.age or 0
  local pull = 1 - ease01(t / math.max(1e-3, l.growSec))
  local convert = 1 - ease01((t - l.growSec) / math.max(1e-3, l.settleSec))
  local size = math.max(0.001, (1 - pull) ^ 1.9)
  desc.sx, desc.sy = (desc.sx or 1) * size, (desc.sy or 1) * size
  if convert > 0.001 then desc.tint = { mode = "blend", coeff = 16 * convert, r = 31, g = 31, b = 31 } end
  desc.alpha, desc.flash, desc.shade = 1, 0, 1
  return desc
end

function BattlePass:logOnce(key, msg)
  if self.warned[key] then return end
  self.warned[key] = true
  self.log("[FRLG_VOXEL] " .. tostring(msg))
end

local function notify(self, kind, payload)
  local h = self.hostApi
  if h and type(h.notifyBattle) == "function" then pcall(h.notifyBattle, h, kind, payload) end
end

local function cameraReset(self, reason)
  local h = self.hostApi
  if h and type(h.notifyCameraReset) == "function" then pcall(h.notifyCameraReset, h, reason) end
end

-- ------------------------------------------------------------ seat
function BattlePass:releaseSeat()
  local cam = self.camera
  if cam and cam.seat then
    cam.seat = nil
    if self.savedYaw ~= nil then cam.yaw = self.savedYaw end
    if cam.reset then pcall(cam.reset, cam) end -- snap back to the player (CRITIQUE #16)
    cameraReset(self, "battle-release")
  end
  self.savedYaw = nil
  self.pinned, self.pendingPin = false, false
  if self.move then self.move:reset() end -- battle-move: the walked offset dies with the seat
end

-- The seat the camera uses: the stage's, or the desktop debug view's.
function BattlePass:viewSeat()
  local st = self.stage
  if not st then return nil end
  if self.debugView == "34" then
    local d = BattlePass.DEBUG_34
    local f, ax, az, rx, rz = st.focus, st.axis[1], st.axis[2], st.right[1], st.right[2]
    local ex = f.x - ax * d.back + rx * d.side
    local ez = f.z - az * d.back + rz * d.side
    local ey = f.y + d.up
    local dx, dy, dz = f.x - ex, f.y - ey, f.z - ez
    local h = math.sqrt(dx * dx + dz * dz)
    return { x = ex, y = ey, z = ez, yaw = BattleStage.yawToward(dx, dz),
      pitch = math.atan2(dy, h), dist = math.sqrt(h * h + dy * dy) * BattleStage.METRES_PER_CELL,
      name = "debug-34" }
  end
  return st.seat
end

function BattlePass:pin(head)
  if not (self.pendingPin and self.stage and self.camera) then return false end
  local seat = self:viewSeat()
  if not seat then return false end
  local cam = self.camera
  local pos = head and head.pos or { 0, 0, 0 }
  local hy = (head and head.quat) and Mat4.quatYaw(head.quat) or 0
  if self.savedYaw == nil then self.savedYaw = cam.yaw end
  cam.seat = {
    x = seat.x, y = seat.y, z = seat.z, yaw = wrapPi(seat.yaw - hy),
    px = pos[1] or 0, py = pos[2] or 0, pz = pos[3] or 0,
    pitch = seat.pitch, focusDist = seat.dist,
  }
  cam.yaw = cam.seat.yaw
  self.cardBase = { pos[1] or 0, pos[2] or 0, pos[3] or 0 }
  self.cardYaw = hy
  if self.move then self.move:begin(cam.seat) end -- battle-move: (re)pinned = back at the seat
  self.cardPin = { self.cardBase[1], self.cardBase[2], self.cardBase[3], self.cardYaw }
  self.pendingPin, self.pinned = false, true
  cameraReset(self, "battle-seat")
  return true
end

-- Re-pin on the next frame (session restart, recentre, 3D toggle: CRITIQUE #20).
function BattlePass:notifyReset(reason)
  if self.stage and STAGED[self.state] then
    self.pendingPin = true
    self.resetReason = reason
  end
end

-- ------------------------------------------------------------ battle-move
-- BATTLE MOVE on/off (VR CONTROLS option). Off in a running battle puts the seat back where it was pinned.
function BattlePass:setMoveEnabled(on)
  on = on ~= false and BattleMove ~= nil
  if on == self.moveEnabled then return end
  self.moveEnabled = on
  if self.move then self.move:setEnabled(on) end
  if self.stage then self:stageOccluders(self.stage) end -- the cutaway list follows the area (wide on, as before off)
end

-- Movement is live: on, seated (fadein/seated state), the seat pinned.
function BattlePass:moveActive()
  return self.moveEnabled == true and self.move ~= nil and STAGED[self.state] == true and self.stage ~= nil
    and self.pinned == true and self.camera ~= nil and self.camera.seat ~= nil
end

-- Does the left stick walk (and so stop being the d-pad) right now?
function BattlePass:walkOwnsStick()
  if not self:moveActive() then return false end
  local mode = BattlePass.MOVE_STICK
  if mode == "always" then return true end
  if mode == "never" then return false end
  return self.tabletUi == true
end

-- The eye in world cells while the player has moved ({ x, z }), else nil (the seat is the eye).
function BattlePass:eyeWorld()
  local mv = self.move
  if self.moveEnabled and mv and mv.eye and self.camera and self.camera.seat then return mv.eye end
  return nil
end

-- Wall-dim level (0..1) for a head pushed past the edge of the battle area.
function BattlePass:moveDim()
  local mv = self.move
  return (self.moveEnabled and mv and mv.dim) or 0
end

local function stagePass(name)
  for _, p in ipairs(BattleStage.PASSES) do if p.name == name then return p end end
  return BattleStage.PASSES[1]
end

-- Standable ground for the walker (integer cells), from the same world query the stage was found
-- with; cached per stage. nil = no ground test (synthetic platform, no world, query failed).
function BattlePass:moveCellOk()
  if self.moveCellFn ~= nil then return self.moveCellFn or nil end
  local st, host = self.stage, self.hostApi
  self.moveCellFn = false
  if not st or st.synthetic or not host or not host.locate then return nil end
  local okQ, q = pcall(BattleStage.worldQuery, host, { engine = self.engine })
  if not okQ or type(q) ~= "table" or type(q.cell) ~= "function" then return nil end
  local pass = stagePass(st.pass)
  local surfing = self.playerAtStart and self.playerAtStart.surfing == true
  local cache = {}
  self.moveCellFn = function(cx, cz)
    local key = cx * 65536 + cz
    local v = cache[key]
    if v == nil then
      local ok, info = pcall(q.cell, cx, cz)
      v = false
      if ok and type(info) == "table" and not info.warp then
        v = (info.walk or (info.water and (surfing or pass.water == "any"))
          or (pass.low and info.low)) and true or false
      end
      cache[key] = v
    end
    return v
  end
  return self.moveCellFn
end

-- The left/right stick for the next moveFrame. controls = the Quest controls snapshot, actions =
-- InputMap:apply's result, suppress = the VRITK claim mask. Called once per frame from main.lua.
function BattlePass:moveInput(controls, actions, dt, suppress)
  local mv = self.move
  if not mv then return end
  if not self:moveActive() then mv:setStick(0, 0); return end
  suppress = suppress or {}
  local sx, sy = 0, 0
  if self:walkOwnsStick() and not suppress.moveStick and type(controls) == "table" then
    sx, sy = tonumber(controls.moveX) or 0, tonumber(controls.moveY) or 0
  end
  mv:setStick(sx, sy)
  if not suppress.lookStick then
    local cam = self.camera
    mv:turnInput(actions, dt, cam.turnStyle, cam.turnSpeed, cam.snapAngle and cam:snapAngle() or nil)
  end
end

-- Once per frame after pin(), before the camera updates: moves the seat. head = the centre head pose
-- ({ pos, quat }, LOCAL) or nil on the desktop. Returns true when the seat was moved this frame.
function BattlePass:moveFrame(head, dt)
  local mv, cam = self.move, self.camera
  if not (mv and cam and cam.seat and self.stage and STAGED[self.state] and self.pinned) then return false end
  if not self.moveEnabled then
    -- switched off in a running battle: back to the pinned seat
    if mv.eye or mv.dyaw ~= 0 then
      mv:restore(cam.seat)
      cam.yaw = cam.seat.yaw
      local cp = self.cardPin
      if cp then self.cardBase, self.cardYaw = { cp[1], cp[2], cp[3] }, cp[4] end
    end
    return false
  end
  local hx, hz, headYaw
  if type(head) == "table" and type(head.pos) == "table" then
    hx, hz = head.pos[1], head.pos[3]
    headYaw = head.quat and Mat4.quatYaw(head.quat) or 0
  end
  local host = self.hostApi
  local heightAt = nil
  if host and host.heightAt then heightAt = function(x, z) return host:heightAt(x, z) end end
  local ok, eye = pcall(mv.frame, mv, {
    seat = cam.seat, dt = dt, head = hx and { hx, hz } or nil, headYaw = headYaw,
    walkPct = self.walkPct and self.walkPct() or nil,
    slots = self.throwSlots, cellOk = self:moveCellOk(), heightAt = heightAt, focus = self.stage.focus })
  mv:setStick(0, 0) -- the stick is one-shot: the next frame's input (main.lua) sets it again
  if not ok then
    self:logOnce("move", "battle movement error (seat left as is): " .. tostring(eye))
    return false
  end
  cam.yaw = cam.seat.yaw
  -- the floating command card (no tablet) follows the head: its position softly, its yaw once the head
  -- has turned well away
  if type(head) == "table" and type(head.pos) == "table" then
    local d = math.max(0, math.min(tonumber(dt) or 0, BattlePass.MAX_DT))
    local kp = 1 - math.exp(-d * BattlePass.CARD_FOLLOW_POS)
    local b = self.cardBase
    b[1] = b[1] + ((head.pos[1] or 0) - b[1]) * kp
    b[2] = b[2] + ((head.pos[2] or 0) - b[2]) * kp
    b[3] = b[3] + ((head.pos[3] or 0) - b[3]) * kp
    local dy = wrapPi((headYaw or 0) - self.cardYaw)
    if math.abs(dy) > BattlePass.CARD_YAW_DEAD then
      self.cardYaw = wrapPi(self.cardYaw + dy * (1 - math.exp(-d * BattlePass.CARD_FOLLOW_YAW)))
    end
  end
  return eye ~= nil
end

-- ------------------------------------------------------------ staging
-- Round 2: the trees, buildings and clutter around the seat and the arena
-- (BattleOccluders), once per stage; the cutaway picks from them per frame.
function BattlePass:stageOccluders(stage)
  local s = stage.seat or {}
  local xs = { stage.own.x, stage.foe.x, tonumber(s.x) or stage.own.x }
  local zs = { stage.own.z, stage.foe.z, tonumber(s.z) or stage.own.z }
  local pad, lowR = 2, nil
  if self.moveEnabled and BattleMove then
    -- battle-move: the player can stand anywhere in the battle area, so the cutaway list covers it
    pad = pad + BattleMove.RADIUS
    lowR = BattleMove.RADIUS + BattleOccluders.LOW_RADIUS
  end
  local x0, x1 = math.min(xs[1], xs[2], xs[3]) - pad, math.max(xs[1], xs[2], xs[3]) + pad
  local z0, z1 = math.min(zs[1], zs[2], zs[3]) - pad, math.max(zs[1], zs[2], zs[3]) + pad
  local near = s.x and { x = s.x, z = s.z } or nil
  local ok, list, source = pcall(BattleOccluders.collect, self.hostApi, x0, z0, x1, z1,
    { engine = self.engine, near = near, lowRadius = lowR })
  self.occluders = ok and list or {}
  self.occluderSource = ok and source or ("error: " .. tostring(list))
end

function BattlePass:setStage(stage, why)
  self.stage = stage
  self.moveCellFn = nil -- battle-move: the ground test is per stage
  self.occHold = nil    -- tree fix: the held occluders belong to the previous stage
  self.throwSlots = {}  -- battle-move: no keep-out from the previous stage on the first frame of this one
  self:stageOccluders(stage)
  self.frameCards = nil
  self.pendingPin = true
  if stage.synthetic then self.synthetics = self.synthetics + 1 end
  local s = stage.seat or {}
  self.log(("[FRLG_VOXEL] battle staged%s: %s (%s pass, walk %s) facing %s, own (%d,%d) foe (%d,%d), seat %s %.2f m%s%s"):format(
    why and (" [" .. why .. "]") or "",
    tostring(stage.shape), tostring(stage.pass), tostring(stage.walk), tostring(stage.dir),
    stage.own.cellX, stage.own.cellZ, stage.foe.cellX, stage.foe.cellZ,
    tostring(s.name), tonumber(s.dist) or -1,
    stage.relocated and " (moved to the nearest open spot)" or "",
    stage.sightBlocked and " (cutaway clears the view)" or ""))
  notify(self, "stage", self:stageSummary())
end

local function playerInput(self, synthetic)
  local src = self.source
  local p = src:player()
  if not p then error("no player cell", 0) end
  local host = self.hostApi
  local ground
  if host and host.heightAt then
    local okH, gy = pcall(host.heightAt, host, p.cellX + 0.5, p.cellY + 0.5)
    if okH and type(gy) == "number" then ground = gy end
  end
  self.playerAtStart = self.playerAtStart
    or { cellX = p.cellX, cellY = p.cellY, facing = p.facing, surfing = p.surfing }
  return { cellX = p.cellX, cellZ = p.cellY, facing = p.facing, surfing = p.surfing,
    ground = ground, synthetic = synthetic }
end

function BattlePass:stageNow()
  local input = playerInput(self, self.forceNoArena)
  local q = nil
  if self.hostApi and not self.forceNoArena then
    q = BattleStage.worldQuery(self.hostApi, { engine = self.engine,
      center = { x = input.cellX + 0.5, z = input.cellZ + 0.5 } })
  end
  local stage, why = BattleStage.find(q, input)
  if not stage then error("stage: " .. tostring(why), 0) end
  self.staged = self.staged + 1
  self.state, self.t = "fadein", 0
  self:setStage(stage, self.forceNoArena and "forced: no arena" or nil)
end

-- Rebuild on the synthetic compact stage (after an error), keeping the
-- battle in 3D. Never raises.
function BattlePass:rebuildSynthetic(reason)
  local ok, err = pcall(function()
    local input = playerInput(self, true)
    local q = self.hostApi and BattleStage.worldQuery(self.hostApi, { engine = self.engine }) or nil
    local stage = BattleStage.synthetic(input, q)
    if not STAGED[self.state] then self.state, self.t = "fadein", 0 end
    self:setStage(stage, "rebuilt after an error: " .. tostring(reason))
  end)
  if not ok then
    self.lastError = "synthetic: " .. tostring(err)
    return false
  end
  return true
end

function BattlePass:finish(reason)
  local was = self.state
  self.forced, self.doneSerials = {}, nil
  self:releaseSeat()
  pcall(self.cut.finish, self.cut)
  self.stage, self.frameCards = nil, nil
  self.state, self.t = "idle", 0
  self.dlgUp, self.dlgText = nil, nil -- wild-message
  self.errorsInRow = 0
  self.playerAtStart = nil
  if was ~= "wipe" then self.exitT = 0 end
  notify(self, "end", { reason = reason })
end

local function step(self, ctx)
  local dt = math.max(0, math.min(tonumber(ctx.dt) or 0, BattlePass.MAX_DT))
  self.frameNo = self.frameNo + 1
  if self.state ~= "idle" or self.frameNo % 120 == 1 then pcall(self.throw.install, self.throw) end
  local src = self.source
  local active, trans = src:active(), src:transition()
  -- a timed-out transition is not re-entered until it ends (or a battle starts)
  if self.wipeLatch and (active or not trans) then self.wipeLatch = nil end
  local s = self.state
  if s == "idle" then
    if active or (trans and not self.wipeLatch) then
      self.battles = self.battles + 1
      self.exitT = nil
      self.state, self.t = active and "fadeout" or "wipe", 0
    end
  elseif s == "wipe" then
    self.t = self.t + dt
    if active then
      self.state, self.t = "fadeout", 0
    elseif not trans or self.t > BattlePass.WIPE_TIMEOUT_S then
      if trans then self.wipeLatch = true end
      self:finish(trans and "wipe-timeout" or "no-battle")
    end
  elseif s == "fadeout" then
    if not active then
      self:finish("ended-before-stage")
    else
      self.t = self.t + dt
      if self.t >= BattlePass.FADE_S then self:stageNow() end
    end
  elseif s == "fadein" or s == "seated" or s == "veiled" then
    if not active then
      self:finish("ended")
    elseif s == "fadein" then
      self.t = self.t + dt
      if self.t >= BattlePass.FADE_S then self.state = "seated" end
    end
  end
  if self.exitT then
    self.exitT = self.exitT + dt
    if self.exitT >= BattlePass.FADE_S then self.exitT = nil end
  end
end

-- A presenter error: log once, rebuild on the synthetic stage and stay 3D.
-- ERRORS_TO_VEIL failing frames in a row veil the visuals until the battle
-- ends. Never selects the flat panel.
function BattlePass:fail(where, err)
  self.failures = self.failures + 1
  self.lastError = tostring(where) .. ": " .. tostring(err)
  self:logOnce("fail:" .. tostring(where), "battle presenter error (battle stays 3D, synthetic stage): "
    .. self.lastError)
  if not self.frameFailed then
    self.frameFailed = true
    self.errorsInRow = self.errorsInRow + 1
  end
  local s = self.state
  -- no stage to rebuild yet (idle / wipe), or already veiled
  if s == "idle" or s == "wipe" or s == "veiled" then return end
  if self.errorsInRow >= BattlePass.ERRORS_TO_VEIL then
    if self.state ~= "veiled" then
      self.state = "veiled"
      self.veils = self.veils + 1
      self.frameCards = nil
      self.log("[FRLG_VOXEL] battle visuals hidden behind the veil after repeated errors (still no flat panel): "
        .. self.lastError)
    end
    return
  end
  self:rebuildSynthetic(where)
end

function BattlePass:frame(ctx)
  ctx = ctx or {}
  if not self.frameFailed then self.errorsInRow = 0 end
  self.frameFailed = false
  local ok, err = pcall(step, self, ctx)
  if not ok then
    local okF = pcall(self.fail, self, "frame", err)
    if not okF and (STAGED[self.state] or self.state == "fadeout") then self.state = "veiled" end
  end
  self.want = SHOWN[self.state] == true and ctx.enabled ~= false
  return self.want
end

-- True while the seat is (or is about to be) in use.
function BattlePass:seated()
  return STAGED[self.state] == true
end

-- FRLG_VOXEL's own in-scene UI card stays hidden while a battle shows in 3D
-- (the battle frame is not a transparent UI plane).
function BattlePass:showFieldCard()
  return not self.want
end

function BattlePass:viewOpts()
  if not (STAGED[self.state] and self.stage) then return nil end
  return { hideActors = true, cullX = self.stage.cullX, cullZ = self.stage.cullZ }
end

function BattlePass:veil(engineVeil)
  local s = self.state
  if s == "veiled" then return self.blackBuf end
  local a = 0
  if s == "fadeout" then
    a = clamp01(self.t / BattlePass.FADE_S)
  elseif s == "fadein" then
    a = 1 - clamp01(self.t / BattlePass.FADE_S)
    if self.pendingPin then a = 1 end
  elseif s == "wipe" and BattlePass.WIPE_VEIL > 0 then
    a = BattlePass.WIPE_VEIL * clamp01(self.t / BattlePass.WIPE_VEIL_S)
  end
  if self.exitT then a = math.max(a, 1 - clamp01(self.exitT / BattlePass.FADE_S)) end
  -- Round 3: the battle's own dims (ui.lua: stage.bgDim, the Old Man /
  -- Pokedude voiceover dim), mildly, while staged
  local fx = STAGED[s] and self.screenFx or nil
  if fx then
    a = math.max(a, clamp01((tonumber(fx.bgDim) or 0) * BattlePass.BG_DIM_VEIL),
      clamp01(tonumber(fx.voiceDim) or 0))
  end
  local ea = (type(engineVeil) == "table" and tonumber(engineVeil[4])) or 0
  if a <= ea then return engineVeil end
  local b = self.veilBuf
  b[1], b[2], b[3], b[4] = 0, 0, 0, a
  return b
end

-- A black quad for the rare frame whose 3D view could not render (a map
-- still building): the flat battle frame is never shown instead.
function BattlePass:blankCanvas(w, h)
  local c = self.blank
  if c and c:getWidth() == w and c:getHeight() == h then return c end
  if c and c.release then pcall(c.release, c) end
  local ok, nc = pcall(love.graphics.newCanvas, w, h, { dpiscale = 1 })
  if not ok or not nc then self.blank = nil; return nil end
  local g = love.graphics
  g.push("all")
  pcall(function()
    g.setCanvas(nc)
    g.clear(0, 0, 0, 1)
  end)
  g.pop()
  self.blank = nc
  return nc
end

-- ------------------------------------------------------------ per-frame cards
local function guarded(body, ...)
  local g = love.graphics
  g.push("all")
  local ok, a, b = pcall(body, ...)
  g.pop()
  if not ok then return false, tostring(a) end
  return true, a, b
end

local whiteImage
local function white()
  if whiteImage ~= nil then return whiteImage or nil end
  whiteImage = false
  local okD, d = pcall(love.image.newImageData, 1, 1, "rgba8")
  if okD and d then
    d:setPixel(0, 0, 1, 1, 1, 1)
    local okI, img = pcall(love.graphics.newImage, d)
    if okI and img then whiteImage = img end
  end
  return whiteImage or nil
end

local function setMesh(self, i, verts, texture)
  local mesh = self.meshes[i]
  if mesh and mesh.nverts ~= #verts then
    if mesh.m.release then pcall(mesh.m.release, mesh.m) end
    mesh = nil
  end
  if not mesh then
    local ok, m = pcall(love.graphics.newMesh, Shaders.FORMAT, verts, "triangles", "stream")
    if not ok then return nil end
    mesh = { m = m, nverts = #verts }
    self.meshes[i] = mesh
    self.meshesMade = (self.meshesMade or 0) + 1
  else
    mesh.m:setVertices(verts)
  end
  if texture then mesh.m:setTexture(texture) end
  return mesh.m
end

local function cardVerts(c, lit)
  local x0, z0, x1, z1, y0, y1 = BattleCards.quad(c)
  local n = lit and 1 or 0
  return {
    { x0, y0, z0, 0, 1, 0, n, 0 }, { x1, y0, z1, 1, 1, 0, n, 0 }, { x1, y1, z1, 1, 0, 0, n, 0 },
    { x0, y0, z0, 0, 1, 0, n, 0 }, { x1, y1, z1, 1, 0, 0, n, 0 }, { x0, y1, z0, 0, 0, 0, n, 0 },
  }
end

-- An effect band: the canvas on its arena-plane parallelogram, unlit.
local function bandVerts(q)
  local tl, tr, br, bl = q[1], q[2], q[3], q[4]
  return {
    { tl[1], tl[2], tl[3], 0, 0, 0, 0, 0 }, { tr[1], tr[2], tr[3], 1, 0, 0, 0, 0 },
    { br[1], br[2], br[3], 1, 1, 0, 0, 0 },
    { tl[1], tl[2], tl[3], 0, 0, 0, 0, 0 }, { br[1], br[2], br[3], 1, 1, 0, 0, 0 },
    { bl[1], bl[2], bl[3], 0, 1, 0, 0, 0 },
  }
end

local function blobVerts(c)
  -- flat on the ground: long axis across the view, short axis toward it
  local ax, az = c.dz * c.w / 2, -c.dx * c.w / 2
  local bx, bz = c.dx * c.h / 2, c.dz * c.h / 2
  local y = c.base
  local p00 = { c.x - ax - bx, y, c.z - az - bz, 0, 0, 0, 0, 0 }
  local p10 = { c.x + ax - bx, y, c.z + az - bz, 1, 0, 0, 0, 0 }
  local p11 = { c.x + ax + bx, y, c.z + az + bz, 1, 1, 0, 0, 0 }
  local p01 = { c.x - ax + bx, y, c.z - az + bz, 0, 1, 0, 0, 0 }
  return { p00, p10, p11, p00, p11, p01 }
end

-- The synthetic stage's platform: a flat disc with a skirt.
local function platformVerts(p)
  local top, skirt = {}, {}
  local n = BattlePass.PLATFORM_SEGMENTS
  local y = p.y + 0.03
  local yb = p.y - BattlePass.PLATFORM_SKIRT
  for i = 0, n - 1 do
    local a0, a1 = i / n * 2 * math.pi, (i + 1) / n * 2 * math.pi
    local x0, z0 = p.x + math.cos(a0) * p.radius, p.z + math.sin(a0) * p.radius
    local x1, z1 = p.x + math.cos(a1) * p.radius, p.z + math.sin(a1) * p.radius
    local c = { p.x, y, p.z, 0.5, 0.5, 0, 1, 0 }
    top[#top + 1] = c
    top[#top + 1] = { x0, y, z0, 0.5, 0.5, 0, 1, 0 }
    top[#top + 1] = { x1, y, z1, 0.5, 0.5, 0, 1, 0 }
    local nx, nz = math.cos((a0 + a1) / 2), math.sin((a0 + a1) / 2)
    skirt[#skirt + 1] = { x0, y, z0, 0.5, 0.5, nx, 0.2, nz }
    skirt[#skirt + 1] = { x1, y, z1, 0.5, 0.5, nx, 0.2, nz }
    skirt[#skirt + 1] = { x1, yb, z1, 0.5, 0.5, nx, 0.2, nz }
    skirt[#skirt + 1] = { x0, y, z0, 0.5, 0.5, nx, 0.2, nz }
    skirt[#skirt + 1] = { x1, yb, z1, 0.5, 0.5, nx, 0.2, nz }
    skirt[#skirt + 1] = { x0, yb, z0, 0.5, 0.5, nx, 0.2, nz }
  end
  return top, skirt
end

local function cardCorners(c)
  local q = c
  if c.restX then -- pan-in fix: the cutaway is cut around the slot, not around a picture that is sliding in
    q = { x = c.restX, z = c.restZ, dx = c.dx, dz = c.dz, w = c.w, h = c.h, base = c.base }
  end
  local x0, z0, x1, z1, y0, y1 = BattleCards.quad(q)
  return { { x0, y0, z0 }, { x1, y0, z1 }, { x0, y1, z0 }, { x1, y1, z1 } }
end

local function prepareBody(self, view, uiCanvas)
  if self.forceError then
    local fe = self.forceError
    if fe == "once" then self.forceError = nil end
    if fe == "once" and not self.stage.synthetic or fe == "always" then
      error("forced presenter error (test switch)", 0)
    end
  end
  local src, cards, stage = self.source, self.cards, self.stage
  local st = src:state()
  local info = src:info()
  self.info = info
  self.uiCanvas = uiCanvas
  local slots = {}
  local throwSlots = {}
  local tintModes = {}
  local alphas = {}
  local nBattler, nHp = 0, 0
  -- battle-ui: the user's own presentations own some pictures this frame (a VR catch in progress:
  -- BattleThrow:visualState; an opening send-out the user's beam has started: the latches)
  local catchVis = self.throw and self.throw.visualState and self.throw:visualState() or nil
  local latches = self:updateOpeningLatches(self.frameDt)
  local owned = {}
  for _, s in ipairs(BattleCards.slotIds(info)) do
    local id = s.id
    local side = BattleSource.sideOf(id)
    local desc
    local catchFoe = catchVis and catchVis.slot == id and catchVis.foe or nil
    local latch = latches[id]
    if catchFoe == "hide" then
      desc = nil
      owned[id] = "catch-hide"
    elseif catchFoe == "show" then
      desc = src:battlerDraw(id, st, { force = true })
      owned[id] = "catch-show"
    elseif latch and latch.kind == "recall" then
      local native = src:battlerDraw(id, st)
      if latch.age >= (latch.recallSec or 1.555) then
        desc = nil
        if not native then self:endLatch(id, "recalled") else owned[id] = "recall" end
      else
        desc = src:battlerDraw(id, st, { force = true })
        if desc then styleRecall(desc, latch) end
        owned[id] = "recall"
      end
    elseif latch then
      -- the engine's own picture, fully shown, ends the latch (after the user's grow has finished)
      local native = src:battlerDraw(id, st)
      local full = native and not native.tint and math.abs(tonumber(native.sy) or 0) >= 0.99
        and (tonumber(native.alpha) or 1) >= 0.99
      if full and latch.age >= latch.growSec + latch.settleSec then
        self:endLatch(id, "engine picture shown")
        desc = native
        self.stats.openingHandoffs = (self.stats.openingHandoffs or 0) + 1
      else
        desc = src:battlerDraw(id, st, { force = true })
        if desc then styleForced(desc, latch) end
        owned[id] = "opening"
      end
    else
      desc = src:battlerDraw(id, st)
    end
    local trainers = (id <= 1) and src:trainerDraw(side) or {}
    local base = desc and { x = desc.baseX, y = desc.baseY } or BattleSource.SINGLES[id % 2]
    -- pan-in fix: the trainer pictures' shared slide offset (the engine's trainer.enemy.ox / player.ox) pans their
    -- card in the world instead of being cut off at the canvas edge
    local trOx = 0
    if #trainers > 0 then
      local okS, raw = pcall(src.stageRaw, src)
      local tr = okS and type(raw) == "table" and raw.trainer or nil
      local row = type(tr) == "table" and (side == "enemy" and tr.enemy or tr.player) or nil
      trOx = type(row) == "table" and tonumber(row.ox) or 0
    end
    local drew = cards:renderBattler(id, side, desc, trainers, base, trOx)
    alphas[id] = BattleCards.cardAlpha(desc)
    tintModes[id] = desc and desc.tint and desc.tint.mode or nil
    local slot = src:slot(id, st)
    local hpDrawn = false
    if slot.hbVisible then hpDrawn = cards:renderHp(id, src, slot, st) end
    local x, z, ground = BattleStage.slotPosition(stage, id, info.double)
    local host = self.hostApi
    if not stage.synthetic and host and host.heightAt then
      local okG, gy = pcall(host.heightAt, host, x, z)
      if okG and type(gy) == "number" then ground = gy end
    end
    local size = cards.battlerSize and cards.battlerSize[id] -- gen5 native-res: this battler's canvas size
    slots[#slots + 1] = { id = id, x = x, z = z, ground = ground, visible = drew,
      topPx = desc and BattleCards.frameTopPx(desc) or BattleCards.PIC_PX_PER_CELL,
      hbVisible = hpDrawn, cw = size and size[1], ch = size and size[2],
      pan = desc and ((tonumber(desc.cx) or 0) - (tonumber(desc.restCx) or tonumber(desc.cx) or 0)) or 0, -- pan-in fix (px)
      trPan = trOx, trainerDrawn = cards.trainerDrawn and cards.trainerDrawn[id] == true or false }
    if drew then nBattler = nBattler + 1 end
    if hpDrawn then nHp = nHp + 1 end
    -- W6 r2: the physical-throw target: the picture's frame on its cell
    throwSlots[#throwSlots + 1] = { id = id, x = x, z = z, ground = ground,
      visible = drew and desc ~= nil and not desc.substitute,
      topPx = desc and BattleCards.frameTopPx(desc) or BattleCards.PIC_PX_PER_CELL,
      w = ((desc and tonumber(desc.imgW)) or 64) / BattleCards.PIC_PX_PER_CELL } -- gen5 native-res: real width
  end
  self.throwSlots = throwSlots
  -- Round 2: occluders between the eye and the Pokemon (and foreground
  -- clutter) for the cutaway
  local floorY = math.min(stage.own.ground or 0, stage.foe.ground or 0)
  local cutOcc = {}
  self.cutOccluders = nil
  if self.occluders and #self.occluders > 0 and view.viewX then
    local ppc = BattleCards.PIC_PX_PER_CELL
    local occCards = {}
    for _, t in ipairs(throwSlots) do
      if t.visible then
        occCards[#occCards + 1] = { x = t.x, z = t.z, base = t.ground, h = (tonumber(t.topPx) or ppc) / ppc }
      end
    end
    local eye = { x = view.viewX, y = view.viewY or (floorY + 1), z = view.viewZ }
    local chosen = BattleOccluders.forView(self.occluders, eye, occCards, stage.focus, floorY)
    chosen = self:holdOccluders(chosen)
    for i, o in ipairs(chosen) do cutOcc[i] = BattleOccluders.corners(o) end
    self.cutOccluders = chosen
  end
  local viewPos = { x = view.viewX, y = view.viewY, z = view.viewZ }
  local list = BattleCards.layout(slots, viewPos)
  -- Poke Balls: the catch throw, shakes and catch/break-out (stage.ball), and
  -- the send-out balls (stage.balls), placed on the arena axis
  local nBall = 0
  local noNativeBall = catchVis ~= nil and catchVis.nativeBall == false
  for i, b in ipairs(src:ballDraw()) do
    -- battle-ui: the engine's catch ball is not drawn while the user's catch presentation runs
    local alpha = nil
    if not (noNativeBall and b.key == "ball") then alpha = cards:renderBall(i, b) end
    if alpha then
      local c = BattleCards.ballCard(stage, b, viewPos, i)
      c.alpha, c.ballIndex = alpha, i
      list[#list + 1] = c
      nBall = nBall + 1
    end
  end
  -- W6 r2 (P-B2): the engine's own move effects and the ball-open burst,
  -- per depth band, on the plane through both battlers
  local nBand = 0
  if src:effectsLive() then
    nBand = cards:renderBands(src, noNativeBall)
    if nBand > 0 then
      local q, bverts
      if BattleCards.BAND_PLANE == "battler" and view.viewX then
        bverts = BattleCards.battlerBandVerts(stage, { x = view.viewX, z = view.viewZ }, info.double)
      elseif BattleCards.BAND_PLANE == "view" and view.viewX then
        q = BattleCards.viewPlane(stage, { x = view.viewX, y = view.viewY or 1, z = view.viewZ })
      end
      if not bverts then q = q or BattleCards.bandQuad(stage) end
      local cx = (stage.own.x + stage.foe.x) / 2
      local cz = (stage.own.z + stage.foe.z) / 2
      for k = 0, 2 do
        list[#list + 1] = { kind = "band", id = k, x = cx, z = cz, quad = q, verts = bverts, dist = 0 }
      end
    end
  end
  -- Round 3 (P-B3): a move background (Psychic, Night Shade) as a curtain
  -- behind the foe; the full-screen effect and the battle's dims for the eyes
  local nBg = 0
  if BattleCards.BACKGROUND_STYLE == "curtain" and view.viewX and src:backgroundLive() then
    local bgc = cards:renderBackground(src)
    if bgc then
      local cur = BattleCards.curtain(stage, { x = view.viewX, z = view.viewZ })
      cur.alpha = 1
      list[#list + 1] = cur
      nBg = 1
    end
  end
  self.screenFx = src:screenFx()
  BattleCards.sort(list)
  local blob = Light.blob()
  local cutOwn, cutFoe = {}, {}
  for i, c in ipairs(list) do
    local mesh
    if c.kind == "curtain" then
      mesh = cards.bg and setMesh(self, "curtain", cardVerts(c, false), cards.bg) or nil
    elseif c.kind == "band" then
      local tex = cards.band[c.id]
      mesh = tex and setMesh(self, "band" .. c.id, c.verts or bandVerts(c.quad), tex) or nil
      c.alpha = 1
    elseif c.kind == "ball" then
      local tex = cards.ball[c.ballIndex]
      mesh = tex and setMesh(self, i, cardVerts(c, true), tex) or nil
    elseif c.kind == "blob" then
      c.alpha = BattleCards.BLOB_ALPHA * (alphas[c.id] or 1)
      mesh = blob and setMesh(self, i, blobVerts(c), blob) or nil
    elseif c.kind == "trainer" then
      c.alpha = alphas[c.id] or 1
      local tex = cards.trainer and cards.trainer[c.id]
      mesh = tex and setMesh(self, i, cardVerts(c, true), tex) or nil
    elseif c.kind == "battler" then
      c.alpha = alphas[c.id] or 1
      local tex = cards.battler[c.id]
      mesh = (c.visible and tex) and setMesh(self, i, cardVerts(c, true), tex) or nil
    else
      c.alpha = 1
      local tex = cards.hp[c.id]
      mesh = tex and setMesh(self, i, cardVerts(c, false), tex) or nil
    end
    c.mesh = mesh
    if c.kind ~= "blob" and c.kind ~= "band" and c.kind ~= "curtain" then
      local ownSide = (c.kind == "ball") and ((c.t or 1) < 0.5) or (c.kind ~= "ball" and c.id % 2 == 0)
      local group = ownSide and cutOwn or cutFoe
      for _, p in ipairs(cardCorners(c)) do group[#group + 1] = p end
    end
  end
  local n = #list
  -- synthetic stage: the platform (drawn first, depth-writing)
  if stage.synthetic and stage.platform and white() then
    local top, skirt = platformVerts(stage.platform)
    n = n + 1
    table.insert(list, 1, { kind = "platform", id = -1, mesh = setMesh(self, n, top, white()),
      color = BattlePass.PLATFORM_COLOR })
    n = n + 1
    table.insert(list, 2, { kind = "platform", id = -2, mesh = setMesh(self, n, skirt, white()),
      color = BattlePass.PLATFORM_EDGE })
  end
  -- debug 3/4 view: mark the real seat
  if self.debugView == "34" and stage.seat and white() then
    local m = { kind = "marker", id = 9, x = stage.seat.x, z = stage.seat.z,
      base = stage.seat.y - BattlePass.MARKER_SIZE / 2, w = BattlePass.MARKER_SIZE,
      h = BattlePass.MARKER_SIZE, dx = 0, dz = 1, alpha = 1 }
    local dx, dz = (view.viewX or m.x) - m.x, (view.viewZ or m.z + 1) - m.z
    local len = math.sqrt(dx * dx + dz * dz)
    if len > 1e-4 then m.dx, m.dz = dx / len, dz / len end
    n = n + 1
    m.mesh = setMesh(self, n, cardVerts(m, false), white())
    list[#list + 1] = m
  end
  -- cutaway spec (per eye rectangles are made from these points)
  if stage.synthetic and stage.platform then
    local pts = {}
    local p = stage.platform
    for i = 0, 11 do
      local a = i / 12 * 2 * math.pi
      local x, z = p.x + math.cos(a) * p.radius, p.z + math.sin(a) * p.radius
      pts[#pts + 1] = { x, p.y, z }
      pts[#pts + 1] = { x, p.y + 2.2, z }
    end
    for _, q in ipairs(cutOwn) do pts[#pts + 1] = q end
    for _, q in ipairs(cutFoe) do pts[#pts + 1] = q end
    self.cutSpec = { synth = pts, floorY = p.y, occ = cutOcc, eye = viewPos }
  else
    self.cutSpec = { own = cutOwn, foe = cutFoe, floorY = floorY, occ = cutOcc, eye = viewPos }
  end
  -- wild-message: one log line when the opening dialogue card comes up or its text changes, one when it goes
  -- (edges only: no per-frame string work)
  local dlg = BattlePass.DIALOGUE_CARD and self.tabletUi == true and info.battleDialogue == true
  if dlg then
    local text = src:dialogText()
    if not self.dlgUp or text ~= self.dlgText then
      self.dlgUp, self.dlgText, self.dlgFrame = true, text, self.frameNo
      self.log(("[FRLG_VOXEL] battle dialogue card up (tablet owns UI: %s, A hint: %s): %s"):format(
        tostring(self.tabletUi == true), tostring(info.dialogHint == true), (text:gsub("\n", " / "))))
    end
  elseif self.dlgUp then
    self.log(("[FRLG_VOXEL] battle dialogue card closed after %d frames"):format(self.frameNo - (self.dlgFrame or self.frameNo)))
    self.dlgUp, self.dlgText = nil, nil
  end
  if dlg and info.dialogHint and BattlePass.DIALOG_HINT then hintImage(self) end
  self.frameCards = list
  self.stats = { battlers = nBattler, hp = nHp, balls = nBall, bands = nBand, background = nBg,
    statMasks = cards.statMasks or 0, screenFx = self.screenFx and self.screenFx.type or nil,
    frame = self.frameNo, cuts = 0,
    tints = cards.tints or 0, tintModes = tintModes,
    command = uiCanvas ~= nil, full = (info.fullscreen or info.window or info.choice) and true or false,
    tabletUi = self.tabletUi == true, owned = owned, nativeBallHidden = noNativeBall,
    openingLatches = self.stats.openingLatches, openingHandoffs = self.stats.openingHandoffs,
    lastLatchEnd = self.stats.lastLatchEnd, commandSkipped = self.stats.commandSkipped,
    commandDrawn = self.stats.commandDrawn, dialogueDrawn = self.stats.dialogueDrawn, hintDrawn = self.stats.hintDrawn,
    dialogue = dlg, dialogHint = info.dialogHint == true }
  return true
end

-- tree fix: BattleOccluders.forView picks per frame; an occluder picked within the last OCC_HOLD frames stays picked
-- (up to BattleOccluders.MAX_CUT, newest picks first), so cut trees do not flicker at the edge of the choice.
BattlePass.OCC_HOLD = 24
function BattlePass:holdOccluders(chosen)
  local hold = self.occHold
  if not hold then hold = {}; self.occHold = hold end
  local now = self.frameNo
  local out, seen = {}, {}
  for _, o in ipairs(chosen) do out[#out + 1] = o; seen[o] = true; hold[o] = now end
  local extra = {}
  for o, t in pairs(hold) do
    if not seen[o] then
      if now - t <= BattlePass.OCC_HOLD then extra[#extra + 1] = { o = o, t = t } else hold[o] = nil end
    end
  end
  table.sort(extra, function(a, b) if a.t ~= b.t then return a.t > b.t end return tostring(a.o) < tostring(b.o) end)
  for _, e in ipairs(extra) do
    if #out >= BattleOccluders.MAX_CUT then break end
    out[#out + 1] = e.o
  end
  return out
end

function BattlePass:prepareFrame(view, uiCanvas)
  self.frameCards = nil
  if not (STAGED[self.state] and self.stage and self.want) then return false end
  -- battle-ui: once per frame (never per eye): does the tablet own the battle UI, and the frame time for the
  -- opening latches (the presenter's own clock, like the fades)
  local okT, owns = pcall(self.tabletOwnsUi, self)
  self.tabletUi = okT and owns == true
  local t = (love and love.timer and love.timer.getTime and love.timer.getTime()) or os.clock()
  self.frameDt = self.lastPrepareT and math.max(0, math.min(BattlePass.MAX_DT, t - self.lastPrepareT)) or 0
  self.lastPrepareT = t
  local ok, err = guarded(prepareBody, self, view or {}, uiCanvas)
  if not ok then
    self:fail("prepare", err)
    -- one retry on the synthetic stage this same frame
    if STAGED[self.state] and self.stage and self.stage.synthetic then
      local ok2, err2 = guarded(prepareBody, self, view or {}, uiCanvas)
      if not ok2 then self:fail("prepare-synthetic", err2); return false end
      return true
    end
    return false
  end
  return true
end

-- ------------------------------------------------------------ cutaway (per eye)
function BattlePass:beginCut(env)
  if not (BattlePass.CUTAWAY and self.frameCards and self.cutSpec and env and env.vp) then return false end
  local ok, active = pcall(self.cut.begin, self.cut, env, self.cutSpec)
  if not ok then
    pcall(self.cut.finish, self.cut)
    self:logOnce("cut", "battle cutaway error (cut off this frame): " .. tostring(active))
    return false
  end
  if active then self.stats.cuts = (self.stats.cuts or 0) + 1 end
  return active == true
end

function BattlePass:endCut()
  pcall(self.cut.finish, self.cut)
end

-- ------------------------------------------------------------ per-eye draw
local function drawEyeBody(self, env)
  local list = self.frameCards
  if not list then return 0 end
  local shader = Shaders.get("CUTOUT")
  if not shader then return 0 end
  local g = love.graphics
  g.setShader(shader)
  Shaders.frame(shader, env, BattlePass.ALPHA_CUT)
  Shaders.shadow(shader, nil)
  Shaders.texSize(shader, nil)
  Shaders.send(shader, "u_mvp", "row", env.vp)
  local n = 0
  for _, c in ipairs(list) do
    if c.mesh then
      if c.kind == "curtain" then
        g.setDepthMode("lequal", false)
        g.setColor(1, 1, 1, 1)
        Shaders.send(shader, "u_alphaCut", 0.004)
      elseif c.kind == "platform" then
        g.setDepthMode("lequal", true)
        local col = c.color or BattlePass.PLATFORM_COLOR
        g.setColor(col[1], col[2], col[3], 1)
        Shaders.send(shader, "u_alphaCut", 0)
      elseif c.kind == "band" then
        -- the band canvas holds premultiplied colour (alpha-blended sprites
        -- drawn onto a clear canvas). No depth test: on the eye-facing band
        -- plane a point that maps onto your Pokemon's feet lies below the
        -- ground; the painter's order layers the bands with the cards.
        g.setDepthMode(BattleCards.BAND_PLANE ~= "axis" and "always" or "lequal", false)
        g.setBlendMode("alpha", "premultiplied")
        g.setColor(1, 1, 1, 1)
        Shaders.send(shader, "u_alphaCut", 0.004)
      else
        g.setDepthMode(c.kind == "marker" and "always" or "lequal", false)
        if c.kind == "marker" then
          g.setColor(1, 0.1, 0.9, 1) -- desktop debug view: the seat, seen through walls
        else
          g.setColor(1, 1, 1, c.alpha or 1)
        end
        Shaders.send(shader, "u_alphaCut", c.kind == "blob" and 0 or BattlePass.ALPHA_CUT)
      end
      g.draw(c.mesh)
      if c.kind == "band" then g.setBlendMode("alpha") end
      n = n + 1
    end
  end
  g.setColor(1, 1, 1, 1)
  g.setBlendMode("alpha")
  g.setDepthMode("lequal", true)
  g.setShader()
  return n
end

-- A draw error restores the eye's state and rebuilds the battle on the
-- synthetic stage from the next frame on.
local function restoreEyeState()
  local g = love.graphics
  pcall(g.setShader)
  pcall(g.setColor, 1, 1, 1, 1)
  pcall(g.setDepthMode, "lequal", true)
  pcall(g.setBlendMode, "alpha")
end

function BattlePass:drawEye(env)
  local ok, n = pcall(drawEyeBody, self, env)
  if not ok then
    restoreEyeState()
    self:fail("draw", n)
    return 0
  end
  return n
end

-- Round 3 (P-B3): the full-screen move effect for one eye. The eye image is
-- copied to a scratch canvas and drawn back through BattleCards.SCREEN_SHADER.
-- Only while an effect is on; any error only skips the pass.
local function postEyeBody(self, canvas)
  local fx = self.screenFx
  local code = fx and fx.type and BattleCards.SCREEN_TYPES[fx.type]
  if not (BattlePass.SCREEN_FX and code and canvas and self.frameCards) then return 0 end
  local sh = BattleCards.extraShader("screen", BattleCards.SCREEN_SHADER, self.log)
  if not sh then return 0 end
  local w, h = canvas:getDimensions()
  local cards = self.cards
  local tmp = cards.scratch
  if not tmp or tmp:getWidth() ~= w or tmp:getHeight() ~= h then
    if tmp and tmp.release then pcall(tmp.release, tmp) end
    local ok, c = pcall(love.graphics.newCanvas, w, h, { dpiscale = 1 })
    if not ok then return 0 end
    tmp = c
    cards.scratch = tmp
  end
  local g = love.graphics
  g.push("all")
  local ok, err = pcall(function()
    g.setCanvas(tmp)
    g.origin()
    g.setScissor()
    g.setShader()
    g.setDepthMode()
    g.setBlendMode("replace", "premultiplied")
    g.setColor(1, 1, 1, 1)
    g.draw(canvas, 0, 0)
    g.setCanvas({ canvas, depth = true })
    g.origin()
    g.setShader(sh)
    Shaders.send(sh, "u_type", code)
    Shaders.send(sh, "u_coeff", math.max(0, math.min(1, tonumber(fx.coeff) or 1)))
    Shaders.send(sh, "u_target", fx.target or { 1, 1, 1 })
    g.draw(tmp, 0, 0)
    g.setShader()
  end)
  g.pop()
  if not ok then
    self:logOnce("screenfx", "battle screen effect pass skipped: " .. tostring(err))
    return 0
  end
  self.stats.screenPasses = (self.stats.screenPasses or 0) + 1
  return 1
end

function BattlePass:postEye(canvas)
  local ok, n = pcall(postEyeBody, self, canvas)
  if not ok then
    self:logOnce("screenfx2", "battle screen effect pass error: " .. tostring(n))
    return 0
  end
  return n
end

local function commandMesh(self, v0, v1)
  local m = self.commandMeshV
  if m and m.v0 == v0 and m.v1 == v1 then return m.mesh end
  local verts = {
    { -0.5, -0.5, 0, 0, v1, 0, 0, 0 }, { 0.5, -0.5, 0, 1, v1, 0, 0, 0 }, { 0.5, 0.5, 0, 1, v0, 0, 0, 0 },
    { -0.5, -0.5, 0, 0, v1, 0, 0, 0 }, { 0.5, 0.5, 0, 1, v0, 0, 0, 0 }, { -0.5, 0.5, 0, 0, v0, 0, 0, 0 },
  }
  local mesh = m and m.mesh
  if mesh then
    mesh:setVertices(verts)
  else
    local ok, nm = pcall(love.graphics.newMesh, Shaders.FORMAT, verts, "triangles", "static")
    if not ok then return nil end
    mesh = nm
  end
  self.commandMeshV = { mesh = mesh, v0 = v0, v1 = v1 }
  return mesh
end

local UNLIT = { light = { sun = { 0, 1, 0 }, fill = { 0, 1, 0 }, terms = { 1, 0, 0 } },
  fog = { 1000, 2000, 0 }, fogColor = { 0, 0, 0, 1 } }

-- ---- wild-message: command card pose cache, allocation-free per-eye matrices, "A" hint marker
-- Same arithmetic as Mat4.mul, written into a caller table (no allocation). out must not alias a or b.
local function mulInto(out, a, b)
  for i = 0, 3 do
    local a1, a2, a3, a4 = a[i * 4 + 1], a[i * 4 + 2], a[i * 4 + 3], a[i * 4 + 4]
    for j = 1, 4 do
      out[i * 4 + j] = a1 * b[j] + a2 * b[4 + j] + a3 * b[8 + j] + a4 * b[12 + j]
    end
  end
  return out
end

-- The pose, the card's model matrix and the hint's model matrix depend only on the pinned seat, the strip
-- (or full frame) and the canvas height: built when one of those changes, not per frame or per eye.
local HINT_ROWS = { ".###.", "#...#", "#...#", "#####", "#...#", "#...#", "#...#" }
local function commandCache(self, full, uh)
  local b, yaw = self.cardBase, self.cardYaw
  local c = self.cmdCache
  if c and c.b1 == b[1] and c.b2 == b[2] and c.b3 == b[3] and c.yaw == yaw and c.full == full and c.uh == uh
      and c.hs == BattlePass.HINT_SIZE then
    return c
  end
  c = c or { mvpA = {}, mvpB = {}, mvpC = {} }
  c.b1, c.b2, c.b3, c.yaw, c.full, c.uh, c.hs = b[1], b[2], b[3], yaw, full, uh, BattlePass.HINT_SIZE
  local pose = BattleCards.commandPose(b, yaw, full, uh)
  c.pose = pose
  local base = Mat4.chain(Mat4.translate(pose.x, pose.y, pose.z), Mat4.rotY(pose.yaw), Mat4.rotX(-pose.tilt))
  c.model = Mat4.chain(base, Mat4.scale(pose.width, pose.height, 1))
  -- the marker sits above the strip's right end, in the card's own plane
  local hs = BattlePass.HINT_SIZE
  c.hintModel = Mat4.chain(base, Mat4.translate(pose.width * 0.5 - hs * 0.75, pose.height * 0.5 + hs * 0.6, 0.002),
    Mat4.scale(hs, hs, 1))
  self.cmdCache = c
  return c
end

-- A 24x24 red disc with a white "A" (built once, only when a hint is first wanted).
function hintImage(self)
  if self.hintImg ~= nil then return self.hintImg or nil end
  self.hintImg = false
  local ok, img = pcall(function()
    local N = 24
    local data = love.image.newImageData(N, N, "rgba8")
    local cx, cy = (N - 1) / 2, (N - 1) / 2
    for y = 0, N - 1 do
      for x = 0, N - 1 do
        local d = math.sqrt((x - cx) ^ 2 + (y - cy) ^ 2)
        if d <= 11.5 then
          local edge = d > 9.5
          if edge then data:setPixel(x, y, 0.35, 0.05, 0.05, 1) else data:setPixel(x, y, 0.86, 0.12, 0.12, 1) end
        else
          data:setPixel(x, y, 0, 0, 0, 0)
        end
      end
    end
    for gy = 1, #HINT_ROWS do
      for gx = 1, 5 do
        if HINT_ROWS[gy]:sub(gx, gx) == "#" then
          for oy = 0, 1 do
            for ox = 0, 1 do data:setPixel(7 + (gx - 1) * 2 + ox, 5 + (gy - 1) * 2 + oy, 1, 1, 1, 1) end
          end
        end
      end
    end
    local image = love.graphics.newImage(data)
    image:setFilter("linear", "linear")
    return image
  end)
  if ok and img then self.hintImg = img else self:logOnce("hintimg", "A hint image failed: " .. tostring(img)) end
  return self.hintImg or nil
end

local function hintMesh(self)
  local m = self.hintMeshV
  if m then return m end
  local verts = {
    { -0.5, -0.5, 0, 0, 1, 0, 0, 0 }, { 0.5, -0.5, 0, 1, 1, 0, 0, 0 }, { 0.5, 0.5, 0, 1, 0, 0, 0, 0 },
    { -0.5, -0.5, 0, 0, 1, 0, 0, 0 }, { 0.5, 0.5, 0, 1, 0, 0, 0, 0 }, { -0.5, 0.5, 0, 0, 0, 0, 0, 0 },
  }
  local ok, nm = pcall(love.graphics.newMesh, Shaders.FORMAT, verts, "triangles", "static")
  if not ok then return nil end
  self.hintMeshV = nm
  return nm
end

-- The command card, in the LOCAL space of the head pose pinned at seat time.
local function drawOverlayBody(self, P, eyeLocal)
  if not (self.frameCards and self.uiCanvas and P and eyeLocal) then return 0 end
  -- battle-ui: the tablet owns the battle UI (COMMAND_CARD "auto"): no floating card
  local info = self.info or {}
  if self.tabletUi and not (BattlePass.DIALOGUE_CARD and info.battleDialogue) then
    self.stats.commandSkipped = (self.stats.commandSkipped or 0) + 1
    return 0
  end
  local ui = self.uiCanvas
  local full = (info.fullscreen or info.window or info.choice) and true or false
  local okD, _, uh = pcall(ui.getDimensions, ui)
  local cache = commandCache(self, full, okD and uh or 160)
  local pose = cache.pose
  local mesh = commandMesh(self, pose.v0, pose.v1)
  local shader = Shaders.get("CUTOUT")
  if not (mesh and shader) then return 0 end
  local g = love.graphics
  mesh:setTexture(ui)
  g.setShader(shader)
  Shaders.frame(shader, UNLIT, 0.0)
  Shaders.shadow(shader, nil)
  Shaders.texSize(shader, nil)
  mulInto(cache.mvpA, P, eyeLocal)
  Shaders.send(shader, "u_mvp", "row", mulInto(cache.mvpB, cache.mvpA, cache.model))
  g.setColor(1, 1, 1, 1)
  g.draw(mesh)
  -- opening dialogue waiting for A with no native continue arrow: the small "A" marker beside the strip
  if self.tabletUi and info.dialogHint and BattlePass.DIALOG_HINT and not full then
    local img, hm = hintImage(self), hintMesh(self)
    if img and hm then
      hm:setTexture(img)
      Shaders.send(shader, "u_mvp", "row", mulInto(cache.mvpC, cache.mvpA, cache.hintModel))
      g.draw(hm)
      self.stats.hintDrawn = (self.stats.hintDrawn or 0) + 1
    end
  end
  g.setShader()
  self.stats.commandDrawn = (self.stats.commandDrawn or 0) + 1
  if self.tabletUi and info.battleDialogue then self.stats.dialogueDrawn = (self.stats.dialogueDrawn or 0) + 1 end
  return 1
end

function BattlePass:drawOverlay(P, eyeLocal)
  local ok, n = pcall(drawOverlayBody, self, P, eyeLocal)
  if not ok then
    restoreEyeState()
    self:fail("card", n)
    return 0
  end
  return n
end

-- ------------------------------------------------------------ diagnostics
function BattlePass:stageSummary()
  local st = self.stage
  if not st then return nil end
  local s = st.seat or {}
  return {
    shape = st.shape, dir = st.dir, gap = st.gap, pass = st.pass, walk = st.walk,
    relocated = st.relocated == true, synthetic = st.synthetic == true,
    sightBlocked = st.sightBlocked == true,
    own = { cellX = st.own.cellX, cellZ = st.own.cellZ, ground = st.own.ground },
    foe = { cellX = st.foe.cellX, cellZ = st.foe.cellZ, ground = st.foe.ground },
    focus = { x = st.focus.x, y = st.focus.y, z = st.focus.z },
    seat = { name = s.name, x = s.x, y = s.y, z = s.z, yaw = s.yaw, pitch = s.pitch, dist = s.dist },
    platform = st.platform and { x = st.platform.x, z = st.platform.z, y = st.platform.y,
      radius = st.platform.radius } or nil,
  }
end

function BattlePass:status()
  local cards = {}
  for i, c in ipairs(self.frameCards or {}) do
    cards[i] = { kind = c.kind, id = c.id, x = c.x, z = c.z, base = c.base, w = c.w, h = c.h,
      drawn = c.mesh ~= nil, alpha = c.alpha }
  end
  local st = {}
  for k, v in pairs(self.stats or {}) do st[k] = v end
  return {
    state = self.state, want = self.want, frameNo = self.frameNo,
    battles = self.battles, staged = self.staged,
    synthetics = self.synthetics, veils = self.veils, failures = self.failures,
    errorsInRow = self.errorsInRow, lastError = self.lastError,
    pinned = self.pinned, pendingPin = self.pendingPin,
    debugView = self.debugView, forceNoArena = self.forceNoArena, forceError = self.forceError,
    cutaway = { enabled = BattlePass.CUTAWAY, broken = self.cut.broken, count = self.cut.count },
    throw = self.throw:status(),
    occluders = { count = self.occluders and #self.occluders or 0, source = self.occluderSource,
      cut = self.cutOccluders and #self.cutOccluders or 0,
      cutList = (function()
        local out = {}
        for i, o in ipairs(self.cutOccluders or {}) do
          local x0, y0, z0, x1, y1, z1 = BattleOccluders.aabb(o)
          out[i] = { kind = o.kind, source = o.source, x0 = x0, y0 = y0, z0 = z0, x1 = x1, y1 = y1, z1 = z1 }
        end
        return out
      end)() },
    stage = self:stageSummary(), cards = cards, stats = st,
    playerAtStart = self.playerAtStart,
    move = self.move and (function()
      local s = self.move:status()
      s.enabled = self.moveEnabled == true
      s.stick = self:walkOwnsStick()
      return s
    end)() or nil,
    camera = self.camera and { seat = self.camera.seat ~= nil, yaw = self.camera.yaw,
      mode = self.camera.mode,
      seatPos = self.camera.seat and { x = self.camera.seat.x, y = self.camera.seat.y,
        z = self.camera.seat.z } or nil } or nil,
  }
end

-- Test switches (desktop driver / unit tests only).
function BattlePass:picPxPerCell() return BattleCards.PIC_PX_PER_CELL end

function BattlePass:setForceNoArena(on) self.forceNoArena = on and true or false end
-- "once": the next staged frame throws once (recovers on the synthetic stage);
-- "always": every frame throws (ends veiled); nil: off.
function BattlePass:setForceError(kind)
  self.forceError = (kind == "once" or kind == "always") and kind or nil
end

function BattlePass:setDebugView(kind)
  self.debugView = (kind == "34") and "34" or nil
  if self.stage and STAGED[self.state] then self.pendingPin = true end
end

function BattlePass:release()
  pcall(self.releaseSeat, self)
  pcall(self.cut.release, self.cut)
  self.state, self.stage, self.frameCards = "idle", nil, nil
  for i, m in pairs(self.meshes) do
    if m.m and m.m.release then pcall(m.m.release, m.m) end
    self.meshes[i] = nil
  end
  if self.commandMeshV and self.commandMeshV.mesh and self.commandMeshV.mesh.release then
    pcall(self.commandMeshV.mesh.release, self.commandMeshV.mesh)
  end
  self.commandMeshV = nil
  if self.blank and self.blank.release then pcall(self.blank.release, self.blank) end
  self.blank = nil
  pcall(self.cards.release, self.cards)
end

return BattlePass
