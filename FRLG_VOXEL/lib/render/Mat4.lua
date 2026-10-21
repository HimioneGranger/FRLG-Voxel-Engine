-- FRLG_VOXEL: 4x4 matrix helpers. Flat 16-number tables, ROW-MAJOR, applied
-- to column vectors (p' = M * p). Sent to shaders with
-- shader:send(name, "row", m), the same convention the Quest-proven Gen2
-- stereo path uses. Pure math: no love, no requires (sandbox-safe).
local V = ...
local _ = V

local Mat4 = {}

local cos, sin, tan, sqrt = math.cos, math.sin, math.tan, math.sqrt

function Mat4.identity()
  return { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }
end

function Mat4.mul(a, b)
  local r = {}
  for i = 0, 3 do
    local a1, a2, a3, a4 = a[i * 4 + 1], a[i * 4 + 2], a[i * 4 + 3], a[i * 4 + 4]
    for j = 1, 4 do
      r[i * 4 + j] = a1 * b[j] + a2 * b[4 + j] + a3 * b[8 + j] + a4 * b[12 + j]
    end
  end
  return r
end

-- a * b * c * ...
function Mat4.chain(...)
  local n = select("#", ...)
  local m = (select(1, ...))
  for i = 2, n do m = Mat4.mul(m, (select(i, ...))) end
  return m
end

function Mat4.translate(x, y, z)
  return { 1, 0, 0, x, 0, 1, 0, y, 0, 0, 1, z, 0, 0, 0, 1 }
end

function Mat4.scale(sx, sy, sz)
  sy = sy or sx
  sz = sz or sx
  return { sx, 0, 0, 0, 0, sy, 0, 0, 0, 0, sz, 0, 0, 0, 0, 1 }
end

-- Right-handed rotation about +Y. rotY(a) maps (0,0,-1) to (-sin a, 0, -cos a).
function Mat4.rotY(a)
  local c, s = cos(a), sin(a)
  return { c, 0, s, 0, 0, 1, 0, 0, -s, 0, c, 0, 0, 0, 0, 1 }
end

function Mat4.rotX(a)
  local c, s = cos(a), sin(a)
  return { 1, 0, 0, 0, 0, c, -s, 0, 0, s, c, 0, 0, 0, 0, 1 }
end

-- Unit quaternion (x, y, z, w) -> rotation matrix.
function Mat4.fromQuat(x, y, z, w)
  x, y, z, w = tonumber(x) or 0, tonumber(y) or 0, tonumber(z) or 0, tonumber(w) or 1
  local len = sqrt(x * x + y * y + z * z + w * w)
  if len < 1e-12 then x, y, z, w, len = 0, 0, 0, 1, 1 end
  x, y, z, w = x / len, y / len, z / len, w / len
  local xx, yy, zz = x * x, y * y, z * z
  local xy, xz, yz = x * y, x * z, y * z
  local wx, wy, wz = w * x, w * y, w * z
  return {
    1 - 2 * (yy + zz), 2 * (xy - wz), 2 * (xz + wy), 0,
    2 * (xy + wz), 1 - 2 * (xx + zz), 2 * (yz - wx), 0,
    2 * (xz - wy), 2 * (yz + wx), 1 - 2 * (xx + yy), 0,
    0, 0, 0, 1,
  }
end

function Mat4.transpose(m)
  return {
    m[1], m[5], m[9], m[13],
    m[2], m[6], m[10], m[14],
    m[3], m[7], m[11], m[15],
    m[4], m[8], m[12], m[16],
  }
end

-- Off-centre perspective from the four signed OpenXR half-angles (radians),
-- right-handed, GL clip z in [-1, 1]. Each eye keeps its own asymmetric
-- frustum; collapsing it to one symmetric FOV mismatches the two eyes.
function Mat4.fovProjection(angleLeft, angleRight, angleUp, angleDown, near, far)
  local l, r = tan(angleLeft), tan(angleRight)
  local u, d = tan(angleUp), tan(angleDown)
  local w, h = r - l, u - d
  local depth = near - far
  return {
    2 / w, 0, (r + l) / w, 0,
    0, 2 / h, (u + d) / h, 0,
    0, 0, (far + near) / depth, (2 * far * near) / depth,
    0, 0, -1, 0,
  }
end

-- Symmetric perspective (desktop mono camera). fovy in radians.
function Mat4.perspective(fovy, aspect, near, far)
  local half = fovy / 2
  local hx = math.atan(tan(half) * aspect)
  return Mat4.fovProjection(-hx, hx, half, -half, near, far)
end

-- LOVE renders into a Canvas with the image stored top row first, so a GL
-- projection (clip +Y = up) lands upside down in the canvas. Negating clip Y
-- makes the canvas read upright when LOVE draws it, and QuestNativeGL's
-- blitToTexture flips it once more into the swapchain's GL orientation.
function Mat4.flipY(p)
  local r = {}
  for i = 1, 16 do r[i] = p[i] end
  r[5], r[6], r[7], r[8] = -p[5], -p[6], -p[7], -p[8]
  return r
end

function Mat4.transformPoint(m, x, y, z)
  local w = m[13] * x + m[14] * y + m[15] * z + m[16]
  if w == 0 then w = 1 end
  return (m[1] * x + m[2] * y + m[3] * z + m[4]) / w,
    (m[5] * x + m[6] * y + m[7] * z + m[8]) / w,
    (m[9] * x + m[10] * y + m[11] * z + m[12]) / w
end

-- Rotation-only part applied to a direction.
function Mat4.transformDir(m, x, y, z)
  return m[1] * x + m[2] * y + m[3] * z,
    m[5] * x + m[6] * y + m[7] * z,
    m[9] * x + m[10] * y + m[11] * z
end

-- Yaw (about +Y) of a quaternion's forward (-Z) direction, 0 = facing -Z.
function Mat4.quatYaw(q)
  if type(q) ~= "table" then return 0 end
  local m = Mat4.fromQuat(q[1], q[2], q[3], q[4])
  local fx, fz = -m[3], -m[11]
  if fx * fx + fz * fz < 1e-9 then return 0 end
  return math.atan2(-fx, -fz)
end

return Mat4
