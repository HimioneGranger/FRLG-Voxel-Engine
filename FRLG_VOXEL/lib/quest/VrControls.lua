-- FRLG_VOXEL: the VR CONTROLS page on the Gen 3 OPTION screen (Lab 7, user answers
-- 2026-10-01): TURN MODE, SNAP ANGLE, SMOOTH SPEED, WALK SPEED, ROOM-SCALE WALK and (battle-move)
-- BATTLE MOVE; and, right after it, the VR DISPLAY page (battle-move part B): RESOLUTION, REFRESH,
-- FOVEATION and a read-only line saying whether a change applies now or after a restart.
--
-- The FireRed and Emerald OPTION screens never raise ui.options.rows, so FRLG_VOXEL's
-- own options were only reachable through OPTION > MODS > mod page > OPTIONS. Both
-- screens (src/ui/game3/option_menu.lua, src/ui/game3/rse/option_menu.lua) build the
-- top page with option_rows.lua's Rows.build(ctx) and Rows.group(rows, openPage), and
-- Rows.group lists the ids named in Rows.ORDER first. The same seam the belt rows
-- (VR_INTERACTIONS_BACKPACK_LAB lib/Gen3OptionRows.lua) and Dialogue Portraits use:
--   * wrap Rows.build and append the five rows,
--   * add one Rows.GROUPS entry ("VR CONTROLS", members = those rows),
--   * name the group in Rows.ORDER, right after the two belt rows when they are there.
-- Every value is written through the mod's real option writer (ManagerState:setOption,
-- as the belt module does), so the Mods page, the saved options file and the live
-- mod.options_changed handlers in main.lua all see the same value.
--
-- Also here, pure and testable: resolveTurn (the effective turn settings, honouring the
-- old VOXEL TURN value) and migrate (one-time: the old single turn_style choice becomes
-- turn_mode + snap_angle). Loaded only on Gen 3 (main.lua is Gen 3 only); removable:
-- uninstall(Rows) puts Rows.ORDER / Rows.GROUPS back and turns the wrapper inert.
local V = ...
local _ = V

local M = {}

M.GROUP = { id = "group.vrcontrols", label = "VR CONTROLS" }

