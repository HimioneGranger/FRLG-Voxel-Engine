-- Gen3-only tablet pointing and hand collision (tablet-input58 v2, 2026-10-11).
--
-- Both jobs are decided ONCE per frame (the interaction update runs once per frame; the two eyes only read the result).
--
--  1. POINTING (pick). A ray from the free hand's drawn index finger (fingertip, along wrist -> tip) or, when that
--     misses the glass, from the controller's grip frame (-Z, the old wrist ray) hits the tablet plane; the hit becomes
--     the same { u, v, kind = "ray" } point the interaction already turns into down / move / up with the trigger. A pinch
--     value (optional hand.model.pinch or controls.pinchL, 0..1) counts as a trigger pull. Touch has priority: a
--     fingertip touch point from the interaction is returned as is. The module never emits events, edits controls or
--     claims a button; off the glass it returns nil.
--     CURSOR (v2): whatever point is returned carries state = nil and proximity = nil, so the existing cursor is ONE
--     small teal dot of one fixed size (QuestDeviceRenderer sizes by pointer.state/proximity only: the hover colour and
--     the 1.7x..0.8x distance scaling came from touch hover, the green 1.1x from state="press"). The only exception is a
--     brief PRESS FLASH (state="press", FLASH seconds) on a trigger or pinch press.
--
--  2. HAND COLLISION (clamp). The drawn glove is pushed (rigidly, render only) out of the tablet BODY, not only the
--     screen: the body is the slab x +-BODY_HX, z +-BODY_HZ, y BODY_BACK..BODY_FRONT in the tablet model frame (measured
--     from the GLB; the red rail and the side panel are inside it). Every joint of the real skinned glove rig is
--     sampled (rig.mats of the last skin x the joint's rest position, so library poses and host-skeleton poses both
--     work), each with a small radius for the finger thickness:
--       * a hand in FRONT of the tablet (the free hand pointing / touching) must keep every joint above the front
--         plane: shift = deepest (FRONT + r + CLAMP_OFFSET - y) along +normal;
--       * a hand BEHIND the tablet (the holding hand's fingers, or a hand reaching round the back) must not poke out of
--         the front: shift = deepest (y + r - FRONT + HOLD_CLEAR) along -normal. Only the finger joints from the middle
--         knuckle out are sampled for the holder, and its thumb is never sampled (it rests on the front rail on purpose).
--     The side a hand is on is latched from its palm joint (hysteresis LATCH_MARGIN while over the body; off the body the palm's side of the mid plane), the holder is always "behind".
--     There is no depth fade: a hand in front is pushed out however deep a finger went (capped at MAX_SHIFT).
--     The clamp never looks at grip or trigger: it runs in every hand pose. Without a usable rig it falls back to the
--     drawn index tip and the wrist point (v1 samples).
--     The amount rises instantly (nothing is ever drawn through the body) and falls exponentially (RELEASE_TAU).
--     Tracked poses, touch and ray input never see it; it is applied in QuestHandsRenderer through adjustModel.
--
-- Allocation: every per-frame function works on numbers and on scratch arrays owned by the instance (a ring of POINTS
-- point tables, one 12-number affine, per-hand output matrices). Rig tables and fit matrices are built only when a rig
-- first appears or the glove fit changes.
-- No V.require here: the VRITK_FRLG_HOST loader only sees its own lib/ folder. QuestDeviceLayout, the glove fit and
-- GloveSkin come in through pick() as the interaction's Layout and V.

local M = {}
M.__index = M

M.DEFAULTS = {
  RAY_SOURCE = "auto",    -- "auto" (finger, then grip) | "finger" | "grip"
  MAX_RANGE = 1.5,        -- metres, same as the old wrist ray
  CLAMP = true,           -- false: pointing only, no collision
  HOLDER_CLAMP = true,    -- false: leave the holding hand alone
  -- tablet body in the tablet model frame (metres); tests compare these with the GLB
  BODY_HX = 0.1117, BODY_HZ = 0.1810, BODY_FRONT = 0.0071, BODY_BACK = -0.0071,
  CLAMP_OFFSET = 0.0015,  -- a front hand's finger surface rests this far above the front plane
  HOLD_CLEAR = 0.0005,    -- a behind hand's finger surface stays this far below the front plane
  RECT_BLEND = 0.012,     -- fade outside the body footprint (m)
  RELEASE_TAU = 0.060,    -- s; exponential tail when the shift ends
  MAX_SHIFT = 0.100,      -- m; hard cap of the drawn shift
  LATCH_MARGIN = 0.020,   -- m; the palm must be this far past the body face to change side
  FLASH = 0.12,           -- s; press flash on the cursor
  PINCH_ON = 0.55, PINCH_OFF = 0.35,
  TRIGGER_ON = 0.55, TRIGGER_OFF = 0.35,
  BASIS_REFRESH = 90,     -- frames between retries while the drawn fingertip is unavailable
  -- joint sphere radii (m) for the finger / hand thickness of the glove mesh. Fitted to the real glove (a capsule fit of the
  -- 3.9k rest vertices per bone, reduced for the flat palm), then checked against the skinned mesh over random poses
  -- (tests	59_clamp.lua, tools\exp_radii.lua): the thumb is the thickest finger of this glove.
  RADII = { tip = 0.0065, dist = 0.0092, inter = 0.0120, prox = 0.0170, meta = 0.0200, palm = 0.0200, wrist = 0.0330,
    thumbScale = 1.5, littleScale = 0.9 },
}
local POINTS = 6

local sqrt, abs, exp, min = math.sqrt, math.abs, math.exp, math.min

local function finite(x, fallback)
  x = tonumber(x)
  if not x or x ~= x or x == math.huge or x == -math.huge then return fallback or 0 end
  return x
end
local function clamp01(x) return x < 0 and 0 or (x > 1 and 1 or x) end
local function smooth(x)
  x = x < 0 and 0 or (x > 1 and 1 or x)
  return x * x * (3 - 2 * x)
end

-- quaternion rotation of a vector, unit quaternion, multiple returns (no table)
local function qrot(qx, qy, qz, qw, x, y, z)
  local tx = 2 * (qy * z - qz * y)
  local ty = 2 * (qz * x - qx * z)
  local tz = 2 * (qx * y - qy * x)
  return x + qw * tx + (qy * tz - qz * ty),
    y + qw * ty + (qz * tx - qx * tz),
    z + qw * tz + (qx * ty - qy * tx)
end

-- one hand's collision state
local function newSlot()
  return { amount = 0, sx = 0, sy = 0, sz = 0, latch = 1,
    rig = nil, full = nil, fing = nil, bindFailed = false,
    fit = nil, fitRev = nil, fitLoaded = nil, A = { 1, 0, 0, 0, 1, 0, 0, 0, 1 }, b = { 0, 0, 0 }, bOk = false,
    gx = 0, gy = 0, gz = 0, scale = 1, bindKey = nil }
end

-- tip: function(side) -> x, y, z in the controller grip frame (DrawnFingertip.tip); optional.
-- opts: tunables overriding DEFAULTS (opts.params); side: the pointing hand ("left");
--   gripToWrist(side) -> {x,y,z} of the pointing pose; gripScale(side, holder) -> gx, gy, gz, scale (hand offset and scale
--   of the pointing pose / the holder pose). Both are the host's VRHandAssets numbers.
function M.new(opts)
  opts = type(opts) == "table" and opts or {}
  local p = {}
  for k, v in pairs(M.DEFAULTS) do p[k] = v end
  if type(opts.params) == "table" then for k, v in pairs(opts.params) do p[k] = v end end
  local side = opts.side == "right" and "right" or "left"
  local self = setmetatable({ p = p, tipFn = opts.tip, side = side, holderSide = side == "left" and "right" or "left",
    gripToWrist = opts.gripToWrist, gripScale = opts.gripScale,
    tx = 0, ty = 0, tz = -0.10, px = 0, py = 0, pz = 0, dx = 0, dy = 0, dz = -1, basisOk = false,
    basisAge = 1 / 0, basisRev = nil,
    gKey = {}, gOk = false, cx = 0, cy = 0, cz = 0, nx = 0, ny = 1, nz = 0, m = { 1, 0, 0, 0, 1, 0, 0, 0, 1 },
    src = nil, ring = {}, ringAt = 0,
    trigger = 0, pinchDown = false, pinch = 0, trigLatch = false, flashLeft = 0,
    onTablet = false, hits = 0, lastU = nil, lastV = nil,
    slots = { left = newSlot(), right = newSlot() },
    F = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0 }, R = { 1, 0, 0, 0, 1, 0, 0, 0, 1 }, T = { 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    out = { left = {}, right = {} },
    picked = false,
    stats = { picks = 0, rayHits = 0, clampFrames = 0, maxShift = 0, rigScans = 0, fallbackScans = 0 } }, M)
  for i = 1, POINTS do self.ring[i] = { u = 0, v = 0, distance = 0, kind = "ray" } end
  for _, s in ipairs({ "left", "right" }) do for i = 1, 16 do self.out[s][i] = 0 end end
  return self
end

-- the pointer-side shift (v1 field names kept for the status / tests)
function M:amountOf(side) local s = self.slots[side]; return s and s.amount or 0 end

-- -------------------------------------------------------------- drawn finger basis (ray)
function M:_refreshBasis(force, fit)
  local fn = self.tipFn
  if type(fn) ~= "function" then return end
  local rev = fit and fit.revision
  self.basisAge = self.basisAge + 1
  if not force and self.basisOk and rev == self.basisRev then return end
  if not force and not self.basisOk and self.basisAge < self.p.BASIS_REFRESH then return end
  self.basisAge, self.basisRev = 0, rev
  local ok, x, y, z = pcall(fn, self.side)
  if not (ok and x and y and z) then self.basisOk = false; return end
  local px, py, pz = 0, 0, 0
  if type(self.gripToWrist) == "function" then
    local okg, g = pcall(self.gripToWrist, self.side)
    if okg and type(g) == "table" then px, py, pz = finite(g[1]), finite(g[2]), finite(g[3]) end
  end
  local dx, dy, dz = x - px, y - py, z - pz
  local len = sqrt(dx * dx + dy * dy + dz * dz)
  if len < 0.02 then px, py, pz, dx, dy, dz, len = 0, 0, 0, x, y, z, sqrt(x * x + y * y + z * z) end
  if len < 1e-6 then self.basisOk = false; return end
  self.tx, self.ty, self.tz, self.px, self.py, self.pz = x, y, z, px, py, pz
  self.dx, self.dy, self.dz = dx / len, dy / len, dz / len
  self.basisOk = true
end

-- -------------------------------------------------------------- tablet geometry (cached by value)
-- The tablet model frame: origin = anchor, M = Rz Rx Ry (the interaction's modelVector), self.m holds M row-major
-- (its transpose is the inverse). center/normal describe the screen glass plane (the ray target).
local function modelMatrix(m, rx, ry, rz)
  local cy_, sy_ = math.cos(ry), math.sin(ry)
  local cx_, sx_ = math.cos(rx), math.sin(rx)
  local cz_, sz_ = math.cos(rz), math.sin(rz)
  for col = 1, 3 do
    local x, y, z = col == 1 and 1 or 0, col == 2 and 1 or 0, col == 3 and 1 or 0
    local ax, ay, az = cy_ * x + sy_ * z, y, -sy_ * x + cy_ * z
    local bx, by, bz = ax, cx_ * ay - sx_ * az, sx_ * ay + cx_ * az
    local ex, ey, ez = cz_ * bx - sz_ * by, sz_ * bx + cz_ * by, bz
    m[col], m[3 + col], m[6 + col] = ex, ey, ez
  end
end

function M:_geometry(I, screen)
  local k = self.gKey
  local a = I.TABLET_ANCHOR
  local rx, ry, rz = I.TABLET_ROTATION_X, I.TABLET_ROTATION_Y, I.TABLET_ROTATION_Z
  if self.gOk and k[1] == rx and k[2] == ry and k[3] == rz and k[4] == a[1] and k[5] == a[2] and k[6] == a[3]
      and k[7] == screen[1] and k[8] == screen[2] and k[9] == screen[3] then return end
  k[1], k[2], k[3], k[4], k[5], k[6], k[7], k[8], k[9] = rx, ry, rz, a[1], a[2], a[3], screen[1], screen[2], screen[3]
  local m = self.m
  modelMatrix(m, rx, ry, rz)
  self.cx = a[1] + m[1] * screen[1] + m[2] * screen[2] + m[3] * screen[3]
  self.cy = a[2] + m[4] * screen[1] + m[5] * screen[2] + m[6] * screen[3]
  self.cz = a[3] + m[7] * screen[1] + m[8] * screen[2] + m[9] * screen[3]
  self.nx, self.ny, self.nz = m[2], m[5], m[8]
  self.gOk = true
end

local function hasPose(hand)
  if type(hand) ~= "table" or hand.tracked ~= true then return nil end
  local pose = hand.pose
  if type(pose) ~= "table" then return nil end
  local p, q = pose.position or pose.pos, pose.orientation or pose.quat
  if type(p) ~= "table" or type(q) ~= "table" then return nil end
  return p, q
end

function M:_hit(ox, oy, oz, dx, dy, dz)
  local nx, ny, nz = self.nx, self.ny, self.nz
  local den = dx * nx + dy * ny + dz * nz
  if den >= -1e-6 then return nil end
  local t = ((self.cx - ox) * nx + (self.cy - oy) * ny + (self.cz - oz) * nz) / den
  if t <= 0 or t > self.p.MAX_RANGE then return nil end
  local hx, hy, hz = ox + dx * t - self.cx, oy + dy * t - self.cy, oz + dz * t - self.cz
  local m = self.m
  return t, m[1] * hx + m[4] * hy + m[7] * hz, m[3] * hx + m[6] * hy + m[9] * hz
end

-- -------------------------------------------------------------- joint sets from the skinned glove rig
-- Built once per rig. `full`: every joint; `fing`: the holder set (finger joints from the middle knuckle out, no thumb,
-- no palm). Joint rest world positions come from the inverse bind matrices (rest world = inverse of invBind):
-- the current joint position in hand space is mats[bone] * rest. `mats` are the skin matrices of the LAST skin
-- (the previous frame's pose when this runs: one frame of lag in the finger curl, none in the hand placement).
local function buildSets(self, rig)
  local R = self.p.RADII
  local ib, names = rig.invBind, rig.bones
  local full = { n = 0, bx = {}, by = {}, bz = {}, bo = {}, br = {}, palm = nil }
  local fing = { n = 0, bx = {}, by = {}, bz = {}, bo = {}, br = {}, palm = nil }
  local back = { n = 0, bx = {}, by = {}, bz = {}, bo = {}, br = {}, palm = nil }   -- fing + thumb: a free hand behind the tablet
  for b = 1, rig.boneCount do
    local name = names[b]
    local o = (b - 1) * 12
    local t1, t2, t3 = ib[o + 4], ib[o + 8], ib[o + 12]
    local rx = -(ib[o + 1] * t1 + ib[o + 5] * t2 + ib[o + 9] * t3)
    local ry = -(ib[o + 2] * t1 + ib[o + 6] * t2 + ib[o + 10] * t3)
    local rz = -(ib[o + 3] * t1 + ib[o + 7] * t2 + ib[o + 11] * t3)
    local finger, part = tostring(name):match("^(%a+)_(%a+)$")
    local r, holderPart
    if not finger then
      r = R[name] or R.palm
    else
      r = R[part == "metacarpal" and "meta" or part == "proximal" and "prox" or part == "intermediate" and "inter"
        or part == "distal" and "dist" or "tip"] or R.tip
      if finger == "little" then r = r * (R.littleScale or 1) end
      if finger == "thumb" then r = r * (R.thumbScale or 1)
      else holderPart = part == "intermediate" or part == "distal" or part == "tip" end
    end
    local function add(set)
      local n = set.n + 1
      set.n = n
      set.bx[n], set.by[n], set.bz[n], set.bo[n], set.br[n] = rx, ry, rz, o, r
      return n
    end
    local i = add(full)
    if name == "palm" then
      full.palm = i
      -- the finger set carries the palm as a zero-radius probe: it gives the side latch its position, and a point cannot push
      local n = fing.n + 1
      fing.n = n
      fing.bx[n], fing.by[n], fing.bz[n], fing.bo[n], fing.br[n] = rx, ry, rz, o, 0
      fing.palm = n
      local m2 = back.n + 1
      back.n = m2
      back.bx[m2], back.by[m2], back.bz[m2], back.bo[m2], back.br[m2] = rx, ry, rz, o, 0
      back.palm = m2
    end
    if holderPart then add(fing); add(back) end
    if finger == "thumb" and part ~= "metacarpal" then
      -- behind the tablet the thumb counts at its plain thickness (the x1.5 of the front rule is for the pad that meets the glass)
      local n = back.n + 1
      back.n = n
      back.bx[n], back.by[n], back.bz[n], back.bo[n], back.br[n] = rx, ry, rz, o, r / (R.thumbScale or 1)
    end
  end
  if not full.palm then full.palm = 1 end
  return full, fing, back
end

local function bindRig(self, slot, side, Vx)
  slot.bindFailed = true
  if type(Vx) ~= "table" or type(Vx.require) ~= "function" then return end
  local ok, GS = pcall(Vx.require, "GloveSkin")
  if not (ok and type(GS) == "table" and type(GS.rig) == "function") then return end
  local okr, rig = pcall(GS.rig, side)
  if not (okr and type(rig) == "table" and rig.invBind and rig.mats and rig.bones and rig.boneCount) then return end
  local okb, full, fing, back = pcall(buildSets, self, rig)
  if not (okb and full and full.n > 0) then return end
  slot.rig, slot.full, slot.fing, slot.back, slot.bindFailed = rig, full, fing, back, false
end

-- hand-space -> hand-pose-frame transform, refreshed when the glove fit changes: p -> A p + b, with
-- A = s * C (3x3 of the fit correction) and b = g + s * Ct for the free hand (SkinnedGloveHands: model * C, no fit for the
-- flat-support holder, which is turned by the host's grip rotation instead).
local function refreshHandTransform(self, slot, side, holder, Vx)
  local fit = type(Vx) == "table" and Vx.gloveFit or nil
  local rev = fit and fit.revision
  local loaded = fit and (fit.loaded and true or false) or nil
  if slot.bOk and slot.fit == fit and slot.fitRev == rev and slot.fitLoaded == loaded and slot.isHolder == holder then return true end
  if type(self.gripScale) ~= "function" then return false end
  local ok, gx, gy, gz, s = pcall(self.gripScale, side, holder)
  if not (ok and gx) then return false end
  s = finite(s, 1); if s <= 0 then s = 1 end
  slot.gx, slot.gy, slot.gz, slot.scale = finite(gx), finite(gy), finite(gz), s
  local A, b = slot.A, slot.b
  A[1], A[2], A[3], A[4], A[5], A[6], A[7], A[8], A[9] = s, 0, 0, 0, s, 0, 0, 0, s
  b[1], b[2], b[3] = slot.gx, slot.gy, slot.gz
  if not holder and fit and type(fit.correction) == "function" then
    local okc, c = pcall(fit.correction, fit, side, { slot.gx, slot.gy, slot.gz }, s)
    if okc and type(c) == "table" then
      A[1], A[2], A[3], A[4], A[5], A[6], A[7], A[8], A[9] =
        s * c[1], s * c[2], s * c[3], s * c[5], s * c[6], s * c[7], s * c[9], s * c[10], s * c[11]
      b[1], b[2], b[3] = slot.gx + s * c[4], slot.gy + s * c[8], slot.gz + s * c[12]
    end
  end
  slot.fit, slot.fitRev, slot.fitLoaded, slot.isHolder, slot.bOk = fit, rev, loaded, holder, true
  return true
end

-- Scan one joint set. F: hand space -> tablet model frame (3x4 row-major). latch +1: keep joints above the front plane;
-- latch -1: keep joints from poking out of the front. Returns the deepest weighted penetration (>= 0) and the palm's
-- model-frame y and "over the body" flag through the instance fields palmY / palmOver.
function M:_scan(set, mats, F, latch)
  local P = self.p
  local HX, HZ, FR = P.BODY_HX, P.BODY_HZ, P.BODY_FRONT
  local RB, OFF, HC = P.RECT_BLEND, P.CLAMP_OFFSET, P.HOLD_CLEAR
  local f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12 = F[1], F[2], F[3], F[4], F[5], F[6], F[7], F[8], F[9], F[10], F[11], F[12]
  local bx, by, bz, bo, br = set.bx, set.by, set.bz, set.bo, set.br
  local palm = set.palm
  local best = 0
  for i = 1, set.n do
    local o = bo[i]
    local x, y, z = bx[i], by[i], bz[i]
    local px = mats[o + 1] * x + mats[o + 2] * y + mats[o + 3] * z + mats[o + 4]
    local py = mats[o + 5] * x + mats[o + 6] * y + mats[o + 7] * z + mats[o + 8]
    local pz = mats[o + 9] * x + mats[o + 10] * y + mats[o + 11] * z + mats[o + 12]
    local lx = f1 * px + f2 * py + f3 * pz + f4
    local ly = f5 * px + f6 * py + f7 * pz + f8
    local lz = f9 * px + f10 * py + f11 * pz + f12
    local ex, ez = HX - abs(lx), HZ - abs(lz)
    local edge = ex < ez and ex or ez
    if i == palm then
      self.palmY, self.palmOver = ly, edge > 0
    end
    local r = br[i]
    -- a joint sphere of radius r overlaps the body footprint when the centre is within r of its edge
    edge = edge + r
    if edge > -RB then
      local pen
      if latch > 0 then pen = FR + r + OFF - ly else pen = ly + r - FR + HC end
      if pen > 0 then
        pen = pen * smooth((edge + RB) / RB)
        if pen > best then best = pen end
      end
    end
  end
  return best
end

-- F (hand space -> tablet frame) for a hand posed at relative rotation (qx,qy,qz,qw) and position (rpx,rpy,rpz) in the holder
-- frame, with hand-space transform p -> A p + b. Writes self.F.
function M:_affine(slot, qx, qy, qz, qw, rpx, rpy, rpz)
  local m, A, b, F, R = self.m, slot.A, slot.b, self.F, self.R
  -- R = rotation matrix of the quaternion
  local xx, yy, zz, xy, xz, yz, wx, wy, wz = qx * qx, qy * qy, qz * qz, qx * qy, qx * qz, qy * qz, qw * qx, qw * qy, qw * qz
  R[1], R[2], R[3] = 1 - 2 * (yy + zz), 2 * (xy - wz), 2 * (xz + wy)
  R[4], R[5], R[6] = 2 * (xy + wz), 1 - 2 * (xx + zz), 2 * (yz - wx)
  R[7], R[8], R[9] = 2 * (xz - wy), 2 * (yz + wx), 1 - 2 * (xx + yy)
  -- T = R * A (3x3)
  local T = self.T
  for i = 0, 2 do
    local r1, r2, r3 = R[i * 3 + 1], R[i * 3 + 2], R[i * 3 + 3]
    T[i * 3 + 1] = r1 * A[1] + r2 * A[4] + r3 * A[7]
    T[i * 3 + 2] = r1 * A[2] + r2 * A[5] + r3 * A[8]
    T[i * 3 + 3] = r1 * A[3] + r2 * A[6] + r3 * A[9]
  end
  -- translation in the holder frame: R b + rp - anchor
  local a = self.anchor
  local tx = R[1] * b[1] + R[2] * b[2] + R[3] * b[3] + rpx - a[1]
  local ty = R[4] * b[1] + R[5] * b[2] + R[6] * b[3] + rpy - a[2]
  local tz = R[7] * b[1] + R[8] * b[2] + R[9] * b[3] + rpz - a[3]
  -- F = M^T * [T | t]
  for i = 0, 2 do
    local m1, m2, m3 = m[1 + i], m[4 + i], m[7 + i]          -- row i of M^T = column i of M
    F[i * 4 + 1] = m1 * T[1] + m2 * T[4] + m3 * T[7]
    F[i * 4 + 2] = m1 * T[2] + m2 * T[5] + m3 * T[8]
    F[i * 4 + 3] = m1 * T[3] + m2 * T[6] + m3 * T[9]
    F[i * 4 + 4] = m1 * tx + m2 * ty + m3 * tz
  end
  return F
end

-- -------------------------------------------------------------- per-frame entry
-- legacy: the point the interaction has so far (a touch point, a wrist-ray point, or nil).
-- holder / pointer: the two hand records (hands.right, hands.left); I: the Interaction class (TABLET_* constants);
-- screen: tabletScreen {x,y,z}; width/height: fitted metres; spec: tablet screen spec; controls: raw frame controls;
-- reserved: reservedHands; dt seconds; Layout: the interaction's QuestDeviceLayout; Vx: the interaction's V (gloveFit,
-- require for GloveSkin). Returns the point to use. Never errors on odd input.
function M:pick(legacy, holder, pointer, I, screen, width, height, spec, controls, reserved, dt, Layout, Vx)
  self.picked = true
  self.stats.picks = self.stats.picks + 1
  dt = finite(dt, 0)
  if dt < 0 or dt > 0.25 then dt = 1 / 72 end
  local P = self.p
  local trig, grip, trigRaw = 0, 0, 0
  local left = self.side == "left"
  if type(controls) == "table" then
    trig = tonumber(left and controls.pinchL or controls.pinchR) or 0
    grip = finite(left and controls.gripL or controls.gripR, 0)
    trigRaw = finite(left and controls.triggerL or controls.triggerR, 0)
  end
  local model = type(pointer) == "table" and pointer.model
  if type(model) == "table" then local pv = tonumber(model.pinch); if pv and pv > trig then trig = pv end end
  trig = clamp01(finite(trig, 0))
  if self.pinchDown then if trig < P.PINCH_OFF then self.pinchDown = false end
  elseif trig >= P.PINCH_ON then self.pinchDown = true end
  self.pinch = self.pinchDown and trig or 0
  if self.flashLeft > 0 then self.flashLeft = self.flashLeft - dt; if self.flashLeft < 0 then self.flashLeft = 0 end end
  if type(Layout) ~= "table" then self.onTablet = false; self:_fallAll(dt); return legacy end
  local tp, tq = hasPose(holder)
  local pp, pq = hasPose(pointer)
  if not (tp and pp) then
    self.onTablet = false
    self:_fallAll(dt)
    return legacy
  end
  self:_refreshBasis(false, type(Vx) == "table" and Vx.gloveFit or nil)
  self:_geometry(I, screen)
  self.anchor = I.TABLET_ANCHOR
  local tl = sqrt(tq[1] * tq[1] + tq[2] * tq[2] + tq[3] * tq[3] + tq[4] * tq[4])
  local pl = sqrt(pq[1] * pq[1] + pq[2] * pq[2] + pq[3] * pq[3] + pq[4] * pq[4])
  if tl < 1e-8 or pl < 1e-8 then self.onTablet = false; self:_fallAll(dt); return legacy end
  local tx_, ty_, tz_, tw_ = tq[1] / tl, tq[2] / tl, tq[3] / tl, tq[4] / tl
  local px_, py_, pz_, pw_ = pq[1] / pl, pq[2] / pl, pq[3] / pl, pq[4] / pl
  local rpx, rpy, rpz = qrot(-tx_, -ty_, -tz_, tw_, pp[1] - tp[1], pp[2] - tp[2], pp[3] - tp[3])
  -- the drawn index finger exists for a hand that is not reserved / holding / cradling / fisting. Grip is NOT part of the
  -- test (v2): holding the grip is how the player points, and the glove then draws its own pointing pose.
  local fingerFree = not (type(reserved) == "table" and reserved[self.side])
  if type(model) == "table" then
    fingerFree = fingerFree and not (model.holding or model.miniCradle or model.gripStyle or model.combined or model.closedFist)
  end
  local cx_, cy_, cz_, cw_ = -tx_, -ty_, -tz_, tw_
  local qx = cw_ * px_ + cx_ * pw_ + cy_ * pz_ - cz_ * py_
  local qy = cw_ * py_ - cx_ * pz_ + cy_ * pw_ + cz_ * px_
  local qz = cw_ * pz_ + cx_ * py_ - cy_ * px_ + cz_ * pw_
  local qw = cw_ * pw_ - cx_ * px_ - cy_ * py_ - cz_ * pz_

  local tipX, tipY, tipZ
  if self.basisOk then
    local ax, ay, az = qrot(qx, qy, qz, qw, self.tx, self.ty, self.tz)
    tipX, tipY, tipZ = rpx + ax, rpy + ay, rpz + az
  end

  -- ---------------------------------------------------------- the ray
  local point = legacy
  local touch = type(legacy) == "table" and legacy.kind == "touch"
  if not touch then
    point = nil
    local mode = P.RAY_SOURCE
    local first, second
    if mode == "grip" then first = "grip"
    elseif mode == "finger" then first = "finger"
    else
      first = (self.src == "grip") and "grip" or "finger"
      second = first == "grip" and "finger" or "grip"
    end
    local fingerOk = self.basisOk and fingerFree
    if first == "finger" and not fingerOk then first, second = second, nil end
    if second == "finger" and not fingerOk then second = nil end
    if mode == "finger" and not fingerOk then first = "grip" end
    for pass = 1, 2 do
      local s = pass == 1 and first or second
      if not s then break end
      local ox, oy, oz, dx, dy, dz
      if s == "finger" then
        ox, oy, oz = tipX, tipY, tipZ
        dx, dy, dz = qrot(qx, qy, qz, qw, self.dx, self.dy, self.dz)
      else
        ox, oy, oz = rpx, rpy, rpz
        dx, dy, dz = qrot(qx, qy, qz, qw, 0, 0, -1)
      end
      local t, lx, lz = self:_hit(ox, oy, oz, dx, dy, dz)
      if t and Layout.inside(spec, lx, lz) then
        local u, v = Layout.uv(lx / width, lz / height, I.TABLET_UI_QUARTER_TURNS)
        if u >= 0 and u <= 1 and v >= 0 and v <= 1 then
          self.ringAt = self.ringAt % POINTS + 1
          point = self.ring[self.ringAt]
          point.u, point.v, point.distance, point.kind = u, v, t, "ray"
          point.source = s
          self.src = s
          break
        end
      end
    end
  end
  self.onTablet = point ~= nil and point.kind == "ray"
  if self.onTablet then
    self.stats.rayHits = self.stats.rayHits + 1
    self.lastU, self.lastV = point.u, point.v
  end

  -- ---------------------------------------------------------- cursor: one dot, press flash on a trigger / pinch press
  local pull = trigRaw > trig and trigRaw or trig
  if self.trigLatch then
    if pull < P.TRIGGER_OFF then self.trigLatch = false end
  elseif pull >= P.TRIGGER_ON then
    self.trigLatch = true
    if point ~= nil then self.flashLeft = P.FLASH end
  end
  if point ~= nil then
    point.state = self.flashLeft > 0 and "press" or nil
    point.proximity = nil
  end

  -- ---------------------------------------------------------- hand collision (every pose)
  local free = self.slots[self.side]
  local hold = self.slots[self.holderSide]
  if P.CLAMP then
    -- the pointing / free hand
    local targetFree = 0
    local sidePush = 1
    local sl = free
    if not sl.rig and not sl.bindFailed then bindRig(self, sl, self.side, Vx) end
    local ready = sl.rig ~= nil and refreshHandTransform(self, sl, self.side, false, Vx)
    if ready then
      self.stats.rigScans = self.stats.rigScans + 1
      local F = self:_affine(sl, qx, qy, qz, qw, rpx, rpy, rpz)
      local mats = sl.rig.mats
      -- latch from the palm joint: scan once for the palm's position (front hand first), flip when it is clearly behind
      -- a hand in front is judged with every joint; a hand behind only by its finger joints (the thick palm / wrist spheres would
      -- reach round the front face of a hand that is entirely behind)
      local pen = self:_scan(sl.latch > 0 and sl.full or sl.back, mats, F, sl.latch)
      local lat = sl.latch
      if self.palmOver then
        if lat > 0 and self.palmY < P.BODY_BACK - P.LATCH_MARGIN then lat = -1
        elseif lat < 0 and self.palmY > P.BODY_FRONT + P.LATCH_MARGIN then lat = 1 end
      else
        -- off the body: the side the palm is on, so a hand that slides in from the side keeps the side it came from
        lat = self.palmY < 0 and -1 or 1
      end
      if lat ~= sl.latch then sl.latch = lat; pen = self:_scan(lat > 0 and sl.full or sl.back, mats, F, lat) end
      targetFree, sidePush = pen, lat
    elseif tipX then
      -- no rig: the drawn index tip and the wrist point against the body front (v1 samples)
      self.stats.fallbackScans = self.stats.fallbackScans + 1
      targetFree = self:_fallbackPen(tipX, tipY, tipZ, qx, qy, qz, qw, rpx, rpy, rpz)
      sidePush = 1
    end
    if targetFree > P.MAX_SHIFT then targetFree = P.MAX_SHIFT end
    local wx, wy, wz = qrot(tx_, ty_, tz_, tw_, self.nx, self.ny, self.nz)
    free.sx, free.sy, free.sz = wx * sidePush, wy * sidePush, wz * sidePush
    self:_fall(free, dt, targetFree)

    -- the holding hand: always behind the tablet
    local targetHold = 0
    if P.HOLDER_CLAMP then
      if not hold.rig and not hold.bindFailed then bindRig(self, hold, self.holderSide, Vx) end
      if hold.rig ~= nil and refreshHandTransform(self, hold, self.holderSide, true, Vx) then
        -- the holder's hand frame is the holder pose turned by Rx(gripPitch) then Ry(gripYaw), as QuestHandsRenderer does
        local hx, hy, hz, hw = self:_gripQuat(I)
        self.stats.rigScans = self.stats.rigScans + 1
        local F = self:_affine(hold, hx, hy, hz, hw, 0, 0, 0)
        targetHold = self:_scan(hold.fing, hold.rig.mats, F, -1)
      end
    end
    if targetHold > P.MAX_SHIFT then targetHold = P.MAX_SHIFT end
    local wx, wy, wz = qrot(tx_, ty_, tz_, tw_, self.nx, self.ny, self.nz)
    hold.sx, hold.sy, hold.sz = -wx, -wy, -wz
    self:_fall(hold, dt, targetHold)
  else
    self:_fallAll(dt)
  end
  return point
end

-- quaternion of Rx(pitch) * Ry(yaw) (the holder's grip rotation), no allocation
function M:_gripQuat(I)
  local px, yy = finite(I.TABLET_GRIP_PITCH), finite(I.TABLET_GRIP_YAW)
  local sx, cx = math.sin(px / 2), math.cos(px / 2)
  local sy, cy = math.sin(yy / 2), math.cos(yy / 2)
  -- q = qx * qy,  qx = (sx,0,0,cx), qy = (0,sy,0,cy)
  return sx * cy, cx * sy, sx * sy, cx * cy
end

-- no-rig samples: the drawn index tip and the wrist point (front hand only)
function M:_fallbackPen(tipX, tipY, tipZ, qx, qy, qz, qw, rpx, rpy, rpz)
  local P = self.p
  local m, a = self.m, self.anchor
  local best = 0
  for k = 1, 2 do
    local x, y, z, r
    if k == 1 then x, y, z, r = tipX, tipY, tipZ, P.RADII.tip
    else
      local ax, ay, az = qrot(qx, qy, qz, qw, self.px, self.py, self.pz)
      x, y, z, r = rpx + ax, rpy + ay, rpz + az, P.RADII.wrist
    end
    local dx, dy, dz = x - a[1], y - a[2], z - a[3]
    local lx = m[1] * dx + m[4] * dy + m[7] * dz
    local ly = m[2] * dx + m[5] * dy + m[8] * dz
    local lz = m[3] * dx + m[6] * dy + m[9] * dz
    local ex, ez = P.BODY_HX - abs(lx), P.BODY_HZ - abs(lz)
    local edge = (ex < ez and ex or ez) + r
    local pen = P.BODY_FRONT + r + P.CLAMP_OFFSET - ly
    if pen > 0 and edge > -P.RECT_BLEND then
      pen = pen * smooth((edge + P.RECT_BLEND) / P.RECT_BLEND)
      if pen > best then best = pen end
    end
  end
  return best
end

-- amount: rises at once to the target, falls exponentially. target 0 = no contact this frame.
function M:_fall(slot, dt, target)
  local a = slot.amount
  if target >= a then a = target
  else a = target + (a - target) * exp(-dt / self.p.RELEASE_TAU) end
  if a < 1e-5 then a = 0 end
  slot.amount = a
  if a > 0 then
    self.stats.clampFrames = self.stats.clampFrames + 1
    if a > self.stats.maxShift then self.stats.maxShift = a end
  end
end
function M:_fallAll(dt)
  self:_fall(self.slots.left, dt, 0)
  self:_fall(self.slots.right, dt, 0)
end

-- Called once per frame by the compat after the interaction update. If pick() did not run (tablet put away,
-- tracking lost, watch mode) the shifts only decay.
function M:endFrame(dt)
  if not self.picked then
    self.onTablet = false
    self.pinch = 0
    self.pinchDown = false
    self.trigLatch = false
    dt = finite(dt, 0)
    if dt < 0 or dt > 0.25 then dt = 1 / 72 end
    self:_fallAll(dt)
  end
  self.picked = false
end

function M:reset()
  for _, s in pairs(self.slots) do s.amount, s.latch = 0, 1 end
  self.picked, self.onTablet, self.src = false, false, nil
  self.pinchDown, self.pinch, self.trigLatch, self.flashLeft = false, 0, false, 0
end

-- true while the ray is on the glass.
function M:claiming() return self.onTablet == true end

-- v1 compatibility for status readers: the pointing hand's shift
function M:shift() return self.slots[self.side].amount end

-- QuestHandsRenderer hook. model: the final hand model matrix (row-major 4x4 as a 16-array, translation at 4/8/12);
-- world: worldFromLocal. Returns `model` itself when there is nothing to do, else this instance's per-side scratch copy
-- shifted along the tablet normal (away from the body). Never writes to `model`. Every pose is shifted (v2): the
-- clamp does not look at grip, trigger or the semantic flags.
function M:adjustModel(model, world, side, semantic)
  local slot = self.slots[side]
  if not slot then return model end
  local a = slot.amount
  if a <= 0 or type(model) ~= "table" or type(world) ~= "table" then return model end
  local out = self.out[side]
  for i = 1, 16 do out[i] = model[i] end
  local sx, sy, sz = slot.sx * a, slot.sy * a, slot.sz * a
  out[4] = out[4] + world[1] * sx + world[2] * sy + world[3] * sz
  out[8] = out[8] + world[5] * sx + world[6] * sy + world[7] * sz
  out[12] = out[12] + world[9] * sx + world[10] * sy + world[11] * sz
  return out
end

return M
