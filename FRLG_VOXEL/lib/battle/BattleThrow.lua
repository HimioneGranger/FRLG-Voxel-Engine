-- FRLG_VOXEL (W6, battle round 2): the in-battle PHYSICAL Poke Ball throw.
--
-- User requirement: catching inside battles, as in every other generation.
-- FRLG_CATCH (W5) owns the pouch -> hand -> flight -> contact physics and
-- leaves a seam for the battle presenter (FRLG_CATCH/main.lua):
--   catching.battleThrow = { active(game), targets(scale), contact(hit, ballKey), assist? }
-- This module fills it from the 3D battle:
--   * active: a 3D battle is staged (the Pokemon stand on the arena).
--   * targets: the foe's card is the throw target ("wild") while a throw can
--     be taken (BattleCatch:canThrow: the command phase, action menu up);
--     otherwise it is "blocked" (the ball bounces off, nothing is spent).
--     Your own Pokemon is always "blocked".
--   * contact: a ball reaching the foe calls BattleCatch:throw(itemId) --
--     the same command the BAG menu makes, so the engine spends the ball
--     and blocks trainer battles and the ghost itself. A refused throw
--     returns false: FRLG_CATCH returns the ball, nothing spent.
-- Targets are FreeThrow-shaped (world px = cells x 16), built the way
-- FRLG_CATCH's FreeThrow.targets builds them (same radii formula).
-- Nothing here writes game state except through BattleCatch:throw, which
-- runs from FRLG_CATCH's input.step (an input action, never a draw).
local V = ...
local _ = V

local BattleThrow = {}
BattleThrow.__index = BattleThrow

BattleThrow.PX = 16                 -- world px per cell (VRITK / FRLG_CATCH)
BattleThrow.CATCH_MOD = "FRLG_CATCH"

-- opts = { pass = BattlePass, catch = BattleCatch, findMod = fn(id) -> mod|nil,
--          engine = fn(name) -> module|nil, log }
function BattleThrow.new(opts)
  opts = opts or {}
  local self = setmetatable({ pass = opts.pass, catch = opts.catch, findMod = opts.findMod,
    engine = opts.engine, log = opts.log or print, proxies = {}, installedOn = nil,
    contacts = 0, accepted = 0, refused = 0, lastRefusal = nil }, BattleThrow)
  self.seam = {
    active = function(game) return self:active(game) end,
    targets = function(scale) return self:targets(scale) end,
    contact = function(hit, ballKey) return self:contact(hit, ballKey) end,
    -- battle-ui (2026-10-01): the user's own catch presentation (FRLG_CATCH BattleCaptureFX)
    result = function() return self:result() end,
    advanceThrowText = function() return self:advanceThrowText() end,
    visual = function(state) return self:setVisual(state) end,
    subject = function(slotId) return self:subject(slotId) end,
    lastThrow = function() return self:lastThrowInfo() end,
  }
  return self
end

-- ------------------------------------------------------------ battle-ui: the user's catch presentation
-- The engine's live catch result for the last VR throw (read-only; BattleCatch:catchResult).
function BattleThrow:result()
  if not (self.catch and self.catch.catchResult) then return nil end
  local ok, r = pcall(self.catch.catchResult, self.catch)
  return ok and r or nil
end

-- Advance the engine's "used POKe BALL!" line (BattleCatch:advanceThrowText; input.step only).
function BattleThrow:advanceThrowText()
  if not (self:active() and self.catch and self.catch.advanceThrowText) then return false end
  local ok, done = pcall(self.catch.advanceThrowText, self.catch)
  return ok and done == true
end

-- What the last accepted throw was (kind "bag"/"safari", blockedBy "trainer"/"ghost"/nil, item id).
function BattleThrow:lastThrowInfo()
  local t = self.lastThrow
  if not t then return nil end
  local info = type(t.info) == "table" and t.info or {}
  return { ball = t.ball, item = t.item, kind = info.kind, blockedBy = info.blockedBy, serial = self.accepted }
end

-- FRLG_CATCH reports who owns the foe's picture while its presentation runs: { serial, slot, foe =
-- "hide"|"show"|nil, nativeBall = false } or nil when it is over. BattlePass reads it (visualState) and drops a
-- state that has not been renewed for STALE_S (a stopped catch mod can never leave a Pokemon hidden).
BattleThrow.STALE_S = 0.6
function BattleThrow:setVisual(state)
  if type(state) == "table" then
    self.visual = { serial = state.serial, slot = tonumber(state.slot) or 1, foe = state.foe,
      nativeBall = state.nativeBall ~= false and true or false }
    self.visualAt = (love and love.timer and love.timer.getTime and love.timer.getTime()) or os.clock()
  else
    self.visual, self.visualAt = nil, nil
  end
  return true
