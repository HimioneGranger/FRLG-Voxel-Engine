-- VRITK_FRLG_HOST compat (FireRed / LeafGreen only, Wilds of Hoenn 1.5.0 as the overworld provider): follower fixes
-- found on the headset (Lab 56, 2026-10-10). Gen-specific compat layer (standing rule 2026-09-28; user rule 2026-10-10:
-- "all these changes need to go in a compat layer that turns on with VRITK installed"). The Wilds mod and the engine are
-- NOT edited: this file wraps their live objects at runtime, only after the targets are confirmed present, and
-- undoes every wrap in uninstall(). Installed by compat/WildsFireRedAdapter:activate() (the router selected Wilds on
-- FireRed) and removed by :deactivate(); with VRITK absent nothing here ever runs and Wilds behaves as stock.
--
--   bug 5  The follower interaction (Pet / Play / Talk menu, its portrait and report) talked about the saved companion /
--          party lead, not the Pokemon the player SEES out: a belt send-out is a session-local override that never
--          touches the companion ("interacting with Mewtwo but it still shows Charizard"). companionMon() is answered
--          from the follower adapter's displayed Pokemon instead (recall -> falls back to stock: the lead).
--   bug 2  A at the follower only started when the engine's Player.facing cell held it. In VR the player looks at the
--          follower without the engine facing following. If the follower stands still next to the player and the cell
--          the player faces holds nothing A could act on (no object, walkable ground), the player is turned to face it
--          just before the stock tryStart runs; if tryStart then refuses, the facing is restored.
--   bug 3  (a) The party menu's ROLE row (Wilds' lib/party_roles.lua) made FireRed's action list draw fail every frame:
--          the engine looks every action label up in its own tables and asserts on a label it does not know
--          ("mod draw failed: party_menu.lua:115: ROLE..."). The ROLE rows are taken out of the list right before the
--          menu draws; the same Role / Follow / Forage / Fight choices stay reachable through the follower menu
--          (A at the follower > Role). Giving the row its own text needs an engine edit (see FIX57.md).
--          (b) The follower menu's labels carry the engine font's pen codes (0xFC cmd arg). They are not UTF-8: the
--          Kanto Gear mirrors choice labels and its wrist redraw failed with "UTF-8 decoding error". The labels are
--          built without pen codes (the stock no-font layout: the arrows follow the label, padded with spaces).
-- Mod sandbox: no package, no debug. Every engine module comes through pcall(require).
local M = {}

M.ROLE_PREFIX = "ROLE"
local RIGHT = "\226\150\182" -- the font's right arrow glyph (UTF-8)
local PEN1 = { [0x0D] = true, [0x0E] = true, [0x11] = true, [0x12] = true, [0x13] = true, [0x14] = true }
local PEN2 = { [0x05] = true, [0x08] = true, [0x0C] = true }
local PEN3 = { [0x0B] = true, [0x10] = true }

local installed = nil

--- Removes the font's pen codes (0xFC, command, argument bytes as frlg_font.lua scans them) from a label.
function M.stripPenCodes(s)
  s = tostring(s or "")
  if not s:find("\252", 1, true) then return s end
  local out, n, i, len = {}, 0, 1, #s
  while i <= len do
    local b = s:byte(i)
    if b == 0xFC then
      local cmd = s:byte(i + 1)
      if not cmd then i = i + 1
      elseif PEN1[cmd] or PEN2[cmd] then i = i + 3
      elseif PEN3[cmd] then i = i + 4
      else i = i + 2 end
    else
      local j = i
      while j < len and s:byte(j + 1) ~= 0xFC do j = j + 1 end
      n = n + 1; out[n] = s:sub(i, j); i = j + 1
    end
  end
  return table.concat(out)
end
local stripPenCodes = M.stripPenCodes

