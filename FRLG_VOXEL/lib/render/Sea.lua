-- FRLG_VOXEL: the open sea past the edge of the built world (tour review R2,
-- 2026-09-28). Maps with water on their horizon ended in a hard line where
-- the border ring's sea stopped and the sky's below-horizon band began. In
-- the horizon sectors that are mostly water (Scene:seaView), a flat sea
-- plane now continues from under the eye out to RADIUS_M, a hair below the
-- map's water surface (the real water always wins the depth test), textured
-- with the map's own sea tile repeated per cell (a CPU copy of that atlas
-- slot, refreshed for the tile animation) and hazed like the terrain -- so it
-- reaches the fog colour, which is the sky's horizon colour, before it ends.
-- Not drawn in the Quest table-top diorama (the model ends at the table).
local V = ...
local Shaders = V.require("render/Shaders")
-- Lab 58 #12 (flag "requirememo"): the tileset module table is remembered after the first success.
local okS58, Speed58 = pcall(V.require, "perf/Speed58")
if not (okS58 and type(Speed58) == "table") then Speed58 = nil end
local ntMemo

local Sea = {}

Sea.RADIUS_M = 140        -- metres from the eye (inside Camera.FAR = 150)
Sea.DROP = 0.02           -- cells below the map's water surface
Sea.ON, Sea.OFF = 0.5, 0.35   -- sector water share hysteresis
Sea.REFRESH = 8           -- frames between tile animation refreshes

local mesh, img, data, texKey, lastFrame
local sectorOn = {}

local function tile(pair, px, frame)
  if not (pair and px) then return nil end
  local okN, NT
  if Speed58 and Speed58.on("requirememo") then
    if ntMemo then
      okN, NT = true, ntMemo
    else
      okN, NT = pcall(require, "src.core.game3.tileset_native")
      if okN and type(NT) == "table" then ntMemo = NT end
    end
  else
    okN, NT = pcall(require, "src.core.game3.tileset_native")
  end
  local ts = okN and type(NT) == "table" and NT._pairs and NT._pairs[pair]
  local src = ts and ts.imageData
  if not (src and src.getDimensions) then return nil end
  local key = tostring(pair) .. ":" .. px[1] .. "," .. px[2]
  if key ~= texKey or not img then
    if img then pcall(img.release, img) end
    img, data, texKey, lastFrame = nil, nil, nil, nil
    local okD, d = pcall(love.image.newImageData, 16, 16, "rgba8")
    if not okD then return nil end
    pcall(d.paste, d, src, 0, 0, px[1], px[2], 16, 16)
    local okI, im = pcall(love.graphics.newImage, d, { mipmaps = true })
    if not okI or not im then return nil end
    pcall(im.setFilter, im, "nearest", "nearest")
    pcall(im.setMipmapFilter, im, "linear", 0)
    pcall(im.setWrap, im, "repeat", "repeat")
    img, data, texKey, lastFrame = im, d, key, frame
  elseif frame and lastFrame and (frame - lastFrame >= Sea.REFRESH or frame < lastFrame) then
    lastFrame = frame
    pcall(data.paste, data, src, 0, 0, px[1], px[2], 16, 16)
    pcall(img.replacePixels, img, data)
  end
  return img
end
Sea._tile = tile
function Sea.resetEngineMemo() ntMemo = nil end

-- Which sectors get sea (with hysteresis so a sector does not flicker).
function Sea.sectors(frac, seg)
  local on = {}
  for i = 1, seg do
    local f = frac and frac[i] or 0
    if sectorOn[i] then on[i] = f >= Sea.OFF else on[i] = f >= Sea.ON end
    sectorOn[i] = on[i]
  end
  return on
end

