-- VRITK_FRLG_HOST compat (Gen3 only: FireRed/LeafGreen and Emerald): a forgiving aim test and a hold-to-confirm
-- for the party-ball RECALL gesture (hold your Pokemon's ball, point it at the Pokemon, pull the trigger).
--
-- belt-switch (2026-10-02, Lab 10 headset: "Recalling a Pokemon in the overworld is very touchy and too hard to
-- perform"). The shared VRITK test (PartyFollower.aim, unchanged for Gen1/Gen2) takes ONE ray and accepts the
-- target only when the ray passes within
--     radius = max(3, min(10, 0.4 * max(cardW, cardH)), 0.14 * distance)   world px (16 px = one cell)
-- of the card centre: about 17 degrees around a follower two cells away, 12 at three cells, 8 at four or more.
-- And the two rays VRITK tries are the held ball's own +Z (sideways out of the hand after the grip seat turn)
-- and the controller grip's -Z (OpenXR grip pose: along the handle, not where the hand points). Neither is
-- where a person points, so the user had to find a wrist angle that happened to line one of them up.
--
-- Here (the Gen3 wrapper of PartyFollower.aim in Gen3ChooseYouCompat calls hit()):
--   * a cone in ANGLE: the card's own half-size seen from the ball plus CONE_MARGIN, clamped to
--     [CONE_MIN, CONE_MAX] (20..35 degrees), out to MAX_RANGE;
--   * three rays: VRITK's two, plus the runtime's own POINTING ray. The engine binds the right hand's OpenXR aim
--     pose (QuestNativeXR "aimr", "where the user is pointing"); the right hand uses it directly, and its offset
--     from the right grip, mirrored, gives the left hand's (no offset measured yet: the left hand keeps the two
--     VRITK rays only);
--   * a ray that hit stays good for MEMO_SEC, so the authority's commit-time recheck (one tick later, same ray
--     table) cannot miss what the hand already had.
-- Hold-to-confirm (the Gen3 wrapper of PartyBelt.request): the trigger must stay pulled on target for HOLD_SEC
-- before the recall command is queued; letting go or losing the target for more than GAP_SEC starts over. A
-- stray trigger squeeze while holding a party ball no longer recalls by itself.
-- Feedback: a red reticle at the target's feet while the ball is aimed at it (brighter and filling while the
-- trigger is held), a short haptic tick when the aim is found and a stronger one when the recall fires.
-- Mod sandbox: no package, no debug. Pure functions plus one plain state table; nothing here touches game state.
local A = {}
A.CONE_MIN = math.rad(20)
A.CONE_MAX = math.rad(35)
A.CONE_MARGIN = math.rad(12)
A.MAX_RANGE = 160      -- world px (10 cells)
A.HOLD_SEC = 0.20      -- trigger held on target before the recall command is queued (fix57: was 0.25)
A.GAP_SEC = 0.30       -- longer than this without a request restarts the hold (fix57: was 0.15; the aim may waver)
-- fix57 (bug 6): the battle-switch recall aims at a small picture (18 px) from further away: a wider cone and a longer
-- reach than the overworld's. The overworld numbers above are unchanged. Passed to A.hit as the optional `profile`.
A.BATTLE = { coneMin = math.rad(28), coneMax = math.rad(45), margin = math.rad(16), range = 320 }
-- fix57 (bug 6): a held party ball only counted as a recall tool after the A-press growth to full size (0.64 s), which
-- nothing tells the user; the aim reticle showed but the trigger did nothing. FireRed accepts the aimed trigger hold from
-- the miniature ball too (PartyBeltComponent asks A.fromMini through the Gen3 compat lookup). Aim cone, hold time and
-- eligibility gates are unchanged.
A.MINI_RECALL = true
function A.fromMini() return A.MINI_RECALL == true end
A.MEMO_SEC = 0.5       -- a ray that hit stays accepted this long (the commit recheck)
A.AIM_FRESH_SEC = 0.12 -- the reticle shows while an aim test hit within this long
A.TICK_AMP, A.TICK_SEC = 0.10, 0.03    -- haptic tick when the aim is found
A.FIRE_AMP, A.FIRE_SEC = 0.22, 0.07    -- haptic pulse when the recall command is queued

local function finite(v) return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge end
local function vec3(t) return type(t) == "table" and finite(t[1]) and finite(t[2]) and finite(t[3]) end

--- The shared VRITK test, verbatim maths (for the before/after measurements).
function A.legacyHit(o, d, x, y, z, w, h)
  local delta = { x - o[1], y - o[2], z - o[3] }
  local along = delta[1] * d[1] + delta[2] * d[2] + delta[3] * d[3]
  if along < 0 or along > 120 then return false end
  local miss = delta[1] ^ 2 + delta[2] ^ 2 + delta[3] ^ 2 - along ^ 2
  local radius = math.max(3, math.min(10, math.max(w or 8, h or 8) * .4), along * .14)
  return miss <= radius ^ 2
