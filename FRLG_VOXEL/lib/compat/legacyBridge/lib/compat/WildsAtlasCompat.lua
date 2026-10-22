-- WildsAtlasCompat (Lab 58, P0): stop the Wilds sprite-atlas shard thrash without touching wilds_of_hoenn.
--
-- The problem (design section 1.4): lib/sprite_atlas.lua of wilds_of_hoenn decodes a ~6 MB shard PNG (20-73 ms
-- on the desktop) every time a species sheet (~40-100 KB) or its opaque-bottom support is asked for and the shard
-- is not one of the two decoded shards it keeps (Config.ATLAS_MAX_SHARDS = 2). With 8 species on screen the two
-- slots thrash and the same shards are decoded again and again.
--
-- What Wilds exposes: nothing that reaches the atlas module (exports carry spawnManager, atlasStats, ...; the
-- module tables live in a private V.require cache, and we may not use package.loaded or debug). So the hook is
-- placed on the only two places the atlas code touches that we can legally reach at runtime:
--   1. love.image.newImageData(<shard png path>) is the decode. For a shard file of the Wilds atlas folder we
--      return a cheap 1x1 SENTINEL ImageData instead of decoding 6 MB.
--   2. ImageData:paste(sentinel, dx, dy, sx, sy, sw, sh) (what SpriteAtlas.image does to slice a sheet) and
--      ImageData:getPixel on a sentinel (what SpriteAtlas.opaqueBottom does) are answered from a small LRU of
--      sheet-sized CROPS (ImageData of the requested rectangle). A crop miss decodes the shard once (kept in a
--      one-slot memo for a short while, so the next crop of the same shard is free), copies the rectangle out and
--      drops the shard again. Nothing else about the atlas changes: the pixels of every image and every support
--      row are identical to the unhooked loader (tests/a/wilds_atlas_love.lua proves this over a scripted
--      request sequence).
-- Both methods are patched on the shared ImageData method table (a lookup in a weak table per call for every
-- other ImageData; a sentinel is the only thing that takes the new branch). Everything is restored by uninstall().
--
-- Lab 60 (item 3): the decode itself can leave the main thread. With the "compute" permission (love.thread) the warm
-- jobs of ApproachLoader hand {shard, rectangles} to ONE worker thread (compat/WildsAtlasWorker.lua) that decodes the
-- shard once, cuts every requested rectangle into its own ImageData and sends them back; update() collects them and
-- registers them exactly like makeCrop does. A sprite drawn before its crop is ready (the demand path) still decodes
-- synchronously, so behaviour is never worse than Lab 58. Without love.thread (no permission, or no thread support) or
-- after a thread error everything below stays on the synchronous path; that is detected at runtime and never raises.
--
-- Memory: crops are capped at MAX_CROP_BYTES (default 8 MiB, about 100 sheets). The synchronous decode keeps at most
-- MEMO_SLOTS decoded shards (Lab 60: 2, one walk shard and one idle shard, because a species needs one of each and
-- they live in different shard families; <= MEMO_MAX_BYTES, 14 MiB, with 6 MB per shard) for MEMO_TTL seconds after
-- their last use. The worker holds one shard (<= ~6 MB) while it cuts and drops it at once. The Wilds LRUs stay
-- exactly as they were.
--
-- Gate: WildsAtlasCompat.ENABLED (default true). install() is only ever called from VRITK_FRLG_HOST, so with the
-- mod absent nothing of this exists. No package.loaded, no debug, no edit under mods/wilds_of_hoenn.
local M = {}

M.ENABLED = true
M.MAX_CROP_BYTES = 8 * 1024 * 1024
M.MEMO_TTL = 1.5          -- seconds a decoded shard stays in the memo after its last use
M.MEMO_SLOTS = 2          -- decoded shards kept by the synchronous path (Lab 58: 1)
M.MEMO_MAX_BYTES = 14 * 1024 * 1024
M.TILE = 128              -- getPixel misses crop an aligned TILE x TILE tile of the shard
M.WILDS_VERSION = "1.5.0" -- legacy public pin
M.SUPPORTED_VERSIONS = { ["1.5.0"] = true, ["1.7.1"] = true, ["1.10.1"] = true }
M.WORKER = true           -- Lab 60: decode warm jobs on a love.thread worker when the thread API is reachable
M.WORKER_IDLE_S = 4       -- the worker exits after this long without work (restarted on demand)
M.WORKER_TIMEOUT_S = 30   -- an in-flight request older than this is treated as a hung worker
M.WORKER_MAX_FAILS = 3    -- consecutive failed requests before the worker is switched off for good
M.MAX_RESULTS_PER_UPDATE = 8 -- crops registered per update() call (bounds the main-thread cost of a burst)

