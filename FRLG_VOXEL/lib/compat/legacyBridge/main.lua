-- VRITK_FRLG_HOST: republishes FRLG_VOXEL's vrHost API 1 as the Gen2 host
-- contract VRITK (the lab copy of VR_INTERACTIONS_BACKPACK_LAB) already
-- speaks -- vritk-hook/DESIGN.md section 2, phase P2. FireRed/LeafGreen
-- only; depends on FRLG_VOXEL. Never touches mod.device.questVR directly
-- (only FRLG_VOXEL may drive it -- DESIGN.md 1 "One frame owner").
--
-- What this file is NOT: a copy of BATTLE_ART_QUEST_COMPAT's 1600-line
-- render pipeline (perf probes, mirror bridges, second-screen JNI dodges --
-- all Gen2/Battle-Art-specific machinery FRLG_VOXEL has no equivalent of
-- and does not need). It borrows only the pieces VRITK's OWN rendering
-- code actually calls (checked against the fl16 source directly, see
-- lib/Voxel3DShim.lua's header) and re-derives the rest from FRLG_VOXEL's
-- vrHost ctx each frame (lib/PxContext.lua).
local mod = ...
local TAG = "[VRITK_FRLG_HOST]"

local function log(message) print(TAG .. " " .. tostring(message)) end

-- ------------------------------------------------------------ gate: Gen 3
-- Belt to the manifest's games brace (VRHOST_PROBE and FRLG_VOXEL both do
-- the same double-check).
local generation
do
  local ok, GV = pcall(require, "src.core.GameVersion")
  if ok and type(GV) == "table" and type(GV.generation) == "function" then
    local ok2, g = pcall(GV.generation)
    if ok2 then generation = g end
  end
end
mod.exports.api = 1
mod.exports.version = mod.version
if generation ~= 3 then
  log("inactive: generation " .. tostring(generation) .. " is not FireRed/LeafGreen")
  mod.exports.active = false
  return
end

-- ------------------------------------------------------------ module loader
-- Same shape as every other mod's own V.require (main.lua:5-15 pattern),
-- plus two special cases neither QC nor BV has a file for: "Voxel3D" (the
-- shim, one shared instance, not a class VRITK instantiates itself) and the
-- three battle-shaped stubs (Stubs.lua; DESIGN.md 2b).
local V = { mod = mod }
local cache = {}
local voxelInstance = nil

local function loadLocal(name)
  local source = mod:read("lib/" .. name .. ".lua")
  if not source then return nil end
  local chunk, err = load(source, "@" .. mod.path .. "/lib/" .. name .. ".lua")
  if not chunk then error(TAG .. " " .. tostring(err), 0) end
  return chunk(V)
end

function V.require(name)
  local cached = cache[name]
  if cached ~= nil then return cached end
  local value
  if name == "Voxel3D" then
    if not voxelInstance then
      voxelInstance = V.require("Voxel3DShim").new({ log = log })
    end
    value = voxelInstance
  elseif name == "QuestPokedexBridge" then
    value = V.require("Stubs").questPokedexBridge()
  elseif name == "BattleScene" then
    value = V.require("Stubs").battleScene()
  elseif name == "OverworldBattle" then
    value = V.require("Stubs").overworldBattle()
  else
    value = loadLocal(name)
    if value == nil then error(TAG .. " missing lib/" .. name .. ".lua", 0) end
  end
  if value == nil then value = false end
  cache[name] = value
  return value
end

local okMods, Mods = pcall(function()
  return {
    Mat4 = V.require("Mat4"),
    VRRig = V.require("VRRig"),
    QuestStereoLayers = V.require("QuestStereoLayers"),
    QuestHandProps = V.require("QuestHandProps"),
    VRHandPose = V.require("VRHandPose"),
    VRHandAssets = V.require("VRHandAssets"),
    QuestHandsRenderer = V.require("QuestHandsRenderer"),
    PxContext = V.require("PxContext"),
    Game3Data = V.require("Game3Data"),
    WorldPx = V.require("WorldPx"),
    QuestSecondScreen = V.require("QuestSecondScreen"),
    -- Gen3 compat layer (standing rule, 2026-09-28): VRITK's shared files
    -- (VR_INTERACTIONS_BACKPACK_LAB) and kanto_gear reach these only
    -- through mod.find("VRITK_FRLG_HOST").exports.compat, never by
    -- requiring them directly -- this mod loads on generation 3 only, so
    -- Gen1/Gen2 never see this table at all.
    Gen3TabletCompat = V.require("compat/Gen3TabletCompat"),
    Gen3GearCompat = V.require("compat/Gen3GearCompat"),
    -- Gen3 dex scanner (tablet), 2026-10-02: the live camera and the
    -- scan pause / numeric dex lookup / unknown page (lib/compat/).
    Gen3TabletCamera = V.require("Gen3TabletCamera"),
    Gen3DexScannerCompat = V.require("compat/Gen3DexScannerCompat"),
    Gen3PouchCompat = V.require("compat/Gen3PouchCompat"),
    Gen3LeadSwapCompat = V.require("compat/Gen3LeadSwapCompat"),
    Gen3NamingCompat = V.require("compat/Gen3NamingCompat"),
    -- Relocated from VR_INTERACTIONS_BACKPACK_LAB (lib/Gen3Contents.lua,
    -- lib/FishingGen3.lua) per the same standing rule: bag-icon rows and
    -- FireRed's own fishing now live here, reached by VRITK only through
    -- Gen3HostCompat, same as the three above.
    Gen3ContentsCompat = V.require("compat/Gen3ContentsCompat"),
    Gen3FishingCompat = V.require("compat/Gen3FishingCompat"),
    -- Lab 8: FireRed "I choose you" (battle opening + overworld send-out)
    -- and the party-belt fixes, installed into VRITK's own V through the
    -- one seam in VR_INTERACTIONS_BACKPACK_LAB/main.lua (compat.install).
    Gen3ChooseYouCompat = V.require("compat/Gen3ChooseYouCompat"),
    Gen3BeltCompat = V.require("compat/Gen3BeltCompat"),
    Gen3JuggleSpin = V.require("compat/Gen3JuggleSpin"),
  }
end)
if not okMods then
  log("disabled: a module failed to load: " .. tostring(Mods))
  mod.exports.active = false
  return
