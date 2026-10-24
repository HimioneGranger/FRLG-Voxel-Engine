-- FRLG_VOXEL: one frame of the voxel view. prepare() runs once per frame
-- (world sync, camera, actors, atlas mips, map culling); renderEye() draws
-- one eye/view into a Canvas with depth:
--   clear -> sky -> terrain (sun, ambient, shadow mask, haze) -> blob
--   shadows -> sprite cards -> UI card -> fade veil.
-- Tour review (2026-09-28): the sky band and the outdoor clear follow the
-- water share of each horizon direction and a sea plane continues open water
-- past the built world (R2, render/Sea.lua); haze reaches 1.0 at the far
-- cull distance (R2); in the 3/4 view the sprite cards share one facing
-- (R5, Billboards env.cardDir).
local V = ...
local FrFog = V.require("render/FrFog")
local Mat4 = V.require("render/Mat4")
local Actors = V.require("data/Actors")
local CavePlacement=V.require("cave/CavePlacement")
local Camera = V.require("render/Camera")
local Light = V.require("render/Light")
local Sky = V.require("render/Sky")
local Horizons = V.require("render/Horizons")
local Shaders = V.require("render/Shaders")
local Shrubs=V.require("render/FrShrubView")
local CaveDark = V.require("render/CaveDark")
local Sea = V.require("render/Sea")
local HealerBalls = V.require("render/HealerBalls")
local AtmosState = V.require("render/AtmosState") -- worker "atmos" (GW-P1)
local Perf = V.require("render/OutdoorPerf") -- Lab 55
-- Lab 55 (G0): FramePacer.PASS indices (quest/FramePacer.lua PASS_KEYS order)
local PASS_SKY, PASS_SEA, PASS_SCENE, PASS_HEALER, PASS_BLOBS, PASS_CARDS = 1, 2, 3, 5, 6, 7
local PASS_WSKY, PASS_BATTLE, PASS_HOST, PASS_WLATE, PASS_UICARD = 8, 9, 10, 11, 12
local okSp58, Speed58 = pcall(V.require, "perf/Speed58") -- Lab 58 SPEED PATCHES (all off without a gate)
local okMr, Mr = pcall(V.require, "quest/MrLink"); if not okMr then Mr = {} end -- PORTAL_MR P1 (Mr.s = the portal session, nil without PORTAL_MR)

local FieldTransition = V.require("render/FieldTransition")

local View = {}
View.__index = View

local engineCache = {}
local function engine(name)
  local m = engineCache[name]
  if m then return m end
  local ok, mod = pcall(require, name)
  if ok and type(mod) == "table" then engineCache[name] = mod; return mod end
  return nil
end

-- Lab 8 (P2, Lab 7 video 5:52-5:54 and 6:10-6:11): a door entrance walks the
-- (hidden) first-person player one step into the doorway before the fade,
-- and a door exit starts in the doorway, so the eye went through the
-- building's wall. While a warp runs: on a step INTO a door cell the eye
-- holds where it stood; on a step OUT of a door cell it stands on the landing
-- cell. Returns the eye target (x, z) in cells.
local function doorGuard(self, cam, p, game)
  local Warp = engine("src.core.game3.warp")
  local busy = false
  if Warp and Warp.isBusy then
    local ok, b = pcall(Warp.isBusy)
    busy = ok and b == true
  end
  if not busy or cam.mode ~= "first" or cam.seat then
    self.doorHold = nil
    return p.x, p.z
  end
  local Coll = engine("src.core.game3.collision")
  local Player = engine("src.core.game3.player")
  local function isDoor(x, y)
    if not (Coll and Coll.isDoorWarp and x and y) then return false end
    local ok, d = pcall(Coll.isDoorWarp, game, x, y)
    return ok and d ~= nil and d ~= false
  end
  local hold = self.doorHold
  local map = Coll and Coll._mapId
  if hold and hold.map == map then return hold.x, hold.z end
  if Player and Player.moving then
    if isDoor(Player.targetX, Player.targetY) then
      local x, z = cam.x or p.x, cam.z or p.z
      self.doorHold = { map = map, x = x, z = z }
      return x, z
    end
    if isDoor(Player.cellX, Player.cellY) then
      return (Player.targetX or 0) + 0.5, (Player.targetY or 0) + 0.5
    end
  elseif Player and Player.facing == "down" and isDoor(Player.cellX, Player.cellY) then
    -- a door exit before its step: already on the landing cell below
    return (Player.cellX or 0) + 0.5, (Player.cellY or 0) + 1.5
  end
  return p.x, p.z
end
View._doorGuard = doorGuard -- test seam

local INDOOR_CLEAR = { 0.0, 0.0, 0.0, 1 }
local INDOOR_FOG = { 1000, 2000, 0 } -- Lab 55 FRAME HOIST: the no-fog default (never mutated)
local NO_ACTORS = {} -- W6: a 3D battle hides every overworld card
View.FOG_START = 14     -- metres beyond the camera's focus distance
View.FOG_END = 62
View.FOG_MAX = 0.92     -- mild: distant terrain keeps a trace of colour...
View.BATTLE_FOG = true
View.BATTLE_FOG_START = 8
View.BATTLE_FOG_END = 34
View.FOG_FULL_CELLS = 6 -- ...then haze reaches 1.0 this far past FOG_END (the cull edge)
-- interiors-team (build/integ/RENDER_PATCH.md): which parts of an interior's
-- room shell (the 4th wall, its doors, the ceiling) this camera draws, for
-- Scene.roomVisible: "first" = first person, everything (the room is closed);
-- "third" = third person, the 4th wall only while the camera is inside the
-- room, never the ceiling; "dollhouse" = the 3/4 view and the Quest table
-- view, none of it; "halfspace" = a battle seat (life size in any mode), the
-- core's reference half-space rule.
View.ROOM_THIRD = "third"
-- (repair2, V2) an open-air interior (Scene:rootOpenAir) draws the sky -- the
-- palette the outdoors last set, no haze -- instead of the black indoor
-- clear (user decision: harbors and roofs are open-air, no ceiling)
View.OPEN_AIR_SKY = true
function View.roomMode(cam)
  if cam.seat then return "halfspace" end
  if cam.mode == "overview" then return "dollhouse" end
  if cam.mode == "third" then return View.ROOM_THIRD end
  return "first"
