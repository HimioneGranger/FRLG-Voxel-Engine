-- Gen3-only Pokedex scanner (tablet) behaviour, 2026-10-02. User decision:
-- "Live camera view a short scan pause then it transition to the pokedex
-- entry". VRITK's own scanner files stay as they are (standing rule
-- 2026-09-28); this module changes them on FireRed/Emerald only, through the
-- two seams this host already owns:
--   installCamera(vkV)  -- compat.install (VR_INTERACTIONS_BACKPACK_LAB
--                          main.lua mods.loaded): VRITK's module tables
--     QuestPokedexCamera.update   live feed at FRAME_INTERVAL (Gen2: 1/8 s)
--     QuestPokedexCamera.snapshot the "locked" hold lasts LOCK_SECONDS
--                                 (Gen2: 0.5 s) before the entry opens
--     (installBridge) bridge.cameraWindow + scanUI.drawSpriteWindow: the tablet
--                                 camera fills the screen while a scan looks
--     QuestWatchPokedex.KEEP_VOICE / TAKEOVER  (new, Lab 59) the wrist scan's
--                                 voice keeps playing after the squeeze is released
--     QuestWearableInteraction.watchScanEdgeRay  (new, Lab 57) the wrist scan
--                                 leaves the TOP EDGE of the watch face
--     QuestPokedexScan._startNarration  narration also plays for uncaught species
--   installBridge(component, interaction, bridge) -- Gen3TabletCompat.install
--     bridge:openPokedex  numeric species id lookup (kanto_gear's Gen3 dex is
--                         keyed by the engine species id, gen3.lua
--                         refreshDefinitions); the shared method only accepts
--                         Gen1/Gen2 name keys, so FireRed got "POKEDEX APP
--                         UNAVAILABLE".
-- Missing species: Gen1/Gen2 scanning never registers a species (the Wilds
-- scanPokemon is read-only; FRLG_CATCH's DexScan is too), and FireRed's own
-- Pokedex has no entry for a species that was never seen. So a scan of an
-- unseen species still opens its page (the transition happens), but the page
-- shows UNKNOWN: name, kind, size, types and text are hidden and the Gear
-- draws its dark unseen silhouette. Nothing is written to the save.
-- uninstall() puts every table back (core.quit_to_launcher).
local M = {}

M.FRAME_INTERVAL = 0.05      -- live viewfinder: every 4th frame at 72 Hz, 5th at 90 Hz = 18 fps
M.LOCK_SECONDS = 0.9         -- scan pause after the target locks (s)
M.UNKNOWN_NAME = "UNKNOWN"
M.UNKNOWN_TEXT = { "UNKNOWN POKEMON.", "NOT IN YOUR POKEDEX YET." }

local state = { camera = nil, scan = nil, model = nil, redact = nil, edge = nil, voice = nil,
  bridges = setmetatable({}, { __mode = "k" }) }

-- Same binding access as KantoGearSurfaceBridge's own read/write (get/set
-- objects; the upvalue form only where `debug` exists -- not in the mod sandbox).
local function read(binding)
  if not binding then return nil end
  if type(binding.get) == "function" then return binding:get() end
  if debug and debug.getupvalue and binding.fn then
    local _, value = debug.getupvalue(binding.fn, binding.index)
    return value
  end
  return nil
end
local function write(binding, value)
  if not binding then return false end
  if type(binding.set) == "function" then return binding:set(value) end
  if not (debug and debug.setupvalue and binding.fn) then return false end
  return debug.setupvalue(binding.fn, binding.index, value) ~= nil
end

------------------------------------------------------------ unknown page
local function copy(t)
  local out = {}
  for k, v in pairs(t or {}) do out[k] = v end
  return out
end

function M.redactModel(model)
  if type(model) ~= "table" then return model end
  local out = copy(model)
  local mon = copy(model.pokemon)
  mon.name = M.UNKNOWN_NAME
  mon.kind, mon.height, mon.weight = nil, nil, nil
  mon.heightValue, mon.weightValue = nil, nil
  mon.type, mon.type2, mon.typeLabel, mon.type2Label = nil, nil, nil, nil
  mon.types, mon.weak, mon.resist = {}, {}, {}
  mon.description, mon.descriptionText = copy(M.UNKNOWN_TEXT), nil
  mon.dvs, mon.seen, mon.caught = nil, false, false
  out.pokemon = mon
  out.statsText, out.habitatText, out.movesText = "?", "?", "?"
  out.view = "profile"
  out.gen3Unknown = true
  return out
