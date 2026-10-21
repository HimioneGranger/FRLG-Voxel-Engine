-- FRLG_VOXEL: emissive (glowing-window) masks (worker "atmos", GW-P4,
-- daynight-weather-hook/DESIGN.md 3.5). One mask per (pair, layer) atlas,
-- in that atlas's texel grid: 1 at a lit texel, 0 elsewhere; mipmapped so
-- distant windows glow by their glass coverage, and the shader needs one
-- extra fetch (DESIGN.md 3.4).
--
-- Sources, unioned into one mask:
--   1. Window GLASS texels (always on; "glow-precise", 2026-09-28): the
--      exact atlas texels Scene.lua's glassTexels found inside W3's
--      registered windows (geom.stats.buildingInfo[i].windows), registered
--      here per pair and layer with addGlass as each map is built. Only the
--      glass itself: frames, mullions, sills and siding in the same tile are
--      never marked, so the shader (emitMix = mask * u_emitOn * u_emitGain
--      * v_emit) lights the panes and nothing around them. This replaces
--      the earlier atlas-wide colour key (six sampled glass blues found by
--      a GPU pass, WINDOW_KEY) and the shader's relaxed blue/bright test,
--      which also matched the navy frames (66,74,107 in the atlas) and the
--      light siding, so whole wall cells glowed. Texel POSITIONS are stored,
--      not colours, so a later palette swap on the atlas does not change
--      which texels glow.
--   2. A registered emissive provider (FRLG_RTC_BRIDGE, via vrHost 1.2
--      emissive.registerProvider, HostApi.lua anchored edit) reporting
--      exactly the texels RTC painted this session. Provider contract
--      (DESIGN.md 4.4):
--        p.revision() -> comparable value, bumped when the paint state changes.
--        p.texels(pair) -> { under = {{x,y}|{x=,y=}, ...}, over = {...} } | nil
--        p.originals(pair) -> pre-paint pixels, for WorldSource's stale-scan
--          fix (not used here; kept on the provider for WorldSource.lua).
--      Provider texels are gated by v_emit like everything else, so they
--      glow only on registered window triangles.
-- The shader supplies the warm colour itself (a fixed uniform: the source
-- art stays blue by design); this mask only says "is this texel lit", so
-- no per-pixel colour ever needs to leave the mod (DESIGN.md 6.3).
local V = ...
local _ = V

local Emissive = {}
Emissive.__index = Emissive

function Emissive.new()
  -- glass[pair][layer] = { w, h, set = { [y * w + x] = true }, n, rev }
  -- byPair[pair][layer] = { image, g, rev, providerKey, w, h } (the built mask)
  return setmetatable({ byPair = {}, glass = {} }, Emissive)
end

local function xy(t)
  local x = tonumber(t.x or t[1])
  local y = tonumber(t.y or t[2])
  return x, y
end

-- Register glass texels (idx = y * w + x) for one (pair, layer) atlas of
-- size w x h. Unioned with every earlier registration for that atlas (a
-- texel that is glass in one map's window tile is the same atlas texel for
-- every map using the pair; v_emit keeps non-window triangles dark). A new
-- atlas size starts a fresh set. Returns how many texels were new.
function Emissive:addGlass(pair, layer, w, h, texels)
  w, h = tonumber(w), tonumber(h)
  if not (pair and layer and w and h and w > 0 and h > 0 and type(texels) == "table") then return 0 end
  local byLayer = self.glass[pair]
  if not byLayer then byLayer = {}; self.glass[pair] = byLayer end
  local g = byLayer[layer]
  if not g or g.w ~= w or g.h ~= h then
    g = { w = w, h = h, set = {}, n = 0, rev = g and (g.rev + 1) or 0 }
    byLayer[layer] = g
  end
  local added, limit = 0, w * h
  for i = 1, #texels do
    local idx = tonumber(texels[i])
    if idx and idx >= 0 and idx < limit and not g.set[idx] then
      g.set[idx] = true
      g.n = g.n + 1
      added = added + 1
    end
  end
  if added > 0 then g.rev = g.rev + 1 end
  return added
end

-- Glass texel count for one (pair, layer) (tests / diagnostics).
function Emissive:glassCount(pair, layer)
  local g = self.glass[pair] and self.glass[pair][layer]
  return g and g.n or 0
end

