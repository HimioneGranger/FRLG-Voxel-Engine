-- VRITK_FRLG_HOST: stubs for the three Gen2-battle-shaped modules VRITK
-- pulls through lib.require but P2 has no FireRed equivalent for yet
-- (vritk-hook/DESIGN.md 2b). Checked against the actual call sites, not
-- assumed:
--   OverworldBattle.arena() / .battle() -- read by
--     VR_INTERACTIONS_BACKPACK_LAB/lib/QuestBattleWorld.lua:70-71. That
--     function's very next line is `if art.battle()~=battle or not arena
--     then self:reset();return nil end`, so a nil arena makes it bail out
--     before BattleScene.groundY is ever called -- groundY only needs to
--     exist, not do anything, for P2.
--   OverworldBattle.backPinned -- read (QuestBattleWorld.lua:89) and
--     WRITTEN (:91, :105 -- the code temporarily replaces it with a
--     function returning false, then restores the original). Must be a
--     plain, reassignable table field, not a local.
--   BattleScene.groundY(map, arena) -- QuestBattleWorld.lua:84. Never
--     reached while arena() is nil (see above); returns 0 defensively
--     anyway in case a future P3/P4 caller reaches it directly.
--   QuestPokedexBridge.scannerGaze -- QuestPokedexScan.lua:12, a default
--     gaze provider for the Pokedex scanner. Nothing in P2's backpack/
--     gloves path constructs a QuestPokedexScan on FireRed: gear-hook
--     DESIGN.md 2e.5 -- KantoGearSurfaceBridge's own openPokedex already
--     refuses FireRed's numeric species, independent of whether kanto_gear
--     itself is loaded (as of the 3.3.3 upgrade it is, on every
--     generation) -- so this is still never called; stubbed for load-time
--     safety only.
local V = ...
local _ = V

local Stubs = {}

function Stubs.overworldBattle()
  local battle = { backPinned = function() return false end }
  battle.arena = function() return nil end
  battle.battle = function() return nil end
  return battle
end

function Stubs.battleScene()
  return { groundY = function(_map, _arena) return 0 end }
end

-- Gen3 Pokedex scanner (2026-10-01): VRITK's QuestPokedexScan.gazeFor and
-- QuestWatchPokedex take their world ray from here. The old stub returned
-- nil, so the wrist and tablet scanners never started on Gen3. event =
-- { pose = {position, orientation (x,y,z,w)}, ray = {origin, direction} }
-- in rig-local metres; worldFromLocal = PxContext.worldFromLocalPx
-- (row-major, world px), the same frame FRLG_CATCH's scan targets use.
local function num(v, fallback)
  v = tonumber(v)
  if not v or v ~= v or v == math.huge or v == -math.huge then return fallback end
  return v
end
local function vec3(v)
  if type(v) ~= "table" then return nil end
  local x, y, z = num(v[1] or v.x), num(v[2] or v.y), num(v[3] or v.z)
  if not (x and y and z) then return nil end
  return { x, y, z }
end
local function quatRotate(q, v)
  local x, y, z, w = q[1], q[2], q[3], q[4]
  local tx = 2 * (y * v[3] - z * v[2])
  local ty = 2 * (z * v[1] - x * v[3])
  local tz = 2 * (x * v[2] - y * v[1])
  return { v[1] + w * tx + (y * tz - z * ty),
    v[2] + w * ty + (z * tx - x * tz),
    v[3] + w * tz + (x * ty - y * tx) }
end
local function apply(m, v, w)
  return { m[1] * v[1] + m[2] * v[2] + m[3] * v[3] + m[4] * w,
    m[5] * v[1] + m[6] * v[2] + m[7] * v[3] + m[8] * w,
    m[9] * v[1] + m[10] * v[2] + m[11] * v[3] + m[12] * w }
end

function Stubs.scannerGaze(event, worldFromLocal)
  local pose, ray = event and event.pose, event and event.ray
  if type(pose) ~= "table" or type(ray) ~= "table" or type(worldFromLocal) ~= "table" then
    return nil
  end
  for i = 1, 12 do if not num(worldFromLocal[i]) then return nil end end
  local p = vec3(pose.position or pose.pos)
  local qs = pose.orientation or pose.quat
  local q = type(qs) == "table" and { num(qs[1] or qs.x), num(qs[2] or qs.y),
    num(qs[3] or qs.z), num(qs[4] or qs.w) } or nil
  local o, d = vec3(ray.origin) or { 0, 0, 0 }, vec3(ray.direction)
  if not (p and q and q[1] and q[2] and q[3] and q[4] and d) then return nil end
  local lo = quatRotate(q, o)
  local origin = apply(worldFromLocal, { lo[1] + p[1], lo[2] + p[2], lo[3] + p[3] }, 1)
  local dir = apply(worldFromLocal, quatRotate(q, d), 0)
  local n = math.sqrt(dir[1] * dir[1] + dir[2] * dir[2] + dir[3] * dir[3])
  if not (n > 1e-6 and n < math.huge) then return nil end
  return { origin = origin, direction = { dir[1] / n, dir[2] / n, dir[3] / n },
    maxDistance = num(ray.maxDistance, 12) }
end

function Stubs.questPokedexBridge()
  return { scannerGaze = Stubs.scannerGaze }
end

return Stubs