end

local function stillUnknown(runtime, species)
  local ok, data = pcall(runtime.pokedexData)
  local row = ok and type(data) == "table" and type(data.bySpecies) == "table" and data.bySpecies[species]
  return not (row and row.caught == true)
end

local function unwrapModel()
  local w = state.model
  if w and rawget(w.runtime, "pokedexModel") == w.fn then rawset(w.runtime, "pokedexModel", w.raw) end
  state.model = nil
end

local function wrapModel(runtime)
  if state.model and state.model.runtime == runtime then return true end
  unwrapModel()
  local raw = rawget(runtime, "pokedexModel")
  if type(raw) ~= "function" then return false end
  local fn
  fn = function(...)
    local dex=runtime.pokedex
    if type(dex)=='table' and dex.view~='index' and stillUnknown(runtime,dex.selected) then
      return M.redactModel(raw(...))
    end

    return raw(...)
  end
  rawset(runtime, "pokedexModel", fn)
  state.model = { runtime = runtime, raw = raw, fn = fn }
  return true
end

------------------------------------------------------------ openPokedex
-- entry = a scan entry (FRLG_CATCH DexScan.entry: species = name string,
-- speciesId = engine id) or a Gear row (openPokedexCamera: species = id).
-- Gen1/Gen2-shaped entries (string species, no speciesId) go to the shared
-- method unchanged.
function M.openPokedex(bridge, entry, original)
  if type(entry) ~= "table" then return false end
  local scanned = tonumber(entry.speciesId)
  local id = scanned or (type(entry.species) == "number" and entry.species or nil)
  if not id then return original(bridge, entry) end
  local b = bridge.bindings or {}
  if not bridge.available or read(b.active) ~= true or read(b.screenMode) ~= "active" then return false end
  local runtime = read(b.displayRuntime)
  if type(runtime) ~= "table" or type(runtime.pokedexData) ~= "function"
      or type(runtime.pokedex) ~= "table" then return false end
  local ok, data = pcall(runtime.pokedexData)
  if not ok or type(data) ~= "table" or type(data.bySpecies) ~= "table" then return false end
  local row = data.bySpecies[id]
  local known = row ~= nil and row.caught == true
  if scanned and not known then
    -- Hide visual identification while keeping the authoritative dex number for narration.
    entry.gen3Unknown, entry.name = true, M.UNKNOWN_NAME
  end
  if not row then
    -- not in the current Pokedex at all (e.g. outside the regional dex):
    -- there is no page to open; the scan ends as UNKNOWN on the camera page
    return scanned ~= nil
  end
  if not write(b.page, "POKEDEX") then return false end
  runtime.pokedex.selected, runtime.pokedex.view = id, "profile"
  runtime.pokedex.habitatPage, runtime.pokedex.movePage = 1, 1
  wrapModel(runtime) -- retain caught-only redaction when navigating tablet pages
  if scanned then
    state.redact = (not known) and wrapModel(runtime) and { runtime = runtime, species = id } or nil
  end
  write(b.dirty, true)
  bridge.watchViewportCache = nil
  bridge.refreshPending, bridge.nextRefreshAt = true, 0
  return true
end

------------------------------------------------------------ full-screen camera (add-on)
-- User, 2026-10-10: "the camera feed on the tablet needs to be larger" -> fill
-- the screen: while a scan is looking (UI phase scanning or locked) the live
-- feed covers the whole 240x216 tablet screen and the scan text sits on top of
-- it. Everything is the Gear surface bridge's own camera path with a different
-- window: the bridge asks bridge:cameraWindow() for the rectangle, scissors to
-- it (scaled by the presentation scale, so 0,0,720,648 at 3x), fills it dark,
-- draws the frame aspect-fitted (320x288 into 240x216 = 0.75, exact) and then
-- calls scanUI:drawSpriteWindow over it. This module replaces those two INSTANCE
-- methods (cameraWindow on the bridge, drawSpriteWindow on its scanUI); Gen1/Gen2
-- never get here. After the lock (crying, speaking, complete, error) and whenever
-- there is no frame yet, the original portrait window is used, so the Pokedex
-- entry stays readable. CAMERA_FILL = false restores the portrait window.
M.CAMERA_FILL = true
M.FILL_W, M.FILL_H = 240, 216    -- the Gear canvas the window is defined on
M.STRIP_TOP, M.STRIP_BOTTOM = 56, 44   -- darkened bands (display px of 216) behind the labels
M.STRIP_ALPHA = 0.38

