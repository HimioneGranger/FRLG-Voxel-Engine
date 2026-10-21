-- FRLG_VOXEL (W6, battle phase P-B1): the battle cutaway.
--
-- World geometry between the seat and the battlers (trees, roofs, walls the
-- heightfield sight test cannot see) and around a synthetic stage is cut
-- away instead of rejecting the spot (user rule 2026-09-28). The cut is done
-- in the terrain shaders, only while a battle is staged:
--   * variants of render/Shaders.lua's OPAQUE and CUTOUT are assembled from
--     W2's own literals at three anchors (a clip-space varying, the cut
--     uniforms, and a discard test at the top of effect()); the everyday
--     field shaders are untouched (no discard added to OPAQUE, so mobile
--     early-z is kept outside battles);
--   * per eye, render/View.lua's scene draw uses them through the
--     Shaders.override hook (INTEGRATION_PATCH.md, Shaders.lua section);
--   * a fragment is discarded when it is above the arena floor AND either
--     nearer than NEAR metres to the eye, or inside a battler group's screen
--     rectangle and nearer than that group, or (round 2) inside one of up to
--     OCC occluder volumes' screen rectangle and depth slab: the trees,
--     buildings and clutter BattleOccluders picked between the seat and the
--     Pokemon (the mesher's tree units and building boxes).
-- If an anchor is missing (the shaders changed) or a variant fails to
-- compile, the cut is off (logged once) and battles still render in 3D.
-- GLES: no default-precision change; highp per variable only (memory: LOVE
-- GLES shader precision). The assembled text is checked offline by the ES
-- gate through w6/es-gate (see w6/REPORT.md).
local V = ...
local Shaders = V.require("render/Shaders")
local TreeView = V.require("render/FrlgTreeView")

local BattleCut = {}
BattleCut.__index = BattleCut

BattleCut.ANCHOR_CLIP = "highp vec4 p = u_mvp * vertex_position;"
BattleCut.ANCHOR_EFFECT = "vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc)\n{"
BattleCut.VARYING = "varying LOVE_HIGHP_OR_MEDIUMP vec3 v_cut;\n"
BattleCut.OCC = 8
BattleCut.UNIFORMS = [[
uniform highp vec4 u_cutA;
uniform highp vec4 u_cutB;
uniform highp vec4 u_cutD;
uniform mediump float u_cutOn;
uniform highp vec4 u_occR[8];
uniform highp vec4 u_occW[8];
]]
BattleCut.TEST = [[
  if (u_cutOn > 0.5 && v_y > u_cutD.w) {
    highp float cw = max(v_cut.z, 0.0001);
    highp vec2 ndc = v_cut.xy / cw;
    if (cw < u_cutD.z) discard;
    if (cw < u_cutD.x && ndc.x > u_cutA.x && ndc.x < u_cutA.z && ndc.y > u_cutA.y && ndc.y < u_cutA.w) discard;
    if (cw < u_cutD.y && ndc.x > u_cutB.x && ndc.x < u_cutB.z && ndc.y > u_cutB.y && ndc.y < u_cutB.w) discard;
    for (int i = 0; i < 8; i++) {
      highp vec4 orr = u_occR[i];
      highp vec4 ow = u_occW[i];
      if (cw > ow.x && cw < ow.y && v_y > ow.z && v_y < ow.w
          && ndc.x > orr.x && ndc.x < orr.z && ndc.y > orr.y && ndc.y < orr.w) discard;
    }
  }
]]

BattleCut.NEAR_M = 1.2          -- anything this close to the eye (above the floor) is cut
BattleCut.NEAR_SYNTH_M = 1.8
BattleCut.DEPTH_MARGIN_M = 0.4  -- cut stops this far in front of a battler group
BattleCut.NDC_MARGIN = 0.03
BattleCut.FLOOR_ABOVE = 0.12    -- cells above the arena floor where cutting starts
BattleCut.OCC_MARGIN_M = 0.15   -- depth slab margin around an occluder
BattleCut.NEAR_W = 0.05 -- shared near-eye clipping guard
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
  if src:find("v_cut", 1, true) then return nil, "already has a cut" end
  local a = findOnce(src, BattleCut.ANCHOR_CLIP)
  local b = findOnce(src, BattleCut.ANCHOR_EFFECT)
  if not (a and b) then return nil, "shader anchors not found (Shaders.lua changed?)" end
  if not src:find("varying mediump float v_y;", 1, true) then return nil, "v_y varying not found" end
  local out = src:sub(1, a - 1) .. BattleCut.ANCHOR_CLIP .. "\n  v_cut = p.xyw;"
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

local NONE = { 2, 2, -2, -2 } -- an empty rectangle: nothing is inside it

-- Pure: the uniforms for one eye. groups = { own = {points}, foe = {points} }
-- (card corners, world cells), or synth = {points} for a synthetic stage;
-- floorY = arena floor (cells). Returns { a, b, d } (vec4 each).
function BattleCut.uniforms(vp, spec)
  local m = BattleCut.NDC_MARGIN
  local dm = BattleCut.DEPTH_MARGIN_M
  local floorY = (spec.floorY or 0) + BattleCut.FLOOR_ABOVE
  local function grow(r) return { r[1] - m, r[2] - m, r[3] + m, r[4] + m } end
  if spec.synth then
    local r, _, wMax = BattleCut.bounds(vp, spec.synth)
    return {
      a = r and grow(r) or NONE, b = NONE,
      d = { r and (wMax + dm) or 0, 0, BattleCut.NEAR_SYNTH_M, floorY },
      occR = BattleCut.occRects(vp, spec.occ),
    }
  end
  local ra, wa = BattleCut.bounds(vp, spec.own or {})
  local rb, wb = BattleCut.bounds(vp, spec.foe or {})
  return {
    a = ra and grow(ra) or NONE, b = rb and grow(rb) or NONE,
    d = { ra and math.max(0, wa - dm) or 0, rb and math.max(0, wb - dm) or 0, BattleCut.NEAR_M, floorY },
    occR = BattleCut.occRects(vp, spec.occ),
  }
end

local NONE_W = { 0, 0, 0, 0 }
-- Pure: per-occluder cut rectangles and depth slabs for one eye. occ = list
-- of corner lists (8 world points each). Returns { rects = {vec4 x OCC},
-- slabs = {vec4 x OCC}: near w, far w, lowest y, highest y } (unused slots
-- never match). Round 3: the height range keeps a cut to the volume itself
-- (tall grass at the seat: the ground under it stays).
function BattleCut.occRects(vp, occ)
  local rects, slabs = {}, {}
  local m, om = BattleCut.NDC_MARGIN, BattleCut.OCC_MARGIN_M
  for i = 1, BattleCut.OCC do
    local pts = occ and occ[i]
    local r, wMin, wMax
    if pts then r, wMin, wMax = BattleCut.bounds(vp, pts) end
    if r then
      -- tree fix: a volume with corners at / behind the eye (a tree right next to the player) has no finite screen
      -- rectangle; the in-front corners alone gave a partial one and the tree was cut to a mosaic. It covers the
      -- screen from the eye out to its far corner instead.
      for _, q in ipairs(pts) do
        local _, _, cw = project(vp, q[1], q[2], q[3])
        if cw <= BattleCut.NEAR_W then
          r, wMin = { -2, -2, 2, 2 }, 0
          break
        end
      end
      local y0, y1 = math.huge, -math.huge
      for _, q in ipairs(pts) do
        if q[2] < y0 then y0 = q[2] end
        if q[2] > y1 then y1 = q[2] end
      end
      rects[i] = { r[1] - m, r[2] - m, r[3] + m, r[4] + m }
      slabs[i] = { math.max(0, wMin - om), wMax + om, y0 - BattleCut.OCC_Y_MARGIN, y1 + BattleCut.OCC_Y_MARGIN }
    else
      rects[i], slabs[i] = NONE, NONE_W
    end
  end
  return { rects = rects, slabs = slabs }
end

-- Per eye, around Scene:draw: returns true when the cut is active.
function BattleCut:begin(env, spec)
  if not spec then return false end
  local v = self:shaders()
  if not v then return false end
  local u = BattleCut.uniforms(env.vp, spec)
  local occ = u.occR or BattleCut.occRects(env.vp, nil)
  for _, sh in pairs(v) do
    Shaders.send(sh, "u_cutA", u.a)
    Shaders.send(sh, "u_cutB", u.b)
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