end
-- the head centre / the trainer handed to Scene:prepareFrame (one reused
-- table each per View; the trainer is nil until the camera has a target)
local function roomEye(self, x, y, z)
  local e = self.roomEye
  if not e then e = {}; self.roomEye = e end
  e[1], e[2], e[3] = x, y, z
  return e
end
local function roomFocus(self, cam)
  if not (cam.x and cam.z) then return nil end
  local f = self.roomFocus
  if not f then f = {}; self.roomFocus = f end
  f[1], f[2], f[3] = cam.x, cam.y or 0, cam.z
  return f
end
View._roomEye, View._roomFocus = roomEye, roomFocus

local LightingContext=V.require('lighting/FrLightingContext')
function View.new(opts)
  FieldTransition.install(engine("src.core.game3.warp"))
  local self = setmetatable({
    scene = opts.scene, billboards = opts.billboards, panel = opts.panel,
    camera = opts.camera, source = opts.source, log = opts.log or print,
    canvases = {}, ground = 0, prepared = false, frame = 0,
    shadows = opts.shadows ~= false, mips = opts.mips ~= false, haze = opts.haze ~= false,
    hostApi = opts.hostApi, weatherHost = opts.weatherHost, -- worker "atmos" (GW-P1/P2)
  }, View)
  self.lightingClock=opts.lightingClock
  self.light = { sun = Light.SUN, fill = Light.FILL, terms = Light.TERMS, hscale = Light.HSCALE }
  self.healerBalls = HealerBalls.new()
  self.caveDark = CaveDark.new(engine, Shaders, self.hostApi, opts.darkGate)
  return self
end

function View:darkHandled(game)
  -- Routing precedes prepare. Invalidate cached healer balls on map/session
  -- changes before they can keep a new dark cave on the flat fallback forever.
  if self.healerBalls and (self.healerBalls.count or 0)>0 then
    self.healerBalls:context(self.scene,game)
  end
  return self.caveDark:update(game, Actors.player(), self.camera.seat~=nil,
    self.healerBalls and (self.healerBalls.count or 0)>0)
end

function View:canvas(slot, w, h)
  local c = self.canvases[slot]
  if c and c:getWidth() == w and c:getHeight() == h then return c end
  if c and c.release then pcall(c.release, c) end
  local ok, nc = pcall(love.graphics.newCanvas, w, h, { dpiscale = 1 })
  if not ok or not nc then return nil end
  nc:setFilter("linear", "linear")
  self.canvases[slot] = nc
  return nc
end

-- Once per frame, BEFORE the XR frame (and in panel frames too): scene
-- placement + a budgeted slice of map building (review item 11). Applies the
-- seamless re-root shift to the camera, or snaps it after a warp (item 18).
-- opts = { budgetMs }
function View:pump(game, opts)
  local p = Actors.player()
  local cam = self.camera
  local focus = p and { x = p.x, z = p.z } or nil
  if focus and self.scene.rootId == nil then focus = nil end
  local sx, sz, changed = self.scene:pump(game, {
    budgetMs = opts and opts.budgetMs or 6, focus = focus, far = self.farCells or 60,
    deferRoot = self.deferRoot == true, -- Lab 60: set by main.lua while the Loading screen is on
  })
  if sx then
    cam:shift(sx, sz)
    if self.scene.retroGrass then self.scene.retroGrass.motion:shift(sx,sz,self.scene.rootId) end
  elseif changed then
    cam:reset()
    if self.scene.retroGrass then self.scene.retroGrass.motion:clear() end
  end
  -- W4 P2: sx/sz appended (changed stays first -- every existing caller
  -- reads only that one) so a root_shift consumer can report the actual
  -- cell offset instead of nil,nil. nil when this call was not a seamless
  -- re-root (either nothing changed, or root changed via a snap/reset,
  -- which cam:reset() already handles with no shift amount to report).
  return changed, sx, sz
end

