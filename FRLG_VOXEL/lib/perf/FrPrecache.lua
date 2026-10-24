-- FRLG_VOXEL Lab 57: WORLD CACHE (FireRed's own file).
--
-- The first time a map or border ring is built, a later idle frame reads the
-- finished GPU vertex streams (and the other sun-independent results) back from
-- the record and writes them to mod.cache. On a later visit, also after a
-- restart, _build loads those bytes instead of running the mesher, the chunk
-- bucketing, the window / glass scans, the height raster, pools and water.
--
-- What is stored per record (see FrPrecacheKey.lua for the key):
--   * every chunk of the opaque / under / over / keyed layers and the room shell:
--     float32 vertex streams (+ AO / emit streams), bounds, triangle counts
--   * the shadow mask: SUN SHADOWS FIXED stores the finished mask (one baked
--     direction, pools in B); MOVING stores the pools-bearing mask plus the
--     rgba32f height field (Solar.pump still marches the directional mask live);
--     indoor / cave maps store their contact mask; pools-only records their
--     pools bytes
--   * per-cell heights, water summary, the occluder fields BattleOccluders and
--     HostApi read, the window-glass texel lists (replayed into Emissive), the
--     tall-grass cells (RetroGrass:build is re-run on a hit)
-- Not cached, always live: records whose mask plan is "defer", interiors with a
-- Pokemon Center healer rig, anything the mesher stubbed.
--
-- Cooperative by construction: loading is part of the build coroutine and
-- yields through Scene's deadline checkpoints (a header read, then per part:
-- read, md5, decompress, and one upload per 4096-vertex segment); writing runs
-- only in frames with no build job, at most one cache:write per frame, in
-- slices of about CAPTURE_MS. A bad record (md5, structure, limits) is deleted,
-- counted, and the build falls back to the live path. Nothing here may throw
-- into Scene.
--
-- Prior art, ideas only (no code shared): the in-house Emerald prebake design.
local V = ...
local F = V.require("perf/FrPrecacheFormat")
local CacheIO = V.require("perf/FrPrecacheIO")
local K = V.require("perf/FrPrecacheKey")
local Store = V.require("perf/FrPrecacheStore")
local Shaders = V.require("render/Shaders")
local Light = V.require("render/Light")
local Solar = V.require("render/SolarShadows")
local LightingRuntime = V.require("render/FrLightingRuntime")
local VoxelTreeCache = V.require("perf/FrVoxelTreeCache")

local PC = {}
PC.__index = PC

PC.BULK_PART_TARGET = 2 * 1024 * 1024 -- preparation only; stored segments/schema unchanged
PC.CAPTURE_MS = 2.0      -- longest capture slice
PC.FLUSH_MIN_MS = 1.5    -- do no cache work in a frame with less than this left
PC.PACK_VERTS = 192      -- vertices read back between checkpoints
PC.MAX_PENDING_BYTES = 6 * 1024 * 1024 -- Lua-heap bytes (masks, glass lists) held by waiting records
PC.MAX_PENDING = 32      -- records waiting for capture (a warp queues ~7 builds back to back; desktop test D1 dropped the root at 6)
PC.MAX_FAIL = 3          -- consecutive write failures before the cache turns itself off
PC.AO_FORMAT = { { "VertexAO", "float", 1 } }
PC.EMIT_FORMAT = { { "VertexEmit", "float", 1 } }
PC.TREE_FORMAT = { { "VertexTree", "float", 3 } }

local ALL_LAYERS = { "opaque", "under", "over", "keyed", "shell" }
-- mask kinds
local M_NONE, M_POOLS, M_CONTACT, M_FIXED, M_MOVING = 0, 1, 2, 3, 4
PC.M = { NONE = M_NONE, POOLS = M_POOLS, CONTACT = M_CONTACT, FIXED = M_FIXED, MOVING = M_MOVING }

local NaN = 0 / 0
local floor = math.floor

local function newStats()
  return { hit = 0, miss = 0, bypass = 0, corrupt = 0, saved = 0, saveFailed = 0, unclean = 0, dropped = 0,
    hitMs = 0, hitMsMax = 0, missMs = 0, saveMs = 0, saveMsMax = 0, bytesRead = 0, bytesWritten = 0,
    parts = 0, evicted = 0 }
end

function PC.new(o)
  local self = setmetatable({
    cache = o.cache, mod = o.mod, log = o.log or print,
    clock = o.clock or (love and love.timer and love.timer.getTime) or os.clock,
    isOn = o.enabled or function() return true end,
    gate = o.gate,          -- Lab 57: VRITK installed and active? (nil = always)
    capBytes = o.capBytes or Store.CAP_BYTES,
    stats = newStats(), pending = {}, bypassWhy = {}, events = 0,
    failStreak = 0,
  }, PC)
  self.usable = self.cache ~= nil and self.mod ~= nil and love ~= nil and love.data ~= nil
    and love.data.hash ~= nil and love.data.compress ~= nil and love.data.pack ~= nil
    and love.graphics ~= nil and love.image ~= nil
  self.store = Store.new(self.cache, self.log, self.clock)
  return self
end

function PC:enabled()
  return self.usable and not self.disabled and self.isOn() ~= false
end

function PC:_say(fmt, ...)
  local ok, s = pcall(string.format, fmt, ...)
  self.log("precache " .. (ok and s or fmt))
end

-- Codes, engine, store index: once, at first use. `tick` lets a build coroutine yield between files.
function PC:ensureReady(tick)
  if self.ready then return true end
  if not self.codeJob then self.codeJob = K.codeJob(self.mod) end
  local t0 = self.clock()
  while not self.codeJob:step() do
    if tick then tick() end
  end
  self.code = self.codeJob.digest
  self.codeFiles, self.codeBytes = self.codeJob.files, self.codeJob.bytes
  self.gen = tonumber(self.code:sub(1, 7), 16) or 0
  self.engine = K.engineDigest()
  self.game = K.gameId()
  local n, bytes = self.store:load()
  self.ready = true
  self:_say("ready game=%s code=%s (%d files, %.0f KB, %.1f ms) engine=%s records=%d cache=%.1f MB cap=%d MB",
    tostring(self.game), self.code:sub(1, 8), self.codeJob.files, self.codeJob.bytes / 1024,
    (self.clock() - t0) * 1000, self.engine:sub(1, 8), n, bytes / 1048576, self.capBytes / 1048576)
  return true
end

-- Digest of the inputs a record depends on, minus the cheap settings token. -> base, edgeDigest | nil, why
function PC:baseKey(key, input, tick)
  if not self:ensureReady(tick) then return nil, "not ready" end
  local atlas, why = K.atlasDigest(input.pair)
  if not atlas then return nil, why end
  local inD, why2 = K.inputDigest(input, tick)
  if not inD then return nil, why2 end
  local edgeD = K.edgeDigest(input, tick)
  local paint = PC.PAINT_FREE -- Lab 59: records do not depend on the night paint (see Scene:_atlasData)
  local kind = input.isBorder and "ring" or "map"
  return table.concat({ K.FORMAT, tostring(self.game), kind, tostring(key), self.code, self.engine, atlas, paint, inD, edgeD }, "|"), edgeD, paint
end

-- The atlas paint state again (end of a live build: did the night repaint change meanwhile?)
PC.PAINT_FREE = "pf1"
function PC:paintToken(pair) return PC.PAINT_FREE end