-- The scan UI's camera-phase art (QuestPokedexScanUI:draw, its cameraPhase
-- branch: tint, border, target ring, progress ticks, the linked labels with
-- their opaque dark panels) drawn without allocating. QuestPokedexScanUI:draw
-- builds five closures and a few strings on every call; this is the same
-- sequence of draw calls for the 240x216 Gear canvas (scale 1), with the
-- strings built once per change. The fixture (layout_fill58) records both and
-- requires identical draw calls. Fonts and colours are the UI's own.
local TICKS = {}
for i = 0, 23 do
  local angle = i * math.pi / 12
  TICKS[i + 1] = { math.cos(angle), math.sin(angle) }
end
local fillCache = setmetatable({}, { __mode = "k" })
local function cyan(g, a) g.setColor(.08, .91, .98, a or 1) end
local function box(g, mode, x, y, w, h, r) g.rectangle(mode, x, y, w, h, r or 0, r or 0) end
local function fit(g, font, value, x, y, maxW, maxH)
  local scale = math.min(1, maxH / font:getHeight())
  if font:getWidth(value) * scale > maxW then
    while #value > 0 and font:getWidth(value .. "...") * scale > maxW do
      local last = #value
      while last > 1 and value:byte(last) >= 128 and value:byte(last) < 192 do last = last - 1 end
      value = value:sub(1, last - 1)
    end
    value = value .. "..."
  end
  g.print(value, x, y, 0, scale, scale)
end
local function label(g, font, value, x, y, w)
  g.setColor(.015, .105, .13, 1)
  box(g, "fill", x, y, w, 20, 2)
  cyan(g, .85); box(g, "line", x, y, w, 20, 2)
  g.setColor(.96, 1, 1, 1); fit(g, font, value, x + 6, y + 4, w - 12, 12)
end
-- the name (with its gender marker) and the level text change only with the scan state
local function strings(ui, font)
  local c = fillCache[ui]
  if not c then c = {}; fillCache[ui] = c end
  if c.name ~= ui.name or c.gender ~= ui.gender or c.font ~= font then
    c.name, c.gender, c.font, c.display = ui.name, ui.gender, font, nil
    if ui.name then
      local marker = ui.gender and " (" .. ui.gender .. ")" or ""
      if ui.gender and type(font.hasGlyphs) == "function" then
        local glyph = ui.gender == "M" and "\226\153\130" or "\226\153\128"
        local ok, supported = pcall(font.hasGlyphs, font, glyph)
        if ok and supported then marker = " " .. glyph end
      end
      c.display = ui.name .. marker
    end
  end
  if c.level ~= ui.level then
    c.level = ui.level
    c.levelText = ui.level and "Lv." .. tostring(ui.level) or nil
  end
  return c
end

-- Dark bands behind the label rows, then the scan overlay. ui = the bridge's
-- QuestPokedexScanUI instance (phase scanning or locked); g = love.graphics.
function M.drawFillOverlay(ui, g, w, h)
  if type(g) ~= "table" or type(ui) ~= "table" or type(ui.draw) ~= "function" then return false end
  if g.setBlendMode then g.setBlendMode("alpha", "alphamultiply") end
  g.setColor(0, 0, 0, M.STRIP_ALPHA)
  local top, bottom = M.STRIP_TOP * h / M.FILL_H, M.STRIP_BOTTOM * h / M.FILL_H
  g.rectangle("fill", 0, 0, w, top)
  g.rectangle("fill", 0, h - bottom, w, bottom)
  if w ~= M.FILL_W or h ~= M.FILL_H or (ui.phase ~= "scanning" and ui.phase ~= "locked") then
    return ui:draw(g, w, h) -- not the Gear canvas this port is laid out for: the UI's own generic draw
  end
  local font = g.getFont()
  local c = strings(ui, font)
  if g.setLineWidth then g.setLineWidth(1) end
  g.setColor(0, .65, .64, .06); box(g, "fill", 2, 2, 236, 212)
  cyan(g, .85); box(g, "line", 3, 3, 234, 210, 3)
  local frame = ui.frame or 0
  local settle = ui.phase == "locked" and 3 * (1 - math.min(frame, 4) / 4) or 0
  cyan(g, .95)
  g.ellipse("line", 120, 108, 50 + settle, 50 + settle, 64)
  cyan(g, .62)
  g.ellipse("line", 120, 108, 42, 42, 64)
  for i, tick in ipairs(TICKS) do
    local active = ui.phase == "scanning" and ((i - 1 - frame) % 24) < 3
    cyan(g, active and 1 or .55)
    local inner = i % 3 == 1 and 44 or 46
    g.line(120 + tick[1] * inner, 108 + tick[2] * inner, 120 + tick[1] * 49, 108 + tick[2] * 49)
  end
  label(g, font, ui.phase == "scanning" and "SCANNING" or "TARGET LOCK", 8, 8, 111)
  if c.display then
    cyan(g, .8); g.line(96, 51, 96, 58); g.line(96, 58, 86, 71)
    label(g, font, c.display, 8, 31, 143)
  end
  if c.levelText then
    cyan(g, .8); g.line(202, 51, 202, 64); g.line(202, 64, 159, 79)
    label(g, font, c.levelText, 165, 31, 67)
  end
  if ui.kind then
    cyan(g, .8); g.line(83, 142, 58, 164); g.line(58, 164, 58, 176)
    label(g, font, ui.kind, 8, 176, 168)
  end
  return true
