-- W4 P2: copied verbatim (no logic changes) from the fl16 game.love lab copy
-- at source/mods/BATTLE_ART_QUEST_COMPAT/lib/VRHandAssets.lua
-- (local verified crystal-fishing-20260925/fl16/game.love, per the
-- Q1 fl16-payload decision -- w4/P2_DECISIONS.md). Self-contained: only V.require
-- of sibling lib files here, no mod.find, no Gen2-only engine requires, so it needed
-- no edit to serve VRITK_FRLG_HOST as well as BATTLE_ART_QUEST_COMPAT.
-- Battle Art-owned standards-based hand lookup, GLB loader, CPU skinning and
-- primitive fallback. The Ash glove is intentionally absent from this
-- approval prototype. The renderer-neutral interaction scene supplies only
-- semantic pose data; no asset path or GPU object crosses that boundary.

local V = ...

local Mat4 = V.require("Mat4")
local Voxel3D = V.require("Voxel3D")

local Hands = {}

Hands.STYLE_ID = "ash_fingerless_v1"

-- Stage one is a clean, bare-hand approval prototype. Keep the stable style
-- ID so VR Interaction stays renderer-neutral; the approved glove shell will
-- be fitted by Battle Art in stage two without changing that public contract.
local ROOT = "assets/vr/hands/standard_openxr/"
local CONTRACT_PATH = ROOT .. "model_contract.json"
local LOOKUP = {
  [Hands.STYLE_ID] = {
    models = {
      left = ROOT .. "openxr_hand_left.glb",
      right = ROOT .. "openxr_hand_right.glb",
    },
    controllerAssetSide = { left = "left", right = "right" },
    contract = CONTRACT_PATH,
    units = "meters",
    origin = "wrist",
    rightAxis = "+X",
    dorsal = { left = "-X", right = "+X" },
    forward = "-Z",
    curlAxis = "+X",
    wristToTipMeters = 0.211553,
    -- The reference rig is 21.2 cm wrist-to-middle-tip. A 0.90 render scale
    -- produces a natural 19 cm Quest hand for the approval pass.
    visualScale = 0.90,
    -- OpenXR's grip pose is the palm centroid, while this GLB is rooted at
    -- the anatomical wrist. At the render scale the wrist sits about 5 cm
    -- behind that centroid along the model's +Z axis.
    gripToWristMeters = { 0, 0, 0.050 },
  },
}

local JOINTS = {
  "wrist",
  "thumb_metacarpal", "thumb_proximal", "thumb_distal", "thumb_tip",
  "index_metacarpal", "index_proximal", "index_intermediate",
    "index_distal", "index_tip",
  "middle_metacarpal", "middle_proximal", "middle_intermediate",
    "middle_distal", "middle_tip",
  "ring_metacarpal", "ring_proximal", "ring_intermediate",
    "ring_distal", "ring_tip",
  "little_metacarpal", "little_proximal", "little_intermediate",
    "little_distal", "little_tip",
}

local DEFAULT_CURL = {
  indexProximal = 86, indexIntermediate = 97, indexDistal = 82,
  gripProximal = 86, gripIntermediate = 97, gripDistal = 82,
  thumbMetacarpal = -20, thumbProximal = 80, thumbDistal = 45,
  thumbOppositionY = -50, thumbAdductionZ = -40,
}
local SKIN = { 0.72, 0.48, 0.32, 1 }

local assetCache, resourceCache, errorCache = {}, {}, {}

local function clamp(value)
  value = tonumber(value) or 0
  if value ~= value then return 0 end
  return math.max(0, math.min(1, value))
end

