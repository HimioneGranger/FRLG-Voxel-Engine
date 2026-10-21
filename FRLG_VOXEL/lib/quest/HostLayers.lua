-- FRLG_VOXEL: the vrHost layer registry (DESIGN.md 2a "Layers", W4 phase P1).
--
-- Shape and rules copied from the Gen2 host's QuestStereoLayers (see
-- vritk-hook/reading-vritk-hosts.md 2c and CRITIQUE.md #6/#7/#12):
--   register(id, layer) / unregister(id, layer?) / debugState()
--   layer = { update = fun(ctx) -> record|nil, draw = fun(record, eye),
--             invalidate = fun()|nil, desktop = bool|nil }
--
-- Contract this module enforces (not just documents):
--   * update() runs at most once per layer per world frame, in sorted-id
--     order, each call pcall'd. A non-nil return becomes that layer's draw
--     record for this frame; a nil return (or an error) skips draw for it.
--   * draw() runs once per eye, in the SAME sorted-id order, each call
--     wrapped in push("all")/pcall/pop with the graphics stack depth checked
--     before and after, so a throwing layer can never leave a level pushed
--     or the eye canvas in an unknown state (CRITIQUE #7's "observation-only"
--     concern is about *what* a layer does in draw, not this module's own
--     exception safety, which is unconditional).
--   * Three consecutive pcall failures for a layer (counting update and
--     draw together) mark it failed=true; a failed layer is skipped (no
--     update, no draw) until it calls register() again, which clears the
--     counter (CRITIQUE: "three consecutive errors mark a layer failed").
--   * HostLayers:draw() itself never raises, even if every layer throws --
--     callers (eventually View.lua, see w4/WIRING_PLAN.md) can rely on that
--     to keep drawing the UI card and veil after the layer slot without an
--     extra pcall of their own.
--   * invalidate(): called by HostLayers:invalidateAll(reason) (stereo off,
--     session stop/teardown, camera mode change -- CRITIQUE #8) and from
--     unregister(). Never called from inside update()/draw().
--
-- No love.* calls are hard-required: a `graphics` table with push/pop/
-- getStackDepth is injected (defaults to love.graphics when present, else a
-- harmless no-op stack), so this file loads and its logic runs under plain
-- LuaJIT tests with no love/package/debug in scope.
local V = ...
local _ = V

local HostLayers = {}
HostLayers.__index = HostLayers

HostLayers.MAX_CONSECUTIVE_ERRORS = 3

-- A graphics stack that does nothing but stays internally consistent, for
-- headless/test use when no love.graphics is available.
local function noopGraphics()
  local depth = 0
  return {
    push = function() depth = depth + 1 end,
    pop = function() if depth > 0 then depth = depth - 1 end end,
    getStackDepth = function() return depth end,
  }
end

local function defaultGraphics()
  -- Bare `love`, not _G.love: referencing an undefined global never raises
  -- in Lua (only indexing one does), and a bare identifier resolves
  -- correctly through any sandboxed _ENV whether or not that sandbox
  -- also aliases _G to itself (the real src/mods/Sandbox.lua does; test
  -- mocks are not required to and not every one does).
  if love and love.graphics then return love.graphics end
  return noopGraphics()
end

-- opts = { log = fun(msg), graphics = { push, pop, getStackDepth } }
function HostLayers.new(opts)
  opts = opts or {}
  return setmetatable({
    log = opts.log or function() end,
    graphics = opts.graphics or defaultGraphics(),
    order = {},      -- sorted array of ids
    byId = {},        -- id -> entry
    frameRecords = {}, -- id -> this frame's update() result (cleared each update())
    frameId = 0,
  }, HostLayers)
end

local function resort(self)
  local order = {}
  for id in pairs(self.byId) do order[#order + 1] = id end
  table.sort(order)
  self.order = order
end

-- register(id, layer) -> true | false, err
-- layer needs update and draw functions (invalidate and desktop are
-- optional). Re-registering an id invalidates and replaces the old entry
-- and resets its error state, matching the Gen2 registry.
function HostLayers:register(id, layer)
  if type(id) ~= "string" or id == "" then return false, "bad id" end
  if type(layer) ~= "table" or type(layer.update) ~= "function"
      or type(layer.draw) ~= "function" then
    return false, "layer needs update() and draw()"
  end
  local old = self.byId[id]
  if old then
    local ok, err = pcall(old.layer.invalidate or function() end)
    if not ok then self.log("[HostLayers] " .. id .. " invalidate (replace) failed: " .. tostring(err)) end
  end
  self.byId[id] = { id = id, layer = layer, failed = false, consecutiveErrors = 0,
    lastError = nil, record = nil }
  resort(self)
  return true
end

-- unregister(id, layer?) -> bool. layer, when given, must match the
-- currently registered one (Gen2 semantics); invalidate always runs first.
function HostLayers:unregister(id, layer)
  local e = self.byId[id]
  if not e then return false end
  if layer ~= nil and e.layer ~= layer then return false end
  local ok, err = pcall(e.layer.invalidate or function() end)
  if not ok then self.log("[HostLayers] " .. id .. " invalidate (unregister) failed: " .. tostring(err)) end
  self.byId[id] = nil
  self.frameRecords[id] = nil
  resort(self)
  return true
end

function HostLayers:debugState()
  local layers = {}
  for _, id in ipairs(self.order) do
    local e = self.byId[id]
    layers[#layers + 1] = { id = id, failed = e.failed,
      consecutiveErrors = e.consecutiveErrors, lastError = e.lastError }
  end
  return { api = 1, layers = layers }
end

local function noteSuccess(e)
  e.consecutiveErrors = 0
end

local function noteError(self, e, err)
  e.consecutiveErrors = e.consecutiveErrors + 1
  e.lastError = tostring(err)
  if e.consecutiveErrors >= HostLayers.MAX_CONSECUTIVE_ERRORS then
    e.failed = true
    self.log(("[HostLayers] %s disabled after %d consecutive errors: %s")
      :format(e.id, e.consecutiveErrors, e.lastError))
  end
end

-- Once per stereo world frame, after view:prepare succeeds (see
-- w4/WIRING_PLAN.md). Never runs on panel frames. ctx is opaque to this
-- module (HostApi builds it); it is only ever read by layers, never by us.
function HostLayers:update(ctx)
  self.frameId = self.frameId + 1
  for _, id in ipairs(self.order) do
    local e = self.byId[id]
    self.frameRecords[id] = nil
    if not e.failed then
      -- Optional pacer observer: the existing callback pcall stays authoritative.
      -- Diagnostic failures must never alter layer failures or returned records.
      local observer = self._pacerUpdateTiming
      local started, token
      if observer then
        local timed, t0, frame = pcall(observer.clock, id)
        if timed then started, token = t0, frame end
      end
      local ok, record = pcall(e.layer.update, ctx)
      if observer and type(started) == "number" then
        pcall(observer.sample, id, started, token, ok)
      end
      if ok then
        noteSuccess(e)
        if record ~= nil then self.frameRecords[id] = record end
      else
        noteError(self, e, record)
      end
    end
  end
end

-- Once per eye, in the same sorted-id order as update(). eye is opaque to
-- this module and just relayed to each layer's draw(record, eye). Layers
-- with no record from this frame's update() (nil return, error, or
-- disabled) are skipped. This method never raises.
function HostLayers:draw(eye)
  local g = self.graphics
  for _, id in ipairs(self.order) do
    local e = self.byId[id]
    local record = self.frameRecords[id]
    if not e.failed and record ~= nil then
      local okDepth, before = pcall(g.getStackDepth)
      pcall(g.push, "all")
      local ok, err = pcall(e.layer.draw, record, eye)
      pcall(g.pop)
      if okDepth then
        local okAfter, after = pcall(g.getStackDepth)
        if okAfter and after ~= before then
          -- Defensive unwind: a layer that pushed without a matching pop
          -- (inside its own pcall'd draw, which should be impossible given
          -- the push/pop above, but a broken graphics mock or a future
          -- love.graphics change could still surface it) must not leak a
          -- stack level into the card/veil drawn after this slot.
          local guard = 0
          while after > before and guard < 64 do
            pcall(g.pop)
            local okA2, a2 = pcall(g.getStackDepth)
            if not okA2 then break end
            after = a2
            guard = guard + 1
          end
        end
      end
      if ok then
        noteSuccess(e)
      else
        noteError(self, e, err)
      end
    end
  end
end

-- Called at lifecycle edges (CRITIQUE #8): explicit toggle off, session
-- stop/teardown, camera mode change, or the "more than 2 s continuous
-- flat" timeout HostApi tracks. Never for a transient flat frame (heal
-- machine, itemfinder, a menu opening, "building").
function HostLayers:invalidateAll(reason)
  for _, id in ipairs(self.order) do
    local e = self.byId[id]
    local ok, err = pcall(e.layer.invalidate or function() end)
    if not ok then
      self.log("[HostLayers] " .. id .. " invalidate failed: " .. tostring(err))
    end
    self.frameRecords[id] = nil
  end
  local _ = reason
end

return HostLayers