-- WorldSource:atlasFor memoises one atlas table per tileset for the whole session (its window / texel scans are
-- read once, lazily, also by builds the cache never sees: bypassed ones, neighbour water scans, cache OFF), while
-- RealTimeClockTest repaints and restores the underlying images in place. What a mesher saw can therefore follow
-- an OLDER paint state than the one in the key. samplePaint() watches EVERY loaded tileset (Scene:pump calls it
-- each frame, baseKey/_pcFinish force it): the first paint token seen for a tileset table is remembered, a
-- different one later taints that tileset for the rest of the session, and nothing built from a tainted
-- tileset is saved (loads stay keyed by the current paint state). Tilesets are held weakly.
function PC:samplePaint(force)
  do return end -- Lab 59: paint-independent records; the Lab 57 taint rule below is retired (kept for reference)
  if self.gate and not self.gate() then return end
  self._sampleN = (self._sampleN or 0) + 1
  if not force and self._sampleN % 4 ~= 0 then return end
  local NT = self.NT
  if not NT then
    local ok, m = pcall(require, "src.core.game3.tileset_native")
    if not (ok and type(m) == "table") then return end
    NT = m
    self.NT = m
  end
  local ps = NT._pairs
  if type(ps) ~= "table" then return end
  self.tsPaint = self.tsPaint or setmetatable({}, { __mode = "k" })
  for _, ts in pairs(ps) do
    if type(ts) == "table" then
      local tok = K.paintTokenOf(ts)
      local e = self.tsPaint[ts]
      if not e then self.tsPaint[ts] = { tok = tok }
      elseif e.tok ~= tok then
        self:_say("atlas paint changed for %s: %s -> %s (records built from it are not saved this session)",
          tostring(ts.pair or ts.name or ts.id or "?"), tostring(e.tok):sub(1, 7), tostring(tok):sub(1, 7))
        e.tok = tok; e.tainted = true
      end
    end
  end
end
-- R1d: a tileset first scanned by a build can be painted in that same frame's draw, before the 4th-frame sample would
-- see it. Scene:pump calls this at its end (before draw): any tileset not yet recorded gets sampled right away.
function PC:sampleNew()
  do return end -- Lab 59
  if self.gate and not self.gate() then return end
  local NT = self.NT
  local ps = NT and NT._pairs
  if type(ps) ~= "table" then
    return self:samplePaint(true)
  end
  local seen = self.tsPaint
  for _, ts in pairs(ps) do
    if type(ts) == "table" and not (seen and seen[ts]) then return self:samplePaint(true) end
  end
end
function PC:pairTainted(pair)
  do return false end -- Lab 59
  local NT = self.NT
  local ts = NT and NT._pairs and NT._pairs[pair]
  local e = ts and self.tsPaint and self.tsPaint[ts]
  return e ~= nil and e.tainted == true
end

-- md5 hex of any plain value through the record codec (sorted keys: deterministic). nil, why when it is not plain.
function PC:valueDigest(v)
  local ok, s = pcall(function()
    local w = F.writer()
    w:value(v)
    return w:result()
  end)
  if not ok then return nil, tostring(s) end
  return K.md5hex(s)
end

function PC:recordKey(base, settings)
  return K.recordKey({ base, settings })
end

-- The neighbour part of the key again (end of a live build: did it change meanwhile?)
function PC:edgeDigest(input, tick) return K.edgeDigest(input, tick) end

-- A finished build that is not saved (Lab 57 counted it as stats.unclean + 1; Lab 59 also remembers why).
function PC:unclean(why)
  self.stats.unclean = self.stats.unclean + 1
  self.uncleanWhy = self.uncleanWhy or {}
  self.uncleanWhy[why] = (self.uncleanWhy[why] or 0) + 1
end

function PC:bypass(why)
  self.stats.bypass = self.stats.bypass + 1
  self.bypassWhy[why] = (self.bypassWhy[why] or 0) + 1
end