end

local function installFill(bridge, rec)
  local origWindow = bridge.cameraWindow
  if type(origWindow) ~= "function" then return end
  local windowFn = function(self)
    local ui = self.scanUI
    local phase = ui and ui.phase
    if M.CAMERA_FILL and (phase == "scanning" or phase == "locked") and self.deviceMode == "tablet"
        and self.cameraSequence ~= nil and self.cameraFrame ~= nil then
      local w, h = self:_canvasDimensions()
      if w == M.FILL_W and h == M.FILL_H then return 0, 0, w, h end
    end
    return origWindow(self)
  end
  rec.window = { fn = windowFn, own = rawget(bridge, "cameraWindow") }
  rawset(bridge, "cameraWindow", windowFn)
  local ui = bridge.scanUI
  if type(ui) == "table" and type(ui.drawSpriteWindow) == "function" and type(ui.draw) == "function" then
    local origSprite = ui.drawSpriteWindow
    local spriteFn = function(self, g, x, y, w, h)
      if x == 0 and y == 0 and w == M.FILL_W and h == M.FILL_H then return M.drawFillOverlay(self, g, w, h) end
      return origSprite(self, g, x, y, w, h)
    end
    rec.sprite = { ui = ui, fn = spriteFn, own = rawget(ui, "drawSpriteWindow") }
    rawset(ui, "drawSpriteWindow", spriteFn)
  end
end

local function uninstallFill(bridge, rec)
  if rec.window and rawget(bridge, "cameraWindow") == rec.window.fn then rawset(bridge, "cameraWindow", rec.window.own) end
  if rec.sprite and rawget(rec.sprite.ui, "drawSpriteWindow") == rec.sprite.fn then
    rawset(rec.sprite.ui, "drawSpriteWindow", rec.sprite.own)
  end
end

function M.installBridge(_component, _interaction, bridge)
  if type(bridge) ~= "table" or state.bridges[bridge] then return false end
  local original = bridge.openPokedex
  if type(original) ~= "function" then return false end
  local fn = function(self, entry) return M.openPokedex(self, entry, original) end
  state.bridges[bridge] = { fn = fn, own = rawget(bridge, "openPokedex") }
  rawset(bridge, "openPokedex", fn)
  installFill(bridge, state.bridges[bridge])
  return true
end