end

-- Lab 51 ALLOC TRIM flag (lib/AllocTrim.lua), default ON. OFF = the Lab 50
-- code paths below, unchanged. Exported as setAllocTrim/allocTrim at the end.
local Trim = V.require("AllocTrim")

-- ------------------------------------------------------------ state
local S = {
  vrHost = nil,        -- FRLG_VOXEL.exports.vrHost once bound (mods.loaded)
  registeredWithHost = false, -- this bridge's OWN vh.layers.register succeeded
  layerUpdates = 0,    -- CRITIQUE #11: distinguishes "registered" from "actually pumping"
  lastError = nil,
  lastMode = nil,       -- W4 review fix #4: last camera mode seen, for the first-person gate
  lastMenuOpen = false, -- W4 review fix #8c: previous frame's ctx.menuOpen, to find the rising edge
  menuHeld = nil,       -- W4 review fix #8c: {gripL=,gripR=,triggerL=} still-forwarded-through-the-menu set
  prevActive = nil,     -- W4 review fix #8c: {gripL=,gripR=,triggerL=} active-state as of the PREVIOUS layerUpdate call
  prevSpare = nil,      -- ALLOC TRIM: the other of the two alternating prevActive tables
  -- gear-hook DESIGN.md 2d: the QuestSecondScreen memoising view, installed
  -- once kanto_gear is actually loaded (see installSecondScreenBridge below).
  secondScreen = nil,
  secondScreenModule = nil,
  removeSecondScreenBridge = nil,
  secondScreenUnwanted = false, -- latched: kanto_gear was checked and is not present this session
}
-- Lab 58 approach loading (compat/ApproachLoader + compat/WildsAtlasCompat): the handle is built at the end of this
-- file (FireRed layout and this mod active only); declared here so the handlers below can reach it.
local approach
-- Gen3 dex scanner: the tablet camera host (one per process) and the bridge
-- hook (Gen3TabletCompat calls it with the Gear surface bridge it adopts).
S.tabletCamera = Mods.Gen3TabletCamera.new({ log = log })
Mods.Gen3TabletCompat.extend(Mods.Gen3DexScannerCompat.installBridge)

-- W4 review fix #3: the "hands" input claim -- grip stops pressing L/R, left
-- trigger stops pressing SELECT, the same three controls FRLG_VOXEL's own
-- HANDS_PROFILE_MASK names (HostApi.lua). Read-only every frame (Claims:claim
-- only iterates it), so one shared table is reused instead of allocating a
-- fresh one per layerUpdate call.
local CLAIM_MASK = { gripL = true, gripR = true, triggerL = true }

-- ------------------------------------------------------------ the vrHost-facing layer
-- Registered against FRLG_VOXEL's vh.layers (HostLayers.lua): update(ctx)
-- builds VRITK's px-frame context and pumps VRITK's OWN stereoLayers/
-- handProps registries; draw(record, eye) sets up the Voxel3D stand-in for
-- that eye and runs the CRITIQUE #6-documented per-eye order (StereoRenderer
-- .lua:201-210, verified against the fl16 source): HandProps.draw, then
-- StereoLayers.draw(records), then QuestHandsRenderer.draw.
--
-- layerInvalidate is declared BEFORE layerUpdate (review fix #3: as a later
-- local it would otherwise resolve as a nil global inside layerUpdate's
-- mode-exit call).
local function layerInvalidate()
  S.voxelActive = false
  -- CRITIQUE #1's principle applied where P2 actually reaches it: a host
  -- invalidate (stereo off, session stop, failure, mode change -- HostApi's
  -- own hard-invalidate rules, CRITIQUE #8) must propagate all the way down
  -- to VRITK's own registered layer, or a held backpack survives a state
  -- the player can no longer see it in. QuestStereoLayers.invalidate calls
  -- every registered layer's invalidate (VRITK's own controller:invalidate,
  -- gear:invalidate, etc. -- main.lua:308-314), and QuestHandProps.clear
  -- drops any in-flight hand-prop pose.
  Mods.Gen3TabletCompat.reset()
  pcall(Mods.QuestStereoLayers.invalidate)
  pcall(Mods.QuestHandProps.clear)
end

