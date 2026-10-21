-- FRLG_VOXEL Lab 57: WORLD CACHE binary codec (FireRed's own file).
--
-- Little-endian writer / reader, a small tagged value codec for plain data
-- (numbers, strings, booleans, tables of those) and the GPU vertex-stream
-- readback used by the capture path. Nothing here touches the disk, the
-- game or the renderer: it needs only love.data (pack / unpack) and, for the
-- mesh helpers, a Mesh object.
--
-- Prior art, ideas only (no code is shared with it): the in-house Emerald
-- prebake design (per-record files, parts written header-last, md5 per part,
-- LZ4, "save clean builds only"). Written for FireRed; do not require the
-- Emerald modules from here.
--
-- Every reader error is thrown as a string beginning "frpc:"; callers wrap
-- the whole decode in pcall and treat any error as a corrupt record.
local F = {}

F.MAGIC = "FRPC"
F.VERSION = 5 -- persisted native tree anchor streams; older records rebuild safely
F.PART_TARGET = 256 * 1024      -- raw bytes per data part (a larger single blob gets a part of its own)
F.SEG_VERTS = 4096              -- vertices per stored / uploaded segment (matches Scene.SLICE_VERTS)
F.MAX_WRITE = 64 * 1024 * 1024  -- mod.cache:write limit (ImportAccess.MAX_CACHE_WRITE_BYTES)
F.MAX_STR = 4 * 1024 * 1024
F.MAX_NODES = 1000000
F.MAX_VERTS = 4 * 1024 * 1024   -- vertices in one chunk
F.MAX_CHUNKS = 8192             -- chunks in one record
F.MAX_PARTS = 4096
F.MAX_DIM = 1024                -- map cells per side

local unpack_ = unpack or table.unpack

local function pack(fmt, ...) return love.data.pack("string", fmt, ...) end
local function unpackStr(fmt, s, pos) return love.data.unpack(fmt, s, pos) end

-- "<dddd..." formats, built once per length
local FMT_D, FMT_F = {}, {}
local function fmtD(k)
  local f = FMT_D[k]
  if not f then f = "<" .. string.rep("d", k); FMT_D[k] = f end
  return f
end
local function fmtF(k)
  local f = FMT_F[k]
  if not f then f = "<" .. string.rep("f", k); FMT_F[k] = f end
  return f
end

function F.fail(msg) error("frpc: " .. tostring(msg), 0) end

-- ------------------------------------------------------------------ writer
local W = {}
W.__index = W

function F.writer()
  return setmetatable({ t = {}, n = 0, size = 0 }, W)
end

local function put(w, s)
  local n = w.n + 1
  w.n = n
  w.t[n] = s
  w.size = w.size + #s
end

function W:raw(s) put(self, s) end
function W:u8(v) put(self, string.char(v)) end
function W:u16(v) put(self, pack("<I2", v)) end
function W:u32(v) put(self, pack("<I4", v)) end
function W:d(v) put(self, pack("<d", v)) end
function W:bool(b) put(self, b and "\1" or "\0") end
function W:str(s)
  put(self, pack("<I4", #s))
  put(self, s)
end
function W:result() return table.concat(self.t) end

-- tagged values -------------------------------------------------------
-- 0 nil, 1 false, 2 true, 3 number (double), 4 string, 5 table (sorted pairs),
-- 6 dense number array (1..n, no other keys).
local function keyLess(a, b)
  local ta, tb = type(a), type(b)
  if ta ~= tb then return ta == "number" end
  return a < b
end

local function enc(w, v, st, depth)
  local tv = type(v)
  if tv == "nil" then
    put(w, "\0")
  elseif tv == "boolean" then
    put(w, v and "\2" or "\1")
  elseif tv == "number" then
    put(w, "\3")
    put(w, pack("<d", v))
  elseif tv == "string" then
    put(w, "\4")
    put(w, pack("<I4", #v))
    put(w, v)
  elseif tv == "table" then
    if depth > 16 then F.fail("value too deep") end
    if st.stack[v] then F.fail("cyclic value") end
    st.nodes = st.nodes + 1
    if st.nodes > F.MAX_NODES then F.fail("too many nodes") end
    if st.tick and st.nodes % 256 == 0 then st.tick() end
    local n = 0
    for _ in pairs(v) do n = n + 1 end
    local dense = n > 0 and #v == n
    if dense then
      for i = 1, n do
        if type(v[i]) ~= "number" then dense = false; break end
      end
    end
    if dense then
      put(w, "\6")
      put(w, pack("<I4", n))
      local i = 1
      while i <= n do
        local k = n - i + 1
        if k > 64 then k = 64 end
        put(w, pack(fmtD(k), unpack_(v, i, i + k - 1)))
        i = i + k
      end
    else
      st.stack[v] = true
      put(w, "\5")
      put(w, pack("<I4", n))
      local keys = {}
      for k in pairs(v) do
        local tk = type(k)
        if tk ~= "number" and tk ~= "string" then F.fail("key type " .. tk) end
        keys[#keys + 1] = k
      end
      table.sort(keys, keyLess)
      for _, k in ipairs(keys) do
        enc(w, k, st, depth + 1)
        enc(w, v[k], st, depth + 1)
      end
      st.stack[v] = nil
    end
  else
    F.fail("unserializable " .. tv)
  end
end

-- tick: optional function called every few hundred nodes (cooperative yield)
function W:value(v, tick)
  enc(self, v, { nodes = 0, stack = {}, tick = tick }, 0)
end

-- ------------------------------------------------------------------ reader
local R = {}
R.__index = R

function F.reader(s, pos, limit)
  return setmetatable({ s = s, pos = pos or 1, n = limit or #s }, R)
end

function R:need(k)
  if k < 0 or self.pos + k - 1 > self.n then F.fail("truncated") end
end
function R:left() return self.n - self.pos + 1 end
function R:u8()
  self:need(1)
  local b = self.s:byte(self.pos)
  self.pos = self.pos + 1
  return b
end
function R:u16()
  self:need(2)
  local v = unpackStr("<I2", self.s, self.pos)
  self.pos = self.pos + 2
  return v
end
function R:u32()
  self:need(4)
  local v = unpackStr("<I4", self.s, self.pos)
  self.pos = self.pos + 4
  return v
end
function R:d()
  self:need(8)
  local v = unpackStr("<d", self.s, self.pos)
  self.pos = self.pos + 8
  return v
end
function R:bool() return self:u8() ~= 0 end
function R:str(max)
  local n = self:u32()
  if n > (max or F.MAX_STR) then F.fail("string too long") end
  self:need(n)
  local r = self.s:sub(self.pos, self.pos + n - 1)
  self.pos = self.pos + n
  return r
end
function R:bytes(n)
  self:need(n)
  local r = self.s:sub(self.pos, self.pos + n - 1)
  self.pos = self.pos + n
  return r
end

local function dec(r, st, depth)
  local tag = r:u8()
  if tag == 0 then return nil
  elseif tag == 1 then return false
  elseif tag == 2 then return true
  elseif tag == 3 then return r:d()
  elseif tag == 4 then return r:str()
  elseif tag == 6 then
    if depth > 16 then F.fail("value too deep") end
    local n = r:u32()
    r:need(n * 8)
    st.nodes = st.nodes + 1
    if st.nodes > F.MAX_NODES then F.fail("too many nodes") end
    local t = {}
    local i = 1
    while i <= n do
      local k = n - i + 1
      if k > 64 then k = 64 end
      local vals = { unpackStr(fmtD(k), r.s, r.pos) }
      for j = 1, k do t[i + j - 1] = vals[j] end
      r.pos = r.pos + 8 * k
      i = i + k
      if st.tick then st.tick() end
    end
    return t
  elseif tag == 5 then
    if depth > 16 then F.fail("value too deep") end
    local n = r:u32()
    if n > r:left() then F.fail("table too large") end
    st.nodes = st.nodes + 1 + n
    if st.nodes > F.MAX_NODES then F.fail("too many nodes") end
    if st.tick and st.nodes % 256 < n + 1 then st.tick() end
    local t = {}
    for _ = 1, n do
      local k = dec(r, st, depth + 1)
      if k == nil or k ~= k then F.fail("bad key") end
      t[k] = dec(r, st, depth + 1)
    end
    return t
  end
  F.fail("bad tag " .. tostring(tag))
end

function R:value(tick)
  return dec(self, { nodes = 0, tick = tick }, 0)
end

-- ------------------------------------------------------------------ helpers
-- Scalar-only deep copy (numbers, strings, booleans; sub-tables to `depth`
-- levels). Used for the occluder / shell-group tables whose consumers read
-- only scalar fields; a field holding a function, userdata or deeper table
-- is dropped. Errors when the copy would exceed `maxNodes` nodes.
function F.project(v, depth, st)
  st = st or { nodes = 0 }
  local out = {}
  for k, x in pairs(v) do
    local tk, tx = type(k), type(x)
    if tk == "number" or tk == "string" then
      if tx == "number" or tx == "string" or tx == "boolean" then
        out[k] = x
        st.nodes = st.nodes + 1
      elseif tx == "table" and depth > 0 then
        out[k] = F.project(x, depth - 1, st)
      end
      if st.nodes > 200000 then F.fail("projection too large") end
    end
  end
  return out
end

-- md5 (raw 16 bytes) / hex helpers
function F.md5(s) return love.data.hash("md5", s) end
function F.hex(raw) return love.data.encode("string", "hex", raw) end
function F.md5hex(s) return F.hex(love.data.hash("md5", s)) end

-- Mesh vertices first..last (1-based) as little-endian float32 bytes, in the
-- mesh's own attribute order. ncomp = floats per vertex (8 for the world
-- format, 1 for the AO / emit streams). Mesh:getVertex returns the attributes
-- as plain numbers, so no table is made per vertex.
function F.packMesh(mesh, first, last, ncomp)
  local parts, np = {}, 0
  local t = {}
  local K = 32
  local i = first
  while i <= last do
    local cnt = last - i + 1
    if cnt > K then cnt = K end
    local tn = 0
    if ncomp == 8 then
      for j = 0, cnt - 1 do
        local a, b, c, d, e, f, g, h = mesh:getVertex(i + j)
        t[tn + 1], t[tn + 2], t[tn + 3], t[tn + 4] = a, b, c, d
        t[tn + 5], t[tn + 6], t[tn + 7], t[tn + 8] = e, f, g, h
        tn = tn + 8
      end
    elseif ncomp == 3 then
      for j = 0, cnt - 1 do
        local a,b,c=mesh:getVertex(i+j)
        t[tn+1],t[tn+2],t[tn+3]=a,b,c
        tn=tn+3
      end
    elseif ncomp == 1 then
      for j = 0, cnt - 1 do
        tn = tn + 1
        t[tn] = (mesh:getVertex(i + j))
      end
    else
      F.fail("unsupported vertex width " .. tostring(ncomp))
    end
    np = np + 1
    parts[np] = pack(fmtF(tn), unpack_(t, 1, tn))
    i = i + cnt
  end
  return table.concat(parts)
end

return F