end

--- Allowed angle (radians) for a card of w x h px whose centre is `dist` px away. profile (optional, A.BATTLE):
--- { coneMin, coneMax, margin }.
function A.cone(dist, w, h, profile)
  local half = math.max(tonumber(w) or 8, tonumber(h) or 8) * 0.5
  local a = math.atan2(half, math.max(1, dist)) + (profile and profile.margin or A.CONE_MARGIN)
  return math.max(profile and profile.coneMin or A.CONE_MIN, math.min(profile and profile.coneMax or A.CONE_MAX, a))
end

--- Angle between ray (o, unit d) and the direction to (x, y, z); and the distance. nil when degenerate.
function A.angleTo(o, d, x, y, z)
  local dx, dy, dz = x - o[1], y - o[2], z - o[3]
  local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
  if dist < 1e-6 then return 0, 0 end
  local c = (dx * d[1] + dy * d[2] + dz * d[3]) / dist
  return math.acos(math.max(-1, math.min(1, c))), dist
end

--- One ray against one target {x, y, z, w, h}: ok, angle, allowed. profile: optional (A.BATTLE).
function A.hit(o, d, t, profile)
  if not (vec3(o) and vec3(d) and t and finite(t.x) and finite(t.y) and finite(t.z)) then return false end
  local len = math.sqrt(d[1] ^ 2 + d[2] ^ 2 + d[3] ^ 2)
  if len < 1e-9 then return false end
  local u = { d[1] / len, d[2] / len, d[3] / len }
  local angle, dist = A.angleTo(o, u, t.x, t.y, t.z)
  if dist > (profile and profile.range or A.MAX_RANGE) then return false, angle, 0 end
  local allowed = A.cone(dist, t.w, t.h, profile)
  return angle <= allowed, angle, allowed
end

-- ------------------------------------------------------------ the pointing ray
-- 4x4 (row-major, translation in [4],[8],[12]) of a {pos|position, quat|orientation} pose, or nil.
function A.poseMatrix(pose)
  if type(pose) ~= "table" then return nil end
  local p, q = pose.position or pose.pos, pose.orientation or pose.quat
  if not (vec3(p) and type(q) == "table") then return nil end
  local n = 0
  for i = 1, 4 do if not finite(q[i]) then return nil end n = n + q[i] ^ 2 end
  if n < 1e-12 then return nil end
  n = math.sqrt(n)
  local x, y, z, w = q[1] / n, q[2] / n, q[3] / n, q[4] / n
  return { 1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w), p[1],
    2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w), p[2],
    2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y), p[3], 0, 0, 0, 1 }
end

local state = { offset = nil, aims = {}, holds = {}, memo = setmetatable({}, { __mode = "k" }), stats = {
  tests = 0, hits = 0, pointingHits = 0, legacyWouldMiss = 0, confirms = 0, fired = 0, restarts = 0 } }
A.state = state

--- Remember the right hand's aim direction in its grip frame (EMA), from one controls snapshot.
function A.learnOffset(controls)
  local g = controls and A.poseMatrix(controls.handr)
  local a = controls and A.poseMatrix(controls.aimr)
  if not (g and a) then return state.offset end
  local f = { -a[3], -a[7], -a[11] } -- aim -Z in room
  local v = { g[1] * f[1] + g[5] * f[2] + g[9] * f[3], g[2] * f[1] + g[6] * f[2] + g[10] * f[3],
    g[3] * f[1] + g[7] * f[2] + g[11] * f[3] } -- into grip local (R^T)
  local o = state.offset
  if o then
    v = { o[1] * 0.8 + v[1] * 0.2, o[2] * 0.8 + v[2] * 0.2, o[3] * 0.8 + v[3] * 0.2 }
  end
  local l = math.sqrt(v[1] ^ 2 + v[2] ^ 2 + v[3] ^ 2)
  if l > 1e-6 then state.offset = { v[1] / l, v[2] / l, v[3] / l } end
  return state.offset
end

local function apply(W, m, v)
  -- world direction of room-local direction m*v (W: world-from-room 4x4, may carry uniform scale)
  local r = { m[1] * v[1] + m[2] * v[2] + m[3] * v[3], m[5] * v[1] + m[6] * v[2] + m[7] * v[3],
    m[9] * v[1] + m[10] * v[2] + m[11] * v[3] }
  local w = { W[1] * r[1] + W[2] * r[2] + W[3] * r[3], W[5] * r[1] + W[6] * r[2] + W[7] * r[3],
    W[9] * r[1] + W[10] * r[2] + W[11] * r[3] }
  local l = math.sqrt(w[1] ^ 2 + w[2] ^ 2 + w[3] ^ 2)
  if l < 1e-9 then return nil end
  return { w[1] / l, w[2] / l, w[3] / l }
