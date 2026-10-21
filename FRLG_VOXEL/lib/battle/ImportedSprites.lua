-- Optional private sprite provider for the FRLG/Emerald battle cards.
-- This adapter only changes a draw descriptor. Native battle state and effects
-- remain owned by the engine. No imported pixels live in this module.
--
-- Provider contracts (exports.apiVersion; separate from the manifest's
-- engine "api" field):
--   1  fixed 64x64 frames, groundOffset 32 (provider 1.x)
--   2  original resolution: the animation's stable union size, at most
--      256x256, groundOffset = height / 2 (provider 2.x)
-- A frame that breaks its contract keeps the native picture.
local Imported = {}
local ID = "GEN5_PRIVATE_SPRITES"
Imported.MAX_SIZE = 256

local function safeCall(t, name, ...)
  if not (t and type(t[name]) == "function") then return nil end
  local ok, a, b, c = pcall(t[name], ...)
  if ok then return a, b, c end
end

local function dimension(n)
  return type(n) == "number" and n == n and n % 1 == 0 and n >= 1 and n <= Imported.MAX_SIZE
end

-- The provider contract version this receiver accepts, or nil.
local function contract(api)
  if not (api and type(api.frame) == "function") then return nil end
  if api.apiVersion == 1 then return 1 end
  if api.apiVersion == 2 and (api.api == nil or api.api == 2) then return 2 end
  return nil
end

-- Width and height of a frame that keeps its contract, else nil.
function Imported.checkFrame(version, frame)
  if not (type(frame) == "table" and frame.image) then return nil end
  local w, h = frame.width, frame.height
  if version == 1 then
    if w == 64 and h == 64 and frame.groundOffset == 32 then return 64, 64 end
    return nil
  end
  if version ~= 2 or not (dimension(w) and dimension(h)) or frame.groundOffset ~= h / 2 then return nil end
  local image = frame.image
  local okD, iw, ih = pcall(function() return image:getDimensions() end)
  if not (okD and iw == w and ih == h) then return nil end
  return w, h
end

-- Returns image, restCy[, size]. size = { width, height } only for an
-- imported picture; the caller centres it with width / 2, height / 2.
function Imported.resolve(V, engine, request, nativeImage, nativeY)
  if not (V and V.mod and type(V.mod.find) == "function")
      or request.substitute or request.ghost or (request.form or 0) ~= 0 then
    return nativeImage, nativeY
  end
  local handle = safeCall(V.mod, "find", ID)
  local api = handle and handle.exports
  local version = contract(api)
  if not version then return nativeImage, nativeY end
  local okP, Pokemon = pcall(engine, "src.core.game3.pokemon")
  if not okP or not Pokemon then return nativeImage, nativeY end
  local sp, shiny, personality = request.species, nil, nil
  if request.ui and request.ui.picArgs then
    sp, shiny, personality = safeCall(request.ui, "picArgs", request.battler, sp)
  end
  if not sp then return nativeImage, nativeY end
  local dex = safeCall(Pokemon, "national", sp)
  -- Personality-dependent pictures and alternate forms retain native art until
  -- their exact form mapping is imported. Never show a different form silently.
  if not dex or dex == 201 or dex == 327 or dex == 351 or dex == 386 then
    return nativeImage, nativeY
  end
  local mon = request.battler and request.battler.mon
  if shiny == nil then shiny = safeCall(Pokemon, "isShiny", mon) == true end
  personality = personality or (mon and mon.personality)
  local gender = safeCall(Pokemon, "gender", sp, personality)
  local frame = safeCall(api, "frame", {
    dex = dex, side = request.side == "player" and "back" or "front",
    shiny = shiny == true, gender = gender == "F" and "female" or "male",
    form = 0, battleId = request.battle, battlerId = request.id, mon = mon,
  })
  local width, height = Imported.checkFrame(version, frame)
  if not width then return nativeImage, nativeY end
  local elevation = 0
  if request.side == "enemy" then
    local okC, coords = pcall(engine, "src.core.game3.battle.pic_coords")
    if okC and coords then
      local okE, e = pcall(function() return coords.elev and coords.elev[sp] end)
      if okE then elevation = tonumber(e) or 0 end
    end
  end
  -- Feet on the slot's ground line (raised by the native elevation): the
  -- centre sits half the picture's own height above it, at original size.
  local ground = request.baseY + (request.side == "player" and 36 or 32)
  return frame.image, ground - frame.groundOffset - elevation, { width = width, height = height }
end

return Imported
