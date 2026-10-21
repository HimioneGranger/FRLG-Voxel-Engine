-- FRLG_VOXEL Lab 57: WORLD CACHE file layout, index and eviction (FireRed's own file).
--
-- mod.cache (src/mods/ImportAccess.lua) has read / write / info / exists /
-- delete and no listing and no rename, so the cache keeps its own index:
--   fr-precache/v1/<rk>.h       record header (written LAST: a record without a valid header is a miss)
--   fr-precache/v1/<rk>.p<N>    data parts
--   fr-precache/v1/idx.a|idx.b  LRU index, written alternately (a torn write leaves the other copy valid)
-- The index only drives size accounting and eviction. A record whose index
-- entry was lost is still found by name, and re-adopted on its first hit.
-- Deleting is cooperative: eviction and CLEAR queue file names, pumpDelete
-- removes a few per frame (header first, so a record becomes a miss at once).
local V = ...
local F = V.require("perf/FrPrecacheFormat")

local S = {}
S.__index = S

S.DIR = "fr-precache/v1/"
S.CAP_BYTES = 384 * 1024 * 1024
S.MAX_ENTRIES = 50000
S.FLUSH_GAP = 30           -- seconds between index writes while dirty

local function hexToRaw(hex) return love.data.decode("string", "hex", hex) end
local function rawToHex(raw) return love.data.encode("string", "hex", raw) end

function S.new(cache, log, clock)
  return setmetatable({
    cache = cache, log = log or print, clock = clock or os.clock,
    entries = {}, count = 0, total = 0, seq = 0, tick = 0,
    dirty = false, lastFlush = nil, last = nil, pendingDelete = {}, stats = {},
  }, S)
end

function S:name(rk, part)
  if part == "h" then return S.DIR .. rk .. ".h" end
  return S.DIR .. rk .. ".p" .. tostring(part)
end

-- ------------------------------------------------------------------ index file
local function encodeIndex(self)
  local w = F.writer()
  w:raw("FRIX")
  w:u32(1)
  w:u32(self.seq)
  w:u32(self.count)
  local keys = {}
  for rk in pairs(self.entries) do keys[#keys + 1] = rk end
  table.sort(keys)
  for _, rk in ipairs(keys) do
    local e = self.entries[rk]
    w:raw(hexToRaw(rk))
    w:u32(e.bytes)
    w:u16(e.parts)
    w:u32(e.use)
    w:u32(e.gen)
  end
  local body = w:result()
  return body .. love.data.hash("md5", body)
end

local function decodeIndex(s)
  if type(s) ~= "string" or #s < 32 then return nil, "short" end
  local body, sum = s:sub(1, -17), s:sub(-16)
  if love.data.hash("md5", body) ~= sum then return nil, "md5" end
  local r = F.reader(body)
  if r:bytes(4) ~= "FRIX" then return nil, "magic" end
  if r:u32() ~= 1 then return nil, "version" end
  local seq, count = r:u32(), r:u32()
  if count > S.MAX_ENTRIES then return nil, "count" end
  local entries, total = {}, 0
  for _ = 1, count do
    local rk = rawToHex(r:bytes(16))
    local e = { bytes = r:u32(), parts = r:u16(), use = r:u32(), gen = r:u32() }
    entries[rk] = e
    total = total + e.bytes
  end
  return { seq = seq, entries = entries, count = count, total = total }
end

-- Load the newer valid index copy. -> records, bytes
function S:load()
  local best, which
  for _, name in ipairs({ "a", "b" }) do
    local okR, s = pcall(self.cache.read, self.cache, S.DIR .. "idx." .. name)
    if okR and s then
      local okD, idx = pcall(decodeIndex, s)
      if okD and idx and (not best or idx.seq > best.seq) then best, which = idx, name end
    end
  end
  self.entries, self.count, self.total, self.seq = {}, 0, 0, 0
  if best then
    self.entries, self.count, self.total, self.seq = best.entries, best.count, best.total, best.seq
    self.last = which
  end
  local top = 0
  for _, e in pairs(self.entries) do if e.use > top then top = e.use end end
  self.tick = top
  self.dirty = false
  self.lastFlush = self.clock()
  return self.count, self.total
end

-- Write the index to the copy that is NOT the newest valid one. Cheap when clean.
function S:flush(force)
  if not self.dirty then return true end
  local t = self.clock()
  if not force and not self.urgent and self.lastFlush and t - self.lastFlush < S.FLUSH_GAP then return false end
  self.urgent = false -- Lab 57 test fix: a new record is indexed on the next idle frame; a failed write falls back to the gap
  self.seq = self.seq + 1
  local okE, data = pcall(encodeIndex, self)
  if not okE then self.seq = self.seq - 1; return false end
  local target = self.last == "a" and "b" or "a"
  local okW, res = pcall(self.cache.write, self.cache, S.DIR .. "idx." .. target, data)
  self.lastFlush = t
  if okW and res ~= nil and res ~= false then
    self.last = target
    self.dirty = false
    self.stats.indexWrites = (self.stats.indexWrites or 0) + 1
    return true
  end
  self.stats.indexFailed = (self.stats.indexFailed or 0) + 1
  return false
end

-- ------------------------------------------------------------------ entries
function S:has(rk) return self.entries[rk] end

-- Register / replace a record (after a successful save, or an orphan hit).
-- Drop queued deletes for this record's files (a key written or re-adopted again must not lose its new files).
function S:cancelDeletes(rk)
  local q = self.pendingDelete
  if #q == 0 then return 0 end
  local prefix = S.DIR .. rk .. "."
  local keep, n = {}, 0
  for _, rel in ipairs(q) do
    if rel:sub(1, #prefix) == prefix then n = n + 1 else keep[#keep + 1] = rel end
  end
  if n > 0 then self.pendingDelete = keep end
  return n
end

function S:add(rk, bytes, parts, gen)
  self:cancelDeletes(rk)
  local old = self.entries[rk]
  if old then self.total = self.total - old.bytes else self.count = self.count + 1 end
  self.tick = self.tick + 1
  self.entries[rk] = { bytes = bytes, parts = parts, use = self.tick, gen = gen or 0, sess = true }
  self.total = self.total + bytes
  self.dirty = true
  -- Lab 57 test fix: CLEAR and eviction can only reach indexed records, so index a new one promptly.
  -- Lab 59: not in bulk mode; FrPrepare writes the index at its checkpoints, before the manifest names the record.
  if not self.bulk then self.urgent = true end
end

-- A hit: bump LRU. Returns false for an unknown record.
function S:touch(rk)
  local e = self.entries[rk]
  if not e then return false end
  self.tick = self.tick + 1
  e.use = self.tick
  e.sess = true
  self.dirty = true
  return true
end

function S:remove(rk)
  local e = self.entries[rk]
  if not e then return nil end
  self.entries[rk] = nil
  self.count = self.count - 1
  self.total = self.total - e.bytes
  self.dirty = true
  return e
end

-- Queue the files of a record for deletion, header first.
function S:queueDelete(rk, parts)
  local q = self.pendingDelete
  q[#q + 1] = S.DIR .. rk .. ".h"
  for i = 1, parts or 0 do q[#q + 1] = S.DIR .. rk .. ".p" .. i end
end

-- Delete up to n queued files. -> files deleted this call
function S:pumpDelete(n)
  local q = self.pendingDelete
  local done = 0
  while done < n and #q > 0 do
    local rel = table.remove(q, 1)
    pcall(self.cache.delete, self.cache, rel)
    done = done + 1
    self.stats.deleted = (self.stats.deleted or 0) + 1
  end
  return done
end

-- Keep the cache under `cap` bytes: older code generations first, then least
-- recently used; records used this session go last. -> number of records evicted
function S:evict(cap, curGen)
  if self.total <= cap then return 0 end
  local list = {}
  for rk, e in pairs(self.entries) do list[#list + 1] = { rk = rk, e = e } end
  table.sort(list, function(a, b)
    local ga, gb = a.e.gen == curGen and 1 or 0, b.e.gen == curGen and 1 or 0
    if ga ~= gb then return ga < gb end
    local sa, sb = a.e.sess and 1 or 0, b.e.sess and 1 or 0
    if sa ~= sb then return sa < sb end
    if a.e.use ~= b.e.use then return a.e.use < b.e.use end
    return a.rk < b.rk
  end)
  local n = 0
  for _, item in ipairs(list) do
    if self.total <= cap then break end
    local e = self:remove(item.rk)
    if e then self:queueDelete(item.rk, e.parts); n = n + 1 end
  end
  self.stats.evicted = (self.stats.evicted or 0) + n
  return n
end

-- Lab 59: records of an older code generation can never be hit again (the code digest is part of the key);
-- queue their files for deletion. -> number of records forgotten, bytes freed
function S:dropOtherGenerations(curGen)
  local list = {}
  for rk, e in pairs(self.entries) do
    if e.gen ~= curGen then list[#list + 1] = rk end
  end
  table.sort(list)
  local bytes = 0
  for _, rk in ipairs(list) do
    local e = self:remove(rk)
    if e then self:queueDelete(rk, e.parts); bytes = bytes + e.bytes end
  end
  self.stats.evicted = (self.stats.evicted or 0) + #list
  return #list, bytes
end

-- CLEAR: forget every record and queue every file. -> records dropped
function S:clearAll()
  local n = 0
  for rk, e in pairs(self.entries) do
    self:queueDelete(rk, e.parts)
    n = n + 1
  end
  self.entries, self.count, self.total = {}, 0, 0
  self.dirty = true
  self:flush(true)
  return n
end

function S:info()
  return { records = self.count, bytes = self.total, pendingDelete = #self.pendingDelete }
end

return S