local S -- state while installed
local installSerial = 0
-- the originals outlive uninstall(): a third party that wrapped our hook must still reach the real functions
local RAW_NEW, ORIG_PASTE, ORIG_GETPIXEL

local function now()
  if love and love.timer and love.timer.getTime then return love.timer.getTime() end
  return os.clock()
end

local function emptyStats()
  return {
    decodes = 0, decodeMs = 0, decodeMaxMs = 0, uniqueShards = 0,
    cropHits = 0, cropMisses = 0, cropEvicted = 0, tileMisses = 0,
    sentinels = 0, pixelCalls = 0, fallbacks = 0, errors = 0,
    -- Lab 60 worker counters (all 0 on the synchronous path)
    workerJobs = 0, workerCrops = 0, workerDecodes = 0, workerDecodeMs = 0, workerDecodeMaxMs = 0,
    workerErrors = 0, workerDup = 0, workerCancelled = 0, workerRestarts = 0, demandWhilePending = 0,
    memoHits = 0,
  }
end

-- ------------------------------------------------------------ shard decode + memo
local function releaseData(d)
  if d and d.release then pcall(d.release, d) end
end

-- S.memo is an array of up to MEMO_SLOTS entries { file, data, last, w, h, bytes }; no table is made per lookup.
local function memoFind(file)
  local memo = S.memo
  for i = 1, #memo do
    local m = memo[i]
    if m.file == file then return m, i end
  end
  return nil
end

local function memoRemove(i)
  local m = table.remove(S.memo, i)
  if m then releaseData(m.data) end
end

local function dropMemo()
  local memo = S.memo
  for i = #memo, 1, -1 do releaseData(memo[i].data); memo[i] = nil end
end

local function memoBytes()
  local n, memo = 0, S.memo
  for i = 1, #memo do n = n + memo[i].bytes end
  return n
end

