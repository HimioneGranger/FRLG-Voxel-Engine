-- Wilds 1.7.1 extension (VRITK-owned, stock provider renderers remain untouched).
-- install ctx.hdField is the public metadata-only hd_field export. Its Species Sizes
-- switch is authoritative; no HD compositor is invoked by these recorded draws.
-- 1.7.1 PMD uses native baked land/flyer anchors, or independent swimY (default18).
-- extraLayerCount=0/1; extraLayers[1] is a reused foam snapshot with the same fields
-- as the main snapshot. Consume it only when count==1 and draw after the body.
-- 1.5 renderer classes retain their existing calibration/support-edge behavior.
-- WildsSnapshotCompat (COMPAT60): give STOCK wilds_of_hoenn renderers the VR snapshot API at runtime.
--
-- Wilds of Hoenn 1.5.0 ships byte-identical to stock. Lab 56/57 used to edit lib/actor_renderer.lua and
-- lib/pmd_renderer.lua to add
--     renderer:vrSnapshotInto(out, x, y, camX, camY, facing, walkPhase, stepFlip)   -- allocation free
--     renderer:vrSnapshot(x, y, camX, camY, facing, walkPhase, stepFlip)            -- allocating wrapper (+ color table)
-- (fields: image, quad, x, y, rotation, sx, sy, ox, oy, r, g, b, a, groundX, groundZ, groundY; nil where draw()
-- would draw nothing), plus a pin of the last drawn image on the renderer (`_img`, the image cache is weak) and
-- SpriteAtlas.opaqueBottom for the PMD ground line. This module provides all of that without touching the mod.
--
-- How: the renderer classes are module-local inside Wilds (private V.require cache; we may not use package.loaded or
-- debug), so adopt(renderer) reaches the class through the live instance: getmetatable(r).__index. The two classes
-- are told apart by their statics (PmdRenderer.rowFor / frameAt / placement; ActorRenderer.frameIndexFor /
-- drawOffset / behindOffset). The class table receives vrSnapshotInto and vrSnapshot.
--
-- vrSnapshotInto RECORDS the stock draw(): for the duration of one `self:draw(...)` call love.graphics.draw and
-- love.graphics.setColor are swapped for two prebuilt recorder functions (upvalue scratch, no closure or table per
-- call), the call runs under pcall, and the exact original functions are put back in every path. The recorded
-- image / quad / position / scale / origin and the colour that was current at the draw call (default 1,1,1,1; the
-- trailing setColor(1,1,1,1) reset of draw() cannot overwrite it) are copied into `out`. So every number is the
-- stock draw's own number, and nothing about the sprite maths is re-implemented. What draw() does not draw is
-- recomputed here exactly as the edited code did: groundX / groundZ / groundY (the Actor ground uses the class
-- statics behindOffset, the PMD ground uses rowFor, and both use a private copy of the tiny recall blend of
-- lib/recall_math.lua).
--
-- PMD groundY needs the opaque-bottom line of the sheet (SpriteAtlas.opaqueBottom in the edited mod). It is
-- re-implemented here from the same atlas files: assets/atlas/index.json + family index through mod:read,
-- shard decode through love.image.newImageData(mod.assets:path(file)) and ImageData:getPixel exactly like the
-- stock atlas does (so Lab 58's WildsAtlasCompat sentinels serve it transparently), memoised per
-- (path, cw, ch, row, cols) in a nested number-keyed table (a hit allocates nothing). At most ONE decoded shard
-- is kept in a short-TTL memo of this module (MEMO_TTL seconds after its last use) and released.
--
-- Known seam (the only value not reachable): wilds Config.PMD_GROUND_Y (12; nothing sets it at runtime). Config is
-- private, so the value is CALIBRATED from the stock draw: every non-recalled PMD snapshot checks the recorded
-- draw y against the 12-based placement and, on a mismatch, derives the integer ground offset that explains it.
-- A fractional PMD_GROUND_Y cannot be recovered exactly (draw() rounds it away). Upstream seam if ever needed:
-- an `exports.config`-style read accessor for Config.
--
-- Mod sandbox: no package, no debug. Pure Lua, install()/uninstall() are symmetrical; with VRITK absent this
-- module does not exist.
local M = {}

M.MEMO_TTL = 1.5 -- seconds a decoded shard stays in the memo after its last use
M.ATLAS_ROOT_INDEX = "assets/atlas/index.json"

local floor, max, min = math.floor, math.max, math.min
local format = string.format
local pcall, type, pairs, ipairs, tonumber, tostring = pcall, type, pairs, ipairs, tonumber, tostring
local getmetatable, rawget = getmetatable, rawget

local S -- installed state, nil while uninstalled

-- classes patched by adopt(): known[cls] = true (has the API now) / false (not a supported class)
local known = {}
-- classes we added methods to: patched[cls] = { kind = "actor"|"pmd", into = fn, alloc = fn }
local patched = {}
local atlases = setmetatable({}, { __mode = "k" }) -- mod -> atlas state | false

-- --------------------------------------------------------------------------------------------- recall maths
-- Private copies of lib/recall_math.lua (same operations in the same order, so results are bit-identical).
local function ease(t)
  t = tonumber(t) or 0
  if t < 0 then t = 0 elseif t > 1 then t = 1 end
  return t * t * (3 - 2 * t)
end

local function blend(recall, fx, fy, px, py, lift)
  local e = ease(recall)
  return px + (fx - px) * e, py + (fy - py) * e - (lift or 0) * (1 - e), e
end

-- --------------------------------------------------------------------------------------------- clock
local function now()
  local s = S
  if s and s.now then return s.now() end
  if love and love.timer and love.timer.getTime then return love.timer.getTime() end
  return os.clock()
end

local function newStats()
  return {
    snapshots = 0, noDraw = 0, recorderSwaps = 0, errors = 0, reentrant = 0, extraDraws = 0,
    adopted = 0, groundCalibrations = 0, groundUnfit = 0,
    opaqueScans = 0, shardDecodes = 0, shardDecodeMs = 0, shardDecodeMaxMs = 0, shardReleases = 0,
    lastError = nil,
  }
end

local function log(fmt, ...)
  local s = S
  if s and s.log then pcall(s.log, fmt, ...) end
end

-- --------------------------------------------------------------------------------------------- recorder
local recording = false
local savedDraw, savedColor, savedG -- the originals while a swap is active (uninstall mid-call safety)
local cr, cg, cb, ca = 1, 1, 1, 1 -- colour as the recorded draw() sets it
local nDraw = 0
local dImg, dQuad, dX, dY, dRot, dSX, dSY, dOX, dOY
local dR, dG, dB, dA = 1, 1, 1, 1
local foam = {} -- bounded second draw; no frame allocations
local factorCache = {}

local function recColor(r, g, b, a)
  if type(r) == "table" then r, g, b, a = r[1], r[2], r[3], r[4] end
  cr, cg, cb, ca = r or 1, g or 1, b or 1, a or 1
end

local function recDraw(img, quad, x, y, rot, sx, sy, ox, oy)
  nDraw = nDraw + 1
  if nDraw == 1 then
    dImg, dQuad, dX, dY, dRot, dSX, dSY, dOX, dOY = img, quad, x, y, rot, sx, sy, ox, oy
    dR, dG, dB, dA = cr, cg, cb, ca
  elseif nDraw == 2 then
    foam.image, foam.quad, foam.x, foam.y, foam.rotation = img, quad, x, y, rot or 0
    foam.sx, foam.sy, foam.ox, foam.oy = sx or 1, sy or sx or 1, ox, oy
    foam.r, foam.g, foam.b, foam.a = cr, cg, cb, ca
  end
end

-- Runs self:draw(...) under the recorder. Returns true when a draw was recorded (the d* upvalues hold it).
local function record(self, x, y, camX, camY, facing, walkPhase, stepFlip)
  local st = S.st
  if recording then st.reentrant = st.reentrant + 1; return false end
  local g = love and love.graphics
  if not g then return false end
  local oD, oC = g.draw, g.setColor
  recording = true
  savedDraw, savedColor, savedG = oD, oC, g
  nDraw = 0
  cr, cg, cb, ca = 1, 1, 1, 1
  dImg, dQuad = nil, nil
  foam.image, foam.quad = nil, nil
  g.draw, g.setColor = recDraw, recColor
  local ok, err = pcall(self.draw, self, x, y, camX, camY, facing, walkPhase, stepFlip)
  g.draw, g.setColor = oD, oC
  recording = false
  savedDraw, savedColor, savedG = nil, nil, nil
  st.recorderSwaps = st.recorderSwaps + 1
  if not ok then
    st.errors = st.errors + 1
    st.lastError = err
    if st.errors <= 3 then log("[wilds-snapshot] draw() raised inside the recorder: %s", tostring(err)) end
    dImg, dQuad = nil, nil
    foam.image, foam.quad = nil, nil
    return false
  end
  if nDraw == 0 then return false end
  if nDraw > 1 then st.extraDraws = st.extraDraws + nDraw - 1 end
  return true
end

-- copy the recorded draw into `out` (colour as r,g,b,a). Everything the edited code wrote, including nil ox/oy.
local function fill(self, out)
  out.r, out.g, out.b, out.a = dR, dG, dB, dA
  out.image, out.quad, out.rotation = dImg, dQuad, dRot or 0
  out.x, out.y = dX, dY
  local sx = dSX or 1
  out.sx, out.sy, out.ox, out.oy = sx, dSY or sx, dOX, dOY
  self._img = dImg -- pin: the image cache of the mod is weak, a visible sprite must stay alive
  dImg, dQuad = nil, nil
  if type(self.cropHeight) == "function" or type(self.swimDropFor) == "function" then
    out.extraLayerCount = 0
    if out.extraLayers then out.extraLayers[1].image, out.extraLayers[1].quad = nil, nil end
  else
    -- Keep the exact 1.5 output schema for old consumers/oracle parity.
    out.extraLayerCount, out.extraLayers = nil, nil
  end
end

-- Metadata scaling is owned by VRITK. The recorder bypasses any HD draw compositor;
-- apply the upstream species factor exactly once, retaining recall/sink scale.
local function factorFor(path)
  local hd = S and S.hdField
  if not (hd and type(hd.speciesFactor) == "function") then return 1 end
  if hd.speciesSizes == false then return 1 end
  local value = factorCache[path]
  if value ~= nil then return value end
  value = tonumber(hd.speciesFactor(path))
  if not value or value ~= value then return 1 end
  value = max(0.2, min(2, value)) -- identical to Wilds hd_field scaleOfPath
  factorCache[path] = value
  return value
end

local function scaleAbout(out, factor, px, py)
  if factor == 1 then return end
  local sx, sy = out.sx, out.sy
  out.x = out.x + (px - (out.ox or 0)) * sx * (1 - factor)
  out.y = out.y + (py - (out.oy or 0)) * sy * (1 - factor)
  out.sx, out.sy = sx * factor, sy * factor
end

local function attachFoam(self, out, factor, ax, ay)
  if nDraw ~= 2 or not foam.image or not foam.quad then
    self._vsFoamImage = nil
    return
  end
  local layers = out.extraLayers
  if not layers then layers = { {} }; out.extraLayers = layers end
  local layer = layers[1]
  for k, v in pairs(foam) do layer[k] = v end
  -- Nil origins must also replace stale reused descriptor values.
  layer.ox, layer.oy = foam.ox, foam.oy
  scaleAbout(layer, factor, ax, ay)
  layer.groundX, layer.groundZ, layer.groundY = out.groundX, out.groundZ, out.groundY
  out.extraLayerCount = 1
  self._vsFoamImage = layer.image
  foam.image, foam.quad = nil, nil
end

-- --------------------------------------------------------------------------------------------- shard memo
local function releaseData(d)
  if d and type(d.release) == "function" then pcall(d.release, d) end
end

local function dropMemo()
  local s = S
  local m = s and s.memo
  if m then
    releaseData(m.data)
    s.memo = nil
    s.st.shardReleases = s.st.shardReleases + 1
  end
end

local function expireMemo(t)
  local s = S
  local m = s and s.memo
  if m and (t or now()) - m.last > M.MEMO_TTL then dropMemo() end
end

-- --------------------------------------------------------------------------------------------- JSON
-- Small strict-enough decoder for the atlas indices (objects, arrays, strings, numbers, true/false/null).
local function jsonDecode(s)
  local pos = 1
  if s:sub(1, 3) == "\239\187\191" then pos = 4 end
  local len = #s
  local value
  local function ws() pos = s:find("[^ \t\r\n]", pos) or (len + 1) end
  local ESC = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
  local function str()
    pos = pos + 1
    local parts, n = {}, 0
    while true do
      local j = s:find('["\\]', pos)
      if not j then error("unterminated string", 0) end
      if j > pos then n = n + 1; parts[n] = s:sub(pos, j - 1) end
      if s:sub(j, j) == '"' then pos = j + 1; return table.concat(parts) end
      local e = s:sub(j + 1, j + 1)
      if ESC[e] then n = n + 1; parts[n] = ESC[e]; pos = j + 2
      elseif e == "u" then
        local code = tonumber(s:sub(j + 2, j + 5), 16)
        if not code then error("bad unicode escape", 0) end
        local c
        if code < 0x80 then c = string.char(code)
        elseif code < 0x800 then c = string.char(0xC0 + floor(code / 64), 0x80 + code % 64)
        else c = string.char(0xE0 + floor(code / 4096), 0x80 + floor(code / 64) % 64, 0x80 + code % 64) end
        n = n + 1; parts[n] = c; pos = j + 6
      else error("bad escape", 0) end
    end
  end
  function value()
    ws()
    local c = s:sub(pos, pos)
    if c == "{" then
      local t = {}
      pos = pos + 1; ws()
      if s:sub(pos, pos) == "}" then pos = pos + 1; return t end
      while true do
        ws()
        if s:sub(pos, pos) ~= '"' then error("expected key", 0) end
        local k = str(); ws()
        if s:sub(pos, pos) ~= ":" then error("expected colon", 0) end
        pos = pos + 1
        t[k] = value(); ws()
        local d = s:sub(pos, pos); pos = pos + 1
        if d == "}" then return t end
        if d ~= "," then error("expected comma", 0) end
      end
    elseif c == "[" then
      local t, n = {}, 0
      pos = pos + 1; ws()
      if s:sub(pos, pos) == "]" then pos = pos + 1; return t end
      while true do
        n = n + 1; t[n] = value(); ws()
        local d = s:sub(pos, pos); pos = pos + 1
        if d == "]" then return t end
        if d ~= "," then error("expected comma", 0) end
      end
    elseif c == '"' then return str()
    elseif s:sub(pos, pos + 3) == "true" then pos = pos + 4; return true
    elseif s:sub(pos, pos + 4) == "false" then pos = pos + 5; return false
    elseif s:sub(pos, pos + 3) == "null" then pos = pos + 4; return nil
    else
      local num = s:match("^-?%d+%.?%d*[eE]?[+-]?%d*", pos)
      if not num or num == "" then error("unexpected character", 0) end
      pos = pos + #num
      return tonumber(num)
    end
  end
  local v = value()
  ws()
  if pos <= len then error("trailing data", 0) end
  return v
end

local function decodeJson(raw)
  local ok, v = pcall(jsonDecode, raw)
  if ok and type(v) == "table" then return v end
  return nil
end

-- --------------------------------------------------------------------------------------------- atlas support
local function readMod(mod, rel)
  if not (mod and type(mod.read) == "function") then return nil end
  local ok, data = pcall(mod.read, mod, rel)
  if ok and type(data) == "string" and data ~= "" then return data end
  return nil
end

-- same acceptance rules as wilds lib/sprite_atlas.lua install(); nil when the mod has no usable atlas
local function buildAtlas(mod)
  local raw = readMod(mod, M.ATLAS_ROOT_INDEX)
  if not raw then return nil end
  local root = decodeJson(raw)
  if not root or root.version ~= 1 or type(root.families) ~= "table" then return nil end
  local a = { mod = mod, dirToFamily = {}, familyMeta = {}, families = {}, support = {} }
  local any = false
  for name, meta in pairs(root.families) do
    if type(meta) == "table" and type(meta.index) == "string" and type(meta.dirs) == "table" then
      a.familyMeta[name] = { index = meta.index }
      for _, dir in ipairs(meta.dirs) do
        a.dirToFamily[dir] = name
        any = true
      end
    end
  end
  if not any then return nil end
  return a
end

local function atlasFor(mod)
  local a = atlases[mod]
  if a ~= nil then return a or nil end
  a = buildAtlas(mod)
  atlases[mod] = a or false
  return a
end

local function loadFamily(a, name)
  local fam = a.families[name]
  if fam ~= nil then return fam or nil end
  local meta = a.familyMeta[name]
  local raw = meta and readMod(a.mod, meta.index)
  local idx = raw and decodeJson(raw) or nil
  if not (idx and type(idx.shards) == "table" and type(idx.dirs) == "table") then
    a.families[name] = false
    return nil
  end
  idx.name = name
  a.families[name] = idx
  return idx
end

local function lookup(a, rel)
  if type(rel) ~= "string" then return nil end
  local dir, fname = rel:match("^(.*)/([^/]+)$")
  if not dir then return nil end
  local famName = a.dirToFamily[dir]
  if not famName then return nil end
  local fam = loadFamily(a, famName)
  if not fam then return nil end
  local entry = fam.dirs[dir] and fam.dirs[dir][fname]
  if type(entry) ~= "table" then return nil end
  return fam, entry
end

-- decoded shard, through the single-slot memo
local function shardData(a, fam, shardIndex)
  local meta = fam.shards[shardIndex + 1]
  if type(meta) ~= "table" or type(meta.file) ~= "string" then return nil end
  if not (love and love.image and love.image.newImageData) then return nil end
  local mod = a.mod
  local full = mod.assets and mod.assets.path and mod.assets:path(meta.file) or meta.file
  local s = S
  local t = now()
  local m = s.memo
  if m then
    if m.file == full and t - m.last <= M.MEMO_TTL then m.last = t; return m.data end
    dropMemo()
  end
  local ok, data = pcall(love.image.newImageData, full)
  local t1 = now()
  if not ok or not data then return nil end
  local ms = (t1 - t) * 1000
  local st = s.st
  st.shardDecodes = st.shardDecodes + 1
  st.shardDecodeMs = st.shardDecodeMs + ms
  if ms > st.shardDecodeMaxMs then st.shardDecodeMaxMs = ms end
  s.memo = { file = full, data = data, last = t1 }
  return data
end

-- SpriteAtlas.opaqueBottom, re-implemented over the same files (see the header). Returns the lowest opaque row + 1
-- of the direction row of a sheet, or nil (no atlas / not covered / undecodable / fully transparent).
local function opaqueBottom(mod, rel, cw, ch, row, cols)
  local a = atlasFor(mod)
  if not a then return nil end
  -- nested number-keyed cache: a hit allocates nothing (no string key)
  local byW = a.support[rel]
  local byH = byW and byW[cw]
  local byRow = byH and byH[ch]
  local byCols = byRow and byRow[row]
  local cached = byCols and byCols[cols]
  if cached ~= nil then return cached or nil end

  local function store(value)
    byW = a.support[rel]
    if not byW then byW = {}; a.support[rel] = byW end
    byH = byW[cw]
    if not byH then byH = {}; byW[cw] = byH end
    byRow = byH[ch]
    if not byRow then byRow = {}; byH[ch] = byRow end
    byCols = byRow[row]
    if not byCols then byCols = {}; byRow[row] = byCols end
    byCols[cols] = value
    return value or nil
  end

  S.st.opaqueScans = S.st.opaqueScans + 1
  local fam, entry = lookup(a, rel)
  local data = fam and shardData(a, fam, entry[1])
  if not data or cw < 1 or ch < 1 or row < 0 or cols < 1
      or cw * cols > entry[4] or (row + 1) * ch > entry[5] then
    return store(false)
  end
  for y = ch - 1, 0, -1 do
    for x = 0, cw * cols - 1 do
      local _, _, _, alpha = data:getPixel(entry[2] + x, entry[3] + row * ch + y)
      if alpha > 0 then return store(y + 1) end
    end
  end
  return store(false)
end

-- --------------------------------------------------------------------------------------------- snapshots
local function actorSnapshotInto(self, out, x, y, camX, camY, facing, walkPhase, stepFlip)
  if not S then return nil end
  local st = S.st
  st.snapshots = st.snapshots + 1
  if S.memo then expireMemo() end
  -- Ground-plane motion is separate from native art padding and recall lift.
  local groundX, groundZ = x, y
  local recall = self.recall
  if recall ~= nil and recall < 1 and self.recallX and self.recallY then
    groundX, groundZ = blend(recall, x, y, self.recallX, self.recallY, 0)
  end
  local act = self.act
  local gfacing = facing
  if act and act.facing then gfacing = act.facing end
  if not record(self, x, y, camX, camY, facing, walkPhase, stepFlip) then
    st.noDraw = st.noDraw + 1
    return nil
  end
  fill(self, out)
  local pushX, pushY = self.pushX, self.pushY
  if pushX == nil or pushY == nil then
    pushX, pushY = self.behindOffset(gfacing, self.largePushback)
  end
  if act then pushX, pushY = pushX + (act.dx or 0), pushY + (act.dy or 0) end
  out.groundX = groundX + pushX + 8
  out.groundZ = groundZ + pushY + 8
  out.groundY = groundZ + pushY + 16
  if type(self.swimDropFor) == "function" then
    local path = self:imagePath()
    local _, _, w, h = out.quad:getViewport()
    scaleAbout(out, factorFor(path), w / 2, h)
  end
  return out
end

local function pmdPathOf(self, entry)
  local p = self._vsPath
  if p and self._vsInfo == self.info and self._vsAnim == self.anim
      and self._vsDex == self.dex and self._vsShiny == self.shiny then
    return p
  end
  local variant = (self.shiny and entry.shiny) and "shiny" or "normal"
  local key = type(self.dex) == "number" and format("%03d", self.dex) or tostring(self.dex)
  p = format("assets/pmd/%s/%s-%s.png", self.anim, key, variant)
  self._vsPath, self._vsInfo, self._vsAnim = p, self.info, self.anim
  self._vsDex, self._vsShiny = self.dex, self.shiny
  return p
end

local function pmdSnapshotInto(self, out, x, y, camX, camY, facing, walkPhase, stepFlip)
  if not S then return nil end
  local st = S.st
  st.snapshots = st.snapshots + 1
  if S.memo then expireMemo() end
  local groundX, groundZ = x, y
  local recall = self.recall
  local recalled = recall ~= nil and recall < 1
  if recalled and self.recallX and self.recallY then
    groundX, groundZ = blend(recall, x, y, self.recallX, self.recallY, 0)
  end
  local act = self.act
  local gfacing = facing
  if act and act.facing then gfacing = act.facing end
  if not record(self, x, y, camX, camY, facing, walkPhase, stepFlip) then
    st.noDraw = st.noDraw + 1
    return nil
  end
  fill(self, out)

  local entry = self.info[self.anim] -- a table, or draw() would not have drawn
  local scale, scaleY = out.sx, out.sy -- as drawn: base scale x recall multiplier, then the sink squash
  local pushY = floor(self.pushY + 0.5)
  local px = floor(self.pushX + .5) + floor((act and act.dx or 0) + .5)
  local pz = pushY + floor((act and act.dy or 0) + .5)
  local ay = entry.ay

  -- PMD_GROUND_Y is private to the mod: calibrate it from the recorded draw (never while recalled: the
  -- recall lift is private too). Costs one placement() per snapshot.
  local G = S.groundY
  -- 1.7.1 bakes grounded vs intentionally hovering anchors into entry.ay.
  -- Swimming uses an independent band baseline and must never calibrate land G.
  if type(self.cropHeight) == "function" then
    local _, band
    if self.swimming then _, band = self.cropHeight(entry) end
    G = band and S.swimY or S.groundY
    out.groundX, out.groundZ = groundX + px + 8, groundZ + pz + 8
    out.groundY = groundZ + pz + G
    local factor = factorFor(pmdPathOf(self, entry))
    scaleAbout(out, factor, entry.ax, band or ay)
    if band then attachFoam(self, out, factor, entry.ax, band)
    else
      self._vsFoamImage = nil
      -- 1.7.1 foot is a classification marker, not the last opaque edge.
      -- Grounded land art can extend below ay (Charizard:28.5 vs32).
      -- Preserve intentional hover and waterlines; sample the actual atlas
      -- row, cached by animation/direction, after species scaling once.
      local foot = tonumber(entry.foot)
      if foot and foot >= ay then
        local support = opaqueBottom(self.mod, pmdPathOf(self, entry), entry.cw, entry.ch, self.rowFor(gfacing), entry.cols)
        if support then
          local baseline = floor(groundZ + G - ay * scale + .5) + pz
          baseline = baseline + floor(ay * (scale - scaleY) + .5)
          out.groundY = baseline + ay * scaleY + max(0, support - ay) * out.sy
        end
      end
    end
    return out
  end
  if not recalled then
    local sinkAdj = 0
    if act then
      local sink = tonumber(act.sink) or 0
      if sink > 0 then sinkAdj = floor(ay * (scale - scaleY) + 0.5) end
    end
    local recBase = out.y - pz - sinkAdj
    local _, dyp = self.placement(entry, scale, G, x - camX, y - camY)
    if dyp ~= recBase then
      -- placement() rounds (floor(v + .5)), so the integer ground offset is one of the neighbours of the exact value
      local est = recBase + ay * scale - (y - camY)
      local Gn = floor(est)
      local _, dyn = self.placement(entry, scale, Gn, x - camX, y - camY)
      if dyn ~= recBase then
        Gn = Gn + 1
        _, dyn = self.placement(entry, scale, Gn, x - camX, y - camY)
      end
      if dyn == recBase then
        S.groundY = Gn
        G = Gn
        st.groundCalibrations = st.groundCalibrations + 1
      else
        st.groundUnfit = st.groundUnfit + 1
      end
    end
  end

  out.groundX = groundX + px + 8
  out.groundZ = groundZ + pz + 8
  out.groundY = groundZ + pz + G
  local row = self.rowFor(gfacing)
  local support = opaqueBottom(self.mod, pmdPathOf(self, entry), entry.cw, entry.ch, row, entry.cols)
  if support then
    -- Shadow markers can lie inside the body. A stable opaque support edge
    -- prevents burial; sprites entirely above the marker retain their hover.
    local baseline = floor(groundZ + G - ay * scale + .5) + pz
    baseline = baseline + floor(ay * (scale - scaleY) + .5)
    out.groundY = baseline + max(ay, support) * scaleY
  end
  return out
end

-- Allocating form: the same fields plus color={r,g,b,a} (r,g,b,a cleared).
local function snapshotAlloc(self, x, y, camX, camY, facing, walkPhase, stepFlip)
  local s = self:vrSnapshotInto({}, x, y, camX, camY, facing, walkPhase, stepFlip)
  if not s then return nil end
  s.color = { s.r, s.g, s.b, s.a }
  s.r, s.g, s.b, s.a = nil, nil, nil, nil
  return s
end

-- --------------------------------------------------------------------------------------------- public API
local function kindOf(cls)
  if type(cls.draw) ~= "function" then return nil end
  if type(cls.rowFor) == "function" and type(cls.frameAt) == "function" and type(cls.placement) == "function" then
    return "pmd"
  end
  if type(cls.frameIndexFor) == "function" and type(cls.drawOffset) == "function"
      and type(cls.behindOffset) == "function" then
    return "actor"
  end
  return nil
end

--- Call once at VRITK startup. ctx = { log = fn(fmt, ...), now = optional clock fn }. Returns true or false + why.
function M.install(ctx)
  if S then return true, "already installed" end
  if not (love and love.graphics and type(love.graphics.draw) == "function"
      and type(love.graphics.setColor) == "function") then
    return false, "no love.graphics.draw/setColor"
  end
  ctx = ctx or {}
  S = { log = ctx.log, now = ctx.now, st = newStats(), groundY = ctx.groundY or 12,
    swimY = ctx.swimY or 18, hdField = ctx.hdField, voxelActive = ctx.voxelActive, memo = nil }
  known, patched, factorCache = {}, {}, {}
  atlases = setmetatable({}, { __mode = "k" })
  return true
end

--- Give the renderer's class the snapshot API (a table lookup after the first call). Call right after every
--- renderer is created. Returns true when the renderer has the API. False when not installed / unsupported.
function M.adopt(renderer)
  if not S or type(renderer) ~= "table" then return false end
  local mt = getmetatable(renderer)
  local cls = mt and mt.__index
  if type(cls) ~= "table" then return false end
  local k = known[cls]
  if k ~= nil then return k end
  if type(cls.vrSnapshotInto) == "function" and type(cls.vrSnapshot) == "function" then
    known[cls] = true -- already native (edited Wilds) or added by someone else: not ours to remove
    return true
  end
  local kind = kindOf(cls)
  if not kind then known[cls] = false; return false end
  local rec = { kind = kind }
  if rawget(cls, "vrSnapshotInto") == nil then
    rec.into = kind == "pmd" and pmdSnapshotInto or actorSnapshotInto
    cls.vrSnapshotInto = rec.into
  end
  if rawget(cls, "vrSnapshot") == nil then
    rec.alloc = snapshotAlloc
    cls.vrSnapshot = rec.alloc
  end
  -- Native follower spacing and fight labels ask these dimension methods.
  -- Match the VR metadata size only while voxel owns the view; flat mode keeps
  -- the provider's own HD-enabled/disabled semantics.
  if kind == "pmd" and type(cls.cropHeight) == "function" and type(cls.hdScale) == "function" then
    rec.sizeKey, rec.sizeOriginal = "hdScale", cls.hdScale
    rec.sizeMethod = function(self)
      if S and S.voxelActive and S.voxelActive() then
        local entry = self.info and self.info[self.anim]
        if entry then return factorFor(pmdPathOf(self, entry)) end
        return 1
      end
      return rec.sizeOriginal(self)
    end
    cls.hdScale = rec.sizeMethod
  elseif kind == "actor" and type(cls.swimDropFor) == "function" and type(cls.visualWidth) == "function" then
    rec.sizeKey, rec.sizeOriginal = "visualWidth", cls.visualWidth
    rec.sizeMethod = function(self)
      if S and S.voxelActive and S.voxelActive() then
        local path, width = self:imagePath(), self:frameWidth()
        return path and width and width * factorFor(path) or width
      end
      return rec.sizeOriginal(self)
    end
    cls.visualWidth = rec.sizeMethod
  end
  patched[cls] = rec
  known[cls] = true
  S.st.adopted = S.st.adopted + 1
  log("[wilds-snapshot] adopted %s renderer class", kind)
  return true
end

--- Remove every method this module added (only while still ours) and free every cache. Safe to call twice.
function M.uninstall()
  if recording and savedG then -- never leave the recorder installed
    savedG.draw, savedG.setColor = savedDraw, savedColor
    recording = false
  end
  for cls, rec in pairs(patched) do
    if rec.into and rawget(cls, "vrSnapshotInto") == rec.into then cls.vrSnapshotInto = nil end
    if rec.alloc and rawget(cls, "vrSnapshot") == rec.alloc then cls.vrSnapshot = nil end
    if rec.sizeKey and rawget(cls, rec.sizeKey) == rec.sizeMethod then cls[rec.sizeKey] = rec.sizeOriginal end
  end
  dropMemo()
  patched, known, factorCache = {}, {}, {}
  foam.image, foam.quad = nil, nil
  atlases = setmetatable({}, { __mode = "k" })
  dImg, dQuad, dOX, dOY, savedDraw, savedColor, savedG = nil, nil, nil, nil, nil, nil, nil
  local had = S ~= nil
  S = nil
  return had
end

function M.installed() return S ~= nil end

--- Housekeeping (optional, once a frame or so): releases the shard memo once idle for MEMO_TTL.
function M.update(t)
  if S and S.memo then expireMemo(t) end
end

--- Counters for tests and diagnostics (a fresh table).
function M.stats()
  local o = {}
  local s = S
  if s then for k, v in pairs(s.st) do o[k] = v end end
  o.installed = s ~= nil
  o.groundY = s and s.groundY or nil
  o.memoShard = s and s.memo and s.memo.file or nil
  local n = 0
  for _ in pairs(patched) do n = n + 1 end
  o.patchedClasses = n
  return o
end

--- Shaped like the edited SpriteAtlas.stats(). The stock atlas keeps no counters, so only what this module can
--- observe is filled: shards = decoded shards held by the memo (0/1), decodes / decodeMs / decodeMaxMs = the
--- shard decodes done for opaque-bottom scans; images / evictedShards / evictedImages are not observable (0).
function M.atlasStats()
  local s = S
  local st = s and s.st
  return {
    shards = s and s.memo and 1 or 0,
    images = 0, evictedShards = 0, evictedImages = 0,
    decodes = st and st.shardDecodes or 0,
    decodeMs = st and st.shardDecodeMs or 0,
    decodeMaxMs = st and st.shardDecodeMaxMs or 0,
  }
end

--- Test hook: forget the atlas index caches (the per-sheet support lines are recomputed on next use).
function M._resetAtlas()
  atlases = setmetatable({}, { __mode = "k" })
  dropMemo()
  if S then S.groundY = 12 end
end

return M