local function layerUpdate(ctx)
  S.layerUpdates = S.layerUpdates + 1

  -- W4 review fix #4 (Q6 "first person only" enforcement): VRITK's own
  -- scale/interaction math is tuned for FRLG_VOXEL's first-person rig only
  -- (10 px/m); third person and the 3/4 table-top view use a different
  -- metresPerCell and would place VRITK's backpack/hands 16x off. Track the
  -- camera mode here (ctx.rig.mode, from HostApi.rigFrame) and go idle the
  -- instant it is not "first" -- invalidating once, on the way OUT of first
  -- person, so a held prop does not survive into third person.
  local mode = (ctx.rig and ctx.rig.mode) or S.lastMode
  if mode ~= S.lastMode then
    if S.lastMode == "first" then layerInvalidate() end
    S.lastMode = mode
  end
  S.voxelActive = true
  if mode ~= "first" then return nil end

  -- W4 review fix #3: claim the hands controls every frame VRITK is
  -- actually live (at least one of its own registered layers is not
  -- failed-off), rather than a one-time setProfile("hands"). A per-frame
  -- claim self-expires the instant this bridge or every VRITK layer fails
  -- or is removed (HostApi.lua's Claims:beginCycle() clears `pending` at the
  -- top of every beginFrame, before this update pass runs); a sticky profile
  -- would keep suppressing L/R/SELECT forever once set. Forwarding VRITK's
  -- own handClaims (A/B/sticks) is a P3 follow-up, not this fix.
  if Mods.QuestStereoLayers.anyLive() then
    pcall(S.vrHost.input.claim, "VRITK_FRLG_HOST.bridge", CLAIM_MASK)
  end

  -- Review #7 (REVIEW_VRITK_P3P5.md): forward VRITK's OWN handClaims (the
  -- "P3 follow-up" the comment above already flagged) -- specifically the
  -- free hand's stick while reeling a fish (VR_INTERACTIONS_BACKPACK_LAB
  -- .exports.inputClaims()). A second, separate claim call (not merged into
  -- CLAIM_MASK above): that table is reused every frame regardless of
  -- content, while this one is empty most of the time and only claims
  -- anything while actually fishing.
  local vk = mod.find("VR_INTERACTIONS_BACKPACK_LAB")
  local vkClaims = vk and vk.exports and vk.exports.inputClaims
  if type(vkClaims) == "function" then
    local ok, claims = pcall(vkClaims)
    if ok and type(claims) == "table" and next(claims) then
      pcall(S.vrHost.input.claim, "VRITK_FRLG_HOST.reel", claims)
    end
  end

  -- W4 review fix #8c: on the menuOpen rising edge, snapshot which of
  -- gripL/gripR/triggerL were already active AS OF THE PREVIOUS FRAME
  -- (S.prevActive, updated below every call) -- those keep reaching VRITK
  -- (PxContext.applyMenuGate) until they physically release; anything else
  -- is a fresh squeeze meant for the game's own menu and reads as 0. Using
  -- THIS frame's own ctx.controls for the snapshot would be wrong: a
  -- squeeze that starts on the very same frame the menu opens is exactly
  -- the "fresh, meant for the menu" case, indistinguishable from an
  -- already-held one if read at that instant instead of one frame earlier.
  local menuOpen = ctx.menuOpen == true
  if menuOpen and not S.lastMenuOpen then
    local held, prev = {}, S.prevActive
    if prev then
      for key in pairs(Mods.PxContext.MENU_GATE_OFF) do
        if prev[key] then held[key] = true end
      end
    end
    S.menuHeld = held
  elseif not menuOpen then
    S.menuHeld = nil
  end
  S.lastMenuOpen = menuOpen
  if Trim.on then
    -- Two tables alternate: this frame's reads (above) are over, so the
    -- table that held the frame BEFORE last is free to be refilled. Every key
    -- of MENU_GATE_OFF is rewritten (or cleared) exactly as the fresh-table
    -- code below leaves it; the only reader is the next call's `prev[key]`.
    local prevActive = S.prevSpare or {}
    local c = ctx.controls
    for key, offThresh in pairs(Mods.PxContext.MENU_GATE_OFF) do
      if c then
        prevActive[key] = (tonumber(c[key]) or 0) > offThresh
      else
        prevActive[key] = nil
      end
    end
    S.prevSpare = S.prevActive
    S.prevActive = prevActive
  else
    local prevActive, c = {}, ctx.controls
    if c then
      for key, offThresh in pairs(Mods.PxContext.MENU_GATE_OFF) do
        prevActive[key] = (tonumber(c[key]) or 0) > offThresh
      end
    end
    S.prevActive = prevActive
  end

  if not ctx.worldFromLocal then return nil end -- HostApi rig not ready yet
  -- Gen3 dex scanner: the tablet camera may render only inside this update
  -- (after FRLG_VOXEL prepared the frame, before the eyes draw).
  local renderCamera, closeCamera = S.tabletCamera:window(ctx, S.vrHost)
  local ok, pxFrame = pcall(Mods.PxContext.buildFrame, ctx, Mods.VRHandPose, S.menuHeld, renderCamera)
  if not ok then closeCamera(); S.lastError = tostring(pxFrame); return nil end
  if not pxFrame.worldFromLocal then closeCamera(); return nil end

  Mods.Gen3TabletCompat.prepareFrame(pxFrame, ctx.controls)
  local okUpdate, records = pcall(Mods.QuestStereoLayers.update, pxFrame)
  closeCamera()
  if not okUpdate then S.lastError = tostring(records); records = {} end

  -- CRITIQUE #6 "host duties": HandProps.place runs once per frame, after
  -- the layer update, so a registered hand prop (P3's ball) has a pose
  -- before the first eye draws. rig gives pivot/anchor/scale/yaw in the
  -- SAME px frame PxContext just built worldFromLocal from.
  local rig = ctx.rig
  if rig then
    local pivotPx, anchorLocal
    if Trim.on then
      -- read-only inputs of VRRig.propMatrix (numbers are copied into
      -- matrices; nothing retains these tables)
      pivotPx, anchorLocal = S.pivotScratch, S.anchorScratch
      if not pivotPx then
        pivotPx, anchorLocal = {}, {}
        S.pivotScratch, S.anchorScratch = pivotPx, anchorLocal
      end
      pivotPx[1], pivotPx[2], pivotPx[3] = 16 * rig.anchor.x, 16 * rig.anchor.y, 16 * rig.anchor.z
      anchorLocal[1], anchorLocal[2], anchorLocal[3] = rig.pivot.x, rig.pivot.y, rig.pivot.z
    else
      pivotPx = { 16 * rig.anchor.x, 16 * rig.anchor.y, 16 * rig.anchor.z }
      anchorLocal = { rig.pivot.x, rig.pivot.y, rig.pivot.z }
    end
    local scalePxPerM = 16 / rig.m
    local handr = pxFrame.controls and pxFrame.controls.handr or nil
    pcall(Mods.QuestHandProps.place, handr, pivotPx, anchorLocal, scalePxPerM, rig.yaw or 0)
  end

  pcall(V.require('compat/Gen3NativeText').prepare)
  local okSpin,spin=pcall(Mods.Gen3JuggleSpin.prepare,pxFrame)
  return { pxFrame = pxFrame, records = records, spin=okSpin and spin or nil }
end

-- ALLOC TRIM: one payload table, refilled before each hands draw and cleared
-- after it. QuestHandsRenderer.draw reads payload.hands / payload.worldFromLocal
-- during the call and keeps neither (it stores only numbers in its own
-- per-side scratch); the FramePacer heap seam wraps draw() and forwards the
-- argument without storing it.
local HANDS_PAYLOAD = { hands = nil, worldFromLocal = nil }

local function layerDraw(record, eye)
  if not record then return end
  local trim = Trim.on
  local vpPx, eyePosPx
  if trim then
    -- per-eye scratch (keyed by eye.index), valid until the same eye is
    -- drawn next frame; beginEye stores them in Voxel3D.vp / Voxel3D.eye and
    -- every reader of those uses them inside this eye's draw.
    vpPx = Mods.PxContext.eyeVpPxScratch(eye)
    eyePosPx = Mods.PxContext.eyePosPxScratch(eye)
  else
    vpPx = Mods.PxContext.eyeVpPx(eye)
    eyePosPx = Mods.PxContext.eyePosPx(eye)
  end
  if not vpPx then return end
  local voxel = V.require("Voxel3D")
  if not voxel.beginEye(vpPx, eyePosPx, eye.nativeFlash, eye.worldLighting) then return end
  pcall(Mods.QuestHandProps.draw)
  pcall(Mods.QuestStereoLayers.draw, record.records)
  pcall(Mods.Gen3JuggleSpin.draw,record.spin)
  -- Hands are local interaction geometry, intentionally exempt from world darkness.
  voxel.flashExempt(true)
  if trim then
    HANDS_PAYLOAD.hands = record.pxFrame.hands
    HANDS_PAYLOAD.worldFromLocal = record.pxFrame.worldFromLocal
    pcall(Mods.QuestHandsRenderer.draw, HANDS_PAYLOAD)
    HANDS_PAYLOAD.hands, HANDS_PAYLOAD.worldFromLocal = nil, nil
  else
    pcall(Mods.QuestHandsRenderer.draw, { hands = record.pxFrame.hands, worldFromLocal = record.pxFrame.worldFromLocal })
  end
  voxel.endEye()
end

-- ------------------------------------------------------------ second-screen setEnabled suppression
-- gear-hook DESIGN.md 2d: kanto_gear calls the engine's second-screen
-- setEnabled on EVERY composed frame with the same value (main.lua:13826)
-- -- on Gen2, BATTLE_ART_QUEST_COMPAT already wraps context.secondScreen in
-- a memoising view (lib/QuestSecondScreen.lua) so only a CHANGED value
-- actually crosses into native code; that wrapper is Gen2-only (its own
-- manifest lists gen2 only), so FireRed had no such suppression -- the
-- Gen2 capture measured 3380 of the native "no secondary display found"
-- log lines in five minutes; the FireRed cost is the same shape (same
-- kanto_gear code path), just not separately measured yet [I].
--
-- Same idempotent-install shape as BATTLE_ART_QUEST_COMPAT's own
-- installSecondScreenBridge: mod.find allocates a fresh table every call
-- (Loader.lua), so latch a "not present" answer instead of re-checking
-- every frame once kanto_gear is confirmed absent. No generation check
-- needed here (unlike BATTLE_ART_QUEST_COMPAT, which also loads on Gen1):
-- this whole mod is FireRed/LeafGreen-only already (the gate at the top of
-- this file).
local function installSecondScreenBridge()
  if S.removeSecondScreenBridge or S.secondScreenUnwanted then return false end
  if not mod.find("kanto_gear") then
    S.secondScreenUnwanted = true
    return false
  end
  local ok, module = pcall(require, "src.render.SecondScreen")
  if not (ok and type(module) == "table" and type(module.setEnabled) == "function") then
    return false
  end
  S.secondScreen, S.secondScreenModule = Mods.QuestSecondScreen.new(module), module
  -- Priority strictly between FRLG_VOXEL's render.compose hook (40, section
  -- 2c) and VRITK's own frame hook (-999) / kanto_gear's (-1000), so this
  -- link sees (and rewrites) context.secondScreen before either of them
  -- reads it, but only once FRLG_VOXEL's own hook has already run.
  S.removeSecondScreenBridge = mod.hooks:wrap("render.compose", function(nextFn, renderer, context)
    if type(context) == "table" and context.secondScreen == S.secondScreenModule then
      context.secondScreen = S.secondScreen.view
    end
    return nextFn(renderer, context)
  end, 0)
  log("second-screen setEnabled suppression installed (kanto_gear present)")
  return true
