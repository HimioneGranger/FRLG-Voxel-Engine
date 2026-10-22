-- FRLG_VOXEL: free (non-grid) walking for the 3D field (Lab 8, P0-2).
--
-- FireRed's engine walks a grid: 16 logic ticks per cell, four directions.
-- In a headset that reads as riding a rail (Lab 7 headset session: "walking
-- on a grid feels bad in VR"). While VOXEL MOVEMENT = FREE (the default,
-- user answer 2026-09-29) this module replaces the WALK and nothing else:
-- the left stick walks the trainer continuously, in any direction relative
-- to where the head looks, and the body slides along whatever it grazes.
--
-- THE GRID IS STILL THE GAME. Every fact FireRed cares about is a fact about
-- cells (what blocks, what warps, what rustles, what triggers), so the
-- engine's own logical cell (Player.cellX/cellY) stays authoritative and is
-- only ever moved by the engine's own arrival code:
--
--   collision      Collision.canEnter is asked once per cell EDGE the body's
--                  leading side crosses, with the real from-cell and
--                  direction, so one-way ledges and elevation edges hold.
--                  Door entrances and escalators, which the grid enters only
--                  through Player.tryMove, refuse the free body.
--   arrival        Player.crossCell (engine seam E2) runs the grid step's
--                  own landing code -- save position, step events, warps,
--                  coord events (Oak's stop), trainer sight, encounters,
--                  grass -- exactly once per new cell. The logical cell
--                  changes one axis at a time, only once the body's centre
--                  is HYST px past the edge, so hovering on a border never
--                  repeats a step and an 8x8 diagonal is 16 steps, the same
--                  count a grid walk would take. When crossCell refuses the
--                  cell (a stair, ledge, door, exit mat, escalator, arrow
--                  warp, sign or blocked cell: whatever tryMove handles
--                  another way) the body is held at the edge and the push
--                  below hands that direction to tryMove.
--   the pushes     a firm push (stick past PUSH_MIN) held for PUSH_TICKS
--                  against the cell in front hands the direction to
--                  Player.tryMove: doors, exit mats, ledges, signs,
--                  boulders, stairs and map connections all run through the
--                  engine's own handlers.
--   phase 1 grid   surf, bike (and Cycling Road), forced/ice/current tiles,
--                  waterfall, spinning and boulder pushing go back to the
--                  grid walk (the original Player.pollWalk).
--   locks          Player.update only calls pollWalk when the field is free
--                  (no script, lock, warp, menu, sight check), so every one
--                  of those gates still applies. While something else holds
--                  the player, preTick glides the body back to its cell
--                  centre, 1 px per tick (never while a menu is open).
--
-- Engine seam (E2, engine commit b7269f55; Gen3-only player.lua/objects.lua):
--   Player.pollWalk(game, input)       the old tail of Player.update, called
--                                      through the module table (wrapped here)
--   Player.crossCell(game, tx, ty, dir) -> true | false, reason: step setup
--                                      without animation, then Player.arrive;
--                                      px/py snap to the cell (restored here)
--   Player.arrive(game)                the tail of the grid finishStep
--   Player.walkHeld()                  why the field holds the avatar, or nil
--   Player.footprint                   list of { x, y } cells the body
--                                      overlaps, honoured by
--                                      Objects.playerBlocks (NPCs keep out)
-- Only the adapter (Seam below) touches those names. Without pollWalk and
-- crossCell this module stays off and the grid walk runs unchanged.
--
-- Locomotion options (teams/locomotion, Lab 7):
--   WALK SPEED    FreeMove.setWalkSpeed(percent) scales the WALK speed only
--                 (running, gliding and every grid hand-off are untouched).
--                 The logical cell, crossCell arrival, step counting and
--                 encounters are per cell, so a slower walk changes how long
--                 a step takes, never what a step does.
--   ROOM-SCALE    FreeMove.roomFrame / roomMove: the head's horizontal offset
--                 from the playspace centre walks the trainer through the very
--                 same slide + crossCell as the stick, then the playspace is
--                 re-centred under the head (see the ROOM-SCALE block below).
--
-- Sandbox: no package, no debug; engine modules only through require.
local V = ...
local _ = V

local FreeMove = {}

FreeMove.RADIUS = 5.5        -- body circle, px (half a cell is 8)
FreeMove.WALK = 1.0          -- px per 60 Hz tick: the grid walk's own speed
FreeMove.RUN = 2.0           -- running shoes (8 ticks per cell on the grid)
FreeMove.HYST = 2            -- px past a cell edge before the logical cell moves
FreeMove.PUSH_TICKS = 6      -- firm push held this long hands off to tryMove
FreeMove.PUSH_MIN = 0.6      -- stick magnitude that counts as a firm push
FreeMove.NUDGE = 0.75        -- corner assist, fraction of the walk speed
FreeMove.GLIDE = 1.0         -- px per tick back to the cell centre while held
FreeMove.DEAD = 0.2          -- analog stick dead zone (InputMap)
FreeMove.INTENT_STALE = 30   -- ticks before a headset intent counts as gone
-- walk speed option (percent of WALK); running is never scaled
FreeMove.WALK_PCT_MIN, FreeMove.WALK_PCT_MAX, FreeMove.WALK_PCT_DEFAULT = 50, 100, 75
-- room-scale walking
FreeMove.ROOM_LEASH = 4      -- px (0.25 cell, 0.4 m): most head offset the body may owe at once
FreeMove.ROOM_JUMP = 0.75    -- metres in ONE frame: more is a tracking jump / recenter, not a step
FreeMove.ROOM_STEP = 6       -- px per tick the walk will take from the owed offset
FreeMove.ROOM_GAP = 12       -- ticks without a headset frame before the offset is re-centred
FreeMove.ROOM_WALK_MIN = 0.1 -- px per tick of room motion that animates the walk cycle
FreeMove.ROOM_DIM_GAIN = 3   -- dim level per metre of head pushed into a wall
FreeMove.ROOM_DIM_MAX = 0.6  -- strongest dim (alpha of black)
FreeMove.ROOM_DIM_TAU = 0.35 -- seconds for the dim to fade out

local CELL = 16
local EPS = 0.01
local DELTA = { up = { 0, -1 }, down = { 0, 1 }, left = { -1, 0 }, right = { 1, 0 } }
local floor, abs, sqrt = math.floor, math.abs, math.sqrt

-- ------------------------------------------------------------ engine access
local cache = {}
local function engine(name)
  local m = cache[name]
  if m then return m end
  local ok, mod = pcall(require, name)
  if ok and type(mod) == "table" then cache[name] = mod; return mod end
  return nil
end
FreeMove._resetCache = function() cache = {} end -- test seam

-- ------------------------------------------------------------ state
local S
local function freshState()
  return {
    installed = false, enabled = true, android = false, live = nil,
    log = function(s) print("[FRLG_VOXEL] " .. tostring(s)) end,
    why = "not installed", broken = nil,
    tick = 0, polled = -1,
    intent = { x = 0, z = 0, m = 0, look = nil, faceLook = false, panel = true, tick = -100000 },
    pos = nil, lastPx = nil, lastPy = nil, map = nil, cx = nil, cy = nil,
    push = { dir = nil, ticks = 0, latched = false },
    anim = { dist = 0, walking = false, running = false },
    facingBias = nil,
    walkScale = FreeMove.WALK_PCT_DEFAULT / 100,
    room = { enabled = true, lastHx = nil, lastHz = nil, frameTick = nil,
             wx = 0, wz = 0, lagX = 0, lagZ = 0, dim = 0, out = {},
             frames = 0, steps = 0, clipped = 0, jumps = 0, leashed = 0, refusals = 0 },
    stats = { ticks = 0, cells = 0, handoffs = 0, slides = 0, glides = 0, drops = 0,
              grid = 0, nudges = 0, refusals = 0, lastGrid = nil, lastHandoff = nil,
              lastRefusal = nil, sessionFixes = 0 },
  }
end
S = freshState()

-- The footprint table handed to the engine: an array of { x, y } cells (also
-- readable as c.x / c.y), the bounds x0..x1 / y0..y1, and callable as
-- footprint(tx, ty) -> bool, so whichever shape E2 reads works.
local FP_MT = { __call = function(self, tx, ty)
  for i = 1, self.n do
    local c = self[i]
    if c[1] == tx and c[2] == ty then return true end
  end
  return false
end }
local fpCells = { { 0, 0, x = 0, y = 0 }, { 0, 0, x = 0, y = 0 },
                  { 0, 0, x = 0, y = 0 }, { 0, 0, x = 0, y = 0 } }
local footprint = setmetatable({ n = 0 }, FP_MT)

-- ------------------------------------------------------------ the seam (E2)
local Seam = {}
FreeMove.Seam = Seam

function Seam.player() return engine("src.core.game3.player") end

function Seam.hasE2(P)
  return type(P) == "table" and type(P.pollWalk) == "function"
    and type(P.crossCell) == "function"
end

-- -> entered (bool), refusal reason. E2 returns true, or false and a reason.
function Seam.crossCell(P, game, tx, ty, dir)
  local ok, why = P.crossCell(game, tx, ty, dir)
  if ok == false then return false, why or "refused" end
  return true
end

function Seam.setFootprint(P, fp) P.footprint = fp end

function Seam.mapToken()
  local Coll = engine("src.core.game3.collision")
  local id = Coll and Coll._mapId
  if id == nil then
    local Map = engine("src.core.game3.map")
    id = Map and Map.current
  end
  return id
end

local function call(m, fn, ...)
  local f = m and m[fn]
  if type(f) ~= "function" then return nil end
  local ok, v = pcall(f, ...)
  return ok and v or nil
end

-- The same gates Player.update checks before pollWalk, plus a battle: used
-- after crossCell to see whether the engine took over. E2's own
-- Player.walkHeld() when the engine has it, else the same list here.
function Seam.busy(P)
  if type(P.walkHeld) == "function" then
    local ok, held = pcall(P.walkHeld)
    if ok then return held ~= nil end
  end
  if P.moving or P.boulderPush then return true end
  if (tonumber(P.fieldMoveAnim) or 0) > 0 then return true end
  local Field = engine("src.core.game3.field")
  if Field and Field.locked then return true end
  local Fade = engine("src.ui.game3.fade")
  if Fade and Fade.lockInput then return true end
  if call(engine("src.core.game3.warp"), "isBusy") then return true end
  if call(engine("src.core.game3.runtime"), "uiBusy") then return true end
  if call(engine("src.core.game3.step_events"), "busy") then return true end
  local Space = engine("src.core.game3.scripting.space")
  local vm = Space and Space.vm
  if vm and vm.isRunning then
    local ok, running = pcall(vm.isRunning, vm)
    if ok and running then return true end
  end
  if call(engine("src.core.game3.battle"), "isActive") then return true end
  return false
end

-- Where the display-rate blend stands inside the current logic tick (0..1),
-- the same number data/Actors samples once per frame (alpha = accum / STEP).
function Seam.alpha()
  local FS = engine("src.core.FixedStep")
  if not FS then return 1 end
  local step = tonumber(FS.STEP) or (1 / 60)
  local a = (tonumber(FS.accum) or step) / step
  if a ~= a then return 1 end
  return math.max(0, math.min(1, a))
end

function Seam.menuOpen()
  return call(engine("src.core.game3.runtime"), "uiBusy") and true or false
end

-- The engine's 2D field view writes the session position from the avatar's
-- pixels on every drawn frame (src/core/game3/field_view.lua, FieldView.draw:
-- floor(px / 16), floor(py / 16)). For a grid avatar standing on its cell
-- that is the cell; a free body in the north or west half of its cell reads
-- as the NEIGHBOURING cell, and a save writes the session position
-- (save_schema_firered toSaveTable), so a save could put the player on a
-- ledge, a wall or a warp. Put back the logical cell, the value the engine's
-- own Player.arrive wrote. -> true when it had drifted.
function Seam.syncSession(P)
  local Runtime = engine("src.core.game3.runtime")
  local getS = Runtime and Runtime.getSession
  if type(getS) ~= "function" then return false end
  local ok, s = pcall(getS)
  if not (ok and type(s) == "table") then return false end
  if s.x == P.cellX and s.y == P.cellY then return false end
  s.x, s.y = P.cellX, P.cellY
  return true
end

-- Phase 1: states the free walk hands back to the grid. nil = free is fine.
local SPECIAL_BEH = { "isIce", "isThinIce", "isCrackedIce", "isCyclingRoadPullDown", "isWaterfall" }
function Seam.special(P)
  if P.surfing or P.surfHopping or P.dismounting then return "surf" end
  if P.biking then return "bike" end
  if P.spinning then return "spin" end
  if P.fishing then return "fishing" end
  if P.walkInPlace or P.boulderPush then return "boulder" end
  if P.jumping then return "jump" end
  local Coll = engine("src.core.game3.collision")
  if Coll and type(Coll.behavior) == "function" then
    local ok, beh = pcall(Coll.behavior, P.cellX, P.cellY)
    if ok and beh ~= nil then
      local FM = engine("src.core.game3.forced_movement")
      if FM and type(FM.isForcedMovementTile) == "function" then
        local okF, forced = pcall(FM.isForcedMovementTile, beh)
        if okF and forced then return "forced tile" end
      end
      for _, fn in ipairs(SPECIAL_BEH) do
        if type(Coll[fn]) == "function" then
          local okB, hit = pcall(Coll[fn], beh)
          if okB and hit then return fn end
        end
      end
    end
  end
  local Field = engine("src.core.game3.field")
  if Field then
    if Field._waterfall then return "waterfall" end
    if call(Field, "forcedMovementPending") then return "forced movement" end
  end
  return nil
end

-- May the body's leading side cross from cell (fx, fy) into (tx, ty) moving
-- `dir`? nil = yes, else the refusal ("bounds"/"tile"/"elevation"/"entity"/
-- "water"/"door"/"escalator").
function Seam.blocked(game, P, fx, fy, tx, ty, dir)
  local Coll = engine("src.core.game3.collision")
  if not (Coll and type(Coll.canEnter) == "function") then return "tile" end
  local ok, can, why = pcall(Coll.canEnter, game, tx, ty, {
    fromX = fx, fromY = fy, dir = dir, surfing = false,
    elevation = P.currentElevation,
  })
  if not ok then return "tile" end
  if not can then return why or "tile" end
  -- cells the grid only enters through Player.tryMove (collision.lua:1248-1251)
  if type(Coll.isDoorWarp) == "function" then
    local okD, door = pcall(Coll.isDoorWarp, game, tx, ty)
    if okD and door then return "door" end
  end
  if type(Coll.isEscalatorWarp) == "function" then
    local okE, esc = pcall(Coll.isEscalatorWarp, game, tx, ty, dir)
    if okE and esc then return "escalator" end
  end
  return nil
end

-- ------------------------------------------------------------ helpers
local function setFootprint(P)
  local pos = S.pos
  if not pos then
    if footprint.n ~= 0 or P.footprint ~= nil then
      footprint.n = 0
      for i = 1, 4 do footprint[i] = nil end
      Seam.setFootprint(P, nil)
    end
    return
  end
  local r = FreeMove.RADIUS
  local x0, x1 = floor((pos.x - r) / CELL), floor((pos.x + r - EPS) / CELL)
  local y0, y1 = floor((pos.z - r) / CELL), floor((pos.z + r - EPS) / CELL)
  local n = 0
  for y = y0, y1 do
    for x = x0, x1 do
      n = n + 1
      local c = fpCells[n]
      c[1], c[2], c.x, c.y = x, y, x, y
      footprint[n] = c
    end
  end
  for i = n + 1, 4 do footprint[i] = nil end
  footprint.n, footprint.x0, footprint.y0, footprint.x1, footprint.y1 = n, x0, y0, x1, y1
  Seam.setFootprint(P, footprint)
end

local function writePos(P)
  P.px, P.py = S.pos.x - CELL / 2, S.pos.z - CELL / 2
  S.lastPx, S.lastPy = P.px, P.py
end

-- Player.running while a free body runs. E2's crossCell lands like a grid
-- step and clears it (player.lua landOnTarget), and the engine reads it
-- between steps: objects.lua trainerCloseToRunningPlayer turns some trainers
-- toward a running player. So the free walk reports it itself and clears
-- only what it set, never a grid step's own flag (P.moving).
local function setRunning(P, on)
  if on then
    P.running = true
    S.ran = true
  elseif S.ran then
    S.ran = false
    if not P.moving then P.running = false end
  end
end

local function drop(P, why)
  if S.pos then S.stats.drops = S.stats.drops + 1 end
  if P then setRunning(P, false) end
  S.pos = nil
  S.push.dir, S.push.ticks, S.push.latched = nil, 0, false
  S.anim.walking, S.anim.running = false, false
  S.dropWhy = why
  if P then setFootprint(P) end
end
FreeMove.drop = function(why) drop(Seam.player(), why) end

local function adopt(P)
  S.pos = { x = (P.px or P.cellX * CELL) + CELL / 2, z = (P.py or P.cellY * CELL) + CELL / 2 }
  S.lastPx, S.lastPy = P.px, P.py
  S.cx, S.cy = P.cellX, P.cellY
  S.map = Seam.mapToken()
  S.push.dir, S.push.ticks, S.push.latched = nil, 0, false
end

-- Back to the grid: stand on the logical cell (the render side eases the
-- jump) and forget the free body.
local function toGrid(P, why)
  if S.pos and not P.moving and P.px == S.lastPx and P.py == S.lastPy then
    P.px, P.py = P.cellX * CELL, P.cellY * CELL
  end
  if S.pos then drop(P, why) end
  S.stats.grid = S.stats.grid + 1
  S.stats.lastGrid = why
end

-- Quantise a world vector (x east, z south) to a grid direction, keeping the
-- previous one while it is within ~6 degrees of the tie.
local SCORE = {
  right = function(x, _) return x end, left = function(x, _) return -x end,
  down = function(_, z) return z end, up = function(_, z) return -z end,
}
local ORDER = { "up", "right", "down", "left" }
local function quantise(x, z, previous)
  if abs(x) < 1e-6 and abs(z) < 1e-6 then return previous end
  local best, score = nil, -math.huge
  for _, d in ipairs(ORDER) do
    local s = SCORE[d](x, z)
    if s > score then best, score = d, s end
  end
  if previous and SCORE[previous] then
    local m = sqrt(x * x + z * z)
    local old = SCORE[previous](x, z)
    if old > 0 and old >= score - 0.1 * m then best = previous end
  end
  return best
end
FreeMove.quantise = quantise

-- Look yaw (0 = north, CCW positive, Camera's convention) -> world unit vector.
local function yawVector(yaw)
  return -math.sin(yaw), -math.cos(yaw)
end
FreeMove.yawVector = yawVector

-- ------------------------------------------------------------ public API
-- opts = { mod?, log, android = bool, live = fn() -> bool (the 3D view is up),
--          enabled = bool, actors = data/Actors (walk cycle hand-off),
--          player = the engine Player table (tests; default require) }
function FreeMove.install(opts)
  opts = opts or {}
  S.log = opts.log or S.log
  S.android = opts.android == true
  S.live = opts.live
  if opts.enabled ~= nil then S.enabled = opts.enabled ~= false end
  if opts.walkSpeed ~= nil then FreeMove.setWalkSpeed(opts.walkSpeed) end
  if opts.roomScale ~= nil then FreeMove.setRoomEnabled(opts.roomScale) end
  if opts.actors then opts.actors.playerAnim = FreeMove.anim end
  local P = opts.player or Seam.player()
  if not P then
    S.why = "engine player module unavailable"
    return false, S.why
  end
  -- The engine's Player module outlives a mod session (mods reload per game
  -- session, the engine module does not): wrap pollWalk once per process and
  -- route it through P._frlgFreeMove, which each install points at itself
  -- and uninstall (session teardown) clears.
  if not P._frlgFreeMoveOrig then
    if not Seam.hasE2(P) then
      S.why = "engine has no Player.pollWalk/crossCell seam (E2); grid walking kept"
      S.log("free walking unavailable: " .. S.why)
      return false, S.why
    end
    local orig = P.pollWalk
    P._frlgFreeMoveOrig = orig
    P.pollWalk = function(game, input)
      local fm = P._frlgFreeMove
      if fm and fm.pollWalk then return fm.pollWalk(orig, game, input) end
      return orig(game, input)
    end
  end
  P._frlgFreeMove = FreeMove
  S.installed, S.why = true, nil
  return true
end

-- Session teardown: stand the player on its cell, forget the footprint and
-- hand pollWalk back to the grid until the next install.
function FreeMove.uninstall(reason)
  local P = Seam.player()
  if P then
    if S.pos then toGrid(P, reason or "uninstall") end
    if P._frlgFreeMove == FreeMove then P._frlgFreeMove = nil end
  end
  local R = S.room -- nothing is owed to a head across a session teardown
  R.lastHx, R.lastHz, R.frameTick = nil, nil, nil
  R.wx, R.wz, R.lagX, R.lagZ = 0, 0, 0, 0
  S.installed, S.why = false, "uninstalled" .. (reason and (" (" .. tostring(reason) .. ")") or "")
  return true
end

function FreeMove.setEnabled(on) S.enabled = on ~= false end
-- VOXEL WALK SPEED: percent of the grid walk's own speed (WALK px per tick).
-- Applies to the stick walk only; RUN is unchanged. Returns the clamped value.
function FreeMove.setWalkSpeed(pct)
  pct = tonumber(pct)
  if pct == nil or pct ~= pct then pct = FreeMove.WALK_PCT_DEFAULT end
  pct = math.max(FreeMove.WALK_PCT_MIN, math.min(FreeMove.WALK_PCT_MAX, pct))
  S.walkScale = pct / 100
  return pct
end
function FreeMove.walkSpeed() return S.walkScale * 100 end
-- VOXEL ROOM-SCALE WALK on/off. Off clears whatever offset is owed.
function FreeMove.setRoomEnabled(on)
  S.room.enabled = on ~= false
  if not S.room.enabled then
    local R = S.room
    R.lastHx, R.lastHz, R.frameTick = nil, nil, nil
    R.wx, R.wz, R.lagX, R.lagZ, R.dim = 0, 0, 0, 0, 0
  end
end
function FreeMove.roomEnabled() return S.room.enabled end
function FreeMove.enabled() return S.enabled end
-- The FREE option is in force and the engine seam is there.
function FreeMove.active() return S.installed and S.enabled and not S.broken end
-- A free body currently stands between cells (for diagnostics).
function FreeMove.free() return S.pos ~= nil end

-- Headset intent, once per rendered frame from InputMap:apply.
-- (x, z) world unit vector (x east, z south), m = 0..1 (0 = stick at rest);
-- o = { look = world look yaw or nil, faceLook = bool, panel = bool }
-- Independent source: headset InputMap cannot overwrite an active keyboard intent.
function FreeMove.setMouseIntent(x, z, m, active)
  if not active then S.mouseIntent=nil; return end
  local it=S.mouseIntent or {}
  it.x,it.z,it.m,it.tick=x,z,m,S.tick
  S.mouseIntent=it
end
function FreeMove.setIntent(x, z, m, o)
  local it = S.intent
  it.x, it.z, it.m = tonumber(x) or 0, tonumber(z) or 0, tonumber(m) or 0
  it.look = o and o.look or nil
  it.faceLook = o and o.faceLook == true or false
  it.panel = o and o.panel == true or false
  it.tick = S.tick
end

-- Walk cycle for the player's card: walkPhase (0/1), stepFlip, running pose
-- (0/1 or nil). Returns nil while the grid owns the walk.
function FreeMove.anim()
  if not S.pos then return nil end
  local a = S.anim
  if not a.walking then return 0, (floor(a.dist / CELL) % 2) == 1, nil end
  local p = a.dist % CELL
  local phase = (p >= 4 and p < 12) and 1 or 0
  return phase, (floor(a.dist / CELL) % 2) == 1, a.running and phase or nil
end

function FreeMove.status()
  local st = S.stats
  return {
    installed = S.installed, enabled = S.enabled, active = FreeMove.active(), why = S.why,
    broken = S.broken, free = S.pos ~= nil, x = S.pos and S.pos.x, z = S.pos and S.pos.z,
    cellX = S.cx, cellY = S.cy, ticks = st.ticks, cells = st.cells, handoffs = st.handoffs,
    slides = st.slides, glides = st.glides, drops = st.drops, grid = st.grid,
    nudges = st.nudges, lastGrid = st.lastGrid, lastHandoff = st.lastHandoff,
    refusals = st.refusals, lastRefusal = st.lastRefusal, dropWhy = S.dropWhy,
    sessionFixes = st.sessionFixes,
    walkSpeed = S.walkScale * 100,
    room = { enabled = S.room.enabled, frames = S.room.frames, steps = S.room.steps,
             clipped = S.room.clipped, jumps = S.room.jumps, leashed = S.room.leashed,
             refusals = S.room.refusals, owedX = S.room.wx, owedZ = S.room.wz,
             dim = S.room.dim },
  }
end

-- A save is about to be written (main.lua's save.write hook): make sure the
-- session holds the logical cell, whatever the last drawn frame wrote. Only
-- while a free body stands between cells; a no-op on the grid.
function FreeMove.syncSession()
  if not S.pos then return false end
  local P = Seam.player()
  if not P or P.moving or P.px ~= S.lastPx or P.py ~= S.lastPy then return false end
  local fixed = Seam.syncSession(P)
  if fixed then S.stats.sessionFixes = S.stats.sessionFixes + 1 end
  return fixed
end

-- test seam: fresh state (keeps nothing wrapped)
function FreeMove._reset() S = freshState() end

-- ------------------------------------------------------------ the tick
-- Intent for this tick: (x, z) unit vector, magnitude 0..1, source.
local function intentOf(input)
  local mi = S.mouseIntent
  if mi and mi.m > 0 and S.tick - mi.tick <= FreeMove.INTENT_STALE then return mi.x, mi.z, mi.m end
  if S.android then
    local it = S.intent
    return it.x, it.z, it.m
  end
  -- desktop: the d-pad (keys) north-up, 8 ways
  if not (input and input.isDown) then return 0, 0, 0 end
  local x = (input:isDown("right") and 1 or 0) - (input:isDown("left") and 1 or 0)
  local z = (input:isDown("down") and 1 or 0) - (input:isDown("up") and 1 or 0)
  local m = sqrt(x * x + z * z)
  if m == 0 then return 0, 0, 0 end
  return x / m, z / m, 1
end

-- Why free walking must not run this tick (nil = it may).
local function gate(P, input)
  if S.broken then return "broken" end
  if not S.enabled then return "grid option" end
  if S.live then
    local ok, live = pcall(S.live)
    if ok and not live then return "3D view off" end
  end
  if S.android and not (S.mouseIntent and S.tick - S.mouseIntent.tick <= FreeMove.INTENT_STALE) then
    local it = S.intent
    if S.tick - it.tick > FreeMove.INTENT_STALE then return "no headset intent" end
    if it.panel then return "panel" end
  end
  if input == nil then return "forced movement pending" end
  return Seam.special(P)
end

-- Move along one axis ("x" or "z") by d px, clamped at the first refusing
-- cell edge. Returns why (nil = free), plus whether the logical front cell
-- refused and whether some overlapped row stayed open (corner assist).
local function slide(game, P, axis, d, at)
  if d == 0 then return nil end
  local r, pos = FreeMove.RADIUS, at or S.pos
  local a = axis == "x" and pos.x or pos.z
  local b = axis == "x" and pos.z or pos.x
  local na = a + d
  local oldEdge, newEdge
  if d > 0 then
    oldEdge, newEdge = floor((a + r - EPS) / CELL), floor((na + r - EPS) / CELL)
  else
    oldEdge, newEdge = floor((a - r) / CELL), floor((na - r) / CELL)
  end
  local why, frontBlocked, openRow = nil, false, nil
  if newEdge ~= oldEdge then
    -- one new column/row per tick at most (speed < 16 px)
    newEdge = oldEdge + (d > 0 and 1 or -1)
    local dir
    if axis == "x" then dir = d > 0 and "right" or "left" else dir = d > 0 and "down" or "up" end
    local logicalRow = axis == "x" and S.cy or S.cx
    local frontEdge = (axis == "x" and S.cx or S.cy) + (d > 0 and 1 or -1)
    local b0, b1 = floor((b - r) / CELL), floor((b + r - EPS) / CELL)
    for bc = b0, b1 do
      local fx, fy, tx, ty
      if axis == "x" then fx, fy, tx, ty = oldEdge, bc, newEdge, bc
      else fx, fy, tx, ty = bc, oldEdge, bc, newEdge end
      local w
      if not (tx == S.cx and ty == S.cy) then
        w = Seam.blocked(game, P, fx, fy, tx, ty, dir)
      end
      if w then
        why = why or w
        if bc == logicalRow and newEdge == frontEdge then frontBlocked = true end
      else
        openRow = openRow or bc
      end
    end
    if why then
      if d > 0 then na = math.max(a, newEdge * CELL - r) else na = math.min(a, (newEdge + 1) * CELL + r) end
      if frontBlocked then openRow = nil end
    else
      openRow = nil
    end
  end
  if axis == "x" then pos.x = na else pos.z = na end
  return why, frontBlocked, openRow
end

-- The logical cell after the body moved along one axis (hysteresis HYST).
local function logicalStep(axis)
  local pos, h = S.pos, FreeMove.HYST
  if axis == "x" then
    local c = S.cx
    if pos.x >= (c + 1) * CELL + h then return c + 1, S.cy, "right" end
    if pos.x < c * CELL - h then return c - 1, S.cy, "left" end
  else
    local c = S.cy
    if pos.z >= (c + 1) * CELL + h then return S.cx, c + 1, "down" end
    if pos.z < c * CELL - h then return S.cx, c - 1, "up" end
  end
  return nil
end

-- Keep the body's centre inside the logical cell's hysteresis band on one
-- axis (the engine refused the next cell).
local function holdAtEdge(axis)
  local pos, h, c = S.pos, FreeMove.HYST, axis == "x" and S.cx or S.cy
  local v = axis == "x" and pos.x or pos.z
  local hi, lo = (c + 1) * CELL + h - EPS, c * CELL - h
  if v > hi then v = hi elseif v < lo then v = lo end
  if axis == "x" then pos.x = v else pos.z = v end
end

-- Hand one new cell to the engine's arrival code. Returns true when the
-- engine took the player over (a warp, a battle, a script, a forced step).
local function cross(game, P, axis, room)
  local tx, ty, dir = logicalStep(axis)
  if not tx then return false end
  writePos(P)
  P.facing = dir
  local ok, entered, refusal = pcall(Seam.crossCell, P, game, tx, ty, dir)
  if not ok then
    S.broken = "crossCell failed: " .. tostring(entered)
    S.log("free walking disabled for this session: " .. S.broken)
    drop(P, "crossCell error")
    return true
  end
  if not entered and room then
    -- walked into it physically: hold at the edge and nothing more. Doors,
    -- signs, ledges, stairs and the Emerald grid verbs only answer the stick's
    -- firm push, never a step taken in the room.
    S.room.refusals = S.room.refusals + 1
    holdAtEdge(axis)
    writePos(P)
    return false
  end
  if not entered then
    -- the engine keeps the player on its cell (a stair, ledge, door, exit
    -- mat, escalator, arrow warp, sign or refused cell): hold the body at
    -- the edge; the firm push hands the direction to tryMove
    S.refused = S.refused or {}
    S.refused.dir, S.refused.why, S.refused.tick = dir, refusal, S.tick
    S.stats.refusals = S.stats.refusals + 1
    S.stats.lastRefusal = dir .. ":" .. tostring(refusal)
    holdAtEdge(axis)
    writePos(P)
    return false
  end
  S.cx, S.cy = tx, ty
  S.stats.cells = S.stats.cells + 1
  if P.moving or Seam.mapToken() ~= S.map or P.cellX ~= tx or P.cellY ~= ty then
    drop(P, "engine took over after crossing")
    return true
  end
  -- still ours: keep the free position even if the seam snapped px to the cell
  writePos(P)
  if Seam.busy(P) then return true end
  return false
end

-- ------------------------------------------------------------ ROOM-SCALE
-- The standard VR way: the head's horizontal offset from the playspace origin
-- walks the body, then the origin is re-centred under the head, so the eye and
-- the collider stay together (a big playspace can no longer carry the head
-- through a wall, and walking around the room is free-roam play).
--
--   every headset frame   roomFrame(c): the head's move since the last frame
--                         (LOCAL metres) is rotated into the world with the
--                         camera yaw and added to what the body "owes"
--                         (S.room.wx/wz, px). The pivot of the camera rig is
--                         set to the head (Camera:setRoom), so the eye sits at
--                         the body plus the owed offset, and a snap or smooth
--                         turn swings the world around the HEAD.
--                         A dry run of the same slide the tick will make
--                         clips the owed offset at walls; the part that would
--                         go through is dropped (the playspace is pushed back,
--                         the view stays outside the wall) and feeds a dim.
--   every logic tick      roomMove(): the owed offset is walked with the very
--                         same slide + crossCell as the stick (edges, ledges,
--                         NPC footprints, warps, encounters, steps). Only a
--                         step taken in the room never hands off to tryMove
--                         (no door, sign, ledge jump or exit by bumping).
-- Gates (all in roomFrame's caller or the tick): GRID movement, third person,
-- 3/4 view, battles and the option all return nil = camera back to its old
-- rig; scripts, menus and warps never run pollWalk, so the offset just waits
-- (bounded by the leash) and is walked when the field is free again.
local roomScratch = { x = 0, z = 0 }

-- How far the body can really go this owed offset (px), from the current body
-- position: a dry run of the tick's own slides.
local function roomClip(game, P, wx, wz)
  local sx, sz = S.pos.x, S.pos.z
  roomScratch.x, roomScratch.z = sx, sz
  local whyX = slide(game, P, "x", wx, roomScratch)
  local whyZ = slide(game, P, "z", wz, roomScratch)
  return roomScratch.x - sx, roomScratch.z - sz, (whyX or whyZ) ~= nil
end

local function roomOff(R, dt)
  R.lastHx, R.lastHz, R.frameTick = nil, nil, nil
  R.wx, R.wz, R.lagX, R.lagZ = 0, 0, 0, 0
  if R.dim > 0 then
    R.dim = R.dim * math.exp(-math.min(tonumber(dt) or 0.1, 0.25) / FreeMove.ROOM_DIM_TAU)
    if R.dim < 0.01 then R.dim = 0 end
  end
end

-- Once per headset frame, BEFORE the camera updates (main.lua, renderEyes).
-- c = { hx, hz = head position in LOCAL metres (horizontal), yaw = the camera
--       yaw this frame (Camera.snapYaw: free walking never follows facing),
--       m = metres per cell, dt = frame seconds, game = the engine game,
--       allowed = first person, 3D field, no battle seat }
-- -> nil (room-scale is off: leave the rig alone) or the camera's room table
--    { px, pz (pivot, LOCAL m), wx, wz (eye offset from the body, cells) }.
function FreeMove.roomFrame(c)
  local R = S.room
  if not (type(c) == "table" and c.allowed and R.enabled and FreeMove.active()
      and tonumber(c.hx) and tonumber(c.hz)) then
    roomOff(R, c and c.dt)
    return nil
  end
  local hx, hz = c.hx, c.hz
  R.frames = R.frames + 1
  if R.lastHx == nil or R.frameTick == nil or S.tick - R.frameTick > FreeMove.ROOM_GAP then
    -- first frame, or the headset frames stopped for a while (panel, battle,
    -- pause): re-centre under the head, owe nothing
    R.lastHx, R.lastHz, R.wx, R.wz, R.lagX, R.lagZ = hx, hz, 0, 0, 0, 0
  end
  R.frameTick = S.tick
  local dxm, dzm = hx - R.lastHx, hz - R.lastHz
  R.lastHx, R.lastHz = hx, hz
  local m = tonumber(c.m) or 1.6
  if m <= 0 then m = 1.6 end
  local jump = FreeMove.ROOM_JUMP
  if dxm * dxm + dzm * dzm > jump * jump then
    R.jumps = R.jumps + 1 -- recenter / tracking loss: not a step
    dxm, dzm = 0, 0
  end
  -- LOCAL metres -> world px, the rotation Camera:eyeWorld uses (Mat4.rotY)
  local yaw = tonumber(c.yaw) or 0
  local sn, cs = math.sin(yaw), math.cos(yaw)
  local k = CELL / m
  local wx = R.wx + (cs * dxm + sn * dzm) * k
  local wz = R.wz + (-sn * dxm + cs * dzm) * k
  -- the leash: never owe more than ROOM_LEASH px (a script holds the field)
  local len = sqrt(wx * wx + wz * wz)
  local leash = FreeMove.ROOM_LEASH
  if len > leash then
    wx, wz = wx * leash / len, wz * leash / len
    R.leashed = R.leashed + 1
  end
  -- clip at walls with the tick's own slide; drop what would go through
  if S.pos and not S.broken and c.game then
    local P = Seam.player()
    if P and (wx ~= 0 or wz ~= 0) then
      local ok, ax, az = pcall(roomClip, c.game, P, wx, wz)
      if ok then
        local drop = sqrt((wx - ax) ^ 2 + (wz - az) ^ 2)
        if drop > 1e-6 then
          R.clipped = R.clipped + 1
          R.dim = math.min(FreeMove.ROOM_DIM_MAX,
            R.dim + drop / CELL * m * FreeMove.ROOM_DIM_GAIN)
        end
        wx, wz = ax, az
      end
    end
  end
  R.wx, R.wz = wx, wz
  if R.dim > 0 then
    R.dim = R.dim * math.exp(-math.min(tonumber(c.dt) or 0.014, 0.25) / FreeMove.ROOM_DIM_TAU)
    if R.dim < 0.01 then R.dim = 0 end
  end
  -- the eye = the blended body + what is owed + the part of the last tick's
  -- room step the 60 -> display blend has not shown yet
  local lag = 1 - Seam.alpha()
  local o = R.out
  o.px, o.pz = hx, hz
  o.wx, o.wz = (wx + R.lagX * lag) / CELL, (wz + R.lagZ * lag) / CELL
  return o
end

-- Black veil strength (0..1) for a head pushed into a wall; 0 when idle.
function FreeMove.roomDim() return S.room.dim end

-- The logic tick: walk the owed offset. -> engine took over (true), px moved.
local function roomMove(game, P)
  local R = S.room
  R.lagX, R.lagZ = 0, 0
  if not R.enabled or R.frameTick == nil or S.tick - R.frameTick > 3 then return false, 0 end
  local wx, wz = R.wx, R.wz
  if wx == 0 and wz == 0 then return false, 0 end
  R.wx, R.wz = 0, 0
  local lim = FreeMove.ROOM_STEP
  wx, wz = math.max(-lim, math.min(lim, wx)), math.max(-lim, math.min(lim, wz))
  local ox, oz = S.pos.x, S.pos.z
  slide(game, P, "x", wx)
  if cross(game, P, "x", true) then return true, 0 end
  slide(game, P, "z", wz)
  if cross(game, P, "z", true) then return true, 0 end
  local ax, az = S.pos.x - ox, S.pos.z - oz
  R.lagX, R.lagZ = ax, az
  R.steps = R.steps + 1
  writePos(P)
  setFootprint(P)
  return false, sqrt(ax * ax + az * az)
end

local function lookFacing(it, previous)
  if it.look == nil then return previous end
  local lx, lz = yawVector(it.look)
  return quantise(lx, lz, previous)
end

-- A pressed: face the cell the look points into, so talking to someone at
-- an angle works (Field.interact reads Player.facing after this tick's walk).
local function faceLookTarget(P, it)
  if it.look == nil then return end
  local lx, lz = yawVector(it.look)
  local pos = S.pos
  local px, pz = pos.x + lx * 14, pos.z + lz * 14
  local tx, ty = floor(px / CELL) - S.cx, floor(pz / CELL) - S.cy
  if tx ~= 0 and ty ~= 0 then
    -- diagonal: prefer the neighbour holding an object, else the larger lean
    local Objects = engine("src.core.game3.objects")
    local hx = Objects and call(Objects, "at", S.cx + tx, S.cy)
    local hz = Objects and call(Objects, "at", S.cx, S.cy + ty)
    if hx and not hz then ty = 0
    elseif hz and not hx then tx = 0
    elseif abs(lx) >= abs(lz) then ty = 0 else tx = 0 end
  end
  if tx == 0 and ty == 0 then
    P.facing = quantise(lx, lz, P.facing)
  elseif tx ~= 0 then
    P.facing = tx > 0 and "right" or "left"
  else
    P.facing = ty > 0 and "down" or "up"
  end
end

-- The pollWalk wrapper body (runs in the logic tick, field free).
function FreeMove.pollWalk(orig, game, input)
  local P = Seam.player()
  if not P then return orig(game, input) end
  local why = gate(P, input)
  if why then
    toGrid(P, why)
    return orig(game, input)
  end
  S.polled = S.tick
  S.stats.ticks = S.stats.ticks + 1
  if not S.pos or P.px ~= S.lastPx or P.py ~= S.lastPy or P.cellX ~= S.cx or P.cellY ~= S.cy
      or Seam.mapToken() ~= S.map then
    adopt(P)
  end
  local it = S.intent
  local wx, wz, m = intentOf(input)
  if input and input.wasPressed and S.android then
    local okA, pressed = pcall(input.wasPressed, input, "a")
    if okA and pressed then faceLookTarget(P, it) end
  end
  P.turnArmed = true
  local roomTook, roomMoved = roomMove(game, P)
  if roomTook then return end
  if m <= 0 then
    S.anim.walking, S.anim.running = roomMoved >= FreeMove.ROOM_WALK_MIN, false
    S.anim.dist = (S.anim.dist + roomMoved) % (CELL * 64)
    setRunning(P, false)
    S.push.dir, S.push.ticks, S.push.latched = nil, 0, false
    if S.android and it.faceLook then P.facing = lookFacing(it, P.facing) end
    writePos(P)
    setFootprint(P)
    return
  end
  local run = false
  if input and input.isDown then
    local okB, b = pcall(input.isDown, input, "b")
    if okB and b then
      local okD, dash = pcall(P.canDash)
      run = okD and dash == true
    end
  end
  local speed = (run and FreeMove.RUN or FreeMove.WALK * S.walkScale) * math.min(1, m)
  local dx, dz = wx * speed, wz * speed
  local ox, oz = S.pos.x, S.pos.z

  local whyX, frontX, openX = slide(game, P, "x", dx)
  if cross(game, P, "x") then return end
  local whyZ, frontZ, openZ = slide(game, P, "z", dz)
  if cross(game, P, "z") then return end

  -- corner assist: pushing square into a gap the body half-overlaps
  local domX = abs(wx) >= abs(wz)
  local nudgeAxis, openRow
  if domX and whyX and openX and abs(wx) >= 0.9 then nudgeAxis, openRow = "z", openX
  elseif not domX and whyZ and openZ and abs(wz) >= 0.9 then nudgeAxis, openRow = "x", openZ end
  if nudgeAxis then
    local target = openRow * CELL + CELL / 2
    local cur = nudgeAxis == "z" and S.pos.z or S.pos.x
    local step = math.min(FreeMove.NUDGE * speed, abs(target - cur))
    if step > 0 then
      slide(game, P, nudgeAxis, target > cur and step or -step)
      S.stats.nudges = S.stats.nudges + 1
      if cross(game, P, nudgeAxis) then return end
    end
  end

  local mx, mz = S.pos.x - ox, S.pos.z - oz
  local moved = sqrt(mx * mx + mz * mz) + roomMoved
  local an = S.anim
  an.walking = moved > 0.05
  an.running = run and an.walking
  setRunning(P, an.running)
  an.dist = (an.dist + moved) % (CELL * 64)
  if whyX or whyZ then S.stats.slides = S.stats.slides + 1 end
  P.facing = quantise(wx, wz, P.facing)
  writePos(P)
  setFootprint(P)

  -- the firm push: hand the direction to the engine's own blocked-step verbs
  local pdir, front
  if domX then pdir, front = (wx > 0 and "right" or "left"), frontX
  else pdir, front = (wz > 0 and "down" or "up"), frontZ end
  -- a cell crossCell refused this tick counts as the cell in front
  local rf = S.refused
  if rf and rf.tick == S.tick and rf.dir == pdir then front = true end
  local push = S.push
  -- a new direction, a released stick or a new cell re-arms the hand-off;
  -- holding the same push on the same cell never repeats it (a sign reads
  -- once, a wall is asked once)
  if m < FreeMove.PUSH_MIN or pdir ~= push.dir or S.cx ~= push.cx or S.cy ~= push.cy then
    push.dir, push.ticks, push.latched = pdir, 0, false
    push.cx, push.cy = S.cx, S.cy
    if m < FreeMove.PUSH_MIN then push.dir = nil end
  end
  if m >= FreeMove.PUSH_MIN and front then
    push.ticks = push.ticks + 1
    if push.ticks >= FreeMove.PUSH_TICKS and not push.latched then
      push.latched = true
      P.facing = pdir
      S.stats.handoffs = S.stats.handoffs + 1
      local okT, res = pcall(P.tryMove, pdir, game, run)
      S.stats.lastHandoff = pdir .. ":" .. tostring(okT and res or ("error " .. tostring(res)))
      if P.moving or P.px ~= S.lastPx or P.py ~= S.lastPy or Seam.mapToken() ~= S.map
          or P.cellX ~= S.cx or P.cellY ~= S.cy then
        drop(P, "handed to the grid: " .. tostring(res))
      end
    end
  elseif not front then
    push.ticks = 0
  end
end

-- The start of every logic tick (engine input.step hook).
function FreeMove.preTick()
  S.tick = S.tick + 1
  S.room.lagX, S.room.lagZ = 0, 0 -- a tick that takes no room step leaves nothing for the blend to show
  if not S.pos then return end
  local P = Seam.player()
  if not P then return end
  if P.moving or P.px ~= S.lastPx or P.py ~= S.lastPy or Seam.mapToken() ~= S.map
      or P.cellX ~= S.cx or P.cellY ~= S.cy then
    drop(P, "engine moved the player")
    return
  end
  -- before anything in this tick can read it (the start menu's save)
  if Seam.syncSession(P) then S.stats.sessionFixes = S.stats.sessionFixes + 1 end
  if S.polled >= S.tick - 1 then return end
  -- something holds the player (script, lock, warp, battle): settle on the
  -- cell centre, except under a menu
  if Seam.menuOpen() then return end
  local pos, g = S.pos, FreeMove.GLIDE
  local tx, tz = S.cx * CELL + CELL / 2, S.cy * CELL + CELL / 2
  if pos.x == tx and pos.z == tz then return end
  local function toward(v, t)
    if abs(t - v) <= g then return t end
    return v + (t > v and g or -g)
  end
  pos.x, pos.z = toward(pos.x, tx), toward(pos.z, tz)
  S.anim.walking = false
  S.stats.glides = S.stats.glides + 1
  writePos(P)
  setFootprint(P)
end

return FreeMove
