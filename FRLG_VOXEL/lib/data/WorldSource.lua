-- FRLG_VOXEL: adapts LIVE game3 state into the mesher's input contract
-- (see w2/INTEGRATION.md "Mesher interface"):
--   input = { width, height, cellAt(x, y) -> cell | nil, atlas, mapId, pair }
--   cell  = { mid, elevation, collision, behavior, layerType, coll, walkable }
--   atlas = { w, h, underRect(mid) -> u0,v0,u1,v1, overRect(mid) -> ... | nil,
--             hasOver(mid) -> bool, overCoverage(mid) -> 0..1 }
-- overRect(mid) is nil unless the mid has painted over-layer pixels (W3: it
-- used to return a rect for every mid of a layered pair, which the mesher
-- read as "every cell has over art" -- the live roofless-house bug, see
-- w3/REPORT.md). overCoverage(mid) is the fraction of the mid's 16x16 over
-- texels with alpha >= 0.5, i.e. that survive the renderer's CUTOUT test.
--
-- Sources (engine, read-only):
--   mapDef.midLayout:cellAt   src/core/game3/layout_native.lua   {mid, coll, elev}
--   Collision.behaviorOn      src/core/game3/collision.lua:195   pret MB_* byte
--   interaction_scripts.behaviors[pair][mid] (same table, for border cells)
--   NativeTileset.get(pair)   src/core/game3/tileset_native.lua  image/overImage
--   Map.computeWorld          src/core/game3/map.lua:66          neighbour offsets
--
-- `collision` is the runtime COLL_* byte the importer stored (0x00 walkable,
-- 0x07 blocked, 0x18 tall grass, 0x29 water, 0xA0-A3 ledges, 0xFF out of
-- bounds). pret's raw 2-bit collision is not retained after import; `walkable`
-- is CollPermissions.isWalkable(coll). `layerType` is DERIVED: 0 (NORMAL) when
-- the mid's baked over-atlas slot has any painted pixel, else 1 (COVERED) --
-- the raw metatile attribute word is import-time only.
local V = ...

-- Lab 57 SIGNS: static sign wording / destinations (read-only) and the native-family gate. A load
-- failure leaves every sign native (mapInput then carries no signLabels).
local okSM, SignMetadata = pcall(V.require, "data/SignMetadata")
local okSP, SignProfiles = pcall(V.require, "data/SignProfiles")
if not (okSM and okSP and type(SignMetadata) == "table" and type(SignProfiles) == "table") then
  SignMetadata, SignProfiles = nil, nil
end

local WorldSource = {}
WorldSource.__index = WorldSource

-- r9: water behaviours, the same sets as lib/mesh/MB.lua WATER_DEEP /
-- WATER_SHALLOW and COLL_WATER (w1 tests assert they stay equal; the mod
-- sandbox makes a sibling require unsafe, w1/LOADING.md).
local WATER_DEEP = {
  [0x10] = true, [0x11] = true, [0x12] = true, [0x13] = true, [0x15] = true,
  [0x1A] = true, [0x1B] = true,
  [0x50] = true, [0x51] = true, [0x52] = true, [0x53] = true,
}
local WATER_SHALLOW = { [0x16] = true, [0x17] = true }
local COLL_WATER = 0x29
local NDX, NDY = { 0, 0, -1, 1 }, { -1, 1, 0, 0 } -- N, S, W, E (the mesher's DIRS order)
WorldSource.WATER_DEEP, WorldSource.WATER_SHALLOW, WorldSource.COLL_WATER = WATER_DEEP, WATER_SHALLOW, COLL_WATER

-- Lab 58 #12 (flag "requirememo"): the sandboxed require costs several gsubs per call and engine() runs twice a
-- frame (currentMapId). With the flag on the module table is remembered after the first success; a failed require
-- is never remembered, and WorldSource.new() / resetEngineMemo() forget everything (new session, engine reload).
local okS58, Speed58 = pcall(V.require, "perf/Speed58")
if not (okS58 and type(Speed58) == "table") then Speed58 = nil end
local engineMemo = {}
local function engine(name)
  if Speed58 and Speed58.on("requirememo") then
    local m = engineMemo[name]
    if m then return m end
    local ok, mod = pcall(require, name)
    if ok and type(mod) == "table" then engineMemo[name] = mod; return mod end
    return nil
  end
  local ok, mod = pcall(require, name)
  if ok and type(mod) == "table" then return mod end
  return nil
end
function WorldSource.resetEngineMemo() for k in pairs(engineMemo) do engineMemo[k] = nil end end

function WorldSource.new()
  WorldSource.resetEngineMemo()
  return setmetatable({
    Map = engine("src.core.game3.map"),
    Collision = engine("src.core.game3.collision"),
    NativeTileset = engine("src.core.game3.tileset_native"),
    Interaction = engine("src.core.game3.scripting.interaction_scripts"),
    CollPermissions = engine("src.core.CollPermissions"),
    ScriptCollision = engine("src.core.game3.scripting.collision"),
    Connections = engine("src.core.game3.connections"),
    atlases = setmetatable({}, { __mode = "k" }),
  }, WorldSource)
end

-- ------------------------------------------------------------------ atlas

-- Lab 8 P0-1 (fix 1c, 2026-09-29): the atlas scans below read each
-- ImageData ONCE, as its raw RGBA8 bytes (one getString call), instead of
-- one ImageData:getPixel per texel per scan. getPixel was ~75% of the
-- 415 ms map-crossing freeze on the Lab 7 desktop run (a first-seen pair's
-- atlasFor, l7_seek_south_B.log:455). The byte tests are the same tests:
--   a > 0.02          <=> alpha byte >= 6     (5/255 = 0.0196, 6/255 = 0.0235)
--   a >= 0.5          <=> alpha byte >= 128   (127/255 = 0.498)
--   c > VOID_MAX      <=> byte > 24           (VOID_MAX = 24/255)
--   floor(c*255+0.5)  == the byte itself
-- with getPixel's values taken as byte/255 in double precision (LOVE's FFI
-- getPixel, the desktop path). LOVE's C getPixel (JIT off at load, as on
-- the Quest) converts through a 32-bit float, where 24/255 reads slightly
-- ABOVE the double 24/255: a texel whose brightest channel is exactly 24 was
-- "not dark" there and is "dark" here, the same as on desktop.
-- The scans also call yield (Scene._yieldPoint, injected by Scene.new) once
-- per mid, so a first-seen pair's scan spreads over build slices instead of
-- stalling one frame.
local byte, char = string.byte, string.char
local function noYield() end
-- Lab 59: output-neutral checkpoints. Scene.new sets source.yieldSafe (a checkpoint that returns instead of raising
-- where a yield is not possible); without it these are no-ops.
local function ysOf(self) return self.yieldSafe or noYield end

-- { s = raw RGBA8 bytes, w, h } for one ImageData, or nil without one. Any
-- other pixel format is converted through getPixel (slow; the native atlases
-- are all rgba8, so this path is only a safety net).
local function pixelBytes(data)
  if not data then return nil end
  local okD, w, h = pcall(data.getDimensions, data)
  if not (okD and w and h) then return nil end
  local okF, fmt = pcall(data.getFormat, data)
  if okF and fmt == "rgba8" then
    local okS, s = pcall(data.getString, data)
    if okS and type(s) == "string" and #s >= w * h * 4 then return { s = s, w = w, h = h } end
  end
  local function to8(v) return math.floor((v or 0) * 255 + 0.5) end
  local rows = {}
  for y = 0, h - 1 do
    local row = {}
    for x = 0, w - 1 do
      local r, g, b, a = data:getPixel(x, y)
      row[x + 1] = char(to8(r), to8(g), to8(b), to8(a))
    end
    rows[y + 1] = table.concat(row)
  end
  return { s = table.concat(rows), w = w, h = h }
end
WorldSource._pixelBytes = pixelBytes -- test seam