end

-- ------------------------------------------------------------ bind to FRLG_VOXEL
local function bind()
  local host = mod.find("FRLG_VOXEL")
  local vh = host and host.exports and host.exports.vrHost
  if not (vh and vh.api == 1) then
    log("FRLG_VOXEL.exports.vrHost API 1 not found; bridge stays inactive")
    return
  end
  S.vrHost = vh
  local ok, err = vh.layers.register("VRITK_FRLG_HOST.bridge",
    { update = layerUpdate, draw = layerDraw, invalidate = layerInvalidate, nativeFlashCovered=true,
      flashCoverage=function() local ok,why=Mods.QuestHandProps.flashCoverage();if not ok then return false,why end;return Mods.QuestStereoLayers.flashCoverage()end })
  if ok then
    S.registeredWithHost = true
    log("bound to FRLG_VOXEL vrHost api " .. tostring(vh.api) .. " version " .. tostring(vh.version))
  else
    log("vrHost.layers.register failed: " .. tostring(err))
  end
end
local installWildsHostCompat
mod.events:on("mods.loaded", function()
  if installWildsHostCompat then installWildsHostCompat() end
  local ok, err = pcall(bind)
  if not ok then log("bind() threw: " .. tostring(err)) end
  -- Track C: the overworld provider router's first detection rides this one
  -- handler (one mods.loaded registration per mod, as before)
  local r = mod.exports.overworldProvider
  if r and r.onModsLoaded then
    local okR, errR = pcall(r.onModsLoaded)
    if not okR then log("overworld provider router: " .. tostring(errR)) end
  end
  if approach then
    local okP, errP = pcall(approach.onModsLoaded)
    if not okP then log("approach loader: " .. tostring(errP)) end
  end
end)

