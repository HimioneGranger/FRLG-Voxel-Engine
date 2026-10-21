-- FRLG_VOXEL Lab 57: WORLD CACHE record keys (FireRed's own file).
--
-- A record is valid only for the exact inputs that produced it. The key is
-- the md5 of these parts, joined with "|":
--   format   "frpc1" + the game (firered / leafgreen)  + record kind + scene key
--   code     md5 over every FRLG_VOXEL file under lib/ and assets/ (Lua, data, textures) and main.lua (and
--            manifest.json), by path and content, read through mod:list /
--            mod:read: any edit of the mod invalidates every record
--   engine   the scalar fields of src.core.Version (engine release, ROM cache
--            generation, ...) and the LOVE version
--   atlas    the engine's own atlas identity for the map's tileset pair: md5 of
--            the under / over index blobs and the palette hash, grid shape
--   input    every grid cell (mid, elevation, collision, coll, behavior,
--            layerType, category, walkable) plus width / height / kind /
--            mapType / pair / origin / layout version / ring signature
--   edge     the answers of input.outsideMidAt on the one-cell ring and of
--            input.edgeWaterBank on every cell (neighbour data the mesher reads)
--   settings (added by the caller) shadows on/off, SUN SHADOWS mode,
--            BUILD SLICING, mask plan
-- Draw range, the other OUTDOOR SPEED / LOOK switches and the grass shape do
-- not change the bytes of a record, so they are not part of the key.
local K = {}

K.FORMAT = "frpc4" -- Lab 59 v4: frpc3 = classification reads canonical art (day pixels, animation frame 0); Lab 58: SIGNS v2 descriptors (part / verts) change the record contents; v1 sign records are never reused

local function md5hex(s) return love.data.encode("string", "hex", love.data.hash("md5", s)) end
local function pack(fmt, ...) return love.data.pack("string", fmt, ...) end
local unpack_ = unpack or table.unpack

local NIL = -1e9

-- ------------------------------------------------------------------ code
-- The mod's file list (sorted): main.lua, manifest.json, every file under lib/ and assets/.
function K.listCode(mod)
  local out = { "main.lua", "manifest.json" }
  local function walk(dir)
    local okL, names = pcall(mod.list, mod, dir)
    if not okL or type(names) ~= "table" then return end
    for _, name in ipairs(names) do
      local rel = dir .. "/" .. name
      local okI, info = pcall(mod.info, mod, rel)
      if okI and info and info.type == "directory" then
        walk(rel)
      elseif info and info.type == "file" or name:sub(-4) == ".lua" then
        out[#out + 1] = rel -- every file of lib/ and assets/ (Lua, data, textures): sign textures etc. are inputs too
      end
    end
  end
  walk("lib")
  walk("assets")
  table.sort(out)
  return out
end

-- Incremental code digest. job = K.codeJob(mod); repeat done = job:step() until done.
-- One file per step (so a caller can yield between files). job.digest is set
-- when done; job.files counts the files hashed; job.bytes their total size.
local CJ = {}
CJ.__index = CJ
function K.codeJob(mod)
  return setmetatable({ mod = mod, list = K.listCode(mod), i = 0, acc = {}, files = 0, bytes = 0 }, CJ)
end
function CJ:step()
  if self.digest then return true end
  self.i = self.i + 1
  local rel = self.list[self.i]
  if rel == nil then
    self.digest = md5hex(table.concat(self.acc, "\n"))
    return true
  end
  local ok, src = pcall(self.mod.read, self.mod, rel)
  if ok and type(src) == "string" then
    self.acc[#self.acc + 1] = rel .. ":" .. #src .. ":" .. md5hex(src)
    self.files = self.files + 1
    self.bytes = self.bytes + #src
  else
    self.acc[#self.acc + 1] = rel .. ":missing"
  end
  return false
end

-- ------------------------------------------------------------------ engine
function K.engineDigest()
  local parts = {}
  local okV, Ver = pcall(require, "src.core.Version")
  if okV and type(Ver) == "table" then
    local keys = {}
    for k, v in pairs(Ver) do
      local tv = type(v)
      if tv == "string" or tv == "number" or tv == "boolean" then keys[#keys + 1] = k end
    end
    table.sort(keys)
    for _, k in ipairs(keys) do parts[#parts + 1] = k .. "=" .. tostring(Ver[k]) end
  end
  local okL, a, b, c = pcall(love.getVersion)
  if okL then parts[#parts + 1] = "love=" .. tostring(a) .. "." .. tostring(b) .. "." .. tostring(c) end
  return md5hex(table.concat(parts, ";")), #parts
end

function K.gameId()
  local ok, GV = pcall(require, "src.core.GameVersion")
  if ok and type(GV) == "table" and type(GV.get) == "function" then
    local ok2, id = pcall(GV.get)
    if ok2 and type(id) == "string" then return id end
  end
  return "frlg"
end

-- ------------------------------------------------------------------ atlas
local atlasMemo = setmetatable({}, { __mode = "k" })
-- The engine's static identity for a tileset pair. Runtime palette animation and
-- RTC repainting mutate the CPU ImageData, so the texels are not hashed; the
-- index blobs and base palettes the atlas is baked from are (this is the hash
-- tileset_native names its baked atlas files by).
function K.atlasDigest(pair)
  if not pair then return nil, "no pair" end
  local okT, NT = pcall(require, "src.core.game3.tileset_native")
  local ts = okT and type(NT) == "table" and NT._pairs and NT._pairs[pair]
  if not ts then return nil, "no native tileset" end
  local memo = atlasMemo[ts]
  if memo then return memo end
  local parts = { tostring(pair), tostring(ts.cols), tostring(ts.rows), tostring(ts.midCount),
    tostring(ts.layered and true or false) }
  if type(ts.idxBlob) ~= "string" then return nil, "no index blob" end
  parts[#parts + 1] = md5hex(ts.idxBlob)
  parts[#parts + 1] = type(ts.overBlob) == "string" and md5hex(ts.overBlob) or "-"
  -- the engine's own palette hash (32-bit FNV over palettes + index blob) plus, when the palettes are
  -- the usual tables, an md5 of the palette colours themselves
  local okP, Palette = pcall(require, "src.core.game3.palette")
  if not (okP and type(Palette) == "table" and type(Palette.hash) == "function" and ts.bgr) then return nil, "no palette hash" end
  local okH, h = pcall(Palette.hash, ts.bgr, ts.idxBlob)
  if not okH or h == nil then return nil, "palette hash failed" end
  parts[#parts + 1] = tostring(h)
  if type(ts.bgr) == "table" then
    local pal = {}
    for p = 0, (Palette.NUM_PALS_TOTAL or 16) - 1 do
      local colors = ts.bgr[p] or ts.bgr[0] or {}
      for c = 0, 15 do pal[#pal + 1] = ("%04x"):format((tonumber(colors[c]) or 0) % 65536) end
    end
    parts[#parts + 1] = md5hex(table.concat(pal))
  end
  local d = md5hex(table.concat(parts, ";"))
  atlasMemo[ts] = d
  return d
end

-- RealTimeClockTest repaints window texels of the live CPU atlas at night (ts._dnNight[mid] = the painted
-- pixels). Window detection, the glass scan and the shadow alpha read those images, so the paint state is
-- part of the key: "-" by day, else the sorted painted mids with their pixel counts. (The paint colours are
-- fixed by the day/night config, so the set of painted mids determines the painted pixels.)
function K.paintTokenOf(ts)
  local dn = ts and ts._dnNight
  if type(dn) ~= "table" or next(dn) == nil then return "-" end
  local mids = {}
  for mid, state in pairs(dn) do mids[#mids + 1] = { mid, type(state) == "table" and #state or 0 } end
  table.sort(mids, function(a, b) return tostring(a[1]) < tostring(b[1]) end)
  local parts = {}
  for i, m in ipairs(mids) do parts[i] = tostring(m[1]) .. ":" .. m[2] end
  return "n" .. md5hex(table.concat(parts, ","))
end
function K.paintToken(pair)
  local okT, NT = pcall(require, "src.core.game3.tileset_native")
  local ts = okT and type(NT) == "table" and NT._pairs and NT._pairs[pair]
  return K.paintTokenOf(ts)
end

-- ------------------------------------------------------------------ input
local function num(v)
  local tv = type(v)
  if tv == "number" then return v end
  if tv == "boolean" then return v and 1 or 0 end
  if tv == "nil" then return NIL end
  return NIL - 1
end

-- Chunked md5 chain over a stream of numbers.
local function chain(acc, buf, n)
  return md5hex(acc .. love.data.hash("md5", pack("<" .. string.rep("d", n), unpack_(buf, 1, n))))
end

-- Digest of the mesher input grid and shape. -> hex. `tick` (optional) is called
-- every few hundred cells so a build coroutine can yield.
-- Lighting classification/placement reads native warps even when grid bytes match.
-- Sort canonical rows: native event order does not change lighting semantics.
function K.warpDigest(warps)
  if warps~=nil and type(warps)~='table' then return nil,'warp metadata type' end
  local rows={}
  local function scalar(v)
    if v==nil then return 'N' end
    if type(v)=='string' then return 'S'..#v..':'..v end
    if type(v)=='number' and v==v and v~=math.huge and v~=-math.huge then
      return 'D'..string.format('%.17g',v==0 and 0 or v)..';'
    end
    return nil
  end
  for _,w in ipairs(warps or{}) do
    if type(w)~='table' then return nil,'warp metadata row' end
    local x,y,d,idx=scalar(w.x),scalar(w.y or w.z),scalar(w.destMap),scalar(w.destWarp)
    if not(x and y and d and idx) then return nil,'warp metadata scalar' end
    rows[#rows+1]=x..y..d..idx
  end
  table.sort(rows)
  return md5hex(table.concat(rows,'|'))
end
-- Lamp keepouts depend only on native event coordinates, not scripts/sprites.
function K.eventDigest(objects,bgEvents)
  local rows,seen={},{}
  for _,events in ipairs{objects or{},bgEvents or{}} do
    if type(events)~='table' then return nil,'event metadata type' end
    for _,e in ipairs(events) do
      if type(e)~='table' then return nil,'event metadata row' end
      local x,y=e.x,e.y or e.z
      if x~=nil and y~=nil then
        if type(x)~='number' or type(y)~='number' or x~=x or y~=y or math.abs(x)==math.huge or math.abs(y)==math.huge then return nil,'event metadata coordinate' end
        local row=string.format('%.17g,%.17g',x==0 and 0 or x,y==0 and 0 or y)
        if not seen[row] then seen[row]=true;rows[#rows+1]=row end
      end
    end
  end
  table.sort(rows)
  return md5hex(table.concat(rows,'|'))
end
function K.inputDigest(input, tick)
  local w, h = input.width or 0, input.height or 0
  local warps,why=K.warpDigest(input.warps)
  if not warps then return nil,why end
  local events,eventWhy=K.eventDigest(input.objects,input.bgEvents)
  if not events then return nil,eventWhy end
  local acc = md5hex(table.concat({
    tostring(input.kind), tostring(input.mapType), tostring(input.pair), tostring(input.mapId),
    w, h, tostring(input.originX or 0), tostring(input.originY or 0),
    tostring(input.isBorder and 1 or 0), tostring(input.layoutVersion), tostring(input.sig), warps, events,
  }, ";"))
  local grid = input.grid
  if type(grid) ~= "table" then return nil, "no grid" end
  local cats, ncats = {}, 0
  local buf, n = {}, 0
  local total = w * h
  for k = 1, total do
    local c = grid[k]
    if c then
      local cat = c.category
      local ci
      if cat == nil then ci = NIL
      else
        ci = cats[cat]
        if not ci then ncats = ncats + 1; ci = ncats; cats[cat] = ci end
      end
      buf[n + 1], buf[n + 2], buf[n + 3], buf[n + 4] = 1, num(c.mid), num(c.elevation), num(c.collision)
      buf[n + 5], buf[n + 6], buf[n + 7], buf[n + 8] = num(c.coll), num(c.behavior), num(c.layerType), ci
      buf[n + 9] = num(c.walkable)
      n = n + 9
    else
      n = n + 1
      buf[n] = 0
    end
    if n >= 504 then
      acc = chain(acc, buf, n)
      n = 0
      if tick then tick() end
    end
  end
  if n > 0 then acc = chain(acc, buf, n) end
  -- category names in order of first use, so equal indexes mean equal names
  local names = {}
  for name, idx in pairs(cats) do names[idx] = tostring(name) end
  acc = md5hex(acc .. table.concat(names, ","))
  return acc
end

-- Digest of what the mesher reads from the neighbourhood: outsideMidAt on the
-- ring around the map, edgeWaterBank on every cell. -> hex (never nil).
function K.connectedBuildingDigest(q, tick)
  if q==nil then return nil end -- byte-identical no-provider legacy key
  local rows={"connected-native-building-v1"}
  local function add(v)
    local t=type(v)
    if t=="number"then
      if v~=v or math.abs(v)==math.huge then v="nonfinite"else v=string.format("%.17g",v)end
    elseif t=="boolean"then v=v and "true"or "false"
    elseif t~="string"and t~="nil"then v="invalid"end
    v=tostring(v);rows[#rows+1]=t..":"..#v..":"..v
  end
  if type(q)~="table"then add(q);return md5hex(table.concat(rows,"|"))end
  for _,k in ipairs{"name","owner","pair","mapId","ownerOffsetY","minX","maxX","minY","maxY"}do add(q[k])end
  local mids={}
  local function cell(c)
    if type(c)~="table"then add("invalid-cell");return end
    for _,k in ipairs{"sourceMap","sourceX","sourceY","x","y","mid","collision","elevation","behavior","layerType","walkable","category"}do add(c[k])end
    if type(c.mid)=="number"and c.mid==math.floor(c.mid)and c.mid>=0 and c.mid<=65535 then mids[c.mid]=true end
  end
  if type(q.cells)=="table"and #q.cells==105 then
    for i=1,105 do cell(q.cells[i])end
  else add("invalid-cell-count")end
  if type(q.terrainContext)=="table"and #q.terrainContext==84 then
    for i=1,84 do cell(q.terrainContext[i])end
  else add("invalid-terrain-context")end
  cell(q.groundDonor)
  if type(q.sourceVersions)=="table"then for i=1,2 do add(q.sourceVersions[i])end else add("invalid-versions")end
  local a=q.atlas
  if type(a)~="table"then add("no-atlas")else
    local ids={};for mid in pairs(mids)do ids[#ids+1]=mid end;table.sort(ids)
    for _,mid in ipairs(ids)do
      add(mid)
      for _,layer in ipairs{"under","over"}do
        local ok,t=pcall(function()return a.texels(mid,layer)end);add(ok)
        if ok and type(t)=="table"then for i=1,256 do add(t[i])end else add("no-texels")end
        local ok,u,v,s,t=pcall(function()return (layer=="under"and a.underRect or a.overRect)(mid)end)
        add(ok);add(u);add(v);add(s);add(t)
      end
      local ok,v=pcall(function()return a.hasOver(mid)end);add(ok);add(v)
      ok,v=pcall(function()return a.overCoverage(mid)end);add(ok);add(v)
      if tick then tick()end
    end
  end
  return md5hex(table.concat(rows,"|"))
end

function K.connectedHouseDigest(q, tick)
  if q==nil then return nil end -- byte-identical no-provider legacy key
  local rows={"connected-native-house-v1"}
  local function add(v)
    local t=type(v)
    if t=="number"then
      if v~=v or math.abs(v)==math.huge then v="nonfinite"else v=string.format("%.17g",v)end
    elseif t=="boolean"then v=v and "true"or "false"
    elseif t~="string"and t~="nil"then v="invalid"end
    v=tostring(v);rows[#rows+1]=t..":"..#v..":"..v
  end
  if type(q)~="table"then add(q);return md5hex(table.concat(rows,"|"))end
  for _,k in ipairs{"name","owner","pair","mapId","ownerOffsetX","ownerOffsetY","minX","maxX","minY","maxY"}do add(q[k])end
  local mids={}
  local function cell(c)
    if type(c)~="table"then add("invalid-cell");return end
    for _,k in ipairs{"sourceMap","sourceX","sourceY","x","y","mid","collision","elevation","behavior","layerType","walkable","category"}do add(c[k])end
    if type(c.mid)=="number"and c.mid==math.floor(c.mid)and c.mid>=0 and c.mid<=65535 then mids[c.mid]=true end
  end
  if type(q.cells)=="table"and #q.cells==49 then
    for i=1,49 do cell(q.cells[i])end
  else add("invalid-cell-count")end
  cell(q.groundDonor)
  local versionsValid=type(q.sourceVersions)=="table"and #q.sourceVersions==2
  if versionsValid then for k in pairs(q.sourceVersions)do if k~=1 and k~=2 then versionsValid=false end end end
  add(versionsValid)
  if versionsValid then for i=1,2 do add(q.sourceVersions[i])end else add("invalid-versions")end
  local a=q.atlas
  if type(a)~="table"then add("no-atlas")else
    add(a.w);add(a.h)
    local ids={};for mid in pairs(mids)do ids[#ids+1]=mid end;table.sort(ids)
    for _,mid in ipairs(ids)do
      add(mid)
      for _,layer in ipairs{"under","over"}do
        local ok,t=pcall(function()return a.texels(mid,layer)end);add(ok)
        if ok and type(t)=="table"then for i=1,256 do add(t[i])end else add("no-texels")end
        local ok,u,v,s,t=pcall(function()return (layer=="under"and a.underRect or a.overRect)(mid)end)
        add(ok);add(u);add(v);add(s);add(t)
      end
      local ok,v=pcall(function()return a.hasOver(mid)end);add(ok);add(v)
      ok,v=pcall(function()return a.overCoverage(mid)end);add(ok);add(v)
      if tick then tick()end
    end
  end
  return md5hex(table.concat(rows,"|"))
end

function K.nativeTerrainBorderDigest(input,tick)
  local provider=input.nativeTerrainBorderAt
  if provider==nil then return nil end -- preserve all legacy map keys
  local rows={"native-terrain-border-v1"}
  local function add(v)
    local t=type(v)
    if t=="number" then
      if v~=v or math.abs(v)==math.huge then v="nonfinite" else v=string.format("%.17g",v) end
    elseif t=="boolean" then v=v and "true" or "false"
    elseif t~="string" and t~="nil" then v="invalid" end
    v=tostring(v);rows[#rows+1]=t..":"..#v..":"..v
  end
  add(type(provider))
  if type(provider)~="function" then return md5hex(table.concat(rows,"|")) end
  local probes=0
  local function probe(x,y)
    local ok,c=pcall(provider,x,y);add(ok);add(type(c))
    if ok and type(c)=="table" then
      for _,k in ipairs{"mid","collision","coll","elevation","behavior","layerType","walkable","category"} do add(c[k]) end
    end
    probes=probes+1;if tick and probes%32==0 then tick() end
  end
  local w,h=input.width or 0,input.height or 0
  add(w);add(h)
  for x=0,w-1 do probe(x,-1);probe(x,h) end
  for y=0,h-1 do probe(-1,y);probe(w,y) end
  return md5hex(table.concat(rows,"|"))
end

function K.edgeDigest(input, tick)
  local w, h = input.width or 0, input.height or 0
  local out, edge = input.outsideMidAt, input.edgeWaterBank
  local acc = md5hex(tostring(out ~= nil) .. tostring(edge ~= nil))
  local buf, n = {}, 0
  local function flush()
    if n > 0 then acc = chain(acc, buf, n); n = 0 end
  end
  local function add(v)
    n = n + 1
    buf[n] = num(v)
    if n >= 500 then flush(); if tick then tick() end end
  end
  if out then
    for x = 0, w do
      local ok1, a = pcall(out, x, -1)
      local ok2, b = pcall(out, x, h)
      add(ok1 and a or nil); add(ok2 and b or nil)
    end
    for y = 0, h do
      local ok1, a = pcall(out, -1, y)
      local ok2, b = pcall(out, w, y)
      add(ok1 and a or nil); add(ok2 and b or nil)
    end
  end
  if input.boundaryBorderAt then
    flush()
    acc=md5hex(acc.."nativeBoundaryBorder-v1")
    local function probe(x,y)
      local ok,mid,elev=pcall(input.boundaryBorderAt,x,y)
      add(ok and 1 or 0);add(ok and mid or nil);add(ok and elev or nil)
    end
    for x=0,w-1 do probe(x,-1);probe(x,h)end
    for y=0,h-1 do probe(-1,y);probe(w,y)end
  end
  if edge then
    for y = 0, h - 1 do
      for x = 0, w - 1 do
        local ok, v = pcall(edge, x, y)
        add(ok and v or nil)
      end
    end
  end
  flush()
  local terrainBorder=K.nativeTerrainBorderDigest(input,tick)
  if terrainBorder then acc=md5hex(acc..terrainBorder)end
  local connected=K.connectedBuildingDigest(input.connectedBuildingSource,tick)
  if connected then acc=md5hex(acc..connected)end
  local house=K.connectedHouseDigest(input.connectedHouseSource,tick)
  if house then acc=md5hex(acc..house)end
  return acc
end

function K.recordKey(parts)
  local full = table.concat(parts, "|")
  return md5hex(full), full
end

K.md5hex = md5hex

return K
