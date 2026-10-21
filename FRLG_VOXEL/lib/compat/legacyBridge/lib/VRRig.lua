-- W4 P2: copied verbatim (no logic changes) from the fl16 game.love lab copy
-- at source/mods/BATTLE_ART_QUEST_COMPAT/lib/VRRig.lua
-- (local verified crystal-fishing-20260925/fl16/game.love, per the
-- Q1 fl16-payload decision -- w4/P2_DECISIONS.md). Self-contained: only V.require
-- of sibling lib files here, no mod.find, no Gen2-only engine requires, so it needed
-- no edit to serve VRITK_FRLG_HOST as well as BATTLE_ART_QUEST_COMPAT.
-- VR: the pose arithmetic -- how a headset eye becomes one of this mod's
-- cameras. Pure math on purpose: no FFI, no OpenXR types, nothing a
-- headless test cannot hold still. Everything device-shaped stays in
-- VRXR/VRGL; everything world-shaped is here.
--
-- Two ways the world can sit around a headset, and they mirror the VOXEL
-- ladder exactly:
--
--   DIORAMA   every orbit rung. The map is a tabletop miniature: a point
--             of the world (the view centre) is pinned VIEW_DIST away
--             along the rung's own viewing angle (dioramaAnchor), at the
--             scale that reproduces the flat screen's framing
--             (dioramaScale) -- so at rest the model presents exactly as
--             the standard view does, and the head moves freely around it
--             -- lean in and the town grows, walk around the table and
--             see the far side of the buildings honest occlusion has been
--             hiding.
--
--   FIRST_PERSON   the 1ST rung. The player's head is pinned to where the
--             headset started, at FP_SCALE, so a 16-pixel person stands
--             about 1.6 m tall and a cell is a stride. The HMD's own
--             orientation becomes FirstPerson's yaw and pitch, so movement
--             stays "push forward, go where you look" through the same
--             FreeMove the flat screen uses.
--
-- SPACES AND UNITS. OpenXR LOCAL space is metres, +Y up, -Z the way the
-- head faced at session start. World space is world PIXELS, +Y up, +Z
-- south. The two are aligned axis-for-axis -- "away from you" is north --
-- so the whole mapping is one translate-and-scale:
--
--   worldFromXr(p) = pivot + s * (p - anchor)
--
-- with `pivot` a world point, `anchor` the LOCAL-space point pinned to it,
-- and `s` the scale in px/m. An eye's camera is then
--
--   worldFromEye = T(pivot) * S(s) * T(-anchor) * T(pose.pos) * R(pose.q)
--   view         = the same chain inverted piece by rigid piece
--
-- and the VIEW deliberately ends in METRES: it un-scales the world, so eye
-- space -- where the projection's near and far live -- is real-world
-- metres whatever the mode's scale. Depth precision and clip planes stay
-- sane at both 10 px/m and 128 px/m.

-- the mod namespace (see main.lua): V.require loads a sibling module
local V = ...

local Mat4 = V.require("Mat4")

local VRRig = {}

-- Battle Art 1.10 intentionally keeps its public Mat4 module limited to the
-- transforms used by the flat renderer, so it no longer exposes fromQuat.
-- Keep the OpenXR-only conversion inside the Quest compatibility boundary
-- instead of adding a VR method back to the official Battle Art module.
local function fromQuat(x, y, z, w)
  x, y, z, w = tonumber(x) or 0, tonumber(y) or 0,
    tonumber(z) or 0, tonumber(w) or 1
  local length = math.sqrt(x * x + y * y + z * z + w * w)
  if length < 1e-12 then x, y, z, w, length = 0, 0, 0, 1, 1 end
  x, y, z, w = x / length, y / length, z / length, w / length
  local xx, yy, zz = x * x, y * y, z * z
  local xy, xz, yz = x * y, x * z, y * z
  local wx, wy, wz = w * x, w * y, w * z
  return {
    1 - 2 * (yy + zz), 2 * (xy - wz),     2 * (xz + wy),     0,
    2 * (xy + wz),     1 - 2 * (xx + zz), 2 * (yz - wx),     0,
    2 * (xz - wy),     2 * (yz + wx),     1 - 2 * (xx + yy), 0,
    0,                  0,                  0,                  1,
  }
end