-- installSecondScreenBridge must run whether or not the camera is in
-- first-person mode (layerUpdate returns early otherwise, review fix #4),
-- and whether or not the vrHost bind() above has succeeded yet -- kanto_gear
-- may load in either order relative to this mod. input.step already runs
-- every engine tick unconditionally (the same property CRITIQUE #7 relies
-- on for the fishing watchdog); the install itself is idempotent (latches
-- on success or on a confirmed-absent kanto_gear), so calling it here every
-- tick until then is cheap.
mod.hooks:wrap("input.step", function(nextFn, game, dt)
  pcall(installSecondScreenBridge)
  Mods.Gen3JuggleSpin.tick()
  if approach then pcall(approach.onTick, game) end -- Lab 58: one budgeted warm job per frame, scan every 15 ticks
  return nextFn(game, dt)
end)

mod.hooks:wrap("core.quit_to_launcher", function(nextFn)
  S.voxelActive = false
  -- Engine-owned provider registration must retire with this engine instance.
  local router=mod.exports.overworldProvider
  local adapter=router and router.active
  if adapter and type(adapter.deactivate)=='function' then pcall(adapter.deactivate,adapter) end

  -- Lab 8: take the Gen3 overrides back out of VRITK's module tables before
  -- another game can reach them in this process.
  if Mods.UntamedGateCompat then pcall(Mods.UntamedGateCompat.uninstall) end
  if Mods.WildsFollowerFixCompat then pcall(Mods.WildsFollowerFixCompat.uninstall) end
  if Mods.WildsLayersCompat then pcall(Mods.WildsLayersCompat.uninstall) end
  if Mods.WildsHostCompat then pcall(Mods.WildsHostCompat.uninstall) end
  pcall(Mods.Gen3ChooseYouCompat.uninstall)
  pcall(V.require('compat/Gen3VrComfort').uninstall)
  pcall(Mods.Gen3JuggleSpin.uninstall)
  pcall(V.require('compat/Gen3NativeText').uninstall)
  pcall(Mods.Gen3BeltCompat.uninstall)
  pcall(Mods.Gen3DexScannerCompat.uninstall)
  if approach then pcall(approach.dispose) end
  if S.vrHost and S.registeredWithHost then
    pcall(S.vrHost.layers.unregister, "VRITK_FRLG_HOST.bridge")
  end
  S.registeredWithHost = false
  if S.removeSecondScreenBridge then pcall(S.removeSecondScreenBridge) end
  S.removeSecondScreenBridge, S.secondScreen, S.secondScreenModule = nil, nil, nil
  S.secondScreenUnwanted = false
  return nextFn()
end)

-- ------------------------------------------------------------ exports
-- Set unconditionally at load time (not deferred into mods.loaded), so
-- VRITK's OWN mods.loaded handler sees a fully-populated table whichever
-- order the two mods' listeners run in (CRITIQUE #11: exports existing is
-- not the same claim as "actually being pumped" -- see status() below for
-- that distinction).
mod.exports.questVrInput = {
  version = 1,
  snapshot = function()
    return S.vrHost and S.vrHost.input.snapshot() or nil
  end,
  pulse = function(side, amplitude, seconds)
    if not S.vrHost then return false end
    local ok, accepted = pcall(S.vrHost.input.pulse, side, amplitude, seconds)
    return ok and accepted == true
  end,
  handProps = {
    version = 1,
    register = Mods.QuestHandProps.register,
    unregister = Mods.QuestHandProps.unregister,
    debugState = Mods.QuestHandProps.debugState,
  },
  stereoLayers = {
    version = 1,
    register = Mods.QuestStereoLayers.register,
    unregister = Mods.QuestStereoLayers.unregister,
    debugState = Mods.QuestStereoLayers.debugState,
  },
}
mod.exports.voxelRenderingActive = function() return S.voxelActive == true end
mod.exports.lib = { require = V.require }
-- Lab 51 ALLOC TRIM toggle (game-neutral names, shared toggle protocol):
-- setAllocTrim(on) takes a boolean, allocTrim() returns the current one.
-- Covers this mod's hands renderer, hand assets, eye scratch and layer
-- glue, and (via VRHandAssets.trimFlag) SkinnedGloveHands.
mod.exports.setAllocTrim = function(on) Trim.set(on == true) end
mod.exports.allocTrim = function() return Trim.on == true end
-- CRITIQUE #17: battles are panel-only on FireRed in v1 (no VR wrist
-- patch -- DESIGN.md risk 8). Returning false (not nil/true) makes VRITK's
-- own wristWanted check in main.lua's wearable layer.update skip
-- Gen2BattleWrist:update entirely, instead of running an unguarded wrist
-- update against a facade with no battle state. (Lab 8: the ChooseYou
-- battle seam now exists -- compat.install below, lib/compat/
-- Gen3ChooseYouCompat.lua -- and its prompt is VR text, not the wrist.)
mod.exports.battleScreen = function() return false end
-- W4 P3 (DESIGN.md 2b line 205): px-space wrapper around FRLG_VOXEL's
-- vrHost.world.* queries, for FRLG_CATCH's ball physics (which draws
-- through the bridge's Voxel3D stand-in / QuestHandProps, both in world
-- px). `function() return S.vrHost end` is a live getter, not a snapshot:
-- worldPx keeps working across a session restart that rebinds S.vrHost.
mod.exports.worldPx = Mods.WorldPx.new(function() return S.vrHost end)
-- game3 data adapters (DESIGN.md 2c). P2 scope: bag.rows, party.list. P3
-- scope: bag.balls (read-only pouch display; capture is a stub, so nothing
-- here ever calls Bag.remove -- a thrown ball never spends one).
mod.exports.game3 = {
  bag = { rows = Mods.Game3Data.bagRows, balls = Mods.Game3Data.ballRows, countBall = Mods.Game3Data.ballCount, bestRod = Mods.Game3Data.bestRod },
  party = { list = Mods.Game3Data.partyList,
    -- gear-hook follow-up: "open nickname for party slot N" -- opens the
    -- SAME real naming screen FireRed's own battle catch flow uses,
    -- routed to Gear's tablet keyboard (kanto_gear_333_naming_lab.diff).
    -- openNicknameForPartySlot(slot, onDone) -> ok, why|nil.
    openNickname = Mods.Game3Data.openNicknameForPartySlot },
  -- gear-hook follow-up round 2: the same hook for a catch sent to the PC
  -- (the party was full). openNickname(boxRef, onDone) -> ok, why|nil,
  -- where boxRef={box=boxId, slot=slotIdx} -- the exact pair
  -- src.core.game3.storage.sendMonToPC hands back.
  box = { openNickname = Mods.Game3Data.openNicknameForBoxMon },
  ready = Mods.Game3Data.ready,
}
-- Gen3 compat layer (standing rule, 2026-09-28): the single door VRITK's
-- shared files and kanto_gear knock on for FireRed-only behaviour. See
-- lib/compat/*.lua for what each one does; VR_INTERACTIONS_BACKPACK_LAB's
-- lib/Gen3HostCompat.lua is the mod.find("VRITK_FRLG_HOST") lookup that
-- reads this table, and kanto_gear/main.lua's namingGrid() reads
-- .namingGrid directly the same way.
mod.exports.compat = {
  tablet = Mods.Gen3TabletCompat,
  pouch = Mods.Gen3PouchCompat,
  gear = Mods.Gen3GearCompat,
  leadSwap = Mods.Gen3LeadSwapCompat,
  namingGrid = Mods.Gen3NamingCompat.grid,
  -- bag-icon rows for BackpackContents.snapshot (VR_INTERACTIONS_BACKPACK_LAB);
  -- bagRows is this mod's own Game3Data function, passed in rather than
  -- looked up again since Gen3ContentsCompat no longer needs a mod.find
  -- round trip back to itself.
  contents = { snapshot = function() return Mods.Gen3ContentsCompat.snapshot(Mods.Game3Data.bagRows) end },
  -- FireRed's own fishing (FishingPlay.lua's Crystal-shaped world/isWater/
  -- facingFor/floatCell/prepare/heartbeat/tick interface).
  fishing = Mods.Gen3FishingCompat,
  -- Lab 8 seam (VR_INTERACTIONS_BACKPACK_LAB/main.lua mods.loaded, one gated
  -- line): install(vkV, enabled, onBegin) puts the FireRed overrides for the
  -- opening/overworld send-out (Gen3ChooseYouCompat) and the belt fixes
  -- (Gen3BeltCompat) into VRITK's own module tables. enabled/onBegin are the
  -- same two closures VRITK hands Gen2BattleCompat.install on Crystal.
  install = function(vkV, enabled, onBegin, visualEnabled)
    local okC, whyC = Mods.Gen3ChooseYouCompat.install(vkV, enabled, onBegin, { log = log })
    -- enabled also gates the belt's A claim (holding()), so a belt VRITK
    -- disables or stops running cannot keep A from the game (review defect 2)
    local okB, whyB = Mods.Gen3BeltCompat.install(vkV, { log = log, enabled = enabled })
    V.require('compat/Gen3VrComfort').install(vkV,{enabled=enabled,visualEnabled=visualEnabled})
    Mods.Gen3JuggleSpin.install(vkV,enabled)
    local okD, whyD = Mods.Gen3DexScannerCompat.installCamera(vkV)
    -- Lab 57 (SCANNER57 review): watchEdge= shows a silent fallback to the old ray in the log
    local okSt, st = pcall(Mods.Gen3DexScannerCompat.status)
    log(("Gen3 dex scanner compat installed: %s %s watchEdge=%s"):format(tostring(okD), tostring(whyD or ""),
      tostring(okSt and type(st) == "table" and st.watchEdge == true)))
    log(("Gen3 ChooseYou/belt compat installed: chooseYou=%s belt=%s"):format(tostring(okC), tostring(okB)))
    return okC == true and okB == true, whyC or whyB
  end,
  chooseYou = Mods.Gen3ChooseYouCompat,
  partyBeltDisplayAllowed = function(game) return V.require('compat/Gen3PartyBeltDisplay').allowed(game) end,
  belt = Mods.Gen3BeltCompat,
  juggleSpin = Mods.Gen3JuggleSpin,
  dexScanner = Mods.Gen3DexScannerCompat,
}
-- COMPAT60 (user rule 2026-10-10: "all these changes need to go in a compat layer that turns on with VRITK installed"):
-- Wilds of Hoenn 1.5.0 and Untamed ship byte-identical to their releases and the engine seams that Wilds probes for live
-- in the VRITK_GEN3_PRELUDE mod (Wilds loads before this mod, so its entry-chunk probe needs them earlier). What the VR
-- layer needs from Wilds / Untamed is added here, at runtime, to the live objects they export: the native-provider gates
-- the router flips, the follower override, the VR battle entry, the 8-mon cap, the spawn decorator, renderer snapshots and
-- the incremental reachability. Nothing here writes an option or a save value; each layer restores what it replaced.
do
  local function logf(fmt, ...)
    local okF, text = pcall(string.format, fmt, ...)
    log(okF and text or tostring(fmt))
  end
  local function optional(name)
    local okM, m = pcall(V.require, name)
    return okM and m or nil
  end
  installWildsHostCompat = function()
   local okH, errH = pcall(function()
    local Host = V.require("compat/WildsHostCompat")
    local ok, why = Host.install({ find = mod.find, events = mod.events, log = logf, require = require,
      voxelActive = function() return S.voxelActive == true end,
      parts = { snapshot = optional("compat/WildsSnapshotCompat"), reach = optional("compat/WildsReachCompat"),
        slots = optional("compat/WildsWaterSlotsCompat") } })
    logf("Wilds host compat: %s %s", tostring(ok), tostring(why or ""))
    Mods.WildsHostCompat = Host
  end)
   if not okH then log("Wilds host compat unavailable: " .. tostring(errH)) end
  end
  installWildsHostCompat()
  local okU, errU = pcall(function()
    local Gate = V.require("compat/UntamedGateCompat")
    local ok, why = Gate.install(mod.find, logf)
    logf("Untamed gate compat: %s %s", tostring(ok), tostring(why or ""))
    Mods.UntamedGateCompat = Gate
  end)
  if not okU then log("Untamed gate compat unavailable: " .. tostring(errU)) end
end
-- Wilds171 auxiliary layers stay inside VRITK; no voxel renderer changes.
do
  local Layers = V.require("compat/WildsLayersCompat")
  Layers.install({ adapter = V.require("compat/WildsFireRedAdapter"), visuals = V.require("compat/WildsVisuals") })
  Mods.WildsLayersCompat = Layers
end
-- Track C (Lab 54): overworld Pokemon provider routing (WILDS_FIRERED_DESIGN.md 4).
-- FireRed / LeafGreen (layout "frlg"): one shared, event-driven router
-- (compat/OverworldProviderRouter) with the FireRed Wilds adapter and the
-- Untamed adapter; AUTO prefers Wilds; the VR option ow_provider (OPTION >
-- OVERWORLD MONS, or the Mods page) picks AUTO / WILDS / UNTAMED / OFF.
-- Emerald (layout "rse") keeps its Lab 47 compat/WildsOfHoennCompat unchanged;
-- moving Emerald onto the router is its own, separately tested change.
-- exports.owMons is the stable owMons v1 facade FRLG_CATCH caches.
local owRouter, owRows
local approachLayout
do
  local layout
  local okGV, GV = pcall(require, "src.core.GameVersion")
  if okGV and type(GV) == "table" and GV.get and GV.layout then
    local okG, id = pcall(GV.get)
    if okG then
      local okL, l = pcall(GV.layout, id)
      if okL then layout = l end
    end
  end
  approachLayout = layout
  if layout == "rse" then
    local okE, errE = pcall(function() return V.require("compat/WildsOfHoennCompat").install(mod, V) end)
    if not okE then log("Emerald Wilds compat unavailable: " .. tostring(errE)) end
  else
   local okRouter, routerErr = pcall(function()
    local Router = V.require("compat/OverworldProviderRouter")
    -- (mod.options is absent in some headless harnesses: the router then reads AUTO)
    if mod.options and mod.options.define then mod.options:define({
      { key = Router.OPTION_KEY, type = "choice", label = "OVERWORLD MONS", default = "auto",
        choices = Router.CHOICES,
        help = "Which mod shows the overworld Pokemon. AUTO uses Wilds of Hoenn when it is installed and compatible, else Untamed. WILDS / UNTAMED pick one (AUTO is used for the session when it is unavailable). OFF shows none. Installed mods are never disabled or removed." },
      -- one-time migration marker (decision 2026-10-10 #1); never shown
      { key = Router.MARKER_KEY, type = "toggle", label = "OW MIGRATED", default = false,
        visible_if = { key = Router.MARKER_KEY, equals = "never-shown" } },
      -- Lab 60 (item 4): look only; the wild Pokemon of a new area appear one after another and grow in
      { key = "wilds_grow_in", type = "toggle", label = "WILD GROW-IN", default = true,
        help = "Wild Pokemon appear one at a time and grow to full size instead of popping in all at once. Looks only: the Pokemon, their positions and the encounter rolls are unchanged." },
    }) end
    local function getOption(key) if mod.options and mod.options.get then return mod.options:get(key) end; return nil end
    local function writeOption(game, key, value)
      local okM, Manager = pcall(require, "src.mods.ManagerState")
      if not (okM and type(Manager) == "table" and Manager.new and game and game.mods) then return false end
      local made, result = pcall(function() return Manager.new(game):setOption(mod.id, key, value) end)
      return made and result ~= false
    end
    local function host()
      local f = mod.find("FRLG_VOXEL")
      return f and f.exports and f.exports.vrHost or nil
    end
    local function session()
      local okR, R = pcall(require, "src.core.game3.runtime")
      return okR and R and R.getSession and R.getSession() or nil
    end
    local okW, wilds = pcall(function()
      return V.require("compat/WildsFireRedAdapter").new({
        find = mod.find,
        ambient = V.require("compat/WildsAmbientCompat"),
        layout = function() return layout end,
        G3 = Mods.Game3Capture or V.require("Game3Capture"),
        capture = V.require("compat/WildsCapture"),
        followerFix = (function() local okF, F = pcall(V.require, "compat/WildsFollowerFixCompat"); return okF and F or nil end)(), -- fix57
        emit = function(snap) mod.events:emit("mod.FRLG_OW_MONS.battle_handoff", snap) end,
        host = host, session = session,
        Catching = function()
          local okC, C = pcall(require, "src.core.game3.battle.catching")
          return okC and C or nil
        end,
        log = log,
      })
    end)
    -- COMPAT60: Wilds' party-menu wrappers (the ROLE rows) stay installed whether or not its native gate is on, and on
    -- FireRed a ROLE row makes the action list draw fail, so the follower-fix layer is installed whenever Wilds is
    -- present; its follower-interaction parts only act while the Wilds gate is on.
    do
      local okFx, errFx = pcall(function()
        local Fix = V.require("compat/WildsFollowerFixCompat")
        Mods.WildsFollowerFixCompat = Fix
        local wf = mod.find("wilds_of_hoenn")
        local wex = wf and wf.exports
        if not wex then return end
        local ok, why = Fix.install(wex, { require = require, log = log, active = function()
          return type(wex.nativeProviderEnabled) ~= "function" or wex.nativeProviderEnabled() == true
        end })
        if not ok then log("wilds follower fix off: " .. tostring(why)) end
      end)
      if not okFx then log("wilds follower fix unavailable: " .. tostring(errFx)) end
    end
    local adapters = {}
    if okW and wilds then adapters[#adapters + 1] = wilds else log("Wilds adapter unavailable: " .. tostring(wilds)) end
    adapters[#adapters + 1] = V.require("compat/UntamedAdapter").new(mod.find)
    owRouter = Router.install({ find = mod.find, log = log, getOption = getOption, writeOption = writeOption,
      events = mod.events, modId = mod.id, modsLoadedByHost = true }, adapters)
    mod.exports.overworldProvider = owRouter
    mod.exports.owMons = owRouter.api
    local okRows, Rows = pcall(require, "src.ui.game3.option_rows")
    if okRows and type(Rows) == "table" then
      local okI, res, why = pcall(V.require("compat/OverworldProviderRows").install, {
        Rows = Rows, router = owRouter, optionKey = Router.OPTION_KEY, choices = Router.CHOICES,
        get = getOption, write = writeOption })
      if okI and res then owRows = Rows else log("OVERWORLD MONS rows unavailable: " .. tostring(okI and why or res)) end
    end
   end)
   -- never let provider routing take the bridge down: without it FRLG_CATCH falls back to FRLG_OW_MONS
   if not okRouter then log("overworld provider router unavailable: " .. tostring(routerErr)); owRouter = nil end
  end
end

mod.exports.status = function()
  return {
    active = true,
    overworldProvider = owRouter and owRouter:status() or nil,
    vrHostBound = S.vrHost ~= nil,
    registeredWithHost = S.registeredWithHost,
    -- CRITIQUE #11: a driver checking "is this actually live" should read
    -- layerUpdates increasing over time, not just registeredWithHost==true
    -- (which is also true the instant register() returns, before FRLG_VOXEL
    -- has ever pumped a single frame).
    layerUpdates = S.layerUpdates,
    error = S.lastError,
    layers = Mods.QuestStereoLayers.debugState(),
    handProps = Mods.QuestHandProps.debugState(),
    tabletCamera = S.tabletCamera:stats(),
    dexScanner = Mods.Gen3DexScannerCompat.status(),
  }
end
mod.exports.active = true

-- Lab 58 approach loading: warm a connected map's cold loads (NPC sheets, Wilds species crops) before the player
-- arrives, and keep the Wilds atlas from re-decoding its shards. FireRed layout only; with this mod absent none of it
-- exists, and ApproachLoader.ENABLED / WildsAtlasCompat.ENABLED switch the two halves off.
do
  local okAp, resAp, whyAp = pcall(function()
    return V.require("compat/ApproachLoader").installForHost({
      mod = mod, V = V, log = log,
      layout = function() return approachLayout end,
      active = function() return mod.exports.active == true end })
  end)
  if okAp and resAp then
    approach = resAp
    mod.exports.approach = { status = approach.status }
  elseif not okAp then
    log("approach loader unavailable: " .. tostring(resAp))
  end
end

-- Lab 60 (item 4): wild Pokemon grow in (stagger + scale-in of the VR cards). Look only, FireRed layout only, option
-- "wilds_grow_in" (default on). It hooks the Wilds adapter module of this mod (adapter.GrowIn); with this mod absent the
-- cards are what they were.
do
  local okGi, errGi = pcall(function()
    local Grow = V.require("compat/WildsGrowInCompat")
    local G, why = Grow.installForHost({
      V = V, log = log,
      layout = function() return approachLayout end,
      active = function() return mod.exports.active == true end,
      getOption = function()
        if mod.options and mod.options.get then return mod.options:get("wilds_grow_in") end
        return nil
      end })
    if not G then log("wilds grow-in not installed: " .. tostring(why)) end
  end)
  if not okGi then log("wilds grow-in unavailable: " .. tostring(errGi)) end
end

log(("loaded %s"):format(tostring(mod.version)))
