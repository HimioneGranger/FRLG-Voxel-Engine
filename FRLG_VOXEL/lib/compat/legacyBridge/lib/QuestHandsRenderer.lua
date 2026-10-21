-- W4 P2: copied verbatim (no logic changes) from the fl16 game.love lab copy
-- at source/mods/BATTLE_ART_QUEST_COMPAT/lib/QuestHandsRenderer.lua
-- (local verified crystal-fishing-20260925/fl16/game.love, per the
-- Q1 fl16-payload decision -- w4/P2_DECISIONS.md). Self-contained: only V.require
-- of sibling lib files here, no mod.find, no Gen2-only engine requires, so it needed
-- no edit to serve VRITK_FRLG_HOST as well as BATTLE_ART_QUEST_COMPAT.
-- Battle Art Quest compatibility renderer for semantic VR hands. Battle Art
-- owns the GLBs, materials, 25-joint skinning, GPU resources and fallback.

local V = ...

local Mat4 = V.require("Mat4")
local VRRig = V.require("VRRig")
local Voxel3D = V.require("Voxel3D")
local Assets = V.require("VRHandAssets")

local Renderer = {}
local meshCache, solidCache = {}, {}

local function finite(value, fallback)
  value = tonumber(value)
  if not value or value ~= value or value == math.huge or value == -math.huge then
    return fallback or 0
  end
  return value
end

local function unitBox()
  local vertices, indices = {}, {}
  for face = 1, 6 do
    local shade = ({ 0.82, 0.62, 1, 0.52, 0.88, 0.68 })[face]
    for _, corner in ipairs(Voxel3D.FACE_CORNERS[face]) do
      vertices[#vertices + 1] = { corner[1] - 0.5, corner[2] - 0.5,
        corner[3] - 0.5, corner[1], corner[2], shade }
    end
    Voxel3D.pushQuad(indices, face - 1)
  end
  return Voxel3D.newMesh(vertices, indices)
end

local function boxMesh()
  if meshCache.box == nil then meshCache.box = unitBox() or false end
  return meshCache.box or nil
end

local function colorKey(color)
  return table.concat({ math.floor((color[1] or 1) * 255 + 0.5),
    math.floor((color[2] or 1) * 255 + 0.5),
    math.floor((color[3] or 1) * 255 + 0.5),
    math.floor((color[4] or 1) * 255 + 0.5) }, ":")
end

local function solid(color)
  local key = colorKey(color)
  if solidCache[key] ~= nil then return solidCache[key] or nil end
  if not (love and love.image and love.image.newImageData
      and love.graphics and love.graphics.newImage) then
    solidCache[key] = false
    return nil
  end
  local ok, image = pcall(function()
    local data = love.image.newImageData(1, 1)
    data:setPixel(0, 0, color[1], color[2], color[3], color[4] or 1)
    local result = love.graphics.newImage(data)
    result:setFilter("nearest", "nearest")
    return result
  end)
  solidCache[key] = ok and image or false
  return solidCache[key] or nil
end

local function localModel(parent, primitive)
  local position = primitive.position or {}
  local size = primitive.size or {}
  local rotation = primitive.rotation or {}
  local model = Mat4.mul(parent, Mat4.translate(finite(position[1]),
    finite(position[2]), finite(position[3])))
  if finite(rotation.yaw) ~= 0 then
    model = Mat4.mul(model, Mat4.rotateY(finite(rotation.yaw)))
  end
  if finite(rotation.pitch) ~= 0 then
    model = Mat4.mul(model, Mat4.rotateX(finite(rotation.pitch)))
  end
  return Mat4.mul(model, Mat4.scale(finite(size[1], 1),
    finite(size[2], 1), finite(size[3], 1)))
end

local function fallback(model, semantic, side)
  local mesh = boxMesh()
  if not mesh then return false end
  local drawn = false
  for _, primitive in ipairs(Assets.fallbackPrimitives(semantic, side)) do
    local texture = solid(primitive.color or { 1, 1, 1, 1 })
    if texture then
      Voxel3D.draw(mesh, texture, localModel(model, primitive))
      drawn = true
    end
  end
  return drawn
end

-- Lab 51 ALLOC TRIM ------------------------------------------------------
-- The hand model matrix is a pure function of: the world matrix, the hand
-- pose, the held-prop rotation (flat_support), and the style's grip offset
-- and scale. All of them are compared by VALUE against the previous
-- computation of that side, so eye 2 of a frame (identical inputs) reuses
-- eye 1's matrix, and a changed input of any kind recomputes it. The
-- matrices live in per-side scratch owned by this file; Assets.draw and
-- fallback() only read the model (Voxel3D.draw sends it synchronously).
-- OFF (Trim.on == false) runs placeLegacy(), the Lab 50 statements.
local Trim = V.require("AllocTrim")
local SIDES = { "left", "right" }
local ZERO3 = { 0, 0, 0 }
local ZERO_POSITION, IDENTITY_QUAT = { 0, 0, 0 }, { 0, 0, 0, 1 }

local function newEntry()
  return { valid = false, flat = false, world = {}, model = {}, a = {}, t = {}, r = {}, x = {} }
end
local entries = { left = newEntry(), right = newEntry() }

