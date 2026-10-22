-- FRLG_VOXEL battle-only cutaway, anchored in world cells.
-- The prepared common eye, selected occluder bounds and battler card bounds
-- are shared by both eyes. Head rotation never changes which world fragments
-- are removed. Physical movement updates the common eye on the next prepare.
-- Near clearing is a metre-sized sphere; sight clearing is a world ray/AABB
-- corridor ending before the battlers. Selected volumes clear only themselves.
-- Synthetic stages additionally clear their existing stage world volume.
-- The floor guard and ordinary field shaders remain unchanged.
-- Missing shader anchors/common eye fail closed to the regular world draw.
local V = ...
local Shaders = V.require("render/Shaders")
local TreeView = V.require("render/FrlgTreeView")

local BattleCut = {}
BattleCut.__index = BattleCut

BattleCut.ANCHOR_CLIP = "highp vec4 p = u_mvp * vertex_position;"
BattleCut.ANCHOR_EFFECT = "vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc)\n{"
BattleCut.VARYING = "varying LOVE_HIGHP_OR_MEDIUMP vec3 v_cutWorld;\nuniform highp vec3 u_cutOrigin;\n"
BattleCut.OCC = 8
BattleCut.UNIFORMS = [[
uniform highp vec4 u_cutEye;
uniform highp vec4 u_cutA0;
uniform highp vec4 u_cutA1;
uniform highp vec4 u_cutB0;
uniform highp vec4 u_cutB1;
uniform highp vec4 u_cutD;
uniform mediump float u_cutOn;
uniform highp vec4 u_occR[8];
uniform highp vec4 u_occW[8];
// World ray/AABB entry. A zero direction never divides or invents a hit.
highp float cutEntry(highp vec3 delta, highp vec3 lo, highp vec3 hi) {
  highp float enter = 0.0;
  highp float leave = 1000000.0;
  for (int axis = 0; axis < 3; axis++) {
    highp float d = delta[axis];
    highp float e = u_cutEye[axis];
    if (abs(d) < 0.00001) {
      if (e < lo[axis] || e > hi[axis]) return -1.0;
    } else {
      highp float a = (lo[axis] - e) / d;
      highp float b = (hi[axis] - e) / d;
      enter = max(enter, min(a, b));
      leave = min(leave, max(a, b));
    }
  }
  return leave >= enter ? enter : -1.0;
}
bool cutInside(highp vec3 p, highp vec4 lo, highp vec4 hi) {
  return lo.w > 0.5 && all(greaterThanEqual(p, lo.xyz)) && all(lessThanEqual(p, hi.xyz));
}
bool cutCorridor(highp vec3 delta, highp float distanceToEye, highp vec4 lo, highp vec4 hi) {
  if (lo.w < 0.5) return false;
  highp float entry = cutEntry(delta, lo.xyz, hi.xyz);
  return entry > 0.0 && distanceToEye < hi.w;
}
]]
BattleCut.TEST = [[
  if (u_cutOn > 0.5 && v_y > u_cutD.w) {
    highp vec3 delta = v_cutWorld - u_cutEye.xyz;
    highp float distanceToEye = length(delta);
    if (distanceToEye < u_cutD.z) discard;
    if (cutCorridor(delta, distanceToEye, u_cutA0, u_cutA1)) discard;
    if (u_cutD.y < 0.5 && cutCorridor(delta, distanceToEye, u_cutB0, u_cutB1)) discard;
    if (u_cutD.y > 0.5 && cutInside(v_cutWorld, u_cutB0, u_cutB1)) discard;
    for (int i = 0; i < 8; i++) {
      if (cutInside(v_cutWorld, u_occR[i], u_occW[i])) discard;
    }
  }
]]

BattleCut.NEAR_M = 1.2          -- anything this close to the eye (above the floor) is cut
BattleCut.NEAR_SYNTH_M = 1.8
BattleCut.DEPTH_MARGIN_M = 0.4  -- cut stops this far in front of a battler group
BattleCut.NDC_MARGIN = 0.03
BattleCut.FLOOR_ABOVE = 0.12    -- cells above the arena floor where cutting starts
BattleCut.OCC_MARGIN_M = 0.15   -- depth slab margin around an occluder
BattleCut.NEAR_W = 0.05 -- legacy projection diagnostics only
BattleCut.METRES_PER_CELL = 1.6 -- Camera.METRES_PER_CELL, battle life size
BattleCut.STEREO_MARGIN_M = 0.08 -- base shared-eye target edge allowance
BattleCut.HALF_IPD_M = 0.04 -- covers up to80mm physical eye separation
BattleCut.OCC_Y_MARGIN = 0.05   -- height margin around an occluder (cells)