-- Build the mask Image: glass texels plus provider texels. nil when there
-- is nothing to mark or the GPU objects cannot be made.
local function buildMask(g, w, h, list)
  local okD, data = pcall(love.image.newImageData, w, h, "rgba8")
  if not okD or not data then return nil end
  local n = 0
  if g then
    for idx in pairs(g.set) do
      data:setPixel(idx % w, math.floor(idx / w), 1, 1, 1, 1)
      n = n + 1
    end
  end
  if type(list) == "table" then
    for i = 1, #list do
      local x, y = xy(list[i])
      if x and y and x >= 0 and y >= 0 and x < w and y < h then
        data:setPixel(math.floor(x), math.floor(y), 1, 1, 1, 1)
        n = n + 1
      end
    end
  end
  if n == 0 then return nil end
  local okI, img = pcall(love.graphics.newImage, data, { mipmaps = true })
  local mipmapped = okI and img ~= nil
  if not mipmapped then okI, img = pcall(love.graphics.newImage, data) end
  if not okI or not img then return nil end
  -- nearest inside a level (texel-exact pane edges up close, the same as
  -- the atlas mirrors Mip.get samples), linear between levels (a distant
  -- window glows by how much of it is glass)
  pcall(img.setFilter, img, "nearest", "nearest")
  if mipmapped then pcall(img.setMipmapFilter, img, "linear", 0) end
  pcall(img.setWrap, img, "clamp", "clamp")
  return img
end

-- Returns the mask Image for one (pair, layer), or nil if nothing glows
-- there. Rebuilt only when that atlas's glass set grew (a new map with
-- windows was built) or the provider's revision() changed. liveImage (the
-- image Scene.lua is about to draw with) sizes the mask when only provider
-- texels exist. Never throws; any failure just means u_emitOn reads 0.
--
-- Lab 8 P0-1 (fix 1a, 2026-09-29): revision() is the cache key and texels()
-- is read only on a cache MISS. Scene.draw asks once per map record, layer
-- and eye (about 17 times a frame); reading texels() before the cache check
-- rebuilt RTC's whole lit-texel list every time (2,571 small tables in
-- Viridian at night, ~4 MB of garbage a frame on the Lab 7 desktop A/B).
-- The mask itself was already rebuilt only on a key change, so skipping
-- texels() on a hit changes nothing that is drawn.
function Emissive:maskFor(pair, layer, liveImage, provider)
  if not pair then return nil end
  local g = self.glass[pair] and self.glass[pair][layer]
  if g and g.n == 0 then g = nil end
  local rec = self.byPair[pair]
  if not rec then rec = {}; self.byPair[pair] = rec end
  local sub = rec[layer]

  local prev = nil
  if provider then
    local okR, r = pcall(provider.revision)
    prev = okR and r or nil
  end
  local providerKey = provider and (prev ~= nil and tostring(prev) or "err") or "none"
  if providerKey == "err" and sub then
    -- a transient provider hiccup: keep whatever was cached rather than
    -- flicker windows off
    return sub.image
  end
  local w, h
  if g then
    w, h = g.w, g.h
  elseif liveImage and liveImage.getDimensions then
    local okDim, lw, lh = pcall(liveImage.getDimensions, liveImage)
    if okDim then w, h = lw, lh end
  end
  local rev = g and g.rev or -1
  if sub and sub.g == g and sub.rev == rev and sub.providerKey == providerKey and sub.w == w and sub.h == h then
    return sub.image
  end

  -- cache miss: only now read the provider's texel list (fix 1a)
  local list = nil
  if provider then
    local okT, texels = pcall(provider.texels, pair)
    if okT and type(texels) == "table" then list = texels[layer] end
  end
  local img = nil
  local hasList = type(list) == "table" and #list > 0
  if w and h and w > 0 and h > 0 and (g or hasList) then
    img = buildMask(g, w, h, hasList and list or nil)
  end
  if sub and sub.image and sub.image ~= img and sub.image.release then pcall(sub.image.release, sub.image) end
  rec[layer] = { image = img, g = g, rev = rev, providerKey = providerKey, w = w, h = h }
  return img
end

function Emissive:release()
  for _, rec in pairs(self.byPair) do
    for _, sub in pairs(rec) do
      if sub.image and sub.image.release then pcall(sub.image.release, sub.image) end
    end
  end
  self.byPair = {}
end

return Emissive