local function placeLegacy(world, hand, semantic, side)
  local model = Mat4.mul(world, VRRig.poseMatrix(hand.pose))
  -- A held prop may rotate its supporting hand about the grip origin.
  -- Apply before wrist translation so contact geometry stays rigid.
  if side == "right" and semantic.holding == true
      and semantic.gripStyle == "flat_support" then
    -- X is the outer controller-local pitch, before the existing yaw.
    model = Mat4.mul(model, Mat4.rotateX(finite(semantic.gripRotationX)))
    model = Mat4.mul(model, Mat4.rotateY(finite(semantic.gripRotationY)))
  end
  local gripToWrist = Assets.gripToWrist
    and Assets.gripToWrist(semantic, side) or { 0, 0, 0 }
  model = Mat4.mul(model, Mat4.translate(finite(gripToWrist[1]),
    finite(gripToWrist[2]), finite(gripToWrist[3])))
  local visualScale = Assets.visualScale
    and finite(Assets.visualScale(semantic, side), 1) or 1
  model = Mat4.mul(model, Mat4.scale(visualScale, visualScale, visualScale))
  return model
end

local function placeTrim(world, hand, semantic, side)
  local c = entries[side]
  local pose = hand.pose
  if type(pose) ~= "table" then pose = nil end
  local p = pose and (pose.position or pose.pos) or ZERO_POSITION
  local q = pose and (pose.orientation or pose.quat) or IDENTITY_QUAT
  local flat = side == "right" and semantic.holding == true
    and semantic.gripStyle == "flat_support"
  local rx, ry
  if flat then rx, ry = semantic.gripRotationX, semantic.gripRotationY end
  local gtw, vsf = Assets.gripToWrist, Assets.visualScale
  local g = gtw and gtw(semantic, side) or ZERO3
  local gx, gy, gz = finite(g[1]), finite(g[2]), finite(g[3])
  local vs = vsf and finite(vsf(semantic, side), 1) or 1
  local w = c.world
  if c.valid and c.flat == flat and c.rx == rx and c.ry == ry
      and c.gx == gx and c.gy == gy and c.gz == gz and c.vs == vs
      and c.p1 == p[1] and c.p2 == p[2] and c.p3 == p[3]
      and c.q1 == q[1] and c.q2 == q[2] and c.q3 == q[3] and c.q4 == q[4]
      and w[1] == world[1] and w[2] == world[2] and w[3] == world[3]
      and w[4] == world[4] and w[5] == world[5] and w[6] == world[6]
      and w[7] == world[7] and w[8] == world[8] and w[9] == world[9]
      and w[10] == world[10] and w[11] == world[11] and w[12] == world[12]
      and w[13] == world[13] and w[14] == world[14] and w[15] == world[15]
      and w[16] == world[16] then
    return c.model
  end
  c.valid = false -- a throw below must not leave a half-written entry usable
  local model = c.model
  VRRig.poseMatrixInto(c.a, c.t, c.r, pose)
  Mat4.mulInto(model, world, c.a)
  if flat then
    Mat4.mulInto(model, model, Mat4.rotateXInto(c.x, finite(rx)))
    Mat4.mulInto(model, model, Mat4.rotateYInto(c.x, finite(ry)))
  end
  Mat4.mulInto(model, model, Mat4.translateInto(c.x, gx, gy, gz))
  Mat4.mulInto(model, model, Mat4.scaleInto(c.x, vs, vs, vs))
  for i = 1, 16 do w[i] = world[i] end
  c.flat, c.rx, c.ry, c.gx, c.gy, c.gz, c.vs = flat, rx, ry, gx, gy, gz, vs
  c.p1, c.p2, c.p3 = p[1], p[2], p[3]
  c.q1, c.q2, c.q3, c.q4 = q[1], q[2], q[3], q[4]
  c.valid = true
  return model
end

function Renderer.draw(payload)
  payload = type(payload) == "table" and payload or {}
  local world = payload.worldFromLocal
  local hands = type(payload.hands) == "table" and payload.hands or {}
  if type(world) ~= "table" then return false end
  Voxel3D.lighting(false)
  Voxel3D.seams(false)
  Voxel3D.glass(false)
  local drawn = false
  local trim = Trim.on
  -- OFF keeps Lab 50's per-call literal so its allocations stay the same
  for _, side in ipairs(trim and SIDES or { "left", "right" }) do
    local hand = hands[side]
    if type(hand) == "table" and hand.tracked == true and hand.pose then
      local semantic = type(hand.model) == "table" and hand.model or {}
      local model
      if trim then
        model = placeTrim(world, hand, semantic, side)
      else
        model = placeLegacy(world, hand, semantic, side)
      end
      if Renderer.adjustModel then model = Renderer.adjustModel(model, world, side, semantic) or model end -- Gen3 tablet-input58 seam (render-only finger clamp)
      drawn = Assets.draw(semantic, side, model)
        or fallback(model, semantic, side) or drawn
    end
  end
  Voxel3D.lighting(true)
  return drawn
end

function Renderer.invalidate()
  Assets.invalidate()
  for _, mesh in pairs(meshCache) do
    if type(mesh) == "userdata" and mesh.release then pcall(mesh.release, mesh) end
  end
  for _, image in pairs(solidCache) do
    if type(image) == "userdata" and image.release then pcall(image.release, image) end
  end
  meshCache, solidCache = {}, {}
end

return Renderer