end

function BattleThrow:visualState()
  local v = self.visual
  if not v then return nil end
  local now = (love and love.timer and love.timer.getTime and love.timer.getTime()) or os.clock()
  if not self.visualAt or now - self.visualAt > BattleThrow.STALE_S then
    self.visual, self.visualAt = nil, nil
    return nil
  end
  return v
end

-- A copy of battler `slotId`'s 3D card (its picture canvas as drawn this frame, and the card's world-px quad
-- facing the seat), for the presentation's red intake. The copy is the caller's (owned = true). input.step only
-- (it renders to a new canvas; never called inside an eye pass).
function BattleThrow:subject(slotId)
  local p = self.pass
  if not (p and p.cards and self:active()) then return nil end
  local id = tonumber(slotId) or 1
  local src = p.cards.battler and p.cards.battler[id]
  local slot
  for _, s in ipairs(p.throwSlots or {}) do if s.id == id then slot = s end end
  if not (src and slot and love and love.graphics) then return nil end
  local w, h = src:getDimensions()
  local okC, copy = pcall(love.graphics.newCanvas, w, h, { dpiscale = 1 })
  if not (okC and copy) then return nil end
  copy:setFilter("nearest", "nearest")
  local g = love.graphics
  g.push("all")
  local okD = pcall(function()
    g.setCanvas(copy)
    g.origin(); g.setScissor(); g.setShader()
    g.clear(0, 0, 0, 0)
    g.setBlendMode("alpha", "premultiplied")
    g.setColor(1, 1, 1, 1)
    g.draw(src, 0, 0)
  end)
  g.pop()
  if not okD then pcall(copy.release, copy); return nil end
  local PX = BattleThrow.PX
  local ppc = p.picPxPerCell and p:picPxPerCell() or 56
  local wc, hc = w / ppc, h / ppc
  local base = (slot.ground or 0) + 0.01 -- BattleCards.GROUND_EPS
  local eye = BattleThrow.eyeOf(p)
  local yaw = 0
  if eye and eye.x and eye.z then yaw = math.atan2(eye.x - slot.x, eye.z - slot.z) end
  return { texture = copy, owned = true, w = wc * PX, h = hc * PX,
    center = { slot.x * PX, (base + hc / 2) * PX, slot.z * PX }, yaw = yaw }
end

-- Where the player is (world cells): the walked eye while battle movement is on (BattlePass:eyeWorld),
-- else the seat anchor as before, else the stage's seat.
function BattleThrow.eyeOf(p)
  local moved = p and p.eyeWorld and p:eyeWorld() or nil
  if moved then return { x = moved.x, z = moved.z } end
  local seat = p and p.camera and p.camera.seat
  return seat and { x = seat.x, z = seat.z } or (p and p.stage and p.stage.seat)
end

-- Installs the seam on FRLG_CATCH's catching object (idempotent; re-installs
-- when that object changes, e.g. a mod reload). Returns true when installed.
function BattleThrow:install()
  local find = self.findMod
  if type(find) ~= "function" then return false end
  local ok, m = pcall(find, BattleThrow.CATCH_MOD)
  local ex = ok and type(m) == "table" and m.exports or nil
  local c = type(ex) == "table" and ex.catching or nil
  if type(c) ~= "table" then return false end
  if c.battleThrow ~= self.seam then
    c.battleThrow = self.seam
    if self.installedOn ~= c then
      self.installedOn = c
      self.log("[FRLG_VOXEL] in-battle ball throw seam installed on " .. BattleThrow.CATCH_MOD)
    end
  end
  return true
end

function BattleThrow:active(_game)
  local p = self.pass
  if not (p and p.stage and (p.state == "seated" or p.state == "fadein")) then return false end
  local ok, on = pcall(p.source.active, p.source)
  return ok and on == true
end

local function proxy(self, id)
  local e = self.proxies[id]
  if not e then
    e = { battleSlot = id, id = "battle:" .. id }
    self.proxies[id] = e
  end
  return e
end

local function unit(x, y, z)
  local n = math.sqrt(x * x + y * y + z * z)
  if n < 1e-8 then return 0, 0, 0 end
  return x / n, y / n, z / n