--- A label list built without pen codes: labels that end in the right arrow are padded with spaces so the arrows
--- line up one column to the right of the widest of them (the stock layout when the font cannot be measured).
function M.plainLabels(labels)
  if type(labels) ~= "table" then return labels end
  local out, widest = {}, 0
  for i, l in ipairs(labels) do
    local s = stripPenCodes(l)
    out[i] = s
    if s:sub(-#RIGHT) == RIGHT then
      local base = s:sub(1, #s - #RIGHT):gsub("%s+$", "")
      if #base > widest then widest = #base end
    end
  end
  for i, s in ipairs(out) do
    if s:sub(-#RIGHT) == RIGHT then
      local base = s:sub(1, #s - #RIGHT):gsub("%s+$", "")
      out[i] = base .. string.rep(" ", widest - #base + 1) .. RIGHT
    end
  end
  for k, v in pairs(labels) do if type(k) ~= "number" then out[k] = v end end
  return out
end

local function isRoleRow(act)
  return type(act) == "string" and act:sub(1, #M.ROLE_PREFIX) == M.ROLE_PREFIX and act:find("\252", 1, true) ~= nil
end

--- Takes Wilds' ROLE rows out of the party menu's action list (in place, so Wilds' own bookkeeping that holds the
--- same list keeps working). Returns how many rows were removed.
function M.hideRoleRows(menu)
  if type(menu) ~= "table" or menu.mode ~= "action" then return 0 end
  local list = menu.ACTIONS
  if type(list) ~= "table" then return 0 end
  local removed = 0
  for i = #list, 1, -1 do
    if isRoleRow(list[i]) then
      table.remove(list, i)
      removed = removed + 1
      local c = tonumber(menu.actionCursor)
      if c and c > i then menu.actionCursor = c - 1 end
    end
  end
  if removed > 0 then
    local c = tonumber(menu.actionCursor) or 1
    if c > #list then menu.actionCursor = math.max(1, #list) end
  end
  return removed
end

local FACING_DELTA = { up = { 0, -1 }, down = { 0, 1 }, left = { -1, 0 }, right = { 1, 0 } }

-- engine modules, once each (a mod's require goes through the loader's gate)
local function engine(req, cache, name)
  local v = cache[name]
  if v then return v end
  local ok, m = pcall(req, name)
  if ok and type(m) == "table" then cache[name] = m; return m end
  return nil -- not cached: the module may load later
end

--- install(ex, deps): ex = the wilds_of_hoenn exports; deps = { require = fn, log = fn, keepRoleRow = bool,
--- active = fn }. `active()` (optional) says whether Wilds is currently the provider: while it answers false the
--- tryStart wrapper does nothing (the ROLE-row / label parts stay on either way: Wilds' party-menu wrappers live on
--- whether or not its native gate is on).
--- true | false, why. Idempotent for the same exports.
function M.install(ex, deps)
  deps = deps or {}
  local log = deps.log or function() end
  if installed and installed.ex == ex then return true, "already installed" end
  if installed then M.uninstall() end
  local fi = type(ex) == "table" and ex.followerInteraction or nil
  if type(fi) ~= "table" then return false, "wilds_of_hoenn followerInteraction missing" end
  local class = getmetatable(fi)
  if type(class) ~= "table" or type(class.tryStart) ~= "function" or type(class.companionMon) ~= "function" then
    return false, "followerInteraction methods missing"
  end
  local req = deps.require or require
  local eng = {}
  local rec = { ex = ex, fi = fi, class = class }

  -- ---------------------------------------------------------------- bug 5: who is out
  local prevCompanionMon = rawget(fi, "companionMon")
  local origCompanionMon = fi.companionMon -- the instance's resolved method (class method or another layer's override)
  local function inParty(mon)
    local Runtime = engine(req, eng, "src.core.game3.runtime")
    local okS, session = pcall(function() return Runtime and Runtime.getSession and Runtime.getSession() end)
    local party = okS and type(session) == "table" and session.party or nil
    if type(party) ~= "table" then return true end -- cannot tell: trust the adapter
    for i = 1, #party do if party[i] == mon then return true end end
    return false
  end
  fi.companionMon = function(self)
    local a = rawget(self, "adapter")
    local d = type(a) == "table" and a.disp or nil
    if type(d) == "table" and d.role ~= "recall" and type(d.mon) == "table" and inParty(d.mon) then return d.mon end
    return origCompanionMon(self)
  end
  rec.companionMon, rec.prevCompanionMon = fi.companionMon, prevCompanionMon

  -- ---------------------------------------------------------------- bug 2: A at an adjacent follower
  local prevTryStart = rawget(fi, "tryStart")
  local origTryStart = fi.tryStart
  local function idle()
    local Field = engine(req, eng, "src.core.game3.field")
    if not Field or not Field.running or Field.locked then return false end
    local Hud = engine(req, eng, "src.ui.game3.hud")
    if Hud and type(Hud.busy) == "function" then
      local ok, busy = pcall(Hud.busy)
      if not ok or busy then return false end
    end
    local Runtime = engine(req, eng, "src.core.game3.runtime")
    if Runtime and type(Runtime.uiBusy) == "function" then
      local ok, busy = pcall(Runtime.uiBusy)
      if not ok or busy then return false end
    end
    local Space = engine(req, eng, "src.core.game3.scripting.space")
    if Space and Space.vm and type(Space.vm.isRunning) == "function" then
      local ok, running = pcall(Space.vm.isRunning, Space.vm)
      if not ok or running then return false end
    end
    local Player = engine(req, eng, "src.core.game3.player")
    if not Player or Player.moving or Player.boulderPush then return false end
    return true
  end
  -- true / false: is there a map background event on the cell; nil when the events cannot be read
  local function bgEventAt(x, y)
    local Field = engine(req, eng, "src.core.game3.field")
    local game, session = Field and Field._game, Field and Field._session
    local mapId = session and session.map
    local data = game and game.data and game.data.maps
    local def = mapId and data and data[mapId]
    local events = def and def.bgEvents
    if not events then
      local Space = engine(req, eng, "src.core.game3.scripting.space")
      local ev = Space and Space.bundle and Space.bundle.events and mapId and Space.bundle.events[mapId]
      events = ev and ev.bgEvents
    end
    if type(events) ~= "table" then return nil end
    for _, ev in ipairs(events) do
      if type(ev) == "table" and ev.x == x and ev.y == y then return true end
    end
    return false
  end
  -- turns the player toward an adjacent follower when nothing else in the facing cell wants A; returns the previous
  -- facing (so a refused start can be undone) or nil
  local function faceFollower()
    local Player = engine(req, eng, "src.core.game3.player")
    local Follower = engine(req, eng, "src.world.game3.Follower")
    if not (Player and Follower and type(Follower.current) == "function" and type(Follower.at) == "function") then return nil end
    local cx, cy = Player.cellX, Player.cellY
    if type(cx) ~= "number" or type(cy) ~= "number" then return nil end
    local d = FACING_DELTA[Player.facing]
    if not d then return nil end
    local okAt, there = pcall(Follower.at, nil, cx + d[1], cy + d[2])
    if okAt and type(there) == "table" and not there.hidden then return nil end -- already facing it: stock path
    local okF, npc = pcall(Follower.current)
    if not (okF and type(npc) == "table") or npc.hidden or npc.moving then return nil end
    if type(npc.cellX) ~= "number" or type(npc.cellY) ~= "number" then return nil end
    local dx, dy = npc.cellX - cx, npc.cellY - cy
    local face
    if dx == 0 and dy == -1 then face = "up"
    elseif dx == 0 and dy == 1 then face = "down"
    elseif dx == -1 and dy == 0 then face = "left"
    elseif dx == 1 and dy == 0 then face = "right" end
    if not face then return nil end
    local fx, fy = cx + d[1], cy + d[2]
    local Objects = engine(req, eng, "src.core.game3.objects")
    if Objects and type(Objects.at) == "function" then
      local okO, obj = pcall(Objects.at, fx, fy)
      if not okO or obj ~= nil then return nil end
    end
    local Collision = engine(req, eng, "src.core.game3.collision")
    if Collision and type(Collision.isWalkable) == "function" then
      local okK, walkable = pcall(Collision.isWalkable, fx, fy)
      if not okK or walkable ~= true then return nil end
    end
    -- a map background event on that cell (a sign, a hidden item, a trigger: field.lua bg_event_at / hidden_item_at)
    -- keeps the press; if the map's events cannot be read, so does the safe side
    if bgEventAt(fx, fy) ~= false then return nil end
    local previous = Player.facing
    Player.facing = face
    return previous
  end
  fi.tryStart = function(self, game)
    if rawget(self, "state") ~= nil then return origTryStart(self, game) end
    if type(deps.active) == "function" and deps.active() ~= true then return origTryStart(self, game) end
    local away = rawget(self, "isAway")
    if type(away) == "function" and away() then return origTryStart(self, game) end
    local a = rawget(self, "adapter")
    if type(a) == "table" and type(a.isBusy) == "function" and a:isBusy() then return origTryStart(self, game) end
    if not idle() then return origTryStart(self, game) end
    if not self:companionMon() then return origTryStart(self, game) end
    local previous = faceFollower()
    local started = origTryStart(self, game)
    if previous and not started then
      local Player = engine(req, eng, "src.core.game3.player")
      if Player then Player.facing = previous end
    end
    return started
  end
  rec.tryStart, rec.prevTryStart = fi.tryStart, prevTryStart

  -- ---------------------------------------------------------------- bug 3b: follower menu labels without pen codes
  local origLabels = class.labels
  if type(origLabels) == "function" then
    class.labels = function(name)
      return M.plainLabels(origLabels(name))
    end
    rec.labels, rec.origLabels = class.labels, origLabels
  else
    log("wilds follower fix: follower menu labels not found; left alone")
  end

  -- ---------------------------------------------------------------- bug 3a: no ROLE row in FireRed's action list
  -- deps.keepRoleRow (Emerald): its action list draws straight from the labels, so the ROLE row works there
  local okPM, PartyMenu = false, nil
  if not deps.keepRoleRow then okPM, PartyMenu = pcall(req, "src.ui.game3.party_menu") end
  if deps.keepRoleRow then
    -- nothing to wrap
  elseif okPM and type(PartyMenu) == "table" and type(PartyMenu.draw) == "function" then
    local origDraw = PartyMenu.draw
    PartyMenu.draw = function(...)
      M.hideRoleRows(PartyMenu)
      return origDraw(...)
    end
    rec.draw, rec.origDraw, rec.PartyMenu = PartyMenu.draw, origDraw, PartyMenu
    -- also right after the menu's own update, so the Kanto Gear (which mirrors the list) rarely sees the row; the draw
    -- wrap above stays as the guarantee (Wilds' update wrap may run after ours)
    if type(PartyMenu.update) == "function" then
      local origUpdate = PartyMenu.update
      PartyMenu.update = function(...)
        local a, b, c = origUpdate(...)
        M.hideRoleRows(PartyMenu)
        return a, b, c
      end
      rec.update, rec.origUpdate = PartyMenu.update, origUpdate
    end
  else
    log("wilds follower fix: party menu not found; ROLE row left alone")
  end

  installed = rec
  log("wilds follower fix installed (interaction mon, face follower, menu text, ROLE row)")
  return true
end

function M.uninstall()
  local rec = installed
  if not rec then return false end
  installed = nil
  local fi = rec.fi
  if rawget(fi, "companionMon") == rec.companionMon then fi.companionMon = rec.prevCompanionMon end
  if rawget(fi, "tryStart") == rec.tryStart then fi.tryStart = rec.prevTryStart end
  if rec.class and rec.class.labels == rec.labels and rec.origLabels then rec.class.labels = rec.origLabels end
  if rec.PartyMenu and rec.PartyMenu.draw == rec.draw then rec.PartyMenu.draw = rec.origDraw end
  if rec.PartyMenu and rec.update and rec.PartyMenu.update == rec.update then rec.PartyMenu.update = rec.origUpdate end
  return true
end

function M.status() return { installed = installed ~= nil } end

return M
