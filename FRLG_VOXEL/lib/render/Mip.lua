-- FRLG_VOXEL: GPU mirrors of the live tileset atlases.
--
-- Mip.get: a mipmapped copy (review R3: now used by the opaque, cutout-under
-- and over layers). The engine's atlas images have no mipmaps and are
-- patched in place by tileset animation / palette code (ts.image:
-- replacePixels), so instead of copying pixels once we keep a Canvas with
-- mipmaps="auto" per atlas and re-blit the live image into it every REFRESH
-- frames; LOVE regenerates the chain when the canvas is released. Sampling:
-- nearest inside a level (crisp pixel art up close), linear between levels.
-- Tiles are 16 px on a 16 px grid, so mip levels 1-4 never mix two tiles.
-- The CUTOUT shader scales alpha back up by lod so distant leaves and grass
-- do not thin out in the averaged levels.
--
-- Mip.keyed (review R2): the same, drawn through the KEY shader so the
-- ground palette -- (115,206,165), (66,181,140), (165,230,197), the greens
-- behind FRLG's grass/fence/sign art, plus the path colour (189,239,214)
-- behind Pallet's flower-bed fence (mid 644) -- becomes alpha 0 for the
-- mesher's cutoutKeyed list (tall-grass tufts, fence and sign cards).
-- Measured on the live pallet_outdoor and viridian_outdoor atlases: mid 13
-- (tall grass) keys 134 of 256 texels (0 transparent before keying), mid
-- 644 keys 70 (30 without the path colour); the path colour occurs in no
-- other texel the cutoutKeyed list samples except the ground gaps at the
-- foot of fence 647.
-- Mipmapped when mips are on and supported, plain otherwise.
--
-- Worker "atmos" (GW-P4, daynight-weather-hook/DESIGN.md 7.3): the two
-- helpers below (Mip.pickFormat, Mip.newBlankCanvas) generalise this file's
-- own canvas-creation logic (newMirror) for render/Emissive.lua's per-texel
-- glow masks, which build their own pixels instead of re-blitting a live
-- atlas image and so cannot reuse newMirror directly. Mip.get/Mip.keyed and
-- their REFRESH-frame re-blit cadence are unchanged.
local V = ...
local Shaders = V.require("render/Shaders")
-- Lab 58 #8 (flag "mipgate"): refresh a mirror only when its source changed. nil = absent = the Lab 57 code path.
local okS58, Speed58 = pcall(V.require, "perf/Speed58")
if not (okS58 and type(Speed58) == "table") then Speed58 = nil end

local Mip = {}
Mip.REFRESH = 4
Mip.SAFETY = 64 -- mipgate: an unchanged-looking mirror is still re-blitted this often (a change source the signature cannot see)
Mip.KEYS = {
  { 115 / 255, 206 / 255, 165 / 255 },
  { 66 / 255, 181 / 255, 140 / 255 },
  { 165 / 255, 230 / 255, 197 / 255 },
  { 189 / 255, 239 / 255, 214 / 255 },   -- path (Pallet flower-bed fence 644)
}

local mirrors = setmetatable({}, { __mode = "k" }) -- source image -> record
local keyedMip = setmetatable({}, { __mode = "k" })
local keyedPlain = setmetatable({}, { __mode = "k" })
local disabled = nil
local keyDisabled = nil

-- W3 note (r12 census round): roofs and walls seen at a slant alias --
-- mipmapping alone picks one LOD for the whole pixel, so a nearly edge-on
-- surface (a shallow roof pitch, a wall receding into the distance) either
-- blurs early or aliases before it does. Anisotropic filtering samples more
-- texels along the surface's own slant instead of a single round footprint.
-- Queried once and cached: LOVE 11's love.graphics.getSystemLimits().
-- anisotropy is the max degree the GPU/driver actually supports (1 = none,
-- e.g. some GLES implementations), so this never asks for more than the
-- device offers; Texture:setFilter's own anisotropy argument additionally
-- clamps silently, so a stale/high cached value is harmless either way.
local anisoMax
function Mip.anisotropy()
  if anisoMax then return anisoMax end
  anisoMax = 1
  if love and love.graphics and love.graphics.getSystemLimits then
    local ok, limits = pcall(love.graphics.getSystemLimits)
    if ok and type(limits) == "table" and type(limits.anisotropy) == "number" then
      anisoMax = math.max(1, limits.anisotropy)
    end
  end
  return anisoMax