function PC:summary()
  local s, i = self.stats, self.store:info()
  return ("hits=%d misses=%d writes=%d corrupt=%d bypass=%d unclean=%d dropped=%d writeFailed=%d evicted=%d cacheMB=%.1f records=%d pending=%d%s"):format(
    s.hit, s.miss, s.saved, s.corrupt, s.bypass, s.unclean, s.dropped, s.saveFailed, self.store.stats.evicted or 0,
    i.bytes / 1048576, i.records, #self.pending + (self.co and 1 or 0), self.disabled and (" DISABLED:" .. self.disabled) or "")
end

function PC:status()
  local s = {}
  for k, v in pairs(self.stats) do s[k] = v end
  local i = self.store:info()
  s.records, s.bytes, s.pendingWrites, s.pendingDeletes = i.records, i.bytes, #self.pending + (self.co and 1 or 0), i.pendingDelete
  s.disabled, s.enabled, s.code, s.cap = self.disabled, self:enabled(), self.code, self.capBytes
  s.bypassWhy = self.bypassWhy
  s.uncleanWhy = self.uncleanWhy
  return s
end

function PC:_event()
  self.events = self.events + 1
  if self.events % 8 == 0 then self:_say("summary %s", self:summary()) end
end

-- ------------------------------------------------------------------ header codec
-- blob refs: { part, off, len }
local function wRefs(w, refs)
  w:u16(#refs)
  for _, r in ipairs(refs) do
    w:u16(r.part); w:u32(r.off); w:u32(r.len)
  end
end
local function rRefs(r, parts, stride)
  local n = r:u16()
  local refs, sum = {}, 0
  for i = 1, n do
    local ref = { part = r:u16(), off = r:u32(), len = r:u32() }
    local p = parts[ref.part]
    if not p or ref.off + ref.len > p.raw then F.fail("blob out of range") end
    if stride and ref.len % stride ~= 0 then F.fail("blob stride") end
    sum = sum + ref.len
    refs[i] = ref
  end
  return refs, sum
end

local function finite(x) return type(x) == "number" and x == x and x > -1e18 and x < 1e18 end

-- Restore exact continuous support as well as the cell sample raster.
-- Descriptors are bounded plain data, copied before closure creation.
function PC.heightFunction(hs,w,h,ramps)
  local copied={}
  if ramps~=nil then
    if type(ramps)~="table" or #ramps>32 then F.fail("support ramps") end
    local seen={}
    for i,r in ipairs(ramps)do
      if type(r)~="table" or not finite(r.x) or not finite(r.z) or r.x~=floor(r.x) or r.z~=floor(r.z)
          or r.x<0 or r.z<0 or r.x>=w or r.z>=h or not finite(r.north) or not finite(r.south)
          or math.abs(r.north)>1000 or math.abs(r.south)>1000 then F.fail("support ramp bounds") end
      local key=r.z*w+r.x+1
      local raster=r.north
      local curve=nil
      if r.northEdge~=nil then
        local q=r.northEdge
        local stoop=type(q)=="table" and q.width==1 and type(q.samples)=="table" and #q.samples==5
          and r.x>=16 and r.x<=18 and r.z==7 and r.north==1 and r.south==.75
          and q.samples[1]==1 and q.samples[2]==1 and q.samples[3]==1 and q.samples[4]==1 and q.samples[5]==.75
        if r.shore16~=nil or type(q)~="table" or type(q.samples)~="table" or #q.samples~=5 or not(stoop or(q.width==.25 and r.north<r.south))then F.fail("north edge curve")end
        curve={width=q.width,samples={}}
        for j=1,5 do local v=q.samples[j];if not finite(v)or(not stoop and(v<r.north or v>r.south or(j>1 and v<q.samples[j-1])))then F.fail("north edge samples")end;curve.samples[j]=v end
        if curve.samples[1]~=r.north or curve.samples[5]~=r.south then F.fail("north edge endpoints")end
      end
      if r.shore16~=nil then
        if type(r.shore16)~="string" or #r.shore16~=256 or r.shore16:find("[^01]") or r.north<=r.south then F.fail("support shoreline mask") end
        if r.shore16:sub(1,1)=="0" then raster=r.south end
      end
      if seen[key] or type(hs)~="table" or hs[key]~=raster then F.fail("support ramp raster") end
      seen[key]=true;copied[i]={x=r.x,z=r.z,north=r.north,south=r.south,shore16=r.shore16,northEdge=curve}
    end
  end
  return function(cx,cy)
    local ix,iz=floor(cx),floor(cy)
    if ix<0 or iz<0 or ix>=w or iz>=h then return nil end
    for _,r in ipairs(copied)do
      if ix==r.x and iz==r.z then
        if r.northEdge then local q=r.northEdge;local t=(cy-r.z)/q.width;if t>=1 then return r.south end;local f=t*4;local i=math.min(4,floor(f)+1);return q.samples[i]+(q.samples[i+1]-q.samples[i])*(f-i+1)end
        if r.shore16 then local i=floor((cy-r.z)*16)*16+floor((cx-r.x)*16)+1;return r.shore16:sub(i,i)=="1" and r.north or r.south end
        return r.north+(r.south-r.north)*(cy-r.z)
      end
    end
    local v=hs[iz*w+ix+1]
    if v~=v then return nil end
    return v
  end
end

-- Header bytes (without the trailing md5) for meta table m.
function PC:_encodeHeader(m, tick)
  local w = F.writer()
  w:raw(F.MAGIC)
  w:u32(F.VERSION)
  w:str(m.full)
  w:str(m.key); w:u32(m.w); w:u32(m.h)
  w:d(m.originX); w:d(m.originY)
  w:str(m.layoutVersion or ""); w:str(m.sig or ""); w:str(m.pair or ""); w:str(m.mesher)
  w:d(m.tris)
  local flags = (m.aoOpaque and 1 or 0) + (m.aoUnder and 2 or 0) + (m.openAir and 4 or 0) + (m.isBorder and 8 or 0)
    + (m.layoutVersion ~= nil and 16 or 0) + (m.sig ~= nil and 32 or 0) + (m.retro and 64 or 0)
  w:u8(flags)
  w:str(m.maskPlan or "")
  w:u8(m.maskKind)
  if m.maskKind ~= M_NONE then
    w:u32(m.mw); w:u32(m.mh)
    wRefs(w, { m.maskRef })
    if m.maskKind == M_MOVING then
      w:u32(m.fw); w:u32(m.fh)
      wRefs(w, { m.fieldRef })
    end
  end
  w:u8(m.alphaState)
  if m.alphaState == 2 then w:u32(m.alphaHidden); w:u32(m.alphaCapped) end
  for _, layer in ipairs(ALL_LAYERS) do
    local list = m.layers[layer] or {}
    w:u32(#list)
    for _, c in ipairs(list) do
      w:u32(c.nverts); w:d(c.tris)
      w:d(c.x0); w:d(c.y0); w:d(c.z0); w:d(c.x1); w:d(c.y1); w:d(c.z1)
      w:u8((c.ao and 1 or 0) + (c.emit and 2 or 0) + (c.rg and 4 or 0) + (c.tree and 8 or 0))
      wRefs(w, c.main)
      if c.ao then wRefs(w, c.ao) end
      if c.emit then wRefs(w, c.emit) end
      if c.rg then w:value(c.rg, tick) end
      if c.tree then wRefs(w,c.tree) end
    end
  end
  local function section(v)
    if v == nil then w:u8(0) else w:u8(1); w:value(v, tick) end
  end
  w:u8(m.heightsMode or 0)
  if m.heights then w:value(m.heights, tick) end
  section(m.supportRamps)
  section(m.lightingData)
  section(m.shrubCards)
  section(m.occluders)
  section(m.water)
  section(m.glassSummary)
  section(m.glassData)
  section(m.grass)
  section(m.shell)
  section(m.signFaces) -- Lab 57 SIGNS: the mesher's sign faces (nil = the build had no prepared signs)
  w:u8(m.voxelTreeMode and 1 or 0)
  section(m.voxelTrees)
  w:u16(#m.parts)
  for _, p in ipairs(m.parts) do
    w:u32(p.stored); w:u32(p.raw); w:raw(p.md5)
  end
  return w:result()
end

-- -> meta table m. Verifies the trailer md5 and the key. Raises on any problem.
function PC:_decodeHeader(hdr, full, tick)
  if #hdr < 40 or #hdr > F.MAX_WRITE then F.fail("header size") end
  local body, sum = hdr:sub(1, -17), hdr:sub(-16)
  if love.data.hash("md5", body) ~= sum then F.fail("header md5") end
  local r = F.reader(body)
  if r:bytes(4) ~= F.MAGIC then F.fail("magic") end
  if r:u32() ~= F.VERSION then F.fail("version") end
  local m = {}
  m.full = r:str()
  if m.full ~= full then F.fail("key mismatch") end
  m.key = r:str(); m.w = r:u32(); m.h = r:u32()
  if m.w < 1 or m.h < 1 or m.w > F.MAX_DIM or m.h > F.MAX_DIM then F.fail("dimensions") end
  m.originX = r:d(); m.originY = r:d()
  local lv, sig, pair = r:str(), r:str(), r:str()
  m.mesher = r:str()
  m.tris = r:d()
  if not finite(m.originX) or not finite(m.originY) or not finite(m.tris) or m.tris < 0 then F.fail("scalars") end
  local flags = r:u8()
  m.aoOpaque, m.aoUnder, m.openAir, m.isBorder = flags % 2 >= 1, flags % 4 >= 2, flags % 8 >= 4, flags % 16 >= 8
  m.layoutVersion = (flags % 32 >= 16) and lv or nil
  m.sig = (flags % 64 >= 32) and sig or nil
  m.retro = flags % 128 >= 64
  m.pair = pair ~= "" and pair or nil
  local plan = r:str()
  m.maskPlan = plan ~= "" and plan or nil
  m.maskKind = r:u8()
  if m.maskKind > M_MOVING then F.fail("mask kind") end
  m.parts = {}
  -- parts table sits at the end; decode it first by scanning is not possible, so the
  -- blob refs are range-checked after the table is read (second pass below)
  local rawRefs = {}
  local function refsDeferred(stride)
    local n = r:u16()
    local refs = {}
    for i = 1, n do refs[i] = { part = r:u16(), off = r:u32(), len = r:u32() } end
    rawRefs[#rawRefs + 1] = { refs = refs, stride = stride }
    return refs
  end
  if m.maskKind ~= M_NONE then
    m.mw, m.mh = r:u32(), r:u32()
    if m.mw < 1 or m.mh < 1 or m.mw > 8 * F.MAX_DIM or m.mh > 8 * F.MAX_DIM then F.fail("mask size") end
    local refs = refsDeferred(nil)
    if #refs ~= 1 then F.fail("mask refs") end
    m.maskRef = refs[1]
    if m.maskKind == M_MOVING then
      m.fw, m.fh = r:u32(), r:u32()
      if m.fw < 1 or m.fh < 1 or m.fw > 8 * F.MAX_DIM or m.fh > 8 * F.MAX_DIM then F.fail("field size") end
      local frefs = refsDeferred(nil)
      if #frefs ~= 1 then F.fail("field refs") end
      m.fieldRef = frefs[1]
    end
  end
  m.alphaState = r:u8()
  if m.alphaState > 2 then F.fail("alpha state") end
  if m.alphaState == 2 then m.alphaHidden, m.alphaCapped = r:u32(), r:u32() end
  m.layers = {}
  local totalChunks = 0
  for _, layer in ipairs(ALL_LAYERS) do
    local n = r:u32()
    totalChunks = totalChunks + n
    if totalChunks > F.MAX_CHUNKS then F.fail("too many chunks") end
    local list = {}
    for i = 1, n do
      local c = {}
      c.nverts = r:u32(); c.tris = r:d()
      c.x0, c.y0, c.z0, c.x1, c.y1, c.z1 = r:d(), r:d(), r:d(), r:d(), r:d(), r:d()
      if c.nverts < 3 or c.nverts % 3 ~= 0 or c.nverts > F.MAX_VERTS then F.fail("chunk size") end
      if not (finite(c.tris) and finite(c.x0) and finite(c.y0) and finite(c.z0) and finite(c.x1) and finite(c.y1) and finite(c.z1)) then F.fail("chunk bounds") end
      if c.x0 > c.x1 or c.y0 > c.y1 or c.z0 > c.z1 then F.fail("chunk bounds order") end
      if layer ~= "shell" and c.tris ~= c.nverts / 3 then F.fail("chunk tris") end
      local cf = r:u8()
      if cf > 15 then F.fail("chunk flags") end
      c.main = refsDeferred(32)
      c.mainStride = 32
      if cf % 2 >= 1 then c.ao = refsDeferred(4) end
      if cf % 4 >= 2 then c.emit = refsDeferred(4) end
      if cf % 8 >= 4 then c.rg = r:value(tick) end
      if cf % 16 >= 8 then c.tree=refsDeferred(12) end
      if (layer == "shell") ~= (c.rg ~= nil) then F.fail("shell ranges") end
      list[i] = c
    end
    m.layers[layer] = list
  end
  m.heightsMode = r:u8()
  if m.heightsMode > 2 then F.fail("heights mode") end
  if m.heightsMode > 0 then m.heights = r:value(tick) end
  local function section()
    if r:u8() == 1 then return r:value(tick) end
    return nil
  end
  m.supportRamps = section()
  m.lightingData = section()
  m.shrubCards = section()
  if m.shrubCards~=nil then
    if type(m.shrubCards)~="table" or #m.shrubCards>65536 then F.fail("shrub cards") end
    for _,c in ipairs(m.shrubCards)do if type(c)~="table" or #c~=7 then F.fail("shrub descriptor")end;for i=1,7 do if type(c[i])~="number" or c[i]~=c[i] or math.abs(c[i])==math.huge then F.fail("shrub coordinate")end end;if c[4]<0 or c[5]<0 or c[6]>1 or c[7]>1 or c[4]>=c[6]or c[5]>=c[7]then F.fail("shrub UV")end end
  end
  if m.lightingData ~= nil and type(m.lightingData) ~= "table" then F.fail("lighting data") end
  m.occluders = section()
  m.water = section()
  m.glassSummary = section()
  m.glassData = section()
  m.grass = section()
  m.shell = section()
  m.signFaces = section()
  if m.signFaces ~= nil and type(m.signFaces) ~= "table" then F.fail("sign faces") end
  local voxelMode=r:u8();if voxelMode>1 then F.fail("voxel tree mode") end
  m.voxelTreeMode=voxelMode==1
  m.voxelTrees=section()
  if m.voxelTrees and not m.voxelTreeMode then F.fail("voxel data in sheet mode") end
  local np = r:u16()
  if np > F.MAX_PARTS then F.fail("too many parts") end
  for i = 1, np do
    m.parts[i] = { stored = r:u32(), raw = r:u32(), md5 = r:bytes(16) }
  end
  if r:left() ~= 0 then F.fail("trailing bytes") end
  -- range-check every blob ref against the parts table; check stream sizes
  for _, item in ipairs(rawRefs) do
    for _, ref in ipairs(item.refs) do
      local p = m.parts[ref.part]
      if not p or ref.off + ref.len > p.raw then F.fail("blob out of range") end
      if item.stride and ref.len % item.stride ~= 0 then F.fail("blob stride") end
    end
  end
  for _, layer in ipairs(ALL_LAYERS) do
    for _, c in ipairs(m.layers[layer]) do
      local function total(refs) local s = 0; for _, x in ipairs(refs) do s = s + x.len end; return s end
      if total(c.main) ~= c.nverts * 32 then F.fail("main stream size") end
      if c.ao and total(c.ao) ~= c.nverts * 4 then F.fail("ao stream size") end
      if c.emit and total(c.emit) ~= c.nverts * 4 then F.fail("emit stream size") end
      if c.tree and total(c.tree) ~= c.nverts * 12 then F.fail("tree stream size") end
    end
  end
  if m.maskKind ~= M_NONE and m.maskRef.len ~= m.mw * m.mh * 4 then F.fail("mask bytes") end
  if m.maskKind == M_MOVING and m.fieldRef.len ~= m.fw * m.fh * 16 then F.fail("field bytes") end
  if m.heightsMode > 0 and (type(m.heights) ~= "table" or #m.heights ~= m.w * m.h) then F.fail("heights size") end
  if m.supportRamps then PC.heightFunction(m.heights,m.w,m.h,m.supportRamps) end
  if m.voxelTrees then VoxelTreeCache.validateStored(m.voxelTrees,m.pair,m.parts,tick) end
  return m
end

-- ------------------------------------------------------------------ load
local function newImage(data)
  local img = love.graphics.newImage(data)
  img:setFilter("linear", "linear")
  pcall(img.setWrap, img, "clamp", "clamp")
  return img
end

-- Sequential part reader: one decompressed part held at a time.
function PC:_partReader(rk, m, host)
  local P = { cur = nil, bd = nil, count = 0 }
  local cache, selfPC = self.cache, self
  function P:close()
    if self.bd and self.bd.release then pcall(self.bd.release, self.bd) end
    self.bd, self.cur = nil, nil
  end
  function P:load(i)
    self:close()
    local pm = m.parts[i]
    local ok, s = pcall(cache.read, cache, Store.DIR .. rk .. ".p" .. i)
    if not ok or type(s) ~= "string" then F.fail("part " .. i .. " missing") end
    if #s ~= pm.stored then F.fail("part " .. i .. " size") end
    selfPC.stats.bytesRead = selfPC.stats.bytesRead + #s
    host.yield()
    if love.data.hash("md5", s) ~= pm.md5 then F.fail("part " .. i .. " md5") end
    host.yield()
    local bd = love.data.decompress("data", "lz4", s)
    if not bd or bd:getSize() ~= pm.raw then F.fail("part " .. i .. " raw size") end
    host.yield()
    self.bd, self.cur = bd, i
    self.count = self.count + 1
  end
  function P:view(ref)
    if self.cur ~= ref.part then self:load(ref.part) end
    return love.data.newDataView(self.bd, ref.off, ref.len)
  end
  return P
end

local function fillMesh(P, mesh, refs, stride, host)
  local first = 1
  for _, ref in ipairs(refs) do
    local count = ref.len / stride
    mesh:setVertices(P:view(ref), first, count)
    first = first + count
    host.yield()
  end
end

-- The sun-facing mask's "want" function for border rings, like Scene:_mask.
local function wantFor(input)
  if not input.isBorder then return nil end
  local cellAt = input.cellAt
  return function(cx, cz) return cellAt(cx, cz) ~= nil end
end

function PC:_load(scene, rk, full, input, plan, host, hdr)
  local m = self:_decodeHeader(hdr, full, host.yield)
  host.nparts = #m.parts
  host.yield()
  local atlas = input.atlas
  if not (atlas and atlas.image) then F.fail("no atlas") end
  if m.w ~= input.width or m.h ~= input.height or m.pair ~= input.pair
      or (m.isBorder or false) ~= (input.isBorder or false) then F.fail("input shape") end
  if m.mesher ~= "FrlgMesher" then F.fail("mesher") end
  if m.voxelTreeMode~=(host.voxelTreeMode==true) then F.fail("tree mode mismatch") end
  if scene.retroGrass and not m.retro then F.fail("no grass cells") end
  local rec = {
    key = m.key, pair = m.pair, w = m.w, h = m.h, originX = m.originX, originY = m.originY,
    layoutVersion = m.layoutVersion, mesher = m.mesher, sig = m.sig, isBorder = m.isBorder or nil,
  }
  host.partial = rec
  if scene.retroGrass then
    scene.inflight[rec] = true
    rec.buildOwner = scene
    rec.buildCoroutine = coroutine.running()
  end
  rec.aoOpaque, rec.aoUnder = m.aoOpaque, m.aoUnder
  rec.healerFR = nil
  local P = self:_partReader(rk, m, host)
  host.P = P
  local images = { opaque = atlas.image, under = atlas.image, over = atlas.overImage or atlas.image,
    keyed = atlas.image, shell = atlas.image }
  for _, layer in ipairs(ALL_LAYERS) do
    local descs = m.layers[layer]
    if layer ~= "shell" or #descs > 0 then
      local out = {}
      rec[layer] = out
      for _, c in ipairs(descs) do
        local mesh = love.graphics.newMesh(Shaders.FORMAT, c.nverts, "triangles", "static")
        local ch = { mesh = mesh, tris = c.tris, x0 = c.x0, y0 = c.y0, z0 = c.z0, x1 = c.x1, y1 = c.y1, z1 = c.z1 }
        if layer == "shell" then
          ch.nverts, ch.rg, ch.vr, ch.nvr = c.nverts, c.rg, {}, 0
          ch.tris = c.nverts / 3
        end
        out[#out + 1] = ch
        fillMesh(P, mesh, c.main, 32, host)
        mesh:setTexture(images[layer])
        if c.ao then
          local am = love.graphics.newMesh(PC.AO_FORMAT, c.nverts, "triangles", "static")
          ch.aoMesh = am
          fillMesh(P, am, c.ao, 4, host)
          mesh:attachAttribute("VertexAO", am)
        end
        if c.emit then
          local em = love.graphics.newMesh(PC.EMIT_FORMAT, c.nverts, "triangles", "static")
          ch.emitMesh = em
          fillMesh(P, em, c.emit, 4, host)
          mesh:attachAttribute("VertexEmit", em)
        end
        if c.tree then
          assert(V.require("render/FrlgTreeView").shader(Shaders),"tree shader unavailable")
          local tm=love.graphics.newMesh(PC.TREE_FORMAT,c.nverts,"triangles","static")
          ch.treeMesh=tm
          fillMesh(P,tm,c.tree,12,host)
          mesh:attachAttribute("VertexTree",tm)
        end
      end
    end
  end
  if m.shell then
    local sh = m.shell
    rec.openAir = m.openAir or nil
    rec.shellTris = sh.tris
    rec.shellInfo = { groups = sh.groups, ceilY = sh.ceilY, W = sh.W, H = sh.H, openAir = sh.openAir, vis = {} }
  else
    rec.openAir = m.openAir or nil
  end
  rec.tris = floor(m.tris)
  V.require("render/FrShrubView").upload(rec,m.shrubCards,V.require("render/Shaders"))
  if m.lightingData then
    if not scene.lighting then F.fail("lighting runtime unavailable") end
    rec.lightRecord = scene.lighting:restore(m.lightingData, function(r) rec.lightRecord = r end)
  end
  if not m.isBorder then
    if m.heightsMode == 1 then
      local hs, w, h = m.heights, m.w, m.h
      rec.heightFn = PC.heightFunction(hs,w,h,m.supportRamps)
      rec.supportRamps = m.supportRamps
    elseif m.heightsMode == 2 then
      local hs, heights = m.heights, {}
      for i = 1, m.w * m.h do
        local v = hs[i]
        if v == v then heights[i] = v end
      end
      rec.heights = heights
    end
    if m.occluders then rec.occluders = m.occluders end
  end
  if m.water then rec.water = m.water end
  rec.meshMs = 0
  rec.shadowMs = 0
  if m.maskPlan then rec.maskPlan = m.maskPlan end
  host.yield()
  -- masks
  local kind = m.maskKind
  if kind == M_POOLS then
    local data = love.image.newImageData(m.mw, m.mh, "rgba8", P:view(m.maskRef))
    rec.poolsOnly = newImage(data)
    data:release()
    rec.shadowXf = { 1 / m.w, 1 / m.h, 0, 0 }
  elseif kind ~= M_NONE then
    local data = love.image.newImageData(m.mw, m.mh, "rgba8", P:view(m.maskRef))
    host.yield()
    if kind == M_CONTACT then
      rec.shadowKind = "contact"
    else
      rec.shadowKind = "sun"
      rec.solarWant = wantFor(input)
      if kind == M_FIXED then
        rec.solarBucket = Solar.FIXED.bucket
      else
        rec.solarFieldAttempted = true
        local bytes = m.w * m.h * Light.RES * Light.RES * 16
        local retain = Solar.reserve(scene, rec, bytes)
        if bytes <= retain then
          if m.fw ~= m.w * Light.RES or m.fh ~= m.h * Light.RES then F.fail("field shape") end
          rec.solarField = love.image.newImageData(m.fw, m.fh, "rgba32f", P:view(m.fieldRef))
        end
      end
    end
    rec.shadowRes = Light.RES
    rec.shadow = newImage(data)
    rec.shadowData = data
    rec.shadowXf = { 1 / m.w, 1 / m.h, 0, 0 }
  end
  if m.alphaState == 1 then rec.shadowAlpha = false
  elseif m.alphaState == 2 then rec.shadowAlpha = { hidden = m.alphaHidden, capped = m.alphaCapped } end
  host.yield()
  -- tall grass and the glass emissive masks: the same calls, in the same order, as a live build
  if m.glassSummary then rec.glass = m.glassSummary end
  if scene.retroGrass then
    local g = m.grass
    local cells = {}
    local xs, ki, kinds = g.xs, g.ki, g.kinds
    for i = 1, #ki do
      cells[i] = { x = xs[3 * i - 2], z = xs[3 * i - 1], y = xs[3 * i], kind = kinds[ki[i]] }
    end
    local tGrass = self.clock()
    scene.retroGrass:build(rec, cells, host.yield)
    rec.retroGrassCells = cells
    rec.baseTris = rec.tris
    rec.grassTris = 0
    for _, ch in ipairs(rec.retroChunks or {}) do rec.grassTris = rec.grassTris + ch.tris end
    rec.tris = rec.baseTris + rec.grassTris
    rec.grassBuildMs = (self.clock() - tGrass) * 1000
  end
  local gd = m.glassData
  if gd and scene.emissive then
    if gd.underW and gd.under and #gd.under > 0 then scene.emissive:addGlass(input.pair, "under", gd.underW, gd.underH, gd.under) end
    if gd.overW and gd.over and #gd.over > 0 then scene.emissive:addGlass(input.pair, "over", gd.overW, gd.overH, gd.over) end
  end
  if m.voxelTrees then
    if not scene.voxelTrees then F.fail("voxel tree renderer unavailable") end
    local trees=VoxelTreeCache.restore(m.voxelTrees,input.pair,m.parts,function(ref)
      local view=P:view(ref)
      local ok,bytes=pcall(view.getString,view)
      view:release() -- the temporary view must not retain its decompressed part
      if not ok then error(bytes,0) end
      return bytes
    end,host.yield)
    rec.tris=rec.tris+scene.voxelTrees:build(rec,trees)
    host.yield()
  end
  P:close()
  host.P=nil
  -- Lab 57 SIGNS, the LAST step (nothing after it can fail): Scene prepared this build's sign textures before the
  -- mesher; the record carries the faces the mesher emitted, so the textured quads are rebuilt exactly as a live
  -- build does (SignRuntime.upload releases a prepared texture without a face). The sign key digest makes
  -- "prepared" and "record has sign faces" agree; a mismatch is a bad record.
  local signed = m.signFaces ~= nil
  if (host.signState ~= nil) ~= signed then F.fail("sign state does not match the record") end
  if signed then
    if type(host.signUpload) ~= "function" then F.fail("no sign runtime") end
    host.signConsumed = true
    local okU, why = host.signUpload(host.signState, m.signFaces, Shaders.FORMAT)
    if not okU then
      if type(host.signRelease) == "function" then pcall(host.signRelease, host.signState) end
      F.fail("sign upload: " .. tostring(why))
    end
    rec.signRuntime = host.signState
  end
  host.partial = nil
  return rec, m
end

-- Try to satisfy a build from the cache. -> rec | nil, why ("miss" / a corrupt reason)
-- host = { yield = fn, releaseRecord = fn, now = fn }; may yield through host.yield.
function PC:tryLoad(scene, rk, full, input, plan, host)
  local st = self.stats
  local t0 = self.clock()
  local okR, hdr = pcall(self.cache.read, self.cache, Store.DIR .. rk .. ".h")
  if not okR or type(hdr) ~= "string" then
    st.miss = st.miss + 1
    st.missMs = st.missMs + (self.clock() - t0) * 1000
    self:_say("miss %s %s", tostring(input.mapId or input.isBorder and "ring" or "?"), rk:sub(1, 8))
    self:_event()
    return nil, "miss"
  end
  st.bytesRead = st.bytesRead + #hdr
  host.yield()
  host.partial, host.P, host.nparts = nil, nil, nil
  local ok, rec, m = pcall(self._load, self, scene, rk, full, input, plan, host, hdr)
  if ok and rec then
    local ms = (self.clock() - t0) * 1000
    st.hit = st.hit + 1
    st.hitMs = st.hitMs + ms
    if ms > st.hitMsMax then st.hitMsMax = ms end
    local entry = self.store:has(rk)
    if entry then self.store:touch(rk)
    else
      local bytes = #hdr
      for _, p in ipairs(m.parts) do bytes = bytes + p.stored end
      self.store:add(rk, bytes, #m.parts, self.gen)
    end
    rec.cacheHit = true
    rec.cacheRk = rk -- Lab 59: FrPrepare's manifest names the record a hit satisfied
    rec.cacheMs = ms
    self:_say("hit %s %s parts=%d tris=%d ms=%.1f", tostring(rec.key), rk:sub(1, 8), #m.parts, rec.tris or 0, ms)
    self:_event()
    return rec
  end
  -- bad record: release whatever was made, forget it, let the live build run
  if host.P then pcall(host.P.close, host.P); host.P = nil end
  if host.partial then pcall(host.releaseRecord, host.partial); host.partial = nil end
  local why = ok and "load failed" or rec
  st.corrupt = st.corrupt + 1
  local e = self.store:remove(rk)
  self.store:queueDelete(rk, (e and e.parts) or host.nparts or 0)
  self:_say("corrupt %s %s: %s", tostring(input.mapId or "?"), rk:sub(1, 8), tostring(why))
  self:_event()
  return nil, "corrupt: " .. tostring(why)
end

-- ------------------------------------------------------------------ capture
-- A record waits here after a clean live build; `info` (rec.pcInfo) carries what the
-- record itself no longer holds: mask / pools bytes, glass lists, key, settings.
local function pendingBytes(info)
  local n = info.maskBytes and #info.maskBytes or 0
  local g = info.glassData
  if g then n = n + 8 * ((g.under and #g.under or 0) + (g.over and #g.over or 0)) end
  -- Foreground stamps can be shared, but CPU-worker restores own fresh arrays.
  -- Conservatively budget both; one oversized bounded record may run alone.
  if info.voxelTrees then
    n=n+#info.voxelTrees.trees*128
    for _,stamp in pairs(info.voxelTrees.stamps) do
      n=n+(#stamp.under+#stamp.over)*256
    end
  end
  return n
end

-- Records wait here, each holding its mask bytes and glass lists (Lua heap!). The queue is bounded by count
-- and by bytes (MAX_PENDING_BYTES): the oldest waiting record is dropped first, counted as `dropped`.
function PC:submit(scene, rec)
  local info = rec.pcInfo
  if not info then return end
  info.pendBytes = pendingBytes(info)
  local function total()
    local n = 0
    for _, it in ipairs(self.pending) do n = n + (it.rec.pcInfo and it.rec.pcInfo.pendBytes or 0) end
    return n
  end
  while #self.pending > 0 and (#self.pending >= PC.MAX_PENDING or total() + info.pendBytes > PC.MAX_PENDING_BYTES) do
    local old = table.remove(self.pending, 1)
    if old.rec then old.rec.pcInfo = nil end
    self.stats.dropped = self.stats.dropped + 1
  end
  self.pending[#self.pending + 1] = { rec = rec, scene = scene }
end

function PC:dropPending()
  for _, it in ipairs(self.pending) do if it.rec then it.rec.pcInfo = nil end end
  self.pending = {}
  if self.co then
    self:_abortCapture("switched off")
  end
end

-- Inside the capture coroutine ------------------------------------------------
function PC:_tick()
  if self.clock() >= self._stop then coroutine.yield() end
end

-- One bounded worker write at a time; yield until its acknowledgement.
function PC:_write(rel, data)
  if #data > F.MAX_WRITE then F.fail("write too large") end
  local c = self.cur
  if not c.io then
    local io, why = CacheIO.new(self.mod, c.rk, self.clock)
    if not io then F.fail("write failed: " .. tostring(why)) end
    c.io = io
  end
  local bytes = #data
  local ok, id = pcall(c.io.submit, c.io, rel, data)
  data = nil -- Channel owns the sole queued payload while the UI keeps pumping.
  if not ok then F.fail("write failed: " .. tostring(id)) end
  repeat
    coroutine.yield()
    local why = c.io:poll()
    if why then F.fail("write failed: " .. tostring(why)) end
    if c.io.terminal and not c.io.ack then F.fail("write failed: worker stopped") end
  until c.io.ack and c.io.ack.id == id
  local wms = c.io.ack.ms or 0
  if wms > (self.stats.writeMsMax or 0) then self.stats.writeMsMax = wms end
  if wms > (c.writeMsMax or 0) then c.writeMsMax = wms end
  self.stats.bytesWritten = self.stats.bytesWritten + bytes
  c.written[#c.written + 1] = rel
  self:_tick()
end
function PC:_flushPart()
  local c = self.cur
  if c.rawLen == 0 then return end
  local raw = table.concat(c.raw)
  c.raw, c.rawLen = {}, 0
  local stored = love.data.compress("string", "lz4", raw)
  self:_tick()
  local idx = #c.parts + 1
  c.parts[idx] = { stored = #stored, raw = #raw, md5 = love.data.hash("md5", stored) }
  self:_write(Store.DIR .. c.rk .. ".p" .. idx, stored)
end

function PC:_addBlob(raw)
  local c = self.cur
  local target = self.store.bulk and PC.BULK_PART_TARGET or F.PART_TARGET
  if c.rawLen > 0 and c.rawLen + #raw > target then self:_flushPart() end
  local ref = { part = #c.parts + 1, off = c.rawLen, len = #raw }
  c.raw[#c.raw + 1] = raw
  c.rawLen = c.rawLen + #raw
  return ref
end

-- Vertices of a mesh as stored segments (<= SEG_VERTS each), read back in PACK_VERTS blocks.
function PC:_streamRefs(mesh, nverts, ncomp)
  local refs = {}
  local seg = F.SEG_VERTS
  local first = 1
  while first <= nverts do
    local last = math.min(nverts, first + seg - 1)
    local pieces = {}
    local i = first
    while i <= last do
      local j = math.min(last, i + PC.PACK_VERTS - 1)
      pieces[#pieces + 1] = F.packMesh(mesh, i, j, ncomp)
      i = j + 1
      self:_tick()
    end
    refs[#refs + 1] = self:_addBlob(table.concat(pieces))
    first = last + 1
  end
  return refs
end

-- Build meta from the record + its pcInfo, writing every data part. Raises on any problem.
function PC:_captureBody(item)
  local rec, scene = item.rec, item.scene
  local info = rec.pcInfo
  local c = self.cur
  local m = { full = info.full, key = rec.key, w = rec.w, h = rec.h, originX = rec.originX or 0, originY = rec.originY or 0,
    layoutVersion = rec.layoutVersion, sig = rec.sig, pair = rec.pair, mesher = rec.mesher,
    tris = rec.baseTris or (rec.tris-(info.voxelTreeTris or 0)), aoOpaque = rec.aoOpaque, aoUnder = rec.aoUnder, openAir = rec.openAir,
    isBorder = rec.isBorder, maskPlan = info.maskPlan, layers = {}, retro = info.retro, voxelTreeMode=info.voxelTreeMode==true }
  -- masks
  m.maskKind = M_NONE
  if info.maskBytes then
    m.maskKind = info.maskKind
    m.mw, m.mh = info.maskW, info.maskH
    m.maskRef = self:_addBlob(info.maskBytes)
    if m.maskKind == M_MOVING then
      local field = rec.solarField
      if not field then F.fail("no height field") end
      m.fw, m.fh = field:getDimensions()
      m.fieldRef = self:_addBlob(field:getString())
    end
    self:_tick()
  end
  if info.alphaState then
    m.alphaState = info.alphaState
    m.alphaHidden, m.alphaCapped = info.alphaHidden, info.alphaCapped
  else
    m.alphaState = 0
  end
  -- chunk streams
  for _, layer in ipairs(ALL_LAYERS) do
    local list = rec[layer]
    local out = {}
    if list then
      for i, ch in ipairs(list) do
        if not ch.mesh then F.fail("chunk without mesh") end
        local nverts = layer == "shell" and ch.nverts or floor(ch.tris * 3 + 0.5)
        if ch.mesh:getVertexCount() ~= nverts then F.fail("vertex count mismatch") end
        local d = { nverts = nverts, tris = layer == "shell" and (nverts / 3) or ch.tris,
          x0 = ch.x0, y0 = ch.y0, z0 = ch.z0, x1 = ch.x1, y1 = ch.y1, z1 = ch.z1 }
        d.main = self:_streamRefs(ch.mesh, nverts, 8)
        if ch.aoMesh then d.ao = self:_streamRefs(ch.aoMesh, nverts, 1) end
        if ch.emitMesh then d.emit = self:_streamRefs(ch.emitMesh, nverts, 1) end
        if ch.treeMesh then d.tree=self:_streamRefs(ch.treeMesh,nverts,3) end
        if layer == "shell" then d.rg = ch.rg end
        out[i] = d
      end
    end
    m.layers[layer] = out
  end
  -- plain-data sections
  if not rec.isBorder then
    if rec.heightFn then
      local hs, w, h = {}, rec.w, rec.h
      for cy = 0, h - 1 do
        for cx = 0, w - 1 do
          local ok, v = pcall(rec.heightFn, cx, cy)
          if ok and type(v) == "number" then hs[cy * w + cx + 1] = v else hs[cy * w + cx + 1] = NaN end
        end
        self:_tick()
      end
      m.heightsMode, m.heights = 1, hs
    elseif rec.heights then
      local hs = {}
      for i = 1, rec.w * rec.h do
        local v = rec.heights[i]
        hs[i] = type(v) == "number" and v or NaN
      end
      m.heightsMode, m.heights = 2, hs
    end
    m.supportRamps = rec.supportRamps
    local occ = rec.occluders
    if occ then
      local st = { nodes = 0 }
      m.occluders = {
        trees = occ.trees and F.project(occ.trees, 2, st) or nil,
        buildings = occ.buildings and F.project(occ.buildings, 3, st) or nil,
        blocks = occ.blocks and F.project(occ.blocks, 3, st) or nil,
      }
    end
  end
  m.water = rec.water
  m.shrubCards=rec.shrubCards
  m.lightingData = LightingRuntime.serialize(rec.lightRecord)
  m.glassSummary = rec.glass
  m.glassData = info.glassData
  if rec.retroGrassCells then
    local cells = rec.retroGrassCells
    local xs, ki, kinds, kindIdx = {}, {}, {}, {}
    for i, cell in ipairs(cells) do
      local n = 0
      for _ in pairs(cell) do n = n + 1 end
      if n ~= 4 or type(cell.x) ~= "number" or type(cell.z) ~= "number" or type(cell.y) ~= "number" or type(cell.kind) ~= "string" then
        F.fail("grass cell schema")
      end
      xs[3 * i - 2], xs[3 * i - 1], xs[3 * i] = cell.x, cell.z, cell.y
      local k = kindIdx[cell.kind]
      if not k then k = #kinds + 1; kinds[k] = cell.kind; kindIdx[cell.kind] = k end
      ki[i] = k
      if i % 256 == 0 then self:_tick() end
    end
    m.grass = { xs = xs, ki = ki, kinds = kinds }
  end
  if info.signFaces ~= nil then m.signFaces = info.signFaces end
  if info.voxelTrees then
    if not m.voxelTreeMode then F.fail("voxel data in sheet capture") end
    m.voxelTrees=VoxelTreeCache.capture(info.voxelTrees,rec.pair,function(bytes)
      return self:_addBlob(bytes)
    end,function()self:_tick()end)
  end
  if rec.shell then
    local si = rec.shellInfo
    if not si then F.fail("shell without info") end
    m.shell = { tris = rec.shellTris, groups = F.project(si.groups or {}, 2), ceilY = si.ceilY, W = si.W, H = si.H, openAir = si.openAir }
  end
  self:_flushPart()
  m.parts = c.parts
  local header = self:_encodeHeader(m, function() self:_tick() end)
  header = header .. love.data.hash("md5", header)
  -- verify the header decodes before it can ever be read as a record
  self:_decodeHeader(header, info.full, function() self:_tick() end)
  self:_write(Store.DIR .. c.rk .. ".h", header)
  local bytes = #header
  for _, p in ipairs(c.parts) do bytes = bytes + p.stored end
  return bytes, #c.parts
end

function PC:_abortCapture(why)
  local c = self.cur
  if c then
    if c.io then c.io:cancel()
    else for _, rel in ipairs(c.written) do self.store.pendingDelete[#self.store.pendingDelete + 1] = rel end end
  end
  local item = self.item
  if item and item.rec then item.rec.pcInfo = nil end
  self.co, self.cur, self.item = nil, nil, nil
end

function PC:_finishCapture(bytes, nparts)
  local c, item = self.cur, self.item
  if c.io then c.io:commit() end
  local st = self.stats
  local ms = (self.clock() - c.t0) * 1000
  st.saved = st.saved + 1
  st.saveMs = st.saveMs + ms
  if ms > st.saveMsMax then st.saveMsMax = ms end
  st.parts = st.parts + nparts
  self.failStreak = 0
  self.store:add(c.rk, bytes, nparts, self.gen)
  self:_say("write %s %s bytes=%d parts=%d frames=%d ms=%.1f slowestWriteCall=%.1f", tostring(item.rec.key), c.rk:sub(1, 8), bytes, nparts, c.frames, ms, c.writeMsMax or 0)
  local n = self.store:evict(self.capBytes, self.gen)
  if n > 0 then st.evicted = st.evicted + n; self:_say("evict %d records, cache now %.1f MB", n, self.store.total / 1048576) end
  item.rec.pcInfo = nil
  self.co, self.cur, self.item = nil, nil, nil
  self:_say("summary %s", self:summary())
end

local function stillPlaced(scene, rec)
  return scene.cache[rec.key] == rec or scene.borders[rec.key] == rec
end

-- Called once per frame from Scene:pump, only when no build job runs. `stop` = clock time the frame's
-- build budget ends.
function PC:pump(scene, stop)
  local ioAvailable = CacheIO.available()
  if not self:enabled() then
    if #self.pending > 0 or self.co then self:dropPending() end
    -- deletes already promised (CLEAR, eviction, a corrupt record) still complete while the cache is OFF
    if self.usable and #self.store.pendingDelete > 0 then self.store:pumpDelete(4) end
    return
  end
  local st = self.store
  local t = self.clock()
  if t >= stop - PC.FLUSH_MIN_MS / 1000 then return end
  st:pumpDelete(4)
  -- Lab 59: FrPrepare's second Scene shares this object. Each Scene's pump serves only its own records: a capture
  -- that belongs to the other Scene is neither continued nor dropped here (a paused precache keeps its place).
  if self.co and self.item and self.item.scene ~= scene then return end
  if not self.co then
    if not ioAvailable then return end
    local item
    local i = 1
    while i <= #self.pending do
      local it = self.pending[i]
      if it.scene ~= scene then
        i = i + 1
      else
        table.remove(self.pending, i)
        local rec = it.rec
        if rec and rec.pcInfo and rec.opaque and stillPlaced(scene, rec) then item = it; break end
        if rec then rec.pcInfo = nil end
        if rec then self.stats.dropped = self.stats.dropped + 1 end
      end
    end
    if not item then
      st:flush(false)
      return
    end
    local info = item.rec.pcInfo
    self.item = item
    st:cancelDeletes(info.rk) -- an old delete for this key must not remove the files about to be written
    self.cur = { rk = info.rk, raw = {}, rawLen = 0, parts = {}, written = {}, t0 = t, frames = 0 }
    self.co = coroutine.create(function() return self:_captureBody(item) end)
  end
  local c = self.cur
  c.frames = c.frames + 1
  self._stop = math.min(stop, t + PC.CAPTURE_MS / 1000)
  local rec = self.item.rec
  if not rec.opaque or not stillPlaced(scene, rec) then
    self:_abortCapture("record gone")
    self.stats.dropped = self.stats.dropped + 1
    return
  end
  local ok, a, b = coroutine.resume(self.co)
  if not ok then
    local why = tostring(a)
    self.stats.saveFailed = self.stats.saveFailed + 1
    self:_say("write failed %s: %s", tostring(rec.key), why)
    if why:find("write failed", 1, true) then
      self.failStreak = self.failStreak + 1
      if self.failStreak >= PC.MAX_FAIL then
        self.disabled = "writes failing"
        self:_say("DISABLED: %s", self.disabled)
      end
    end
    self:_abortCapture(why)
    return
  end
  if coroutine.status(self.co) == "dead" then
    self:_finishCapture(a, b)
  end
end

-- Called when a map is released or the scene is torn down: forget captures that point at it.
function PC:forget(rec)
  if not rec then return end
  rec.pcInfo = nil
  for i = #self.pending, 1, -1 do
    if self.pending[i].rec == rec then table.remove(self.pending, i) end
  end
  if self.item and self.item.rec == rec then self:_abortCapture("released") end
end

function PC:flush()
  if self.ready then self.store:flush(true) end
end

-- Lab 59 PRECACHE ON FIRST LOAD (lib/perf/FrPrepare.lua) ------------------------------------------------
-- A capture is queued or running (a record is waiting for its idle-frame write).
-- scene (optional): only that Scene's records count.
function PC:busy(scene)
  if scene == nil then return self.co ~= nil or #self.pending > 0 end
  if self.co and self.item and self.item.scene == scene then return true end
  for _, it in ipairs(self.pending) do if it.scene == scene then return true end end
  return false
end

-- Forget one Scene's waiting and running captures (skip / switch off); the other Scene's are left alone.
-- The worker cleans unfinished captures after any in-flight write has returned.
function PC:dropFor(scene)
  for i = #self.pending, 1, -1 do
    local it = self.pending[i]
    if it.scene == scene then
      if it.rec then it.rec.pcInfo = nil end
      table.remove(self.pending, i)
    end
  end
  if self.co and self.item and self.item.scene == scene then self:_abortCapture("dropped") end
end

-- Bulk mode: the index is written by the caller at its own checkpoints (Store:flush(true)) instead of
-- after every record, and the cap may be raised (setCap) for the duration of the precache.
function PC:setBulk(on)
  self.store.bulk = on == true
end

function PC:setCap(bytes)
  if type(bytes) == "number" and bytes > 0 then self.capBytes = bytes end
  return self.capBytes
end

-- OPTION > WORLD CACHE > CLEAR
function PC:clear()
  if not self.usable then return 0 end -- Lab 57 test fix: no mod.cache -> nothing to clear (was an index-a-nil-field error)
  self:dropPending()
  if not self.ready then
    pcall(function() self:ensureReady(nil) end)
  end
  local n = self.store:clearAll()
  self:_say("cleared %d records", n)
  return n
end

function PC:info()
  local i = self.store:info()
  return { records = i.records, bytes = i.bytes, mb = i.bytes / 1048576, capMb = self.capBytes / 1048576 }
end

return PC