-- Battle Art 1.10 also removed the two OpenXR-only matrix helpers used by
-- the stereo camera. Keep exact local copies at the compatibility boundary
-- rather than mutating or depending on Battle Art's private math surface.
local function transpose(m)
  return {
    m[1], m[5], m[9],  m[13],
    m[2], m[6], m[10], m[14],
    m[3], m[7], m[11], m[15],
    m[4], m[8], m[12], m[16],
  }
end

-- Right-handed OpenXR off-centre perspective projected into GL clip space
-- (z in [-1, 1]). Each eye needs its own four signed half-angles; reducing
-- this to one symmetric FOV would introduce a subtle stereo mismatch.
local function fovProjection(angleLeft, angleRight, angleUp, angleDown,
                             near, far)
  local l, r = math.tan(angleLeft), math.tan(angleRight)
  local u, d = math.tan(angleUp), math.tan(angleDown)
  local width, height = r - l, u - d
  local depth = near - far
  return {
    2 / width, 0, (r + l) / width, 0,
    0, 2 / height, (u + d) / height, 0,
    0, 0, (far + near) / depth, (2 * far * near) / depth,
    0, 0, -1, 0,
  }
end

-- first person's life size: 10 px/m makes a 16 px tile a 1.6 m stride
VRRig.FP_SCALE = 10

-- How far the diorama's pivot sits from the resting head, in metres --
-- the arm's-length viewing distance the anchor and the scale below are
-- both built around.
VRRig.VIEW_DIST = 0.95

-- Where, in LOCAL metres, the diorama's pivot sits: VIEW_DIST away along
-- the RUNG'S OWN viewing angle. The flat screen's camera looks at the
-- world `a` radians off vertical; putting the pivot at (-d cos a) below
-- and (-d sin a) ahead of the resting head reproduces exactly that line
-- of sight -- step onto the 35 rung and the table presents at 35 degrees,
-- onto 75 and it rises toward eye level, easing between them as the rung
-- tween runs.
--
-- `off` is the grab-drag adjustment, in metres of LOCAL travel -- where
-- the player has carried the model to. A bare number is the height alone,
-- which is what the standard mode's one-axis drag has always sent; the
-- DIORAMA modes hand over all three (see lib/Diorama). Positive Y drags
-- the world up: the anchor is the LOCAL point pinned to the pivot, so
-- moving it moves the model with the hand rather than against it.
function VRRig.dioramaAnchor(angleRad, off)
  local d = VRRig.VIEW_DIST
  local ox, oy, oz = 0, 0, 0
  if type(off) == "table" then
    ox, oy, oz = off[1] or 0, off[2] or 0, off[3] or 0
  elseif type(off) == "number" then
    oy = off
  end
  return { ox,
           -d * math.cos(angleRad or 0) + oy,
           -d * math.sin(angleRad or 0) + oz }
end

-- The diorama's scale, in world px per metre: the one that makes the
-- table subtend the same field the flat screen frames. The flat camera
-- fits `vh` world pixels in a lens of focal `focal` (Voxel.FOCAL); at
-- VIEW_DIST the same framing needs vh * focal / d pixels to the metre --
-- so the resting head sees the standard view's angle AND its apparent
-- size, and the zoom rows (which change vh) keep working in VR.
function VRRig.dioramaScale(vh, focal)
  return math.max(16, (vh or 288) * (focal or 1) / VRRig.VIEW_DIST)
end

-- kept as the test suite's fixed example anchor, and as the fallback for
-- an angle nobody supplied
VRRig.TABLE = { 0, -0.45, -0.75 }

-- ------- the battle mount
--
-- A staged fight snaps the headset to an OVER-THE-SHOULDER seat: the same
-- line the flat battle camera stands on (eye through focus, so the player's
-- mon is near-left and the foe far-right exactly as the flat shot frames
-- them), but pulled in to BATTLE_DIST -- the flat rig is a long lens from
-- fifteen metres back, and a headset's lens is its own eyes, so keeping the
-- distance would shrink the fight to a stage seen from the back row. 66 px
-- is the wide rig's own standing distance: six and a half metres at life
-- scale, close enough to fill the view, far enough to hold both mons in it
-- -- and short enough to stay inside the small rooms the wide rig exists
-- for.
VRRig.BATTLE_DIST = 66