------------------------------------------------------------ VRITK module tables
local function swap(rec, module, name, fn)
  local raw = rawget(module, name)
  if type(raw) ~= "function" then return false end
  rec[#rec + 1] = { module = module, name = name, raw = raw, fn = fn(raw) }
  rawset(module, name, rec[#rec].fn)
  return true
end

------------------------------------------------------------ watch scan edge (Lab 57)
-- Headset 2026-10-10: "The scanner for the watch should be at the top of the
-- watch" = scan from the top edge. QuestWearableInteraction builds the wrist
-- scan ray out of the BACK of the case (centre of the glass, along the face
-- normal reversed). On Gen3 the Pokedex scan instead leaves the TOP EDGE of the
-- watch face, along the face's up axis, in the face's plane, away from its
-- centre. The shell contract (pokedex_wearable_v3_contract.json, watch.screen)
-- names the axes: normal +Y, right +X, up -Z (QuestDeviceLayout.uv puts the
-- top of the texture at -Z), centre (0, 0.00528, 0), height 0.046 m. The edge
-- is therefore model point centre + up * height / 2, and the same mount
-- rotation the watch is drawn and touched with (WATCH_ROTATION_X/Y/Z, applied Y,
-- then X, then Z) carries it into the left hand frame. QuestWatchPokedex asks
-- for it only when a scan resolves; the "is the watch raised toward the head"
-- test keeps using the back-of-case ray. Gen1/Gen2 never install this.
local function rotY(v, a)
  local c, s = math.cos(a or 0), math.sin(a or 0)
  return { c * v[1] + s * v[3], v[2], -s * v[1] + c * v[3] }
end
local function rotX(v, a)
  local c, s = math.cos(a or 0), math.sin(a or 0)
  return { v[1], c * v[2] - s * v[3], s * v[2] + c * v[3] }
end
local function rotZ(v, a)
  local c, s = math.cos(a or 0), math.sin(a or 0)
  return { c * v[1] - s * v[2], s * v[1] + c * v[2], v[3] }
end
-- QuestWearableInteraction's modelVector: Y first, then X, then Z.
local function modelVec(I, v) return rotZ(rotX(rotY(v, I.WATCH_ROTATION_Y), I.WATCH_ROTATION_X), I.WATCH_ROTATION_Z) end

local function triple(t)
  if type(t) ~= "table" then return false end
  for i = 1, 3 do
    local n = t[i]
    if type(n) ~= "number" or n ~= n or math.abs(n) == math.huge then return false end
  end
  return true
end

-- Interaction: the QuestWearableInteraction module table (live WATCH_* mount);
-- screen: VRDeviceAssets.screen("watch"). Returns {origin, direction, up,
-- maxDistance} in the left-hand frame, or nil when either is unusable.
function M.watchEdgeRay(I, screen)
  if type(I) ~= "table" or type(screen) ~= "table" then return nil end
  local c, up, n, h = screen.centerMeters, screen.up, screen.normal, screen.heightMeters
  local a = I.WATCH_ANCHOR
  if not (triple(c) and triple(up) and triple(n) and triple(a)) or type(h) ~= "number" or not (h > 0) then
    return nil
  end
  local half = h / 2
  local o = modelVec(I, { c[1] + up[1] * half, c[2] + up[2] * half, c[3] + up[3] * half })
  return { origin = { a[1] + o[1], a[2] + o[2], a[3] + o[3] },
    direction = modelVec(I, up), up = modelVec(I, n), maxDistance = 12 }
end

local function installWatchEdge(vkV)
  if state.edge then return true end
  local okI, I = pcall(vkV.require, "QuestWearableInteraction")
  local okA, Assets = pcall(vkV.require, "VRDeviceAssets")
  if not (okI and type(I) == "table" and okA and type(Assets) == "table" and type(Assets.screen) == "function") then
    return false
  end
  local okS, screen = pcall(Assets.screen, "watch")
  if not (okS and M.watchEdgeRay(I, screen)) or rawget(I, "watchScanEdgeRay") ~= nil then return false end
  -- The hand-frame ray only changes when the mount does (glove fit change), so
  -- the table is reused while the seven mount numbers are unchanged: a held,
  -- searching wrist asks for it 8 times a second.
  local cache = { m = {} }
  local fn = function()
    local a, m = I.WATCH_ANCHOR, cache.m
    if cache.ray and type(a) == "table" and m[1] == a[1] and m[2] == a[2] and m[3] == a[3]
        and m[4] == I.WATCH_ROTATION_X and m[5] == I.WATCH_ROTATION_Y and m[6] == I.WATCH_ROTATION_Z then
      return cache.ray
    end
    local ray = M.watchEdgeRay(I, screen)
    if ray then
      m[1], m[2], m[3] = a[1], a[2], a[3]
      m[4], m[5], m[6] = I.WATCH_ROTATION_X, I.WATCH_ROTATION_Y, I.WATCH_ROTATION_Z
      cache.ray = ray
    end
    return ray
  end
  rawset(I, "watchScanEdgeRay", fn)
  state.edge = { module = I, fn = fn }
  return true
end

local function uninstallWatchEdge()
  local e = state.edge
  if e and rawget(e.module, "watchScanEdgeRay") == e.fn then rawset(e.module, "watchScanEdgeRay", nil) end
  state.edge = nil
end

------------------------------------------------------------ voice after release (Lab 59)
-- Headset, FireRed Lab 58: "watch scanning works but the voice stops when you let
-- go of scan button. it should continue regardless". QuestWatchPokedex closes its
-- scan session on release and the close reset the scan object, which stops the cry
-- and the spoken entry. This installs two class fields on QuestWatchPokedex:
--   KEEP_VOICE  true: a release / lost hand / lowered watch only closes the panel;
--               the audio keeps playing to its end (QuestWatchPokedex advances it)
--   TAKEOVER    function() -> true when a battle, a menu or no game session has taken
--               over (the Gen3 gear's own interrupted() test, the one VRITK uses to
--               cancel gear placement); the kept wrist voice and the tablet's voice
--               stop when it says so. Resolved on first use, polled by the callers at
--               most every 0.1 s; the call itself allocates nothing here.
-- Without this compat (Gen1/Gen2) both fields are nil and nothing changes.
-- KEEP_VOICE = false leaves the old stop-on-release behaviour.
M.KEEP_VOICE = true

local function installVoice(vkV)
  if state.voice or not M.KEEP_VOICE then return false end
  local okW, W = pcall(vkV.require, "QuestWatchPokedex")
  if not (okW and type(W) == "table") or rawget(W, "KEEP_VOICE") ~= nil or rawget(W, "TAKEOVER") ~= nil then return false end
  local interrupted
  local function takeover()
    if interrupted == nil then
      local okH, host = pcall(function() return vkV.require("Gen3HostCompat").get() end)
      local gear = okH and type(host) == "table" and host.gear
      if not (gear and type(gear.interrupted) == "function") then return false end
      interrupted = gear.interrupted
    end
    local ok, value = pcall(interrupted)
    return ok and value == true
  end
  rawset(W, "KEEP_VOICE", true)
  rawset(W, "TAKEOVER", takeover)
  state.voice = { module = W, fn = takeover }
  return true
end

local function uninstallVoice()
  local v = state.voice
  if v and rawget(v.module, "TAKEOVER") == v.fn then
    rawset(v.module, "TAKEOVER", nil)
    rawset(v.module, "KEEP_VOICE", nil)
  end
  state.voice = nil
end

function M.installCamera(vkV)
  if state.camera then return true end
  if type(vkV) ~= "table" or type(vkV.require) ~= "function" then return false, "no VRITK V" end
  local okC, Camera = pcall(vkV.require, "QuestPokedexCamera")
  local okS, Scan = pcall(vkV.require, "QuestPokedexScan")
  if not (okC and type(Camera) == "table" and okS and type(Scan) == "table") then
    return false, "scanner modules unavailable"
  end
  local rec = {}
  local ok = swap(rec, Camera, "update", function(raw)
    return function(self, st, context, dt)
      local before = self.nextAt
      local changed = raw(self, st, context, dt)
      -- a render was attempted this call (the module just set clock+0.125)
      if self.nextAt ~= before and type(self.clock) == "number" and self.nextAt > self.clock then
        self.nextAt = self.clock + M.FRAME_INTERVAL
      end
      return changed
    end
  end) and swap(rec, Camera, "snapshot", function(raw)
    return function(self)
      local s = raw(self)
      if type(s) == "table" and s.lockedReady and (tonumber(self.lockTime) or 0) < M.LOCK_SECONDS then
        s.lockedReady = false
      end
      return s
    end
  end) and swap(rec, Scan, "_startNarration", function(raw)
    return function(self)
      -- Audio identification is independent of the tablet's caught-only page.
      return raw(self)
    end
  end)
  state.camera = rec
  if not ok then M.uninstallCamera(); return false, "scanner module shape changed" end
  installWatchEdge(vkV)
  installVoice(vkV)
  return true
end

function M.uninstallCamera()
  uninstallWatchEdge()
  uninstallVoice()
  local rec = state.camera
  if not rec then return end
  for i = #rec, 1, -1 do
    local r = rec[i]
    if rawget(r.module, r.name) == r.fn then rawset(r.module, r.name, r.raw) end
  end
  state.camera = nil
end

function M.uninstall()
  M.uninstallCamera()
  unwrapModel()
  state.redact = nil
  for bridge, rec in pairs(state.bridges) do
    if rawget(bridge, "openPokedex") == rec.fn then rawset(bridge, "openPokedex", rec.own) end
    uninstallFill(bridge, rec)
    state.bridges[bridge] = nil
  end
end

function M.status()
  return { camera = state.camera ~= nil, modelWrapped = state.model ~= nil,
    unknownSpecies = state.redact and state.redact.species or nil,
    watchEdge = state.edge ~= nil, cameraFill = M.CAMERA_FILL, keepVoice = state.voice ~= nil,
    frameInterval = M.FRAME_INTERVAL, lockSeconds = M.LOCK_SECONDS }
end

return M