local function copy(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for key, item in pairs(value) do out[key] = copy(item) end
  return out
end

local function styleId(value)
  value = type(value) == "table" and value or {}
  local id = value.id or value.styleId or value.style
  -- One-release compatibility for renderer-neutral scenes made before the
  -- stable v1 suffix was introduced. New scenes never emit this alias.
  if id == "ash_fingerless" then id = Hands.STYLE_ID end
  return tostring(id or Hands.STYLE_ID)
end

function Hands.resolve(id, side)
  id = id == "ash_fingerless" and Hands.STYLE_ID or id
  local style = LOOKUP[id]
  side = side == "left" and "left" or side == "right" and "right" or nil
  if not (style and side) then return nil end
  local assetSide = style.controllerAssetSide[side]
  local gripToWrist = style.gripToWristMeters or { 0, 0, 0 }
  return {
    styleId = id,
    side = side,
    assetSide = assetSide,
    glb = style.models[assetSide],
    contract = style.contract,
    units = style.units,
    origin = style.origin,
    right = style.rightAxis,
    dorsal = style.dorsal[side],
    forward = style.forward,
    curlAxis = style.curlAxis,
    wristToTipMeters = style.wristToTipMeters,
    visualScale = style.visualScale,
    gripToWristMeters = { gripToWrist[1], gripToWrist[2], gripToWrist[3] },
  }
end

local function visualScaleLegacy(value, side)
  local pose = Hands.pose(value, side)
  local descriptor = Hands.resolve(pose.styleId, pose.side)
  return descriptor and descriptor.visualScale or 1
end

local function gripToWristLegacy(value, side)
  local pose = Hands.pose(value, side)
  local descriptor = Hands.resolve(pose.styleId, pose.side)
  local offset = descriptor and descriptor.gripToWristMeters or nil
  return offset and { offset[1], offset[2], offset[3] } or { 0, 0, 0 }
end

-- Lab 51 ALLOC TRIM. The flag table is shared (lib/AllocTrim.lua); other
-- libraries (SkinnedGloveHands) read it as Hands.trimFlag.on, a plain field
-- read. OFF = the Lab 50 functions above, unchanged.
local Trim = V.require("AllocTrim")
Hands.trimFlag = Trim

-- ON: both answers depend only on (style id, normalised side). They are
-- cached per pair, never rebuilt per call. The offset table is SHARED and
-- READ-ONLY: every caller in the tree only indexes it (renderer, GloveFit
-- correction/gripMatrix via `g[1] or 0`, DrawnFingertip, FishingRod,
-- HeldBallFit, QuestWearableInteraction, indexTip, the MiniBallGrip wrapper
-- builds a NEW table). The style id is derived exactly as Hands.pose does
-- (styleId()); the side as Hands.pose does (anything but "left" is "right").
-- Hands.pose is not called, which only matters if a wrapper of Hands.pose
-- changed styleId/side; the one shipped wrapper (MiniBallGrip) changes only
-- p.trigger.
local ZERO3, STYLE_ROWS = { 0, 0, 0 }, {}
local function styleRow(value, side)
  local id = styleId(value)
  side = side == "left" and "left" or "right"
  local bySide = STYLE_ROWS[id]
  local row = bySide and bySide[side]
  if row then return row end
  local descriptor = Hands.resolve(id, side)
  if not descriptor then return nil end -- unknown style: not cached (unbounded ids)
  row = { offset = { descriptor.gripToWristMeters[1], descriptor.gripToWristMeters[2],
      descriptor.gripToWristMeters[3] },
    scale = descriptor.visualScale or 1 }
  if not bySide then bySide = {}; STYLE_ROWS[id] = bySide end
  bySide[side] = row
  return row
end

function Hands.visualScale(value, side)
  if not Trim.on then return visualScaleLegacy(value, side) end
  local row = styleRow(value, side)
  return row and row.scale or 1
end

function Hands.gripToWrist(value, side)
  if not Trim.on then return gripToWristLegacy(value, side) end
  local row = styleRow(value, side)
  return row and row.offset or ZERO3
end

function Hands.pose(value, side)
  value = type(value) == "table" and value or {}
  side = side == "left" and "left" or "right"
  local grip, trigger = clamp(value.grip), clamp(value.trigger)
  local holding = value.holding == true
  -- Thin flat props need fingers resting behind the face, not the deep curl
  -- used for a ball/controller. This opt-in leaves every existing holder alone.
  local gripStyle = value.gripStyle == "flat_support" and "flat_support" or nil
  if holding and gripStyle ~= "flat_support" then grip = math.max(grip, 0.58) end
  local thumbRest = value.thumbRest == true
  local combined = grip >= 0.35 and trigger >= 0.35
  local pointing = value.pointing == true
    or (grip >= 0.35 and trigger <= 0.20 and not holding)
  return {
    styleId = styleId(value),
    side = side,
    grip = grip,
    trigger = trigger,
    thumbRest = thumbRest,
    pointing = pointing,
    holding = holding,
    gripStyle = gripStyle,
    thumbGrip = value.thumbGrip ~= nil and clamp(value.thumbGrip) or nil,
    thumbPose = value.thumbPose == "rail_rest" and "rail_rest" or nil,
    combined = combined,
    closedFist = combined and thumbRest,
  }
end

local function thumbAmount(pose)
  if pose.thumbGrip ~= nil then return pose.thumbGrip end
  local thumb = pose.thumbRest and (pose.closedFist and 1 or 0.58) or 0
  if pose.holding then thumb = math.max(thumb, 0.48) end
  return thumb
end

local function curlDegrees(contract, key)
  local values = contract and contract.articulation
    and contract.articulation.controllerFallbackDegrees or {}
  return tonumber(values[key]) or DEFAULT_CURL[key] or 0
end

function Hands.jointPose(value, side, contract)
  local pose = Hands.pose(value, side)
  local out = {}
  local thumb = thumbAmount(pose)
  local railRest = pose.holding and pose.gripStyle == "flat_support"
    and pose.thumbPose == "rail_rest"
  for _, name in ipairs(JOINTS) do
    local digit = name:match("^([^_]+)")
    local amount = digit == "index" and (pose.pointing and 0 or pose.trigger)
      or digit == "thumb" and thumb
      or (digit == "middle" or digit == "ring" or digit == "little")
        and pose.grip or 0
    local degreeKey
    if digit == "index" then
      degreeKey = name:match("_proximal$") and "indexProximal"
        or name:match("_intermediate$") and "indexIntermediate"
        or name:match("_distal$") and "indexDistal"
    elseif digit == "middle" or digit == "ring" or digit == "little" then
      degreeKey = name:match("_proximal$") and "gripProximal"
        or name:match("_intermediate$") and "gripIntermediate"
        or name:match("_distal$") and "gripDistal"
    elseif digit == "thumb" then
      degreeKey = name:match("_metacarpal$") and "thumbMetacarpal"
        or name:match("_proximal$") and "thumbProximal"
        or name:match("_distal$") and "thumbDistal"
    end
    local sideSign = pose.side == "left" and -1 or 1
    out[name] = {
      curl = amount,
      rotation = {
        x = math.rad(curlDegrees(contract, degreeKey) * amount),
        y = name == "thumb_metacarpal" and math.rad(
          curlDegrees(contract, "thumbOppositionY") * sideSign * amount) or 0,
        -- Thumb opposition plus adduction lays it across index and middle.
        -- The authored left/right rigs require mirrored local Y/Z signs.
        z = name == "thumb_metacarpal" and math.rad(
          curlDegrees(contract, "thumbAdductionZ") * sideSign * amount) or 0,
      },
    }
    -- An opt-in thumb resting lengthwise on a flat prop's outer rail. These
    -- are absolute local rig angles, not a scalar closed-fist interpolation.
    -- The other digits and every ordinary holder keep their existing pose.
    if railRest and digit == "thumb" then
      out[name].rotation = {
        -- Open the base outside the shell before bringing the pad forward.
        -- These deltas counter the GLB's curved bind pose; a zero distal
        -- delta still hooks through the rail in this rig.
        x = math.rad(name == "thumb_metacarpal" and 25.2
          or name == "thumb_proximal" and -16.1 or -20),
        y = name == "thumb_metacarpal" and math.rad(18 * sideSign) or 0,
        z = name == "thumb_metacarpal" and math.rad(-20.3 * sideSign) or 0,
      }
    end
  end
  return out, pose
end

local function direction(yaw, pitch)
  local sy, cy = math.sin(yaw), math.cos(yaw)
  local sp, cp = math.sin(pitch), math.cos(pitch)
  return { -sy * cp, sp, -cy * cp }
end

local function box(region, color, x, y, z, sx, sy, sz)
  return { primitive = "box", region = region, color = color,
    position = { x, y, z }, size = { sx, sy, sz } }
end

local function addSegment(out, region, color, base, radius, length, yaw, pitch)
  local axis = direction(yaw, pitch)
  local finish = { base[1] + axis[1] * length,
    base[2] + axis[2] * length, base[3] + axis[3] * length }
  out[#out + 1] = {
    primitive = "box", region = region, color = color,
    position = { (base[1] + finish[1]) * 0.5,
      (base[2] + finish[2]) * 0.5, (base[3] + finish[3]) * 0.5 },
    size = { radius * 2, radius * 2, length },
    rotation = { yaw = yaw, pitch = pitch, roll = 0 },
  }
  return finish
end

-- Battle Art owns this geometry. It is used only when the GLB bridge cannot
-- validate or allocate the authored skinned hand.
function Hands.fallbackPrimitives(value, side)
  local pose = Hands.pose(value, side)
  local mirror = pose.side == "left" and -1 or 1
  local out = {
    box("skin_wrist", SKIN, 0, -0.006, 0.030, 0.075, 0.030, 0.050),
    box("skin_palm", SKIN, 0, 0.002, -0.030, 0.086, 0.030, 0.085),
  }
  local fingerX = { -0.031, -0.010, 0.011, 0.032 }
  local lengths = { 0.056, 0.066, 0.063, 0.050 }
  local curls = { pose.pointing and 0 or pose.trigger,
    pose.grip * 0.92, pose.grip, pose.grip * 0.88 }
  for index = 1, 4 do
    local amount, total = clamp(curls[index]), lengths[index]
    local proximal, distal = total * 0.56, total * 0.44
    local base = { fingerX[index] * mirror, 0, -0.066 }
    local joint = addSegment(out, "skin_finger_" .. index .. "_proximal",
      SKIN, base, 0.0087, proximal, 0, math.rad(-7 - 78 * amount))
    addSegment(out, "skin_finger_" .. index .. "_distal", SKIN, joint,
      0.0082, distal, 0, math.rad(-7 - 148 * amount))
  end
  -- The box fallback has no authored metacarpal rig. Keep its existing scalar
  -- approximation (the holder supplies thumbGrip) if the GLB cannot render.
  local thumb = thumbAmount(pose)
  local base = { 0.047 * mirror, -0.002, -0.026 }
  local joint = addSegment(out, "skin_thumb_proximal", SKIN, base,
    0.0102, 0.028, math.rad((-38 + 34 * thumb) * mirror),
    math.rad(-12 - 30 * thumb))
  addSegment(out, "skin_thumb_distal", SKIN, joint, 0.0095, 0.023,
    math.rad((-38 + 100 * thumb) * mirror), math.rad(-12 - 54 * thumb))
  return out
end

local function u16(data, offset)
  local a, b = data:byte(offset, offset + 1)
  if not b then error("truncated uint16") end
  return a + b * 256
end

local function u32(data, offset)
  local a, b, c, d = data:byte(offset, offset + 3)
  if not d then error("truncated uint32") end
  return a + b * 256 + c * 65536 + d * 16777216
end

local function f32(data, offset)
  local bits = u32(data, offset)
  local sign = bits >= 2147483648 and -1 or 1
  if sign < 0 then bits = bits - 2147483648 end
  local exponent = math.floor(bits / 8388608)
  local mantissa = bits - exponent * 8388608
  if exponent == 255 then error("non-finite float32") end
  if exponent == 0 then
    return sign * (mantissa / 8388608) * 2 ^ -126
  end
  return sign * (1 + mantissa / 8388608) * 2 ^ (exponent - 127)
end

local function readFile(path)
  if type(V.readFile) == "function" then
    local value = V.readFile(path)
    if value then return value end
  end
  if V.mod and type(V.mod.read) == "function" then
    local ok, value = pcall(V.mod.read, V.mod, path)
    if ok and type(value) == "string" then return value end
  end
  return nil
end

local function decodeJson(text)
  if type(V.decodeJson) == "function" then return V.decodeJson(text) end
  local ok, Json = pcall(require, "src.link.Json")
  if not (ok and Json and type(Json.decode) == "function") then
    error("engine JSON decoder unavailable")
  end
  local value, err = Json.decode(text)
  if not value then error(err or "invalid JSON") end
  return value
end

local COMPONENT_COUNT = {
  SCALAR = 1, VEC2 = 2, VEC3 = 3, VEC4 = 4, MAT4 = 16,
}
local COMPONENT_SIZE = {
  [5121] = 1, [5123] = 2, [5125] = 4, [5126] = 4,
}

local function component(data, offset, kind)
  if kind == 5121 then
    local value = data:byte(offset)
    if value == nil then error("truncated uint8") end
    return value
  end
  if kind == 5123 then return u16(data, offset) end
  if kind == 5125 then return u32(data, offset) end
  if kind == 5126 then return f32(data, offset) end
  error("unsupported GLB component type " .. tostring(kind))
end

local function parseChunks(bytes)
  if type(bytes) ~= "string" or #bytes < 28
      or bytes:sub(1, 4) ~= "glTF" then error("invalid GLB header") end
  if u32(bytes, 5) ~= 2 or u32(bytes, 9) ~= #bytes then
    error("unsupported or truncated GLB")
  end
  local cursor, jsonText, binary = 13
  while cursor + 7 <= #bytes do
    local length = u32(bytes, cursor)
    local kind = bytes:sub(cursor + 4, cursor + 7)
    local first, last = cursor + 8, cursor + 7 + length
    if last > #bytes then error("truncated GLB chunk") end
    if kind == "JSON" then jsonText = bytes:sub(first, last)
    elseif kind == "BIN\0" then binary = bytes:sub(first, last) end
    cursor = last + 1
  end
  if not (jsonText and binary) then error("GLB requires JSON and BIN chunks") end
  return decodeJson(jsonText), binary
end

local function bufferView(gltf, binary, zeroIndex)
  local view = gltf.bufferViews and gltf.bufferViews[zeroIndex + 1]
  if type(view) ~= "table" or tonumber(view.buffer or 0) ~= 0 then
    error("invalid GLB buffer view")
  end
  local offset = math.floor(tonumber(view.byteOffset) or 0)
  local length = math.floor(tonumber(view.byteLength) or -1)
  if offset < 0 or length < 0 or offset + length > #binary then
    error("GLB buffer view out of range")
  end
  return view, offset + 1, length
end

local function accessorData(gltf, binary, zeroIndex)
  local value = gltf.accessors and gltf.accessors[zeroIndex + 1]
  if type(value) ~= "table" or value.sparse ~= nil then
    error("invalid or sparse GLB accessor")
  end
  local count = math.floor(tonumber(value.count) or -1)
  local width = COMPONENT_COUNT[value.type]
  local size = COMPONENT_SIZE[value.componentType]
  if count < 1 or not (width and size) then error("unsupported GLB accessor") end
  local view, start = bufferView(gltf, binary, value.bufferView)
  start = start + math.floor(tonumber(value.byteOffset) or 0)
  local packed = width * size
  local stride = math.floor(tonumber(view.byteStride) or packed)
  if stride < packed or start + (count - 1) * stride + packed - 1 > #binary then
    error("GLB accessor out of range")
  end
  local out = {}
  for row = 0, count - 1 do
    local base, item = start + row * stride, {}
    for column = 0, width - 1 do
      item[column + 1] = component(binary, base + column * size,
        value.componentType)
    end
    out[row + 1] = width == 1 and item[1] or item
  end
  return out
end

local function rowMajor(columnMajor)
  local out = {}
  for row = 0, 3 do
    for column = 0, 3 do
      out[row * 4 + column + 1] = columnMajor[column * 4 + row + 1]
    end
  end
  return out
end

local function filename(path)
  return tostring(path):gsub("\\", "/"):match("([^/]+)$")
end

local function canonicalJointName(value)
  value = tostring(value or ""):gsub("^Left", ""):gsub("^Right", "")
  if value == "Hand" then return "wrist" end
  return value:gsub("(%l)(%u)", "%1_%2"):lower()
end

local function nodeLocalMatrix(node)
  if type(node.matrix) == "table" and #node.matrix == 16 then
    return rowMajor(node.matrix)
  end
  local t, q, s = node.translation or { 0, 0, 0 },
    node.rotation or { 0, 0, 0, 1 }, node.scale or { 1, 1, 1 }
  local x, y, z, w = tonumber(q[1]) or 0, tonumber(q[2]) or 0,
    tonumber(q[3]) or 0, tonumber(q[4]) or 1
  local sx, sy, sz = tonumber(s[1]) or 1, tonumber(s[2]) or 1,
    tonumber(s[3]) or 1
  return {
    (1 - 2 * (y * y + z * z)) * sx,
      (2 * (x * y - z * w)) * sy, (2 * (x * z + y * w)) * sz,
      tonumber(t[1]) or 0,
    (2 * (x * y + z * w)) * sx,
      (1 - 2 * (x * x + z * z)) * sy, (2 * (y * z - x * w)) * sz,
      tonumber(t[2]) or 0,
    (2 * (x * z - y * w)) * sx,
      (2 * (y * z + x * w)) * sy, (1 - 2 * (x * x + y * y)) * sz,
      tonumber(t[3]) or 0,
    0, 0, 0, 1,
  }
end

local function validateContract(contract, descriptor)
  if type(contract) ~= "table" or tonumber(contract.schemaVersion) ~= 1
      or contract.units ~= "meters" then error("invalid hand model contract") end
  local axes = contract.controllerSpace or {}
  if axes.origin ~= "wrist joint" or axes.right ~= "+X"
      or axes.dorsal ~= "side-dependent X (see authoredMeshSpace)"
      or axes.forward ~= "-Z toward fingertips"
      or axes.curlAxis ~= "+X bends fingertips toward +Y" then
    error("hand coordinate contract changed")
  end
  local meshAxes = contract.authoredMeshSpace or {}
  if meshAxes.palmThicknessAxis ~= "X" or meshAxes.fingerSpreadAxis ~= "Y"
      or not meshAxes.dorsal or meshAxes.dorsal[descriptor.side] ~= descriptor.dorsal then
    error("hand authored mesh basis changed")
  end
  local target = contract.target or {}
  local length = tonumber(target.wristToTipMeters)
  if not length or math.abs(length - descriptor.wristToTipMeters) > 0.0001 then
    error("hand scale contract changed")
  end
  local model = contract.models and contract.models[descriptor.assetSide]
  if type(model) ~= "table" or model.glb ~= filename(descriptor.glb)
      or type(model.joints) ~= "table" or #model.joints ~= #JOINTS then
    error("hand side contract changed")
  end
  for index, name in ipairs(JOINTS) do
    if model.joints[index] ~= name then error("hand joint contract changed") end
  end
  return model
end

local function restJointCenters(parents, translations)
  local centers = {}
  for slot, translation in ipairs(translations) do
    local parent = parents[slot]
    local base = parent and centers[parent] or { 0, 0, 0 }
    centers[slot] = { base[1] + translation[1],
      base[2] + translation[2], base[3] + translation[3] }
  end
  return centers
end

local function taperFingerPositions(positions, joints, weights, primitives,
    parents, translations, radialScale)
  radialScale = tonumber(radialScale) or 1
  if radialScale >= 0.999 then return 0 end
  local skinVertices = {}
  for _, index in ipairs(primitives[1].indices) do skinVertices[index] = true end
  local centers = restJointCenters(parents, translations)
  local child = {}
  -- parents[1] is intentionally nil for the wrist, so ipairs would stop
  -- before visiting any finger joint.
  for slot = 2, #JOINTS do
    local parent = parents[slot]
    if parent then child[parent] = slot end
  end
  local adjusted = 0
  for index in pairs(skinVertices) do
    local position = positions[index]
    local jointSet, weightSet = joints[index], weights[index]
    local x, y, z, total, taperedWeight = 0, 0, 0, 0, 0
    for influence = 1, 4 do
      local weight = tonumber(weightSet[influence]) or 0
      if weight > 0 then
        local slot = math.floor(tonumber(jointSet[influence]) or -1) + 1
        local from, to = centers[slot], centers[child[slot]]
        local px, py, pz = position[1], position[2], position[3]
        -- Wrist/glove influences remain unchanged. Every actual digit joint
        -- has a child that defines its local bone axis.
        if slot > 1 and from and to then
          local ax, ay, az = to[1] - from[1], to[2] - from[2],
            to[3] - from[3]
          local length = math.sqrt(ax * ax + ay * ay + az * az)
          if length > 1e-8 then
            ax, ay, az = ax / length, ay / length, az / length
            local rx, ry, rz = px - from[1], py - from[2], pz - from[3]
            local along = rx * ax + ry * ay + rz * az
            local cx, cy, cz = from[1] + ax * along,
              from[2] + ay * along, from[3] + az * along
            px, py, pz = cx + (px - cx) * radialScale,
              cy + (py - cy) * radialScale,
              cz + (pz - cz) * radialScale
            taperedWeight = taperedWeight + weight
          end
        end
        x, y, z, total = x + px * weight, y + py * weight,
          z + pz * weight, total + weight
      end
    end
    if total > 0 and taperedWeight > 0 then
      positions[index] = { x / total, y / total, z / total }
      adjusted = adjusted + 1
    end
  end
  return adjusted
end

local function parseAsset(descriptor)
  local contractBytes = readFile(descriptor.contract)
  local glbBytes = readFile(descriptor.glb)
  if not contractBytes then error("missing hand contract") end
  if not glbBytes then error("missing hand GLB") end
  local contract = decodeJson(contractBytes)
  local contractModel = validateContract(contract, descriptor)
  local gltf, binary = parseChunks(glbBytes)
  if not (gltf.asset and gltf.asset.version == "2.0") then
    error("hand asset is not glTF 2.0")
  end
  local mesh = gltf.meshes and gltf.meshes[1]
  local skin = gltf.skins and gltf.skins[1]
  if type(mesh) ~= "table" or type(mesh.primitives) ~= "table"
      or #mesh.primitives ~= 1 or type(skin) ~= "table"
      or type(skin.joints) ~= "table" or #skin.joints ~= #JOINTS then
    error("hand GLB mesh/skin layout changed")
  end

  local nodes, nodeParents = gltf.nodes or {}, {}
  for parent, node in ipairs(nodes) do
    for _, child in ipairs(type(node.children) == "table" and node.children or {}) do
      nodeParents[child + 1] = parent
    end
  end
  local jointNodes, jointNames, nodeToSlot = {}, {}, {}
  for slot, nodeIndex in ipairs(skin.joints) do
    local node = nodes[nodeIndex + 1]
    local expected = JOINTS[slot]
    if type(node) ~= "table" or canonicalJointName(node.name) ~= expected then
      error("hand GLB joint order changed")
    end
    jointNodes[slot], jointNames[slot] = nodeIndex + 1, expected
    nodeToSlot[nodeIndex + 1] = slot
  end
  local parents, jointLocal = {}, {}
  for slot, nodeIndex in ipairs(jointNodes) do
    parents[slot] = nodeToSlot[nodeParents[nodeIndex]]
    -- Preserve each authored quaternion. Dropping these rest rotations was
    -- the root cause of the earlier backwards-bending fingers.
    jointLocal[slot] = nodeLocalMatrix(nodes[nodeIndex])
  end

  local first = mesh.primitives[1]
  local attributes = type(first) == "table" and first.attributes or {}
  for _, name in ipairs({ "POSITION", "NORMAL", "TEXCOORD_0",
      "JOINTS_0", "WEIGHTS_0" }) do
    if tonumber(attributes[name]) == nil then error("missing hand " .. name) end
  end
  local positions = accessorData(gltf, binary, attributes.POSITION)
  local normals = accessorData(gltf, binary, attributes.NORMAL)
  local uv = accessorData(gltf, binary, attributes.TEXCOORD_0)
  local joints = accessorData(gltf, binary, attributes.JOINTS_0)
  local weights = accessorData(gltf, binary, attributes.WEIGHTS_0)
  local vertexCount = #positions
  if vertexCount < 100 or vertexCount > 5000 or #normals ~= vertexCount
      or #uv ~= vertexCount or #joints ~= vertexCount
      or #weights ~= vertexCount then error("invalid hand vertex streams") end

  local minZ, maxZ = math.huge, -math.huge
  for _, position in ipairs(positions) do
    minZ, maxZ = math.min(minZ, position[3]), math.max(maxZ, position[3])
  end
  local wristToTip = maxZ - minZ
  if wristToTip < 0.20 or wristToTip > 0.22 then
    error("standards hand is outside the expected physical size")
  end

  local inverseValues = accessorData(gltf, binary, skin.inverseBindMatrices)
  if #inverseValues ~= #JOINTS then error("invalid inverse bind matrices") end
  local inverseBind = {}
  for index, value in ipairs(inverseValues) do inverseBind[index] = rowMajor(value) end

  local primitives = {}
  for index, primitive in ipairs(mesh.primitives) do
    if primitive.mode ~= nil and tonumber(primitive.mode) ~= 4 then
      error("hand primitive is not triangles")
    end
    local attrs = primitive.attributes or {}
    for key, expected in pairs(attributes) do
      if tonumber(attrs[key]) ~= tonumber(expected) then
        error("hand primitives do not share skinned vertices")
      end
    end
    local rawIndices = accessorData(gltf, binary, primitive.indices)
    if #rawIndices < 3 or #rawIndices % 3 ~= 0 then
      error("invalid hand triangle list")
    end
    local indices = {}
    for item, zeroIndex in ipairs(rawIndices) do
      zeroIndex = tonumber(zeroIndex)
      if not zeroIndex or zeroIndex < 0 or zeroIndex >= vertexCount then
        error("hand index out of range")
      end
      indices[item] = zeroIndex + 1
    end
    primitives[index] = { indices = indices,
      material = math.floor(tonumber(primitive.material) or -1) + 1 }
  end

  local materials = {}
  for index, material in ipairs(gltf.materials or {}) do
    local pbr = material.pbrMetallicRoughness or {}
    materials[index] = { name = material.name,
      color = copy(pbr.baseColorFactor or { 1, 1, 1, 1 }),
      textured = type(pbr.baseColorTexture) == "table" }
  end
  if not (materials[1] and materials[1].textured) then
    error("bare-hand texture material changed")
  end
  materials[1].name = "openxr_bare_hand"

  local image = gltf.images and gltf.images[1]
  if type(image) ~= "table" or image.mimeType ~= "image/png"
      or tonumber(image.bufferView) == nil then error("missing embedded hand image") end
  local _, imageStart, imageLength = bufferView(gltf, binary, image.bufferView)
  local imageBytes = binary:sub(imageStart, imageStart + imageLength - 1)

  return {
    descriptor = descriptor, contract = contract,
    vertexCount = vertexCount,
    triangleCount = #primitives[1].indices / 3,
    positions = positions, normals = normals, uv = uv,
    joints = joints, weights = weights,
    jointNames = jointNames, jointParents = parents,
    jointLocal = jointLocal, inverseBind = inverseBind,
    primitives = primitives, materials = materials, imageBytes = imageBytes,
    wristToTipMeters = wristToTip,
    visualScale = descriptor.visualScale,
    expectedVertices = tonumber(contractModel.vertices),
    expectedTriangles = tonumber(contractModel.triangles),
  }
end

local function asset(value, side)
  local pose = Hands.pose(value, side)
  local descriptor = Hands.resolve(pose.styleId, pose.side)
  if not descriptor then return nil, "unknown-hand-style" end
  local key = descriptor.styleId .. ":" .. descriptor.side
  if assetCache[key] ~= nil then
    return assetCache[key] or nil, errorCache[key]
  end
  local ok, result = pcall(parseAsset, descriptor)
  if ok and result and result.vertexCount == result.expectedVertices
      and result.triangleCount == result.expectedTriangles then
    assetCache[key] = result
  else
    assetCache[key] = false
    errorCache[key] = ok and "hand contract counts changed" or tostring(result)
  end
  return assetCache[key] or nil, errorCache[key]
end

function Hands.validate(value, side)
  local parsed, err = asset(value, side)
  if not parsed then return nil, err end
  return { styleId = parsed.descriptor.styleId, side = parsed.descriptor.side,
    vertices = parsed.vertexCount, triangles = parsed.triangleCount,
    joints = #parsed.jointNames, wristToTipMeters = parsed.wristToTipMeters,
    visualScale = parsed.visualScale,
    -- Use the calibrated rig target, not the mesh's small open wrist rim.
    visualWristToTipMeters = parsed.descriptor.wristToTipMeters
      * parsed.visualScale,
    materials = { parsed.materials[1].name } }
end

local function imageTexture(bytes, name)
  if not (love and love.filesystem and love.filesystem.newFileData
      and love.graphics and love.graphics.newImage) then return nil end
  local ok, texture = pcall(function()
    local fileData = love.filesystem.newFileData(bytes, name)
    local image = love.graphics.newImage(fileData)
    if image.setFilter then image:setFilter("linear", "linear") end
    return image
  end)
  return ok and texture or nil
end

local function solidTexture(color)
  if not (love and love.image and love.image.newImageData
      and love.graphics and love.graphics.newImage) then return nil end
  local ok, texture = pcall(function()
    local data = love.image.newImageData(1, 1)
    data:setPixel(0, 0, tonumber(color[1]) or 1,
      tonumber(color[2]) or 1, tonumber(color[3]) or 1,
      tonumber(color[4]) or 1)
    local image = love.graphics.newImage(data)
    if image.setFilter then image:setFilter("nearest", "nearest") end
    return image
  end)
  return ok and texture or nil
end

local function transformPoint(matrix, point)
  return matrix[1] * point[1] + matrix[2] * point[2]
      + matrix[3] * point[3] + matrix[4],
    matrix[5] * point[1] + matrix[6] * point[2]
      + matrix[7] * point[3] + matrix[8],
    matrix[9] * point[1] + matrix[10] * point[2]
      + matrix[11] * point[3] + matrix[12]
end

local function skinMatrices(parsed, value, side)
  local joints = Hands.jointPose(value, side, parsed.contract)
  local globals, out = {}, {}
  for slot, name in ipairs(parsed.jointNames) do
    local rotation = joints[name].rotation
    local localMatrix = parsed.jointLocal[slot]
    if rotation.y ~= 0 then
      localMatrix = Mat4.mul(localMatrix, Mat4.rotateY(rotation.y))
    end
    if rotation.x ~= 0 then
      localMatrix = Mat4.mul(localMatrix, Mat4.rotateX(rotation.x))
    end
    if rotation.z ~= 0 then
      localMatrix = Mat4.mul(localMatrix, Mat4.rotateZ(rotation.z))
    end
    local parent = parsed.jointParents[slot]
    globals[slot] = parent and Mat4.mul(globals[parent], localMatrix)
      or localMatrix
    out[slot] = Mat4.mul(globals[slot], parsed.inverseBind[slot])
  end
  return out
end

local function skinnedVertices(parsed, value, side)
  local matrices = skinMatrices(parsed, value, side)
  local out = {}
  for index, position in ipairs(parsed.positions) do
    local jointSet, weightSet = parsed.joints[index], parsed.weights[index]
    local x, y, z, total = 0, 0, 0, 0
    for influence = 1, 4 do
      local weight = tonumber(weightSet[influence]) or 0
      if weight > 0 then
        local slot = math.floor(tonumber(jointSet[influence]) or -1) + 1
        local matrix = matrices[slot]
        if not matrix then error("hand vertex uses an unknown joint") end
        local px, py, pz = transformPoint(matrix, position)
        x, y, z, total = x + px * weight, y + py * weight,
          z + pz * weight, total + weight
      end
    end
    if total < 0.999 or total > 1.001 then
      if total <= 0 then error("hand vertex has no skin weights") end
      x, y, z = x / total, y / total, z / total
    end
    local uv = parsed.uv[index]
    -- The authored source UVs use the usual modelling-tool bottom-left V;
    -- LOVE Image coordinates are top-left, so flip V once at import.
    out[index] = { x, y, z, tonumber(uv[1]) or 0,
      1 - (tonumber(uv[2]) or 0), 1 }
  end
  return out
end

local function dynamicMesh(vertices, indices)
  if not (love and love.graphics and love.graphics.newMesh) then return nil end
  local ok, mesh = pcall(love.graphics.newMesh, Voxel3D.FORMAT, vertices,
    "triangles", "dynamic")
  if not (ok and mesh and type(mesh.setVertexMap) == "function"
      and type(mesh.setVertices) == "function") then return nil end
  local mapped = pcall(mesh.setVertexMap, mesh, indices)
  return mapped and mesh or nil
end

local function resources(value, side)
  local pose = Hands.pose(value, side)
  local parsed, err = asset(pose, pose.side)
  if not parsed then return nil, err end
  local key = parsed.descriptor.styleId .. ":" .. parsed.descriptor.side
  if resourceCache[key] ~= nil then
    return resourceCache[key] or nil, errorCache["gpu:" .. key]
  end
  local ok, result = pcall(function()
    local vertices = skinnedVertices(parsed, { grip = 0, trigger = 0,
      pointing = false, styleId = pose.styleId }, pose.side)
    local skinTexture = imageTexture(parsed.imageBytes,
      "openxr_hand_" .. pose.side .. ".png")
    if not skinTexture then error("hand texture unavailable") end
    local made = { parsed = parsed, poseKey = nil, resources = {} }
    for index, primitive in ipairs(parsed.primitives) do
      local mesh = dynamicMesh(vertices, primitive.indices)
      local material = parsed.materials[primitive.material]
      if not (mesh and material) then error("hand mesh allocation failed") end
      made.resources[index] = { mesh = mesh,
        texture = skinTexture, material = material.name }
    end
    return made
  end)
  if ok and result then resourceCache[key] = result
  else
    resourceCache[key] = false
    errorCache["gpu:" .. key] = tostring(result)
  end
  return resourceCache[key] or nil, errorCache["gpu:" .. key]
end

local function poseKey(value, side)
  local pose = Hands.pose(value, side)
  return table.concat({ pose.styleId, pose.side,
    ("%.4f"):format(pose.grip), ("%.4f"):format(pose.trigger),
    pose.thumbRest and "thumbrest" or "thumbfree",
    pose.closedFist and "fist" or "notfist",
    pose.pointing and "point" or "free", pose.holding and "held" or "empty",
    pose.gripStyle or "default-grip",
    pose.thumbGrip ~= nil and ("thumb:%.4f"):format(pose.thumbGrip) or "thumb:auto",
    pose.thumbPose or "thumb-pose:auto" },
    ":")
end

local fingertipCache = {}
local emptyContactPose = {}
local contactFields = { "styleId", "id", "grip", "trigger", "thumbRest",
  "closedFist", "pointing", "holding", "gripStyle", "thumbGrip", "thumbPose" }

-- The touch point is the authored index-tip joint, with exactly the same
-- wrist offset/scale and held-hand correction as QuestHandsRenderer. Cache
-- joint evaluation by semantic pose: no mesh skinning, uploads or readback.
function Hands.indexTip(value, side)
  value = type(value) == "table" and value or emptyContactPose
  side = side == "left" and "left" or "right"
  local cached = fingertipCache[side]
  local changed = not cached
  if cached then
    for _, field in ipairs(contactFields) do
      if cached.input[field] ~= value[field] then changed = true; break end
    end
  end
  if changed then
    local parsed = asset(value, side)
    if not parsed then return nil end
    local joints, globals = Hands.jointPose(value, side, parsed.contract), {}
    local tip
    for slot, name in ipairs(parsed.jointNames) do
      local r, m = joints[name].rotation, parsed.jointLocal[slot]
      if r.y ~= 0 then m = Mat4.mul(m, Mat4.rotateY(r.y)) end
      if r.x ~= 0 then m = Mat4.mul(m, Mat4.rotateX(r.x)) end
      if r.z ~= 0 then m = Mat4.mul(m, Mat4.rotateZ(r.z)) end
      local parent = parsed.jointParents[slot]
      globals[slot] = parent and Mat4.mul(globals[parent], m) or m
      if name == "index_tip" then tip = globals[slot]; break end
    end
    if not tip then return nil end
    local wrist, scale = Hands.gripToWrist(value, side), Hands.visualScale(value, side)
    cached = { input = {}, x = tip[4]*scale+wrist[1],
      y = tip[8]*scale+wrist[2], z = tip[12]*scale+wrist[3] }
    for _, field in ipairs(contactFields) do cached.input[field] = value[field] end
    fingertipCache[side] = cached
  end
  local x, y, z = cached.x, cached.y, cached.z
  if side == "right" and type(value) == "table" and value.holding == true
      and value.gripStyle == "flat_support" then
    local yaw, pitch = tonumber(value.gripRotationY) or 0, tonumber(value.gripRotationX) or 0
    if yaw ~= yaw or math.abs(yaw) == math.huge then yaw = 0 end
    if pitch ~= pitch or math.abs(pitch) == math.huge then pitch = 0 end
    x, z = math.cos(yaw)*x+math.sin(yaw)*z, -math.sin(yaw)*x+math.cos(yaw)*z
    y, z = math.cos(pitch)*y-math.sin(pitch)*z, math.sin(pitch)*y+math.cos(pitch)*z
  end
  return x, y, z
end

function Hands.prepare(value, side)
  return resources(value, side) ~= nil
end

function Hands.draw(value, side, model)
  local made = resources(value, side)
  if not made then return false end
  local key = poseKey(value, side)
  if made.poseKey ~= key then
    local ok, vertices = pcall(skinnedVertices, made.parsed, value, side)
    if not ok then return false end
    for _, resource in ipairs(made.resources) do
      if not pcall(resource.mesh.setVertices, resource.mesh, vertices) then
        return false
      end
    end
    made.poseKey = key
  end

  local oldCull
  if love and love.graphics and love.graphics.getMeshCullMode then
    local ok, value = pcall(love.graphics.getMeshCullMode)
    if ok then oldCull = value end
  end
  if love and love.graphics and love.graphics.setMeshCullMode then
    pcall(love.graphics.setMeshCullMode, "none")
  end
  local ok = true
  for _, resource in ipairs(made.resources) do
    ok = pcall(Voxel3D.draw, resource.mesh, resource.texture, model) and ok
  end
  if oldCull and love and love.graphics and love.graphics.setMeshCullMode then
    pcall(love.graphics.setMeshCullMode, oldCull)
  end
  return ok
end

function Hands.status(value, side)
  local pose = Hands.pose(value, side)
  local descriptor = Hands.resolve(pose.styleId, pose.side)
  local key = descriptor and (descriptor.styleId .. ":" .. descriptor.side) or nil
  return { styleId = pose.styleId, side = pose.side,
    resolved = descriptor ~= nil,
    parsed = key and assetCache[key] ~= nil and assetCache[key] ~= false or false,
    gpuReady = key and resourceCache[key] ~= nil
      and resourceCache[key] ~= false or false,
    error = key and (errorCache["gpu:" .. key] or errorCache[key])
      or "unknown-hand-style" }
end

function Hands.invalidate()
  for _, made in pairs(resourceCache) do
    if type(made) == "table" then
      for _, resource in ipairs(made.resources or {}) do
        if resource.mesh and type(resource.mesh.release) == "function" then
          pcall(resource.mesh.release, resource.mesh)
        end
      end
    end
  end
  assetCache, resourceCache, errorCache = {}, {}, {}
  fingertipCache = {}
end

Hands.JOINTS = copy(JOINTS)

return Hands