-- Where the head sits for a staged fight, and which way the mapping must
-- turn so that seat FACES it. Returns the pivot (world px -- pin the XR
-- origin here at FP_SCALE) and the yaw for eyeCamera: the flat camera
-- looks along focus - eye, the resting headset looks along XR -Z (world
-- north), and the yaw is what closes that gap.
function VRRig.battleMount(eye, focus)
  local dx = eye[1] - focus[1]
  local dy = eye[2] - focus[2]
  local dz = eye[3] - focus[3]
  local len = math.sqrt(dx * dx + dy * dy + dz * dz)
  if len < 1e-6 then return { eye[1], eye[2], eye[3] }, 0 end
  local k = VRRig.BATTLE_DIST / len
  -- Ry(yaw) sends XR forward (0,0,-1) to (-sin yaw, 0, -cos yaw); aiming
  -- that along the horizontal of focus - eye solves to atan2 of eye - focus
  return { focus[1] + dx * k, focus[2] + dy * k, focus[3] + dz * k },
         math.atan2(dx, dz)
end

-- eye-space clip planes, in metres (see the unit note above)
VRRig.NEAR = 0.05
VRRig.FAR = 400
-- Companion panoramas can sit much farther away than Battle Art's ordinary
-- terrain. Keep a second projection with the exact same OpenXR eye frustum,
-- but enough metric depth for a 16,384-world-pixel backdrop at FP_SCALE.
-- The stereo adapter applies it only while a background companion explicitly
-- substitutes its own extended-clip matrix; ordinary terrain keeps FAR above.
VRRig.BACKGROUND_FAR = 2048

-- ------- one eye's camera