end
local function worldPoint(W, p)
  return { W[1] * p[1] + W[2] * p[2] + W[3] * p[3] + W[4], W[5] * p[1] + W[6] * p[2] + W[7] * p[3] + W[8],
    W[9] * p[1] + W[10] * p[2] + W[11] * p[3] + W[12] }
end

--- The pointing direction (world, unit) of the hand nearest `origin`, or nil.
--- controls = the raw snapshot (handl/handr/aimr in room metres), W = world-from-room.
function A.pointing(controls, W, origin)
  if not (type(controls) == "table" and type(W) == "table" and vec3(origin)) then return nil end
  A.learnOffset(controls)
  local best, side, bestM
  for _, s in ipairs({ "left", "right" }) do
    local m = A.poseMatrix(controls[s == "left" and "handl" or "handr"])
    if m then
      local p = worldPoint(W, { m[4], m[8], m[12] })
      local d = (p[1] - origin[1]) ^ 2 + (p[2] - origin[2]) ^ 2 + (p[3] - origin[3]) ^ 2
      if not best or d < best then best, side, bestM = d, s, m end
    end
  end
  if not side then return nil end
  if side == "right" then
    local a = A.poseMatrix(controls.aimr)
    if a then return apply(W, a, { 0, 0, -1 }), side end
    if state.offset then return apply(W, bestM, state.offset), side end
    return nil, side
  end
  local o = state.offset
  if not o then return nil, side end
  return apply(W, bestM, { -o[1], o[2], o[3] }), side -- mirrored across the grip's YZ plane
end

-- ------------------------------------------------------------ aim bookkeeping (feedback + memo)
local function clock() return love and love.timer and love.timer.getTime and love.timer.getTime() or os.clock() end
A.clock = clock

--- Record an aim test result for the reticle / haptics. key = the target identity, point = {x,y,z,w,h}.
function A.noteAim(key, point, hit, via)
  state.stats.tests = state.stats.tests + 1
  if not hit then return end
  state.stats.hits = state.stats.hits + 1
  if via == "pointing" then state.stats.pointingHits = state.stats.pointingHits + 1 end
  local now = clock()
  local a = state.aims[key]
  if not a or now - a.at > A.AIM_FRESH_SEC * 3 then
    a = { found = now, ticked = false }
    state.aims[key] = a
  end
  a.at, a.point, a.via = now, point, via
end
function A.memo(ray, entity)
  if type(ray) == "table" then state.memo[ray] = { entity = entity, at = clock() } end
end
function A.recalled(ray, entity)
  local m = type(ray) == "table" and state.memo[ray]
  return m ~= nil and m.entity == entity and clock() - m.at <= A.MEMO_SEC
end
local function gap()
  -- a frame hitch is not a let-go: allow three frames of the current frame time
  local dt = love and love.timer and love.timer.getDelta and love.timer.getDelta() or 0
  return math.max(A.GAP_SEC, 3 * (tonumber(dt) or 0))
end
--- Live aims (for the reticle): list of { key, point, hold (0..1 or nil), found }.
function A.liveAims()
  local now, out = clock(), {}
  -- review fix 3: holds are kept per belt ball (confirm's key) and aims per target; the hold being pulled now is
  -- the newest one still inside its gap, and it fills whichever target is aimed at this moment
  local current
  for _, h in pairs(state.holds) do
    if now - h.last <= gap() and (not current or h.last > current.last) then current = h end
  end
  for key, a in pairs(state.aims) do
    if now - a.at <= A.AIM_FRESH_SEC then
      local h = current
      local hold = h and now - h.last <= gap() and math.min(1, (h.last - h.start) / A.HOLD_SEC) or nil
      out[#out + 1] = { key = key, point = a.point, hold = hold, found = a.found, via = a.via }
    elseif now - a.at > 2 then
      state.aims[key] = nil
    end
  end
  return out
end

--- Hold-to-confirm. Called on every recall request for `key` (the belt index); true once the trigger has been
--- held on target for HOLD_SEC without a gap.
function A.confirm(key)
  local now = clock()
  local h = state.holds[key]
  if not h or now - h.last > gap() then
    if h then state.stats.restarts = state.stats.restarts + 1 end
    h = { start = now, last = now }
    state.holds[key] = h
    state.stats.confirms = state.stats.confirms + 1
  end
  h.last = now
  if now - h.start >= A.HOLD_SEC then
    state.holds[key] = nil
    state.stats.fired = state.stats.fired + 1
    return true
  end
  return false
end
function A.clearHolds() state.holds = {} end

function A.status()
  local out = {}
  for k, v in pairs(state.stats) do out[k] = v end
  out.offset = state.offset and { state.offset[1], state.offset[2], state.offset[3] } or nil
  out.live = #A.liveAims()
  return out
end

return A