end

-- r8 (one byte per texel) when the device's canvas formats list it, else
-- rgba8 (DESIGN.md 7.2 GLES rules: "check r8 canvas support at runtime").
-- Checked once and cached; pass false/nil to skip the check and always get
-- "rgba8" (callers that need alpha, or that never asked for r8).
local canvasFormat
function Mip.pickFormat(preferR8)
  if not preferR8 then return "rgba8" end
  if canvasFormat then return canvasFormat end
  canvasFormat = "rgba8"
  if love and love.graphics and love.graphics.getTextureFormats then
    local ok, formats = pcall(love.graphics.getTextureFormats, { canvas = true })
    if ok and type(formats) == "table" and formats.r8 then canvasFormat = "r8" end
  end
  return canvasFormat
end

-- A blank canvas of the given size, mipmapped when supported (opts.mipmaps
-- ~= false) and requested. For a caller that paints its own content into a
-- mirror-sized canvas (render/Emissive.lua) rather than re-blitting a live
-- source image, so newMirror's "blit `image` in" shape does not fit.
-- Returns canvas, mipmapped (bool) -- never throws; nil, err on failure.
function Mip.newBlankCanvas(w, h, opts)
  opts = opts or {}
  local settings = { format = opts.format or "rgba8", dpiscale = 1 }
  if opts.mipmaps ~= false then settings.mipmaps = "auto" end
  local ok, canvas = pcall(love.graphics.newCanvas, w, h, settings)
  if (not ok or not canvas) and settings.mipmaps then
    settings.mipmaps = nil
    ok, canvas = pcall(love.graphics.newCanvas, w, h, settings)
  end
  if not ok or not canvas then return nil, canvas end
  pcall(canvas.setFilter, canvas, opts.minFilter or "nearest", opts.magFilter or "linear")
  if settings.mipmaps then
    local okM = pcall(canvas.setMipmapFilter, canvas, "linear", 0)
    if not okM then settings.mipmaps = nil end
  end
  return canvas, settings.mipmaps ~= nil
end

function Mip.status()
  return disabled or "ok"
end

function Mip.keyStatus()
  return keyDisabled or "ok"
end

function Mip.disable(reason)
  disabled = reason or "disabled"
end

Mip.stats = { mirrors = 0, ms = 0, blits = 0, blitMs = 0 } -- Lab 57: first-use mirror canvases / blits (eye-pass probe)
local function nowS() return love.timer and love.timer.getTime and love.timer.getTime() or 0 end