-- Build the placed-camera record for one eye.
--
--   pose    { pos = {x,y,z} metres, quat = {x,y,z,w} }  (OpenXR LOCAL)
--   fov     { angleLeft, angleRight, angleUp, angleDown }  signed radians
--   pivot   {x,y,z} world px pinned to `anchor`
--   anchor  {x,y,z} LOCAL metres (VRRig.TABLE, or 0,0,0 for first person)
--   scale   world px per metre
--   yaw     optional turn of the whole mapping about +Y, radians: the
--           battle mount faces the resting head at the arena with it.
--           worldFromXr(p) becomes pivot + s * Ry(yaw) * (p - anchor).
--   curveK  the world curve this eye is to be drawn with (see WorldCurve);
--           omitted is 0, the curve DECLINED.
--
-- Off by default because standing inside a bent world is what first person
-- already declines on the flat screen, and the battle mount is a placed
-- shot. The DIORAMA modes are the case that wants it and asks for it: the
-- model is a thing being looked AT, so bending it into a little globe is
-- the whole point rather than a broken tabletop -- and it is what the left
-- stick's click throws (see lib/VR). Passed in rather than read here
-- because a rig has no business deciding what a row means.
--
-- Beware the shape of the answer: Voxel3D reads `camera.curve` with `or`,
-- and 0 is TRUE in Lua, so a 0 here really does pin the bend off -- which
-- is exactly why the diorama's curve did nothing until this became a
-- parameter.
--
-- Returns a table shaped for Voxel3D.camera: raw view + proj, the world
-- eye and focus (for setLook, the water's lean, the sky), fov as a
-- vertical span, and that curve.
function VRRig.eyeCamera(pose, fov, pivot, anchor, scale, yaw, curveK)
  local px, py, pz = pose.pos[1], pose.pos[2], pose.pos[3]
  local q = pose.quat
  local R = fromQuat(q[1], q[2], q[3], q[4])

  -- view = R^T * T(-pos) * T(anchor) * Ry(-yaw) * S(1/s) * T(-pivot)
  local view = Mat4.mul(transpose(R), Mat4.translate(-px, -py, -pz))
  view = Mat4.mul(view, Mat4.translate(anchor[1], anchor[2], anchor[3]))
  if yaw and yaw ~= 0 then
    view = Mat4.mul(view, Mat4.rotateY(-yaw))
  end
  view = Mat4.mul(view, Mat4.scale(1 / scale, 1 / scale, 1 / scale))
  view = Mat4.mul(view, Mat4.translate(-pivot[1], -pivot[2], -pivot[3]))

  local proj = fovProjection(fov.angleLeft, fov.angleRight,
                             fov.angleUp, fov.angleDown,
                             VRRig.NEAR, VRRig.FAR)
  local backgroundProj = fovProjection(
    fov.angleLeft, fov.angleRight, fov.angleUp, fov.angleDown,
    VRRig.NEAR, VRRig.BACKGROUND_FAR)

  -- The eye's RAY FAN, in world axes: the direction a canvas point
  -- (u, v in 0..1, left-to-right and top-to-bottom) looks along is
  -- base + u * du + v * dv. The sky reads its per-pixel TRUE elevation
  -- off this (a real skybox cannot be painted from any per-frame row
  -- mapping -- that is exact only at the view's own azimuth and swims
  -- everywhere else). Directions only, so the mapping's scale drops out;
  -- the yaw must not (the battle mount and the snap turn swing the world).
  local Rw = R
  if yaw and yaw ~= 0 then Rw = Mat4.mul(Mat4.rotateY(yaw), R) end
  local tl, tr = math.tan(fov.angleLeft), math.tan(fov.angleRight)
  local tu, td = math.tan(fov.angleUp), math.tan(fov.angleDown)
  -- world columns of the head's rotation: right (X), up (Y), forward (-Z)
  local rxc, ryc, rzc = Rw[1], Rw[5], Rw[9]
  local uxc, uyc, uzc = Rw[2], Rw[6], Rw[10]
  local fxc, fyc, fzc = -Rw[3], -Rw[7], -Rw[11]
  local skyRay = {
    base = { fxc + rxc * tl + uxc * tu,
             fyc + ryc * tl + uyc * tu,
             fzc + rzc * tl + uzc * tu },
    du = { rxc * (tr - tl), ryc * (tr - tl), rzc * (tr - tl) },
    dv = { uxc * (td - tu), uyc * (td - tu), uzc * (td - tu) },
  }

  -- the eye and its forward, in world pixels: worldFromEye applied to the
  -- origin and to -Z
  local ax, ay, az = px - anchor[1], py - anchor[2], pz - anchor[3]
  -- R's third column is the eye's +Z axis; forward is its negation
  local fx, fy, fz = -R[3], -R[7], -R[11]
  if yaw and yaw ~= 0 then
    local c, s = math.cos(yaw), math.sin(yaw)
    ax, az = c * ax + s * az, -s * ax + c * az
    fx, fz = c * fx + s * fz, -s * fx + c * fz
  end
  local ex = pivot[1] + scale * ax
  local ey = pivot[2] + scale * ay
  local ez = pivot[3] + scale * az

  return {
    view = view,
    proj = proj,
    backgroundProj = backgroundProj,
    eye = { ex, ey, ez },
    focus = { ex + fx * scale, ey + fy * scale, ez + fz * scale },
    fov = fov.angleUp - fov.angleDown,
    curve = curveK or 0,
    skyRay = skyRay,
  }
end

-- Centre-of-head ray in voxel-world coordinates. Wilds uses this to resolve
-- which visible Pokémon the rear scanner or a forward Ball release targets.
function VRRig.headGaze(eyes)
  if type(eyes) ~= "table" or not eyes[1] or not eyes[2] then return nil end
  local a = eyes[1].camera or eyes[1]
  local b = eyes[2].camera or eyes[2]
  if not (a and b and a.eye and b.eye and a.focus and b.focus) then return nil end
  local ox = ((tonumber(a.eye[1]) or 0) + (tonumber(b.eye[1]) or 0)) * 0.5
  local oy = ((tonumber(a.eye[2]) or 0) + (tonumber(b.eye[2]) or 0)) * 0.5
  local oz = ((tonumber(a.eye[3]) or 0) + (tonumber(b.eye[3]) or 0)) * 0.5
  local dx = ((a.focus[1] - a.eye[1]) + (b.focus[1] - b.eye[1])) * 0.5
  local dy = ((a.focus[2] - a.eye[2]) + (b.focus[2] - b.eye[2])) * 0.5
  local dz = ((a.focus[3] - a.eye[3]) + (b.focus[3] - b.eye[3])) * 0.5
  local length = math.sqrt(dx * dx + dy * dy + dz * dz)
  if length < 1e-6 then return nil end
  return { origin = { ox, oy, oz },
    direction = { dx / length, dy / length, dz / length } }
end

-- The WORLD model matrix a hand-held prop stands on: worldFromXr (the
-- same mapping the eyes use -- so the prop is exactly where the hand is,
-- whatever mode the mapping is in) composed with the hand's own tracked
-- pose. A mesh authored in METRES rides it straight: the mapping's scale
-- is what turns metres into world pixels, so the prop keeps its real
-- size in the hand at the diorama's scale and at life scale alike.
--
--   model = T(pivot) * S(s) * Ry(yaw) * T(-anchor) * T(hand.pos) * R(hand.quat)
function VRRig.worldFromLocal(pivot, anchor, scale, yaw)
  local m = Mat4.translate(pivot[1], pivot[2], pivot[3])
  m = Mat4.mul(m, Mat4.scale(scale, scale, scale))
  if yaw and yaw ~= 0 then m = Mat4.mul(m, Mat4.rotateY(yaw)) end
  return Mat4.mul(m, Mat4.translate(-anchor[1], -anchor[2], -anchor[3]))
end

function VRRig.poseMatrix(pose)
  pose = type(pose) == "table" and pose or {}
  local p = pose.position or pose.pos or { 0, 0, 0 }
  local q = pose.orientation or pose.quat or { 0, 0, 0, 1 }
  local m = Mat4.translate(tonumber(p[1]) or 0, tonumber(p[2]) or 0,
    tonumber(p[3]) or 0)
  return Mat4.mul(m, fromQuat(q[1], q[2], q[3], q[4]))
end

-- Lab 51 ALLOC TRIM: VRRig.poseMatrix with out-params. Same expressions in
-- the same order (translate matrix times fromQuat matrix), so the result is
-- bit-identical; `out`, `tmpT` and `tmpR` are three distinct caller-owned
-- scratch matrices (nothing retains them).
local function fromQuatInto(out, x, y, z, w)
  x, y, z, w = tonumber(x) or 0, tonumber(y) or 0,
    tonumber(z) or 0, tonumber(w) or 1
  local length = math.sqrt(x * x + y * y + z * z + w * w)
  if length < 1e-12 then x, y, z, w, length = 0, 0, 0, 1, 1 end
  x, y, z, w = x / length, y / length, z / length, w / length
  local xx, yy, zz = x * x, y * y, z * z
  local xy, xz, yz = x * y, x * z, y * z
  local wx, wy, wz = w * x, w * y, w * z
  out[1], out[2], out[3], out[4] = 1 - 2 * (yy + zz), 2 * (xy - wz), 2 * (xz + wy), 0
  out[5], out[6], out[7], out[8] = 2 * (xy + wz), 1 - 2 * (xx + zz), 2 * (yz - wx), 0
  out[9], out[10], out[11], out[12] = 2 * (xz - wy), 2 * (yz + wx), 1 - 2 * (xx + yy), 0
  out[13], out[14], out[15], out[16] = 0, 0, 0, 1
  return out
end

local ZERO_POSITION, IDENTITY_QUAT = { 0, 0, 0 }, { 0, 0, 0, 1 }
function VRRig.poseMatrixInto(out, tmpT, tmpR, pose)
  if type(pose) ~= "table" then pose = nil end
  local p = pose and (pose.position or pose.pos) or ZERO_POSITION
  local q = pose and (pose.orientation or pose.quat) or IDENTITY_QUAT
  Mat4.translateInto(tmpT, tonumber(p[1]) or 0, tonumber(p[2]) or 0,
    tonumber(p[3]) or 0)
  fromQuatInto(tmpR, q[1], q[2], q[3], q[4])
  return Mat4.mulInto(out, tmpT, tmpR)
end

function VRRig.propMatrix(pose, pivot, anchor, scale, yaw)
  local m = VRRig.worldFromLocal(pivot, anchor, scale, yaw)
  return Mat4.mul(m, VRRig.poseMatrix(pose))
end

-- The flat compass numbers a head orientation implies, for driving
-- FirstPerson (and through it FreeMove) from the HMD: yaw in this mod's
-- convention (0 south, pi/2 east) and pitch positive-down.
function VRRig.headYawPitch(quat)
  local R = fromQuat(quat[1], quat[2], quat[3], quat[4])
  local fx, fy, fz = -R[3], -R[7], -R[11]
  local flat = math.sqrt(fx * fx + fz * fz)
  local yaw = flat > 1e-6 and math.atan2(fx, fz) or 0
  local pitch = -math.asin(math.max(-1, math.min(1, fy)))
  return yaw, pitch
end

-- The two pivots. First person pins the player's head; the diorama pins
-- the view centre at the ground plane. `gh` is the ground height under
-- the player (VoxelScene.groundAt), `eyeH` FirstPerson.EYE_HEIGHT.
function VRRig.fpPivot(pxTopLeft, pyTopLeft, gh, eyeH)
  return { pxTopLeft + 8, (gh or 0) + (eyeH or 13), pyTopLeft + 8 }
end

function VRRig.dioramaPivot(cx, cy)
  return { cx, 0, cy }
end

return VRRig
