-- VRITK_FRLG_HOST: converts FRLG_VOXEL's vrHost rig/eye (root cells,
-- metres) into VRITK's Gen2-shaped px frame (world px, 16 px per cell) --
-- vritk-hook/DESIGN.md 2b, the "per-frame context" and "Voxel3D stand-in"
-- sections. Formulas verified two ways: against DESIGN.md's own citations
-- (VRRig.lua:320-325, StereoRenderer.lua:299-301/334) and by re-deriving
-- them from Camera.lua's documented worldFromLocal identity (see
-- w4/tests/test_matrix_identities.lua, which already round-trips that
-- identity against FRLG_VOXEL's real Camera.lua/Mat4.lua).
--
--   pxPerCell = 16 (VK\lib\FishingPlay.lua:116's own cell*16+8; QC\lib
--     \VRRig.lua:101-102's FP_SCALE=10 px/m * 1.6 m/cell = 16 px/cell)
--   worldFromLocalPx = VRRig.worldFromLocal(
--       {16*anchor.x, 16*anchor.y, 16*anchor.z},   -- pivot, in world px
--       {pivot.x, pivot.y, pivot.z},                -- anchor, LOCAL metres
--       16 / rig.m,                                 -- scale, px per metre
--       rig.yaw)
--     = S(16) * ctx.worldFromLocal (a uniform scale commutes with Ry; BV's
--     Mat4.rotateY is the same matrix as FV's Mat4.rotY -- DESIGN.md 2b).
--     In first person, 16/m = 16/1.6 = 10 = VRRig.FP_SCALE exactly, which
--     is why no VRITK edit is needed for scale (DESIGN.md 0.1 point 3).
--   eyeVpPx = eye.vp * S(1/16)   -- a px point / 16 = the same cell point
--   eyePosPx = 16 * eye.pos
local V = ...

local Mat4 = V.require("Mat4")
local VRRig = V.require("VRRig")

local PxContext = {}

PxContext.PX_PER_CELL = 16

-- rig = ctx.rig from HostApi's layer ctx: {anchor={x,y,z}, pivot={x,y,z},
-- m, yaw, mode}. Returns the row-major worldFromLocalPx matrix, or nil if
-- rig is absent (e.g. the very first frame, or a desktop mock with no
-- camera attached yet).
function PxContext.worldFromLocalPx(rig)
  if type(rig) ~= "table" then return nil end
  local a, p = rig.anchor, rig.pivot
  if type(a) ~= "table" or type(p) ~= "table" or not rig.m or rig.m == 0 then return nil end
  local pivotPx = { PxContext.PX_PER_CELL * a.x, PxContext.PX_PER_CELL * a.y, PxContext.PX_PER_CELL * a.z }
  local anchorLocal = { p.x, p.y, p.z }
  local scalePxPerM = PxContext.PX_PER_CELL / rig.m
  return VRRig.worldFromLocal(pivotPx, anchorLocal, scalePxPerM, rig.yaw or 0)
end

-- eye = the {index,name,vp,proj,view,pos={x,y,z}} table View.lua's layer
-- slot builds (HostApi.eyeFrame's shape). Returns vpPx (row-major) and
-- eyePosPx ({x,y,z} world px), or nil, nil if eye.vp is missing.
function PxContext.eyeVpPx(eye)
  if not (eye and type(eye.vp) == "table") then return nil end
  return Mat4.mul(eye.vp, Mat4.scale(1 / PxContext.PX_PER_CELL, 1 / PxContext.PX_PER_CELL, 1 / PxContext.PX_PER_CELL))
end

-- Lab 51 ALLOC TRIM: per-eye scratch versions for the VRITK layerDraw only
-- (FRLG_CATCH keeps the allocating versions above and retains their results).
-- Same arithmetic as the originals (mulInto = mul order, same constants), so
-- the values are bit-identical. The result of eyeVpPxScratch/eyePosPxScratch
-- is owned by this module: valid until the same eye index is asked again,
-- i.e. through this eye's draw and until the next frame's draw of that eye.
-- Voxel3D.vp / Voxel3D.eye point at it between beginEye calls; their readers
-- (QuestBackpackBackend, capture_material, NativeBallFX, OpeningBeamFX which
-- copies, VRDeviceAssets.glossVectors) all use it inside the eye's draw.
local EYE_SCRATCH = { {}, {} }
local VP_SCALE = Mat4.scale(1 / PxContext.PX_PER_CELL, 1 / PxContext.PX_PER_CELL, 1 / PxContext.PX_PER_CELL)

function PxContext.eyeVpPxScratch(eye)
  if not (eye and type(eye.vp) == "table") then return nil end
  local slot = EYE_SCRATCH[eye.index]
  if not slot then return PxContext.eyeVpPx(eye) end
  local vp = slot.vp
  if not vp then vp = {}; slot.vp = vp end
  return Mat4.mulInto(vp, eye.vp, VP_SCALE)
end

function PxContext.eyePosPxScratch(eye)
  if not (eye and type(eye.pos) == "table") then return nil end
  local slot = EYE_SCRATCH[eye.index]
  if not slot then return PxContext.eyePosPx(eye) end
  local pos = slot.pos
  if not pos then pos = {}; slot.pos = pos end
  pos[1] = PxContext.PX_PER_CELL * eye.pos.x
  pos[2] = PxContext.PX_PER_CELL * eye.pos.y
  pos[3] = PxContext.PX_PER_CELL * eye.pos.z
  return pos
end

function PxContext.eyePosPx(eye)
  if not (eye and type(eye.pos) == "table") then return nil end
  return { PxContext.PX_PER_CELL * eye.pos.x, PxContext.PX_PER_CELL * eye.pos.y, PxContext.PX_PER_CELL * eye.pos.z }
end

-- Best-effort gaze, in world px: origin at the head, direction along its
-- forward (-Z in the head's own local frame, rotated by worldFromLocalPx's
-- rotation-only part -- the same convention Mat4.transformDir uses).
-- DESIGN.md marks ctx.gaze a GAP "computed from head"; VRRig.headGaze
-- itself wants two eye records with .eye/.focus this bridge does not build
-- for P2 (no camera-window renderCamera path is wired), so this is a
-- direct one-ray version instead of a port of that function. Not read by
-- anything in the P2 (backpack/gloves) path -- kept for forward
-- compatibility with P3's ball-targeting gaze use.
function PxContext.headGazePx(worldFromLocalPx, head)
  if not (worldFromLocalPx and type(head) == "table" and head.pos and head.quat) then return nil end
  local q = head.quat
  local R = Mat4.fromQuat(q[1], q[2], q[3], q[4])
  -- forward = -Z column of R, rotated into world by worldFromLocalPx's
  -- rotation part (its upper-left 3x3, since Mat4.mul on a direction with
  -- w=0 already drops translation -- see Mat4.mul's row-major layout).
  local fx, fy, fz = -R[3], -R[7], -R[11]
  local m = worldFromLocalPx
  local dx = m[1] * fx + m[2] * fy + m[3] * fz
  local dy = m[5] * fx + m[6] * fy + m[7] * fz
  local dz = m[9] * fx + m[10] * fy + m[11] * fz
  local len = math.sqrt(dx * dx + dy * dy + dz * dz)
  if len < 1e-6 then return nil end
  local px, py, pz = head.pos[1], head.pos[2], head.pos[3]
  local ox = m[1] * px + m[2] * py + m[3] * pz + m[4]
  local oy = m[5] * px + m[6] * py + m[7] * pz + m[8]
  local oz = m[9] * px + m[10] * py + m[11] * pz + m[12]
  return { origin = { ox, oy, oz }, direction = { dx / len, dy / len, dz / len } }
end

-- The full Gen2-shaped per-frame context (StereoRenderer.lua:352-366's
-- shape, verified against the actual fl16 source). `hostCtx` is the ctx
-- HostLayers:update(ctx) hands this bridge's own layer.update. `rootIdText`
-- is a stable per-map token (DESIGN.md 2b "map = a stable token per
-- rootId"); the caller passes tostring(hostCtx.rootId).
--
-- NOT built here (P2 scope, DESIGN.md 0.1 point 4 -- pouch/belt/HUD are
-- P3): the "held-prop finger-curl override" StereoRenderer.lua:318-333
-- applies to `hands` (there is no ball prop to hold on FireRed yet, since
-- overworld_wild_spawns stays gen1/gen2-only -- Q1). `hands` here is the
-- plain VRHandPose.fromControls(controls) result.
-- W4 review fix #8c (REVIEW_VRITK_P2.md): on a 3D menu frame the game's own
-- menu ALSO reads gripL/gripR/triggerL directly (L/R/SELECT navigation), so
-- without this gate one squeeze would reach both the menu AND VRITK's own
-- grab/reel logic. Thresholds match InputMap's own analog release
-- hysteresis (CRITIQUE #2's held-style convention), not the press one.
PxContext.MENU_GATE_OFF = { gripL = 0.45, gripR = 0.45, triggerL = 0.35 }

-- Pure: given raw controls and a `held` set the CALLER owns and populates
-- on the menuOpen rising edge (main.lua's layerUpdate -- which of gripL/
-- gripR/triggerL were already active the instant the menu opened), returns
-- a controls table with those three keys zeroed EXCEPT ones still marked
-- held. Clears a `held` entry the frame its value drops below the release
-- threshold (so a grab in progress when the menu opened keeps reaching
-- VRITK only until it is physically released, never re-arming for a fresh
-- squeeze later in the same menu session). Never mutates the input table.
function PxContext.applyMenuGate(controls, held)
  if type(controls) ~= "table" then return controls end
  local out = {}
  for k, v in pairs(controls) do out[k] = v end
  for key, offThresh in pairs(PxContext.MENU_GATE_OFF) do
    if held and held[key] then
      local v = tonumber(controls[key]) or 0
      if v <= offThresh then held[key] = nil end -- physically released; stop forwarding from here on
    end
    if not (held and held[key]) then out[key] = 0 end
  end
  return out
end

-- menuHeld (optional): the caller's persistent held-set for applyMenuGate
-- above, consulted only while hostCtx.menuOpen is true. Hand POSE (handl/
-- handr pos/quat, via VRHandPose.fromControls) is built from the RAW
-- controls regardless -- it is visual glove placement, not a claimable
-- button, and is not one of the three gated keys.
-- renderCamera (optional, Gen3 dex scanner 2026-10-02): the host's camera
-- window for this frame (Gen3TabletCamera:window); absent = unsupported.
function PxContext.buildFrame(hostCtx, VRHandPose, menuHeld, renderCamera)
  local worldFromLocal = PxContext.worldFromLocalPx(hostCtx.rig)
  local hands = VRHandPose.fromControls(hostCtx.controls)
  local gaze = worldFromLocal and PxContext.headGazePx(worldFromLocal, hostCtx.head) or nil
  local controls = hostCtx.controls
  if hostCtx.menuOpen then
    controls = PxContext.applyMenuGate(controls, menuHeld)
  end
  return {
    controls = controls,
    hands = hands,
    worldFromLocal = worldFromLocal,
    gaze = gaze,
    views = hostCtx.views,
    dt = hostCtx.dt,
    predictedTime = nil, -- VRITK never reads it (reading-vritk-hosts.md 2e)
    map = tostring(hostCtx.rootId),
    -- gear-hook DESIGN.md 2e.5: kanto_gear 3.3.3 IS present on FireRed now.
    -- Gen3 dex scanner (2026-10-02): the tablet's Pokedex camera renders
    -- through FRLG_VOXEL (vrHost.camera.render) inside main.lua's layer
    -- update; the numeric-species lookup is Gen3DexScannerCompat's.
    renderCamera = renderCamera or function() return nil, "unsupported" end,
  }
end

return PxContext