local function newMirror(image, mipmapped)
  local t0 = nowS()
  Mip.stats.mirrors = Mip.stats.mirrors + 1
  local w, h = image:getDimensions()
  local settings = { dpiscale = 1 }
  if mipmapped then settings.mipmaps = "auto" end
  local ok, canvas = pcall(love.graphics.newCanvas, w, h, settings)
  if not ok or not canvas then return nil, "canvas unavailable: " .. tostring(canvas) end
  -- W3 note (r12 census): anisotropic filtering for roofs/walls seen at a
  -- slant, only meaningful with a mip chain to sample along; degrades to
  -- plain nearest/nearest (today's behaviour) when Mip.anisotropy() is 1
  -- (unsupported) or the mipmapped canvas itself is unavailable below.
  local aniso = mipmapped and Mip.anisotropy() or 1
  local okF = pcall(canvas.setFilter, canvas, "nearest", "nearest", aniso)
  if not okF then pcall(canvas.setFilter, canvas, "nearest", "nearest") end
  if mipmapped then
    local okM = pcall(canvas.setMipmapFilter, canvas, "linear", 0)
    if not okM then
      pcall(canvas.release, canvas)
      return nil, "setMipmapFilter unavailable"
    end
  end
  Mip.stats.ms = Mip.stats.ms + (nowS() - t0) * 1000
  return { canvas = canvas, frame = -1000 }
end

-- Re-blit `image` into rec.canvas (through `shader` when given). Lab 57 body, used when "mipgate" is off.
local function refreshOld(rec, image, frame, shader)
  if not (frame - rec.frame >= Mip.REFRESH or frame < rec.frame) then return true end
  rec.frame = frame
  local tb = nowS()
  local g = love.graphics
  g.push("all")
  local okD = pcall(function()
    g.setCanvas(rec.canvas)
    g.origin()
    g.setShader(shader)
    g.setScissor()
    g.setDepthMode()
    g.setBlendMode("replace", "premultiplied")
    g.setColor(1, 1, 1, 1)
    g.draw(image, 0, 0)
  end)
  g.pop()
  Mip.stats.blits = Mip.stats.blits + 1
  Mip.stats.blitMs = Mip.stats.blitMs + (nowS() - tb) * 1000
  return okD
end

-- Lab 58 #8. The source images are patched in place by the tileset animation (water, sand, flower frames), the
-- RSE animation counters, palette writes and the day/night repaint. The signature below is the engine's own
-- state for the tileset that owns `image`: the three animation frames, the RSE counters and
-- ts._editorLayerRevision (which the engine bumps on every palette write and night repaint, its own "the
-- texture changed" stamp). One number, no allocation. An image that no tileset owns, or a tileset the signature
-- cannot describe, has no signature and keeps the Lab 57 schedule.
local engNT, engTA
local function engine()
  if not engNT then
    local ok, m = pcall(require, "src.core.game3.tileset_native")
    if ok and type(m) == "table" then engNT = m end
  end
  if not engTA then
    local ok, m = pcall(require, "src.core.game3.tileset_anim")
    if ok and type(m) == "table" then engTA = m end
  end
  return engNT, engTA
end
function Mip.resetEngineMemo() engNT, engTA = nil, nil end

local function ownerOf(image)
  local NT = engine()
  local pairs_ = NT and NT._pairs
  if type(pairs_) ~= "table" then return nil, nil end
  for pair, ts in pairs(pairs_) do
    if type(ts) == "table" and (ts.image == image or ts.overImage == image) then return ts, pair end
  end
  return nil, nil
end

local function frameNum(v) return type(v) == "number" and v + 1 or 0 end

local function signature(rec, image, frame)
  local ts = rec.ts
  if not (ts and (ts.image == image or ts.overImage == image)) then
    -- not found yet (or the tileset was replaced): look again, but not on every due frame for foreign images
    if rec.ownerAt and frame >= rec.ownerAt and frame - rec.ownerAt < Mip.SAFETY then return nil end
    rec.ownerAt = frame
    rec.ts, rec.pair = ownerOf(image)
    ts = rec.ts
    if not ts then return nil end
  end
  local _, TA = engine()
  local entry = TA and TA._pairs and TA._pairs[rec.pair]
  local fw, fs, ff = 0, 0, 0
  if type(entry) == "table" then
    local fr = entry.frames
    if type(fr) == "table" then fw, fs, ff = frameNum(fr.water), frameNum(fr.sand), frameNum(fr.flower) end
    if entry.rse and type(TA._rse) == "table" then
      fw, fs = frameNum(TA._rse.primary), frameNum(TA._rse.secondary)
    end
  end
  local rev = ts._editorLayerRevision
  if type(rev) ~= "number" then rev = 0 end
  return ((rev * 64 + fw) * 64 + fs) * 64 + ff
end

local function sendKeys(shader)
  Shaders.send(shader, "u_key0", Mip.KEYS[1])
  Shaders.send(shader, "u_key1", Mip.KEYS[2])
  Shaders.send(shader, "u_key2", Mip.KEYS[3])
  Shaders.send(shader, "u_key3", Mip.KEYS[4])
end

local function blit(canvas, image, shader)
  local g = love.graphics
  g.setCanvas(canvas)
  g.origin()
  g.setShader(shader)
  g.setScissor()
  g.setDepthMode()
  g.setBlendMode("replace", "premultiplied")
  g.setColor(1, 1, 1, 1)
  g.draw(image, 0, 0)
end

-- Same schedule as Lab 57 (due when REFRESH frames have passed since the last scheduled one), but a due frame only
-- re-blits when the signature moved, the mirror is new or resized, or SAFETY frames passed since the last blit.
-- Returns ok, blitted.
local function refreshNew(rec, image, frame, shader)
  if not (frame - rec.frame >= Mip.REFRESH or frame < rec.frame) then return true, false end
  rec.frame = frame
  local sig = signature(rec, image, frame)
  local iw, ih = image:getDimensions()
  if sig ~= nil and sig == rec.sig and iw == rec.iw and ih == rec.ih
      and frame >= rec.blitFrame and frame - rec.blitFrame < Mip.SAFETY then
    return true, false
  end
  if rec.keyed then sendKeys(shader) end -- only when a blit really happens
  local tb = nowS()
  local g = love.graphics
  g.push("all")
  local okD = pcall(blit, rec.canvas, image, shader)
  g.pop()
  Mip.stats.blits = Mip.stats.blits + 1
  Mip.stats.blitMs = Mip.stats.blitMs + (nowS() - tb) * 1000
  if okD then rec.sig, rec.iw, rec.ih, rec.blitFrame = sig, iw, ih, frame end
  return okD, true
end

local function refresh(rec, image, frame, shader)
  if Speed58 and Speed58.on("mipgate") then
    local ok = refreshNew(rec, image, frame, shader)
    return ok
  end
  return refreshOld(rec, image, frame, shader)
end

-- Returns the mipmapped mirror of `image` (or `image` itself when mipmapped
-- canvases are unavailable on this GPU / LOVE build).
function Mip.get(image, frame)
  if disabled or not image then return image end
  local rec = mirrors[image]
  if not rec then
    local err
    rec, err = newMirror(image, true)
    if not rec then
      disabled = "mipmapped canvas unavailable: " .. tostring(err)
      return image
    end
    mirrors[image] = rec
  end
  if not refresh(rec, image, frame or 0, nil) then
    disabled = "mip refresh failed"
    return image
  end
  return rec.canvas
end

-- Returns the colour-keyed mirror of `image` (mipmapped when `mips` and
-- supported), or nil when keying is unavailable (callers then fall back to
-- the unkeyed atlas: the ground colour shows, nothing breaks).
function Mip.keyed(image, frame, mips)
  if keyDisabled or not image then return nil end
  local shader, serr = Shaders.get("KEY")
  if not shader then
    keyDisabled = "key shader unavailable: " .. tostring(serr)
    return nil
  end
  local useMips = mips and not disabled
  local store = useMips and keyedMip or keyedPlain
  local rec = store[image]
  if not rec then
    local err
    rec, err = newMirror(image, useMips)
    if not rec and useMips then
      rec, err = newMirror(image, false)
      store = keyedPlain
    end
    if not rec then
      keyDisabled = "keyed canvas unavailable: " .. tostring(err)
      return nil
    end
    store[image] = rec
  end
  if Speed58 and Speed58.on("mipgate") then
    rec.keyed = true -- Lab 58: refreshNew sends the key colours itself, right before a real blit
  elseif rec.frame < 0 or frame - rec.frame >= Mip.REFRESH or frame < rec.frame then
    Shaders.send(shader, "u_key0", Mip.KEYS[1])
    Shaders.send(shader, "u_key1", Mip.KEYS[2])
    Shaders.send(shader, "u_key2", Mip.KEYS[3])
    Shaders.send(shader, "u_key3", Mip.KEYS[4])
  end
  if not refresh(rec, image, frame or 0, shader) then
    keyDisabled = "keyed refresh failed"
    return nil
  end
  return rec.canvas
end

-- CPU reference of the key (tests, diagnostics, Scene's shadow alpha).
function Mip.isKey(r, g, b)
  for _, k in ipairs(Mip.KEYS) do
    local dr, dg, db = r - k[1], g - k[2], b - k[3]
    if dr * dr + dg * dg + db * db < 0.012 * 0.012 then return true end
  end
  return false
end

-- Keyed texel count in a 16x16 slot of an ImageData.
function Mip.countKeyed(imageData, sx, sy)
  local n = 0
  for y = 0, 15 do
    for x = 0, 15 do
      local r, g, b = imageData:getPixel(sx + x, sy + y)
      if Mip.isKey(r, g, b) then n = n + 1 end
    end
  end
  return n
end

function Mip.release()
  for _, store in ipairs({ mirrors, keyedMip, keyedPlain }) do
    for img, rec in pairs(store) do
      if rec.canvas and rec.canvas.release then pcall(rec.canvas.release, rec.canvas) end
      store[img] = nil
    end
  end
end

return Mip