-- One list drives the rows, the migration and the tests. Labels are short on purpose:
-- the OPTION screen gives a label about 12 characters before the value column.
M.SPECS = {
  {id="frlgvoxel:battle-aim",key="battle_aim",label="AIM CUE",kind="toggle",default=true},
  {id="frlgvoxel:belt-locked",key="belt_locked",label="BELT LOCK",kind="toggle",default=true},
  {id="frlgvoxel:throw-strength",key="throw_strength",label="THROW POWER",kind="choice",
    choices={{"NORMAL","normal"},{"ASSISTED","assisted"}},default="assisted"},

  { id = "frlgvoxel:turn-mode", key = "turn_mode", label = "TURN MODE", kind = "choice",
    choices = { { "SNAP", "snap" }, { "SMOOTH", "smooth" } }, default = "snap" },
  { id = "frlgvoxel:snap-angle", key = "snap_angle", label = "SNAP ANGLE", kind = "number",
    min = 15, max = 90, step = 15, default = 30, suffix = " DEG" },
  { id = "frlgvoxel:turn-speed", key = "turn_speed", label = "SMOOTH SPEED", kind = "number",
    min = 30, max = 180, step = 15, default = 90, suffix = " DEG/S" },
  { id = "frlgvoxel:walk-speed", key = "walk_speed", label = "WALK SPEED", kind = "number",
    min = 50, max = 100, step = 5, default = 75, suffix = "%" },
  { id = "frlgvoxel:room-scale", key = "room_scale", label = "ROOM-SCALE WALK", kind = "toggle",
    default = true },
  -- battle-move (user 2026-10-01: "I want movement in battle now."), default ON. The label stays short:
  -- the OPTION screen gives a label about 12 characters before the value column.
  { id = "frlgvoxel:battle-move", key = "battle_move", label = "BATTLE MOVE", kind = "toggle",
    default = true },
  -- belt-switch (user 2026-10-02: "I want you to have to recall your Pokemon to your party belt and physically
  -- switch in new Pokemon from your belt"), default ON. VRITK_FRLG_HOST compat/Gen3BeltSwitch reads it through
  -- FRLG_VOXEL's exports.beltSwitch(); OFF = the engine's own switch presentation, as before.
  { id = "frlgvoxel:belt-switch", key = "belt_switch", label = "BELT SWITCH", kind = "toggle",
    default = true },
}

-- VR DISPLAY (battle-move part B, user 2026-10-01: "There is no resolution setting and I feel like we are
-- stuck on a lower res."). RESOLUTION is the eye image size in percent of the runtime's recommended size:
-- up to 100% it is the OpenXR swapchain (fixed when the session starts: the engine adapter and the native
-- binding both refuse more than 1.0); above 100% the mod draws its eye canvases larger and the blit into the
-- swapchain shrinks them (supersampling; costs frame rate; live). REFRESH is requested from the headset
-- (live); 120 appears only when the runtime lists it. FOVEATION: the binding has ON (the native MEDIUM level)
-- and OFF only. The old `quality` profile choice stays readable and is carried over once (migrateDisplay).
M.DISPLAY_GROUP = { id = "group.vrdisplay", label = "VR DISPLAY" }
M.REFRESH_BASE = { 72, 80, 90 }
M.DISPLAY_SPECS = {
  { id = "frlgvoxel:eye-res", key = "eye_res", label = "RESOLUTION", kind = "number",
    min = 70, max = 130, step = 10, default = 100, suffix = "%" },
  { id = "frlgvoxel:refresh", key = "refresh_rate", label = "REFRESH", kind = "choice",
    dynamic = "refresh", default = 72 },
  { id = "frlgvoxel:foveation", key = "foveation", label = "FOVEATION", kind = "toggle", default = true },
}
-- Keep diagnostics separate from display quality. Both fit without pagination
-- and use the same persisted option writer as the Mods page.
M.PERF_GROUP = { id = "group.vrperf", label = "VR PERFORMANCE" }
M.PERF_SPECS = {
  { id = "frlgvoxel:gc-pacing", key = "perf_gc_step", label = "GC PACING", kind = "choice",
    choices = { { "OFF", "0" }, { "0.5 MS", "0.5" }, { "1 MS", "1" }, { "SLACK", "slack" } }, default = "slack" },
  { id = "frlgvoxel:gc-test", key = "perf_gc_pause", label = "GC PAUSE TEST", kind = "toggle", default = false },
  { id = "frlgvoxel:gc-render-test", key = "perf_gc_render", label = "GC RENDER TEST", kind = "toggle", default = false },
  -- Lab 49 (lib/quest/FlatRate.lua): same key, choices and default as main.lua's schema
  { id = "frlgvoxel:flat-rate", key = "perf_flat_rate", label = "FLAT DRAW RATE", kind = "choice",
    choices = { { "EVERY FRAME", "1" }, { "HALF", "2" }, { "THIRD", "3" } }, default = "3" },
  -- Lab 51: same keys and defaults as main.lua's schema
  { id = "frlgvoxel:skip-present", key = "perf_skip_present", label = "SKIP PRESENT", kind = "toggle", default = true },
  { id = "frlgvoxel:alloc-trim", key = "perf_alloc_trim", label = "ALLOC TRIM", kind = "toggle", default = true },
  { id = "frlgvoxel:xr-hints", key = "perf_xr_hints", label = "XR HINTS", kind = "toggle", default = true },
}
-- Lab 55 (lib/render/OutdoorPerf.lua): same keys, choices and defaults as main.lua's schema. Two pages of
-- their own next to VR PERFORMANCE, which stays the Lab 51 one-page list: OUTDOOR LOOK = the look trades
-- (defaults are the fast settings), OUTDOOR SPEED = same-picture code switches.
M.LOOK_GROUP = { id = "group.vroutlook", label = "OUTDOOR LOOK" }
M.LOOK_SPECS = {
  { id = "frlgvoxel:weather-tier", key = "perf_weather_tier", label = "WEATHER DETAIL", kind = "choice",
    choices = { { "FULL", "full" }, { "LITE", "lite" }, { "OFF", "off" } }, default = "lite" },
  { id = "frlgvoxel:draw-range", key = "perf_draw_range", label = "DRAW RANGE", kind = "choice",
    choices = { { "FULL", "full" }, { "MEDIUM", "medium" }, { "NEAR", "near" } }, default = "medium" },
  { id = "frlgvoxel:far-masks", key = "perf_far_masks", label = "FAR SHADOWS", kind = "choice",
    choices = { { "FULL", "full" }, { "DEFER", "defer" }, { "OFF", "off" } }, default = "off" },
  { id = "frlgvoxel:sun-shadows", key = "perf_sun_shadows", label = "SUN SHADOWS", kind = "choice",
    choices = { { "MOVING", "moving" }, { "FIXED", "fixed" }, { "OFF", "off" } }, default = "fixed" },
}
M.LOOK_SPECS[#M.LOOK_SPECS+1]={id="frlgvoxel:voxel-trees",key="fr_trees",label="TREES",kind="choice",
 choices={{"CARDS","sheet"},{"VOXEL","voxel"},{"VOXEL LOW RES","voxel_low"}},default="sheet"}
M.SPEED_GROUP = { id = "group.vroutspeed", label = "OUTDOOR SPEED" }
M.SPEED_SPECS = {
  { id = "frlgvoxel:frame-hoist", key = "perf_frame_hoist", label = "FRAME HOIST", kind = "toggle", default = true },
  { id = "frlgvoxel:eye-scratch", key = "perf_eye_scratch", label = "EYE SCRATCH", kind = "toggle", default = true },
  { id = "frlgvoxel:grass-state", key = "perf_grass_state", label = "GRASS STATE", kind = "toggle", default = true },
  { id = "frlgvoxel:sea-once", key = "perf_sea_once", label = "SEA ONCE", kind = "toggle", default = true },
  { id = "frlgvoxel:weather-hoist", key = "perf_weather_hoist", label = "WEATHER HOIST", kind = "toggle", default = true },
  { id = "frlgvoxel:build-slice", key = "perf_build_slice", label = "BUILD SLICING", kind = "toggle", default = true },
  { id = "frlgvoxel:catch-beam-fast", key = "perf_catch_beam_fast", label = "CATCH BEAM FAST", kind = "toggle", default = true }, -- Lab 50
}
-- Lab 57 (lib/perf/FrPrecache*.lua): a small page of its own, so OUTDOOR SPEED keeps its seven rows (the
-- option pager shows seven). Same keys, choices and defaults as main.lua's schema; the size line is read-only.
M.WORLD_GROUP = { id = "group.vrworldcache", label = "WORLD LOADING" }
M.WORLD_SPECS = {
  { id = "frlgvoxel:world-cache", key = "perf_world_cache", label = "WORLD CACHE", kind = "toggle", default = true },
  { id = "frlgvoxel:world-cache-clear", key = "perf_world_cache_clear", label = "CLEAR CACHE", kind = "choice",
    choices = { { "NO", "no" }, { "CLEAR", "clear" } }, default = "no" },
  { id = "frlgvoxel:loading-screen", key = "perf_loading_screen", label = "LOADING SCREEN", kind = "toggle", default = true },
  -- Lab 58: OUTDOOR SPEED is full (seven rows), so SPEED PATCHES sits on this page, before the read-only size line
  { id = "frlgvoxel:speed-patches", key = "perf_speed58", label = "SPEED PATCHES", kind = "toggle", default = true },
  -- Lab 59 (lib/perf/FrPrepare.lua). The Mods page shows the full name PRECACHE ON FIRST LOAD; this OPTION row is
  -- shortened to fit the GBA option window (label column ~120 px).
  { id = "frlgvoxel:precache-first-load", key = "perf_precache_first_load", label = "PRECACHE 1ST LOAD", kind = "toggle", default = true },
}
local WORLD_SIZE_ID = "frlgvoxel:world-cache-size"
-- the old quality profiles as (resolution %, Hz); performance's 65% is under the new 70% floor
M.LEGACY_QUALITY = {
  performance = { 70, 72 }, balanced = { 80, 72 }, smooth90 = { 70, 90 }, quality = { 100, 72 },
}

local BY_KEY = {}
for _, spec in ipairs(M.SPECS) do BY_KEY[spec.key] = spec end
local DISPLAY_BY_KEY = {}
for _, spec in ipairs(M.DISPLAY_SPECS) do BY_KEY[spec.key] = spec; DISPLAY_BY_KEY[spec.key] = spec end
for _, spec in ipairs(M.PERF_SPECS) do BY_KEY[spec.key] = spec end
for _, spec in ipairs(M.LOOK_SPECS) do BY_KEY[spec.key] = spec end -- Lab 55
for _, spec in ipairs(M.SPEED_SPECS) do BY_KEY[spec.key] = spec end -- Lab 55
for _, spec in ipairs(M.WORLD_SPECS) do BY_KEY[spec.key] = spec end -- Lab 57
M.BY_KEY = BY_KEY
M.DISPLAY_BY_KEY = DISPLAY_BY_KEY

local function memberIds(specs)
  local ids = {}
  for i, spec in ipairs(specs or M.SPECS) do ids[i] = spec.id end
  return ids
end

local STATUS_ID = "frlgvoxel:display-apply"

local function isOurs(id)
  if id == M.GROUP.id or id == M.DISPLAY_GROUP.id or id == M.PERF_GROUP.id or id == STATUS_ID then return true end
  if id == M.LOOK_GROUP.id or id == M.SPEED_GROUP.id then return true end -- Lab 55
  if id == M.WORLD_GROUP.id or id == WORLD_SIZE_ID then return true end -- Lab 57
  for _, spec in ipairs(M.SPECS) do if spec.id == id then return true end end
  for _, spec in ipairs(M.DISPLAY_SPECS) do if spec.id == id then return true end end
  for _, spec in ipairs(M.PERF_SPECS) do if spec.id == id then return true end end
  for _, spec in ipairs(M.LOOK_SPECS) do if spec.id == id then return true end end -- Lab 55
  for _, spec in ipairs(M.SPEED_SPECS) do if spec.id == id then return true end end -- Lab 55
  for _, spec in ipairs(M.WORLD_SPECS) do if spec.id == id then return true end end -- Lab 57
  return false
end

-- ------------------------------------------------------------ values
local function clamp(v, spec)
  v = tonumber(v)
  if v == nil or v ~= v then return spec.default end
  return math.max(spec.min, math.min(spec.max, v))
end

-- A choice spec's list: static `choices`, or (dynamic = "refresh") the base rates plus 120 when the runtime
-- lists it, plus the stored value itself (so a stored 120 on a runtime that does not list it still shows).
local function choicesOf(spec, env, value)
  if spec.choices then return spec.choices end
  if spec.dynamic == "refresh" then
    local rates = {}
    local have = {}
    for _, r in ipairs(M.REFRESH_BASE) do rates[#rates + 1] = r; have[r] = true end
    local list = env and env.rates and env.rates() or nil
    if type(list) == "table" then
      for _, r in ipairs(list) do
        r = tonumber(r)
        if r and r >= 119 and r <= 121 and not have[120] then rates[#rates + 1] = 120; have[120] = true end
      end
    end
    local v = tonumber(value)
    if v and not have[v] then rates[#rates + 1] = v end
    table.sort(rates)
    local out = {}
    for i, r in ipairs(rates) do out[i] = { r .. " HZ", r } end
    return out
  end
  return {}
end
M.choicesOf = choicesOf

-- The current value of a spec through env.get(key) (the mod's real options).
local function current(env, spec)
  local v = env.get and env.get(spec.key)
  if v == nil then v = spec.default end
  if spec.kind == "number" then return clamp(v, spec) end
  if spec.kind == "toggle" then return v ~= false end
  for _, c in ipairs(choicesOf(spec, env, v)) do if c[2] == v then return v end end
  return spec.default
end
M.current = current

local function display(spec, value, env)
  if spec.kind == "toggle" then return value and "ON" or "OFF" end
  if spec.kind == "number" then return ("%d%s"):format(value, spec.suffix or "") end
  for _, c in ipairs(choicesOf(spec, env, value)) do if c[2] == value then return c[1] end end
  return "?"
end
M.display = display

-- The next value one step in `dir` (-1 / +1). Choices wrap, numbers stop at the ends
-- (as the Mods page does). -> new value, changed?
local function stepped(spec, value, dir, env)
  dir = (dir and dir < 0) and -1 or 1
  if spec.kind == "toggle" then return not value, true end
  if spec.kind == "number" then
    local nv = clamp(value + dir * spec.step, spec)
    return nv, nv ~= value
  end
  local choices = choicesOf(spec, env, value)
  local n = #choices
  local at = 1
  for i, c in ipairs(choices) do if c[2] == value then at = i end end
  local nv = choices[(at - 1 + dir) % n + 1][2]
  return nv, nv ~= value
end
M.stepped = stepped

-- ManagerState:setOption is the one writer (the Mods page uses it): it updates
-- loader.modOptions + save.options.modOptions, writes the options file and emits
-- mod.options_changed, which main.lua applies live.
local function write(env, game, key, value)
  local ok, Manager = pcall(require, "src.mods.ManagerState")
  if not (ok and type(Manager) == "table" and Manager.new and game and game.mods) then return false end
  local made, result = pcall(function() return Manager.new(game):setOption(env.id, key, value) end)
  return made and result ~= false
end
M.write = write

-- One-time migration of the retired separate low-detail toggle. Preserve
-- existing Cards/detailed choices and never override a new explicit mode.
function M.migrateTrees(env,game)
  local stored=game and game.mods and game.mods.modOptions and game.mods.modOptions[env.id]
  if type(stored)~="table" or stored.fr_tree_low==nil then return false end
  if stored.fr_trees=="voxel" and stored.fr_tree_low==true then
    if not write(env,game,"fr_trees","voxel_low") then return false end
  end
  return write(env,game,"fr_tree_low",nil)
end

local function buildRow(env, spec)
  return {
    id = spec.id, label = spec.label,
    value = function() return display(spec, current(env, spec), env) end,
    step = function(c, dir)
      local nv, changed = stepped(spec, current(env, spec), dir, env)
      if not changed then return false end
      return write(env, c and c.game, spec.key, nv)
    end,
  }
end

-- Lab 57: the read-only size line on the WORLD CACHE page (env.cacheInfo() -> { records, mb, capMb } | nil).
local function cacheSizeRow(env)
  return {
    id = WORLD_SIZE_ID, label = "SIZE",
    value = function()
      local ok, info = pcall(function() return env.cacheInfo and env.cacheInfo() end)
      if not ok or type(info) ~= "table" then return "N/A" end
      return ("%d / %d MB  %d MAPS"):format(math.floor(info.mb + 0.5), math.floor(info.capMb + 0.5), info.records)
    end,
    step = function() return false end,
  }
end

-- The read-only line on the VR DISPLAY page: does the setting apply now or after a restart?
local function statusRow(env)
  return {
    id = STATUS_ID, label = "APPLIES",
    value = function()
      local pending = env.pending and env.pending()
      return pending and "AFTER RESTART" or "NOW"
    end,
    step = function() return false end,
  }
end

-- ------------------------------------------------------------ display settings
-- The effective VR DISPLAY: { res (70-130), swapScale (0.5-1.0), renderScale (>= 1), refreshRate (Hz),
-- foveation (bool), legacy (true when it came from an unmigrated quality profile) }. get(key) is the mod's
-- option getter; stored = the mod's stored option table (nil = unknown): while none of the three new keys was
-- ever stored and an old quality profile was, the profile wins (until migrateDisplay has run).
function M.resolveDisplay(get, stored)
  local res = clamp(get("eye_res"), DISPLAY_BY_KEY.eye_res)
  local hz = tonumber(get("refresh_rate")) or DISPLAY_BY_KEY.refresh_rate.default
  hz = math.max(60, math.min(144, hz))
  local legacy = false
  if type(stored) == "table" and stored.quality ~= nil and stored.eye_res == nil
      and stored.refresh_rate == nil and stored.foveation == nil then
    local p = M.LEGACY_QUALITY[stored.quality]
    if p then res, hz, legacy = p[1], p[2], true end
  end
  return { res = res, swapScale = math.min(res, 100) / 100, renderScale = math.max(res, 100) / 100,
    refreshRate = hz, foveation = get("foveation") ~= false, legacy = legacy }
end

-- One-time (game.ready): an explicitly chosen old quality profile becomes RESOLUTION + REFRESH through the
-- real writer. The quality key itself stays stored (readable). Only when none of the new keys was ever set.
-- -> true when something was written.
function M.migrateDisplay(env, game)
  local modOptions = game and game.mods and game.mods.modOptions
  local stored = modOptions and modOptions[env.id]
  if type(stored) ~= "table" or stored.quality == nil then return false end
  if stored.eye_res ~= nil or stored.refresh_rate ~= nil or stored.foveation ~= nil then return false end
  local p = M.LEGACY_QUALITY[stored.quality]
  if not p then return false end
  local ok = write(env, game, "eye_res", p[1])
  ok = write(env, game, "refresh_rate", p[2]) and ok
  return ok
end

-- The old quality choice changed on the Mods page after the migration: apply it to the rows the same way.
function M.applyLegacyQuality(env, game, profile)
  local p = M.LEGACY_QUALITY[profile]
  if not p then return false end
  local ok = write(env, game, "eye_res", p[1])
  ok = write(env, game, "refresh_rate", p[2]) and ok
  return ok
end

-- ------------------------------------------------------------ turn settings
local LEGACY = { smooth = { "smooth", nil }, snap30 = { "snap", 30 }, snap45 = { "snap", 45 }, snap90 = { "snap", 90 } }

-- The old single VOXEL TURN choice as (mode, angle); nil for anything else.
function M.legacyTurn(value)
  local l = LEGACY[value]
  if not l then return nil end
  return l[1], l[2]
end

-- The effective turn: (style "snap" | "smooth", snap angle in degrees). get(key) is the
-- mod's option getter (stored value or schema default; nil for the retired turn_style
-- once it is gone). While an unmigrated legacy value is still there and the new rows are
-- at their defaults, the legacy value wins: smooth -> smooth, snapNN -> snap at NN.
function M.resolveTurn(get)
  local modeSpec, angleSpec = BY_KEY.turn_mode, BY_KEY.snap_angle
  local mode, angle = get("turn_mode"), get("snap_angle")
  local legacy = get("turn_style")
  local lmode, langle = M.legacyTurn(legacy)
  if lmode and (mode == nil or mode == modeSpec.default)
      and (angle == nil or tonumber(angle) == angleSpec.default) then
    return lmode, langle or clamp(angle, angleSpec)
  end
  if mode ~= "smooth" then mode = "snap" end
  return mode, clamp(angle, angleSpec)
end

-- One-time migration (game.ready): the old turn_style becomes turn_mode + snap_angle
-- through the real writer, then turn_style is cleared. Only when the new keys were never
-- set. -> true when something was written.
function M.migrate(env, game)
  local modOptions = game and game.mods and game.mods.modOptions
  local stored = modOptions and modOptions[env.id]
  if type(stored) ~= "table" or stored.turn_style == nil then return false end
  local lmode, langle = M.legacyTurn(stored.turn_style)
  local ok = true
  if lmode and stored.turn_mode == nil and stored.snap_angle == nil then
    ok = write(env, game, "turn_mode", lmode) and ok
    if langle then ok = write(env, game, "snap_angle", langle) and ok end
  end
  if ok then write(env, game, "turn_style", nil) end
  return ok
end

-- ------------------------------------------------------------ install
local KEY = "__frlgvoxel_vrcontrols_rows"

local function removeOurs(Rows)
  if type(Rows.ORDER) == "table" then
    for i = #Rows.ORDER, 1, -1 do
      if isOurs(Rows.ORDER[i]) then table.remove(Rows.ORDER, i) end
    end
  end
  if type(Rows.GROUPS) == "table" then
    for i = #Rows.GROUPS, 1, -1 do
      local gid = Rows.GROUPS[i].id
      if gid == M.GROUP.id or gid == M.DISPLAY_GROUP.id or gid == M.PERF_GROUP.id
          or gid == M.LOOK_GROUP.id or gid == M.SPEED_GROUP.id or gid == M.WORLD_GROUP.id then table.remove(Rows.GROUPS, i) end -- Lab 55 / 57
    end
  end
end

-- env: Rows (src.ui.game3.option_rows), id (the mod id), get(key) -> the mod's option
--      value, enabled() -> bool (nil = always), log(text),
--      rates() -> the refresh rates the runtime lists ({} / nil = unknown), pending() -> true while a
--      setting waits for a restart (VR DISPLAY page)
function M.install(env)
  local Rows = env and env.Rows
  if type(Rows) ~= "table" or type(Rows.build) ~= "function" or type(Rows.GROUPS) ~= "table"
      or type(Rows.ORDER) ~= "table" then
    return false, "no Gen3 option rows"
  end
  local state = Rows[KEY]
  if state then
    state.env, state.active = env, true
  else
    state = { env = env, active = true, vanilla = Rows.build }
    Rows[KEY] = state
    Rows.build = function(ctx)
      local rows = state.vanilla(ctx)
      local e = state.env
      if not state.active or type(rows) ~= "table" or (e.enabled and not e.enabled()) then return rows end
      local have = {}
      for _, row in ipairs(rows) do if row.id then have[row.id] = true end end
      for _, spec in ipairs(M.SPECS) do
        if not have[spec.id] then rows[#rows + 1] = buildRow(e, spec) end
      end
      for _, spec in ipairs(M.DISPLAY_SPECS) do
        if not have[spec.id] then rows[#rows + 1] = buildRow(e, spec) end
      end
      for _, spec in ipairs(M.PERF_SPECS) do
        if not have[spec.id] then rows[#rows + 1] = buildRow(e, spec) end
      end
      for _, spec in ipairs(M.LOOK_SPECS) do -- Lab 55
        if not have[spec.id] then rows[#rows + 1] = buildRow(e, spec) end
      end
      for _, spec in ipairs(M.SPEED_SPECS) do -- Lab 55
        if not have[spec.id] then rows[#rows + 1] = buildRow(e, spec) end
      end
      for _, spec in ipairs(M.WORLD_SPECS) do -- Lab 57
        if not have[spec.id] then rows[#rows + 1] = buildRow(e, spec) end
      end
      if not have[WORLD_SIZE_ID] then rows[#rows + 1] = cacheSizeRow(e) end
      if not have[STATUS_ID] then rows[#rows + 1] = statusRow(e) end
      return rows
    end
  end
  -- the group + its place on the first page
  removeOurs(Rows)
  Rows.GROUPS[#Rows.GROUPS + 1] = { id = M.GROUP.id, label = M.GROUP.label, members = memberIds() }
  local displayMembers = memberIds(M.DISPLAY_SPECS)
  displayMembers[#displayMembers + 1] = STATUS_ID
  Rows.GROUPS[#Rows.GROUPS + 1] = { id = M.DISPLAY_GROUP.id, label = M.DISPLAY_GROUP.label,
    members = displayMembers }
  Rows.GROUPS[#Rows.GROUPS + 1] = { id = M.PERF_GROUP.id, label = M.PERF_GROUP.label,
    members = memberIds(M.PERF_SPECS) }
  Rows.GROUPS[#Rows.GROUPS + 1] = { id = M.LOOK_GROUP.id, label = M.LOOK_GROUP.label, -- Lab 55
    members = memberIds(M.LOOK_SPECS) }
  Rows.GROUPS[#Rows.GROUPS + 1] = { id = M.SPEED_GROUP.id, label = M.SPEED_GROUP.label, -- Lab 55
    members = memberIds(M.SPEED_SPECS) }
  local worldMembers = memberIds(M.WORLD_SPECS) -- Lab 57
  worldMembers[#worldMembers + 1] = WORLD_SIZE_ID
  Rows.GROUPS[#Rows.GROUPS + 1] = { id = M.WORLD_GROUP.id, label = M.WORLD_GROUP.label, members = worldMembers }
  local at = 1
  for i, id in ipairs(Rows.ORDER) do
    if id == "vrinteractions:adjust-hip" or id == "vrinteractions:swap-belt" then at = i + 1 end
  end
  table.insert(Rows.ORDER, at, M.GROUP.id)
  table.insert(Rows.ORDER, at + 1, M.DISPLAY_GROUP.id) -- VR DISPLAY right after VR CONTROLS
  table.insert(Rows.ORDER, at + 2, M.PERF_GROUP.id)
  table.insert(Rows.ORDER, at + 3, M.LOOK_GROUP.id) -- Lab 55
  table.insert(Rows.ORDER, at + 4, M.SPEED_GROUP.id) -- Lab 55
  table.insert(Rows.ORDER, at + 5, M.WORLD_GROUP.id) -- Lab 57
  return true
end

function M.uninstall(Rows)
  local state = Rows and Rows[KEY]
  if not state then return end
  state.active = false
  removeOurs(Rows)
end

return M