-- the real PNG decode (the cost this module exists to avoid repeating)
local function decodeShard(file)
  local t = now()
  local hit = memoFind(file)
  if hit then hit.last = t; S.st.memoHits = S.st.memoHits + 1; return hit.data end
  local t0 = now()
  local ok, data = pcall(RAW_NEW, file)
  local ms = (now() - t0) * 1000
  if not ok or not data then S.st.errors = S.st.errors + 1; return nil end
  local st = S.st
  st.decodes = st.decodes + 1
  st.decodeMs = st.decodeMs + ms
  if ms > st.decodeMaxMs then st.decodeMaxMs = ms end
  if not S.seenShard[file] then S.seenShard[file] = true; st.uniqueShards = st.uniqueShards + 1 end
  S.lastDecodeMs = ms
  local okW, w, h = pcall(data.getDimensions, data)
  w, h = okW and w or nil, okW and h or nil
  local bytes = (w and h) and w * h * 4 or 6 * 1024 * 1024
  -- make room: least recently used first, by slot count and by bytes; the new shard always stays
  local memo = S.memo
  while #memo > 0 and (#memo >= S.memoSlots or memoBytes() + bytes > S.memoMaxBytes) do
    local oldest = 1
    for i = 2, #memo do if memo[i].last < memo[oldest].last then oldest = i end end
    memoRemove(oldest)
  end
  memo[#memo + 1] = { file = file, data = data, last = t, w = w, h = h, bytes = bytes }
  if S.onDecode then pcall(S.onDecode, file, ms) end
  return data
end

-- ------------------------------------------------------------ crop store
-- S.rects[file] = array of { x, y, w, h, data, tick, bytes }
local function evictIfNeeded(keep)
  local cap = S.maxBytes
  while S.bytes > cap do
    local fOld, iOld, tOld
    for file, list in pairs(S.rects) do
      for i = 1, #list do
        local r = list[i]
        if r ~= keep and (tOld == nil or r.tick < tOld) then fOld, iOld, tOld = file, i, r.tick end
      end
    end
    if not fOld then break end
    local list = S.rects[fOld]
    local r = table.remove(list, iOld)
    if S.fileLast[fOld] == r then S.fileLast[fOld] = nil end
    releaseData(r.data)
    S.bytes = S.bytes - r.bytes
    S.nCrops = S.nCrops - 1
    S.st.cropEvicted = S.st.cropEvicted + 1
    if #list == 0 then S.rects[fOld] = nil end
  end
end

-- register a finished crop (made here or by the worker) in the store
local function addRect(file, x, y, w, h, crop)
  S.tick = S.tick + 1
  local r = { x = x, y = y, w = w, h = h, data = crop, tick = S.tick, bytes = w * h * 4 }
  local list = S.rects[file]
  if not list then list = {}; S.rects[file] = list end
  list[#list + 1] = r
  S.bytes = S.bytes + r.bytes
  S.nCrops = S.nCrops + 1
  S.fileLast[file] = r
  evictIfNeeded(r) -- never the crop the caller is about to use
  return r
end

local function rectExists(file, x, y, w, h)
  local list = S.rects[file]
  if list then
    for i = 1, #list do
      local r = list[i]
      if r.x == x and r.y == y and r.w == w and r.h == h then return true end
    end
  end
  return false
end

local pendingKey -- defined with the worker code below

local function makeCrop(file, x, y, w, h)
  local shard = decodeShard(file)
  if not shard then return nil end
  local okC, crop = pcall(RAW_NEW, w, h)
  if not okC or not crop then S.st.errors = S.st.errors + 1; return nil end
  local okP = pcall(ORIG_PASTE, crop, shard, 0, 0, x, y, w, h)
  if not okP then releaseData(crop); S.st.errors = S.st.errors + 1; return nil end
  return addRect(file, x, y, w, h, crop)
end

-- exact rectangle (what SpriteAtlas.image pastes)
local function rectFor(file, x, y, w, h)
  local last = S.fileLast[file]
  if last and last.x == x and last.y == y and last.w == w and last.h == h then
    S.tick = S.tick + 1; last.tick = S.tick
    S.st.cropHits = S.st.cropHits + 1
    return last
  end
  local list = S.rects[file]
  if list then
    for i = 1, #list do
      local r = list[i]
      if r.x == x and r.y == y and r.w == w and r.h == h then
        S.tick = S.tick + 1; r.tick = S.tick
        S.fileLast[file] = r
        S.st.cropHits = S.st.cropHits + 1
        return r
      end
    end
  end
  S.st.cropMisses = S.st.cropMisses + 1
  if S.w and S.w.npend > 0 and pendingKey(file, x, y, w, h) then S.st.demandWhilePending = S.st.demandWhilePending + 1 end
  return makeCrop(file, x, y, w, h)
end

-- any rectangle holding pixel (x, y) (what SpriteAtlas.opaqueBottom reads)
local function rectAt(file, x, y)
  local last = S.fileLast[file]
  if last and x >= last.x and y >= last.y and x < last.x + last.w and y < last.y + last.h then
    return last
  end
  local list = S.rects[file]
  if list then
    for i = 1, #list do
      local r = list[i]
      if x >= r.x and y >= r.y and x < r.x + r.w and y < r.y + r.h then
        S.fileLast[file] = r
        return r
      end
    end
  end
  S.st.tileMisses = S.st.tileMisses + 1
  local T = S.tile
  local tx, ty = math.floor(x / T) * T, math.floor(y / T) * T
  decodeShard(file) -- the shard size is needed to clip the tile (and the decode is needed anyway)
  local m = memoFind(file)
  local w, h = T, T
  if m and m.w then
    w = math.min(T, m.w - tx); h = math.min(T, m.h - ty)
  end
  if w < 1 or h < 1 then return nil end
  return makeCrop(file, tx, ty, w, h)
end

-- ------------------------------------------------------------ the hooks
local function isShardPath(a)
  local prefix = S.prefix
  -- 1.10.1 palette PNGs are read with getString(), not paste(): they
  -- must be real data. Only actual numbered shard files may be sentinels.
  return a:find(prefix, 1, true) == 1 and a:match("_[0-9]+%.png$") ~= nil
end

local function realShard(info)
  -- sentinel could not be answered from crops: give the caller the real thing (never a silent 1x1)
  S.st.fallbacks = S.st.fallbacks + 1
  local ok, data = pcall(RAW_NEW, info.file)
  return ok and data or nil
end

local function shardExists(s, path)
  -- a missing shard must fail exactly like the unhooked decode does (SpriteAtlas pcall's it and serves nothing)
  local wmod = s.wmod
  if not (wmod and type(wmod.info) == "function") then return true end
  local ok, info = pcall(wmod.info, wmod, path:sub(#s.wpath + 2))
  return ok and info ~= nil
end

local function hookNew(a, ...)
  local s = S
  if s and s.on and type(a) == "string" and select("#", ...) == 0 and isShardPath(a) and shardExists(s, a) then
    local ok, sentinel = pcall(RAW_NEW, 1, 1)
    if ok and sentinel then
      s.reg[sentinel] = { file = a }
      s.st.sentinels = s.st.sentinels + 1
      return sentinel
    end
  end
  return RAW_NEW(a, ...)
end

local function hookPaste(self, src, dx, dy, sx, sy, sw, sh)
  local s = S
  local info = s and s.on and s.reg[src]
  if info then
    if sx and sy and sw and sh then
      local r = rectFor(info.file, sx, sy, sw, sh)
      if r then return ORIG_PASTE(self, r.data, dx, dy, 0, 0, sw, sh) end
    end
    local real = realShard(info)
    if real then
      local a, b, c, d, e, f = ORIG_PASTE(self, real, dx, dy, sx, sy, sw, sh)
      releaseData(real)
      return a, b, c, d, e, f
    end
    -- the shard cannot be decoded: fail like the unhooked loader's failed slice (its caller pcall's this and serves nothing)
    error("WildsAtlasCompat: shard cannot be decoded: " .. tostring(info.file), 2)
  end
  return ORIG_PASTE(self, src, dx, dy, sx, sy, sw, sh)
end

local function hookGetPixel(self, x, y)
  local s = S
  local info = s and s.on and s.reg[self]
  if info then
    s.st.pixelCalls = s.st.pixelCalls + 1
    local r = rectAt(info.file, x, y)
    if r then return ORIG_GETPIXEL(r.data, x - r.x, y - r.y) end
    -- outside the shard (or a decode failure): ask the real shard so the caller sees the real error/value
    local real = realShard(info)
    if real then
      local a, b, c, d = ORIG_GETPIXEL(real, x, y)
      releaseData(real)
      return a, b, c, d
    end
    return 0, 0, 0, 0 -- undecodable shard: transparent, which the support scan reads as "no support" (the unhooked loader's nil)
  end
  return ORIG_GETPIXEL(self, x, y)
end

-- ------------------------------------------------------------ decode worker (Lab 60)
-- S.w = { avail = nil|true|false, why, dead, thread, inCh, outCh, inName, outName, source, queue = { entries },
--         nq, npend, pend = { key -> true }, inflight = entry|nil, nextId, fails, sentAt, restarts }
-- queue entry = { file, n = rectangle count, r = { x, y, w, h, tag, x, y, w, h, tag, ... } }; all queued rectangles of
-- one shard share ONE entry (and so one decode); a request for a shard already in flight is queued behind it.
local function newWorkerState(opts)
  return { avail = nil, dead = false, queue = {}, nq = 0, npend = 0, pend = {}, nextId = 0, fails = 0, restarts = 0,
           source = opts.workerSource, off = opts.worker == false }
end

pendingKey = function(file, x, y, w, h)
  local wk = S.w
  if not wk then return false end
  return wk.pend[file .. "|" .. x .. "|" .. y .. "|" .. w .. "|" .. h] == true
end

local function workerFail(why)
  local s = S
  local wk = s and s.w
  if not wk or wk.dead then return end
  wk.dead, wk.why, wk.avail = true, why, false
  wk.queue, wk.nq, wk.inflight = {}, 0, nil
  wk.pend, wk.npend = {}, 0
  if wk.inCh then pcall(wk.inCh.push, wk.inCh, { quit = true }) end
  if s.log then s.log("[approach] atlas decode worker off, synchronous decode from now on: " .. tostring(why)) end
end

-- is love.thread reachable here, and do we have the worker source? Cached; never raises.
local function probeWorker()
  local s = S
  local wk = s.w
  if wk.avail ~= nil then return wk.avail end
  local reason
  if not M.WORKER or wk.off then
    reason = "disabled"
  else
    local okT, T = pcall(function() return s.lv.thread end)
    if not okT then
      reason = "love.thread not reachable (" .. tostring(T):gsub("^.-:%d+: ", "") .. ")"
    elseif type(T) ~= "table" or type(T.newThread) ~= "function" or type(T.getChannel) ~= "function" then
      reason = "no love.thread"
    else
      local src = wk.source
      if type(src) == "function" then
        local okS, v = pcall(src)
        src = okS and v or nil
      end
      if type(src) ~= "string" or not src:find("\n", 1, true) then
        reason = "no worker source"
      else
        wk.source, wk.T = src, T
      end
    end
  end
  wk.avail = reason == nil
  wk.why = reason
  if reason and s.log and reason ~= "disabled" then
    s.log("[approach] atlas decode worker unavailable (" .. reason .. "): synchronous decode, as Lab 58")
  end
  return wk.avail
end

local function startThread()
  local s = S
  local wk = s.w
  if not wk.inName then
    installSerial = installSerial + 1
    wk.inName, wk.outName = "wildsatlas_in_" .. installSerial, "wildsatlas_out_" .. installSerial
  end
  if not wk.inCh then
    wk.inCh, wk.outCh = wk.T.getChannel(wk.inName), wk.T.getChannel(wk.outName)
    pcall(wk.inCh.clear, wk.inCh)
    pcall(wk.outCh.clear, wk.outCh)
  end
  local ok, th = pcall(wk.T.newThread, wk.source)
  if not ok or not th then return false, "newThread failed: " .. tostring(th) end
  local okS, errS = pcall(th.start, th, wk.inName, wk.outName, M.WORKER_IDLE_S)
  if not okS then return false, "thread start failed: " .. tostring(errS) end
  wk.thread = th
  return true
end

local function workerRegister(msg)
  local s = S
  local x, y, w, h, data = msg.x, msg.y, msg.w, msg.h, msg.data
  if type(x) ~= "number" or type(w) ~= "number" or not data then return end
  if rectExists(msg.file, x, y, w, h) then
    s.st.workerDup = s.st.workerDup + 1 -- the demand path got there first
    releaseData(data)
  else
    addRect(msg.file, x, y, w, h, data)
    s.st.workerCrops = s.st.workerCrops + 1
  end
end

local function finishInflight(ok, ms, errText)
  local s = S
  local wk = s.w
  local e = wk.inflight
  wk.inflight = nil
  if e then
    local r = e.r
    for i = 1, e.n * 5, 5 do
      local k = e.file .. "|" .. r[i] .. "|" .. r[i + 1] .. "|" .. r[i + 2] .. "|" .. r[i + 3]
      if wk.pend[k] then
        wk.pend[k] = nil
        wk.npend = wk.npend - 1
      end
    end
  end
  local st = s.st
  if ok then
    wk.fails = 0
    st.workerDecodes = st.workerDecodes + 1
    st.workerDecodeMs = st.workerDecodeMs + (ms or 0)
    if (ms or 0) > st.workerDecodeMaxMs then st.workerDecodeMaxMs = ms end
  else
    st.workerErrors = st.workerErrors + 1
    wk.fails = wk.fails + 1
    if wk.fails >= M.WORKER_MAX_FAILS then workerFail("repeated request errors: " .. tostring(errText)) end
  end
end

local function dispatchNext(t)
  local s = S
  local wk = s.w
  if wk.thread == nil or not wk.thread:isRunning() then
    local ok, why = startThread()
    if not ok then workerFail(why); return end
  end
  local e = table.remove(wk.queue, 1)
  wk.nq = wk.nq - 1
  wk.nextId = wk.nextId + 1
  e.id = wk.nextId
  local rects = {}
  for i = 1, e.n do
    local b, o = (i - 1) * 5, (i - 1) * 4
    rects[o + 1], rects[o + 2], rects[o + 3], rects[o + 4] = e.r[b + 1], e.r[b + 2], e.r[b + 3], e.r[b + 4]
  end
  wk.inflight, wk.sentAt = e, t
  s.st.workerJobs = s.st.workerJobs + 1
  wk.inCh:push({ id = e.id, file = e.file, rects = rects })
end

-- one step: collect finished crops, check the thread, send the next request. No allocation when idle.
local function workerStep(t)
  local s = S
  local wk = s.w
  if wk.dead then return end
  local e = wk.inflight
  if e then
    local outCh = wk.outCh
    for _ = 1, M.MAX_RESULTS_PER_UPDATE do
      local msg = outCh:pop()
      if msg == nil then break end
      if msg.fatal ~= nil then
        workerFail("worker error: " .. tostring(msg.fatal))
        return
      end
      if msg.id == e.id then
        if msg.done then
          finishInflight(msg.err == nil, msg.ms, msg.err)
          break
        end
        workerRegister(msg)
      elseif msg.data then
        releaseData(msg.data)
      end
    end
    e = wk.inflight
    if e then
      local th = wk.thread
      if th and not th:isRunning() then
        local err = th:getError()
        if err then
          workerFail("thread error: " .. tostring(err))
          return
        end
        -- exited while idle just before our push: start it again (the request is still in the channel)
        wk.restarts = wk.restarts + 1
        s.st.workerRestarts = wk.restarts
        if wk.restarts > 8 then workerFail("worker keeps exiting"); return end
        local ok, why = startThread()
        if not ok then workerFail(why); return end
      elseif t - wk.sentAt > M.WORKER_TIMEOUT_S then
        workerFail("request timed out")
        return
      end
    end
  end
  if not wk.inflight and wk.nq > 0 then dispatchNext(t) end
end

--- true when warm requests will be decoded off the main thread (probes love.thread once; never raises).
function M.workerAvailable()
  local s = S
  if not (s and s.on and s.w) then return false end
  if s.w.dead then return false end
  return probeWorker()
end

--- Queue one rectangle of a shard for the worker. Returns true (queued or already queued), or false + reason:
--- "cached" (a crop already exists), "no worker" (synchronous path), "bad rect".
function M.submitRect(file, x, y, w, h, tag)
  local s = S
  if not (s and s.on and s.w) then return false, "no worker" end
  if type(file) ~= "string" or type(x) ~= "number" or type(y) ~= "number" or type(w) ~= "number" or type(h) ~= "number"
      or w < 1 or h < 1 then
    return false, "bad rect"
  end
  if rectExists(file, x, y, w, h) then return false, "cached" end
  if not M.workerAvailable() then return false, "no worker" end
  local wk = s.w
  local key = file .. "|" .. x .. "|" .. y .. "|" .. w .. "|" .. h
  if wk.pend[key] then return true end
  -- merge into the queued entry of the same shard (one decode serves them all); a shard already in flight gets its own entry
  local entry
  for i = 1, wk.nq do
    if wk.queue[i].file == file then entry = wk.queue[i]; break end
  end
  if not entry then
    entry = { file = file, n = 0, r = {} }
    wk.nq = wk.nq + 1
    wk.queue[wk.nq] = entry
  end
  local o = entry.n * 5
  entry.r[o + 1], entry.r[o + 2], entry.r[o + 3], entry.r[o + 4], entry.r[o + 5] = x, y, w, h, tag
  entry.n = entry.n + 1
  wk.pend[key] = true
  wk.npend = wk.npend + 1
  return true
end

--- Queue the sheet of (dex, which = 1 walk | 2 idle) for the worker; same index and keys as warmSheet.
function M.warmSheetAsync(dex, which, shiny, tag)
  local sh, x, y, w, h, full = M.sheetInfo(dex, which, shiny)
  if not sh then return false, x end
  return M.submitRect(full, x, y, w, h, tag)
end

--- Drop every queued (not yet sent) rectangle carrying `tag`. A request already at the worker cannot be recalled (a
--- native decode cannot be interrupted); its crops are kept when they arrive (valid data, bounded by the crop cap).
--- Returns how many rectangles were dropped.
function M.cancel(tag)
  local s = S
  local wk = s and s.w
  if not wk or wk.nq == 0 then return 0 end
  local dropped = 0
  local i = 1
  while i <= wk.nq do
    local e = wk.queue[i]
    local r, kept = e.r, 0
    for j = 1, e.n do
      local b = (j - 1) * 5
      if r[b + 5] == tag then
        local k = e.file .. "|" .. r[b + 1] .. "|" .. r[b + 2] .. "|" .. r[b + 3] .. "|" .. r[b + 4]
        if wk.pend[k] then
          wk.pend[k] = nil
          wk.npend = wk.npend - 1
        end
        dropped = dropped + 1
      else
        local o = kept * 5
        r[o + 1], r[o + 2], r[o + 3], r[o + 4], r[o + 5] = r[b + 1], r[b + 2], r[b + 3], r[b + 4], r[b + 5]
        kept = kept + 1
      end
    end
    for j = kept * 5 + 1, e.n * 5 do r[j] = nil end
    e.n = kept
    if kept == 0 then
      table.remove(wk.queue, i)
      wk.nq = wk.nq - 1
    else
      i = i + 1
    end
  end
  s.st.workerCancelled = s.st.workerCancelled + dropped
  return dropped
end

--- Worker state for logs and tests: "unprobed", "ready", "busy", "off: <why>", "dead: <why>"; nil when not installed.
function M.workerState()
  local s = S
  local wk = s and s.w
  if not wk then return nil end
  if wk.dead then return "dead: " .. tostring(wk.why) end
  if wk.avail == false then return "off: " .. tostring(wk.why) end
  if wk.avail == nil then return "unprobed" end
  if wk.inflight or wk.nq > 0 then return "busy" end
  return "ready"
end

--- Queued + in-flight rectangle count (0 when idle).
function M.pending()
  local wk = S and S.w
  return wk and wk.npend or 0
end

-- ------------------------------------------------------------ install / uninstall
--- opts: find (mod.find), log (fn), love (override, tests), maxBytes, tile, onDecode(file, ms),
--- workerSource (the source text of compat/WildsAtlasWorker.lua, or a function returning it; without it the worker is
--- not used), worker = false (never use the worker), memoSlots, memoMaxBytes.
--- Returns true, or false + reason. Idempotent.
function M.install(opts)
  opts = opts or {}
  local log = opts.log or function() end
  if not M.ENABLED then return false, "disabled" end
  if S then return true, "already installed" end
  local lv = opts.love or love
  if not (lv and lv.image and type(lv.image.newImageData) == "function") then return false, "no love.image" end
  local find = opts.find
  local wilds = find and find("wilds_of_hoenn")
  local ex = wilds and wilds.exports
  if not (ex and ex.spawnManager and type(ex.atlasStats) == "function") then return false, "wilds_of_hoenn not ready" end
  if not M.SUPPORTED_VERSIONS[wilds.version or ex.version] then return false, "wilds version " .. tostring(wilds.version or ex.version) end
  if (wilds.version or ex.version) ~= "1.5.0" and not (type(ex.spriteAtlas) == "table" and type(ex.spriteAtlas.release) == "function") then
    return false, "wilds_of_hoenn atlas release hook missing"
  end
  local wmod = ex.spawnManager.mod
  local wpath = type(wmod) == "table" and wmod.path
  if type(wpath) ~= "string" or wpath == "" then return false, "wilds path unknown" end
  local rawNew = lv.image.newImageData
  -- a previous install whose uninstall could not take every hook out (someone wrapped it meanwhile): never treat our
  -- own hook as the original, that would make the hook call itself forever
  if rawNew == hookNew then rawNew = RAW_NEW end
  local okP, probe = pcall(rawNew, 1, 1)
  if not (okP and probe) then return false, "ImageData probe failed" end
  local mt = getmetatable(probe)
  local methods = type(mt) == "table" and (type(mt.__index) == "table" and mt.__index or mt) or nil
  local origPaste, origGetPixel = methods and methods.paste, methods and methods.getPixel
  pcall(probe.release, probe)
  if origPaste == hookPaste then origPaste = ORIG_PASTE end
  if origGetPixel == hookGetPixel then origGetPixel = ORIG_GETPIXEL end
  if type(rawNew) ~= "function" or type(origPaste) ~= "function" or type(origGetPixel) ~= "function"
      or rawNew == hookNew or origPaste == hookPaste or origGetPixel == hookGetPixel then
    return false, "ImageData methods not patchable"
  end
  RAW_NEW, ORIG_PASTE, ORIG_GETPIXEL = rawNew, origPaste, origGetPixel
  S = {
    on = true, lv = lv, find = find, wmod = wmod, atlas = ex.spriteAtlas, rawNew = rawNew, methods = methods, origPaste = origPaste, origGetPixel = origGetPixel,
    wpath = wpath, prefix = wpath .. "/assets/atlas/", reg = setmetatable({}, { __mode = "k" }),
    rects = {}, fileLast = {}, bytes = 0, nCrops = 0, tick = 0, seenShard = {},
    memo = {}, memoSlots = opts.memoSlots or M.MEMO_SLOTS, memoMaxBytes = opts.memoMaxBytes or M.MEMO_MAX_BYTES,
    w = newWorkerState(opts),
    maxBytes = opts.maxBytes or M.MAX_CROP_BYTES, tile = opts.tile or M.TILE,
    st = emptyStats(), onDecode = opts.onDecode, log = log,
    hookNew = hookNew, hookPaste = hookPaste, hookGetPixel = hookGetPixel,
  }
  lv.image.newImageData = hookNew
  methods.paste = hookPaste
  methods.getPixel = hookGetPixel
  log(("[approach] atlas crop cache installed (shard prefix %s, cap %d KiB)"):format(S.prefix, math.floor(S.maxBytes / 1024)))
  return true
end

--- Restore the originals (only the ones still ours) and free everything. Safe to call twice.
function M.uninstall()
  local s = S
  if not s then return false end
  -- Wilds holds our 1x1 sentinel shard ImageData in its own LRU. Flush that LRU
  -- BEFORE detaching hooks; otherwise a hot reload interprets a sentinel as actual atlas pixels.
  local cachedSentinel = next(s.reg) ~= nil
  if s.atlas and type(s.atlas.release) == "function" then
    local ok, why = pcall(s.atlas.release)
    if not ok or why == false then
      s.log("[approach] atlas release failed; keeping sentinel hooks installed: " .. tostring(why))
      return false, "atlas release failed"
    end
  elseif cachedSentinel then
    s.log("[approach] atlas release unavailable; keeping sentinel hooks installed")
    return false, "atlas release unavailable"
  end
  s.on = false
  local wk = s.w
  if wk and wk.inCh then pcall(wk.inCh.push, wk.inCh, { quit = true }) end -- the thread also exits by itself when idle
  if s.lv.image.newImageData == s.hookNew then s.lv.image.newImageData = s.rawNew end
  if s.methods.paste == s.hookPaste then s.methods.paste = s.origPaste end
  if s.methods.getPixel == s.hookGetPixel then s.methods.getPixel = s.origGetPixel end
  dropMemo()
  for _, list in pairs(s.rects) do for i = 1, #list do releaseData(list[i].data) end end
  S = nil
  return true
end

function M.installed() return S ~= nil and S.on == true end

--- Housekeeping, call every frame or so: releases the shard memo once it has been idle for MEMO_TTL.
function M.update(t)
  local s = S
  if not s then return end
  local tt = t or now()
  local memo = s.memo
  for i = #memo, 1, -1 do
    if tt - memo[i].last > M.MEMO_TTL then memoRemove(i) end
  end
  local wk = s.w
  if wk.inflight or wk.nq > 0 then
    local ok, err = pcall(workerStep, tt)
    if not ok then workerFail("worker step error: " .. tostring(err)) end
  end
end

--- Live counters (a fresh table; for logging, not for per-frame use).
function M.stats()
  local s = S
  if not s then return nil end
  local o = {}
  for k, v in pairs(s.st) do o[k] = v end
  o.crops, o.cropBytes = s.nCrops, s.bytes
  local newest
  for i = 1, #s.memo do if not newest or s.memo[i].last >= newest.last then newest = s.memo[i] end end
  o.memoShard = newest and newest.file or nil
  o.memoShards, o.memoBytes = #s.memo, memoBytes()
  o.workerState = M.workerState()
  o.workerPending = s.w and s.w.npend or 0
  return o
end

--- Read one counter without allocating (e.g. "decodes", "cropHits").
function M.counter(name)
  local s = S
  return s and s.st[name] or 0
end

function M.resetStats()
  if S then S.st = emptyStats(); S.seenShard = {} end
end

-- ------------------------------------------------------------ species warm (read-only)
-- Crop the walk and idle sheet of a national dex number ahead of its first draw, using the same index files and
-- the same path convention Wilds uses (assets/pmd/<walk|idle>/%03d-normal.png in the atlas family json). Only
-- strings are read from the index (no JSON decode); a missing entry is a quiet no-op.
local ANIMS = { { fam = "pmd_walk", dir = "assets/pmd/walk" }, { fam = "pmd_idle", dir = "assets/pmd/idle" } }

local function familyRaw(fam)
  local s = S
  local hit = s.famRaw and s.famRaw[fam]
  if hit ~= nil then return hit or nil end
  s.famRaw = s.famRaw or {}
  local wmod = s.wmod
  local raw
  if wmod and wmod.read then
    local ok, v = pcall(wmod.read, wmod, "assets/atlas/" .. fam .. ".json")
    raw = ok and type(v) == "string" and v or nil
  end
  s.famRaw[fam] = raw or false
  return raw
end

local function bindWilds()
  local s = S
  if not s.wmod then
    local wilds = s.find and s.find("wilds_of_hoenn")
    s.wmod = wilds and wilds.exports and wilds.exports.spawnManager and wilds.exports.spawnManager.mod
  end
end

--- Where the sheet of (dex, which = 1 walk | 2 idle) lives in the atlas: shard number, x, y, w, h, and the absolute
--- shard path as SpriteAtlas hands it to newImageData. nil when the index has no such entry. Reads index strings only.
function M.sheetInfo(dex, which, shiny)
  local s = S
  if not (s and s.on) then return nil, "not installed" end
  local a = ANIMS[which]
  if not a then return nil, "bad sheet" end
  bindWilds()
  local raw = familyRaw(a.fam)
  if not raw then return nil, "no family index" end
  local key = ('"%03d-%s.png"'):format(dex, shiny and "shiny" or "normal")
  local at = raw:find(key, 1, true)
  if not at then return nil, "no entry" end
  local sh, x, y, w, h = raw:match("^%s*:%s*%[%s*(%d+)%s*,%s*(%d+)%s*,%s*(%d+)%s*,%s*(%d+)%s*,%s*(%d+)%s*%]", at + #key)
  -- 1.10.1 appends a palette-row index to the same rectangle tuple.
  -- Warm the number pixels; SpriteAtlas owns their exact colour expansion.
  if not sh then
    sh, x, y, w, h = raw:match("^%s*:%s*%[%s*(%d+)%s*,%s*(%d+)%s*,%s*(%d+)%s*,%s*(%d+)%s*,%s*(%d+)%s*,%s*%d+%s*%]", at + #key)
  end
  if not sh then return nil, "unparsed entry" end
  return tonumber(sh), tonumber(x), tonumber(y), tonumber(w), tonumber(h), s.prefix .. a.fam .. "_" .. sh .. ".png"
end

--- Crop the sheet ahead of its first draw (same files and keys the atlas uses). Returns true, or false + reason.
function M.warmSheet(dex, which, shiny)
  local sh, x, y, w, h, full = M.sheetInfo(dex, which, shiny)
  if not sh then return false, x end
  local rect = rectFor(full, x, y, w, h)
  return rect ~= nil, rect and "ok" or "decode failed"
end

--- Test seam: give warmSheet the find function when install() was called with one.
function M._bindFind(find) if S then S.find = find end end

return M