-- Once per frame. `headPose` (LOCAL, optional) orients the sprite cards.
-- opts = { cameraOffset = {x, z} cells (cutscene camera object) }
function View:prepare(game, dt, headPose, opts)
  FrFog.clouds(self, nil)
  self.prepared = false
  self.caveDark.frame.enabled = false
  self.frame = self.frame + 1
  -- Lab 55 FRAME HOIST (review R1): the Shaders uniform cache trusts LOVE to
  -- keep a shader's uniforms. After a long frame gap (pause/resume, which can
  -- reload the graphics context) and every 600 frames it is emptied, so every
  -- cached value is sent again on the next draw.
  if Perf.hoist and ((tonumber(dt) or 0) > 0.25 or self.frame % 600 == 0) then Shaders.invalidateCache() end
  -- Lab 8 (CHECK "Missing" 1): sample the 60 Hz -> display blend once per
  -- frame, before the camera and the cards read any position
  Actors.beginFrame(dt)
  self.healerBalls:prepare(self.scene, game, dt,
    self.scene:ready() and Actors.player() ~= nil and not (opts and opts.battle))
  if not self.scene:ready() then
    if self.scene.retroGrass then self.scene.retroGrass.motion:clear() end
    return false, self.scene:rootFailure() or "building"
  end
  local p = Actors.player()
  if not p then
    if self.scene.retroGrass then self.scene.retroGrass.motion:clear() end
    return false,"no player"
  end
  local ground = self.scene:nativeHeightAt(p.x, p.z)
  if self.scene.retroGrass then
    local rm=self.camera.mode=="first" and not self.camera.seat and self.camera.room or nil
    local gx,gz=p.x+(rm and rm.wx or 0),p.z+(rm and rm.wz or 0)
    self.scene.retroGrass:update(dt,gx,self.scene:heightAt(gx,gz) or ground or 0,gz,self.scene.rootId)
  end
  if ground then self.ground = ground end
  local cam = self.camera
  local off = opts and opts.cameraOffset
  -- W6 (battle P-B1): { hideActors, cullX, cullZ } from BattlePass:viewOpts()
  local battle = opts and opts.battle
  local tx, tz = doorGuard(self, cam, p, game) -- Lab 8 (P2)
  local projectedX,_,projectedZ=self.scene:nativeToWorld(tx,tz)
  self.fieldTransition = self.fieldTransition or FieldTransition.new()
  local held = self.fieldTransition:update(dt, engine("src.core.game3.warp"), cam)
  if not held then cam:update(dt, { x = projectedX, z = projectedZ, ground = self.ground, facing = p.facing,
    offsetX = off and off[1], offsetZ = off and off[2],
    blended = Actors.blending() }) end -- Lab 8
  local darkOK,darkWhy=self.caveDark:update(game,p,battle~=nil and battle~=false or cam.seat~=nil,(self.healerBalls.count or 0)>0)
  if not darkOK and self.caveDark.required and not battle and not cam.seat then return false,darkWhy end
  local m = cam:metresPerCell()
  local outdoor = self.source.isOutdoor(self.scene.rootDef)
  self.outdoor = outdoor
  -- interiors-team (V2, repair2): the sky over an open-air interior
  self.openAirSky = false
  if not outdoor and View.OPEN_AIR_SKY and type(self.scene.rootOpenAir) == "function" then
    local okO, vO = pcall(self.scene.rootOpenAir, self.scene)
    self.openAirSky = okO and vO == true
  end
  local diorama = cam.vr and cam.mode == "overview" and not cam.seat -- W6: the seat is life size
  if outdoor and self.haze and not diorama then
    local base = cam:focusDistance()
    self.fog = { base + View.FOG_START, base + View.FOG_END, View.FOG_MAX }
  else
    self.fog = { 1000, 2000, 0 }
  end
  -- worker "atmos" (GW-P1, DESIGN.md 3.3): one resolved atmosphere per
  -- frame, outdoors only (identity indoors/caves, DESIGN.md 4.8). The clock
  -- comes from vrHost.clock (highest-priority live provider, DESIGN.md 4.4
  -- B); with none registered yet (pre-GW-P2, or TWS/RTC/BR not loaded)
  -- resolveClock() returns nil and the grade stays identity (today's look,
  -- DESIGN.md 2.6 "Neither" row). Sky.setPalette must run BEFORE
  -- Sky.fogColor() below reads Sky.HORIZON. publishAtmosphere runs
  -- UNCONDITIONALLY (bug found live, desktop proof w8_driver.lua "indoors:
  -- atmosphere.get() is nil" FAIL before this fix): otherwise stepping
  -- indoors leaves the last outdoor grade published forever, since nothing
  -- else ever clears it.
  self.atmos = nil
  if outdoor then
    local hour, hostApi = 12, self.hostApi
    if hostApi then
      local r = hostApi:resolveClock()
      if r and type(r.hour) == "number" then hour = r.hour end
    end
    local okA, atmos = pcall(AtmosState.compute, V.require("render/Gen3StormGrade").context(self, hour))
    if okA and atmos then
      self.atmos = atmos
      pcall(Sky.setPalette, atmos.sky)
      if atmos.fog then self.fog = { atmos.fog.start, atmos.fog["end"], atmos.fog.max } end
    end
  end
  -- Masks and directional lighting publish as one solar commit. Indoor
  -- contact shading retains the original identity/default light.
  self.light.sun = outdoor and Light.SUN or Light.DEFAULT_SUN
  self._solarTerms = self._solarTerms or { Light.TERMS[1], 0, Light.TERMS[3] }
  self._solarTerms[2] = Light.TERMS[2] * (Light.solarWeight or 0)
  self.light.terms = outdoor and self._solarTerms or Light.TERMS
  if self.atmos and outdoor then
    local w = Light.solarWeight or 0
    self.atmos.terms[2] = self.atmos.terms[2] * w
    self.atmos.shadowFade = self.atmos.shadowFade * w
  end
  if self.hostApi then self.hostApi:publishAtmosphere(self.atmos) end
  -- Lab 11 (user 2026-10-02): a moderately heavier haze in outdoor 3D battles, so surrounding trees and
  -- clutter soften instead of glitching at the edges; the arena itself (up to the foe) stays clear. Never
  -- lighter than the current fog (weather may already be heavier).
  if battle and outdoor and self.fog[3] > 0 and View.BATTLE_FOG then
    local base = cam:focusDistance()
    self.fog = { math.min(self.fog[1], base + View.BATTLE_FOG_START), math.min(self.fog[2], base + View.BATTLE_FOG_END),
      math.max(self.fog[3], View.FOG_MAX) }
  end
  -- Lab 55 DRAW RANGE (OutdoorPerf.drawRange, a look trade): an outdoor haze
  -- that ends nearer, and with it the cull radius below (fog max is raised to
  -- the default cut-off so the cull follows the haze end). FULL = Lab 52.
  local rangeEnd = outdoor and not diorama and Perf.FOG_END[Perf.drawRange]
  if rangeEnd and self.fog[3] > 0 then
    local base = cam:focusDistance()
    local cap = base + rangeEnd
    local f1, f2 = self.fog[1], self.fog[2]
    if f2 > cap then
      local span = f2 - base
      local start = span > 0 and base + (f1 - base) * (rangeEnd / span) or f1
      self.fog = { math.min(f1, start), cap, math.max(self.fog[3], View.FOG_MAX) }
    elseif self.fog[3] <= 0.9 then
      self.fog = { f1, f2, View.FOG_MAX }
    end
  end
  self.fogColor = outdoor and Sky.fogColor() or INDOOR_CLEAR
  local hx, hy, hz = cam:eyeWorld(headPose)
  self.viewX, self.viewY, self.viewZ = hx, hy, hz
  -- Culling radius and centre (item 13). First/third person: from the eye,
  -- out to the end of the haze (maps past it are fully hazed). 3/4 view:
  -- centred on the trainer, whom the eye sits 7-9 cells behind; the Quest
  -- table-top model has no haze, so it uses a fixed cell radius.
  if cam.mode == "overview" and not cam.seat then -- W6
    self.cullX, self.cullZ = cam.x or p.x, cam.z or p.z
    if diorama then
      self.farCells = Camera.DIORAMA_FAR_CELLS
    elseif self.fog[3] > 0.9 then
      self.farCells = (self.fog[2] - cam:focusDistance()) / m + 6
    else
      self.farCells = Camera.FAR / m + 6
    end
  else
    self.cullX, self.cullZ = hx, hz
    local farM = self.fog[3] > 0.9 and self.fog[2] or Camera.FAR
    self.farCells = farM / m + 6
  end
  -- W6 (battle P-B1): cull around the battle arena
  if battle and battle.cullX and battle.cullZ then
    self.cullX, self.cullZ = battle.cullX, battle.cullZ
  end
  self.fogFar = self.fog[3] > 0 and (self.fog[2] + View.FOG_FULL_CELLS * m) or 0
  -- Match the existing horizontal cull circle, once for both eyes.
  local radial = outdoor and not diorama and self.fog[3] > 0.9
  self._radialFog = self._radialFog or {0,0,0,0}
  self._cameraFog = self._cameraFog or {0,0,0}
  local rf=self._radialFog
  rf[1],rf[2],rf[3],rf[4]=self.cullX,self.cullZ,m,
    cam.mode == "overview" and not cam.seat and cam:focusDistance() or 0
  self.radialFog = radial and rf or nil
  FrFog.clouds(self, radial and not self.caveDark.frame.enabled and self.fogColor or nil)
  self.scene.shrubFace = Shrubs.basis(cam,self.scene.shrubFace)
  self.scene.treeFace=self.scene.shrubFace -- one untracked rig basis shared by both eyes
  self.visibleMaps = self.scene:prepareFrame({
    camX = self.cullX, camZ = self.cullZ, far = self.farCells, frame = self.frame, mips = self.mips,
    eye = roomEye(self, hx, hy, hz), roomMode = View.roomMode(cam), roomFocus = roomFocus(self, cam), -- interiors-team (V1)
  })
  local scene = self.scene
  if scene.lighting then
    local frame=LightingContext.frame(game,self.lightingClock)
    local gated=scene.lighting:isBlocked(Mr.s,self.caveDark.frame,battle,cam.seat~=nil)
    scene.lighting:prepare(scene.visible,scene.rootId,frame,outdoor and not gated)
    if self._lightingMap~=scene.rootId or self._lightingDef~=scene.rootDef or self._lightingGeneration~=scene.lighting.policy.generation then
      self._lightingMap,self._lightingDef,self._lightingGeneration=scene.rootId,scene.rootDef,scene.lighting.policy.generation
      self._indoorLighting=scene.lighting.policy:indoor(LightingContext.indoor(scene.rootId,scene.rootDef))
    end
    self.worldLighting=not outdoor and not gated and self._indoorLighting or nil
  end
  -- R2: water share per horizon sector -> sky band, clear colour, sea plane
  self.sea, self.seaShare = nil, 0
  if outdoor then
    local okV, sv = pcall(scene.seaView, scene, hx, hz, Sky.SEG)
    sv = okV and sv or nil
    Sky.setBands(sv and sv.frac or nil)
    self.seaShare = sv and sv.overall or 0
    if sv and not diorama then self.sea = sv end
  end
  -- R5: 3/4 view (desktop and diorama): every card faces minus the camera's
  -- forward, flattened; first and third person keep facing the eye
  -- Lab 58 (#1, #2, #7): with the card switches on, the card env is one table reused every frame, and its
  -- heightAt / shadowAt are two functions made once per view (they read self.scene at call time) instead of two
  -- closures and a table per frame; cardDir is reused too.
  local spCull = okSp58 and Speed58.on("cardcull")
  local spMemo = okSp58 and Speed58.on("actormemo")
  local bbReuse = spCull or spMemo
  local cardDir
  if cam.mode == "overview" and not cam.seat then -- W6
    local yaw = cam.vr and cam:worldLookYaw(headPose) or (cam.yaw or 0)
    if bbReuse then
      cardDir = self._cardDirT
      if not cardDir then cardDir = { 0, 0 }; self._cardDirT = cardDir end
      cardDir[1], cardDir[2] = math.sin(yaw), math.cos(yaw)
    else
      cardDir = { math.sin(yaw), math.cos(yaw) }
    end
  end
  -- W6 (battle P-B1): hide every overworld card (NPCs, the player, provider
  -- cards) while the battle is staged
  local nativeCullX,nativeCullZ=self.scene:worldToNative(self.cullX,self.cullZ)
  local actors = (battle and battle.hideActors) and NO_ACTORS or CavePlacement.actors(self.scene,Actors.collect(game, nativeCullX, nativeCullZ, self.farCells)) -- Lab 58: cull circle for the ghost cards
  if bbReuse then
    local e = self._bbEnv
    if not e then
      e = {}
      self._bbEnv = e
      self._bbHeightAt = function(x, z) return self.scene:heightAt(x, z) end
      self._bbShadowAt = function(x, z) return self.scene:shadowAt(x, z) end
    end
    e.viewX, e.viewZ = hx, hz
    e.skyRecords = scene.visible -- shared loaded scenery bounds, not per-eye visibility
    e.heightAt = self._bbHeightAt
    e.shadowAt = self.shadows and self._bbShadowAt or nil
    e.defaultGround = self.ground
    e.hidePlayer = cam.vr == true or cam.mode == "first"
    e.cardScale = cam:cardScale()
    e.cardDir = cardDir
    e.outdoor = outdoor
    e.shadowFade = self.atmos and self.atmos.shadowFade
    -- the cull centre and radius the scene itself uses (cells); the billboards add their own margin
    e.cullX, e.cullZ, e.cullFar = self.cullX, self.cullZ, self.farCells
    e.clock = Actors.clock -- Lab 58: scale-in age clock (cardscale)
    e.memoEpoch = spMemo and scene.probeEpoch and scene:probeEpoch() or nil
    self.billboards:prepare(actors, e)
  else
  self.billboards:prepare(actors, {
    viewX = hx, viewZ = hz,
    skyRecords = scene.visible,
    heightAt = function(x, z) return scene:heightAt(x, z) end,
    shadowAt = self.shadows and function(x, z) return scene:shadowAt(x, z) end or nil,
    defaultGround = self.ground,
    hidePlayer = cam.vr == true or cam.mode == "first", -- shared local-trainer headset visibility
    cardScale = cam:cardScale(),
    cardDir = cardDir,
    outdoor = outdoor,
    shadowFade = self.atmos and self.atmos.shadowFade, -- worker "atmos" (GW-P1)
    clock = Actors.clock, -- Lab 58: scale-in age clock (cardscale)
  })
  end
  -- FireRed's location preview (Viridian Forest, caves) paints full-screen
  -- artwork into the UI plane: over the 3D view keep only its name banner
  -- (Panel.maskPreview; both the desktop overlay and the Quest card read the
  -- plane after this point in the frame)
  self.previewCut = false
  local panel = self.panel
  if panel and panel.maskPreview then
    local okM, cut = pcall(panel.maskPreview)
    self.previewCut = okM and cut or false
  end
  self.prepared = true
  return true
end

function View:setShadows(on)
  self.shadows = on ~= false
  if self.scene.setShadows then self.scene:setShadows(self.shadows) end
end

-- Lab 8 (sun/moon): the view focus handed to the weather layer for one eye.
-- TWS's sky layer (CelestialBodies.drawWorld = sun and moon, NightSky = the
-- stars) builds its billboard axes from focus - eye and draws nothing when
-- that is zero, which is what focus = nil gave it (WeatherHostLib._setEye
-- then sets focus = eye). The Gen 1/2 Quest hosts hand it the eye plus the
-- eye's own forward, one LOCAL metre out (VRRig.eyeCamera). Same here: the
-- forward is this eye's view matrix -Z row (head pose, desktop pitch and the
-- rig's turn included), so each eye gets its own. The disc and star
-- orientation itself stays world-fixed inside TWS (WorldCelestialDisc.axes,
-- stableStarBillboards); the focus only lets them draw (TWS's Gen 3 layer,
-- compat/gen3/Gen3SunMoon.lua, sizes the discs and keeps the costly star
-- field off). One scratch table:
-- _setEye copies it into its own pixel table, TWS never keeps ours.
local weatherEnvScratch = { focus = { x = 0, y = 0, z = 0 } }
local function weatherEnvFor(view, ex, ey, ez, m)
  -- the view's 3x3 rows are the eye's axes in world cells, scaled by m
  local fx, fy, fz = -view[9], -view[10], -view[11]
  local len = math.sqrt(fx * fx + fy * fy + fz * fz)
  if not (len > 1e-9) or not (m and m > 0) then return nil end
  local s = 1 / (len * m) -- unit forward, times one metre in cells
  local f = weatherEnvScratch.focus
  f.x, f.y, f.z = ex + fx * s, ey + fy * s, ez + fz * s
  return weatherEnvScratch
end
View._weatherEnvFor = weatherEnvFor -- test seam

local function renderBody(self, canvas, eye, opts)
  local cam = self.camera
  local view = cam:eyeView(eye.pose, opts.pitch)
  local P = Mat4.flipY(Mat4.fovProjection(eye.fov.angleLeft, eye.fov.angleRight,
    eye.fov.angleUp, eye.fov.angleDown, Camera.NEAR, Camera.FAR))
  local vp = Mat4.mul(P, view)
  local g = love.graphics
  -- worker "atmos" (GW-P1, DESIGN.md 3.3 step 6): the resolved atmosphere
  -- (nil indoors/pre-clock) supplies this eye's grade and, outdoors, the
  -- shadow-fade terms; Light.TERMS/Light.SUN/Light.FILL stay the fixed-sun
  -- default otherwise (Light.lua's own doc comment cross-references this).
  local atmos = self.atmos
  local env
  if Perf.hoist then
    -- Lab 55 FRAME HOIST: the eye-independent env fields are built once per
    -- frame (View:prepare bumps self.frame) into reused tables; only vp is
    -- per eye. Same values as the Lab 52 per-eye tables below.
    env = self._frameEnv
    if not env then env = { light = {}, gradeT = {} }; self._frameEnv = env end
    if env.frame ~= self.frame then
      local light = self.light
      if atmos and atmos.terms then
        local l = env.light
        l.sun, l.fill, l.terms, l.hscale = self.light.sun, self.light.fill, atmos.terms, self.light.hscale
        light = l
      end
      env.lightRef = light
      if atmos then
        local gr = env.gradeT
        gr.mul, gr.add, gr.shadowFade = atmos.mul, atmos.add, atmos.shadowFade
        gr.emitGain = atmos.emissive and atmos.emissive.gain
        gr.emitColor = atmos.emissive and atmos.emissive.color
        gr.poolGain = atmos.pools and atmos.pools.gain
        gr.poolColor = atmos.pools and atmos.pools.color
        gr.waterFade, gr.waterDark = atmos.waterFade, atmos.waterDark
        env.gradeRef = gr
      else
        env.gradeRef = nil
      end
      env.emissiveProvider = self.hostApi and self.hostApi:emissiveProvider() or nil
      env.frame = self.frame -- last: a throw above rebuilds again next eye
    end
    env.light, env.grade, env.vp = env.lightRef, env.gradeRef, vp
    -- per call, not per frame (review D1): the tablet camera render
    -- (HostApi:renderCameraView) shortens view.farCells for its own eye in
    -- the same frame; plain field copies, no allocation
    env.fog = self.fog or INDOOR_FOG
    env.fogColor = self.fogColor or INDOOR_CLEAR
    env.shadows, env.fogFar = self.shadows, self.fogFar or 0
    env.camX = self.cullX or self.viewX or cam.x or 0
    env.camZ = self.cullZ or self.viewZ or cam.z or 0
    env.far = self.farCells or 60
  else
    local light = self.light
    if atmos and atmos.terms then
      light = { sun = self.light.sun, fill = self.light.fill, terms = atmos.terms, hscale = self.light.hscale }
    end
    env = {
      vp = vp, light = light, fog = self.fog or { 1000, 2000, 0 },
      fogColor = self.fogColor or INDOOR_CLEAR, shadows = self.shadows, fogFar = self.fogFar or 0,
      camX = self.cullX or self.viewX or cam.x or 0, camZ = self.cullZ or self.viewZ or cam.z or 0,
      far = self.farCells or 60,
      grade = atmos and { mul = atmos.mul, add = atmos.add, shadowFade = atmos.shadowFade,
        emitGain = atmos.emissive and atmos.emissive.gain, emitColor = atmos.emissive and atmos.emissive.color,
        poolGain = atmos.pools and atmos.pools.gain, poolColor = atmos.pools and atmos.pools.color,
        waterFade = atmos.waterFade, waterDark = atmos.waterDark } or nil, -- coordinator review round 2
      emissiveProvider = self.hostApi and self.hostApi:emissiveProvider() or nil,
      frame = self.frame, -- Lab 55: EYE SCRATCH emissive memo key
    }
  end
  env.radialFog=self.radialFog
  env.fog,env.fogFar=FrFog.limit(env.fog,env.fogFar,env.radialFog,env.far,self._cameraFog)
  env.fogBackdrop=nil
  if env.radialFog and env.fog[3]>.9 and not self.caveDark.frame.enabled then
    local fx,fy,fz=cam:eyeWorld(eye.pose)
    self._fogEye=self._fogEye or {};self._fogEye[1],self._fogEye[2],self._fogEye[3]=fx,fy,fz
    self._fogBackdrop=Sky.fogBackdrop(self._fogEye,self._fogBackdrop)
    env.fogBackdrop=self._fogBackdrop
  end
  env.worldLighting=self.worldLighting
  env.lightingManaged=self.scene.lighting~=nil
  env.nativeFlash = self.caveDark.frame
  env.dark = env.nativeFlash.enabled and env.nativeFlash or nil
  local pt = self._pacerPass -- Lab 55 (G0): FramePacer pass observer (nil = not timing)
  local EL = self.eyeLedger -- Lab 60: creation ledger (nil = disarmed); setPhase labels the pass for the "slow eye" log
  if EL then EL.setPhase("eyeSetup") end
  local t0
  local calls = 0
  g.setCanvas(Mr.s and Mr.s:eyeTarget(opts.eyeIndex, canvas) or { canvas, depth = true }) -- PORTAL_MR P1: readable depth only while the pulled floor is captured
  g.origin()
  g.setScissor()
  -- review R1: outdoors, anything the sky cylinder does not cover is below
  -- it -- clear to the same forest haze as its below-horizon band
  local clear = (self.outdoor or self.openAirSky) and Sky.clearColor(self.seaShare) or env.fogColor -- interiors-team (V2)
  g.clear(clear[1], clear[2], clear[3], 1, false, true)
  g.setBlendMode("alpha")
  g.setColor(1, 1, 1, 1)
  g.setMeshCullMode("none")
  if self.outdoor or self.openAirSky then -- interiors-team (V2): + open-air interiors
    local ex, ey, ez = cam:eyeWorld(eye.pose)
    if EL then EL.setPhase("sky") end
    t0 = pt and pt.clock()
    calls = calls + Sky.draw(vp, { ex, ey, ez }, cam:metresPerCell(), env)
    calls = calls + Horizons.draw(vp, {ex,ey,ez}, cam:metresPerCell(), env, self.scene.rootId, self.outdoor)
    if t0 then pt.sample(PASS_SKY, t0) end
  end
  g.setDepthMode("lequal", true)
  if self.sea then
    t0 = pt and pt.clock()
    local okS, n = pcall(Sea.draw, env, self.sea, { self.viewX or 0, self.viewZ or 0 },
      cam:metresPerCell(), self.frame, Sky.SEG)
    if okS then calls = calls + (n or 0) end
    if t0 then pt.sample(PASS_SEA, t0) end
  end
  -- W6 (battle P-B1): while a battle is staged, world geometry between the
  -- seat and the battlers (and around a synthetic stage) is cut away
  local cutting = opts.battle and opts.battle.beginCut and opts.battle:beginCut(env) or false
  local ok, err
  if EL then EL.setPhase("scene") end
  t0 = pt and pt.clock()
  if cutting then
    local okD, a, b = pcall(self.scene.draw, self.scene, env)
    opts.battle:endCut()
    if okD then ok, err = a, b else ok, err = false, a end
  else
    local mrClip = Mr.s and Mr.s:clipBegin(env, eye) -- PORTAL_MR P1: the portal terrain clip (never inside a battle cut)
    ok, err = self.scene:draw(env)
    if mrClip then Mr.s:clipEnd() end
  end
  if t0 then pt.sample(PASS_SCENE, t0) end
  if ok then
    calls = calls + (self.scene.frameCalls or 0)
    t0 = pt and pt.clock()
    calls = calls + self.healerBalls:draw(env)
    if t0 then pt.sample(PASS_HEALER, t0) end
    if Mr.s then Mr.s:capture(opts.eyeIndex, canvas, eye, opts.veil) end -- PORTAL_MR P1: the pulled floor (ground, water), before any card
    t0 = pt and pt.clock()
    calls = calls + self.billboards:drawBlobs(env)
    if t0 then pt.sample(PASS_BLOBS, t0) end
    t0 = pt and pt.clock()
    calls = calls + self.billboards:draw(env)
    if t0 then pt.sample(PASS_CARDS, t0) end
    -- worker "atmos" (GW-P2, DESIGN.md 4.5 step 6): TWS's sky pieces (sun,
    -- moon, stars, aurora, the cloud deck), depth-tested against the
    -- terrain, no depth write -- drawing AFTER Scene:draw hides them behind
    -- it correctly (reading-voxel-renderer-sky-light.md 4.5 "why no
    -- separate sky pass"). Runs in desktop mono too (DESIGN.md 4.5: "one
    -- anchored edit makes steps 6 and 8 run there too"), unlike the vrHost
    -- layer slot below, which only runs on Quest/side-by-side.
    local weatherEyeX, weatherEyeY, weatherEyeZ = cam:eyeWorld(eye.pose, opts.pitch)
    local weatherEye = { vp = vp, pos = { x = weatherEyeX, y = weatherEyeY, z = weatherEyeZ } }
    -- Lab 8 (sun/moon): a real per-eye focus, but only for an eye that drew
    -- the sky above (outdoors, battles included); indoors and in caves it
    -- stays nil (focus = eye), so no sun, moon or stars are drawn there.
    -- The sky pass runs BEFORE the battle cards below: those (battlers, HP
    -- cards, move bands, the move-background curtain) draw with no depth
    -- write, so a sky pass after them saw only the sky's depth behind a card
    -- and painted the sun or moon over it. Drawn first, the cards cover it.
    -- Terrain, buildings, trees and the billboards above do write depth, so
    -- they still hide it.
    local weatherEnv = self.outdoor and weatherEnvFor(view, weatherEyeX, weatherEyeY, weatherEyeZ,
      cam:metresPerCell()) or nil
    if EL then EL.setPhase("weatherSky") end
    t0 = pt and pt.clock()
    if self.weatherHost and not (env.dark and env.dark.enabled) then
      local facade=self.weatherHost.hostLib._modules.Voxel3D
      facade.horizonCloudLift=Horizons.active(self.scene.rootId,self.outdoor) and 480 or nil
      self.weatherHost:sky(weatherEye, weatherEnv)
      facade.horizonCloudLift=nil
    end
    if t0 then pt.sample(PASS_WSKY, t0) end
    -- W6 (battle P-B1): battle cards (battlers, HP, shadow blobs, synthetic
    -- platform), depth-tested against the terrain, before the vrHost layer slot.
    if opts.battle then
      t0 = pt and pt.clock()
      local okB, nB = pcall(opts.battle.drawEye, opts.battle, env)
      if okB then
        calls = calls + (tonumber(nB) or 0)
      else
        self.log("[FRLG_VOXEL] battle draw slot: " .. tostring(nB))
      end
      if t0 then pt.sample(PASS_BATTLE, t0) end
    end
    -- W4: the vrHost layer slot (VRITK, the P1 probe, ...). Still depth-on,
    -- still inside this function's push("all")/pcall/pop (View:renderEye
    -- below), so a throwing layer cannot leave the stack pushed or this
    -- eye's canvas in an unknown state; HostLayers:draw itself never
    -- raises (own doc comment), the pcall here is redundant defence only.
    local mrProps = Mr.s and Mr.s:propsBegin(opts.eyeIndex, canvas) -- PORTAL_MR P1: hands and companions on their own layer
    if opts.hostApi and opts.eyeIndex then
      if EL then EL.setPhase("hostLayers") end
      t0 = pt and pt.clock()
      local ex, ey, ez = weatherEyeX, weatherEyeY, weatherEyeZ
      local okL, errL = pcall(opts.hostApi.drawEye, opts.hostApi, {
        index = opts.eyeIndex, name = opts.eyeIndex == 1 and "left" or "right",
        vp = vp, proj = P, view = view, nativeFlash = env.nativeFlash, worldLighting=env.worldLighting, pos = { x = ex, y = ey, z = ez },
      })
      if not okL then self.log("[FRLG_VOXEL] host layer draw slot: " .. tostring(errL)) end
      if t0 then pt.sample(PASS_HOST, t0) end
    end
    -- worker "atmos" (GW-P2, DESIGN.md 4.5 step 8): storm bolts, rain/snow
    -- (Voxel3D.endScene, a no-op until GW-P3), after the vrHost layer slot
    -- so near weather draws over VRITK hands/catch FX, before the UI card.
    if mrProps then Mr.s:propsEnd(opts.eyeIndex, mrProps) end
    if EL then EL.setPhase("weatherLate") end
    t0 = pt and pt.clock()
    if self.weatherHost and not (env.dark and env.dark.enabled) then self.weatherHost:late(weatherEye, weatherEnv) end
    if t0 then pt.sample(PASS_WLATE, t0) end
  end
  g.setDepthMode()
  if ok and opts.showCard and opts.uiCanvas then
    t0 = pt and pt.clock()
    local pos = eye.pose and eye.pose.pos or { 0, 0, 0 }
    local q = eye.pose and eye.pose.quat or { 0, 0, 0, 1 }
    local eyeLocal = Mat4.mul(Mat4.transpose(Mat4.fromQuat(q[1], q[2], q[3], q[4])),
      Mat4.translate(-pos[1], -pos[2], -pos[3]))
    local mrCard = Mr.s and Mr.s:propsBegin(opts.eyeIndex, canvas, true) -- PORTAL_MR P1: the UI card stays whole outside the window
    if mrCard then -- (pcall: the layer's push is always popped before an error goes on)
      local okC, errC = pcall(self.panel.drawCard, self.panel, P, eyeLocal, opts.uiCanvas)
      Mr.s:propsEnd(opts.eyeIndex, mrCard)
      if not okC then error(errC, 0) end
    else
      self.panel:drawCard(P, eyeLocal, opts.uiCanvas)
    end
    calls = calls + 1
    if t0 then pt.sample(PASS_UICARD, t0) end
  end
  -- W6 r3 (battle P-B3): a full-screen move effect (invert, greyscale, ...)
  -- over this eye's world image, before the command card (the GBA keeps its
  -- text box out of these effects too)
  if ok and opts.battle and opts.battle.postEye then
    local okP, errP = pcall(opts.battle.postEye, opts.battle, canvas)
    if not okP then self.log("[FRLG_VOXEL] battle screen effect slot: " .. tostring(errP)) end
  end
  -- W6 (battle P-B1): the battle command card, LOCAL space, depth off
  if ok and opts.battle then
    local pos = eye.pose and eye.pose.pos or { 0, 0, 0 }
    local q = eye.pose and eye.pose.quat or { 0, 0, 0, 1 }
    local eyeLocal = Mat4.chain(Mat4.transpose(Mat4.fromQuat(q[1], q[2], q[3], q[4])),
      Mat4.translate(-pos[1], -pos[2], -pos[3]),
      opts.pitch and Mat4.rotX(-opts.pitch) or Mat4.identity())
    local okO, nO = pcall(opts.battle.drawOverlay, opts.battle, P, eyeLocal)
    if okO then
      calls = calls + (tonumber(nO) or 0)
    else
      self.log("[FRLG_VOXEL] battle card slot: " .. tostring(nO))
    end
  end
  local veil = self.fieldTransition and self.fieldTransition:veil(opts.veil) or opts.veil
  if veil and (veil[4] or 0) > 0 then
    g.setShader()
    g.setColor(veil[1] or 0, veil[2] or 0, veil[3] or 0, veil[4])
    g.rectangle("fill", 0, 0, canvas:getWidth(), canvas:getHeight())
  end
  self.eyeCalls = calls
  self.eyeTris = (self.scene.frameTris or 0) + 2 * (self.billboards.count or 0)
    + 2 * (self.billboards.blobCount or 0)
  if not ok then return false, err end
  return true
end

-- One view into `canvas`. eye = { pose = LOCAL pose, fov = angles },
-- opts = { pitch, uiCanvas, showCard, veil = {r,g,b,a} }
-- The body runs between push("all") and a pop() that always happens, so a
-- throw can never leave the eye canvas bound or leak a stack level (item 1).
function View:renderEye(canvas, eye, opts)
  opts = opts or {}
  local g = love.graphics
  g.push("all")
  local ok, a, b = pcall(renderBody, self, canvas, eye, opts)
  g.pop()
  if not ok then return false, "render error: " .. tostring(a) end
  return a, b
end

function View:release()
  FieldTransition.uninstall(engine("src.core.game3.warp"))
  FrFog.clouds(self, nil)
  self.healerBalls:release()
  for k, c in pairs(self.canvases) do
    if c.release then pcall(c.release, c) end
    self.canvases[k] = nil
  end
  Horizons.release()
  Sky.release()
  Sea.release()
  local _ = Shaders
end

return View