-- Fan of one triangle per sea sector around (ex, ez), at height y, radius r
-- (cells); UVs are world cells so the tile repeats on the map's own grid.
function Sea.vertices(ex, ez, y, r, on, seg)
  local out = {}
  for i = 1, seg do
    if on[i] then
      local a0, a1 = (i - 1) / seg * 2 * math.pi, i / seg * 2 * math.pi
      local x0, z0 = ex + math.cos(a0) * r, ez + math.sin(a0) * r
      local x1, z1 = ex + math.cos(a1) * r, ez + math.sin(a1) * r
      out[#out + 1] = { ex, y, ez, ex, ez, 0, 1, 0 }
      out[#out + 1] = { x0, y, z0, x0, z0, 0, 1, 0 }
      out[#out + 1] = { x1, y, z1, x1, z1, 0, 1, 0 }
    end
  end
  return out
end

-- Lab 55 SEA ONCE (OutdoorPerf.sea): the fan only depends on the frame (the
-- view centre, sea height and sector mask are per frame, not per eye), so it
-- is built into reused vertex tables and uploaded once per frame; the second
-- eye draws the same mesh contents. Same vertices, same uniforms.
local Perf = V.require("render/OutdoorPerf")
local fanRows, fanKey = {}, { frame = nil }
local function fanInto(ex, ez, y, r, on, seg)
  local n = 0
  for i = 1, seg do
    if on[i] then
      local a0, a1 = (i - 1) / seg * 2 * math.pi, i / seg * 2 * math.pi
      local x0, z0 = ex + math.cos(a0) * r, ez + math.sin(a0) * r
      local x1, z1 = ex + math.cos(a1) * r, ez + math.sin(a1) * r
      for k = 1, 3 do
        n = n + 1
        local v = fanRows[n]
        if not v then v = { 0, 0, 0, 0, 0, 0, 1, 0 }; fanRows[n] = v end
        local px, pz = ex, ez
        if k == 2 then px, pz = x0, z0 elseif k == 3 then px, pz = x1, z1 end
        v[1], v[2], v[3], v[4], v[5], v[6], v[7], v[8] = px, y, pz, px, pz, 0, 1, 0
      end
    end
  end
  for i = #fanRows, n + 1, -1 do fanRows[i] = nil end
  return fanRows, n
end
Sea._fanInto = fanInto -- test seam

-- view = Scene:seaView result; eye = { x, z } cells; m = metres per cell.
-- Returns the number of draw calls (0 or 1).
function Sea.draw(env, view, eye, m, frame, seg)
  if Perf.sea and frame then return Sea._drawOnce(env, view, eye, m, frame, seg) end
  if not (view and view.seaY and view.pair and view.px) then return 0 end
  local on = Sea.sectors(view.frac, seg)
  local any = false
  for i = 1, seg do if on[i] then any = true break end end
  if not any then return 0 end
  local tex = tile(view.pair, view.px, frame)
  local shader = Shaders.get("OPAQUE")
  if not (tex and shader) then return 0 end
  local verts = Sea.vertices(eye[1], eye[2], view.seaY - Sea.DROP, Sea.RADIUS_M / m, on, seg)
  if not mesh then
    local cap = {}
    for i = 1, seg * 3 do cap[i] = { 0, 0, 0, 0, 0, 0, 1, 0 } end
    local okM, mm = pcall(love.graphics.newMesh, Shaders.FORMAT, cap, "triangles", "stream")
    if not okM then return 0 end
    mesh = mm
  end
  mesh:setVertices(verts)
  mesh:setDrawRange(1, #verts)
  mesh:setTexture(tex)
  local g = love.graphics
  g.setShader(shader)
  Shaders.frame(shader, env)
  Shaders.shadow(shader, nil)
  Shaders.texSize(shader, nil)   -- repeating tile, not an atlas slot
  Shaders.send(shader, "u_mvp", "row", env.vp)
  g.draw(mesh)
  g.setShader()
  return 1
end

function Sea._drawOnce(env, view, eye, m, frame, seg)
  if not (view and view.seaY and view.pair and view.px) then return 0 end
  local fresh = fanKey.frame ~= frame or fanKey.view ~= view or fanKey.x ~= eye[1] or fanKey.z ~= eye[2]
    or fanKey.m ~= m or fanKey.seg ~= seg or fanKey.y ~= view.seaY or not mesh
  local on
  if fresh then
    on = Sea.sectors(view.frac, seg)
    local any = false
    for i = 1, seg do if on[i] then any = true break end end
    fanKey.any = any
    if not any then
      fanKey.frame, fanKey.view, fanKey.x, fanKey.z, fanKey.m, fanKey.seg, fanKey.y = frame, view, eye[1], eye[2], m, seg, view.seaY
      return 0
    end
  elseif not fanKey.any then
    return 0
  end
  local tex = tile(view.pair, view.px, frame)
  local shader = Shaders.get("OPAQUE")
  if not (tex and shader) then return 0 end
  if not mesh then
    local cap = {}
    for i = 1, seg * 3 do cap[i] = { 0, 0, 0, 0, 0, 0, 1, 0 } end
    local okM, mm = pcall(love.graphics.newMesh, Shaders.FORMAT, cap, "triangles", "stream")
    if not okM then return 0 end
    mesh = mm
    fresh = true
  end
  if fresh then
    if not on then on = Sea.sectors(view.frac, seg) end
    local verts, n = fanInto(eye[1], eye[2], view.seaY - Sea.DROP, Sea.RADIUS_M / m, on, seg)
    mesh:setVertices(verts)
    mesh:setDrawRange(1, n)
    fanKey.frame, fanKey.view, fanKey.x, fanKey.z, fanKey.m, fanKey.seg, fanKey.y = frame, view, eye[1], eye[2], m, seg, view.seaY
  end
  mesh:setTexture(tex)
  local g = love.graphics
  g.setShader(shader)
  Shaders.frame(shader, env)
  Shaders.shadow(shader, nil)
  Shaders.texSize(shader, nil)   -- repeating tile, not an atlas slot
  Shaders.send(shader, "u_mvp", "row", env.vp)
  g.draw(mesh)
  g.setShader()
  return 1
end

function Sea.release()
  if mesh then pcall(mesh.release, mesh) end
  if img then pcall(img.release, img) end
  mesh, img, data, texKey, lastFrame = nil, nil, nil, nil, nil
  for k in pairs(sectorOn) do sectorOn[k] = nil end
  fanKey.frame, fanKey.view = nil, nil -- Lab 55
end

return Sea
