-- FRLG_VOXEL: FireRed/LeafGreen overworld as a voxel world.
--
-- Quest: once the overworld is live, this mod takes the OpenXR session from
-- the native launcher panel (mod.device.questVR) and renders the field in
-- stereo per eye; menus, text and the start menu float as a card in front of
-- you. Battles play in the same 3D world (lib/battle, W6): the Pokemon stand
-- on the nearest open ground, you watch from a seat over your Pokemon's
-- shoulder, HP floats over each Pokemon and the text/command card sits low
-- in front of you. A battle never uses the flat panel while the voxel view
-- is on (user rule 2026-09-28). Full-screen menus outside battles and the
-- title show the flat game frame on a panel quad (PANEL mode). Left stick
-- click toggles 3D <-> panel.
-- Desktop: the same renderer draws a mono (or side-by-side stereo preview)
-- view into the window through render.compose; F7 toggles it.
--
-- Robustness contract: any error in this mod logs once and falls back to the
-- stock flat presentation (desktop: the vanilla composite; Quest: PANEL
-- mode). Nothing here may crash the game. Option "FRLG VOXEL VIEW" OFF keeps
-- the whole mod inert (stock native panel, no OpenXR takeover).
local mod = ...
local V = { mod = mod, path = mod.path }
local TAG = "[FRLG_VOXEL]"

local loaded = {}
function V.require(name)
  local cached = loaded[name]
  if cached ~= nil then return cached end
  local rel = "lib/" .. name .. ".lua"
  local source = mod:read(rel)
  if not source then error(TAG .. " missing " .. rel, 0) end
  local chunk, err = load(source, "@" .. mod.path .. "/" .. rel)
  if not chunk then error(TAG .. " " .. tostring(err), 0) end
  local value = chunk(V)
  if value == nil then value = false end
  loaded[name] = value
  return value
end

function V.has(rel)
  local ok, info = pcall(mod.info, mod, rel)
  return ok and info ~= nil
end

local warned = {}
local function logOnce(key, message)
  if warned[key] then return end
  warned[key] = true
  print(TAG .. " " .. tostring(message))
end
local function log(message) print(TAG .. " " .. tostring(message)) end

-- ------------------------------------------------------------ gate: Gen 3
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
  -- The manifest's games list already keeps this mod off Gen 1/2; this is
  -- the belt to that brace.
  log("inactive: generation " .. tostring(generation) .. " is not FireRed/LeafGreen")
  mod.exports.active = false
  return
end

-- Own the early engine seams inside this folder. On the tester host the
-- optional gen3-hd-sprites dependency orders Wilds after this entry runs.
do
  local ok, Seams = pcall(V.require, "compat/EngineSeams")
  if ok and type(Seams) == "table" then
    local installed, why = Seams.install(log)
    mod.exports.engineSeams = { version = 1, status = Seams.status, uninstall = Seams.uninstall }
    if not installed then log("engine seams unavailable: " .. tostring(why)) end
    mod.hooks:wrap("core.quit_to_launcher", function(nextFn)
      pcall(Seams.uninstall)
      return nextFn()
    end)
  else log("engine seams unavailable: " .. tostring(Seams)) end
end

-- Keep compatibility exports separate from the renderer; start below after initialization.
V.require('compat/LegacyBridge').expose(V)

-- ------------------------------------------------------------ options
local frlgOptionRows = mod.options:define({
  {key="battle_aim",type="toggle",label="BATTLE AIM CUE",default=true,help="Marks where your own Pokemon will appear while a battle opening or switch waits for your party-ball throw."},
  {key="belt_locked",type="toggle",label="BELT REFERENCE LOCK",default=true,
    help="Keep waist equipment facing recentered room forward while you look around. External equipment mounts retain their own anchors."},
  {key="throw_strength",type="choice",label="THROW STRENGTH",default="assisted",
    choices={{"NORMAL","normal"},{"ASSISTED","assisted"}},
    help="ASSISTED adds a capped25% release boost for deliberate horizontal throws. Normal restores existing strength; drops and vertical juggling are unchanged."},

  {key="contextual_horizons",type="toggle",label="KANTO HORIZONS",default=true,
   help="Contextual distant scenery for the Kanto first-pass areas. Follows time and fog; raises TWS clouds only where these horizons are active. Sevii Islands are not included."},
  {
    key = "voxel_view", type = "toggle", label = "FRLG VOXEL VIEW", default = true,
    help = "3D voxel overworld. Quest: stereo VR (left stick click switches to the flat panel and back). PC: 3D preview (F7). OFF = flat view now; the VR session itself is only skipped from the next launch.",
  },
  {
    key = "camera", type = "choice", label = "VOXEL CAMERA",
    choices = { { "FIRST PERSON", "first" }, { "THIRD PERSON", "third" }, { "3/4 VIEW", "overview" } },
    default = "first",
    help = "First person at the trainer's eye height; a raised camera behind the trainer; or 3/4 VIEW like the original screen (Quest: a seated table-top model).",
  },
  {
    key = "mouse_keyboard", type = "toggle", label = "MOUSE & KEYBOARD", default = false,
    help = "F6 toggles mouse look + camera-relative WASD in first/third person. Click the world to capture the mouse. Escape releases it; menus and focus loss release automatically. Existing A/B/START keys remain available. PC only; Quest keeps its existing VR controls.",
  },
  {
    key = "mouse_sensitivity", type = "number", label = "MOUSE SENSITIVITY", default = 100, min = 25, max = 250, step = 25,
    help = "Mouse look speed in percent. Applies immediately.",
  },
  {
    key = "turning", type = "choice", label = "VOXEL TURNING",
    choices = { { "LOOK", "look" }, { "FOLLOW FACING", "follow" } },
    default = "look",
    help = "Quest: LOOK keeps the world still (stick forward walks where you look, the right stick turns). FOLLOW turns the world to the trainer's facing (GRID movement only; free walking always uses LOOK).",
  },
  -- Lab 8 (P0-2, user answers 2026-09-29): free walking by default with the
  -- grid as an option; smooth turning by default with snap turning as an option
  {
    key = "movement", type = "choice", label = "VOXEL MOVEMENT",
    choices = { { "FREE", "free" }, { "GRID", "grid" } },
    default = "free",
    help = "FREE: the left stick walks smoothly in any direction (forward is where you look). GRID: one square at a time in four directions, like the original game.",
  },
  -- VR CONTROLS (Lab 7, user answers 2026-10-01): turning, walking pace and room-scale
  -- walking. The same five values are on the OPTION screen under VR CONTROLS
  -- (lib/quest/VrControls.lua, which lists them by these keys). turn_mode + snap_angle
  -- replace the old single turn_style choice (migrated at game.ready).
  {
    key = "turn_mode", type = "choice", label = "VOXEL TURN MODE",
    choices = { { "SNAP", "snap" }, { "SMOOTH", "smooth" } }, default = "snap",
    help = "Quest right stick: SNAP turns in one jump per flick (by VOXEL SNAP ANGLE); SMOOTH turns while you hold it (at VOXEL TURN SPEED).",
  },
  {
    key = "snap_angle", type = "number", label = "VOXEL SNAP ANGLE", default = 30, min = 15, max = 90, step = 15,
    help = "How far one SNAP turn goes, in degrees (15-90).",
  },
  {
    key = "turn_speed", type = "number", label = "VOXEL TURN SPEED", default = 90, min = 30, max = 180, step = 15,
    help = "SMOOTH turning speed at full stick, in degrees per second (30-180).",
  },
  {
    key = "walk_speed", type = "number", label = "VOXEL WALK SPEED", default = 75, min = 50, max = 100, step = 5,
    help = "FREE movement walking pace in percent of the original game's (50-100). Running (B) is unchanged. 100 is the game's own pace, about 6 m/s at this scale. A step is the same step at any pace.",
  },
  {
    key = "room_scale", type = "toggle", label = "VOXEL ROOM-SCALE WALK", default = true,
    help = "Quest, FIRST PERSON + FREE movement: physically walking around your room walks the trainer too (walls, NPCs, ledges, warps and encounters all apply), so you cannot walk through walls. OFF = only the stick moves the trainer.",
  },
  {
    key = "battle_move", type = "toggle", label = "VOXEL BATTLE MOVEMENT", default = true,
    help = "3D battles: walk (left stick, at VOXEL WALK SPEED), turn (right stick, per VOXEL TURN MODE) and walk about your room inside the battle area. Looks only: the trainer stays where he is on the map, nothing triggers, battle rules are untouched. The left stick walks while the tablet runs the battle menu; without a tablet it stays the d-pad. OFF = you stay in the battle seat.",
  },
  {
    -- belt-switch (user 2026-10-02), default ON; also on the OPTION screen under VR CONTROLS
    key = "belt_switch", type = "toggle", label = "VOXEL BELT SWITCH", default = true,
    help = "3D battles with the VR party belt: a switch you pick on the tablet (and the send-out after a faint) waits for you to recall your Pokemon into its belt ball (aim the ball, hold the trigger) and throw the next one; the red ring marks the ball. Hold B to skip; it also goes on by itself after 30 s. OFF = the game's own switch animation.",
  },
  {
    key = "quality", type = "choice", label = "VOXEL QUEST QUALITY",
    choices = { { "PERFORMANCE", "performance" }, { "BALANCED", "balanced" },
                { "SMOOTH 90HZ", "smooth90" }, { "QUALITY", "quality" } },
    default = "balanced",
    help = "OLD profile choice, replaced by the OPTION > VR DISPLAY page (VOXEL EYE RESOLUTION / REFRESH RATE / FOVEATION). A profile you picked before is carried over to those once; picking one here now sets them (the resolution part applies the next time the VR session starts).",
  },
  {
    key = "eye_res", type = "number", label = "VOXEL EYE RESOLUTION", default = 100, min = 70, max = 130, step = 10,
    help = "Quest eye image size in percent of the headset's recommended size (70-130). Up to 100 the size is fixed when the VR session starts: restart the game after changing it. Above 100 the game draws bigger and shrinks the picture to fit (sharper edges, costs frame rate); that part changes at once. The headset software refuses a real image bigger than 100.",
  },
  {
    key = "refresh_rate", type = "choice", label = "VOXEL REFRESH RATE",
    choices = { { "72 HZ", 72 }, { "80 HZ", 80 }, { "90 HZ", 90 }, { "120 HZ", 120 } }, default = 72,
    help = "Quest display refresh rate. Changes at once. The headset picks the closest rate it supports (120 only if it lists it).",
  },
  {
    key = "foveation", type = "toggle", label = "VOXEL FOVEATION", default = true,
    help = "Fixed foveated rendering (sharp in the centre, softer at the edges, saves GPU). ON uses the headset's medium level; there is no other level. Changes at once.",
  },
  {
    key = "shadows", type = "toggle", label = "VOXEL SHADOWS", default = true,
    help = "Sun shadows under trees, buildings and characters. Turning them back on rebuilds the nearby maps.",
  },
  -- Lab 8 P0-1e: lib/quest/FramePacer.lua debug experiment (rising edge only)
  {
    key = "perf_gc_pause", type = "toggle", label = "GC PAUSE TEST", default = false,
    help = "Debug. Switching this ON logs 10 s of frame timings, then 10 s with the Lua garbage collector stopped, side by side. Switch it OFF and ON to repeat.",
  },
  {
    key = "perf_gc_render", type = "toggle", label = "GC RENDER TEST", default = false,
    help = "Debug. Fresh OFF to ON arms a bounded world-only A/B/A render callback test with matched collector restarts. Tablet/menu closed; GC PACING must be 0.5 MS. Does not change the GC PAUSE TEST.",
  },
  -- Lab 8 P0-1d: bounded garbage-collector steps right after each headset frame.
  -- Lab 51: SLACK (lib/quest/GcSlack.lua) is the default of this build.
  {
    key = "perf_gc_step", type = "choice", label = "GC PACING",
    choices = { { "OFF", "0" }, { "0.5 MS", "0.5" }, { "1 MS", "1" }, { "SLACK", "slack" } },
    default = "slack",
    help = "Lua garbage collection. SLACK: during 3D play the collector works only in the idle time before each headset frame (the normal collector takes over in menus and the flat panel). 0.5 MS / 1 MS: this much collector time after each headset frame. OFF: the normal collector.",
  },
  -- Lab 51 (also on the OPTION screen under VR PERFORMANCE)
  {
    key = "perf_skip_present", type = "toggle", label = "SKIP WINDOW PRESENT", default = true,
    help = "Quest: while the 3D world is in the headset, skip clearing and presenting the hidden flat window and the frame-cap sleep (it is still presented about twice a second). OFF is the old behaviour.",
  },
  {
    key = "perf_alloc_trim", type = "toggle", label = "ALLOC TRIM", default = true,
    help = "Quest: reuse scratch tables in the VR hands, devices, backpack and catch code instead of making new ones every frame (less garbage). Same picture. OFF is the old code.",
  },
  {
    key = "perf_xr_hints", type = "toggle", label = "XR THREAD HINTS", default = true,
    help = "Quest: tell the headset which thread renders and ask for its sustained-high CPU/GPU level, when the headset supports it. Applies the next time the VR session starts.",
  },
  -- Lab 55: outdoor renderer switches (lib/render/OutdoorPerf.lua; also on the OPTION screen under VR PERFORMANCE)
  {
    key = "perf_frame_hoist", type = "toggle", label = "FRAME HOIST", default = true,
    help = "Outdoors: work that is the same for both eyes (lighting and fog values, the sky's matrices) is done once per frame, and unchanged shader values are not re-sent. Same picture. OFF is the old code.",
  },
  {
    key = "perf_eye_scratch", type = "toggle", label = "EYE SCRATCH", default = true,
    help = "Reuse the per-eye culling planes, map matrices and small shader tables instead of making new ones every eye (less garbage). Same picture. OFF is the old code.",
  },
  {
    key = "perf_grass_state", type = "toggle", label = "GRASS STATE", default = true,
    help = "Tall grass skips repeated shader switches and uniform uploads between its small draw batches. Same picture, same draw order. OFF is the old code.",
  },
  {
    key = "perf_sea_once", type = "toggle", label = "SEA ONCE", default = true,
    help = "The open-sea plane past the map edge is built once per frame instead of once per eye. Same picture. OFF is the old code.",
  },
  {
    key = "perf_weather_hoist", type = "toggle", label = "WEATHER HOIST", default = true,
    help = "Lightweight Weather & Skies: cloud and sky values are prepared without new tables and closures every eye. OFF is the old code.",
  },
  {
    key = "perf_weather_tier", type = "choice", label = "WEATHER DETAIL",
    choices = { { "FULL", "full" }, { "LITE", "lite" }, { "OFF", "off" } }, default = "lite",
    help = "Lightweight Weather & Skies in the 3D view. FULL: the full sky, cloud deck and atmosphere (the old look). LITE: a cheaper sky and cloud deck for better frame rate. OFF: only rain, snow and the day/night light. Your weather settings are not changed.",
  },
  {
    key = "perf_draw_range", type = "choice", label = "DRAW RANGE",
    choices = { { "FULL", "full" }, { "MEDIUM", "medium" }, { "NEAR", "near" } }, default = "medium",
    help = "How far the outdoor haze reaches before the world fades out (FULL 62 m, the old range; MEDIUM 50 m; NEAR 40 m). Nearer draws less and runs faster.",
  },
  {
    key = "perf_far_masks", type = "choice", label = "FAR SHADOWS",
    choices = { { "FULL", "full" }, { "DEFER", "defer" }, { "OFF", "off" } }, default = "off",
    help = "Sun shadows on the border scenery and far maps. FULL: built with each map (the old behaviour, slower map loads). DEFER: added a little later. OFF: none there; nearby maps keep their shadows. Faster map loads.",
  },
  {
    key = "perf_sun_shadows", type = "choice", label = "SUN SHADOWS",
    choices = { { "MOVING", "moving" }, { "FIXED", "fixed" }, { "OFF", "off" } }, default = "fixed",
    help = "MOVING: shadows turn with the clock (the old behaviour; maps re-shade as the sun moves). FIXED: one mid-morning shadow direction, the time of day only softens and fades it, and the sun and moon keep to that side of the sky. Faster. OFF: no sun shadows.",
  },
  {
    key = "perf_build_slice", type = "toggle", label = "BUILD SLICING", default = true,
    help = "Map building pauses more often so a frame is never held up for long, and old map geometry is released when too much is kept. Same finished picture; with MOVING sun shadows, the shadows already shown stay on while a newly loaded map is shaded. OFF is the old code.",
  },
  -- Lab 50 (frames first): OPTION > OUTDOOR SPEED
  {
    key = "perf_catch_beam_fast", type = "toggle", label = "CATCH BEAM FAST", default = true,
    help = "While a ball catches a Pokemon, the capture beam and the shrinking Pokemon are computed with fewer operations (fewer CPU cycles per beam tick). Same picture, frame for frame. OFF is the old code.",
  },
  -- Lab 57: lib/perf/FrPrecache*.lua (also on the OPTION screen: WORLD CACHE page)
  {
    key = "perf_world_cache", type = "toggle", label = "WORLD CACHE", default = true,
    help = "Maps and border scenery you have built once are saved to disk and loaded from there on later visits (also after a restart) instead of being rebuilt, so map loads are shorter. The first visit to a map is as slow as before. Same picture. OFF is the old code and nothing is read or written. Up to 384 MB of storage.",
  },
  {
    key = "perf_world_cache_clear", type = "choice", label = "CLEAR WORLD CACHE",
    choices = { { "NO", "no" }, { "CLEAR", "clear" } }, default = "no",
    help = "Choose CLEAR to delete every saved map. Maps are rebuilt (and saved again) as you visit them. The row returns to NO by itself.",
  },
  {
    key = "perf_loading_screen", type = "toggle", label = "LOADING SCREEN", default = true,
    help = "Show Preparing world while nearby terrain is being built. Quest also warms the view before revealing it. OFF shows the flat game while terrain builds.",
  },
  {
    key = "perf_speed58", type = "toggle", label = "SPEED PATCHES", default = true,
    help = "Same-picture speed-ups added in Lab 58 (sea view cache, texture mirror refresh only when the water/sand/flower animation or palette changed, engine lookups remembered, map change checks 4 times a second, and the NPC/card patches). Quest VR only. OFF is the Lab 57 code.",
  },
  -- Lab 59: lib/perf/FrPrepare.lua (also on the OPTION screen: WORLD LOADING page, shortened label)
  {
    key = "perf_precache_first_load", type = "toggle", label = "PRECACHE ON FIRST LOAD", default = true,
    help = "When saved maps are missing, build them behind a Preparing world screen using your game data. Quest B skips for now. OFF builds maps as you visit them. Needs WORLD CACHE ON.",
  },
  -- Lab 49: lib/quest/FlatRate.lua (also on the OPTION screen under VR PERFORMANCE)
  {
    key = "perf_flat_rate", type = "choice", label = "FLAT DRAW RATE",
    choices = { { "EVERY FRAME", "1" }, { "HALF", "2" }, { "THIRD", "3" } },
    default = "3",
    help = "Quest: how often the hidden flat 2D game frame is redrawn while you walk the 3D world with no menu or text open. Menus, text, battles and the flat panel always draw every frame. EVERY FRAME is the old behaviour.",
  },
  -- W2 (cam34): 3/4 VIEW angle and zoom, applied live (render/Camera.lua)
  {
    key = "view34_angle", type = "number", label = "VOXEL 3/4 ANGLE", default = 45, min = 35, max = 55, step = 5,
    help = "How steeply the 3/4 VIEW looks down, in degrees (35-55). Quest: how far below your eyes the table-top sits.",
  },
  {
    key = "view34_zoom", type = "number", label = "VOXEL 3/4 ZOOM", default = 100, min = 80, max = 130, step = 10,
    help = "3/4 VIEW zoom in percent (80-130). PC: the camera moves closer or farther. Quest: the table-top model grows or shrinks.",
  },
})
local RetroGrass = V.require("grass/RetroGrass")
frlgOptionRows[#frlgOptionRows+1]={key="fr_trees",type="choice",label="TREES",
 choices={{"CARDS","sheet"},{"VOXEL","voxel"},{"VOXEL LOW RES","voxel_low"}},default="sheet",
 help="CARDS: flat native-art trees. VOXEL: detailed 3D trees. VOXEL LOW RES: coarser 3D trees for slower systems. Changing between the two voxel modes applies immediately; changing to or from Cards rebuilds nearby maps."}