end

-- Pure: FreeThrow-shaped target for a slot (cells) seen from `eye` (cells).
-- slot = { x, z, ground, topPx, w (cells) }, ppc = picture px per cell.
function BattleThrow.targetFor(slot, eye, kind, entity, scale, ppc)
  local PX = BattleThrow.PX
  local wCells = slot.w or 1
  local hCells = (tonumber(slot.topPx) or ppc) / ppc
  local cx, cy, cz = slot.x * PX, ((slot.ground or 0) + hCells / 2) * PX, slot.z * PX
  local nx, _, nz = unit((eye and eye.x or slot.x) * PX - cx, 0, (eye and eye.z or slot.z + 1) * PX - cz)
  if nx == 0 and nz == 0 then nz = 1 end
  local w, h = wCells * PX, hCells * PX
  scale = tonumber(scale) or 10
  return { entity = entity, kind = kind, center = { cx, cy, cz }, normal = { nx, 0, nz },
    right = { nz, 0, -nx },
    radii = { math.max(2, math.min(48, w)) * .5 + scale * .168,
              math.max(2, math.min(48, h)) * .5 + scale * .168, scale * .198 } }
end

-- FreeThrow targets for FRLG_CATCH (world px). Empty when no battle is staged.
function BattleThrow:targets(scale)
  if not self:active() then return {} end
  local p = self.pass
  local slots = p.throwSlots
  if type(slots) ~= "table" then return {} end
  local canThrow = false
  if self.catch then
    local fn = self.catch.window or self.catch.canThrow
    local ok, can, why = pcall(fn, self.catch)
    canThrow = ok and can == true
    self.lastWindow = canThrow and 'open' or tostring(ok and why or can)
  end
  local eye = BattleThrow.eyeOf(p)
  local ppc = p.picPxPerCell and p:picPxPerCell() or 64
  local out = {}
  for _, s in ipairs(slots) do
    if s.visible then
      local foe = (s.id % 2 == 1)
      local kind = (foe and canThrow) and "wild" or "blocked"
      out[#out + 1] = BattleThrow.targetFor(s, eye, kind, proxy(self, s.id), scale, ppc)
    end
  end
  return out
end

-- Item id of a ball key ("POKE_BALL", "MASTER_BALL", ... or a number).
function BattleThrow:itemId(ballKey)
  if type(ballKey) == "number" then return ballKey end
  local engine = self.engine or function(name)
    local ok, m = pcall(require, name)
    return ok and type(m) == "table" and m or nil
  end
  local ItemsData = engine("src.core.game3.items_data")
  if ItemsData and ItemsData.toNumericId then
    local ok, n = pcall(ItemsData.toNumericId, ballKey)
    if ok and tonumber(n) and tonumber(n) > 0 then return tonumber(n) end
  end
  return nil
end

-- A ball reached a battle target. Accepted only for a foe card while a
-- throw can be taken; the engine then spends the ball and plays the throw.
function BattleThrow:contact(hit, ballKey)
  self.contacts = self.contacts + 1
  local e = type(hit) == "table" and hit.entity or nil
  local function refuse(why)
    self.refused = self.refused + 1
    self.lastRefusal = why
    return false
  end
  if type(e) ~= "table" or e.battleSlot == nil then return refuse("not a battle target") end
  if e.battleSlot % 2 == 0 then return refuse("your own Pokemon") end
  if not self:active() then return refuse("no 3D battle") end
  if not self.catch then return refuse("no catch seam") end
  local id = self:itemId(ballKey)
  if ballKey == "SAFARI_BALL" then id = nil end -- the Safari command takes no item id
  if not id and ballKey ~= "SAFARI_BALL" then return refuse("unknown ball " .. tostring(ballKey)) end
  local ok, done, info = pcall(self.catch.throw, self.catch, id)
  if not ok then return refuse("error: " .. tostring(done)) end
  if not done then return refuse(tostring(info)) end
  self.accepted = self.accepted + 1
  self.lastThrow = { ball = ballKey, item = id, info = info }
  return true
end

function BattleThrow:status()
  return { installed = self.installedOn ~= nil, window = self.lastWindow,
    contacts = self.contacts, accepted = self.accepted,
    refused = self.refused, lastRefusal = self.lastRefusal,
    lastThrow = self.lastThrow and { ball = self.lastThrow.ball, item = self.lastThrow.item } or nil,
    path = self.catch and self.catch.path or nil }
end

return BattleThrow