-- Per mid: `set[mid] = true` when its over slot has any painted pixel
-- (alpha > 0.02, unchanged), and `coverage[mid]` = fraction of its 256
-- texels with alpha >= 0.5 (the renderer's CUTOUT threshold, Scene.lua).
-- `over` = pixelBytes(ts.overImageData).
local function scanOverMids(ts, over, yield)
  local set, coverage = {}, {}
  if not (over and ts.midToSlot) then return set, coverage end
  yield = yield or noYield
  local s, ow, oh = over.s, over.w, over.h
  local cols = ts.cols or 16
  for mid, slot in pairs(ts.midToSlot) do
    local sx = (slot % cols) * 16
    local sy = math.floor(slot / cols) * 16
    if sx + 15 < ow and sy + 15 < oh then
      local hit, solid = false, 0
      for y = 0, 15 do
        local i = ((sy + y) * ow + sx) * 4 + 4 -- the alpha byte
        for _ = 0, 15 do
          local a = byte(s, i)
          if a >= 6 then
            hit = true
            if a >= 128 then solid = solid + 1 end
          end
          i = i + 4
        end
      end
      if hit then set[mid] = true end
      coverage[mid] = solid / 256
    end
    yield()
  end
  return set, coverage
end

-- r8: VOID tiles -- a mid whose every drawn texel, in BOTH layers, is
-- near-black (max channel <= VOID_MAX): all 256 under texels, and every
-- over texel with alpha > 0.02. FRLG draws the space outside an interior /
-- beyond a cave with such a tile (the building tilesets' mid 8 is (0,0,0)
-- in the under layer AND a solid (0,0,0) over layer; mid 0 is the empty
-- slot); the mesher emits no geometry for it (atlas.isVoid,
-- w3/CONTRACT_V2.md "V2.1").
-- VOID_MAX = 24 / 255 as a byte: a channel above 24 is not dark (see the
-- fix 1c note above pixelBytes)
local VOID_MAX_BYTE = 24
local function allDark(px, sx, sy, alphaGate)
  local s, w = px.s, px.w
  for y = 0, 15 do
    local i = ((sy + y) * w + sx) * 4 + 1
    for _ = 0, 15 do
      local r, g, b, a = byte(s, i, i + 3)
      if not alphaGate or a >= 6 then
        if r > VOID_MAX_BYTE or g > VOID_MAX_BYTE or b > VOID_MAX_BYTE then return false end
      end
      i = i + 4
    end
  end
  return true
end
-- `under` / `over` = pixelBytes(ts.imageData) / pixelBytes(ts.overImageData).
local function scanVoidMids(ts, overMids, under, over, yield)
  local set = {}
  if not (under and ts.midToSlot) then return set end
  yield = yield or noYield
  local cols = ts.cols or 16
  local iw, ih = under.w, under.h
  for mid, slot in pairs(ts.midToSlot) do
    local sx = (slot % cols) * 16
    local sy = math.floor(slot / cols) * 16
    if sx + 15 < iw and sy + 15 < ih and allDark(under, sx, sy, false) then
      local overOk = not overMids[mid]
      if not overOk and over then
        overOk = sx + 15 < over.w and sy + 15 < over.h and allDark(over, sx, sy, true)
      end
      if overOk then set[mid] = true end
    end
    yield()
  end
  return set
end

-- r11 (review M2): ROCK art. Each of a mid's 16x16 texels is its over
-- texel when that is opaque (alpha >= 0.5), else its under texel; a texel
-- is LEAF when g >= r + 16 and g >= b, WATER when b >= r + 32 and
-- b >= g + 8, DARK when max(r, g, b) < 40, else ROCK (browns, tans,
-- greys). A mid is rock art when ROCK >= 60% and LEAF <= 25% of its texels,
-- leafy when LEAF >= 50%
-- (mountains the engine calls BUILDING: Route 23, Sevii). The mesher uses
-- it only for solid prop lumps (atlas.isRock; w3/tools/art_stats.py is the
-- same rule for the test / sweep dumps).
local ROCK_MIN, LEAF_MAX, LEAFY_MIN = 0.60, 0.25, 0.50
-- r11 (USER REPORT, log posts): distinct upright objects in a tile (log
-- stumps, bollards, posts) -- the rule of w3/tools/art_stats.py
-- find_posts: background = the most common border colour; object texel =
-- a channel differs from it by more than 40; post column = >= 6 object
-- texels in rows 1..14; posts = runs of post columns 3..9 wide, 1..3 of
-- them, the first / last column not a post column, no row with a
-- contiguous object run of >= 13 columns (a rail). Flat { x0, x1, y0, y1, ... } texels, or nil.
local function findPosts(px)
  local cnt, bg, bgn = {}, nil, -1
  for y = 0, 15 do
    for x = 0, 15 do
      if x == 0 or x == 15 or y == 0 or y == 15 then
        local k = px[y][x]
        cnt[k] = (cnt[k] or 0) + 1
      end
    end
  end
  for k, n in pairs(cnt) do
    if n > bgn or (n == bgn and k < bg) then bg, bgn = k, n end
  end
  local br, bgc, bb = math.floor(bg / 65536), math.floor(bg / 256) % 256, bg % 256
  local obj = {}
  for y = 0, 15 do
    obj[y] = {}
    local run, best = 0, 0
    for x = 0, 15 do
      local k = px[y][x]
      local r, g, b = math.floor(k / 65536), math.floor(k / 256) % 256, k % 256
      local o = math.max(math.abs(r - br), math.abs(g - bgc), math.abs(b - bb)) > 40
      obj[y][x] = o
      if o then run = run + 1 else run = 0 end
      if run > best then best = run end
    end
    if best >= 13 then return nil end -- a rail (contiguous object run)
  end
  local post = {}
  for x = 0, 15 do
    local n = 0
    for y = 1, 14 do if obj[y][x] then n = n + 1 end end
    post[x] = n >= 6
  end
  if post[0] or post[15] then return nil end
  local out, x, spans = {}, 0, 0
  while x <= 15 do
    if post[x] then
      local x0 = x
      while x <= 15 and post[x] do x = x + 1 end
      local x1 = x - 1
      if x1 - x0 + 1 < 3 or x1 - x0 + 1 > 9 then return nil end
      local y0, y1 = 16, -1
      for yy = 0, 15 do
        for xx = x0, x1 do
          if obj[yy][xx] then
            if yy < y0 then y0 = yy end
            if yy > y1 then y1 = yy end
          end
        end
      end
      out[#out + 1], out[#out + 2], out[#out + 3], out[#out + 4] = x0, x1, y0, y1
      spans = spans + 1
    else
      x = x + 1
    end
  end
  if spans < 1 or spans > 3 then return nil end
  return out
end
-- `under` / `over` = pixelBytes(ts.imageData) / pixelBytes(ts.overImageData).
local function scanRockMids(ts, under, over, yield)
  local set, leafy, leafFrac, waterFrac, colors, posts = {}, {}, {}, {}, {}, {}
  if not (under and ts.midToSlot) then return set, leafy, leafFrac, waterFrac, colors, posts end
  yield = yield or noYield
  local cols = ts.cols or 16
  local us, iw, ih = under.s, under.w, under.h
  local os_, ow, oh = nil, 0, 0
  if over then os_, ow, oh = over.s, over.w, over.h end
  for mid, slot in pairs(ts.midToSlot) do
    local sx = (slot % cols) * 16
    local sy = math.floor(slot / cols) * 16
    if sx + 15 < iw and sy + 15 < ih then
      local useOver = os_ and sx + 15 < ow and sy + 15 < oh
      local leaf, rock, water = 0, 0, 0
      local cnt, px = {}, {}
      for yy = 0, 15 do px[yy] = {} end
      for y = 0, 15 do
        local ui = ((sy + y) * iw + sx) * 4 + 1
        local oi = ((sy + y) * ow + sx) * 4 + 1
        for x = 0, 15 do
          local r, g, b, a
          if useOver then r, g, b, a = byte(os_, oi, oi + 3) end
          if not (a and a >= 128) then r, g, b = byte(us, ui, ui + 2) end
          ui, oi = ui + 4, oi + 4
          local k = r * 65536 + g * 256 + b
          cnt[k] = (cnt[k] or 0) + 1
          px[y][x] = k
          if g >= r + 16 and g >= b then leaf = leaf + 1
          elseif b >= r + 32 and b >= g + 8 then -- water
          elseif math.max(r, g, b) < 40 then -- dark
          else rock = rock + 1 end
          -- strongly blue (pool water, not blue-grey stone): waterFrac
          if b >= r + 64 and b >= g + 24 then water = water + 1 end
        end
      end
      if rock >= ROCK_MIN * 256 and leaf <= LEAF_MAX * 256 then set[mid] = true end
      if leaf >= LEAFY_MIN * 256 then leafy[mid] = true end
      leafFrac[mid] = leaf / 256
      waterFrac[mid] = water / 256
      -- the 8 most common colours (ties: lower rgb) as a flat
      -- { rgb, fraction, ... } list (review M6: ground-palette test)
      local keys = {}
      for k in pairs(cnt) do keys[#keys + 1] = k end
      table.sort(keys, function(p, q) if cnt[p] ~= cnt[q] then return cnt[p] > cnt[q] end return p < q end)
      local list = {}
      for i = 1, math.min(8, #keys) do
        list[#list + 1] = keys[i]
        list[#list + 1] = math.floor(cnt[keys[i]] / 256 * 1000 + 0.5) / 1000
      end
      colors[mid] = list
      posts[mid] = findPosts(px)
    end
    yield()
  end
  return set, leafy, leafFrac, waterFrac, colors, posts
end

WorldSource._scanOverMids, WorldSource._scanVoidMids, WorldSource._scanRockMids =
  scanOverMids, scanVoidMids, scanRockMids -- test seams (Lab 8 P0-1)

-- Tiny inset (1/32 texel) keeps nearest sampling inside the 16x16 slot at
-- grazing angles without visibly shrinking the art.
local INSET = 1 / 32

-- worker "atmos" (GW-P4): if an emissive provider's originals(pair) has
-- pre-paint pixels for this tileset, scan a CLONE with those written back
-- instead of the live (possibly RTC-painted) ImageData, so the one-time
-- classification below is deterministic regardless of what time of day the
-- pair was first scanned at. Falls back to `ts` itself (today's behaviour)
-- whenever no provider is set, it errors, or it has nothing for this pair.
--
-- Shape (confirmed against W9's actual FRLG_RTC_BRIDGE this pass,
-- daynight-weather-hook/W9_NOTES.md): originals(pair) returns ONE flat
-- list, `{{x=,y=,r=,g=,b=,a=,over=<bool>}, ...}` -- `over` marks which
-- ImageData the entry belongs to, it is not pre-split into two lists.
WorldSource._originalsProvider = nil
function WorldSource.setOriginalsProvider(fn) WorldSource._originalsProvider = fn end

local function cloneWithOriginals(data, list, yield)
  if not (data and list and #list > 0) then return data end
  local okC, clone = pcall(data.clone, data)
  if not okC or not clone then return data end
  for i = 1, #list do
    local p = list[i]
    local x, y = tonumber(p.x or p[1]), tonumber(p.y or p[2])
    local r, g, b, a = p.r or p[3], p.g or p[4], p.b or p[5], p.a or p[6]
    if x and y and r and g and b then
      pcall(clone.setPixel, clone, x, y, r, g, b, a or 1)
    end
    if yield and i % 256 == 0 then yield() end -- Lab 8 P0-1 (1c)
  end
  return clone
end

function WorldSource._cleanClone(ts, list, yield)
  local underList, overList = {}, {}
  for i = 1, #list do
    local p = list[i]
    if p.over then overList[#overList + 1] = p else underList[#underList + 1] = p end
  end
  local under = cloneWithOriginals(ts.imageData, underList, yield)
  local over = cloneWithOriginals(ts.overImageData, overList, yield)
  if under == ts.imageData and over == ts.overImageData then return ts end
  local clone = {}
  for k, v in pairs(ts) do clone[k] = v end
  clone.imageData, clone.overImageData = under, over
  return clone
end

-- Lab 59 v4: the art the CLASSIFICATION reads (atlas scan, texels(), glass lists, shadow alpha). While paintFree (VRITK
-- active) it is a private copy of the tileset image with (1) the RealTimeClockTest night paint undone, from the originals
-- provider, and (2) every engine-animated tile (water, sand, flowers: tileset_anim banks) set to animation frame 0. So
-- the geometry, keyed layer and masks no longer depend on the time of day or on whichever animation frame happened to
-- be pasted into the live atlas when a map was built; a cache hit and a live build read the same art. The live atlas
-- (what is drawn) is not touched. Built once per tileset; read-only engine data (src.core.game3.tileset_anim banks).
local ANIM_MID_BYTES = 16 * 16 * 4
function WorldSource:canonicalImages(ts, pair)
  local pf = self.paintFree
  if not (ts and ts.imageData) then return nil, nil end
  if not (pf and pf()) then return ts.imageData, ts.overImageData end
  self.canon = self.canon or setmetatable({}, { __mode = "k" })
  local c = self.canon[ts]
  if c and c.under0 == ts.imageData and c.over0 == ts.overImageData then return c.under, c.over, true end
  local yield = self.yieldPoint or noYield
  local okU, under = pcall(ts.imageData.clone, ts.imageData)
  if not okU or not under then return ts.imageData, ts.overImageData end
  local over = ts.overImageData
  if over then
    local okO, o2 = pcall(over.clone, over)
    over = okO and o2 or ts.overImageData
  end
  local prov = WorldSource._originalsProvider
  -- Lab 59 v4 fix: a tileset that is painted (RTC night paint) while no pre-paint list is available yet (the RTC bridge
  -- has not registered) gives a clone that still carries the paint. That clone must not be memoised, and the atlas
  -- built from it must not be kept (third result false), so the next call, once the list exists, starts clean.
  local dn = ts._dnNight
  local painted = type(dn) == "table" and next(dn) ~= nil
  local haveList = false
  if prov then
    local okP, list = pcall(prov, pair)
    if okP and type(list) == "table" then
      haveList = #list > 0
      for i = 1, #list do
        local p = list[i]
        local x, y = tonumber(p.x or p[1]), tonumber(p.y or p[2])
        local r, g, b, a = p.r or p[3], p.g or p[4], p.b or p[5], p.a or p[6]
        local target = p.over and over or under
        if x and y and r and g and b and target then pcall(target.setPixel, target, x, y, r, g, b, a or 1) end
        if i % 256 == 0 then yield() end
      end
    end
  end
  local okA, TA = pcall(require, "src.core.game3.tileset_anim")
  local entry = okA and type(TA) == "table" and type(TA._pairs) == "table" and TA._pairs[pair] or nil
  if type(entry) == "table" and type(entry.banks) == "table" and not entry.rse then
    local cols = ts.cols or 16
    for _, kind in ipairs({ "water", "sand", "flower" }) do
      local bank = entry.banks[kind]
      if type(bank) == "table" and type(bank.rgba) == "string" and type(bank.mids) == "table" and (bank.frames or 0) >= 1 then
        for mi, mid in ipairs(bank.mids) do
          local slot = ts.midToSlot and ts.midToSlot[mid]
          if slot then
            local rgba = bank.rgba:sub((mi - 1) * ANIM_MID_BYTES + 1, mi * ANIM_MID_BYTES)
            if #rgba == ANIM_MID_BYTES then
              local okI, piece = pcall(love.image.newImageData, 16, 16, "rgba8", rgba)
              if okI and piece then pcall(under.paste, under, piece, (slot % cols) * 16, math.floor(slot / cols) * 16, 0, 0, 16, 16) end
            end
          end
        end
        yield()
      end
    end
  end
  if painted and not haveList then return under, over, false end
  self.canon[ts] = { under0 = ts.imageData, over0 = ts.overImageData, under = under, over = over }
  return under, over, true
end

function WorldSource:atlasFor(pair)
  local NT = self.NativeTileset
  if not (NT and pair and NT.ready and NT.ready(pair)) then return nil end
  local ts = NT.get(pair)
  if not (ts and (ts.image or (ts.cpuAtlas and ts.imageData))) then return nil end
  local cached = self.atlases[ts]
  if cached then return cached end
  local W, H = (ts.image or ts.imageData):getDimensions()
  local cols = ts.cols or 16
  local midToSlot = ts.midToSlot or {}
  -- Lab 8 P0-1 (1c): Scene.new injects Scene._yieldPoint as self.yieldPoint
  -- (a no-op outside a deadline-bound build slice, e.g. in _runNow).
  local yield = self.yieldPoint or noYield
  local scanTs = ts
  local cu, co, canonFinal = self:canonicalImages(ts, pair)
  if cu ~= ts.imageData or co ~= ts.overImageData then
    scanTs = {}
    for k, v in pairs(ts) do scanTs[k] = v end
    scanTs.imageData, scanTs.overImageData = cu, co
  elseif WorldSource._originalsProvider then
    local okO, orig = pcall(WorldSource._originalsProvider, pair)
    if okO and type(orig) == "table" and #orig > 0 then
      local okClone, cloned = pcall(WorldSource._cleanClone, ts, orig, yield)
      if okClone and cloned then scanTs = cloned end
    end
  end
  -- each ImageData read once, as bytes (fix 1c)
  local underPx = pixelBytes(scanTs.imageData)
  local overPx = pixelBytes(scanTs.overImageData)
  local overMids, overCov = scanOverMids(scanTs, overPx, yield)
  local voidMids = scanVoidMids(scanTs, overMids, underPx, overPx, yield)
  local rockMids, leafyMids, leafFrac, waterFrac, colorSets, postSets = scanRockMids(scanTs, underPx, overPx, yield)
  local texCache = {}
  -- Lab 57 SIGNS: the palette of every sign metatile of this tileset (0xRRGGBB, the same layout as
  -- texels(mid, "under")), taken ONCE from the clean bytes just read (scanTs: the RTC originals written
  -- back when a provider exists), so a night repaint never reaches a sign texture.
  local signPal = {}
  if SignProfiles and underPx then
    for _, smid in ipairs(SignProfiles.MIDS) do
      local sslot = midToSlot[smid]
      if sslot ~= nil and SignProfiles.style({ mapId = "FR_", pair = pair }, smid) then
        local sx0, sy0 = (sslot % cols) * 16, math.floor(sslot / cols) * 16
        if sx0 + 15 < underPx.w and sy0 + 15 < underPx.h then
          local tt, s = {}, underPx.s
          for yy = 0, 15 do
            local i = ((sy0 + yy) * underPx.w + sx0) * 4 + 1
            for xx = 0, 15 do
              tt[yy * 16 + xx + 1] = byte(s, i) * 65536 + byte(s, i + 1) * 256 + byte(s, i + 2)
              i = i + 4
            end
          end
          signPal[smid] = tt
        end
      end
    end
  end
  -- Lab 57 SIGNS v2: palette of the gym crest tiles (OVER layer; -1 = transparent), read once from the clean bytes.
  local signOverPal = {}
  if SignProfiles and overPx then
    for _, cmid in ipairs(SignProfiles.CREST_MIDS) do
      local cslot = midToSlot[cmid]
      if cslot ~= nil and overMids[cmid] then
        local cx0, cy0 = (cslot % cols) * 16, math.floor(cslot / cols) * 16
        if cx0 + 15 < overPx.w and cy0 + 15 < overPx.h then
          local tt, s = {}, overPx.s
          for yy = 0, 15 do
            local i = ((cy0 + yy) * overPx.w + cx0) * 4 + 1
            for xx = 0, 15 do
              tt[yy * 16 + xx + 1] = byte(s, i + 3) >= 128 and (byte(s, i) * 65536 + byte(s, i + 1) * 256 + byte(s, i + 2)) or -1
              i = i + 4
            end
          end
          signOverPal[cmid] = tt
        end
      end
    end
  end
  local function rect(mid)
    local slot = midToSlot[mid]
    if slot == nil then slot = midToSlot[0] or 0 end
    local sx = (slot % cols) * 16
    local sy = math.floor(slot / cols) * 16
    return (sx + INSET) / W, (sy + INSET) / H, (sx + 16 - INSET) / W, (sy + 16 - INSET) / H
  end
  local atlas = {
    pair = pair,
    w = W, h = H,
    image = ts.image,
    overImage = ts.layered and ts.overImage or nil,
    overMids = overMids,
    underRect = rect,
    -- nil for a mid without over art (contract: "overRect(mid) -> ... | nil";
    -- the mesher derives hasOver from it; w3/REPORT.md "Contract additions").
    overRect = function(mid)
      if not (ts.layered and (ts.overImage or (ts.cpuAtlas and ts.overImageData))) then return nil end
      if not overMids[mid] then return nil end
      return rect(mid)
    end,
    hasOver = function(mid) return overMids[mid] == true end,
    overCoverage = function(mid) return overCov[mid] or 0 end,
    voidMids = voidMids,
    isVoid = function(mid) return voidMids[mid] == true end,
    rockMids = rockMids,
    isRock = function(mid) return rockMids[mid] == true end, -- r11 (review M2)
    isLeafy = function(mid) return leafyMids[mid] == true end, -- LEAF >= 50%: grass lips, foliage
    leafFrac = function(mid) return leafFrac[mid] or 0 end, -- LEAF texels / 256 (review M6: ground-free wall art)
    waterFrac = function(mid) return waterFrac[mid] or 0 end, -- WATER texels / 256 (review M11: fountains)
    colors = function(mid) return colorSets[mid] end, -- top-8 { rgb, fraction, ... } (review M6)
    posts = function(mid) return postSets[mid] end, -- { x0, x1, y0, y1, ... } upright posts in the art
    -- every texel of a mid's layer as 0xRRGGBB (-1 = transparent over
    -- texel), lazily: the mesher's clean plaster column (side walls)
    texels = function(mid, layer)
      local key = mid * 2 + (layer == "over" and 1 or 0)
      local t = texCache[key]
      if t ~= nil then return t or nil end
      -- Lab 59 v4: scanTs holds the CANONICAL art (pre-paint, animation frame 0) while paintFree, else the live atlas
      local data = layer == "over" and (ts.layered and overMids[mid] and scanTs.overImageData) or (layer ~= "over" and scanTs.imageData)
      local slot = midToSlot[mid]
      if not data or slot == nil then texCache[key] = false; return nil end
      local sx, sy = (slot % cols) * 16, math.floor(slot / cols) * 16
      local dw, dh = data:getDimensions()
      if sx + 15 >= dw or sy + 15 >= dh then texCache[key] = false; return nil end
      t = {}
      for y = 0, 15 do
        for x = 0, 15 do
          local r, g, b, a = data:getPixel(sx + x, sy + y)
          if layer == "over" and (a or 0) < 0.5 then
            t[y * 16 + x + 1] = -1
          else
            t[y * 16 + x + 1] = math.floor((r or 0) * 255 + 0.5) * 65536 + math.floor((g or 0) * 255 + 0.5) * 256
              + math.floor((b or 0) * 255 + 0.5)
          end
        end
      end
      texCache[key] = t
      ysOf(self)()
      return t
    end,
    signOverTexels = function(mid) return signOverPal[mid] end, -- Lab 57 SIGNS v2: gym crest art (over layer)
    signTexels = function(mid) return signPal[mid] end, -- Lab 57 SIGNS (clean palette), nil = keep the native sign
  }
  if canonFinal ~= false then self.atlases[ts] = atlas end -- v4 fix: never keep an atlas classified from painted pixels
  return atlas
end

-- ------------------------------------------------------------------ cells

function WorldSource:behaviorFor(pair, mid)
  local I = self.Interaction
  local by = I and I.behaviors and I.behaviors[pair]
  return by and by[mid] or nil
end

local function isWalkable(self, coll)
  local CP = self.CollPermissions
  if CP and CP.isWalkable then
    local ok, v = pcall(CP.isWalkable, coll)
    if ok then return v == true end
  end
  return coll == 0
end

-- W3: the engine's own metatile category for a cell (Collision.classify,
-- src/core/game3/scripting/collision.lua:90 -- the importer's classifier:
-- "TREE" for the outdoor General-tileset tree metatiles, else BLOCKED /
-- CLIFF / BUILDING / WATER / ...). The mesher reads only "TREE" (tree art
-- vs fence/rock, w3/REPORT.md). The runtime COLL byte stands in for pret's
-- raw collision: classify only tests it against 0.
local function categoryOf(self, mid, coll, behavior, kind)
  local SC = self.ScriptCollision
  if not (SC and SC.classify) then return nil end
  local ok, cat = pcall(SC.classify, mid or 0, coll or 0, behavior, kind)
  if ok and type(cat) == "string" then return cat end
  return nil
end

-- r8: map kind for the mesher, pret map header type FIRST (the same field
-- WorldSource.isOutdoor reads; pokefirered include/constants/map_types.h:
-- 1 TOWN, 2 CITY, 3 ROUTE, 4 UNDERGROUND, 5 UNDERWATER, 6 OCEAN_ROUTE,
-- 8 INDOOR, 9 SECRET_BASE). The dataset's own `kind` defaults to "town"
-- for 253 of the 263 FireRed interiors (w3 sweep), so it cannot be trusted
-- for them. Indoor -> "indoor", underground -> "cave", else the dataset kind.
local INDOOR_MAP_TYPES = { [8] = true, [9] = true }
function WorldSource.mapKind(def)
  if type(def) ~= "table" then return nil end
  local mt = tonumber(def.mapType) or 0
  if INDOOR_MAP_TYPES[mt] then return "indoor" end
  if mt == 4 then return "cave" end
  return def.kind
end
-- Kind handed to the engine classifier: it knows "indoor" (no outdoor tree
-- / shrub / cliff lists) and "route" (secondary-tileset solids -> CLIFF, not
-- BUILDING) -- caves are classified as "route".
local function classifyKind(kind)
  if kind == "cave" then return "route" end
  return kind
end

local function makeCell(self, atlas, pair, mid, coll, elev, behavior, kind)
  local layerType = 1
  if atlas and atlas.overMids[mid] then layerType = 0 end
  return {
    mid = mid or 0,
    elevation = elev or 0,
    collision = coll or 0xff,
    coll = coll or 0xff,
    walkable = isWalkable(self, coll or 0xff),
    behavior = behavior,
    layerType = layerType,
    category = categoryOf(self, mid, coll or 0xff, behavior, classifyKind(kind)),
    pair = pair,
  }
end

-- Bounded native connected source for the Tower clipped by the Route10 /
-- Lavender map seam. No cells, collision or elevation are modified. The
-- mesher must still validate every native art/state pin before claiming or
-- suppressing any of this source; a provider alone is not model admission.
-- Exact Five Island / Meadow source context. This supplies native state;
-- only the independently guarded mesher module may claim visual ownership.
function WorldSource:connectedHouseSource(mapId,def)
  if mapId~="FR_FIVE_ISLAND"and mapId~="FR_FIVE_ISLAND_MEADOW"then return nil end
  local maps,Cn=self.maps,self.Connections
  if type(maps)~="table"or not(Cn and type(Cn.each)=="function")then return nil end
  local west,east=maps.FR_FIVE_ISLAND,maps.FR_FIVE_ISLAND_MEADOW
  if type(west)~="table"or type(east)~="table"or def~=(mapId=="FR_FIVE_ISLAND"and west or east)then return nil end
  local wl,el=west.midLayout,east.midLayout;local pair="general__rom_082d5064"
  if type(wl)~="table"or type(el)~="table"or type(wl.cellAt)~="function"or type(el.cellAt)~="function"
   or wl.width~=24 or wl.height~=20 or el.width~=24 or el.height~=40
   or(west.pair or wl.pair)~=pair or(east.pair or el.pair)~=pair then return nil end
  local function connected(d,dir,id)
    local n=0
    for _,c in ipairs(Cn.each(d))do if c.dir==dir then
      if c.map~=id or(c.offset or 0)~=0 then return false end;n=n+1
    end end
    return n==1
  end
  if not connected(west,"east","FR_FIVE_ISLAND_MEADOW")or not connected(east,"west","FR_FIVE_ISLAND")then return nil end
  local atlas=self:atlasFor(pair);if not atlas then return nil end
  local behaviors=self.Interaction and self.Interaction.behaviors and self.Interaction.behaviors[pair]
  local cells,ground={},nil
  for y=5,11 do for x=20,26 do
    local d,sx=x<24 and west or east,x<24 and x or x-24
    local raw=d.midLayout:cellAt(sx,y)
    if not raw or type(raw.mid)~="number"or type(raw.coll)~="number"or type(raw.elev)~="number"then return nil end
    local c=makeCell(self,atlas,pair,raw.mid,raw.coll,raw.elev,behaviors and behaviors[raw.mid],WorldSource.mapKind(d))
    c.x,c.y,c.sourceMap,c.sourceX,c.sourceY=x,y,x<24 and"FR_FIVE_ISLAND"or"FR_FIVE_ISLAND_MEADOW",sx,y
    cells[#cells+1]=c;if x==21 and y==10 then ground=c end
  end end
  return {name="five-island-connected-house",owner="FR_FIVE_ISLAND",pair=pair,mapId=mapId,
    ownerOffsetX=mapId=="FR_FIVE_ISLAND_MEADOW"and -24 or 0,ownerOffsetY=0,
    minX=20,maxX=26,minY=5,maxY=11,cells=cells,atlas=atlas,groundDonor=ground,
    sourceVersions={WorldSource.layoutVersion(wl),WorldSource.layoutVersion(el)}}
end

function WorldSource:connectedBuildingSource(mapId,def)
  if mapId~="FR_LAVENDER_TOWN"and mapId~="FR_ROUTE_10"then return nil end
  local maps,Cn=self.maps,self.Connections
  if type(maps)~="table"or not(Cn and type(Cn.each)=="function")then return nil end
  local lav,route=maps.FR_LAVENDER_TOWN,maps.FR_ROUTE_10
  if type(lav)~="table"or type(route)~="table"then return nil end
  if def~=(mapId=="FR_LAVENDER_TOWN"and lav or route)then return nil end
  local ll,rl=lav.midLayout,route.midLayout
  local pair="general__rom_082d4b0c"
  if not(ll and rl and type(ll.cellAt)=="function"and type(rl.cellAt)=="function")
   or ll.width~=24 or ll.height~=20 or rl.width~=24 or rl.height~=80
   or(lav.pair or ll.pair)~=pair or(route.pair or rl.pair)~=pair then return nil end
  local function exactConnection(d,dir,id)
    local matches=0
    for _,c in ipairs(Cn.each(d))do
      if c.dir==dir then if c.map~=id or(c.offset or 0)~=0 then return false end;matches=matches+1 end
    end
    return matches==1
  end
  if not exactConnection(lav,"north","FR_ROUTE_10")or not exactConnection(route,"south","FR_LAVENDER_TOWN")then return nil end
  local atlas=self:atlasFor(pair)
  if not atlas then return nil end
  local behaviors=self.Interaction and self.Interaction.behaviors and self.Interaction.behaviors[pair]
  local cells={}
  for y=-8,6 do
    local source,sy=y<0 and route or lav,y<0 and y+80 or y
    for x=15,21 do
      local raw=source.midLayout:cellAt(x,sy)
      if not raw or type(raw.mid)~="number"or type(raw.coll)~="number"or type(raw.elev)~="number"then return nil end
      local c=makeCell(self,atlas,pair,raw.mid,raw.coll,raw.elev,behaviors and behaviors[raw.mid],WorldSource.mapKind(source))
      c.x,c.y,c.sourceMap,c.sourceX,c.sourceY=x,y,y<0 and"FR_ROUTE_10"or"FR_LAVENDER_TOWN",x,sy
      cells[#cells+1]=c
    end
  end
  -- Exact surrounding native terrain is guarded, never claimed.
  local terrainContext={}
  for y=73,79 do for x=12,23 do
    local raw=rl:cellAt(x,y)
    if not raw then return nil end
    local c=makeCell(self,atlas,pair,raw.mid,raw.coll,raw.elev,behaviors and behaviors[raw.mid],WorldSource.mapKind(route))
    c.sourceMap,c.sourceX,c.sourceY,c.x,c.y="FR_ROUTE_10",x,y,x,y-80
    terrainContext[#terrainContext+1]=c
  end end
  local raw=rl:cellAt(18,71)
  if not raw then return nil end
  local ground=makeCell(self,atlas,pair,raw.mid,raw.coll,raw.elev,behaviors and behaviors[raw.mid],WorldSource.mapKind(route))
  ground.sourceMap,ground.sourceX,ground.sourceY="FR_ROUTE_10",18,71
  return {name="pokemon-tower-connected-native",owner="FR_LAVENDER_TOWN",pair=pair,
    mapId=mapId,ownerOffsetY=mapId=="FR_ROUTE_10"and 80 or 0,
    minX=15,maxX=21,minY=-8,maxY=6,cells=cells,terrainContext=terrainContext,atlas=atlas,groundDonor=ground,
    sourceVersions={WorldSource.layoutVersion(ll),WorldSource.layoutVersion(rl)}}
end

-- Mesher input for one whole map, in that map's own cell coordinates.
-- Returns nil, reason when the map cannot be meshed (no layout / no atlas).
-- Exact native closed-border repair input. Match borderInput's dry rock
-- elevation rule; never infer another map's surface from the root mesh.
function WorldSource:boundaryBorderFn(mapId,def)
  if mapId~="FR_LAVENDER_TOWN" and mapId~="FR_ROUTE_8" then return nil end
  local layout=def and def.midLayout
  if not layout or (def.pair or layout.pair)~="general__rom_082d4b0c" then return nil end
  local w,h=layout.width,layout.height
  if h~=20 or w~=(mapId=="FR_LAVENDER_TOWN" and 24 or 72) then return nil end
  local walk=self:walkElev(layout)
  local connected=self:outsideMidFn(def,def.pair or layout.pair)
  return function(x,y)
    if x>=0 and y>=0 and x<w and y<h then return nil end
    if connected and connected(x,y)~=nil then return nil end
    local c=layout:cellAt(x,y)
    if not c or c.mid~=113 then return nil end
    local nx,ny=math.max(0,math.min(w-1,x)),math.max(0,math.min(h-1,y))
    local inner=layout:cellAt(nx,ny)
    local elev=walk[ny*w+nx+1]
    if elev==nil then elev=inner and inner.elev or 0 end
    return c.mid,elev
  end
end

-- Bond forest terrace: expose only the adjacent native ocean contour.
-- Use borderInput itself so collision, behavior and derived elevations match
-- the ring consumed by Scene. No independent water-height approximation.
function WorldSource:nativeTerrainBorderFn(mapId,def)
  local layout=def and def.midLayout
  if mapId~="FR_THREE_ISLAND_BOND_BRIDGE" or not layout
      or (def.pair or layout.pair)~="sevii_outdoor"
      or layout.width~=96 or layout.height~=20 then return nil end
  local connected=self:outsideMidFn(def,def.pair or layout.pair)
  local ring=self:borderInput(mapId,def,1,function(x,y)
    return connected and connected(x,y)~=nil or false
  end)
  if not ring then return nil end
  return function(x,y)
    if type(x)~="number" or type(y)~="number" or x%1~=0 or y%1~=0 then return nil end
    if not ((y==-1 and x>=0 and x<=26) or (x==-1 and y>=0 and y<=19) or (y==20 and x>=0 and x<=24) or (y==-1 and x>=46 and x<=87) or (y==20 and x>=64 and x<=85)) then return nil end
    return ring.cellAt(x+1,y+1)
  end
end

function WorldSource:mapInput(mapId, def)
  local layout = def and def.midLayout
  if not layout then return nil, "no midLayout for " .. tostring(mapId) end
  local pair = def.pair or layout.pair
  local atlas = self:atlasFor(pair)
  if not atlas then return nil, "no native atlas for pair " .. tostring(pair) end
  local w, h = layout.width or 0, layout.height or 0
  if WorldSource.mapKind(def)=="cave" then w,h=layout.trueWidth or w,layout.trueHeight or h end
  if w < 1 or h < 1 then return nil, "empty layout " .. tostring(mapId) end
  local grid = {}
  local behaviors = self.Interaction and self.Interaction.behaviors
    and self.Interaction.behaviors[pair] or nil
  local kind = WorldSource.mapKind(def)
  local ys = ysOf(self)
  for y = 0, h - 1 do
    ys()
    for x = 0, w - 1 do
      local c = layout:cellAt(x, y) or { mid = 0, coll = 0xff, elev = 0 }
      local beh = behaviors and behaviors[c.mid] or nil
      grid[y * w + x + 1] = makeCell(self, atlas, pair, c.mid, c.coll, c.elev, beh, kind)
    end
  end
  -- Lab 57 SIGNS: wording and destinations of this map's sign events from imported script data and the
  -- map connections. Read-only: no script runs. Any failure leaves the signs native.
  -- VRITK compat gate (set by main.lua): without VRITK installed and active nothing about signs changes.
  local signCompat = false
  if self.signGate then
    local okG, on = pcall(self.signGate)
    signCompat = okG and on == true
  end
  local signLabels
  if signCompat and SignMetadata and SignProfiles then
    local sinput = { mapId = mapId, pair = pair, mapType = def.mapType, kind = kind }
    local okL, labels = pcall(SignMetadata.collect, mapId, def, self.game, self.Connections, function(x, y)
      if x < 0 or y < 0 or x >= w or y >= h or x % 1 ~= 0 or y % 1 ~= 0 then return nil end
      local cell = grid[y * w + x + 1]
      return cell and SignProfiles.style(sinput, cell.mid)
    end)
    if okL then signLabels = labels end
  end
  -- Lab 57 SIGNS v2: a gym board with no event / unusable wording still gets the bold GYM (it needs no wording).
  if signCompat and SignProfiles then
    local ginput = { mapId = mapId, pair = pair, mapType = def.mapType, kind = kind }
    for gi, gc in ipairs(grid) do
      if (gc.mid == 360 or gc.mid == 780) and gc.behavior == 0x84 and SignProfiles.style(ginput, gc.mid) == "fr-gym" then
        local gkey = ((gi - 1) % w) .. "," .. math.floor((gi - 1) / w)
        if not (signLabels and signLabels[gkey]) then
          signLabels = signLabels or {}
          signLabels[gkey] = { gymOnly = true, reason = "no-event" }
        end
      end
    end
  end
  return {
    width = w, height = h, mapId = mapId, pair = pair, atlas = atlas,
    kind = kind, -- r8: "indoor" | "cave" | dataset kind ("town" | "route")
    mapType = def.mapType,
    warps = def.warps, -- native doorway ownership for building lighting policy
    objects = def.objects, -- canonical native object-event spawn coordinates
    bgEvents = def.bgEvents, -- native signs/hidden-item keepouts for lamps
    signCompat = signCompat or nil, -- Lab 57 SIGNS: VRITK gate for the mesher / Scene sign paths
    signLabels = signLabels, -- Lab 57 SIGNS: { ["x,y"] = { title, directions, scriptKey, reason } } | nil
    connectedBuildingSource = self:connectedBuildingSource(mapId,def),
    connectedHouseSource = self:connectedHouseSource(mapId,def),
    boundaryBorderAt = self:boundaryBorderFn(mapId,def),
    nativeTerrainBorderAt = self:nativeTerrainBorderFn(mapId,def),
    outsideMidAt = self:outsideMidFn(def, pair), -- r9 (review 5), may be nil
    edgeWaterBank = self:edgeWaterBankFn(mapId, def), -- r10 (review 2 variant C), may be nil
    cellAt = function(x, y)
      if x < 0 or y < 0 or x >= w or y >= h then return nil end
      return grid[y * w + x + 1]
    end,
    grid = grid,
    layoutVersion = WorldSource.layoutVersion(layout),
  }
end

-- r9 (review 5): mid of an out-of-map cell from a DIRECTLY connected map
-- (static connections, placed exactly like Map.computeWorld), or nil. Used
-- by the mesher only to pair 2x2 trees split by a seam. Neighbour mids are
-- passed only when both maps share a tileset pair or are both outdoor
-- (FireRed outdoor maps share the General primary set, which holds the
-- tree metatiles). Needs the maps table worldEntries keeps; without it
-- (or without connections) returns nil and the mesher is unchanged.
function WorldSource:outsideMidFn(def, pair)
  local Cn, maps = self.Connections, self.maps
  if not (Cn and Cn.each and type(maps) == "table" and type(def) == "table") then return nil end
  local layout = def.midLayout
  if not layout then return nil end
  local curW, curH = layout.width or 0, layout.height or 0
  local outdoor = WorldSource.isOutdoor(def)
  local list = {}
  for _, conn in ipairs(Cn.each(def)) do
    local dd = maps[conn.map]
    local L = type(dd) == "table" and dd.midLayout or nil
    local dpair = dd and (dd.pair or (L and L.pair)) or nil
    if L and L.cellAt and (dpair == pair or (outdoor and WorldSource.isOutdoor(dd))) then
      local dw, dh = L.width or 0, L.height or 0
      local off = conn.offset or 0
      local ox, oy
      if conn.dir == "north" then ox, oy = off, -dh
      elseif conn.dir == "south" then ox, oy = off, curH
      elseif conn.dir == "west" then ox, oy = -dw, off
      elseif conn.dir == "east" then ox, oy = curW, off end
      if ox then list[#list + 1] = { L = L, ox = ox, oy = oy, w = dw, h = dh } end
    end
  end
  if #list == 0 then return nil end
  return function(x, y)
    if x >= 0 and y >= 0 and x < curW and y < curH then return nil end
    for i = 1, #list do
      local n = list[i]
      local lx, ly = x - n.ox, y - n.oy
      if lx >= 0 and ly >= 0 and lx < n.w and ly < n.h then
        local c = n.L:cellAt(lx, ly)
        return c and c.mid or nil
      end
    end
    return nil
  end
end

-- r10 (shore heights, review 2 "variant C"). The mesher's M1 heights
-- (FrlgMesher pass 1b) in elevation-tag units for one layout, and its
-- water regions with their lowest banks, by the SAME rules: sources are
-- walkable non-water cells tagged 1..14; phase 1 resolves walkable 0/15
-- cells, phase 2 the rest, multi-source 4-neighbour BFS in row-major seed
-- order, neighbours N/S/W/E, tie -> higher; bank = lowest walkable /
-- resolved neighbour, a blocked own-tagged one only when there is none.
-- So a region's bank here equals the mesher's own (w1 test "r10 shore").
-- Cached per layout + layout version.
local function isWaterRaw(beh, coll, elev)
  return (beh ~= nil and (WATER_DEEP[beh] or (WATER_SHALLOW[beh] and elev == 1))) or coll == COLL_WATER
end
-- Exact native Vermilion roof projection over the north water row. These
-- five raw walkable elevation1 cells have black UNDER and green roof OVER;
-- they are not terrain banks. Keep their raw states and every other source.
local function nativeVermilionProjectionBanks(layout,pair,atlas,by)
  if pair~='general__rom_082d4b24' or layout.width~=48 or layout.height~=40
      or not atlas or atlas.w~=256 or atlas.h~=416 or type(atlas.texels)~='function'
      or type(atlas.hasOver)~='function' or type(by)~='table' then return false end
  local h=0
  for y=0,39 do for x=0,47 do local c=layout:cellAt(x,y)
    if not c then return false end
    for _,v in ipairs{c.mid,c.coll,c.elev}do
      if type(v)~='number' or v~=v or v<0 or v%1~=0 or v>65535 then return false end
      h=(h*31+v+2)%2147483647
    end
    if c.mid==nil or c.coll==nil or c.elev==nil then return false end
  end end
  if h~=1188400040 then return false end
  for x=11,15 do local c=layout:cellAt(x,14);local mid=x==11 and 712 or x==15 and 714 or 713
    if c.mid~=mid or c.coll~=0 or c.elev~=1 or by[mid]~=0 then return false end
  end
  local expected={[712]=1076899270,[713]=61400951,[714]=1950092983}
  for mid,overHash in pairs(expected)do
    if not atlas.hasOver(mid)then return false end
    for _,layer in ipairs{'under','over'}do local t=atlas.texels(mid,layer)
      if type(t)~='table' then return false end
      local q=0
      for i=1,256 do local v=t[i]
        if type(v)~='number' or v~=v or v%1~=0 or v< -1 or v>16777215
            or(layer=='under' and v~=0)then return false end
        q=(q*31+(v>=0 and v+2 or 1))%2147483647
      end
      if q~=(layer=='under' and 174315250 or overHash)then return false end
    end
  end
  return true
end
function WorldSource:waterInfo(layout, pair)
  local key = WorldSource.layoutVersion(layout)
  self.waterCache = self.waterCache or setmetatable({}, { __mode = "k" })
  local hit = self.waterCache[layout]
  if hit and hit.key == key and hit.pair == pair then return hit end
  local w, h = layout.width or 0, layout.height or 0
  local atlas = self:atlasFor(pair)
  local by = self.Interaction and self.Interaction.behaviors and self.Interaction.behaviors[pair] or nil
  local projectionBanks=nativeVermilionProjectionBanks(layout,pair,atlas,by)
  local present, water, walk, elev = {}, {}, {}, {}
  local ys = ysOf(self)
  for y = 0, h - 1 do
    ys()
    for x = 0, w - 1 do
      local c = layout:cellAt(x, y) or { mid = 0, coll = 0xff, elev = 0 }
      local mid = c.mid or 0
      if not (atlas and atlas.isVoid and atlas.isVoid(mid)) then
        local k = y * w + x + 1
        local coll, e = c.coll or 0xff, c.elev or 0
        present[k], elev[k] = true, e
        water[k] = isWaterRaw(by and by[mid] or nil, coll, e) and true or false
        walk[k] = isWalkable(self, coll)
      end
    end
  end
  local tag, src = {}, {}
  for k in pairs(present) do
    if not water[k] and elev[k] >= 1 and elev[k] <= 14 then tag[k], src[k] = elev[k], "own" end
  end
  local function bfs(seed)
    local queue, head, tail, dist, bh = {}, 1, 0, {}, {}
    for k = 1, w * h do
      if present[k] then
        local v = seed(k)
        if v then dist[k], bh[k] = 0, v; tail = tail + 1; queue[tail] = k end
      end
    end
    while head <= tail do
      if head % 1024 == 0 then ys() end
      local k = queue[head]
      head = head + 1
      local x, y = (k - 1) % w, math.floor((k - 1) / w)
      local d1, hk = dist[k] + 1, bh[k]
      for i = 1, 4 do
        local nx, ny = x + NDX[i], y + NDY[i]
        if nx >= 0 and ny >= 0 and nx < w and ny < h then
          local nk = ny * w + nx + 1
          if present[nk] then
            if dist[nk] == nil then
              dist[nk], bh[nk] = d1, hk
              tail = tail + 1
              queue[tail] = nk
            elseif dist[nk] == d1 and hk > bh[nk] then
              bh[nk] = hk
            end
          end
        end
      end
    end
    return bh
  end
  local h1 = bfs(function(k) if walk[k] and src[k] == "own" then return tag[k] end end)
  for k in pairs(present) do
    if walk[k] and not water[k] and tag[k] == nil and h1[k] then tag[k], src[k] = h1[k], "resolved" end
  end
  local h2 = bfs(function(k) if walk[k] and not water[k] and tag[k] ~= nil then return tag[k] end end)
  for k in pairs(present) do
    if not water[k] and tag[k] == nil then
      if h2[k] ~= nil then tag[k], src[k] = h2[k], "resolved" else tag[k], src[k] = elev[k], "fallback" end
    end
  end
  -- water regions and their banks
  local regionOf, regions = {}, {}
  for k = 1, w * h do
    if present[k] and water[k] and not regionOf[k] then
      local R = { bank = nil, bankOwn = nil }
      regions[#regions + 1] = R
      local id = #regions
      local stack = { k }
      regionOf[k] = id
      while #stack > 0 do
        local q = stack[#stack]
        stack[#stack] = nil
        local x, y = (q - 1) % w, math.floor((q - 1) / w)
        for i = 1, 4 do
          local nx, ny = x + NDX[i], y + NDY[i]
          if nx >= 0 and ny >= 0 and nx < w and ny < h then
            local nk = ny * w + nx + 1
            if present[nk] then
              if water[nk] then
                if not regionOf[nk] then regionOf[nk] = id; stack[#stack + 1] = nk end
              elseif src[nk] ~= "fallback" and not(projectionBanks and ny==14 and nx>=11 and nx<=15) then
                if not walk[nk] and src[nk] == "own" then
                  if R.bankOwn == nil or tag[nk] < R.bankOwn then R.bankOwn = tag[nk] end
                elseif R.bank == nil or tag[nk] < R.bank then
                  R.bank = tag[nk]
                end
              end
            end
          end
        end
      end
      R.bank = R.bank or R.bankOwn
    end
  end
  local info = { key = key, pair = pair, w = w, h = h, regionOf = regionOf, regions = regions }
  self.waterCache[layout] = info
  return info
end

-- r10: per water cell of `mapId` (k = y * w + x + 1), the lowest bank tag
-- of its water BODY: its region joined across static connections (seam
-- cells water on both sides) with the neighbours' regions, transitively.
-- Neighbour layouts are loaded on demand (Map.ensureMidLayout). Without a
-- maps table / connections the body is the map's own region. nil when the
-- map has no layout.
function WorldSource:waterBodyBanks(mapId, def)
  local layout = type(def) == "table" and def.midLayout or nil
  if not layout then return nil end
  local Cn, maps = self.Connections, self.maps
  local infoOf, defOf, order = {}, {}, {}
  local function add(id, d)
    local L = d.midLayout
    infoOf[id] = self:waterInfo(L, d.pair or L.pair)
    defOf[id] = d
    order[#order + 1] = id
  end
  add(mapId, def)
  local parent = {}
  local function find(a)
    while parent[a] and parent[a] ~= a do a = parent[a] end
    return a
  end
  local function union(a, b)
    parent[a] = parent[a] or a
    parent[b] = parent[b] or b
    a, b = find(a), find(b)
    if a ~= b then parent[a] = b end
  end
  local qi = 1
  while order[qi] and Cn and Cn.each and type(maps) == "table" do
    local id = order[qi]
    qi = qi + 1
    local d, A = defOf[id], infoOf[id]
    for _, conn in ipairs(Cn.each(d)) do
      local dd = maps[conn.map]
      if type(dd) == "table" and not dd.midLayout and self.Map and self.Map.ensureMidLayout and self.game then
        pcall(self.Map.ensureMidLayout, self.game, conn.map, dd)
      end
      local L = type(dd) == "table" and dd.midLayout or nil
      if L and L.cellAt then
        local B = infoOf[conn.map] or self:waterInfo(L, dd.pair or L.pair)
        local off = conn.offset or 0
        local linked = false
        local function link(ax, ay, bx, by)
          local ra = A.regionOf[ay * A.w + ax + 1]
          local rb = B.regionOf[by * B.w + bx + 1]
          if ra and rb then union(id .. "#" .. ra, conn.map .. "#" .. rb); linked = true end
        end
        if conn.dir == "south" then
          for x = 0, A.w - 1 do local bx = x - off; if bx >= 0 and bx < B.w then link(x, A.h - 1, bx, 0) end end
        elseif conn.dir == "north" then
          for x = 0, A.w - 1 do local bx = x - off; if bx >= 0 and bx < B.w then link(x, 0, bx, B.h - 1) end end
        elseif conn.dir == "east" then
          for y = 0, A.h - 1 do local by = y - off; if by >= 0 and by < B.h then link(A.w - 1, y, 0, by) end end
        elseif conn.dir == "west" then
          for y = 0, A.h - 1 do local by = y - off; if by >= 0 and by < B.h then link(0, y, B.w - 1, by) end end
        end
        if linked and not infoOf[conn.map] then
          infoOf[conn.map], defOf[conn.map] = B, dd
          order[#order + 1] = conn.map
        end
      end
    end
  end
  -- ring joins: the sea beyond a map edge that no connected map covers is
  -- the border ring (tiled border metatiles, drawn around the root map as
  -- one continuous sea). A boundary water cell whose outside border tile
  -- is water joins the map's ring node, so two harbours that meet in the
  -- ring (Vermilion west / east of its pier) are one body with one height.
  for _, id in ipairs(order) do
    local d, A = defOf[id], infoOf[id]
    local L = d.midLayout
    local by = self.Interaction and self.Interaction.behaviors
      and self.Interaction.behaviors[d.pair or L.pair] or nil
    local covered = { north = {}, south = {}, west = {}, east = {} }
    if Cn and Cn.each then
      for _, conn in ipairs(Cn.each(d)) do
        local dd = type(maps) == "table" and maps[conn.map] or nil
        local DL = type(dd) == "table" and dd.midLayout or nil
        local span = DL and ((conn.dir == "north" or conn.dir == "south") and (DL.width or 0) or (DL.height or 0)) or 0
        local list = covered[conn.dir]
        if list then list[#list + 1] = { conn.offset or 0, (conn.offset or 0) + span - 1 } end
      end
    end
    local function isCovered(side, t)
      for _, r in ipairs(covered[side]) do if t >= r[1] and t <= r[2] then return true end end
      return false
    end
    local ringKey = id .. "#ring"
    local function ringTest(x, y, ox, oy, side, t)
      local ri = A.regionOf[y * A.w + x + 1]
      if not ri or isCovered(side, t) then return end
      local inner = L:cellAt(x, y)
      local c = L:cellAt(ox, oy)
      local beh = c and by and by[c.mid or 0] or nil
      local e = inner and inner.elev or 0
      if beh ~= nil and (WATER_DEEP[beh] or (WATER_SHALLOW[beh] and e == 1)) then
        union(id .. "#" .. ri, ringKey)
      end
    end
    for x = 0, A.w - 1 do
      ringTest(x, 0, x, -1, "north", x)
      ringTest(x, A.h - 1, x, A.h, "south", x)
    end
    for y = 0, A.h - 1 do
      ringTest(0, y, -1, y, "west", y)
      ringTest(A.w - 1, y, A.w, y, "east", y)
    end
  end
  -- lowest bank per body
  local bodyBank = {}
  for _, id in ipairs(order) do
    for ri, R in ipairs(infoOf[id].regions) do
      local b = find(id .. "#" .. ri)
      if R.bank ~= nil and (bodyBank[b] == nil or R.bank < bodyBank[b]) then bodyBank[b] = R.bank end
    end
  end
  local A, out = infoOf[mapId], {}
  for k, ri in pairs(A.regionOf) do
    out[k] = bodyBank[find(mapId .. "#" .. ri)]
  end
  return out
end
function WorldSource:edgeWaterBankFn(mapId, def)
  local banks = self:waterBodyBanks(mapId, def)
  if not banks then return nil end
  local w, h = def.midLayout.width or 0, def.midLayout.height or 0
  return function(x, y)
    if x < 0 or y < 0 or x >= w or y >= h then return nil end
    return banks[y * w + x + 1]
  end
end

-- r7m M1: per in-map cell, the elevation of the NEAREST WALKABLE cell whose
-- elevation is a real height tag (1..14) -- multi-source 4-neighbour BFS,
-- the higher tag on a distance tie (the mesher's own rule, FrlgMesher.lua
-- pass 1b). pret elevation 0/15 is "any height", so the border must not
-- copy it from a blocked edge cell (that sank the whole ring 0.75 below the
-- street). Cached per layout and layout version.
function WorldSource:walkElev(layout)
  local key = WorldSource.layoutVersion(layout)
  self.walkElevCache = self.walkElevCache or setmetatable({}, { __mode = "k" })
  local cached = self.walkElevCache[layout]
  if cached and cached.key == key then return cached.grid end
  local w, h = layout.width or 0, layout.height or 0
  local grid, dist, queue, head = {}, {}, {}, 1
  local ys = ysOf(self)
  for y = 0, h - 1 do
    ys()
    for x = 0, w - 1 do
      local c = layout:cellAt(x, y)
      if c and (c.elev or 0) >= 1 and (c.elev or 0) <= 14 and isWalkable(self, c.coll or 0xff) then
        local k = y * w + x + 1
        grid[k], dist[k] = c.elev, 0
        queue[#queue + 1] = k
      end
    end
  end
  -- r9 (review 15): no tables per pop; same neighbour order (N, S, W, E).
  local tail = #queue
  while head <= tail do
    if head % 1024 == 0 then ys() end
    local k = queue[head]
    head = head + 1
    local x, y = (k - 1) % w, math.floor((k - 1) / w)
    local d1, gk = dist[k] + 1, grid[k]
    for i = 1, 4 do
      local nx, ny = x + NDX[i], y + NDY[i]
      if nx >= 0 and ny >= 0 and nx < w and ny < h then
        local nk = ny * w + nx + 1
        local dn = dist[nk]
        if dn == nil then
          dist[nk], grid[nk] = d1, gk
          tail = tail + 1
          queue[tail] = nk
        elseif dn == d1 and gk > grid[nk] then
          grid[nk] = gk
        end
      end
    end
  end
  self.walkElevCache[layout] = { key = key, grid = grid }
  return grid
end

-- Border ring around the ROOT map: cells outside the map that no connected
-- map covers show the layout's tiled border (trees, rock, sea) exactly like
-- the flat view's out-of-bounds sampling. r7m M1: border elevation = the
-- nearest in-map cell's nearest-WALKABLE elevation tag (walkElev), so the
-- ring sits at street level, not at a blocked edge cell's 0.
-- `covered(x, y)` answers root-space cells owned by a placed neighbour map.
function WorldSource:borderInput(rootId, rootDef, margin, covered)
  local layout = rootDef and rootDef.midLayout
  if not layout then return nil, "no root layout" end
  local pair = rootDef.pair or layout.pair
  local atlas = self:atlasFor(pair)
  if not atlas then return nil, "no atlas for border" end
  local w, h = layout.width or 0, layout.height or 0
  local B = margin
  local W, H = w + 2 * B, h + 2 * B
  local grid = {}
  local any = false
  local walkElev = self:walkElev(layout)
  local kind = WorldSource.mapKind(rootDef)
  local bodyBank = self:waterBodyBanks(rootId, rootDef) -- r10
  local ringBank = {}
  local ys = ysOf(self)
  for y = 0, H - 1 do
    ys()
    for x = 0, W - 1 do
      local rx, ry = x - B, y - B
      if not (rx >= 0 and ry >= 0 and rx < w and ry < h) and not covered(rx, ry) then
        local c = layout:cellAt(rx, ry)
        local mid = c and c.mid or 0
        -- r8: a void border tile (interiors: the black space around the
        -- room) is no cell at all -- an all-void ring returns nil below
        -- ("no border cells"), which Scene already records as empty.
        if not atlas.isVoid(mid) then
          local nx = math.max(0, math.min(w - 1, rx))
          local ny = math.max(0, math.min(h - 1, ry))
          local beh = self:behaviorFor(pair, mid)
          local inner = layout:cellAt(nx, ny)
          local elev
          -- r9 (review 2a): a WATER ring cell takes the clamped in-map
          -- cell's own tag (the sea's 1), not the street's walkElev, so the
          -- ring sea meets the map sea at one height (the mesher's edge-
          -- region rule, FrlgMesher pass 1b, gives both the same base).
          local innerElev = inner and inner.elev or 0
          if (beh ~= nil and (WATER_DEEP[beh] or (WATER_SHALLOW[beh] and innerElev == 1)))
              or (inner and inner.coll == COLL_WATER) then
            elev = innerElev
            -- r10: and the lowest bank of the map water it continues (its
            -- body across connections), which the mesher copies
            ringBank[y * W + x + 1] = bodyBank and bodyBank[ny * w + nx + 1] or nil
          else
            elev = walkElev[ny * w + nx + 1]
            if elev == nil then elev = innerElev end
          end
          grid[y * W + x + 1] = makeCell(self, atlas, pair, mid, 0x07, elev, beh, kind)
          any = true
        end
      end
    end
  end
  if not any then return nil, "no border cells" end
  return {
    width = W, height = H, mapId = tostring(rootId) .. "#border", pair = pair,
    atlas = atlas, originX = -B, originY = -B, isBorder = true, kind = kind, mapType = rootDef.mapType,
    edgeWaterBank = bodyBank and function(x, y) -- r10: ring water copies the map's sea
      if x < 0 or y < 0 or x >= W or y >= H then return nil end
      return ringBank[y * W + x + 1]
    end or nil,
    cellAt = function(x, y)
      if x < 0 or y < 0 or x >= W or y >= H then return nil end
      return grid[y * W + x + 1]
    end,
    grid = grid,
  }
end

-- Changes whenever a script swaps a metatile (door open, cut tree, boulder
-- switch): LayoutNative:applyOverride writes layout.overrides. Only
-- overrides whose mid or elevation DIFFER from the base cell count, so the
-- collision-only overrides Collision.installWarps writes on map entry (door
-- cells re-coded COLL_DOOR) do not force a re-mesh of an already cached map,
-- and restoring a metatile returns to the old hash (review items 11, 17).
function WorldSource.layoutVersion(layout)
  if not (layout and layout.overrides) then return "0" end
  local w = layout.width or 0
  local tw = layout.trueWidth or w
  local th = layout.trueHeight or layout.height or 0
  local cells = layout.cells or {}
  local n, sum = 0, 0
  for key, ov in pairs(layout.overrides) do
    local cx, cy = key % 1024, math.floor(key / 1024)
    local base = (cx < tw and cy < th) and cells[cy * w + cx + 1] or nil
    local mid, elev = ov.mid or 0, ov.elev or 0
    if not base or base.mid ~= mid or (base.elev or 0) ~= elev then
      n = n + 1
      sum = (sum + key * 7 + mid * 131 + elev) % 1000000007
    end
  end
  return n .. ":" .. sum
end

-- ------------------------------------------------------------------ world

-- Root map plus connected maps placed in ROOT cell coordinates: direct
-- connections always, further maps only within `reach` cells of the root.
function WorldSource:worldEntries(game, rootId, reach)
  local Map = self.Map
  local maps = game and game.data and game.data.maps
  if type(maps) == "table" then self.maps = maps end -- r9: outsideMidFn
  self.game = game -- r10: loads neighbour layouts for the water-body flood
  local rootDef = maps and maps[rootId]
  if not (Map and rootDef) then return nil end
  local out = { { id = rootId, def = rootDef, ox = 0, oy = 0 } }
  if Map.computeWorld then
    local ok, list = pcall(Map.computeWorld, maps, rootId, 1, reach, reach,
      function(id, def)
        if Map.ensureMidLayout then pcall(Map.ensureMidLayout, game, id, def) end
      end)
    if ok and type(list) == "table" then
      for _, e in ipairs(list) do
        if e.def and e.def.midLayout then out[#out + 1] = e end
      end
    end
  end
  return out, rootDef
end

function WorldSource.currentMapId(game)
  local Runtime = engine("src.core.game3.runtime")
  local session = Runtime and Runtime.getSession and Runtime.getSession()
  local Map = engine("src.core.game3.map")
  if Map and Map.current then return Map.current end
  if session and session.map then return session.map end
  return nil
end

-- Outdoor = sky, haze and haze culling. pret's map header type first (the
-- same set the engine uses, src/core/game3/field_move_show_mon.lua:15,
-- pokefirered/src/overworld.c:1228: town, city, route, underwater, ocean
-- route); then the dataset kind when it is not the "town" default; the
-- tileset pair name last (many outdoor pairs, e.g. general__rom_*, lack
-- "outdoor" -- review item 8). Cached per map definition.
local OUTDOOR_MAP_TYPES = { [1] = true, [2] = true, [3] = true, [5] = true, [6] = true }
local outdoorCache = setmetatable({}, { __mode = "k" })
function WorldSource.isOutdoor(def)
  if type(def) ~= "table" then return false end
  local cached = outdoorCache[def]
  if cached ~= nil then return cached end
  local result
  local mt = tonumber(def.mapType) or 0
  if mt ~= 0 then
    result = OUTDOOR_MAP_TYPES[mt] == true
  elseif def.kind ~= nil and def.kind ~= "town" then
    result = def.kind ~= "indoor"
  else
    local pair = def.pair or (def.midLayout and def.midLayout.pair)
    result = type(pair) == "string" and pair:find("outdoor", 1, true) ~= nil
  end
  outdoorCache[def] = result
  return result
end

return WorldSource