frlgOptionRows[#frlgOptionRows+1]={key="fr_grass_shape",type="choice",label="GRASS SHAPE",choices={{"UPRIGHT","upright"},{"WIDE + LAYERED","layered"}},default="upright",help="Grass shape. Applies live; grass bends when you walk through it."}
local grassRenderer
local function opt(key)
  local ok, v = pcall(mod.options.get, mod.options, key)
  if ok then return v end
  return nil
end

local initialGrassGround = "native"
local okGO, GrassOptions = pcall(V.require,"grass/GrassOptions")
if not okGO then GrassOptions=nil end

-- ------------------------------------------------------------ modules
local okMods, Mods = pcall(function()
  return {
    Mat4 = V.require("render/Mat4"),
    Shaders = V.require("render/Shaders"),
    WorldSource = V.require("data/WorldSource"),
    Scene = V.require("render/Scene"),
    Camera = V.require("render/Camera"),
    Billboards = V.require("render/Billboards"),
    Panel = V.require("render/Panel"),
    View = V.require("render/View"),
    StubMesher = V.require("render/StubMesher"),
    XRSession = V.require("quest/XRSession"),
    InputMap = V.require("quest/InputMap"),
    HostLayers = V.require("quest/HostLayers"), -- W4
    HostApi = V.require("quest/HostApi"),       -- W4
  }
end)
if not okMods then
  log("disabled: a module failed to load: " .. tostring(Mods))
  mod.exports.active = false
  return
end

-- W6 (battle P-B1): the 3D battle presenter (lib/battle). Optional: if it
-- fails to load, everything else runs as before.
local okBattle, BattleMods = pcall(function()
  return { Pass = V.require("battle/BattlePass") }
end)
if not okBattle then
  log("3D battle presenter failed to load: " .. tostring(BattleMods))
  BattleMods = nil
end

-- Lab 8 (P0-2): free walking (lib/quest/FreeMove.lua) and the 60 -> 72 Hz
-- display blend (lib/data/Actors.lua). Optional: if either fails to load,
-- the grid walk and raw positions stay exactly as in Lab 7.
local okFree, FreeMove = pcall(V.require, "quest/FreeMove")
if not okFree or type(FreeMove) ~= "table" then
  log("free walking failed to load: " .. tostring(FreeMove))
  FreeMove = nil
end
-- Lab 7: the VR CONTROLS page on the Gen 3 OPTION screen + the turn settings helpers.
-- Optional: without it the options still work from the Mods page.
local okVC, VrControls = pcall(V.require, "quest/VrControls")
if not okVC or type(VrControls) ~= "table" then
  log("VR CONTROLS page failed to load: " .. tostring(VrControls))
  VrControls = nil
end
local okActors, ActorsMod = pcall(V.require, "data/Actors")
if not okActors or type(ActorsMod) ~= "table" then ActorsMod = nil end
-- Lab 49: FLAT DRAW RATE (lib/quest/FlatRate.lua). Optional: without it the
-- flat frame is drawn on every frame exactly as before.
local okFlat, FlatRate = pcall(V.require, "quest/FlatRate")
if not okFlat or type(FlatRate) ~= "table" then
  log("flat draw rate failed to load: " .. tostring(FlatRate))
  FlatRate = nil
end

-- ------------------------------------------------------------ mesher
-- W1's FrlgMesher when present; the stub per map when it is absent or throws.
local function buildMesher()
  local w1, w1Name
  if V.has("lib/mesh/FrlgMesher.lua") then
    local ok, M = pcall(V.require, "mesh/FrlgMesher")
    if ok and type(M) == "table" and type(M.build) == "function" then
      w1, w1Name = M, "FrlgMesher"
    else
      logOnce("w1-load", "W1 mesher failed to load, using the stub: " .. tostring(M))
    end
  else
    logOnce("w1-absent", "lib/mesh/FrlgMesher.lua absent; using the W2 stub mesher")
  end
  local function optional(name)
    if not V.has("lib/" .. name .. ".lua") then return nil end
    local ok, value = pcall(V.require, name)
    if ok then return value end
    return nil
  end
  local deps = {
    Flora = grassRenderer and grassRenderer:wrap(optional("mesh/FrlgFlora")),
    MB = optional("mesh/MB"),
    Constants = optional("mesh/Constants"),
    BuildingProfiles = optional("mesh/FrlgBuildingProfiles"),
    NativeFoliage = optional("mesh/FrlgNativeFoliage"),
    NativeGrayGate = optional("mesh/NativeGrayGate"),
    ConnectedHouseNative = optional("mesh/FrlgConnectedHouseNative"),
    TowerNative = optional("mesh/FrlgTowerNative"),
    require = V.require,
    log = log,
    -- W3's requested mesher yield hook: Scene._yieldPoint exists in the
    -- current lib/render/Scene.lua (verified before adding this, per the
    -- coordinator's explicit instruction not to invent it if missing).
    yield = Mods.Scene._yieldPoint,
    yieldSafe = Mods.Scene._yieldPointSafe, -- Lab 59: finer output-neutral mesher checkpoints
  }
  local acceptedCaves=optional("cave/CompiledCaves")
  local caveDeps={index=optional("cave/CaveIndex"),CompiledCave=optional("cave/CompiledCave"),
    yieldSafe=deps.yieldSafe,
    read=function(name)return mod:read("lib/cave/data/"..name)end,
    sha256=function(s)return love.data.encode("string","hex",love.data.hash("sha256",s))end,
    inflate=function(s)return love.data.decompress("string","gzip",s)end,
    unpack=love.data.unpack, QueryCodec=optional('cave/QueryCodec'),
    makeAtlas=function(w,h,donors)
      local data=love.image.newImageData(w,h,"rgba8")
      local tile,image
      local ok,why=pcall(function()
        for _,d in ipairs(donors)do
          tile=love.image.newImageData(16,16,"rgba8",d.rgba)
          data:paste(tile,d.x,d.y,0,0,16,16);tile:release();tile=nil
        end
        image=love.graphics.newImage(data,{mipmaps=false})
        image:setFilter("nearest","nearest")
      end)
      if tile then tile:release()end
      data:release()
      if not ok then if image then image:release()end;error(why,0)end
      return image
    end}
  return function(input)
    if acceptedCaves and caveDeps.index and caveDeps.CompiledCave then
      local ok,geom,id=pcall(acceptedCaves.build,input,caveDeps)
      if ok and geom then return geom,"accepted-cave:"..tostring(id)end
      if not ok then logOnce("accepted-cave:"..tostring(input.mapId),"Accepted cave unavailable; using native fallback: "..tostring(geom))end
    end
    if w1 then
      local ok, geom = pcall(w1.build, input, deps)
      if ok and type(geom) == "table" and type(geom.opaque) == "table" then
        return geom, w1Name
      end
      logOnce("w1-fail:" .. tostring(input.mapId), "W1 mesher failed on "
        .. tostring(input.mapId) .. " (stub used): " .. tostring(ok and "bad geom" or geom))
    end
    local ok, geom = pcall(Mods.StubMesher.build, input, deps)
    if ok and type(geom) == "table" then return geom, "w2-stub" end
    return nil, nil, tostring(geom)
  end
end

-- ------------------------------------------------------------ state
local S = {
  game = nil,
  android = Mods.XRSession.isAndroid(),
  bootEnabled = opt("voxel_view") ~= false,
  voxelOn = opt("voxel_view") ~= false,
  failed = nil,
  frame = 0,
  composeFrame = -1,
  worldActive = false,
  preview = "mono",
  xrTries = 0,
  xrGaveUp = false,
  xrNextTry = 0,
  handedOver = false,   -- XR.start attempted: the launcher may have released OpenXR
  renderFails = 0,
  renderErrors = 0,     -- thrown render errors; never reset by a good frame
  lastPrepareReason = nil,
  lastRootId = nil,      -- W4: for root_shift detection, see noteRootShift()
  flatWorld = false,     -- Lab 49: the last Quest frame showed the 3D field (world, want3d, no battle)
  wearAway = false,      -- Lab 50: the last Quest frame confirmed no Gear watch/tablet on screen (+ hold)
  wear = {},             -- Lab 50: FlatRate.wearStep state (lastVisible, why, visibleFrames)
  wearInfo = {},         -- Lab 50: the reused wearStep input table
}
-- Desktop-only options must not appear on Quest, even with old saved values.
if S.android then
  for i = #frlgOptionRows, 1, -1 do
    local key = frlgOptionRows[i].key
    if key == "mouse_keyboard" or key == "mouse_sensitivity" then table.remove(frlgOptionRows, i) end
  end
end
local mouseControls, mouseStep
local R = nil -- lazily built renderer objects
local saveView -- FRLG-owned save thumbnail capture
local flat = nil -- Lab 49: the FlatRate instance, built below once its gate functions exist

-- W4: built once, early -- not lazily like R -- so mod.exports.vrHost is a
-- stable table from mods.loaded onward. Consumers (VRHOST_PROBE, later
-- VRITK_FRLG_HOST) bind mod.find("FRLG_VOXEL").exports.vrHost on
-- mods.loaded, which can fire before ensureRenderer() ever ran. camera/
-- scene/xr start nil here and are filled in by ensureRenderer() below;
-- every HostApi method re-reads self.camera/self.scene/self.xr on each
-- call, so handing out the table before those exist is safe.
local hostApi = Mods.HostApi.new({ mod = mod, log = log, android = S.android })
mod.exports.vrHost = hostApi.vrHost
-- PORTAL_MR P1: the optional PORTAL_MR mod (lib/quest/MrLink.lua): its link, and the closures it may read.
local Mr = (function() local ok, m = pcall(V.require, "quest/MrLink"); return ok and m or { find = function() return false end } end)()
mod.exports.mrHost = Mr.host and Mr.host({ R = function() return R end, FreeMove = FreeMove, opt = opt, PerfEm = PerfEm, Mods = Mods }) or nil

-- worker "atmos" (GW-P1/P2/P4): the day/night/weather render pipeline.
local okWeather, WeatherMods = pcall(function()
  return {
    AtmosTime = V.require("render/AtmosTime"),
    AtmosState = V.require("render/AtmosState"),
    WeatherHostLib = V.require("quest/WeatherHostLib"),
    WeatherHost = V.require("quest/WeatherHost"),
  }
end)
local Weather = nil
if not okWeather then
  log("atmos (day/night/weather) failed to load: " .. tostring(WeatherMods))
else
  local okW, w = pcall(function()
    local hostLib = WeatherMods.WeatherHostLib.new({
      getHour = function()
        local r = hostApi:resolveClock()
        return r and r.hour or 12
      end,
      getSource = function()
        local r, id = hostApi:resolveClock()
        return (r and r.source) or id or "none"
      end,
      getPreset = function() return WeatherMods.AtmosTime.DEFAULT_PRESET end,
    })
    local host = WeatherMods.WeatherHost.new({ hostLib = hostLib, log = log })
    return { hostLib = hostLib, host = host, AtmosState = WeatherMods.AtmosState,
      AtmosTime = WeatherMods.AtmosTime }
  end)
  if okW then
    Weather = w
    -- DESIGN.md 4.4 A: the strict-whitelist facade TWS's legacy Gen1/Gen2
    -- adapter (DramalessAtmos, CinematicAtmos, QuestStorm) already calls.
    mod.exports.lib = { require = Weather.hostLib.require }
  else
    log("atmos (day/night/weather) failed to build: " .. tostring(w))
  end
end

-- Lab 8 (P0-2 + CHECK "Missing" 1): the logic-tick seam. At the start of
-- every 60 Hz logic tick (the engine's input.step hook, Game3:fixedUpdate)
-- data/Actors notes where everything stands, for the display-rate blend, and
-- FreeMove settles a free body the game is holding. FreeMove.install wraps
-- the engine's Player.pollWalk (seam E2) when the engine has it; without it
-- free walking stays off and logs why once.
if FreeMove then
  local okI, errI = pcall(FreeMove.install, {
    log = log, android = S.android, enabled = opt("movement") ~= "grid",
    walkSpeed = opt("walk_speed"), roomScale = opt("room_scale") ~= false,
    live = function() return S.voxelOn and not S.failed end,
    actors = ActorsMod,
  })
  if not okI then log("free walking not installed: " .. tostring(errI)) end
end
mod.hooks:wrap("input.step", function(nextFn)
  if ActorsMod then pcall(ActorsMod.beginTick) end
  if mouseStep then mouseStep() end
  if FreeMove then pcall(FreeMove.preTick) end
  return nextFn()
end, 40)
-- Lab 8 (P0-2): a save writes the session position, which the engine's 2D
-- field view sets from the avatar's pixels on every drawn frame; with a free
-- body in the north or west half of its cell that is the neighbouring cell.
-- Put the logical cell back first (FreeMove.syncSession; a no-op on the grid).
mod.hooks:wrap("save.write", function(nextFn)
  if FreeMove then pcall(FreeMove.syncSession) end
  return nextFn()
end, 40)

-- Engine modules are process singletons; cache them, because the sandboxed
-- require re-runs its deny-list checks on every call.
local engineCache = {}
local function engine(name)
  local m = engineCache[name]
  if m then return m end
  local ok, mod2 = pcall(require, name)
  if ok and type(mod2) == "table" then engineCache[name] = mod2; return mod2 end
  return nil
end

local grassRows
if GrassOptions then
  local Rows=engine("src.ui.game3.option_rows")
  if Rows then
    local ok,res=pcall(GrassOptions.install,{Rows=Rows,id=mod.id,get=opt,shapeKey="fr_grass_shape",recache="restart"})
    if ok and res then grassRows=Rows else log("Grass options unavailable: "..tostring(res)) end
  end
end

-- Lab 7: VR CONTROLS on the FireRed / Emerald OPTION screen (this file is Gen 3 only);
-- taken out again by teardown().
local vrRows
local ControlsHelp=V.require('quest/ControlsHelp')
local function installControlsHelp()
 local help=engine('src.ui.game3.help_system')
 if help then ControlsHelp.install(help,function()return R and R.xr and R.xr.started==true and mod.game and mod.game.phase~='boot' end,engine('src.core.game3.audio'))end
end
installControlsHelp()
if VrControls then
  local Rows = engine("src.ui.game3.option_rows")
  if Rows then
    local okI, res, why = pcall(VrControls.install, { Rows = Rows, id = mod.id, log = log,
      rates = function() return R and R.xr and R.xr:supportedRates() or {} end, -- VR DISPLAY: runtime-listed Hz
      pending = function() return R and R.xr and R.xr:pendingRestart() or false end, -- VR DISPLAY: needs a restart?
      get = function(key) return opt(key) end,
      cacheInfo = function() local e = mod.exports.worldCache; return e and e.info() or nil end }) -- Lab 57: WORLD CACHE size line
    if okI and res then vrRows = Rows else log("VR CONTROLS rows unavailable: " .. tostring(okI and why or res)) end
  end
end

-- Escalator rides and special field animations swap metatiles every few
-- frames; re-meshing the root for each swap is pure cost (review item 17).
local function overridesTransient()
  local W = engine("src.core.game3.warp")
  if W and W.isEscalatorActive then
    local ok, v = pcall(W.isEscalatorActive)
    if ok and v then return true end
  end
  local SA = engine("src.core.game3.special_field_anim")
  if SA and SA.isActive then
    local ok, v = pcall(SA.isActive)
    if ok and v then return true end
  end
  return false
end

local function currentGame()
  if S.game then return S.game end
  local Runtime = engine("src.core.game3.runtime")
  return Runtime and Runtime._game or nil
end

-- ------------------------------------------------------------ Lab 51
-- ALLOC TRIM: the shared VR mods (VRITK_FRLG_HOST, VR_INTERACTIONS_BACKPACK_LAB)
-- and FRLG_CATCH each expose a game-neutral exports.setAllocTrim(on); this mod
-- owns the option and pushes its value (renderer build, option change, and every
-- OPTION_PUSH frames, since those mods can load after this one).
local TRIM_MODS = { "VRITK_FRLG_HOST", "VR_INTERACTIONS_BACKPACK_LAB", "FRLG_CATCH" }
-- Lab 55: outdoor renderer switches. render/OutdoorPerf.lua is read on the hot
-- paths; this mod owns the options and pushes the two weather values to the
-- shared weather mod's game-neutral setters (it can load after this mod, so
-- the push repeats every OPTION_PUSH frames like ALLOC TRIM).
local OutdoorPerf = V.require("render/OutdoorPerf")
mod.exports.outdoorPerf = OutdoorPerf -- Lab 55: read-only diagnostics (switch values, epoch)
local WEATHER_MOD = "the_world_weather_quest_lite_private"
local function pushWeather()
  local okF, h = pcall(mod.find, WEATHER_MOD)
  local ex = okF and h and type(h.exports) == "table" and h.exports or nil
  if not ex then return end
  if type(ex.setFrameHoist) == "function" then pcall(ex.setFrameHoist, OutdoorPerf.weather) end
  if type(ex.setQuestWeatherTier) == "function" then pcall(ex.setQuestWeatherTier, OutdoorPerf.weatherTier) end
  -- SUN SHADOWS FIXED: the drawn sun and moon keep to the side the baked shadows fall away from.
  -- The weather mod's heading is degrees from +X toward +Z (world cells); fixedSunDir points
  -- toward the sun in the same world axes (render/OutdoorPerf.lua, render/SolarShadows.lua).
  if type(ex.setFixedSunAzimuth) == "function" then
    local d = OutdoorPerf.sunShadows == "fixed" and OutdoorPerf.fixedSunDir or nil
    local az = d and math.deg(math.atan2(d[3], d[1])) % 360 or nil
    local okC, cur = true, nil
    if type(ex.fixedSunAzimuth) == "function" then okC, cur = pcall(ex.fixedSunAzimuth) end
    if not okC or cur ~= az then pcall(ex.setFixedSunAzimuth, az) end
  end
end
local function pushOutdoorPerf()
  OutdoorPerf.applyAll(opt)
  pushWeather()
end
local OPTION_PUSH = 30
local function allocTrimOn() return opt("perf_alloc_trim") ~= false end
local function pushAllocTrim()
  local on = allocTrimOn()
  S.allocTrim = on
  for i = 1, #TRIM_MODS do
    local okF, h = pcall(mod.find, TRIM_MODS[i])
    local set = okF and h and type(h.exports) == "table" and h.exports.setAllocTrim
    if type(set) == "function" then pcall(set, on) end
  end
  if R and R.xr and R.xr.configure then pcall(R.xr.configure, R.xr, { lean = on }) end
end
-- Lab 50: CATCH BEAM FAST. FRLG_CATCH exposes exports.setCapturePlasmaFast(on) (its CapturePlasma keeps a
-- bit-identical fast path next to the legacy one); this mod owns the option and pushes it like ALLOC TRIM
-- (renderer build, option change, and every OPTION_PUSH frames: FRLG_CATCH can load after this mod).
local function pushCatchBeam()
  local on = opt("perf_catch_beam_fast") ~= false
  S.catchBeamFast = on
  local okF, h = pcall(mod.find, "FRLG_CATCH")
  local set = okF and h and type(h.exports) == "table" and h.exports.setCapturePlasmaFast
  if type(set) == "function" then pcall(set, on) end
end
-- One mod handle per id per frame (mod.find builds a fresh {id,version,exports}
-- table on every call). ALLOC TRIM OFF = the old direct call.
local findMemo, findMemoFrame = {}, -1
local function findMod(id)
  if not S.allocTrim then return mod.find(id) end
  if findMemoFrame ~= S.frame then
    for k in pairs(findMemo) do findMemo[k] = nil end
    findMemoFrame = S.frame
  end
  local h = findMemo[id]
  if h == nil then
    h = mod.find(id) or false
    findMemo[id] = h
  end
  return h or nil
end
-- SKIP WINDOW PRESENT: the engine's love.run reads love._pacerOuterLoop.presentGate.
-- stereo = this frame (questFrame) really submitted the stereo world. The engine
-- skips the hidden window's clear/present/cap-sleep only then, and still presents
-- every PRESENT_EVERY frames and whenever a screenshot is pending.
local presentGate = { enabled = false, stereo = false }
local function outerLoop()
  local reg = love and love._pacerOuterLoop
  if type(reg) == "table" then return reg end
  return nil
end
local function installPresentGate()
  presentGate.enabled = S.android == true and opt("perf_skip_present") ~= false
  presentGate.stereo = false
  local reg = outerLoop()
  if reg then reg.presentGate = presentGate end
end
local function removePresentGate()
  presentGate.enabled, presentGate.stereo = false, false
  local reg = outerLoop()
  if reg and rawget(reg, "presentGate") == presentGate then reg.presentGate = nil end
end

-- Lab 57 VRITK GATE: WORLD CACHE, LOADING SCREEN (+ its collect and warm-up pass) and the eye-pass probe turn on
-- only when VRITK (VRITK_FRLG_HOST) is installed and active. Without it they stay off: the game behaves as before.
local okVG, VritkGate = pcall(V.require, "quest/VritkGate")
local vritk = (okVG and type(VritkGate) == "table")
  and VritkGate.new(function(id) return mod.find(id) end, function() return love.timer.getTime() end, 1.0)
  or { active = function() return false end }
mod.exports.vritkGate = function() return vritk:active() end

-- Lab 58 SPEED PATCHES (lib/perf/Speed58.lua): the equivalent-output speed-ups run only while VRITK is installed and
-- active AND the SPEED PATCHES row (OutdoorPerf.speed58, default ON) is on. Speed58.master stays true: the gate
-- carries both conditions, so the row and VRITK absence both give exactly the Lab 57 code path.
local okS58, Speed58 = pcall(V.require, "perf/Speed58")
if okS58 and type(Speed58) == "table" then
  Speed58.setGate(function() return OutdoorPerf.speed58 ~= false and vritk:active() end)
  mod.exports.speed58 = Speed58
else
  log("speed58 failed to load: " .. tostring(Speed58))
  Speed58 = nil
end
local speed58Logged = nil
local function logSpeed58()
  if not Speed58 then return end
  local on = {}
  for name in pairs(Speed58.items) do if Speed58.on(name) then on[#on + 1] = name end end
  table.sort(on)
  local gate = Speed58.active()
  local sig = tostring(gate) .. ":" .. table.concat(on, ",")
  if sig ~= speed58Logged then
    speed58Logged = sig
    log("[speed58] gate=" .. tostring(gate) .. " items=" .. (#on > 0 and table.concat(on, ",") or "none"))
  end
end
logSpeed58() -- startup (VRITK can load after this mod: the line is repeated when the answer changes)

-- Lab 57 WORLD CACHE (lib/perf/FrPrecache*.lua): one cache object for the Scene and for the
-- CLEAR row. Optional: without it, or without mod.cache, the world builds exactly as in Lab 56.
local okPC, PrecacheMod = pcall(V.require, "perf/FrPrecache")
local worldCache = nil
local function getWorldCache()
  if worldCache ~= nil then return worldCache or nil end
  worldCache = false
  if okPC and type(PrecacheMod) == "table" then
    local okN, pc = pcall(PrecacheMod.new, { cache = mod.cache, mod = mod, log = log,
      enabled = function() return OutdoorPerf.worldCache and (not S.android or vritk:active()) end,
      gate = function() return not S.android or vritk:active() end })
    if okN and pc then worldCache = pc else log("world cache not built: " .. tostring(pc)) end
  elseif not okPC then
    log("world cache failed to load: " .. tostring(PrecacheMod))
  end
  return worldCache or nil
end
mod.exports.worldCache = {
  status = function() local pc = getWorldCache(); return pc and pc:status() or nil end,
  info = function() local pc = getWorldCache(); return pc and pc:info() or nil end,
  clear = function() local pc = getWorldCache(); return pc and pc:clear() or 0 end,
}

-- Lab 59 PRECACHE ON FIRST LOAD (lib/perf/FrPrepare.lua + PrepareHost.lua): built lazily, only while the switch,
-- WORLD CACHE and VRITK allow it. With PRECACHE ON FIRST LOAD OFF, or without VRITK, questFrame is the Lab 57/58 one.
local okPH, PrepareHost = pcall(V.require, "perf/PrepareHost")
local prepareHost = nil
local function getPrepareHost()
  if prepareHost ~= nil then return prepareHost or nil end
  prepareHost = false
  if okPH and type(PrepareHost) == "table" then
    local okN, h = pcall(PrepareHost.new, { mod = mod, log = log, V = V, Mods = Mods, OutdoorPerf = OutdoorPerf, vritk = vritk,
      worldCache = getWorldCache, grass = function() return grassRenderer end, android = S.android,
      vr = function() return S.android or (R and R.xr and R.xr.started==true) end })
    if okN and h then prepareHost = h else log("prepare host not built: " .. tostring(h)) end
  elseif not okPH then
    log("prepare host failed to load: " .. tostring(PrepareHost))
  end
  return prepareHost or nil
end

local bootPrepare -- set after renderer construction helpers
local function ensureRenderer()
  if not ControlsHelp.installed() then installControlsHelp() end
  if R then return R end
  grassRenderer = RetroGrass.new({shape=opt("fr_grass_shape"),ground="native"})
  local treeStyle=opt("fr_trees")
  V.require("render/FrlgVoxelTrees").setLowQuality(treeStyle == "voxel_low")
  V.require("render/FrlgVoxelTrees").setActive(treeStyle == "voxel" or treeStyle == "voxel_low")
  local source = Mods.WorldSource.new()
  -- Lab 57 SIGNS compat gate: lettered signs and their native-shape repairs exist only while VRITK (the
  -- VRITK_FRLG_HOST bridge) is installed AND active. Looked up through the mod registry on every map input,
  -- so load order does not matter (the bridge loads after this mod). No package.loaded.
  source.signGate = function()
    local host = mod.find("VRITK_FRLG_HOST")
    return host ~= nil and type(host.exports) == "table" and host.exports.active == true
  end
  -- Lab 59: while the world cache is live the art the mesher reads (WorldSource atlas texels) is the pre-paint one
  source.paintFree = function() return vritk:active() end -- v4: independent of WORLD CACHE (day shapes in both modes)
  -- ... and the atlas scan, texels and glass read the RTC bridge's pre-paint pixels (the provider hook WorldSource has had
  -- since the stale-scan fix, never connected before). Gated by VRITK active only (v4: cache on or off); VRITK absent = stock.
  local originalsMemo = {}
  Mods.WorldSource.setOriginalsProvider(function(pair)
    if not source.paintFree() then return nil end
    local p = hostApi:emissiveProvider()
    local f = p and p.originals
    if type(f) ~= "function" then return nil end
    -- the list is every painted texel of the tileset: ask once per paint state (the provider's revision), not per read
    local okR, rev = pcall(p.revision or function() return nil end)
    rev = okR and rev or nil
    local m = originalsMemo[pair]
    if m and rev ~= nil and m.rev == rev and m.p == p then return m.list end
    local okF, list = pcall(f, pair)
    list = okF and list or nil
    originalsMemo[pair] = { rev = rev, p = p, list = list }
    return list
  end)
  local scene = Mods.Scene.new({ source = source, mesher = buildMesher(), log = log,
    shadows = opt("shadows") ~= false, isBusy = overridesTransient, retroGrass=grassRenderer,
    precache = getWorldCache() }) -- Lab 57
  local turnStyle, snapDeg = "snap", 30 -- Lab 7: SNAP 30 is the default turn
  if VrControls then turnStyle, snapDeg = VrControls.resolveTurn(opt) end
  local camera = Mods.Camera.new({ mode = opt("camera"), vr = S.android,
    angle = opt("view34_angle"), zoom = opt("view34_zoom"), -- W2 (cam34)
    turnStyle = turnStyle, snapDeg = snapDeg, turnSpeed = opt("turn_speed") }) -- Lab 8 / Lab 7
  local panel = Mods.Panel.new()
  R = {
    source = source, scene = scene, camera = camera, panel = panel,
    billboards = Mods.Billboards.new(),
    xr = Mods.XRSession.new({ mod = mod, log = log, profile = opt("quality") or "balanced",
      display = (function() -- VR DISPLAY (stored = what the player really set); never raises
        if not VrControls then return nil end
        local okD, d = pcall(function()
          local g = S.game
          local t = g and g.mods and g.mods.modOptions
          return VrControls.resolveDisplay(opt, t and t[mod.id] or nil)
        end)
        return okD and d or nil
      end)() }),
    input = Mods.InputMap.new(),
  }
  R.view = Mods.View.new({ scene = scene, billboards = R.billboards, panel = panel,
    lightingClock=function()
      local rtc=findMod('RealTimeClockTest');local api=rtc and rtc.exports
      if api and type(api.readLightingCalendar)=='function'then return api.readLightingCalendar()end
    end,
    camera = camera, source = source, log = log, shadows = opt("shadows") ~= false,
    hostApi = hostApi, darkGate = function() return vritk:active() end, weatherHost = Weather and Weather.host or nil }) -- worker "atmos"
  hostApi.camera, hostApi.scene, hostApi.xr = camera, scene, R.xr -- W4
  hostApi.view = R.view -- Gen3 dex scanner: vrHost.camera.render draws through it
  R.hostApi = hostApi                                             -- W4
  if BattleMods then -- W6: battles in 3D
    local okP, pass = pcall(BattleMods.Pass.new, { camera = camera, hostApi = hostApi, log = print,
      findMod = function(id) return mod.find(id) end, -- W6 r2: the in-battle ball throw seam
      aimEnabled = function() return R and R.xr and R.xr.started==true and opt("battle_aim")~=false end,
      battleMove = opt("battle_move") ~= false, -- battle-move: walk / turn inside the battle area
      walkPct = function() return FreeMove and FreeMove.walkSpeed() or 75 end })
    if okP then R.battle = pass else log("battle presenter not built: " .. tostring(pass)) end
    hostApi.battlePass = R.battle
  end
  -- Lab 49: the flat-rate wrapper goes on Display.present BEFORE the pacer
  -- exists, so the pacer's displayPresent probe wraps (and times) it.
  if flat then
    flat:reset()
    flat:setRate(opt("perf_flat_rate"))
    local okF, res, why = pcall(FlatRate.install, engine("src.core.game3.display"), flat)
    if not (okF and res) then log("flat draw rate not installed: " .. tostring(okF and why or res)) end
  end
  -- Lab 8 P0-1e: per-frame split log + GC-pause debug (lib/quest/FramePacer.lua); never fatal
  pcall(function() R.pacer = V.require("quest/FramePacer").install(R, { log = log, game = currentGame, android = S.android, option = function() return opt("perf_gc_pause") end, renderOption = function() return opt("perf_gc_render") end, collectorMod = mod, stepOption = function() return opt("perf_gc_step") end, exports = mod.exports,
    flatRate = flat and function() return flat:takeCounts() end or nil }) end) -- Lab 49: drawn/skipped per window
  if R.pacer then pcall(R.pacer.setGcMode, R.pacer, opt("perf_gc_step") or "slack") end -- Lab 51: GC MODE now (schema default SLACK), not at the first poll
  pcall(R.xr.configure, R.xr, { hints = opt("perf_xr_hints") ~= false, lean = allocTrimOn() }) -- Lab 51
  pushAllocTrim() -- Lab 51
  pushOutdoorPerf() -- Lab 55
  pushCatchBeam() -- Lab 50
  installPresentGate() -- Lab 51
  return R
end

local function applyTurning()
  if not R then return end
  -- A desktop has no head to look with: the view always follows facing.
  -- Lab 8: free walking always uses LOOK on the headset (a world turning with
  -- every change of travel direction would spin the player).
  local free = FreeMove and FreeMove.active() or false
  R.camera.follow = not (mouseControls and mouseControls:looking()) and ((not S.android) or (opt("turning") == "follow" and not free))
end

-- W4 P2: root_shift, detected from main.lua right after r.view:pump(...),
-- from both the desktop and Quest paths. dx/dz (root cells) come straight
-- from View:pump's own additive return (View.lua, W4 P2: "changed, sx, sz"
-- -- changed stays first for every pre-existing caller); nil,nil when this
-- particular root change was not a seamless shift (a snap/reset instead).
--
-- Review fix #2 (REVIEW_VRITK_P2.md): dx/dz nil used to still route through
-- notifyRootShift(nil, nil, ...), which told VRITK's bridge layer to re-
-- anchor its held-prop/backpack pose by a "shift" with no actual delta --
-- silently freezing it in place across a real warp/snap instead of dropping
-- and reacquiring it. A non-seamless root change is a camera reset, not a
-- shift with zero distance: route it through notifyCameraReset("warp")
-- instead, which only emits (no numeric payload VRITK could misread as
-- "shift by 0").
local function noteRootShift(r, dx, dz)
  local rootId = r.scene and r.scene.rootId
  if rootId == nil or rootId == S.lastRootId then return end
  if S.lastRootId ~= nil and r.hostApi then
    if dx ~= nil and dz ~= nil then
      r.hostApi:notifyRootShift(dx, dz, S.lastRootId, rootId)
    else
      r.hostApi:notifyCameraReset("warp")
    end
  end
  S.lastRootId = rootId
end

-- W4 review fix #4 (REVIEW_VRITK_P2.md, Q6 "first person only"): every
-- camera-mode change site (the options menu, F8, and exports.setCamera) must
-- notify the host so VRITK_FRLG_HOST's layerUpdate can gate itself on
-- ctx.rig.mode == "first" -- before this fix, F8 and setCamera changed
-- r.camera.mode with no event at all, so a player could switch to third
-- person or the table-top overview and VRITK would keep rendering at its
-- first-person scale (10 px/m) instead of going idle. Reads r.camera.mode
-- back AFTER the change (not the raw `mode`/nxt argument) because setMode
-- can reject or clamp an invalid value; only notifies when the mode
-- actually changed, so re-selecting the same mode is a no-op.
local function applyCameraMode(r, mode, nxt)
  local prev = r.camera.mode
  if nxt then r.camera:nextMode() else r.camera:setMode(mode) end
  if r.camera.mode ~= prev then
    r.hostApi:notifyModeChanged(r.camera.mode, r.camera:metresPerCell())
  end
end

-- Stop drawing the voxel view for the rest of the session; stock view stays.
local function fail(where, err)
  if mouseControls then mouseControls:release() end
  if S.failed then return end
  S.failed = where .. ": " .. tostring(err)
  log("voxel view disabled for this session, flat fallback: " .. S.failed)
  -- W4 / CRITIQUE #8: a permanent failure is a HARD invalidate (not the
  -- "sustained flat" timer) -- a held backpack/prop must drop immediately,
  -- not up to 2s later. Guarded on R: fail() can run before ensureRenderer()
  -- (e.g. a desktop compose failure on the very first frame).
  if R and R.hostApi then R.hostApi:notifyFailed(where, err) end
end

local function fieldPhase(game)
  if not (game and game.phase == "field") then return false end
  local Runtime = engine("src.core.game3.runtime")
  if not (Runtime and Runtime.isActive and Runtime.isActive()) then return false end
  local T = engine("src.core.game3.battle_transition")
  if T and T.isActive and T.isActive() then return false end
  return true
end

local function menuOpen()
  local Runtime = engine("src.core.game3.runtime")
  if Runtime and Runtime.uiBusy then
    local ok, busy = pcall(Runtime.uiBusy)
    if ok and busy then return true end
  end
  local Stack = engine("src.ui.game3.stack")
  if Stack and Stack.busy then
    local ok, busy = pcall(Stack.busy)
    if ok and busy then return true end
  end
  -- the Help System (L/R) is a menu too: absolute d-pad, card re-anchors
  local Help = engine("src.ui.game3.help_system")
  if Help and Help.isOpen then
    local ok, open = pcall(Help.isOpen)
    if ok and open then return true end
  end
  return false
end

-- Effects the flat view paints into its own canvas and the 3D view cannot
-- show (review items 19, 20): while one runs, the frame goes flat.
local function activeCall(name, fn)
  local m = engine(name)
  local f = m and m[fn]
  if type(f) ~= "function" then return false end
  local ok, v = pcall(f)
  return ok and v and true or false
end
local function effectsNeedFlat()
  if activeCall("src.core.game3.field_move_show_mon", "isActive") then return "field-move banner" end
  if activeCall("src.core.game3.itemfinder", "isActive") then return "itemfinder" end
  if activeCall("src.core.game3.pokecenter_heal", "isActive") then
    local balls = R and R.view and R.view.healerBalls
    local ok, supported = false, false
    if balls and balls.supported then
      ok, supported = pcall(balls.supported, balls, R.scene, currentGame())
    end
    if not (ok and supported == true) then return "heal machine" end
  end
  if activeCall("src.ui.game3.credits", "isOpen") then return "credits" end
  local darkOK,darkHandled,darkWhy = false,false,nil
  if R and R.view then darkOK,darkHandled,darkWhy=pcall(R.view.darkHandled,R.view,currentGame()) end
  local FV = engine("src.core.game3.field_view")
  if FV and FV.flashRadius then
    local ok, radius = pcall(FV.flashRadius)
    if ok and radius ~= nil and not (darkOK and darkHandled==true) then return "flash darkness: "..tostring(darkOK and darkWhy or darkHandled) end
  end
  local FE = engine("src.core.game3.field_effects")
  if FE and FE.bgFlashAlpha then
    local ok, a = pcall(FE.bgFlashAlpha)
    if ok and type(a) == "number" and a > 0 then return "background flash" end
  end
  return false
end

-- SpawnCameraObject cutscenes pan the flat camera away from the player:
-- (dx, dy) cells, for the raised cameras only (never the head-locked view).
local function cameraOffset()
  local CO = engine("src.core.game3.camera_object")
  if not (CO and CO.isActive and CO.offset) then return nil end
  local okA, active = pcall(CO.isActive)
  if not (okA and active) then return nil end
  local ok, dx, dy = pcall(CO.offset)
  if not ok then return nil end
  return { (tonumber(dx) or 0) / 16, (tonumber(dy) or 0) / 16 }
end

-- ---------------------------------------------------------- graphics guard
-- Backstop for review item 1: after any caught error, pop the LOVE graphics
-- stack back to where the hook found it and rebind its canvas and shader, so
-- love.graphics.present() never runs with a mod canvas bound.
local function graphicsState()
  local g = love.graphics
  local okD, depth = pcall(g.getStackDepth)
  local okC, canvas = pcall(g.getCanvas)
  local okS, shader = pcall(g.getShader)
  return { depth = okD and tonumber(depth) or nil, canvas = okC and canvas or nil,
           shader = okS and shader or nil }
end
local function unwind(state)
  local g = love.graphics
  if state and state.depth then
    local guard = 0
    while guard < 130 do
      local ok, d = pcall(g.getStackDepth)
      if not ok or not d or d <= state.depth then break end
      if not pcall(g.pop) then break end
      guard = guard + 1
    end
  end
  if state and state.canvas then
    if not pcall(g.setCanvas, state.canvas) then pcall(g.setCanvas) end
  else
    pcall(g.setCanvas)
  end
  pcall(g.setShader, state and state.shader or nil)
end

local function renderer()
  return engine("src.render.Renderer")
end

local function clock()
  local ok, t = pcall(love.timer.getTime)
  return ok and t or os.clock()
end

local function dtNow()
  local ok, dt = pcall(love.timer.getDelta)
  return ok and dt or (1 / 60)
end

-- W6 (battle P-B1): one step of the battle presenter per frame. True for the
-- whole battle (and its transition) while the voxel view is on: battles
-- never use the flat panel (user rule 2026-09-28).
local function battleFrame(r)
  local bp = r and r.battle
  if not bp then return false end
  local ok, want = pcall(bp.frame, bp, { dt = dtNow(), enabled = S.voxelOn and not S.failed })
  if not ok then
    logOnce("battle-frame", "battle presenter error: " .. tostring(want))
    return S.voxelOn and not S.failed and bp.want == true
  end
  return want == true
end

-- ------------------------------------------------------------ flat draw rate
-- Lab 49 (lib/quest/FlatRate.lua): the flat 2D frame may be skipped only when
-- ALL of these hold, read at the start of the engine's Display.present (after
-- this frame's game update). Anything else -> the flat frame draws.
-- UI elements the in-scene card shows outside menus/text, and flat-only
-- machinery that is animated on screen: while one is up, draw every frame.
local FLAT_OVERLAYS = {
  { "src.ui.game3.map_name_popup", "isActive" },
  { "src.ui.game3.map_preview_screen", "isActive" },
  { "src.ui.game3.money_box", "isVisible" },
  { "src.ui.game3.coins_box", "isVisible" },
  { "src.ui.game3.berry_powder_box", "isVisible" },
  { "src.ui.game3.elevator_window", "isVisible" },
  { "src.ui.game3.seagallop", "isActive" },
  { "src.ui.game3.naming", "isOpen" },
  { "src.core.game3.pokecenter_heal", "isActive" },
  { "src.ui.game3.shop_menu", "isShopCamera" },
  -- a minigame runs under a "minigame" Stack layer (Stack.busy -> menuOpen);
  -- its module is not required here: the engine itself only peeks at it
  { "src.ui.game3.stack", "fullscreen" },
  -- wild-message: an open message (field dialogue or battle text) is always a blocker, whatever the other
  -- gates say: the flat frame carries its text
  { "src.ui.game3.message", "isOpen" },
}
local function flatEligible()
  -- Android, the XR session started, the 3D view on and not failed
  if not (S.android and R and R.xr and R.xr.started == true and S.voxelOn and not S.failed) then return false end
  -- the last frame composed the field world and the Quest frame showed it in 3D
  -- (world, want3d: no panel/quad view, no battle)
  if not (S.worldActive == true and S.flatWorld == true) then return false end
  -- Lab 50: the Gear watch/tablet is not on screen (and was not for WEAR_HOLD_S)
  if S.wearAway ~= true then return false end
  local game = currentGame()
  if not fieldPhase(game) then return false end -- field phase, runtime live, no battle transition
  if menuOpen() then return false end           -- uiBusy (text, choice, menus, fades, battle), stack, help
  if activeCall("src.core.game3.battle", "isActive") then return false end
  if R.battle and R.battle.want == true then return false end
  if effectsNeedFlat() then return false end
  for i = 1, #FLAT_OVERLAYS do
    local spec = FLAT_OVERLAYS[i]
    if activeCall(spec[1], spec[2]) then return false end
  end
  local MonPic = engine("src.ui.game3.mon_pic")
  if MonPic and MonPic.active then return false end
  local Display = engine("src.core.game3.display")
  if not Display or Display.planesBroken then return false end
  -- map identity: a map change or warp makes the next frame a new state
  local Runtime = engine("src.core.game3.runtime")
  local okS, session = false, nil
  if Runtime and Runtime.getSession then okS, session = pcall(Runtime.getSession) end
  local Map = engine("src.core.game3.map")
  return true, okS and type(session) == "table" and session.map or nil, Map and Map.current or nil
end

local function flatComposeVanilla() return false end
if FlatRate then
  local okN, inst = pcall(FlatRate.new, {
    rate = opt("perf_flat_rate"), log = log,
    eligible = flatEligible,
    frame = function() return S.frame end,
    -- the engine's own canvas target for render.compose (Renderer:endFrame)
    before = function()
      local GV = engine("src.render.GameViewport")
      if GV and GV.setTarget then GV.setTarget() end
    end,
    -- looked up per call: FramePacer's renderCompose probe wraps Runtime.call
    compose = function(rendererObj, ctx)
      local Runtime = engine("src.mods.Runtime")
      return Runtime.call("render.compose", flatComposeVanilla, rendererObj, ctx)
    end,
  })
  if okN then flat = inst else log("flat draw rate not built: " .. tostring(inst)) end
end

-- ------------------------------------------------------------ teardown
-- One idempotent teardown (review item 2): controller holds released, the
-- OpenXR session stopped (XRSession:stop also restores FrameCap), GPU
-- objects released, retry state reset. Called from core.quit_to_launcher,
-- core.session_ending (engine), and the game's returnToLauncher / onExit.
-- Mouse input policy belongs to the engine; the host only forwards events.
if not S.android then mouseControls = V.require("input/MouseKeyboard").new({
  mouse = love.mouse, window = love.window, free = FreeMove,
  sensitivity = function() return opt("mouse_sensitivity") end,
}) end
mouseStep = function()
  if S.android then return end
  local game = currentGame()
  local camera = R and R.camera
  local allowed = not S.android and opt("mouse_keyboard") == true and S.voxelOn and not S.failed
    and camera and camera.mode ~= "overview" and not camera.seat
    and fieldPhase(game) and not menuOpen()
    and not (prepareHost and prepareHost.shown)
    and not (S.loading and S.loading.holding) and not S.desktopBuilding
  mouseControls:context(allowed == true, camera, game and game.input, opt("movement") ~= "grid")
  mouseControls:step()
end
if not S.android then
mod.hooks:wrap("input.mouse", function(nextFn, game, ev)
  if S.android then return nextFn() end
  mouseStep()
  if mouseControls:pointer(ev) then return end
  return nextFn()
end, 90)
mod.hooks:wrap("input.focus", function(nextFn, game, ev)
  if S.android then return nextFn() end
  mouseControls:focus(ev and ev.active == true)
  return nextFn()
end, 90)
end

local function teardown(reason)
  if saveView then saveView:reset() end
  if mouseControls then mouseControls:release() end
  if bootPrepare then bootPrepare:reset() end
  S.preintroReady = nil
  if grassRows and GrassOptions then pcall(GrassOptions.uninstall,grassRows);grassRows=nil end
  if vrRows and VrControls then pcall(VrControls.uninstall, vrRows); vrRows = nil end
  local r = R
  R = nil
  if ControlsHelp then pcall(ControlsHelp.uninstall) end
  if prepareHost then pcall(prepareHost.release, prepareHost, r) end
  if S.desktopLoading then pcall(S.desktopLoading.release, S.desktopLoading); S.desktopLoading = nil end
  S.desktopBuilding = false -- Lab 59
  S.xrTries, S.xrGaveUp, S.xrNextTry = 0, false, 0
  S.perf = nil
  S.lastRootId = nil -- W4 review fix #2: a fresh session's first root must not diff against the torn-down one
  S.flatWorld = false -- Lab 49
  S.wearAway, S.wear = false, {} -- Lab 50
  S.slackWorld = false; removePresentGate() -- Lab 51 (the pacer detach below gives the collector back)
  if flat then flat:reset() end -- Lab 49: the next frame draws; R == nil keeps every frame drawing
  if FreeMove then pcall(FreeMove.uninstall, reason) end -- Lab 8
  if not r then return false end
  if r.pacer then pcall(r.pacer.cancelPause, r.pacer, reason or "teardown"); pcall(r.pacer.detach, r.pacer) end -- Lab 8 P0-1e
  -- W4 review fix #7 (optional half): a lost-session frame already reported
  -- session_stopped (questFrame, right after r.xr:frame{}) -- skip the
  -- duplicate here so a loss immediately followed by teardown emits exactly
  -- one session_stopped/invalidate, not two.
  if not hostApi.lossReported then
    hostApi:notifySessionStopped(reason or "teardown") -- W4, while r.xr/camera/scene are still live
  end
  pcall(r.input.releaseAll, r.input)
  pcall(r.xr.stop, r.xr, reason or "teardown")
  pcall(r.scene.release, r.scene)
  pcall(r.billboards.release, r.billboards)
  pcall(r.panel.release, r.panel)
  pcall(r.view.release, r.view)
  if r.battle then pcall(r.battle.release, r.battle) end -- W6
  hostApi.battlePass = nil                               -- W6
  hostApi.camera, hostApi.scene, hostApi.xr = nil, nil, nil -- W4: detach from the torn-down renderer
  hostApi.view = nil -- Gen3 dex scanner
  log("teardown (" .. tostring(reason) .. ")")
  return true
end

-- Boot loading uses the native panel before the stereo session or onboarding.
bootPrepare = V.require("perf/BootPrepare").new({
  enabled = function() return S.bootEnabled and OutdoorPerf.precacheFirstLoad ~= false and OutdoorPerf.worldCache ~= false end,
  host = getPrepareHost, renderer = ensureRenderer,
  screen = {new=function() return V.require("render/PrepareScreen").new({vr=S.android or (R and R.xr and R.xr.started==true)})end}, clock = clock,
  ready = function(value) S.preintroReady = value end,
  log = log,
})
mod.hooks:wrap("game.boot_prepare", function(nextFn, game, dt)
  if bootPrepare:hold(game) then return true end
  return nextFn()
end, 100)
mod.hooks:wrap("render.boot", function(nextFn, game, w, h)
  if bootPrepare:draw(game, w, h, S.frame) then return true end
  return nextFn()
end, 100)

-- ------------------------------------------------------------ desktop view
local function drawDesktop(ctx, battle3d)
  S.desktopBuilding = false
  local game = currentGame()
  local r = ensureRenderer()
  mouseStep()
  applyTurning()
  local ph
  if not battle3d and S.voxelOn and (not S.failed or (prepareHost and prepareHost.failure)) and not menuOpen() then
    ph = getPrepareHost()
    if ph and ph:frame(r, game, false, false, S.failed ~= nil) then
      local g = love.graphics
      local w, h = g.getDimensions()
      local c = ph:canvas(w, h)
      if c then
        g.push("all"); g.origin(); g.setShader(); g.setScissor(); g.setStencilTest(); g.setDepthMode()
        g.setColorMask(true, true, true, true); g.setWireframe(false); g.setBlendMode("alpha"); g.setColor(1, 1, 1, 1); g.draw(c, 0, 0); g.pop()
        ph:presentedFrame()
        r.input:releaseAll()
        return true
      end
      error("Preparing world screen unavailable")
    end
  end
  if S.failed then return false end
  r.view.deferRoot = OutdoorPerf.loadingScreen ~= false and not battle3d
  local _, pumpDx, pumpDz = r.view:pump(game, { budgetMs = 8 })
  noteRootShift(r, pumpDx, pumpDz) -- W4
  local bp = battle3d and r.battle or nil -- W6: pin the battle seat before the camera updates
  if bp then bp:pin(nil) end
  if bp then pcall(bp.moveFrame, bp, nil, dtNow()) end
  local ok, why = r.view:prepare(game, dtNow(), nil, { cameraOffset = cameraOffset(),
    battle = bp and bp:viewOpts() or nil })
  if not ok then
    local rootError = r.scene:rootFailure()
    if rootError and not S.failed then
      fail("scene", rootError)
      local ph = getPrepareHost()
      if ph then ph:showFailure(rootError) end
      return false
    end
    if why == "building" and OutdoorPerf.loadingScreen ~= false then
      S.desktopBuilding = true
      local g = love.graphics
      local w, h = g.getDimensions()
      local screen = S.desktopLoading
      if not screen then screen = V.require("render/PrepareScreen").new(); S.desktopLoading = screen end
      local c = screen:canvas(w, h, { phase = "building", done = 0, total = 0, frac = 0 }, clock())
      g.push("all"); g.origin(); g.setShader(); g.setScissor(); g.setStencilTest(); g.setDepthMode()
      g.setColorMask(true, true, true, true); g.setWireframe(false); g.setBlendMode("alpha"); g.setColor(1, 1, 1, 1); g.draw(c); g.pop()
      return true
    end
    if why ~= S.lastPrepareReason then
      S.lastPrepareReason = why
      log("3D view waiting: " .. tostring(why))
    end
    if why ~= "building" and r.scene:rootFailure() then fail("scene", why) end
    return false
  end
  S.lastPrepareReason = nil
  if bp then bp:prepareFrame(r.view, ctx.uiCanvas) end -- W6: battle card canvases
  local g = love.graphics
  local ww, wh = g.getDimensions()
  local pw, ph = g.getPixelDimensions()
  local sx, sy = ww / pw, wh / ph
  if S.preview == "sbs" then
    local ew = math.floor(pw / 2)
    local views = Mods.Camera.syntheticViews(ew, ph)
    -- W4: DESIGN.md 2a scopes the P1 layer slot to Quest and desktop
    -- side-by-side frames (not mono). controls come from whatever
    -- vrHost.debug.setMockControls() last set (CRITIQUE #15: drive this
    -- from F9, never F7, which turns 3D off outright).
    local layerCtx = r.hostApi:beginFrame({
      dt = dtNow(), controls = r.hostApi:snapshot(), views = views,
      menuOpen = false, field = not battle3d, battle = battle3d == true, -- W6
    })
    r.hostApi:updateLayers(layerCtx)
    for i = 1, 2 do
      local c = r.view:canvas("sbs" .. i, ew, ph)
      if not c then return false end
      local okE, errE = r.view:renderEye(c, views[i], { hostApi = r.hostApi, eyeIndex = i,
        battle = bp }) -- W6
      if not okE then fail("render", errE); return false end
      g.setColor(1, 1, 1, 1)
      g.draw(c, (i - 1) * ew * sx, 0, 0, sx, sy)
    end
    r.hostApi:setWorldActive(true, "desktop-sbs") -- W4: reached only on full success above
  else
    local c = r.view:canvas("mono", pw, ph)
    if not c then return false end
    local eye = { pose = nil, fov = Mods.Camera.monoFov(pw / ph, r.camera:monoFovY()) }
    local okE, errE = r.view:renderEye(c, eye, { pitch = r.camera:monoPitch(), battle = bp }) -- W6
    if not okE then fail("render", errE); return false end
    g.setColor(1, 1, 1, 1)
    g.draw(c, 0, 0, 0, sx, sy)
    r.hostApi:setWorldActive(false, "desktop-mono") -- W4: layers do not run in mono
  end
  -- UI plane (text, menus, popups) over the 3D view, integer-scaled like
  -- the flat game frame. W6: not in a 3D battle, where the UI canvas holds
  -- the whole flat battle frame (its text/command strip is on the battle card).
  local ui = (not battle3d) and ctx.uiCanvas or nil
  if ui then
    local uw, uh = ui:getWidth(), ui:getHeight()
    local k = math.max(1, math.floor(math.min(pw / uw, ph / uh)))
    local dx = math.floor((pw - uw * k) / 2)
    local dy = math.floor((ph - uh * k) / 2)
    g.setColor(1, 1, 1, 1)
    g.draw(ui, dx * sx, dy * sy, 0, k * sx, k * sy)
  end
  local Rn = ctx.renderer
  local veil = Rn and Rn.screenVeil
  if r.battle then -- W6: the battle fade to black and back
    local okV, v2 = pcall(r.battle.veil, r.battle, veil)
    if okV then veil = v2 end
  end
  if veil and (veil[4] or 0) > 0 then
    g.setColor(veil[1] or 0, veil[2] or 0, veil[3] or 0, veil[4])
    g.rectangle("fill", 0, 0, ww, wh)
  end
  g.setColor(1, 1, 1, 1)
  return true
end

-- ------------------------------------------------------------ render.compose
-- Optional intro scene shares this host's existing XR session.
local function immersiveIntroScene()
  if not S.bootEnabled or not S.voxelOn or S.failed then return nil end
  local game = currentGame()
  local boot = game and game.boot
  -- The menu can precede preparation; selecting an action gives loading ownership.
  local preparing = bootPrepare and bootPrepare.selected ~= nil and not bootPrepare.done
  local pending = boot and (boot.fadeThen == "new_game" or boot.fadeThen == "continue")
  if preparing or pending then return nil end
  local function resolve(id)
    local h = type(mod.find) == "function" and mod.find(id)
    local scene = h and h.exports and h.exports.scene
    if type(scene) ~= "table" or type(scene.active) ~= "function"
        or type(scene.drawEyes) ~= "function" or type(scene.drawDesktop) ~= "function" then return nil end
    local ok, active = pcall(scene.active)
    return ok and active == true and scene or nil
  end
  local title = resolve("firered_vr_title")
  if title then return title end
  if S.preintroReady ~= true then return nil end -- preparation barrier owns onboarding until complete
  return resolve("gen3_immersive_intro")
end

local function onCompose(ctx)
  -- Loading alone bypasses native-artwork scaling. Keep the same 960x640
  -- canvas sharp in the final native panel, before intro or Android routing.
  if bootPrepare and bootPrepare:composeCurrent(currentGame(),
      ctx.ww or love.graphics.getWidth(), ctx.wh or love.graphics.getHeight(), S.frame) then return true end
  local introScene = not S.android and immersiveIntroScene()
  if introScene and introScene.drawDesktop(ctx) == true then return true end

  S.composeFrame = S.frame
  S.worldActive = ctx.worldActive == true
  if S.android then
    if R and R.xr.started then
      -- The headset shows only this mod's layers now: keep a flat copy for
      -- PANEL mode and skip compositing the (invisible) window.
      -- Lab 49: not on a FLAT DRAW RATE skipped frame (the canvases hold the
      -- last drawn frame; the chain below still runs). A real frame's ctx is
      -- kept for the next skipped frame's compose.
      if not (flat and flat:isSkipFrame(S.frame)) then
        if flat then pcall(flat.capture, flat, ctx.renderer, ctx) end
        R.panel:composeFlat(ctx, S.frame)
      end
      return true
    end
    return false
  end
  -- W6: a battle (and its transition) stays in 3D while the voxel view is on
  local battle3d = battleFrame(R)
  if not (S.voxelOn and (not S.failed or (prepareHost and prepareHost.failure))
      and (battle3d or (ctx.worldActive and fieldPhase(currentGame())))) then
    return false
  end
  if not battle3d and effectsNeedFlat() then return false end
  local drawn = drawDesktop(ctx, battle3d)
  if battle3d and not drawn then
    -- W6: never the flat battle frame (e.g. a map still building): black
    local g = love.graphics
    g.setColor(0, 0, 0, 1)
    g.rectangle("fill", 0, 0, g.getDimensions())
    g.setColor(1, 1, 1, 1)
    return true
  end
  return drawn
end

-- gear-hook/DESIGN.md section 2c: on the two paths where onCompose(ctx)
-- fully handles the frame itself (Android once XR has started; desktop in
-- the voxel field view) this hook used to return true immediately, WITHOUT
-- ever calling nextFn() -- so VRITK's frame hook (priority -999, which
-- copies Kanto Gear's watch/tablet screen) and Gear's own hook (-1000,
-- which refreshes its FireRed data and redraws) never ran at all. That is
-- why the watch/tablet screens stayed black on FireRed: VRITK's frame()
-- never returned a ready surface, so the device renderer drew only the
-- blank backing. Fix: still do FRLG_VOXEL's own work first, but then call
-- nextFn() to let the rest of the chain run, restore the graphics state
-- (nextFn's own draws may leave it dirty) and THEN return true -- the
-- engine's default end-of-chain step is `function() return false end`
-- (Renderer.lua:918) and the whole-window composite only runs when the
-- chain does NOT return true, so passing the frame on this way costs no
-- extra composite. Gated on kanto_gear actually being loaded (optional
-- cost limit from the design doc): on a setup with no Gear at all, this
-- keeps the original fast path (immediate return, no extra hook calls).
local gearLoaded = nil
mod.hooks:wrap("render.compose", function(nextFn, rendererObj, ctx)
  local state = graphicsState()
  local ok, handled = pcall(onCompose, ctx or {})
  if ok and handled == true then
    if gearLoaded == nil then
      gearLoaded = type(mod.find) == "function" and mod.find("kanto_gear") ~= nil
    end
    if gearLoaded then
      nextFn()
      unwind(state)
    end
    return true
  end
  if not ok then
    unwind(state)
    fail("compose", handled)
    if S.android and R and R.xr.started then return true end
  end
  return nextFn()
end, 40)

-- ------------------------------------------------------------ Quest frame
local function centerPose(views)
  local a, b = views[1].pose, views[2] and views[2].pose or views[1].pose
  return {
    pos = { (a.pos[1] + b.pos[1]) / 2, (a.pos[2] + b.pos[2]) / 2, (a.pos[3] + b.pos[3]) / 2 },
    quat = a.quat,
  }
end

-- Lab 7: a head pushed into a wall dims the view (FreeMove.roomDim).
local roomVeilBuf = { 0, 0, 0, 0 }
local function roomVeil(veil, dim)
  if dim > ((veil and veil[4]) or 0) then
    roomVeilBuf[4] = dim
    return roomVeilBuf
  end
  return veil
end

-- Lab 57 LOADING SCREEN (lib/render/VoxelLoading.lua). Optional: without the module, or with the switch OFF,
-- questFrame is exactly the Lab 56 one (the flat game is shown while the world builds).
local okVL, VoxelLoading = pcall(V.require, "render/VoxelLoading")
if not (okVL and type(VoxelLoading) == "table") then log("loading screen failed to load: " .. tostring(VoxelLoading)); VoxelLoading = nil end
local loadingO = {}
-- Lab 60: the Loading screen's inputs (lib/render/LoadingGate.lua): menu check that ignores the engine screen Fade, the hard
-- re-root latch, the show/hide log. Optional like VoxelLoading; without it Lab 58 behaviour.
local okLG, LoadingGate = pcall(V.require, "render/LoadingGate")
if not (okLG and type(LoadingGate) == "table") then log("loading gate failed to load: " .. tostring(LoadingGate)); LoadingGate = nil end
local function loadingMenuOpen()
  if LoadingGate then return LoadingGate.menuOpenNoFade(engine, menuOpen) end
  return menuOpen()
end
-- Lab 57 eye-pass probe: Lab 56 on the headset had a single ~5 s frame on the first outdoor eye pass after leaving
-- the Pokemon Center (cause unknown: lazy shader compile, atlas mirror canvases, uploads?). Any world frame
-- whose prepare / canvas / eye pass takes >= 100 ms logs where the time went (max 12 lines per session).
local okMipP, MipP = pcall(V.require, "render/Mip")
local probeLines = 0
local pb = { sc = 0, sm = 0, mc = 0, mm = 0, bc = 0, bm = 0 }
-- Lab 60: creation ledger (lib/perf/EyeLedger.lua): counts every GPU-side creation of ANY mod by pass, so a slow eye
-- names its culprit (Lab 58's 4.3 s was the weather mod's cloud texture + shader, invisible to Mods.Shaders.stats).
-- Armed only while the probe can still log (12 lines per session); wrappers are removed afterwards.
local okEL, EyeLedger = pcall(V.require, "perf/EyeLedger")
if not (okEL and type(EyeLedger) == "table") then EyeLedger = nil end
local function ledgerFrame(r)
  local EL = EyeLedger
  if not EL then return end
  if not S.ledgerSet then
    S.ledgerSet = true
    EL.setGate(function() return vritk:active() end)
    EL.setLog(log)
  end
  if probeLines < 12 and vritk:active() then
    if not EL.isArmed() then EL.arm() end
    if r and r.view then r.view.eyeLedger = EL end
    EL.frameBegin()
  elseif EL.isArmed() then
    EL.disarm()
    if r and r.view then r.view.eyeLedger = nil end
  end
end
local function eyeProbe(prepMs, canvMs, e1, e2)
  if not vritk:active() then return end
  local shs, mps = Mods.Shaders.stats, okMipP and MipP.stats or nil
  local worst = math.max(prepMs, canvMs, e1, e2)
  if worst >= 100 and probeLines < 12 then
    probeLines = probeLines + 1
    local EL = EyeLedger
    local ledger = EL and EL.isArmed() and EL.frameReport() or nil
    if ledger then log("eye probe ledger: " .. ledger .. (" | shaders created by all mods since start: %d (%.0f ms)"):format(EL.shaders())) end
    log(("eye probe: SLOW world frame prepare=%.0f ms canvases=%.0f ms eyes=%.0f/%.0f ms | first-use work since the last world frame: shaders compiled %d (%.0f ms), atlas mirror canvases %d (%.0f ms), mirror blits %d (%.0f ms)")
      :format(prepMs, canvMs, e1, e2, shs and shs.compiles - pb.sc or -1, shs and shs.ms - pb.sm or -1,
        mps and mps.mirrors - pb.mc or -1, mps and mps.ms - pb.mm or -1, mps and mps.blits - pb.bc or -1, mps and mps.blitMs - pb.bm or -1))
  end
  if shs then pb.sc, pb.sm = shs.compiles, shs.ms end
  if mps then pb.mc, pb.mm, pb.bc, pb.bm = mps.mirrors, mps.ms, mps.blits, mps.blitMs end
end
-- After the build pump, before the frame. -> hold (bool: the world is not submitted), warm (bool: this frame
-- renders the eyes but does not submit them)
local function loadingStep(r, game, dt, want3d, battle3d, hard)
  if not VoxelLoading then return false end
  local LD = S.loading
  if OutdoorPerf.loadingScreen == false or not vritk:active() then
    if LD and LD.holding then LD.holding, LD.elapsed, LD.endWhy = false, 0, "disabled" end
    if S.loadGate then S.loadGate.hardAt = nil end
    return false
  end
  if not LD then LD = VoxelLoading.new(); S.loading = LD end
  local o = loadingO
  local pl = ActorsMod and ActorsMod.player and ActorsMod.player()
  local due, ready = 0, false
  local okD, d = pcall(r.scene.buildsDue, r.scene, pl and { x = pl.x, z = pl.z } or nil, r.view.farCells or 60)
  if okD then due = d else due = 0 end
  local rootError = r.scene:rootFailure()
  if rootError and not S.failed then
    fail("scene", rootError)
    local ph = getPrepareHost()
    if ph then ph:showFailure(rootError) end
  end
  ready = r.scene:ready() == true
  o.dt, o.enabled, o.failed, o.battle = dt, true, S.failed ~= nil, battle3d == true
  o.menu, o.phase, o.active = loadingMenuOpen() == true, game and game.phase or nil, want3d == true -- Lab 60: a Fade is not a menu here
  -- Lab 60: the one-shot hard flag is latched for HARD_LATCH_S (cleared once the hold has started)
  local lg = S.loadGate
  if not lg then lg = {}; S.loadGate = lg end
  if LoadingGate then hard = LoadingGate.effectiveHard(lg, hard == true, clock()) end
  o.hard, o.reason, o.rootReady, o.due = hard == true, S.prepWhy, ready, due
  o.warmed = S.warmed == true
  local was = LD.holding
  local okU, hold, collect, warm = pcall(LD.update, LD, o)
  if not okU then LD.holding = false; logOnce("loading", "loading screen step failed: " .. tostring(hold)); return false end
  if hold and LoadingGate then LoadingGate.consumed(lg) end -- the latch has done its job
  if hold and not was then log(("loading screen: hold started (hard=%s reason=%s due=%d)"):format(tostring(o.hard), tostring(o.reason), due)) end
  if collect then
    S.warmed = false
    local kb0 = collectgarbage("count")
    local kb1 = VoxelLoading.collect(r.pacer)
    log(("loading screen: held %.1f s%s, due=%d, full collect behind the black screen: heap %.0f MB -> %s MB")
      :format(LD.lastElapsed or 0, LD.lastCapped and " (CAPPED)" or "", due, kb0 / 1024, kb1 and ("%.0f"):format(kb1 / 1024) or "?"))
  end
  return hold == true, warm == true
end

-- Lab 60: build the weather mod's cloud deck (image, mesh, shader, one offscreen warm-up draw) BEFORE the first outdoor eye
-- frame, so nothing is created lazily there (Lab 58/59 headset: a 4.0-4.3 s first outdoor eye frame, even with a cache hit).
-- One stage per frame from the first frame of the session ('idle'), all at once when the Loading hold starts ('loading').
-- Behind the VRITK gate; the weather side logs `cloud deck warmed at <phase> in N ms` once.
local cloudWarm = { done = false, next = 0, tries = 0 }
local function cloudPrewarm(r, frame, holdingNow)
  if cloudWarm.done or frame < cloudWarm.next or not vritk:active() then return end
  local wh = r.view and r.view.weatherHost
  if not (wh and wh.prewarm) then cloudWarm.done = true; return end
  local ok, done, info = pcall(wh.prewarm, wh, holdingNow and "loading" or "idle", not holdingNow)
  if not ok then cloudWarm.done = true; logOnce("cloudwarm", "cloud prewarm failed: " .. tostring(done)); return end
  if done then
    if info == "unavailable" and cloudWarm.tries < 40 then -- the weather compat publishes its hook after mods.loaded
      cloudWarm.tries = cloudWarm.tries + 1; cloudWarm.next = frame + 60
    else
      cloudWarm.done = true
    end
  end
end

local function questFrame(frame)
  -- Log presentation gates on changes only. This does not modify preferences.
  if frame % 120 == 0 then
    local game = currentGame()
    local title = type(mod.find) == "function" and mod.find("firered_vr_title")
    local status = title and title.exports and title.exports.status
    local ok, st = false, nil
    if type(status) == "function" then ok, st = pcall(status) end
    st = ok and type(st) == "table" and st or {}
    local fields = { tostring(game and game.phase), tostring(game and game.boot and game.boot.phase),
      tostring(S.bootEnabled), tostring(S.voxelOn), tostring(S.failed), tostring(S.xrGaveUp),
      tostring(R and R.xr and R.xr.started), tostring(st.active), tostring(st.phase), tostring(st.failed) }
    local signature = table.concat(fields, "|")
    logOnce("presentation:" .. signature, "presentation gates game/boot/enabled/voxel/error/gaveUp/xr/titleActive/titlePhase/titleFailed=" .. signature)
  end
  if not S.bootEnabled then return end
  local game = currentGame()
  if game and game.phase == "boot" and S.preintroReady ~= true and not immersiveIntroScene() then
    if S.titleXRScene then
      S.titleXRScene.updateXR(nil, nil, 0, { epoch = S.titleXREpoch, frame = frame, unavailable = true })
      S.titleXRScene = nil
    end
    -- A title may have started XR before loading; keep submitting its native panel.
    if R and R.xr.started then
      local controls = R.xr:frame({ wantWorld = false, wantPanel = true, panelFollow = true,
        panelCanvas = function()
          if bootPrepare and bootPrepare.selected and not bootPrepare.done and bootPrepare.lastCanvas then
            return bootPrepare.lastCanvas
          end
          return R.panel:quadCanvas(frame, Mods.XRSession.QUAD_W, Mods.XRSession.QUAD_H)
        end })
      R.hostApi.lastControls = controls
      R.input:apply(controls, { menuOpen = true, faceLook = false, battleWalk = false, suppress = {} })
      if not R.xr.started then R.hostApi:notifySessionStopped("session-lost"); R.hostApi.lossReported = true end
    end
    return
  end
  local r = ensureRenderer()
  if frame % OPTION_PUSH == 0 then pushAllocTrim(); pushWeather(); pushCatchBeam(); logSpeed58() end -- Lab 51 / Lab 55 / Lab 50: mods that loaded after us
  applyTurning()
  if not r.xr.started then
    if S.xrGaveUp or not (immersiveIntroScene() or fieldPhase(game)) then return end
    local t = clock()
    if t < (S.xrNextTry or 0) then return end
    -- once XR.start runs, the native launcher may already have released its
    -- OpenXR session (QuestNativeXR.start), so a failure is NOT "the stock
    -- panel stays in charge" (review item 3)
    if not r.xr:unavailableReason() then S.handedOver = true end
    local ok, why = r.xr:start()
    if not ok then
      if why == "not-android" then
        S.xrGaveUp = true
        logOnce("xr:" .. tostring(why), "Quest stereo unavailable (" .. tostring(why)
          .. "); the stock flat panel stays in charge")
      else
        S.xrTries = S.xrTries + 1
        local wait = math.min(10, 1.25 * 2 ^ (S.xrTries - 1))
        S.xrNextTry = t + wait
        log(("Quest OpenXR start failed (%s); retrying in %ds"):format(tostring(why),
          math.floor(wait + 0.5)))
      end
      return
    end
    S.xrTries, S.xrNextTry = 0, 0
    S.titleXREpoch = (S.titleXREpoch or 0) + 1
    r.hostApi:notifySessionStarted(r.xr.refreshRate) -- W4
    if r.battle then r.battle:notifyReset("session-started") end -- W6: re-pin (CRITIQUE #20)
  end
  local introScene = immersiveIntroScene()
  if introScene then
    love.graphics.setCanvas()
    -- This is an intro frame, not an overworld/gear frame.
    r.hostApi:setWorldActive(false, "immersive-intro")
    r.hostApi.field, r.hostApi.battle, r.hostApi.menuOpen = false, false, true
    local titleInputOwned, titleUpdated = false, false
    local sceneDt = dtNow()
    local sceneContext = { epoch = S.titleXREpoch, frame = frame }
    if saveView then saveView:setInXR(true) end
    local controls, views, world, reason = r.xr:frame({
      wantWorld = true, wantPanel = false,
      renderEyes = function(v)
        if type(introScene.updateXR) == "function" then
          S.titleXRScene = introScene
          titleUpdated = true
          titleInputOwned = introScene.updateXR(v, r.xr.lastControls, sceneDt, sceneContext) == true
        end
        return introScene.drawEyes(v)
      end,
      panelCanvas = function()
        return r.panel:quadCanvas(frame, Mods.XRSession.QUAD_W, Mods.XRSession.QUAD_H)
      end,
    })
    r.hostApi.lastControls = controls
    if not r.xr.started then
      local status = type(views) == "string" and views or reason or "session-lost"
      r.hostApi:notifySessionStopped(status)
      r.hostApi.lossReported = true
    end
    if not titleUpdated and type(introScene.updateXR) == "function" then
      introScene.updateXR(nil, nil, 0, { epoch = S.titleXREpoch, frame = frame, unavailable = true })
    end
    -- Portal intent owns menu actions while tracked; native title/naming keep menu mapping.
    local actions = {}
    if titleInputOwned then
      r.input:releaseAll()
    else
      actions = r.input:apply(controls, {
        menuOpen = true, faceLook = false, battleWalk = false, suppress = {},
      })
    end
    if actions.toggle then
      S.voxelOn = not S.voxelOn
      if not S.voxelOn then r.hostApi:invalidateNow("toggle-off") end
    end
    if type(introScene.afterFrame) == "function" then introScene.afterFrame(controls) end
    return
  end
  -- LOVE's belief between passes is "screen bound"; the host blits end with
  -- framebuffer 0 bound, so make the two agree before the XR frame.
  love.graphics.setCanvas()
  local dt = dtNow()
  -- First-use cloud work waits until a loading panel has already been submitted.
  if not cloudWarm.done and (S.preparationPresented or (OutdoorPerf.loadingScreen == false and OutdoorPerf.precacheFirstLoad == false)) then cloudPrewarm(r, frame, false) end
  local field = S.composeFrame == frame and S.worldActive and fieldPhase(game)
  -- W6: battles (and their transition) stay 3D while the voxel view is on;
  -- only the player's own toggle/option shows the flat game
  local battle3d = battleFrame(r)
  local bp = battle3d and r.battle or nil
  local want3d = S.voxelOn and not S.failed and ((field and not effectsNeedFlat()) or battle3d)
  if ControlsHelp.isOpen() then want3d=false end
  -- Lab 60: with the Loading screen on, a warp's new root is NOT built inside this frame's pump (that is one 0.2-1.1 s
  -- call before the frame is submitted, so Loading could never be on screen during it). The pump queues the root job, this
  -- frame submits the Loading panel, and the job is built sliced under the hold from the next frame on.
  r.view.deferRoot = LoadingGate ~= nil and VoxelLoading ~= nil
    and LoadingGate.wantDefer(OutdoorPerf.loadingScreen ~= false, vritk:active(), want3d, S.loading ~= nil and S.loading.holding == true)
  -- map building happens here, outside xrWaitFrame..xrEndFrame, in panel
  -- frames too, under a per-frame budget (review item 11)
  local pumpHard = false
  -- Lab 59 PRECACHE ON FIRST LOAD: while the Preparing 3D world screen is up it owns the frame (no live pump, no
  -- Loading hold, panel instead of the world, no controls to the game). Nil when the switch is OFF / VRITK absent.
  local prepShow = false
  if game and game.phase == "field" and prepareHost ~= false and (OutdoorPerf.precacheFirstLoad ~= false or (prepareHost and prepareHost.failure)) then
    local ph = getPrepareHost()
    if ph then
      local okH, shown = pcall(ph.frame, ph, r, game, battle3d, loadingMenuOpen(), S.failed ~= nil)
      prepShow = okH and shown == true
      if not okH then logOnce("prepare", "prepare step failed: " .. tostring(shown)) end
    end
    if prepShow then want3d = false end
  end
  if game and game.phase == "field" and not prepShow and not S.failed then
    local okP, errP, pumpDx, pumpDz = pcall(r.view.pump, r.view, game, { budgetMs = (want3d and not (S.loading and S.loading.holding)) and 6 or 12 })
    if not okP then
      logOnce("pump", "map build pump failed: " .. tostring(errP))
      fail("pump", errP)
      local ph = getPrepareHost()
      if ph then ph:showFailure(errP) end
    end
    noteRootShift(r, okP and pumpDx or nil, okP and pumpDz or nil) -- W4
    pumpHard = okP and errP == true and pumpDx == nil -- Lab 57: a hard re-root (boot, warp, Fly): no seamless shift
  end
  -- Lab 57 LOADING SCREEN: while holding, the world is not drawn and the quad shows Loading
  local holding, warming = false, false
  if VoxelLoading and not prepShow then
    local okS, h, w = pcall(loadingStep, r, game, dt, want3d, battle3d, pumpHard)
    holding, warming = okS and h == true, okS and w == true
    if holding and not warming then want3d = false end
  end
  S.prepWhy = nil
  local Rn = renderer()
  local veil = Rn and Rn.screenVeil
  if r.battle then -- W6: the battle fade to black and back
    local okV, v2 = pcall(r.battle.veil, r.battle, veil)
    if okV then veil = v2 end
  end
  local open = menuOpen()
  -- W6 r2: in a staged 3D battle the hands keep working (the pouch, a ball
  -- throw at the foe): VR layers and input claims see no open menu, so a
  -- grip is never a fresh L/R (the battle Help screen). The game input still
  -- treats the battle as a menu (absolute d-pad).
  local handsMenu = open and not (bp and bp:seated())
  local camOffset = cameraOffset()
  local center
  local renderStart, renderMs = 0, nil
  local mr = Mr.find(mod, S.frame) and Mr.s:frame({ battle = battle3d == true, field = field == true, menu = open == true, want3d = want3d == true, dt = dt }) or nil -- PORTAL_MR P1 (nil without PORTAL_MR)
  local collector
  if r.pacer and r.pacer.collector and r.pacer.collector.stage~=0 then
    collector=r.pacer:collectorBeforeFrame(field==true and want3d==true and not open and not battle3d,
      r.scene,r.scene and r.scene.rootId,mr)
  end
  -- Lab 51: GC MODE SLACK owns the collector only for a stereo world frame (never
  -- while the GC RENDER TEST scope runs); slackAfterFrame hands it back otherwise.
  if r.pacer and r.pacer.slackFrame then r.pacer:slackFrame(want3d == true and collector == nil) end
  if saveView then saveView:setInXR(true) end
  local controls, views, world, reason = r.xr:frame({
    collector = collector,
    wantWorld = want3d,
    wantPanel = not want3d,
    panelFollow = holding or prepShow, -- Lab 60: the Loading panel follows the head like the comfortable panel (XRSession)
    mr = mr, -- PORTAL_MR P1
    renderEyes = function(v)
      renderStart = clock()
      ledgerFrame(r) -- Lab 60
      center = centerPose(v)
      if bp then bp:pin(center) end -- W6: pin the seat to this head pose
      if bp then -- battle-move: walk / turn / room-scale inside the battle area (before the camera updates)
        pcall(bp.moveFrame, bp, center, dt)
        local bdim = bp:moveDim()
        if bdim > 0 then veil = roomVeil(veil, bdim) end
      end
      if FreeMove then -- Lab 7: room-scale walking (first person, 3D field, FREE movement only)
        local okR, room = pcall(FreeMove.roomFrame, { hx = center.pos[1], hz = center.pos[3],
          yaw = r.camera:turnYaw(), m = Mods.Camera.METRES_PER_CELL, dt = dt, game = game,
          allowed = r.camera.mode == "first" and not r.camera.follow and not r.camera.seat and not bp })
        r.camera:setRoom(okR and room or nil)
        local dim = FreeMove.roomDim()
        if dim > 0 then veil = roomVeil(veil, dim) end
      end
      local tProbe = clock()
      local ok, why = r.view:prepare(game, dt, center, { cameraOffset = camOffset,
        battle = bp and bp:viewOpts() or nil })
      if not ok then S.prepWhy = why; return nil, why end
      local probePrep = (clock() - tProbe) * 1000
      r.panel:updateCardPose(center, open)
      if bp then bp:prepareFrame(r.view, Rn and Rn.canvas) end -- W6: battle card canvases

      -- W4: layer update once per world frame, right after prepare
      -- succeeds (vritk-hook/DESIGN.md 2a Layers "Rules").
      local layerCtx = r.hostApi:beginFrame({
        dt = dt, controls = r.xr.lastControls, views = v,
        head = center, menuOpen = handsMenu, field = not battle3d, battle = battle3d == true, -- W6
      })
      r.hostApi:updateLayers(layerCtx)

      local tabletMod=findMod('VRITK_FRLG_HOST');local tablet=tabletMod and tabletMod.exports and tabletMod.exports.compat and tabletMod.exports.compat.tablet;local tabletOwnsCard=tablet and tablet.presented() or false
      local out = {}
      local probeCanv, probeE1, probeE2 = 0, 0, 0
      for i = 1, 2 do
        local tc0 = clock()
        local rs = r.xr.renderScale and r.xr:renderScale() or 1 -- VR DISPLAY: above 100% = supersampling
        local c = r.view:canvas("eye" .. i, rs > 1 and math.floor(v[i].w * rs + 0.5) or v[i].w,
          rs > 1 and math.floor(v[i].h * rs + 0.5) or v[i].h)
        if not c then return nil, "eye canvas allocation failed" end
        probeCanv = probeCanv + (clock() - tc0) * 1000
        local te0 = clock()
        local okE, errE = r.view:renderEye(c, v[i], {
          uiCanvas = Rn and Rn.canvas, showCard = not bp and not tabletOwnsCard, veil = veil, -- W6: battle card/fade
          hostApi = r.hostApi, eyeIndex = i, -- W4
          battle = bp, -- W6
        })
        if not okE then return nil, "render: " .. tostring(errE) end
        if i == 1 then probeE1 = (clock() - te0) * 1000 else probeE2 = (clock() - te0) * 1000 end
        out[i] = c
      end
      renderMs = (clock() - renderStart) * 1000
      eyeProbe(probePrep, probeCanv, probeE1, probeE2)
      -- Lab 57 LOADING SCREEN warm-up: the eyes were rendered for real (first-use work done); do not submit them
      if warming then S.warmed = true; return nil, "building" end
      return out
    end,
    panelCanvas = function()
      if ControlsHelp.isOpen() then return ControlsHelp.canvas(Mods.XRSession.QUAD_W,Mods.XRSession.QUAD_H) end
      if prepareHost and prepareHost.failure then
        local c = prepareHost:canvas(Mods.XRSession.QUAD_W, Mods.XRSession.QUAD_H)
        if c then return c end
      end
      -- W6: never the flat battle frame; black on the rare failed 3D frame
      if battle3d and r.battle then
        return r.battle:blankCanvas(Mods.XRSession.QUAD_W, Mods.XRSession.QUAD_H)
      end
      -- Lab 59: the Preparing 3D world screen replaces the flat game while the precache runs
      if prepShow and prepareHost then
        local pcv = prepareHost:canvas(Mods.XRSession.QUAD_W, Mods.XRSession.QUAD_H)
        if pcv then S.prepareCanvasFrame = frame; return pcv end
      end
      -- Lab 57 LOADING SCREEN: the black Loading canvas replaces the flat game while the hold is on or the root is building
      if VoxelLoading and OutdoorPerf.loadingScreen ~= false and vritk:active() and S.loading
          and VoxelLoading.shouldShow({ enabled = true, failed = S.failed ~= nil, battle = false, menu = loadingMenuOpen() == true, -- Lab 60: a Fade is not a menu
            phase = game and game.phase or nil, holding = holding, reason = S.prepWhy }) then
        local okC, c = pcall(S.loading.canvas, S.loading, Mods.XRSession.QUAD_W, Mods.XRSession.QUAD_H)
        if okC and c then S.loadShownFrame = frame; return c end
      end
      return r.panel:quadCanvas(frame, Mods.XRSession.QUAD_W, Mods.XRSession.QUAD_H)
    end,
  })

  -- W4 review fix #7 (REVIEW_VRITK_P2.md): XRSession:frame's early-return
  -- paths (session lost, no handle, waiting-for-focus, frame-wait-failed)
  -- `return nil, <status string>` -- only 2 values -- so this call's 4-slot
  -- destructuring lands that status string in `views` (world/reason stay
  -- nil), not in `reason` where the rest of this function expects a status.
  -- Recovered here rather than at the source: XRSession:frame's return
  -- shape must not change (other callers/tests rely on it exactly as is).
  local xrStatus = (world == nil and type(views) == "string") and views or nil
  if not xrStatus and world == false and r.xr.panelSubmitted == true then
    if prepShow and prepareHost and S.prepareCanvasFrame == frame then prepareHost:presentedFrame(); S.preparationPresented = true end
    if S.loadShownFrame == frame then S.preparationPresented = true end
  end
  if saveView then
    saveView:setInXR(false)
    local okPreview, previewError = pcall(function()
      local context, eligible, rejection = saveView.deps.context(game)
      if eligible then
        if holding then rejection="frame-holding" elseif warming then rejection="frame-warming"
        elseif prepShow then rejection="frame-preparing" elseif battle3d then rejection="frame-battle"
        elseif mr then rejection="frame-mr" end
      end
      saveView:afterFrame(context, type(views)=="table" and views[1] or nil, world == true, open,
        eligible and not holding and not warming and not prepShow and not battle3d and not mr, frame, rejection)
    end)
    if not okPreview then logOnce("save-view-preview", "save preview unavailable: "..tostring(previewError)) end
  end
  if xrStatus then views = nil end -- never let a status string reach centerPose/hand code below
  S.slackWorld = world == true and r.xr.started == true -- Lab 51: SLACK and SKIP WINDOW PRESENT
  -- Lab 49: FLAT DRAW RATE may skip the next flat frame only after a frame
  -- that really showed the 3D field (no panel quad, no battle, session live)
  S.flatWorld = world == true and want3d == true and not battle3d and r.xr.started == true
  -- Lab 60: `loading screen show/hide reason=...` (one line per change; the hold itself logs its start and its collect)
  if LoadingGate and S.loading then
    local lg = S.loadGate
    if not lg then lg = {}; S.loadGate = lg end
    local shownNow = holding == true or S.loadShownFrame == frame
    if shownNow ~= (lg.shown == true) then
      local why = LoadingGate.transition(lg, shownNow, holding and S.loading.startWhy or "building", S.loading.endWhy)
      if why then log(why) end
    end
  end
  if collector then
    r.pacer:collectorAfterFrame(world==true and r.xr.started==true and fieldPhase(game) and not menuOpen() and not battle3d,
      r.scene,r.scene and r.scene.rootId,xrStatus~=nil or r.xr.started~=true,mr)
  end
  -- questFrame only reaches this point while the session was started; if
  -- r.xr:frame{} just stopped it (the "session-lost" branch calls
  -- XRSession:stop internally), this is the ONE frame that can observe
  -- that transition, so it is the one frame responsible for reporting it --
  -- nothing else ever does, and a held VRITK prop otherwise survives a lost
  -- session indefinitely.
  if not r.xr.started then
    r.hostApi:notifySessionStopped(xrStatus or "session-lost")
    r.hostApi.lossReported = true
  end
  -- Keeps vrHost.input.snapshot()/state().menuOpen/state().field live on
  -- every questFrame call, not only the ones where the renderEyes closure
  -- above actually ran beginFrame (panel-only frames, lost-session frames,
  -- and menu/unfocused frames all skip it, and previously left these three
  -- fields frozen at whatever the last WORLD frame set).
  r.hostApi.lastControls, r.hostApi.menuOpen, r.hostApi.field = controls, open == true, field == true
  r.hostApi.battle = battle3d == true -- W6

  r.hostApi:setWorldActive(world == true, reason or xrStatus) -- W4 / CRITIQUE #8, review fix #7
  if want3d and not world and reason then
    if reason ~= "building" then
      S.renderFails = S.renderFails + 1
      logOnce("stereo:" .. tostring(reason), "stereo frame fell back to the panel: " .. tostring(reason))
      if tostring(reason):find("render error", 1, true) then
        S.renderErrors = S.renderErrors + 1
        if S.renderErrors >= 20 then fail("stereo", reason) end
      end
      if S.renderFails >= 90 then fail("stereo", reason) end
    end
  elseif world then
    S.renderFails = 0
  end
  -- logcat timing line every 300 headset frames (CPU submit time only)
  local p = S.perf
  if not p then p = { n = 0, world = 0, ms = 0, max = 0, t0 = clock() }; S.perf = p end
  p.n = p.n + 1
  if world then p.world = p.world + 1 end
  if renderMs then p.ms = p.ms + renderMs; p.max = math.max(p.max, renderMs) end
  if p.n >= 300 then
    local st = r.scene:stats()
    log(("timing n=%d fps=%.1f world=%d eyes-cpu avg=%.1fms max=%.1fms root=%s maps=%d drawnTris=%d drawCalls=%d visibleMaps=%d state=%s")
      :format(p.n, p.n / math.max(0.001, clock() - p.t0), p.world, p.ms / math.max(1, p.world),
        p.max, tostring(st.root), st.maps or 0, math.floor(st.drawnTris or 0), math.floor(st.drawCalls or 0),
        st.visibleMaps or 0, tostring(r.xr.state)))
    S.perf = nil
  end
  local lookYaw = nil
  if world and views then
    local pose = center or centerPose(views)
    if r.camera.mode == "overview" then
      lookYaw = nil -- north-up table-top model: the stick is absolute
    elseif r.camera.follow and r.camera.mode == "first" then
      lookYaw = r.camera.yaw
    else
      lookYaw = r.camera:worldLookYaw(pose)
    end
  end
  local menuOrPanel = open or not world
  local suppress = r.hostApi:suppressMask(controls, (handsMenu or not world) and true or false) -- W4; W6 r2: battle hands
  local tabletMod=world and findMod('VRITK_FRLG_HOST');local tablet=tabletMod and tabletMod.exports and tabletMod.exports.compat and tabletMod.exports.compat.tablet;if tablet then tablet.suppress(suppress,controls)end
  -- Lab 50: may the next flat frame be skipped as far as the Gear watch and
  -- tablet go? Only on a shown 3D field frame; read after this frame's layer
  -- update (Gen3TabletCompat state) with this frame's controls and head.
  -- Fail-closed: anything unknown -> false -> the next frame draws.
  if flat and S.flatWorld then
    local wi = S.wearInfo -- reused: no per-frame table or closure
    wi.gear, wi.tablet, wi.controls, wi.head = gearLoaded, tablet, controls, center
    if wi.head == nil and views and views[1] then
      local okC, c = pcall(centerPose, views)
      wi.head = okC and c or nil
    end
    local okW, away = pcall(FlatRate.wearStep, S.wear, wi, clock())
    wi.tablet, wi.controls, wi.head = nil, nil, nil
    S.wearAway = okW and away == true
    if not okW then S.wear.errors = (S.wear.errors or 0) + 1 end
  end
  local companion=findMod('VR_INTERACTIONS_BACKPACK_LAB')
  local editor=companion and companion.exports and companion.exports.gearAdjustment
  local gearEditing=editor and editor.active and editor.active()
  if gearEditing or prepShow then -- Lab 59: the prepare screen takes no game input (B skips it, read by PrepareHost)
    r.input:releaseAll()
    return -- includes both-click confirm and the release latch; no walk/turn/toggle
  end
  local actions = r.input:apply(controls, { lookYaw = lookYaw, menuOpen = menuOrPanel, suppress = suppress,
    faceLook = r.camera.mode == "first", -- Lab 8: an idle first-person trainer faces the look
    battleWalk = bp ~= nil and bp:walkOwnsStick() or false }) -- battle-move
  if actions.toggle then
    S.voxelOn = not S.voxelOn
    log("voxel view " .. (S.voxelOn and "ON" or "OFF (flat panel)") .. " by controller")
    if not S.voxelOn then r.hostApi:invalidateNow("toggle-off") end -- W4 / CRITIQUE #8
    if r.battle then r.battle:notifyReset("toggle") end -- W6: re-pin the seat to the head
  end
  -- W6: turning is ignored while seated in a battle. Lab 8: SMOOTH (default)
  -- or SNAP per the VOXEL TURN option (Camera:turnInput)
  if world and r.camera.mode ~= "overview" and not r.camera.seat then
    r.camera:turnInput(actions, dt)
  end
  if world and bp and bp:moveActive() then pcall(bp.moveInput, bp, controls, actions, dt, suppress) end
end

-- Lab 51: after EVERY Quest frame (also an error, an early return or a non-game
-- frame): SLACK gives the collector back unless this frame submitted the stereo
-- world, and the engine may skip the hidden window's present only after one.
local function afterQuestFrame()
  local world = S.slackWorld == true
  presentGate.stereo = world and presentGate.enabled
  local reg = outerLoop()
  presentGate.iteration = reg and tonumber(rawget(reg, "loopIteration")) or nil -- the engine honours this iteration only
  local r = R
  if r and r.pacer then pcall(r.pacer.slackAfterFrame, r.pacer, world) end
end

mod.events:on("render.frame_drawn", function(payload)
  local frame = S.frame
  -- If the native plane compositor failed, Game3 used its stock flat fallback
  -- and never called render.compose. Repaint only the retained loading screen;
  -- all cache work still waits until a later frame after this final paint.
  local game = currentGame()
  if payload and payload.kind == "game" and bootPrepare and bootPrepare:needsComposite(game,frame) then
    local state = graphicsState()
    local ok,why = pcall(bootPrepare.composeCurrent,bootPrepare,game,
      love.graphics.getWidth(),love.graphics.getHeight(),frame)
    if not ok then unwind(state); fail("boot-compose",why) end
  end
  S.frame = S.frame + 1
  if not S.android then return end
  S.flatWorld = false -- Lab 49: set again by questFrame only on a shown 3D field frame
  S.wearAway = false -- Lab 50: likewise, set again only by a completed wearable check
  S.slackWorld = false -- Lab 51: likewise, set again only after a submitted stereo world frame
  presentGate.stereo = false
  if not (payload and payload.kind == "game") then afterQuestFrame(); return end
  local state = graphicsState()
  local ok, err = pcall(questFrame, frame)
  if saveView then saveView:setInXR(false) end
  if not ok then
    S.slackWorld = false
    unwind(state)
    fail("quest-frame", err)
    -- keep the headset alive: submit a panel-only frame next time around
  end
  afterQuestFrame()
end)

-- ------------------------------------------------------------ events/hooks
-- Wrap the game's own ways back to the launcher (review item 2). These run
-- during update, outside any XR frame. On Quest, once the native launcher
-- has handed its OpenXR session to this mod, nothing in-process can give it
-- back, so EXIT relaunches the process instead (HostShell.restart ->
-- love.system.restartApp, the engine's own crash-free Android restart);
-- the fresh process starts in the native launcher (review item 2c).
local function installExitWrappers(game)
  if type(game) ~= "table" or rawget(game, "_frlgVoxelExitWrapped") then return end
  local toLauncher = game.returnToLauncher
  if type(toLauncher) == "function" then
    game.returnToLauncher = function(...)
      local handedOver = S.handedOver
      teardown("return-to-launcher")
      if S.android and handedOver then
        local HostShell = engine("src.core.HostShell")
        if HostShell and HostShell.restart then
          log("return to launcher: restarting the app to restore the launcher's OpenXR session")
          local okR, errR = pcall(HostShell.restart)
          if okR then return end
          log("app restart failed, returning in-process: " .. tostring(errR))
        end
      end
      return toLauncher(...)
    end
  end
  local onExit = game.onExit
  if type(onExit) == "function" then
    game.onExit = function(...)
      teardown("on-exit")
      return onExit(...)
    end
  end
  rawset(game, "_frlgVoxelExitWrapped", true)
end
mod.exports._installExitWrappers = installExitWrappers

mod.events:on("game.ready", function(payload)
  S.game = payload and payload.game or S.game
  if VrControls then -- Lab 7: the old VOXEL TURN value becomes TURN MODE + SNAP ANGLE, once
    local okM, errM = pcall(VrControls.migrate, { id = mod.id }, S.game)
    if not okM then log("turn option migration failed: " .. tostring(errM)) end
    local okD, errD = pcall(VrControls.migrateDisplay, { id = mod.id }, S.game) -- VR DISPLAY: quality -> rows, once
    if not okD then log("display option migration failed: " .. tostring(errD)) end
    local okT, errT = pcall(VrControls.migrateTrees, { id = mod.id }, S.game)
    if not okT then log("tree option migration failed: " .. tostring(errT)) end
  end

  local okW, errW = pcall(installExitWrappers, payload and payload.game)
  if not okW then log("exit wrappers not installed: " .. tostring(errW)) end
  log(("ready: %s, voxel view %s, camera %s"):format(S.android and "Quest/Android" or "desktop",
    S.voxelOn and "ON" or "OFF", tostring(opt("camera") or "first")))
end)

-- Engine: emitted by returnToLauncher before mod Runtime is reset (engine
-- commit, review item 2b) -- the last moment this mod can still act.
mod.events:on("core.session_ending", function()
  teardown("session-ending")
end)

-- Mod manager changes apply live (review item 9). VOXEL VIEW only switches
-- the view: the running VR session is never abandoned mid-play.
mod.events:on("mod.options_changed", function(p)
  if type(p) ~= "table" or p.mod ~= mod.id then return end
  local ok, err = pcall(function()
    if p.key == "mouse_keyboard" then
      mouseStep()
    elseif p.key == "fr_grass_shape" and R then
      R.scene:setRetroShape(p.value)
    elseif p.key == "fr_trees" then
      V.require("render/FrlgVoxelTrees").setLowQuality(p.value == "voxel_low")
      if R then R.scene:setVoxelTrees(p.value == "voxel" or p.value == "voxel_low") end
    elseif p.key == "voxel_view" then
      S.voxelOn = p.value ~= false
    elseif p.key == "movement" then -- Lab 8
      if FreeMove then FreeMove.setEnabled(p.value ~= "grid") end
    elseif (p.key == "turn_mode" or p.key == "snap_angle" or p.key == "turn_speed") and R then -- Lab 8 / Lab 7
      R.camera:setTurn(p.key == "turn_mode" and p.value or nil, p.key == "turn_speed" and p.value or nil,
        p.key == "snap_angle" and p.value or nil)
    elseif p.key == "walk_speed" then -- Lab 7
      if FreeMove then FreeMove.setWalkSpeed(p.value) end
    elseif p.key == "room_scale" then -- Lab 7
      if FreeMove then FreeMove.setRoomEnabled(p.value ~= false) end
    elseif (p.key == "eye_res" or p.key == "refresh_rate" or p.key == "foveation") and R and VrControls then -- VR DISPLAY
      R.xr:applyDisplay(VrControls.resolveDisplay(opt, nil))
    elseif p.key == "quality" and VrControls and p.value ~= nil then -- the old profile choice now sets the rows
      VrControls.applyLegacyQuality({ id = mod.id }, S.game, p.value)
    elseif p.key == "perf_flat_rate" then -- Lab 49
      if flat then log("flat draw rate 1/" .. tostring(flat:setRate(p.value))) end
    elseif p.key == "perf_gc_step" then -- Lab 51: at once, not at the next option poll
      if R and R.pacer then R.pacer:setGcMode(p.value) end
    elseif p.key == "perf_skip_present" then -- Lab 51
      presentGate.enabled = S.android == true and p.value ~= false
      if not presentGate.enabled then presentGate.stereo = false end
      log("skip window present " .. (presentGate.enabled and "ON" or "OFF"))
    elseif p.key == "perf_alloc_trim" then -- Lab 51
      pushAllocTrim()
      log("alloc trim " .. (S.allocTrim and "ON" or "OFF"))
    elseif p.key == "perf_catch_beam_fast" then -- Lab 50
      pushCatchBeam()
      log("catch beam fast " .. (S.catchBeamFast and "ON" or "OFF"))
    elseif p.key == "perf_world_cache_clear" then -- Lab 57: a momentary row; it puts itself back to NO
      if p.value == "clear" then
        local pc = getWorldCache()
        local n = pc and pc:clear() or 0
        log("world cache cleared (" .. tostring(n) .. " records)")
        if VrControls then VrControls.write({ id = mod.id }, S.game, "perf_world_cache_clear", "no") end
      end
    elseif OutdoorPerf.KEYS[p.key] or p.key == "perf_world_cache" or p.key == "perf_loading_screen" or p.key == "perf_speed58"
        or p.key == "perf_precache_first_load" then -- Lab 55 (+ Lab 57)
      local field = OutdoorPerf.apply(p.key, p.value)
      if field == "weather" or field == "weatherTier" or field == "sunShadows" then pushWeather() end
      if R and R.scene and type(R.scene.outdoorPerfChanged) == "function" then
        pcall(R.scene.outdoorPerfChanged, R.scene, field)
      end
      log("outdoor perf " .. tostring(field) .. " = " .. tostring(OutdoorPerf[field]))
      if (field == "precacheFirstLoad" or field == "worldCache") and prepareHost then -- Lab 59
        if OutdoorPerf[field] ~= false then prepareHost:rearm() -- switched ON again: look at the cache again
        else prepareHost:switchedOff(R) end -- switched OFF: a running precache stops now
      end
    elseif p.key == "perf_xr_hints" then -- Lab 51: read when the VR session starts
      if R and R.xr then R.xr:configure({ hints = p.value ~= false }) end
      log("XR thread hints " .. (p.value ~= false and "ON" or "OFF") .. " (from the next VR session start)")
    elseif p.key == "battle_move" then -- battle-move
      if R and R.battle then R.battle:setMoveEnabled(p.value ~= false) end
    elseif p.key == "camera" and R then
      applyCameraMode(R, p.value, false) -- W4 / CRITIQUE #8, review fix #4
    elseif p.key == "shadows" and R then
      R.view:setShadows(p.value ~= false)
    elseif p.key == "view34_angle" and R then   -- W2 (cam34)
      R.camera:setOverview(p.value, nil)
    elseif p.key == "view34_zoom" and R then    -- W2 (cam34)
      R.camera:setOverview(nil, p.value)
    end
  end)
  if not ok then log("option change not applied: " .. tostring(err)) end
end)

mod.events:on("map.entered", function(payload)
  if payload and payload.mapId then
    log("map entered " .. tostring(payload.mapId) .. " via " .. tostring(payload.via))
  end
end)

-- Desktop hotkeys: F7 voxel view, F8 camera, F9 stereo preview.
local mouseToggleHeld = false
mod.hooks:wrap("input.key", function(nextFn, game, ev)
  if S.android then return nextFn() end
  if ev and ev.key == "f6" then
    if ev.phase == "released" then mouseToggleHeld = false end
    if ev.phase == "pressed" and not mouseToggleHeld then
      mouseToggleHeld = true
      local enabled = opt("mouse_keyboard") ~= true
      local ok = VrControls and VrControls.write({id = mod.id}, game, "mouse_keyboard", enabled)
      if not ok then log("Change MOUSE & KEYBOARD in the Mods options") end
      mouseStep()
    end
    return
  end
  mouseStep()
  if mouseControls:key(ev) then return end
  if ev and ev.phase == "pressed" and not S.android then
    if ev.key == "f7" then
      S.voxelOn = not S.voxelOn
      mouseStep()
      log("voxel view " .. (S.voxelOn and "ON" or "OFF"))
      return
    elseif ev.key == "f8" then
      local r = ensureRenderer()
      applyCameraMode(r, nil, true) -- W4 review fix #4
      log("camera " .. r.camera.mode)
      return
    elseif ev.key == "f9" then
      S.preview = S.preview == "sbs" and "mono" or "sbs"
      log("desktop preview " .. S.preview)
      return
    end
  end
  return nextFn()
end, 40)

mod.hooks:wrap("core.quit_to_launcher", function(nextFn)
  pcall(teardown, "quit-to-launcher")
  return nextFn()
end)

-- ------------------------------------------------------------ exports
-- Diagnostics / driver seam (plain data in and out).
local function saveViewContext(game)
  local current = currentGame()
  local session = game and game.session
  -- FreeMove pre-save repairs session floor(px/16) drift to the logical cell.
  -- Match the actual unmoved body, not that mutable serialization mirror.
  local player = engine("src.core.game3.player")
  local context = session and { game=game, session=session, map=session.map,
    x=player and player.cellX or session.x, y=player and player.cellY or session.y,
    px=player and player.px, py=player and player.py } or nil
  local eligible = session and game==current and fieldPhase(game) and R and R.view and R.view.prepared
    and R.scene and R.scene.rootId==session.map and R.xr and R.xr.started and not S.failed
  local rejection
  if eligible and R.view.fieldTransition then
    local ok, veil = pcall(R.view.fieldTransition.veil,R.view.fieldTransition,nil)
    if not ok or (veil and (veil[4] or 0)>0) then
      eligible=false;rejection=not ok and "ctx-transition-error" or "ctx-transition-active"
    end
  end
  -- Diagnostic enums only: preserve the existing eligibility result above.
  if not eligible and not rejection then
    if not game then rejection="ctx-no-game"
    elseif not session then rejection="ctx-no-session"
    elseif game~=current then rejection="ctx-game-mismatch"
    elseif game.phase~="field" then rejection="ctx-not-field"
    else
      local Runtime=engine("src.core.game3.runtime")
      local T=engine("src.core.game3.battle_transition")
      if not(Runtime and Runtime.isActive and Runtime.isActive())then rejection="ctx-runtime-inactive"
      elseif T and T.isActive and T.isActive()then rejection="ctx-battle-transition"
      elseif not(R and R.view)then rejection="ctx-renderer"
      elseif not R.view.prepared then rejection="ctx-not-prepared"
      elseif not(R.scene and R.scene.rootId==session.map)then rejection="ctx-root"
      elseif not(R.xr and R.xr.started)then rejection="ctx-xr-inactive"
      elseif S.failed then rejection="ctx-host-failed"
      else rejection="frame-ineligible"end
    end
  end
  return context, eligible==true, rejection
end
saveView = V.require("quest/SaveViewCapture").new({
  context=saveViewContext,
  capture=function(eye,w,h)
    if not (R and R.hostApi) then return nil end
    return R.hostApi:renderCameraView(eye,w,h,{})
  end,
  copy=function(source)
    local g=love.graphics
    local state=graphicsState()
    local canvas
    local ok,err=pcall(function()
      canvas=g.newCanvas(384,256,{format="rgba8",readable=true,msaa=0,dpiscale=1})
      g.push("all");g.setCanvas(canvas);g.origin();g.setShader();g.setColor(1,1,1,1)
      g.setDepthMode();g.setScissor();g.setStencilTest();g.setColorMask(true,true,true,true)
      g.setBlendMode("replace","premultiplied");g.clear(0,0,0,1)
      g.draw(source,0,0,0,384/source:getWidth(),256/source:getHeight())
    end)
    unwind(state)
    if not ok then if canvas then pcall(canvas.release,canvas)end;error(err,0)end
    return canvas
  end,
})
mod.exports.saveView={
  arm=function(game,attemptId)return saveView:arm(game,attemptId)end,
  take=function(token)return saveView:take(token)end,
  release=function(token)return saveView:release(token)end,
}
mod.exports.active = true
mod.exports.status = function()
  local st = {
    active = true, android = S.android, voxelOn = S.voxelOn, bootEnabled = S.bootEnabled,
    failed = S.failed, frame = S.frame, preview = S.preview,
  }
  if R then
    st.scene = R.scene:stats()
    st.camera = { mode = R.camera.mode, follow = R.camera.follow, x = R.camera.x,
                  y = R.camera.y, z = R.camera.z, yaw = R.camera.yaw }
    st.eye = { calls = R.view.eyeCalls, tris = R.view.eyeTris, visibleMaps = R.view.visibleMaps,
               shadows = R.view.shadows, mips = R.view.mips, haze = R.view.haze,
               fog = R.view.fog }
    st.xr = { started = R.xr.started, state = R.xr.state, frames = R.xr.frames,
              worldFrames = R.xr.worldFrames }
    st.billboards = R.billboards.count
    st.blobs = R.billboards.blobCount -- W6
    st.battle = R.battle and R.battle.state or nil -- W6
    st.camera.seat = R.camera.seat ~= nil -- W6
    st.camera.turnStyle, st.camera.turnSpeed = R.camera.turnStyle, R.camera.turnSpeed -- Lab 8
    st.camera.snapDeg = R.camera.snapDeg
  end
  local scene=R and R.scene;local grass=scene and scene.retroGrass
  st.grass={enabled=grass~=nil,shape=grass and grass.shape or opt("fr_grass_shape"),ground=grass and grass.ground or initialGrassGround,cells=0,instanced=grass and grass.instanced or false,drawCalls=scene and scene.grassDrawCalls or 0,motionTris=scene and scene.grassMotionTris or 0,motionStrength=0,inflight=0,queuedShapeJobs=0}
  if grass then
    local u=grass.motion:uniforms();st.grass.motionStrength=u.velocity[4] or 0
    for i=4,16,4 do st.grass.motionStrength=math.max(st.grass.motionStrength,u.positions[i] or 0) end
    for _,rec in ipairs(scene.visible or {})do st.grass.cells=st.grass.cells+#(rec.retroGrassCells or {})end
    for _ in pairs(scene.inflight)do st.grass.inflight=st.grass.inflight+1 end
    for _,job in ipairs(scene.queue)do if job.retroShape then st.grass.queuedShapeJobs=st.grass.queuedShapeJobs+1 end end
    if scene.active and scene.active.job.retroShape then st.grass.queuedShapeJobs=st.grass.queuedShapeJobs+1 end
  end
  st.freeMove = FreeMove and FreeMove.status() or nil -- Lab 8 (plain data)
  st.flatRate = flat and { rate = flat.rate, drawn = flat.totalDrawn, skipped = flat.totalSkipped, -- Lab 49
    wearAway = S.wearAway, wearWhy = S.wear.why, wearVisibleFrames = S.wear.visibleFrames or 0, wearErrors = S.wear.errors or 0 } or nil -- Lab 50
  return st
end
-- W6 (battle P-B1): diagnostics / driver seam for the 3D battle presenter
-- (plain data; vrHost.battle.state() returns the same status).
mod.exports.battle = {
  status = function() return R and R.battle and R.battle:status() or nil end,
  setForceNoArena = function(on) if R and R.battle then R.battle:setForceNoArena(on) end end,
  setForceError = function(kind) if R and R.battle then R.battle:setForceError(kind) end end,
  setDebugView = function(kind) if R and R.battle then R.battle:setDebugView(kind) end end,
  pass = function() return R and R.battle or nil end, -- W6 r2: desktop driver inspection only
}
mod.exports.grassCells=function(limit)
  limit=math.max(0,math.min(128,math.floor(tonumber(limit) or 128)))
  local scene=R and R.scene;local out={rootMap=scene and scene.rootId,cells={}}
  if scene then for _,rec in ipairs(scene.visible or {})do for _,c in ipairs(rec.retroGrassCells or {})do
    if #out.cells>=limit then return out end
    out.cells[#out.cells+1]={x=c.x+.5+(rec.ox or 0),y=c.y,z=c.z+.5+(rec.oz or 0),kind=c.kind,mapId=rec.key,localX=c.x,localZ=c.z}
  end end end
  return out
end
-- Lab 58 approach loading (A3): the seam for VRITK_FRLG_HOST's ApproachLoader (called through mod.find + pcall).
-- warmArtRows(gid | sprite, budgetRows) runs the Billboards.artRows scan of an ALREADY LOADED sheet, at most
-- budgetRows pixel rows per call (nil = all): true = rows cached, false = call again, nil + reason = sheet not loaded.
-- isCardWarm(gid) = sheet resident and art rows cached (the condition for a neighbour ghost card). Loads nothing.
mod.exports.warmArtRows = function(spriteOrGid, budgetRows)
  local okB, BB = pcall(V.require, "render/Billboards")
  if not (okB and type(BB) == "table") then return nil, "no Billboards" end
  if type(spriteOrGid) == "table" then return BB.warmArtRows(spriteOrGid, budgetRows) end
  return BB.warmGid(spriteOrGid, budgetRows)
end
mod.exports.isCardWarm = function(gid)
  local okB, BB = pcall(V.require, "render/Billboards")
  return okB and type(BB) == "table" and BB.cardWarm(gid) == true
end
mod.exports.setVoxel = function(on) S.voxelOn = on and true or false end
mod.exports.beltSwitch = function() return opt("belt_switch") ~= false end
mod.exports.teardown = function(reason) return teardown(reason or "export") end
-- Lab 59: test / driver access to the PRECACHE ON FIRST LOAD driver (desktop LOVE drivers step it themselves)
mod.exports.prepare = {
  host = function() return getPrepareHost() end,
  driver = function() local h = getPrepareHost(); return h and h:ensure(ensureRenderer()) or nil end,
  status = function() local h = getPrepareHost(); return h and h:status() or nil end,
}
-- test seam: the review item 1 backstop (plain functions, no engine handles)
mod.exports._graphicsGuard = { state = graphicsState, unwind = unwind }
mod.exports.setEffects = function(fx)
  local r = ensureRenderer()
  if type(fx) ~= "table" then return end
  if fx.shadows ~= nil then r.view:setShadows(fx.shadows and true or false) end
  if fx.mips ~= nil then r.view.mips = fx.mips and true or false end
  if fx.haze ~= nil then r.view.haze = fx.haze and true or false end
end
-- Diagnostics: the root map's shadow mask ImageData (nil if none).
mod.exports.debugShadowMask = function(key)
  if not R then return nil end
  local rec = R.scene:record(key or R.scene.rootId)
  return rec and rec.shadowData or nil
end
mod.exports.setPreview = function(kind) S.preview = kind == "sbs" and "sbs" or "mono" end
mod.exports.setCamera = function(mode)
  local r = ensureRenderer()
  applyCameraMode(r, mode, false) -- W4 review fix #4
end

log(("loaded %s (%s)"):format(tostring(mod.version), S.android and "Quest/Android" or "desktop"))

-- Compatibility belongs to this mod and starts even when no legacy shim exists.
-- Native host services, hooks and events retain FRLG_VOXEL ownership.
do
 local ok,why=pcall(function()return V.require('compat/LegacyBridge').start(V)end)
 if not ok then logOnce('compat-start','compatibility startup failed: '..tostring(why))end
end


