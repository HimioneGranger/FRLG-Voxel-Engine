-- VRITK_FRLG_HOST compat (Gen 3 only, Wilds of Hoenn as the overworld provider): reserved slots for water Pokemon.
-- Gen-specific compat layer (user rule 2026-10-10: all VR changes live in the compat layer). Wilds fills the land spawns
-- first, and the host caps the total number of live wild Pokemon (WildsHostCompat, 8). On a land-rich route land alone
-- wants the whole cap, so water Pokemon would never get a place even when water cells are eligible. This part keeps up to
-- `slots` (default 3) places free for water: land may fill at most cap - reserve, where
--     reserve = max(0, min(slots, spawns wanted on the eligible water cells) - water spawns alive).
-- Water cells are only eligible when Wilds says so (water reachable with Surf, or the Water Pokemon Without Surf option),
-- so a route with no eligible water has reserve 0 and every call goes straight to the previous method: no extra draws,
-- no change at all (inland maps are unchanged, RNG for RNG).
--
-- What it wraps (instance fields of the live SpawnManager, restored by uninstall()):
--   refill(terrain)      "land": skips the call when count + reserve >= cap, else runs it with the limit armed
--   _spawnOne(terrain)   "land" while a refill is running: stops the refill the moment count + reserve >= cap
-- "water" is never limited here (the host cap still applies to it through the wrappers underneath).
-- The wanted-water number is cached per (cell scan, reachable set) so the steady state allocates nothing.
--
-- ctx = { spawnManager = live SpawnManager, cap = function() -> number|nil (total cap), slots = function() -> number,
--         log = function(fmt, ...) }
local M = {}

local pcall, error, type, rawget, math_min, math_floor = pcall, error, type, rawget, math.min, math.floor

local S -- installed state

local STOP = {} -- thrown by the _spawnOne wrapper while a land refill runs, swallowed by the refill wrapper

local function say(st, fmt, ...)
  if st.log then pcall(st.log, fmt, ...) end
end

-- spawns wanted on the eligible water cells (0 when none); cached until the cell scan or the reachable set changes
local function wanted(st, sm)
  local src = sm.source
  if type(src) ~= "table" then return 0 end
  local cells, reach = src.cells, src.reachable
  local c = st.cache
  local range = st.shoreRange and st.shoreRange() or nil
  if c.cells == cells and c.reach == reach and c.shore == src.shore and c.range == range and c.map == sm.mapId and c.have then return c.n end
  c.cells, c.reach, c.shore, c.range, c.map, c.have = cells, reach, src.shore, range, sm.mapId, true
  local n = 0
  local ok, list = pcall(src.eligibleCells, src, "water")
  if ok and type(list) == "table" then n = #list end
  if n > 0 and type(st.target) == "function" then
    local okT, w = pcall(st.target, n)
    n = (okT and type(w) == "number") and w or 0
  elseif n > 0 then
    n = 1
  end
  c.n = n
  return n
end

-- places to keep free for water right now
local function reserve(st, sm)
  local slots = st.slots()
  if type(slots) ~= "number" or slots < 1 then return 0 end
  local want = wanted(st, sm)
  if want <= 0 then return 0 end
  local quota = math_min(math_floor(slots), want)
  local alive = sm:_activeCountFor("water")
  local r = quota - alive
  if r < 0 then return 0 end
  return r
end

function M.install(ctx)
  if S then
    if ctx and ctx.spawnManager == S.sm then return true, "already installed" end
    M.uninstall()
  end
  if type(ctx) ~= "table" or type(ctx.spawnManager) ~= "table" then return false, "no spawn manager" end
  local sm = ctx.spawnManager
  for _, k in ipairs({ "refill", "_spawnOne", "count", "_activeCountFor" }) do
    if type(sm[k]) ~= "function" then return false, "spawn manager lacks " .. k end
  end
  if type(ctx.cap) ~= "function" then return false, "no cap function" end
  local st = {
    sm = sm, cap = ctx.cap, log = ctx.log, cache = {}, shoreRange = ctx.shoreRange,
    slots = type(ctx.slots) == "function" and ctx.slots or function() return 3 end,
    target = type(sm._targetCount) == "function" and sm._targetCount or nil,
    inLand = false, restore = {}, trims = 0, skipped = 0,
  }
  local prevRefill, prevSpawn = sm.refill, sm._spawnOne
  local ownRefill, ownSpawn = rawget(sm, "refill"), rawget(sm, "_spawnOne")

  local function limit(self)
    local cap = st.cap()
    if type(cap) ~= "number" then return nil end
    local r = reserve(st, self)
    if r <= 0 then return nil end
    return cap - r
  end

  local refill = function(self, terrain, ...)
    if S ~= st or self ~= sm or terrain ~= "land" then return prevRefill(self, terrain, ...) end
    local lim = limit(self)
    if not lim then return prevRefill(self, terrain, ...) end
    if self:count() >= lim then st.skipped = st.skipped + 1; return end
    local was = st.inLand
    st.inLand = true
    st.lim = lim
    local ok, err = pcall(prevRefill, self, terrain, ...)
    st.inLand = was
    if not ok and err ~= STOP then error(err, 0) end
  end
  local spawnOne = function(self, terrain, cell)
    if S == st and self == sm and st.inLand and terrain == "land" and self:count() >= st.lim then
      st.trims = st.trims + 1
      error(STOP, 0)
    end
    return prevSpawn(self, terrain, cell)
  end
  sm.refill, sm._spawnOne = refill, spawnOne
  st.restore = { refill = refill, spawn = spawnOne, ownRefill = ownRefill, ownSpawn = ownSpawn }
  S = st
  return true, "installed"
end

function M.uninstall()
  local st = S
  if not st then return true, "not installed" end
  S = nil
  local sm, r = st.sm, st.restore
  local left = {}
  if rawget(sm, "refill") == r.refill then sm.refill = r.ownRefill else left[#left + 1] = "refill" end
  if rawget(sm, "_spawnOne") == r.spawn then sm._spawnOne = r.ownSpawn else left[#left + 1] = "_spawnOne" end
  if #left > 0 then return true, "left in place (wrapped by others, now inert): " .. table.concat(left, ",") end
  return true, "uninstalled"
end

function M.status()
  local st = S
  if not st then return { installed = false } end
  return { installed = true, trims = st.trims, skipped = st.skipped, wantedWater = st.cache.n or 0 }
end

return M
