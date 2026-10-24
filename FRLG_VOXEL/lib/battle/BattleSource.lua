-- FRLG_VOXEL (W6, battle phase P-B1): read-only adapter over the game3
-- battle (battle-hook DESIGN.md section 3, the data contract).
--
-- Everything here READS engine state; nothing writes it. In particular the
-- per-battler present records and the stage table are read with rawget, not
-- through Anim.present()/Anim.stage(), which create missing entries. The
-- only engine calls made are pure lookups the engine's own battle draw makes
-- every frame (Ui.battlerPic, Ui.battlerSpriteCenter, Anim.shownBattler,
-- Anim.substituteImage) and, from drawHealthbox, Healthbox.draw itself,
-- which only draws (called only while its stage/present entries exist).
--
-- Engine modules come through an injectable accessor so plain-LuaJIT tests
-- can hand in fake game3 tables (w6/tests/test_battle_source.lua).
local V = ...
local _ = V
local ImportedSprites = V.require("battle/ImportedSprites")

local BattleSource = {}
BattleSource.__index = BattleSource

BattleSource.PATHS = {
  battle = "src.core.game3.battle",
  anim = "src.core.game3.battle.anim",
  ui = "src.core.game3.battle.ui",
  healthbox = "src.core.game3.battle.healthbox",
  transition = "src.core.game3.battle_transition",
  player = "src.core.game3.player",
  trainerPic = "src.core.game3.trainer_pic",
  ballOpen = "src.core.game3.battle.ball_open",
  animSprites = "src.core.game3.battle.anim_sprites",
  choice = "src.ui.game3.choice",
  stack = "src.ui.game3.stack",
  message = "src.ui.game3.message",
  chrome = "src.ui.game3.chrome",
}
-- Screens that cover the whole 240x160 frame (CRITIQUE #7) and small windows
-- or prompts that sit above the command strip (CRITIQUE #8).
BattleSource.FULLSCREEN = {
  { "src.ui.game3.bag_menu", "isOpen", "bag" },
  { "src.ui.game3.party_menu", "isOpen", "party" },
  { "src.ui.game3.pokedex", "isOpen", "pokedex" },
  { "src.ui.game3.summary_menu", "isOpen", "summary" },
  { "src.ui.game3.naming", "isOpen", "naming" },
  { "src.ui.game3.evolution_scene", "isOpen", "evolution" },
}
BattleSource.WINDOWS = {
  { "src.ui.game3.stat_growth", "isOpen", "stat-growth" },
}
-- pret sBattlerCoords (singles), used when the anim module is unavailable.
BattleSource.SINGLES = { [0] = { x = 72, y = 80 }, [1] = { x = 176, y = 40 } }
BattleSource.PRESENT_FIELDS = {
  "visible", "ox", "oy", "alpha", "scale", "sx", "sy", "rotation", "hFlip", "darken", "flash",
  "blinkHidden", "invisible", "battlerInvisible", "substitute", "substituteY",
  "displayHp", "displayMaxHp", "displayLevel", "transformSpecies", "pendingTransform",
}

local function defaultEngine(name)
  local ok, m = pcall(require, name)
  if ok and type(m) == "table" then return m end
  return nil
end

-- Loaded with the voxel mod, before game.ready installs Gear's shared HUD
-- wrapper. Keep the engine draw for our separate 3D card canvases: Gear's
-- battle_view setting owns its screen HUD, not these cards. Do not replace
-- the shared function or change Gear's own visibility decisions.
local nativeHealthbox = defaultEngine(BattleSource.PATHS.healthbox)
local nativeHealthboxDraw = nativeHealthbox and nativeHealthbox.draw

-- opts = { engine = fn(name) -> module|nil }
function BattleSource.new(opts)
  opts = opts or {}
  local engine = opts.engine or defaultEngine
  local draw = nativeHealthboxDraw
  if opts.engine then
    local healthbox = engine(BattleSource.PATHS.healthbox)
    draw = healthbox and healthbox.draw
  end
  return setmetatable({ engine = engine, cache = {}, healthboxDraw = draw }, BattleSource)
end

function BattleSource:mod(key)
  local m = self.cache[key]
  if m ~= nil then return m or nil end
  local path = BattleSource.PATHS[key] or key
  m = self.engine(path)
  self.cache[key] = m or false
  return m
end

local function call(m, fn, ...)
  local f = m and m[fn]
  if type(f) ~= "function" then return nil end
  local ok, v = pcall(f, ...)
  if ok then return v end
  return nil
end

function BattleSource:active()
  return call(self:mod("battle"), "isActive") == true
end

function BattleSource:transition()
  return call(self:mod("transition"), "isActive") == true
end

function BattleSource:state()
  local B = self:mod("battle")
  if not B then return nil end
  local st = call(B, "getState")
  if st == nil then st = rawget(B, "_st") end
  return type(st) == "table" and st or nil
end

function BattleSource:isDouble(st)
  st = st or self:state()
  return type(st) == "table" and st.double == true
end

-- Engine battler ids on screen, in the order a card set is built.
function BattleSource:ids(st)
  if self:isDouble(st) then return { 0, 1, 2, 3 } end
  return { 0, 1 }
end

local function sideOf(id) return (id % 2 == 0) and "player" or "enemy" end
BattleSource.sideOf = sideOf

-- Raw present record for battler id (nil when the engine has none yet).
function BattleSource:presentRaw(id)
  local A = self:mod("anim")
  local t = A and rawget(A, "_present")
  if type(t) ~= "table" then return nil end
  return rawget(t, id)
end

function BattleSource:stageRaw()
  local A = self:mod("anim")
  local s = A and rawget(A, "_stage")
  return type(s) == "table" and s or nil
end

local function battlerOf(st, id, double)
  if type(st) ~= "table" then return nil end
  if not double then
    if id == 0 then return st.player end
    if id == 1 then return st.enemy end
  end
  local bs = st.battlers
  local b = type(bs) == "table" and bs[id] or nil
  if b == nil and id == 0 then b = st.player end
  if b == nil and id == 1 then b = st.enemy end
  return b
end

-- Species actually on show, as the engine's draw resolves it (ui.lua
-- draw_mon_sprite: species, then Transform per CRITIQUE #3).
function BattleSource.resolveSpecies(battler, pres)
  if type(battler) ~= "table" then return nil end
  local sp = battler.species
  if sp == nil and type(battler.mon) == "table" then
    sp = battler.mon.species or battler.mon.speciesId
  end
  if battler.expTransform then
    local tf = pres and pres.transformSpecies
    if not tf and not (pres and pres.pendingTransform) then tf = battler.expTransform.species end
    if tf then sp = tf end
  end
  return tonumber(sp) or sp
end

-- Plain battle summary (no engine tables inside).
function BattleSource:info()
  local st = self:state()
  local B = self:mod("battle")
  local ui = self:mod("ui")
  local info = {
    active = self:active(), transition = self:transition(),
    phase = B and rawget(B, "_phase") or nil,
    double = self:isDouble(st),
    uiMode = ui and rawget(ui, "_mode") or nil,
  }
  if st then
    info.kind = st.kind or (st.wild and "wild" or nil)
    info.wild = st.wild == true or st.kind == "wild"
    info.safari = st.safari and true or false
    info.ghost = st.ghostBattle and true or false
    info.oldMan = st.oldManTutorial and true or false
    info.pokedude = st.pokedude and true or false
    info.link = st.link and true or false
    info.terrain = st.terrain
    info.over = st.over and true or false
    info.result = st.result
    info.turn = st.turn
  end
  local Choice = self:mod("choice")
  info.choice = Choice ~= nil and rawget(Choice, "active") == true
  for _, row in ipairs(BattleSource.FULLSCREEN) do
    if call(self:mod(row[1]), row[2]) == true then info.fullscreen = row[3]; break end
  end
  for _, row in ipairs(BattleSource.WINDOWS) do
    if call(self:mod(row[1]), row[2]) == true then info.window = row[3]; break end
  end
  -- Native dialogue includes move/EXP/money/results as well as the intro. The tablet owns the battle
  -- UI, so without this the player never sees what the game is waiting for. Read only; the engine's message
  -- queue, pacing and input are untouched. Link, Oak's tutorial and the Pokedude have their own presentation.
  info.dialogPending = call(ui, "dialogPending") == true
  if info.phase == "intro" and st and not (st.link or st.oldManTutorial or st.pokedude) then
    info.battleDialoguePhase = "intro"
  elseif info.dialogPending and not(st and(st.link or st.oldManTutorial or st.pokedude))then
    local message=self:mod("message")
    if call(message,"isOpen")==true then info.battleDialoguePhase=info.phase or "result"end
  end
  info.battleDialogue = info.active and not (B and B._headless)
    and info.dialogPending and info.battleDialoguePhase ~= nil
    and not (info.fullscreen or info.window or info.choice) or false
  info.dialogHint = info.battleDialogue and self:continueHint() or false
  return info
end

-- Opening dialogue (wild encounter: "A wild X appeared!"): the text the engine's own message box shows now.
-- Called on a change only (BattlePass logs it), never per frame.
function BattleSource:dialogText()
  local M = self:mod("message")
  local page = call(M, "currentPage")
  return type(page) == "string" and page or ""
end

-- True when the engine's message box is waiting for A and its own box shows NO continue arrow: the opening
-- text is fully printed, will close on A (not a stay message, not held, no choice), and src.ui.game3.message
-- would not draw the arrow (Message.drawText: the classic red arrow shows whenever a non-stay message waits;
-- a chrome arrow spec, Emerald's down arrow with lastPage=false, shows it on every page but the last).
function BattleSource:continueHint()
  local M = self:mod("message")
  if not (M and rawget(M, "open") == true and rawget(M, "_waiting") == true) then return false end
  if rawget(M, "_stay") or rawget(M, "_held") or rawget(M, "_choice") then return false end
  local chrome = self:mod("chrome")
  local f = chrome and chrome.arrowSpec
  if type(f) ~= "function" then return false end
  local ok, spec = pcall(f)
  if not ok or type(spec) ~= "table" then return false end -- no spec: the classic arrow is drawn
  if spec.lastPage then return false end
  local pages = rawget(M, "_pages")
  local n = type(pages) == "table" and #pages or 1
  return (rawget(M, "_page") or 1) >= n
end

-- Plain per-battler snapshot (present fields copied, HP as displayed).
function BattleSource:slot(id, st)
  st = st or self:state()
  local double = self:isDouble(st)
  local b = battlerOf(st, id, double)
  local pres = self:presentRaw(id)
  local out = { id = id, side = sideOf(id), present = {} }
  if pres then
    for _, k in ipairs(BattleSource.PRESENT_FIELDS) do out.present[k] = rawget(pres, k) end
  end
  if type(b) == "table" then
    local mon = type(b.mon) == "table" and b.mon or {}
    out.species = BattleSource.resolveSpecies(b, pres)
    out.hp, out.maxHp, out.level = mon.hp, mon.maxHp, mon.level
    out.fainted = b.fainted == true or (tonumber(mon.hp) or 1) <= 0
  end
  out.displayHp = out.present.displayHp or out.hp
  out.displayMaxHp = out.present.displayMaxHp or out.maxHp
  out.displayLevel = out.present.displayLevel or out.level
  local stage = self:stageRaw()
  local hbs = stage and stage.healthbox
  local hb = type(hbs) == "table" and (rawget(hbs, id) or hbs[out.side]) or nil
  out.hbVisible = hb ~= nil and hb.visible ~= false
  out.hbOx = hb and tonumber(hb.ox) or 0
  return out
end

-- Draw descriptor for battler id: which picture, where on the 240x160
-- battle screen (the engine's own placement, offsets included) and how
-- (alpha, shade, flash, scale, rotation). Returns desc or nil, reason.
-- desc = { id, side, image, cx, cy, restCx, restCy, baseX, baseY, rot, sx,
--          sy, alpha, shade, flash, species, ghost, substitute }
-- battle-ui (2026-10-01): opts.force = the user's own presentation owns this picture right now (FRLG_VOXEL
-- BattlePass: an opening send-out the user's beam has reached, a catch break-out). The engine's hide flags and its
-- present offsets, scale, tint and flash are ignored: the battler's own picture at its rest spot, full size.
-- Still read-only.
function BattleSource:battlerDraw(id, st, opts)
  st = st or self:state()
  if not st then return nil, "no battle" end
  local A, Ui = self:mod("anim"), self:mod("ui")
  if not (A and Ui) then return nil, "no battle ui" end
  local double = self:isDouble(st)
  local side = sideOf(id)
  if not double and id == 0 and st.safari then return nil, "safari" end
  local b = battlerOf(st, id, double)
  if type(b) ~= "table" then return nil, "no battler" end
  local force = type(opts) == "table" and opts.force == true
  local pres = self:presentRaw(id)
  if pres and not force and (pres.visible == false or pres.blinkHidden or pres.battlerInvisible or pres.invisible) then
    return nil, "hidden"
  end
  if double and not force and Ui.targetHidden and call(Ui, "targetHidden", id) == true then return nil, "hidden" end
  if force then pres = nil end
  local key = double and id or side
  if A.shownBattler then
    local okS, shown = pcall(A.shownBattler, key, b)
    if okS and type(shown) == "table" then b = shown end
  end
  local sp = BattleSource.resolveSpecies(b, pres)
  local base
  if double then
    base = A.coords and call(A, "coords", nil, id) or nil
  else
    base = (id == 0) and (A.PLAYER_MON or BattleSource.SINGLES[0]) or (A.ENEMY_MON or BattleSource.SINGLES[1])
  end
  base = base or BattleSource.SINGLES[id % 2]
  local ghost = false
  if Ui.showsGhost then ghost = call(Ui, "showsGhost", side, st) == true end
  local form = 0
  if Ui.castformForm then form = tonumber(call(Ui, "castformForm", side, b)) or 0 end
  local ox = pres and tonumber(pres.ox) or 0
  local oy = pres and tonumber(pres.oy) or 0
  local image, cx, cy, restCx, restCy
  local substitute = false
  if pres and pres.substitute and A.substituteImage then
    image = call(A, "substituteImage", key)
    if image then
      substitute = true
      restCx = base.x
      restCy = tonumber(pres.substituteY) or tonumber(call(A, "substituteY", key)) or (base.y + 16)
    end
  end
  if not image then
    if not Ui.battlerPic then return nil, "no battlerPic" end
    local okP, entry = pcall(Ui.battlerPic, key, b, sp)
    if not (okP and type(entry) == "table" and entry.image) then return nil, "no picture" end
    image = entry.image
    if Ui.battlerSpriteCenter then
      local okC, x, y = pcall(Ui.battlerSpriteCenter, double and id or side, sp,
        (not double) and base or nil, form, ghost)
      if okC and type(x) == "number" then restCx, restCy = x, y end
    end
    restCx, restCy = restCx or base.x, restCy or base.y
  end
  local imported
  image, restCy, imported = ImportedSprites.resolve(V, self.engine, { battle = st, id = id,
    battler = b, species = sp, side = side, form = form, ghost = ghost,
    substitute = substitute, baseY = base.y, ui = Ui }, image, restCy)
  -- Native pictures (battler, substitute) keep their 64 px frame and centre;
  -- an imported picture keeps its original size, centred on its own middle.
  local imageW, imageH, originX, originY = 64, 64, 32, 32
  if type(imported) == "table" then
    imageW, imageH = imported.width, imported.height
    originX, originY = imageW / 2, imageH / 2
  end
  local bounce = 0
  if Ui.bounceOffset then bounce = tonumber(call(Ui, "bounceOffset", "mon", id)) or 0 end
  -- The engine's idle bob moves the picture down by 0-2 px. An imported
  -- picture stands with its lowest row on the card's ground row, so it bobs
  -- up by the same amount instead and never sinks into the ground (user
  -- report on Emerald 3306: the back sprite clipped below the ground).
  if imported then bounce = -math.abs(bounce) end
  cx, cy = restCx + ox, restCy + oy + bounce
  local scale = pres and tonumber(pres.scale) or 1
  local hFlip = pres and pres.hFlip and true or false
  local darken = pres and tonumber(pres.darken) or 0
  local tint = (not force) and self:tintFor(id, side, double, pres, b, substitute) or nil
  local rot = pres and tonumber(pres.rotation) or 0
  local sy = scale * (pres and tonumber(pres.sy) or 1)
  local hShift = nil
  if pres and type(pres.hShift) == "table" and rot == 0 and sy == 1 then hShift = pres.hShift end
  return {
    tint = tint, hShift = hShift, hTop = math.floor(restCy + oy + bounce - originY + 0.5),
    -- gen5 native-res: picture size and draw origin (native: 64x64, origin 32,32). The horizontal origin is
    -- half-pixel origin is retained; BattleCards.canvasPos aligns odd-width artwork to pixels.
    imported = imported ~= nil, imgW = imageW, imgH = imageH,
    imageW = imageW, imageH = imageH,
    originX = originX, originY = originY,
    statMask = self:statMaskFor(pres, substitute),
    id = id, side = side, image = image, cx = cx, cy = cy, restCx = restCx, restCy = restCy,
    baseX = base.x, baseY = base.y,
    rot = pres and tonumber(pres.rotation) or 0,
    sx = (hFlip and -1 or 1) * scale * (pres and tonumber(pres.sx) or 1),
    sy = scale * (pres and tonumber(pres.sy) or 1),
    alpha = pres and tonumber(pres.alpha) or 1,
    shade = 1 - darken * (1 - 8 / 255),
    flash = pres and tonumber(pres.flash) or 0,
    species = sp, ghost = ghost, substitute = substitute,
  }
end

-- The engine's picture tint for battler id, in the order ui.lua's
-- draw_mon_sprite picks one (the ball-open colour fade; the palette affine;
-- mosaic; greyscale; a move's blend; the Transform tint; the doubles target
-- preview). Returns nil or { mode = "blend", coeff, r, g, b (0..31) } |
-- { mode = "affine", m, r, g, b } | { mode = "mosaic", block } | { mode = "gray" }.
-- Read-only: BallOpen.monBlend and Ui.previewCoeff only read.
function BattleSource:tintFor(id, side, double, pres, battler, substitute)
  local BO = self:mod("ballOpen")
  local function monBlend(key)
    if not (BO and BO.monBlend) then return nil end
    local ok, c, r, g, b = pcall(BO.monBlend, key)
    c = ok and tonumber(c) or 0
    if c > 0 then return { mode = "blend", coeff = c, r = tonumber(r) or 0, g = tonumber(g) or 0, b = tonumber(b) or 0 } end
    return nil
  end
  local t = double and (monBlend(id) or (id < 2 and monBlend(side) or nil)) or monBlend(side)
  if t then return t end
  if pres then
    local pa = pres.palAffine
    if type(pa) == "table" then
      return { mode = "affine", m = tonumber(pa.m) or 1, r = tonumber(pa.r) or 0, g = tonumber(pa.g) or 0,
        b = tonumber(pa.b) or 0 }
    end
    local mos = tonumber(pres.mosaic) or 0
    if mos > 0 then return { mode = "mosaic", block = mos + 1 } end
    if pres.grayscale then return { mode = "gray" } end
    local bc = tonumber(pres.blendCoeff) or 0
    if bc > 0 then
      local c = type(pres.blendColor) == "table" and pres.blendColor or { 1, 1, 1 }
      return { mode = "blend", coeff = bc * 16, r = (c[1] or 0) * 31, g = (c[2] or 0) * 31, b = (c[3] or 0) * 31 }
    end
  end
  if type(battler) == "table" and battler.expTransform and not substitute then
    local tf = pres and pres.transformSpecies
    if not tf and not (pres and pres.pendingTransform) then tf = battler.expTransform.species end
    if tf then return { mode = "blend", coeff = 6, r = 31, g = 31, b = 31 } end
  end
  if double then
    local Ui = self:mod("ui")
    local pc = Ui and Ui.previewCoeff and tonumber(call(Ui, "previewCoeff", id)) or 0
    if pc > 0 then return { mode = "blend", coeff = pc, r = 31, g = 31, b = 31 } end
  end
  return nil
end

-- True while move effects or the ball-open burst are on screen (the move
-- VM runs, an effect sprite is live, or ball-open particles fly). Read-only.
function BattleSource:effectsLive()
  local A = self:mod("anim")
  local vm = A and rawget(A, "_vm")
  if type(vm) == "table" and vm.active then return true end
  local BO = self:mod("ballOpen")
  local ps = BO and rawget(BO, "_particles")
  if type(ps) == "table" and #ps > 0 then return true end
  local AS = self:mod("animSprites")
  local pool = AS and rawget(AS, "_pool")
  if type(pool) == "table" then
    for i = 1, #pool do
      local sp = pool[i]
      if type(sp) == "table" and sp.active and sp.visible ~= false then return true end
    end
  end
  return false
end

-- Draws the engine's own move-effect sprites of one depth band (the bands
-- ui.lua's Ui.draw uses: 1-99 behind the foe, 101-199 between the two,
-- 201-999 in front), at the current transform; the front band also draws
-- the ball-open burst. The lower bound starts at 1 so the full-screen move
-- background is not drawn (anim_vm.lua draws it for a lower bound <= 0).
-- Drawing only: AnimVm:draw / BallOpen.draw keep draw caches, no state.
function BattleSource:drawBand(lo, hi, withBallOpen)
  local A = self:mod("anim")
  if A and A.drawParticles then pcall(A.drawParticles, math.max(1, lo), hi) end
  if withBallOpen then
    local BO = self:mod("ballOpen")
    if BO and BO.draw then pcall(BO.draw) end
  end
end

-- Round 3 (P-B3): the stat-change overlay on battler id (the engine's
-- battle_anim_utility_funcs stat mask: a scrolling pattern over the
-- picture while the move VM runs). Returns nil or { image (the 256 px mask),
-- x, y (scroll), eva, evb }. Anim.statMaskImage only fills its image cache.
function BattleSource:statMaskFor(pres, substitute)
  local sm = pres and pres.statMask
  if substitute or type(sm) ~= "table" or (tonumber(sm.eva) or 0) <= 0 then return nil end
  local A = self:mod("anim")
  local vm = A and rawget(A, "_vm")
  if not (type(vm) == "table" and vm.active and A.statMaskImage) then return nil end
  local ok, img = pcall(A.statMaskImage, sm.tilemap, sm.pal)
  if not (ok and img) then return nil end
  return { image = img, x = tonumber(sm.x) or 0, y = tonumber(sm.y) or 0,
    eva = math.min(16, tonumber(sm.eva) or 0), evb = sm.evb and math.min(16, tonumber(sm.evb) or 0) or nil }
end

-- Round 3: a move background is on screen (Psychic, Night Shade, ...: the
-- VM's bg image, or its fade to black). Read-only.
function BattleSource:backgroundLive()
  local A = self:mod("anim")
  local vm = A and rawget(A, "_vm")
  if type(vm) ~= "table" then return false end
  local id = rawget(vm, "_animBgId")
  if id ~= nil and tonumber(id) and tonumber(id) >= 0 then return true end
  local f = rawget(vm, "_bgFade")
  return type(f) == "table" and (tonumber(f.y) or 0) > 0
end

-- Draws the move background (only the background: AnimVm:draw with the
-- band 0..0 draws it, plus any sprite exactly at z 0).
function BattleSource:drawBackground()
  local A = self:mod("anim")
  if A and A.drawParticles then pcall(A.drawParticles, 0, 0) end
end

-- Round 3: the full-screen effect a move set (Anim.screenEffect: invert,
-- fade to white/black, darken, greyscale, colour blend), plus the dims the
-- battle draws over its frame (stage.bgDim; the Old Man / Pokedude
-- voiceover dim). Plain data.
function BattleSource:screenFx()
  local A = self:mod("anim")
  local fx = A and rawget(A, "_screenEffect")
  local out = {}
  if type(fx) == "table" and fx.type and fx.type ~= "none" then
    local c = type(fx.targetColor) == "table" and fx.targetColor or { 1, 1, 1 }
    out.type, out.coeff = fx.type, tonumber(fx.coeff) or 1
    out.target = { tonumber(c[1]) or 1, tonumber(c[2]) or 1, tonumber(c[3]) or 1 }
  end
  local stage = self:stageRaw()
  out.bgDim = stage and tonumber(stage.bgDim) or 0
  local Ui = self:mod("ui")
  out.voiceDim = (Ui and Ui.voiceoverDim) and (tonumber(call(Ui, "voiceoverDim")) or 0) or 0
  return out
end

-- Opposing trainer pictures for the 3D battle's intro and victory slides.
-- The user occupies the player's place, so omit their trainer in every 3D
-- camera mode. Keep native stage flags intact for the ordinary 2D renderer.
-- Returns a list of { image, quadFrame, frameW, frameH,
-- imageW, imageH, x, y } in screen pixels (centre), possibly empty.
function BattleSource:trainerDraw(side)
  if side == "player" then return {} end
  local stage = self:stageRaw()
  local tr = stage and stage.trainer
  local out = {}
  if type(tr) ~= "table" then return out end
  local TP = self:mod("trainerPic")
  if not TP then return out end
  if side == "enemy" then
    local te = tr.enemy
    if type(te) == "table" and te.visible then
      for _, row in ipairs({ { te.pic2, te.x2 }, { te.picId, te.x or 176 } }) do
        if row[1] ~= nil and row[2] ~= nil then
          local entry = call(TP, "front", row[1])
          if type(entry) == "table" and entry.image then
            out[#out + 1] = { image = entry.image, x = row[2] + (tonumber(te.ox) or 0),
              y = 40 + (tonumber(te.oy) or 0) }
          end
        end
      end
    end
  else
    local tp = tr.player
    if type(tp) == "table" and tp.visible then
      for _, row in ipairs({ { tp.gender2, tp.x2 }, { tp.gender or 0, tp.x or 80 } }) do
        if row[1] ~= nil and row[2] ~= nil then
          local entry = call(TP, "back", row[1])
          if type(entry) == "table" and entry.image then
            local frames = tonumber(entry.frames) or 5
            local frame = math.max(0, math.min(frames - 1, tonumber(tp.frame) or 0))
            out[#out + 1] = { image = entry.image, quadFrame = frame, frameW = 64, frameH = 64,
              imageW = entry.w or 64, imageH = entry.h or frames * 64,
              x = row[2] + (tonumber(tp.ox) or 0), y = 80 + (tonumber(tp.oy) or 0) }
          end
        end
      end
    end
  end
  return out
end

-- Poke Balls on show: the thrown catch ball (Anim.stage().ball: throw,
-- shakes, break-out or catch) and the per-battler send-out balls
-- (stage.balls). Returns a list of { key, image, quad, x, y (screen centre),
-- rot, alpha, flash, darken }, possibly empty. Ui.ballQuad is the lookup the
-- engine's own draw_ball_entry makes for the same frame.
function BattleSource:ballDraw()
  local out = {}
  local stage = self:stageRaw()
  local Ui = self:mod("ui")
  if not (stage and Ui and Ui.ballQuad) then return out end
  local function add(key, b)
    if type(b) ~= "table" or not b.visible then return end
    local okQ, img, quad = pcall(Ui.ballQuad, b.ballId, b.frame)
    if not (okQ and img and quad) then return end
    out[#out + 1] = {
      key = key, image = img, quad = quad,
      x = (tonumber(b.x) or 0) + (tonumber(b.ox) or 0),
      y = (tonumber(b.y) or 0) + (tonumber(b.oy) or 0),
      rot = tonumber(b.rot) or 0, alpha = tonumber(b.alpha) or 1,
      flash = tonumber(b.flash) or 0, darken = tonumber(b.darken) or 0,
    }
  end
  add("ball", stage.ball)
  if type(stage.balls) == "table" then
    for id = 0, 3 do add("ball" .. id, rawget(stage.balls, id)) end
  end
  return out
end

-- Healthbox on-screen rest top-left for battler id (the engine's own centre
-- table), so a card canvas can hold it with a fixed offset.
function BattleSource:healthboxTopLeft(id, st)
  st = st or self:state()
  local H = self:mod("healthbox")
  local c
  if H and H.center then c = call(H, "center", st, id) end
  if type(c) ~= "table" then
    c = (id % 2 == 0) and { x = 158, y = 88 } or { x = 44, y = 30 }
  end
  return c.x - 32, c.y - 16
end

-- Draws the engine's own healthbox for battler id at the current transform
-- (the caller translates). Returns true when something was drawn.
function BattleSource:drawHealthbox(id, st)
  st = st or self:state()
  if not st then return false end
  local H, A, Ui = self:mod("healthbox"), self:mod("anim"), self:mod("ui")
  if not (H and type(self.healthboxDraw) == "function" and A) then return false end
  -- Healthbox.draw reads Anim.stage()/Anim.present(): only call it while both
  -- already exist, so it can never create them (read-only contract).
  if not self:stageRaw() or not self:presentRaw(id) then return false end
  local double = self:isDouble(st)
  local b = battlerOf(st, id, double)
  if type(b) ~= "table" then return false end
  local key = double and id or sideOf(id)
  if A.shownBattler then
    local okS, shown = pcall(A.shownBattler, key, b)
    if okS and type(shown) == "table" then b = shown end
  end
  local oy = 0
  if Ui and Ui.bounceOffset then oy = tonumber(call(Ui, "bounceOffset", "hb", id)) or 0 end
  local ok = pcall(self.healthboxDraw, key, b, { oy = oy, st = st })
  return ok
end

-- The player (for staging): integer cell, facing, surfing, ground unknown.
function BattleSource:player()
  local P = self:mod("player")
  if not P then return nil end
  local cx, cy = tonumber(rawget(P, "cellX")), tonumber(rawget(P, "cellY"))
  if P.moving and tonumber(P.targetX) and tonumber(P.targetY) then
    -- mid-step: the cell being entered (CRITIQUE #22)
    cx, cy = tonumber(P.targetX), tonumber(P.targetY)
  end
  if not (cx and cy) then return nil end
  return { cellX = cx, cellY = cy, facing = P.facing or "down", surfing = P.surfing == true,
    moving = P.moving == true }
end

return BattleSource