local function findOnce(s, pat)
  local a = s:find(pat, 1, true)
  if not a then return nil end
  if s:find(pat, a + #pat, true) then return nil end
  return a
end

-- Pure: the cut variant of one of Shaders.lua's world shader literals.
-- Returns the source, or nil and a reason.
function BattleCut.assemble(src)
  if type(src) ~= "string" then return nil, "no source" end
  if src:find("v_cutWorld", 1, true) then return nil, "already has a cut" end
  local a = findOnce(src, BattleCut.ANCHOR_CLIP)
  local b = findOnce(src, BattleCut.ANCHOR_EFFECT)
  if not (a and b) then return nil, "shader anchors not found (Shaders.lua changed?)" end
  if not src:find("varying mediump float v_y;", 1, true) then return nil, "v_y varying not found" end
  local out = src:sub(1, a - 1) .. BattleCut.ANCHOR_CLIP .. "\n  v_cutWorld = vertex_position.xyz + u_cutOrigin;"
    .. src:sub(a + #BattleCut.ANCHOR_CLIP)
  local b2 = out:find(BattleCut.ANCHOR_EFFECT, 1, true)
  out = out:sub(1, b2 - 1) .. BattleCut.UNIFORMS .. BattleCut.ANCHOR_EFFECT .. "\n" .. BattleCut.TEST
    .. out:sub(b2 + #BattleCut.ANCHOR_EFFECT)
  return BattleCut.VARYING .. out
end

function BattleCut.new(opts)
  opts = opts or {}
  return setmetatable({ log = opts.log or print, variants = nil, broken = nil, active = false,
    count = 0 }, BattleCut)
end

-- Compiled { OPAQUE, CUTOUT } cut variants, or nil when unavailable.
function BattleCut:shaders()
  if self.variants then return self.variants end
  if self.broken then return nil end
  local out = {}
  for _, kind in ipairs({ "OPAQUE", "CUTOUT" }) do
    local src, why = BattleCut.assemble(kind=="CUTOUT" and TreeView.source(Shaders) or Shaders[kind])
    if not src then
      self.broken = kind .. ": " .. tostring(why)
      break
    end
    local ok, sh = pcall(love.graphics.newShader, src)
    if not ok or not sh then
      self.broken = kind .. ": " .. tostring(sh)
      break
    end
    out[kind] = sh
  end
  if self.broken then
    self.log("[FRLG_VOXEL] battle cutaway off (battles still 3D): " .. self.broken)
    return nil
  end
  self.variants = out
  return out
end

-- Pure: clip-space projection of world point (x, y, z) by the row-major vp.
local function project(vp, x, y, z)
  local cx = vp[1] * x + vp[2] * y + vp[3] * z + vp[4]
  local cy = vp[5] * x + vp[6] * y + vp[7] * z + vp[8]
  local cw = vp[13] * x + vp[14] * y + vp[15] * z + vp[16]
  return cx, cy, cw
end
BattleCut.project = project

-- Pure: screen rectangle (NDC) and nearest/farthest clip w of a point set.
-- Points behind the eye (w <= 0.05) are skipped. Returns rect {x0,y0,x1,y1},
-- wMin, wMax, or nil when no point is in front.
function BattleCut.bounds(vp, points)
  local x0, y0, x1, y1, wMin, wMax
  for _, p in ipairs(points) do
    local cx, cy, cw = project(vp, p[1], p[2], p[3])
    if cw > 0.05 then
      local nx, ny = cx / cw, cy / cw
      x0 = (x0 == nil or nx < x0) and nx or x0
      x1 = (x1 == nil or nx > x1) and nx or x1
      y0 = (y0 == nil or ny < y0) and ny or y0
      y1 = (y1 == nil or ny > y1) and ny or y1
      wMin = (wMin == nil or cw < wMin) and cw or wMin
      wMax = (wMax == nil or cw > wMax) and cw or wMax
    end
  end
  if not x0 then return nil end
  return { x0, y0, x1, y1 }, wMin, wMax
end

-- The cut geometry is prepared in root-map cells around ONE common eye.
-- Eye VP remains a caller argument for compatibility, never a mask input.
local ZERO = { 0, 0, 0, 0 }
local function worldBounds(points, pad, ypad)
  if not points or #points == 0 then return ZERO, ZERO end
  local lo, hi = {math.huge,math.huge,math.huge,1}, {-math.huge,-math.huge,-math.huge,1}
  for _,p in ipairs(points)do for i=1,3 do lo[i]=math.min(lo[i],p[i]);hi[i]=math.max(hi[i],p[i])end end
  for i=1,3 do local m=i==2 and (ypad or pad)or pad;lo[i]=lo[i]-m;hi[i]=hi[i]+m end
  return lo,hi
end
BattleCut.worldBounds=worldBounds
-- A fixed source aperture covers either physical eye's sight line outside
-- the near sphere. Expand only angular bounds; the stopping distance uses
-- the original, unexpanded card bounds (no depth margin drift).
local function targetBounds(points, eye, near)
  local lo,hi=worldBounds(points,0)
  if lo[4]<0.5 then return lo,hi end
  local pos={eye.x,eye.y,eye.z};local far2,nearest2=0,0
  for _,p in ipairs(points)do local d2=0;for j=1,3 do d2=d2+(p[j]-pos[j])^2 end;far2=math.max(far2,d2)end
  for j=1,3 do local d=math.max(lo[j]-pos[j],0,pos[j]-hi[j]);nearest2=nearest2+d*d end
  local m=BattleCut.METRES_PER_CELL
  local pad=BattleCut.STEREO_MARGIN_M/m+BattleCut.HALF_IPD_M/m*math.max(0,math.sqrt(far2)/near-1)
  for j=1,3 do lo[j]=lo[j]-pad;hi[j]=hi[j]+pad end
  hi[4]=math.max(0,math.sqrt(nearest2)-BattleCut.DEPTH_MARGIN_M/m)
  return lo,hi
end
function BattleCut.occRects(_, occ)
  local lows, highs = {}, {}
  for i=1,BattleCut.OCC do
    lows[i],highs[i]=worldBounds(occ and occ[i],BattleCut.OCC_MARGIN_M/BattleCut.METRES_PER_CELL,BattleCut.OCC_Y_MARGIN)
  end
  return {rects=lows,slabs=highs}
end
function BattleCut.uniforms(_, spec)
  local eye=spec.eye
  if not(eye and type(eye.x)=='number'and type(eye.y)=='number'and type(eye.z)=='number')then return nil,'missing common battle eye'end
  local m=BattleCut.METRES_PER_CELL
  local pad=BattleCut.STEREO_MARGIN_M/m
  local near=(spec.synth and BattleCut.NEAR_SYNTH_M or BattleCut.NEAR_M)/m
  local a0,a1=targetBounds(spec.synth or spec.own,eye,near)
  local b0,b1
  if spec.synth then b0,b1=worldBounds(spec.synth,pad)else b0,b1=targetBounds(spec.foe,eye,near)end
  return {a0=a0,a1=a1,b0=b0,b1=b1,eye={eye.x,eye.y,eye.z,1},
    d={BattleCut.DEPTH_MARGIN_M/m,spec.synth and 1 or 0,near,
      (spec.floorY or 0)+BattleCut.FLOOR_ABOVE},occR=BattleCut.occRects(nil,spec.occ)}
end

-- Per eye, around Scene:draw: returns true when the cut is active.
function BattleCut:begin(env, spec)
  if not spec then self:finish(); return false end
  local v = self:shaders()
  if not v then return false end
  local u = BattleCut.uniforms(env.vp, spec)
  if not u then self:finish(); return false end
  local occ = u.occR or BattleCut.occRects(env.vp, nil)
  for _, sh in pairs(v) do
    Shaders.send(sh, "u_cutEye", u.eye)
    Shaders.send(sh, "u_cutOrigin", {0,0,0})
    Shaders.send(sh, "u_cutA0", u.a0)
    Shaders.send(sh, "u_cutA1", u.a1)
    Shaders.send(sh, "u_cutB0", u.b0)
    Shaders.send(sh, "u_cutB1", u.b1)
    Shaders.send(sh, "u_cutD", u.d)
    Shaders.send(sh, "u_cutOn", 1)
    Shaders.send(sh, "u_occR", unpack(occ.rects))
    Shaders.send(sh, "u_occW", unpack(occ.slabs))
  end
  Shaders.override = v
  self.active = true
  self.count = self.count + 1
  self.last = u
  return true
end

function BattleCut:finish()
  if self.active and self.variants then
    for _,sh in pairs(self.variants)do Shaders.send(sh,"u_cutOn",0)end
  end
  if self.active or Shaders.override then Shaders.override = nil end
  self.active = false
end

function BattleCut:release()
  self:finish()
  if self.variants then
    for _, sh in pairs(self.variants) do if sh.release then pcall(sh.release, sh) end end
  end
  self.variants, self.broken = nil, nil
end

return BattleCut
