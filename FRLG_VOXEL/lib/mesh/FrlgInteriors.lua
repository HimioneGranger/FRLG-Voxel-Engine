-- FRLG_VOXEL / interiors-team CORE: FrlgInteriors.lua
--
-- The per-build interiors context the mesher creates for every indoor map
-- (FrlgMesher dispatch D0-D4, build/core/DISPATCH_PATCH.md) and the frozen
-- API the feature modules (doors, ceilings, section props) build on
-- (build/core/API.md). This file owns:
--   * the entry points bind / classify / south / gap / side / finish, EACH
--     guarded by pcall with a latch: after any unexpected error the context
--     turns into a pass-through (bind -> the mesher's own strips, south /
--     side -> false, gap -> no-op, finish -> no shell), so a module failure
--     never breaks a map build (VERIFY_arch 6b);
--   * the room's wallpaper (tiers O / A / B / C, DESIGN 1.3);
--   * the 4th (south) wall from the room's real wallpaper, texel-exact and
--     world-anchored so it continues round the corners, straight segments
--     plus slanted segments along stair-stepped south edges (the Pokemon
--     Tower curve, DESIGN BB-1);
--   * W / E / N synthetic walls emitted at once by side() (D2b), fillers /
--     drops on door cells' non-exit sides, the exit slots the Doors module
--     fills;
--   * wall-shade parity (VERIFY_coverage C5, decided: every room-enclosing
--     wall shades like the back wall);
--   * the per-triangle cutaway groups of geom.roomShell (contract V2.14) and
--     the reference visibility rule (M.roomVisible) the renderer mirrors;
--   * the journaled classify step: the core's own fixes (B1 Underground Path
--     walls, B2 Silph pads, real-life furniture heights) and the ctx helpers
--     the sections use (setGroupHeight, unwall, claim, ...), each step rolled
--     back on error.
-- No debug / package / io (mod sandbox). Sub-modules load through
-- env.require (the mesher's deps.require = V.require).
local V = ...
local _ = V

local M = { VERSION = "interiors-core 1.0 (2026-09-29)" }
-- (interiors team) the PropTypes hook revision. M.VERSION stays: it is part of
-- every roomShell, and the hooked core must stay bit-exact without types (G0).
M.HOOK_VERSION = "proptypes hook w0r5 (2026-10-02)" -- w0r5: deferred regroup in a type step (Ctx:deferRegroup)

-- ---------------------------------------------------------------------------
-- options: env.C[name] (deps.Constants) overrides the default here
-- ---------------------------------------------------------------------------
local DEF = {
  -- C5 (decided 2026-09-29): "back" = every room-enclosing wall (4th wall,
  -- W / E / N synthetic walls, fillers, the mesher's own side-wall faces)
  -- shades with the back wall's normal (0,0,1): all 0.73 (Light.lua terms),
  -- no brightness seam at the corners. "core" = only the core's walls;
  -- "true" = geometric normals (W 0.61 / 4th 0.80 / E 0.88).
  INTERIORS_WALL_SHADE = "back",
  INTERIORS_A_MIN = 0.95,       -- tier A band score (DESIGN 1.3)
  INTERIORS_O_MIN = 0.5,        -- tier O override: minimum band score when the room has candidates
  INTERIORS_B_MIN = 0.6,        -- tier B: the best column's modal match
  INTERIORS_BAND_SHARE = 0.2,   -- a texel matches the band model when its colour holds >= this share of its row
  INTERIORS_MARGIN = 0.02,      -- visibility margin (cells)
  INTERIORS_DIAG_MAX_STEP = 3,  -- south staircase: absorbed step width <= this many cells
  INTERIORS_DIAG_MAX_FIN = 2,   -- ... fin (rise) <= this many cells
  INTERIORS_DIAG_MIN_FINS = 2,  -- ... and at least this many fins in one monotone chain
  INTERIORS_DROP_H = 1.0,       -- fall-warp holes: a dark drop this deep below the floor edge
  INTERIORS_LEVEL_GROUPS = true, -- repair1 (HO-7): a furniture group on mixed ground gets one ground (no slit in its top)
  INTERIORS_HIDDEN_FACES = true, -- repair1 (skeptic-visual FAIL 1): box / wall faces the mesher skips beside slanted walls and absorbed stair-step edges
  INTERIORS_SKIRTS = true,      -- repair1 (GY-7): a cell lower than a neighbouring wall run gets the wall face down to its ground
  INTERIORS_REAL_HEIGHTS = true, -- user decision: counters and tables at real-life heights
  INTERIORS_FIX_WARP_WALLS = true, -- B1: unwalkable warp tiles at a side edge are wall
  INTERIORS_FIX_PADS = true,    -- B2: walkable warp pads are never in-wall doors
  INTERIORS_PROPFIX = true,     -- props (build/props): prop heights / real-life furniture (lib/mesh/interiors/PropFix)
  INTERIORS_PROPTYPES = true,   -- interiors team 2026-10-01: per-type furniture modules (lib/mesh/interiors/PropTypes)
  INTERIORS_RETURNS = true,     -- repair2 (skeptic-visual-r2 N1): close the 0.06 step where an inset wall ends on a cell-edge face
  INTERIORS_HOLE_WALLS = true,  -- repair2 (skeptic-visual-r2 N2): fall holes on the room's edge keep the room's wall (first person stays closed)
  INTERIORS_SHELL_TO_OPAQUE = false, -- DEBUG preview only (desktop captures without the render patch)
  INTERIORS_KEEP_LAST = false,  -- DEBUG: M.last = the last context (tests)
  INTERIORS_DEBUG_TAG = false,  -- DEBUG: tag the core's vertices (.ic) for tests
}
-- furniture heights in cells (1 cell = 1.6 m), by behaviour; others keep
-- MB.FURNITURE_H / the pair's INDOOR_PROPS; unknown furniture (tables) gets
-- FURN_DEFAULT (DESIGN 3.2 decision 2, user decision "real-life heights")
M.FURNITURE_H = {
  [0x80] = 0.65, -- counter 1.04 m
  [0x83] = 0.75, -- PC 1.2 m
  [0x86] = 0.55, -- TV (stand) 0.88 m
  [0x89] = 0.75, -- cabinet 1.2 m
  [0x8A] = 0.55, -- kitchen 0.88 m
  [0x8B] = 0.75, -- dresser 1.2 m
}
M.FURN_DEFAULT = 0.45 -- table 0.72 m
-- things standing ON a table / counter (snacks, food, telephone, cup): they
-- never raise their group's box (a counter with a cup stays a counter)
M.ON_TOP = { [0x8C] = true, [0x90] = true, [0x96] = true, [0x99] = true, [0x9B] = true }

local WALL_KINDS = { wall = true, filler = true, door = true, sill = true }
local CEIL_KINDS = { ceiling = true, riser = true, shaft = true, lamp = true }
M.WALL_KINDS, M.CEIL_KINDS = WALL_KINDS, CEIL_KINDS

-- exits: arrow warps point at their side; 0x60 / 0x69 / 0x71 have no arrow
-- (VERIFY_arch 1a: "the single open side, else none")
local ARROW = { [0x62] = "right", [0x63] = "left", [0x64] = "up", [0x65] = "down" }
local NOARROW_EXIT = { [0x60] = true, [0x69] = true, [0x71] = true }
local FALL = { [0x66] = true }
local PAD = { [0x66] = true, [0x67] = true }
M.ARROW, M.NOARROW_EXIT = ARROW, NOARROW_EXIT
local DIRS = {
  { name = "up", dx = 0, dy = -1 }, { name = "down", dx = 0, dy = 1 },
  { name = "left", dx = -1, dy = 0 }, { name = "right", dx = 1, dy = 0 },
}
local DXY = { up = { 0, -1 }, down = { 0, 1 }, left = { -1, 0 }, right = { 1, 0 } }
local FACE = { up = "N", down = "S", left = "W", right = "E" }
M.FACE = FACE

local mfloor, mabs, mmax, mmin, msqrt = math.floor, math.abs, math.max, math.min, math.sqrt
local function now() if os and os.clock then return os.clock() end return 0 end

-- ---------------------------------------------------------------------------
-- sub-modules (cached per module load; tests can inject M.modules[name])
-- ---------------------------------------------------------------------------
M.modules = {}
local modCache = {}
function M.clearCache() modCache = {} end
local function loadMod(env, name)
  local inj = M.modules[name]
  if inj ~= nil then return inj or nil end
  local c = modCache[name]
  if c ~= nil then return c or nil end
  c = false
  if type(env.require) == "function" then
    local ok, mod = pcall(env.require, "mesh/interiors/" .. name)
    if ok and type(mod) == "table" then c = mod end
  end
  modCache[name] = c
  return c or nil
end
M.loadMod = loadMod

-- ---------------------------------------------------------------------------
-- caches that outlive one build (weak-keyed: they go with the atlas / its
-- texel tables): a tile's void share, and the wallpaper pick per candidate
-- signature -- a rebuild (tile swap, map re-entry) skips the texel scans
-- ---------------------------------------------------------------------------
local voidShareC = setmetatable({}, { __mode = "k" }) -- texel table -> { [voidC] = share }
local wallpaperC = setmetatable({}, { __mode = "k" }) -- atlas -> { [signature] = P }
-- (tests / timing: forget both, as on a map's first build)
function M.clearWallpaperCaches()
  voidShareC = setmetatable({}, { __mode = "k" })
  wallpaperC = setmetatable({}, { __mode = "k" })
end

-- ---------------------------------------------------------------------------
-- the context
-- ---------------------------------------------------------------------------
local Ctx = {}
Ctx.__index = Ctx
M.Ctx = Ctx

function M.new(env)
  if type(env) ~= "table" or env.isBorder then return nil end -- (VERIFY_arch 7: border rings)
  local C = env.C or {}
  local self = setmetatable({
    env = env, C = C, W = env.W, H = env.H, grid = env.grid, mapId = env.mapId, pair = env.pair,
    dead = false, errors = {}, southCells = {}, gaps = {}, groups = {}, nextGid = 0,
    claims = {}, doors = {}, buffers = {}, fills = {},
    stats = { tris = 0, wallTris = 0, doorTris = 0, ceilTris = 0, lampTris = 0, fillTris = 0, segments = 0,
      slanted = 0, doors = 0, exits = 0, faceExits = 0, fillers = 0, holes = 0, sides = 0, finSides = 0,
      classifyOps = 0, rolledBack = 0, ms = 0, sectionMs = 0, errors = {}, b1Cells = 0, b2Cells = 0,
      heightGroups = 0, parityFaces = 0 },
  }, Ctx)
  self.WH = C.INDOOR_WALL_H or 2.0
  self.ins = C.SYNTH_WALL_INSET or 0.06
  -- (repair2, JIT-off build time) the options read per quad, once per build
  self.oShade = self:opt("INTERIORS_WALL_SHADE")
  self.oTag = self:opt("INTERIORS_DEBUG_TAG") and true or false
  self.oReturns = self:opt("INTERIORS_RETURNS") and true or false
  -- the section registry (lib/mesh/interiors/SectionMap.lua)
  local SM = loadMod(env, "SectionMap")
  local secId = SM and SM.maps and env.mapId and SM.maps[env.mapId] or nil
  self.section = secId
  self.openAir = (SM and SM.openAir and env.mapId and SM.openAir[env.mapId]) and true or false
  local sec = secId and SM.modules and SM.modules[secId] and loadMod(env, SM.modules[secId]) or nil
  self.sec = sec
  if sec and type(sec.openAir) == "function" then
    local ok, v = pcall(sec.openAir, self)
    if ok and v ~= nil then self.openAir = v and true or false end
  end
  if self:opt("INTERIORS_KEEP_LAST") then M.last = self end
  return self
end

function Ctx:opt(name)
  local v = self.C[name]
  if v == nil then v = DEF[name] end
  return v
end
function Ctx:at(x, y)
  if x < 0 or y < 0 or x >= self.W or y >= self.H then return nil end
  return self.grid[y][x] or nil
end
local function key(x, y) return y * 65536 + x end
M.key = key

-- an unexpected error: record it and latch the pass-through mode
function Ctx:fail(where, err)
  local msg = where .. ": " .. tostring(err)
  self.errors[#self.errors + 1] = msg
  self.stats.errors[#self.stats.errors + 1] = msg
  self.dead = true
end
-- a contained error (a section / module step): recorded, no latch
function Ctx:note(where, err)
  local msg = where .. ": " .. tostring(err)
  self.errors[#self.errors + 1] = msg
  self.stats.errors[#self.stats.errors + 1] = msg
end
function Ctx:yield()
  local Y = self.env.Y
  if type(Y) == "function" then Y() end
end

-- ---------------------------------------------------------------------------
-- journal (classify): every state write goes through it; rollback on error
-- ---------------------------------------------------------------------------
local Journal = {}
Journal.__index = Journal
local function newJournal() return setmetatable({ n = 0, e = {} }, Journal) end
function Journal:set(t, k, v)
  local n = self.n + 1
  self.n = n
  self.e[n] = { t, k, t[k] }
  t[k] = v
end
function Journal:push(list, v)
  local n = self.n + 1
  self.n = n
  self.e[n] = { list, false, #list }
  list[#list + 1] = v
end
function Journal:rollback()
  for i = self.n, 1, -1 do
    local e = self.e[i]
    if e[2] == false then
      for j = #e[1], e[3] + 1, -1 do e[1][j] = nil end
    else
      e[1][e[2]] = e[3]
    end
  end
  self.n, self.e = 0, {}
end
M.newJournal = newJournal

function Ctx:set(t, k, v)
  local J = self.J
  if not J then error("interiors: state writes are only allowed inside a classify step", 2) end
  if t[k] ~= v then
    J:set(t, k, v)
    self.stats.classifyOps = self.stats.classifyOps + 1
  end
end

-- run fn(self) as one journaled step; an error rolls the step back
function Ctx:step(name, fn, ...)
  local prev = self.J
  self.J = newJournal()
  local ok, err = pcall(fn, self, ...)
  if not ok then
    self.J:rollback()
    self.stats.rolledBack = self.stats.rolledBack + 1
    self:note("classify " .. name, err)
  end
  self.J = prev
  return ok
end

-- ---------------------------------------------------------------------------
-- cell helpers
-- ---------------------------------------------------------------------------
local function floorLevel(c) return c and c.role ~= "wall" and not c.exitFrame end
function Ctx:open(x, y) local n = self:at(x, y); return (not n) or (n.exitFrame and true) or false end

-- the column run of wall cells containing (x, y) -> a, b (from the cells)
function Ctx:runOf(x, y)
  local c = self:at(x, y)
  if not (c and c.role == "wall") then return nil end
  return c.runA, c.runB
end

-- ===========================================================================
-- CLASSIFY (dispatch D-C): the core's fixes, then the section's rules
-- ===========================================================================
function Ctx:classify(floorMid)
  if self.dead then return end
  local ok, err = pcall(function()
    local t0 = now()
    self.floorMid = floorMid
    if self:opt("INTERIORS_FIX_WARP_WALLS") then self:step("B1 warp walls", Ctx.fixWarpWalls) end
    if self:opt("INTERIORS_FIX_PADS") then self:step("B2 pads", Ctx.fixPads) end
    if self:opt("INTERIORS_REAL_HEIGHTS") then self:step("heights", Ctx.realHeights) end
    if self:opt("INTERIORS_PROPTYPES") then -- per-type furniture (PropTypes.lua)
      local PT = loadMod(self.env, "PropTypes")
      if PT and type(PT.classify) == "function" then
        -- (w0r2) the Ceiling module's lamp inputs before the per-type step
        -- (Ceiling 1.1: lamps keep their places when a type pulls a cell out
        -- of a wall); geometry-neutral without types (G0)
        local CeilM = loadMod(self.env, "Ceiling")
        if CeilM and type(CeilM.snapshot) == "function" then
          local okS, errS = pcall(CeilM.snapshot, self)
          if not okS then self:note("Ceiling snapshot", errS) end
        end
        PT.classify(self, loadMod)
      end
    end
    if self:opt("INTERIORS_PROPFIX") then -- props (build/props/CORE_HOOK.md)
      local PF = loadMod(self.env, "PropFix")
      if PF and type(PF.classify) == "function" then
        local prevOwner = self.owner
        self.owner = "PropFix"
        self:step("propfix", function(s) PF.classify(s) end)
        self.owner = prevOwner
      end
    end
    if self:opt("INTERIORS_LEVEL_GROUPS") then self:step("levels", Ctx.levelGroups) end -- repair1 (HO-7)
    local sec = self.sec
    if sec and type(sec.classify) == "function" then
      local ts = now()
      self:step("section " .. tostring(self.section), function(s) sec.classify(s) end)
      self.stats.sectionMs = self.stats.sectionMs + (now() - ts) * 1000
    end
    self.stats.ms = self.stats.ms + (now() - t0) * 1000
  end)
  if not ok then self:fail("classify", err) end
end

-- one pass over the door cells (both fixes read only these)
function Ctx:doorCells()
  if self._doorCells then return self._doorCells end
  local out, grid = {}, self.grid
  for y = 0, self.H - 1 do
    local row = grid[y]
    for x = 0, self.W - 1 do
      local c = row[x]
      if c and c.isDoor then out[#out + 1] = c end
    end
  end
  self._doorCells = out
  return out
end
-- B1 (VERIFY_coverage): a warp tile you cannot walk on is not a door. The
-- Underground Path tunnels' brick side walls (x 7 rows 2-60; x 79 rows 2-4)
-- carry stair behaviour 0x6E on unwalkable cells -> no wall anywhere today.
-- Such a cell with void / off-map to its W or E becomes a SIDE WALL cell of a
-- column run (merged with the wall cells above / below), exactly what the
-- role pass makes of a plain wall tile there.
function Ctx:fixWarpWalls()
  local MB = self.env.MB or {}
  local DOOR = MB.DOOR or {}
  local cand, any = {}, false
  for _, c in ipairs(self:doorCells()) do
    local x, y = c.x, c.y
    if not c.walkable and c.beh and DOOR[c.beh] and c.role == nil
        and (self:open(x - 1, y) or self:open(x + 1, y)) then
      cand[key(x, y)] = c
      any = true
    end
  end
  if not any then self.stats.b1Cells = 0 return end
  local n = 0
  for x = 0, self.W - 1 do
    local y = 0
    while y < self.H do
      local c = self:at(x, y)
      if c and cand[key(x, y)] then
        local a, b = y, y
        while cand[key(x, b + 1)] do b = b + 1 end
        -- merge with wall cells directly above / below (their runs)
        local up, dn = self:at(x, a - 1), self:at(x, b + 1)
        if up and up.role == "wall" then a = up.runA end
        if dn and dn.role == "wall" then b = dn.runB end
        for yy = a, b do
          local p = self:at(x, yy)
          if cand[key(x, yy)] then
            self:set(p, "role", "wall")
            self:set(p, "side", true)
            self:set(p, "wb", true)
            self:set(p, "warpWall", true)
            n = n + 1
          end
          self:set(p, "runA", a)
          self:set(p, "runB", b)
        end
        y = b + 1
      else
        y = y + 1
      end
    end
  end
  self.stats.b1Cells = n
end

-- B2 (VERIFY_coverage): walkable warp pads (0x66 / 0x67) are floor, never
-- an in-wall door (mesher role rule 5 excludes stair warps, not pads: Silph
-- 7F (5,4), 8F (11,10), 9F (22,18) stood upright in walls).
function Ctx:fixPads()
  local n = 0
  for _, c in ipairs(self:doorCells()) do
    if c.role == "wall" and c.inWall == "door" and c.walkable and c.beh and PAD[c.beh] then
      self:unwall(c.x, c.y, c.y, { as = "floor", allowInWall = true })
      self:set(c, "padFixed", true) -- (repair1) fallbackGaps closes its open sides if the core fails
      n = n + 1
    end
  end
  self.stats.b2Cells = n
end

-- real-life furniture heights (user decision; DESIGN 3.2 decision 2)
-- (repair1, skeptic-visual FAIL 1) an UNKNOWN group (no behaviour / prop
-- height: "a table") is lowered to FURN_DEFAULT only when none of its tiles
-- is also a wall-run tile of this room: such a group is wall art the role
-- pass could not make a wall (the Cerulean Gym back-wall row between its
-- porthole notches, harbor quay railings, warehouse crates ...), not a table;
-- lowering it opened slits into the notches behind it. It keeps the mesher's
-- height (PropFix / a section may still set one).
function Ctx:wallMids()
  if self._wallMids then return self._wallMids end
  local wm, grid = {}, self.grid
  for y = 0, self.H - 1 do
    local row = grid[y]
    for x = 0, self.W - 1 do
      local c = row[x]
      if c and c.role == "wall" and c.mid then wm[c.mid] = true end
    end
  end
  self._wallMids = wm
  return wm
end
-- one group's real-life height by that rule -> h (nil = keep the group's
-- height), wallArt (interiors team w0r1: one method, so PropTypes re-derives
-- a host group's height after a type took cells out of it)
function Ctx:realHeightOf(g, wm)
  local MB = self.env.MB or {}
  local FH = MB.FURNITURE_H or {}
  local props = self.env.IN and self.env.IN.props or nil
  wm = wm or self:wallMids()
  local h, known, wallArt = nil, false, false
  for _, p in ipairs(g.cells) do
    local v = p.beh and M.FURNITURE_H[p.beh]
    if v == nil and p.beh and M.ON_TOP[p.beh] then v = false end
    if v == nil then v = p.beh and FH[p.beh] end
    if v == nil then local pr = props and props[p.mid]; v = pr and pr.h or nil end
    if v then known = true; if h == nil or v > h then h = v end end
    if p.mid and wm[p.mid] then wallArt = true end
  end
  if not known then
    if wallArt then return nil, true end
    return M.FURN_DEFAULT, false
  end
  return h, false
end
function Ctx:realHeights()
  local wm = self:wallMids()
  local n, kept = 0, 0
  for _, g in ipairs(self.env.groups or {}) do
    if not g.pillar and not g.slot and not g.fixedH then
      local h, wallArt = self:realHeightOf(g, wm)
      if wallArt then kept = kept + 1 end
      if h and mabs(h - g.h) > 1e-9 then
        self:set(g, "h", h)
        n = n + 1
      end
    end
  end
  self.stats.heightGroups = n
  self.stats.heightWallArt = kept
end

-- (repair1, HO-7) a furniture group whose cells stand on different grounds
-- (the Fan Club and Silph 8F tables over a raised 0.25 plate, One Island's
-- counter) has a top stepped by that difference with an open slit in the
-- step. Every cell gets ONE ground, the group's HIGHEST (DESIGN HO-7 "group
-- ground = max": no cell of the box sinks below a raised walkable neighbour,
-- whose step face would then overlap the box side), and the box height is
-- set so the TOP stays at its real-life height over the floor people stand
-- on round it (the modal ground of the walkable neighbours; ties: the
-- lower) -- a table stays 0.45 over the main floor, not over the plate.
-- Only the ground under the box moves (it is not drawn); the side faces
-- reach down to the lower of the two grounds as before.
function Ctx:levelGroups()
  local n = 0
  for _, g in ipairs(self.env.groups or {}) do
    local mn, mx = math.huge, -math.huge
    for _, p in ipairs(g.cells) do
      local h = p.hgt or 0
      if h < mn then mn = h end
      if h > mx then mx = h end
    end
    if mx - mn > 1e-9 and not g.pillar and not g.slot then
      local inG, cnt = {}, {}
      for _, p in ipairs(g.cells) do inG[p] = true end
      for _, p in ipairs(g.cells) do
        for _, d in ipairs(DIRS) do
          local q = self:at(p.x + d.dx, p.y + d.dy)
          if q and not inG[q] and q.walkable then cnt[q.hgt or 0] = (cnt[q.hgt or 0] or 0) + 1 end
        end
      end
      local ref, bn = mn, 0
      for h, k in pairs(cnt) do
        if k > bn or (k == bn and h < ref) then ref, bn = h, k end
      end
      local top = ref + (g.h or 0)
      for _, p in ipairs(g.cells) do
        if mabs((p.hgt or 0) - mx) > 1e-9 then self:setGround(p.x, p.y, mx) end
      end
      local nh = mmin(self.WH, top - mx)
      if nh >= 0.1 and mabs(nh - (g.h or 0)) > 1e-9 then self:set(g, "h", nh) end
      self:set(g, "levelled", true)
      n = n + 1
    end
  end
  self.stats.levelledGroups = n
end

-- ---------------------------------------------------------------------------
-- classify helpers (sections: ONLY through these; each write is journaled)
-- ---------------------------------------------------------------------------
-- a furniture group's box height (cells above its ground)
function Ctx:setGroupHeight(g, h)
  assert(type(g) == "table" and g.cells, "setGroupHeight: not a furniture group")
  assert(type(h) == "number" and h > 0 and h <= self.WH, "setGroupHeight: height out of range")
  if g.pillar then self:unPillar(g) end
  self:set(g, "h", h)
  self:set(g, "fixedH", true)
end
-- a pillar group back to a plain furniture box (its capital decal returns)
function Ctx:unPillar(g, h)
  if g.pillar then
    local cap = g.pillar.cap
    if cap then self:set(cap, "suppressDecal", nil) end
    self:set(g, "pillar", nil)
  end
  if h then self:set(g, "h", h); self:set(g, "fixedH", true) end
end

-- (w0r5) ctx -> { list, set }: the groups whose regroup waits (deferRegroup)
local REGROUP_DEFER = setmetatable({}, { __mode = "k" })
-- remove cell p from its furniture group (keeps the group consistent)
function Ctx:leaveGroup(p)
  local g = p.group
  if not g then return end
  local cells = {}
  for _, q in ipairs(g.cells) do if q ~= p then cells[#cells + 1] = q end end
  self:set(g, "cells", cells)
  self:set(p, "group", nil)
  self:set(p, "fy0", nil)
  self:set(p, "fy1", nil)
  if #cells == 0 then
    local groups = self.env.groups
    local keep = {}
    for _, q in ipairs(groups) do if q ~= g then keep[#keep + 1] = q end end
    -- rewrite the shared list in place (the mesher holds the same table)
    for i = 1, mmax(#groups, #keep) do self:set(groups, i, keep[i]) end
  else
    -- (w0r5) inside a furniture type's step a group left with 2+ cells waits
    -- for flushRegroup (one regroup per group, not one per cell); a group
    -- left with 1 cell is regrouped now (its extents if it is emptied next)
    local d = REGROUP_DEFER[self]
    if d and #cells > 1 then
      if not d.set[g] then d.set[g] = true; d.list[#d.list + 1] = g end
    else
      self:regroup(g)
    end
  end
end
-- (interiors team w0r5) deferred regroup for ONE furniture type's step
-- (PropTypes 1.4 sets it around the type's classify): leaveGroup marks the
-- host group instead of recomputing its extents per leaving cell, and
-- flushRegroup recomputes each marked group once from its final cells. The
-- cells, groups and geometry equal a regroup per leave (regroup depends only
-- on the group's final cells; a group emptied in the step keeps the extents
-- of its last 1-cell regroup, as before); the journal holds fewer writes.
-- Never active outside a type step (the core, PropFix and the sections
-- regroup per leave: G0). An error in the step: cancelRegroup (the journal
-- rolls the cells back).
function Ctx:deferRegroup() REGROUP_DEFER[self] = { list = {}, set = {} } end
function Ctx:flushRegroup()
  local d = REGROUP_DEFER[self]
  REGROUP_DEFER[self] = nil
  if not d then return end
  for _, g in ipairs(d.list) do
    if #g.cells > 0 then self:regroup(g) end
  end
end
function Ctx:cancelRegroup() REGROUP_DEFER[self] = nil end
function Ctx:regroupDeferred() return REGROUP_DEFER[self] ~= nil end
-- recompute a group's row extents and every cell's column extents
function Ctx:regroup(g)
  local inG, minY, maxY = {}, math.huge, -math.huge
  for _, q in ipairs(g.cells) do
    inG[q] = true
    if q.y < minY then minY = q.y end
    if q.y > maxY then maxY = q.y end
  end
  self:set(g, "minY", minY)
  self:set(g, "maxY", maxY)
  for _, q in ipairs(g.cells) do
    local y0, y1 = q.y, q.y
    while inG[self:at(q.x, y0 - 1) or false] do y0 = y0 - 1 end
    while inG[self:at(q.x, y1 + 1) or false] do y1 = y1 + 1 end
    self:set(q, "fy0", y0)
    self:set(q, "fy1", y1)
  end
end

-- a new (or given) furniture group over cells; returns the group
function Ctx:furnish(cells, h, g)
  if not g then
    g = { cells = {}, minY = math.huge, maxY = -math.huge, h = h or (self.C.FURNITURE_H_DEFAULT or 0.7),
      stairs = false, interiors = true }
    self.J:push(self.env.groups, g)
  end
  local list = {}
  for _, q in ipairs(g.cells) do list[#list + 1] = q end
  for _, p in ipairs(cells) do
    list[#list + 1] = p
    self:set(p, "role", "furniture")
    self:set(p, "group", g)
  end
  self:set(g, "cells", list)
  if h then self:set(g, "h", h); self:set(g, "fixedH", true) end
  self:regroup(g)
  return g
end

-- take wall cells (x, y0..y1) -- all in ONE column run -- out of the run;
-- the rest of the run above / below becomes its own run(s).
-- opts.as: "furniture" (default: a box h = opts.h, joined to opts.group),
--          "claim" (role "ext": the section's props draw it; opts.h is the
--          fallback box height), "floor" (the cell's own art on the floor),
--          "flat" (role flat: a floor decal)
-- returns the furniture group (as = "furniture") or nil
function Ctx:unwall(x, y0, y1, opts)
  opts = opts or {}
  local c0 = self:at(x, y0)
  assert(c0 and c0.role == "wall", "unwall: (" .. x .. "," .. y0 .. ") is not a wall cell")
  local a, b = c0.runA, c0.runB
  assert(y0 <= y1 and a <= y0 and y1 <= b, "unwall: rows outside the cell's column run")
  for yy = y0, y1 do
    local p = self:at(x, yy)
    assert(p.inWall == nil or opts.allowInWall, "unwall: an in-wall door / sign cell")
  end
  if y0 > a then for yy = a, y0 - 1 do self:set(self:at(x, yy), "runB", y0 - 1) end end
  if y1 < b then for yy = y1 + 1, b do self:set(self:at(x, yy), "runA", y1 + 1) end end
  local cells = {}
  for yy = y0, y1 do
    local p = self:at(x, yy)
    self:set(p, "role", nil)
    self:set(p, "runA", nil)
    self:set(p, "runB", nil)
    self:set(p, "side", nil)
    self:set(p, "inWall", nil)
    self:set(p, "pocket", nil)
    self:set(p, "wb", false)
    cells[#cells + 1] = p
  end
  local as = opts.as or "furniture"
  if as == "furniture" then
    return self:furnish(cells, opts.h or (self.C.FURNITURE_H_DEFAULT or 0.7), opts.group)
  elseif as == "claim" then
    for _, p in ipairs(cells) do self:claimCell(p, opts.groundMid, opts.h) end
  elseif as == "flat" then
    for _, p in ipairs(cells) do self:set(p, "role", "flat") end
  end
  return nil
end

function Ctx:claimCell(p, groundMid, h)
  if p.group then self:leaveGroup(p) end
  self:set(p, "role", "ext")
  self:set(p, "groundMid", groundMid or p.groundMid or self.floorMid)
  self:set(p, "claimH", h or (self.C.FURNITURE_H_DEFAULT or 0.7))
  self:set(p, "claimOwner", self.owner or "section") -- props (build/props/CORE_HOOK.md)
  self.J:push(self.claims, p)
end
-- role "ext": the mesher draws only the cell's ground; the section draws the
-- prop in props(); if props fails the core draws a fallback box
function Ctx:claim(x, y, groundMid, h)
  local p = assert(self:at(x, y), "claim: no cell")
  if p.role == "wall" then self:unwall(x, y, y, { as = "claim", groundMid = groundMid, h = h }) return end
  self:claimCell(p, groundMid, h)
end
-- drawn like floor with its own tile (invisible walls)
function Ctx:flatten(x, y)
  local p = assert(self:at(x, y), "flatten: no cell")
  if p.role == "wall" then self:unwall(x, y, y, { as = "flat" }) return end
  if p.group then self:leaveGroup(p) end
  self:set(p, "role", "flat")
end
-- the cell's ground height (phantom steps); feeds heightAt too
function Ctx:setGround(x, y, h)
  local p = assert(self:at(x, y), "setGround: no cell")
  assert(type(h) == "number", "setGround: height")
  self:set(p, "hgt", h)
end
-- add / remove the plant role (a pot under the walkable over-art leaves above)
function Ctx:plant(x, y, on)
  local p = assert(self:at(x, y), "plant: no cell")
  if on then
    local top = self:at(x, y - 1)
    assert(top and top.walkable and top.hasOver, "plant: no leaves above")
    if p.role == "wall" then self:unwall(x, y, y, { as = "floor" }) end
    if p.group then self:leaveGroup(p) end
    self:set(p, "role", "plant")
    self:set(p, "plantTop", top)
    self:set(top, "suppressDecal", true)
  elseif p.role == "plant" then
    if p.plantTop then self:set(p.plantTop, "suppressDecal", nil) end
    self:set(p, "plantTop", nil)
    self:set(p, "role", nil)
  end
end

-- ---------------------------------------------------------------------------
-- queries for the feature modules (read-only)
-- ---------------------------------------------------------------------------
-- the top of cell (x, y)'s own geometry as the roles say (cells): wall runs
-- g + WH; furniture g + its group's height (pillars: their column); plants,
-- statues, gates, boulders, claimed cells; floor / flat: g. nil off-map.
function Ctx:topAt(x, y)
  local c = self:at(x, y)
  if not c then return nil end
  local C, g, r = self.C, c.hgt or 0, c.role
  if r == "wall" then return g + self.WH end
  if r == "furniture" and c.group then
    local grp = c.group
    if grp.pillar then return g + mmin(self.WH, (grp.maxY - grp.minY + 2) * (C.PILLAR_ROW_H or 0.55)) end
    return g + (grp.h or 0)
  end
  if r == "plant" then return g + (C.PLANT_TOP_H or 1.35) end
  if r == "statue" then return g + (C.STATUE_PLINTH_H or 0.55) + (C.STATUE_CARD_H or 1.0) end
  if r == "gate" then return g + (C.GATE_BAR_H0 or 0.45) + (C.GATE_BAR_STEP or 0.45) * 2 end
  if r == "boulder" then return g + (C.BOULDER_H_MAX or 0.8) end
  if r == "ext" then return g + (c.claimH or 0) end
  return g
end
function Ctx:floorLevel(x, y) return floorLevel(self:at(x, y)) and true or false end

-- free-standing wall runs (not 4-connected to the room's outer ring): under
-- a ceiling each becomes a floor-to-ceiling partition -- the C1 review list
-- (graves, railings, bikes, banisters, lamps ... or real partitions).
-- -> { { x, a, b, g, mids = {...} }, ... } (one entry per column run)
function Ctx:freeWalls()
  local out = {}
  for x = 0, self.W - 1 do
    local y = 0
    while y < self.H do
      local c = self:at(x, y)
      if c and c.role == "wall" and c.runA == y then
        local ring = false
        local mids = {}
        for yy = c.runA, c.runB do
          local p = self:at(x, yy)
          if p.ring or p.side then ring = true end
          mids[#mids + 1] = p.mid
          for _, d in ipairs(DIRS) do if not self:at(x + d.dx, yy + d.dy) then ring = true end end
        end
        if not ring then out[#out + 1] = { x = x, a = c.runA, b = c.runB, g = c.hgt, mids = mids } end
        y = c.runB + 1
      else
        y = y + 1
      end
    end
  end
  return out
end

-- the cells a ceiling covers: every floor-level cell (not void, not a wall
-- run, not an exit frame), with the inset of the wall standing on each
-- side (SYNTH_WALL_INSET where the side is open: void / exit frame --
-- synthetic walls, the 4th wall, door slots; 0 toward cells and wall runs)
-- -> { { x, y, g, c, top, trim = { up, down, left, right } }, ... }
-- The slanted 4th wall's floor fills (ctx.fills: { poly = {{x,z}...}, g })
-- need ceiling too; ctx.diagOf is the mesher's slanted north walls.
function Ctx:ceilingCells()
  local out, ins = {}, self.ins
  for y = 0, self.H - 1 do
    for x = 0, self.W - 1 do
      local c = self:at(x, y)
      if floorLevel(c) then
        local t = {}
        for _, d in ipairs(DIRS) do t[d.name] = self:open(x + d.dx, y + d.dy) and ins or 0 end
        -- (an absorbed stair-step edge / fin: the slanted wall stands
        -- beyond it -- the fill carries the ceiling on to it)
        if self.absSouth and self.absSouth[key(x, y)] then t.down = 0 end
        if self.fin and self.fin[key(x, y) * 4 + 1] then t.left = 0 end
        if self.fin and self.fin[key(x, y) * 4 + 2] then t.right = 0 end
        out[#out + 1] = { x = x, y = y, g = c.hgt or 0, c = c, top = self:topAt(x, y), trim = t }
      end
    end
  end
  return out
end

-- test / debug: every wall cell's run is the maximal wall run of its column
function M.checkRuns(grid, W, H)
  local bad = {}
  for x = 0, W - 1 do
    local y = 0
    while y < H do
      local c = grid[y][x]
      if c and c.role == "wall" then
        local a, b = y, y
        while b + 1 < H and grid[b + 1][x] and grid[b + 1][x].role == "wall" do b = b + 1 end
        for yy = a, b do
          local p = grid[yy][x]
          if p.runA ~= a or p.runB ~= b then bad[#bad + 1] = string.format("(%d,%d) run %s..%s, want %d..%d", x, yy, tostring(p.runA), tostring(p.runB), a, b) end
        end
        y = b + 1
      else
        if c and (c.runA or c.runB) and c.role ~= "wall" then bad[#bad + 1] = string.format("(%d,%d) non-wall with a run", x, y) end
        y = y + 1
      end
    end
  end
  return bad
end

-- ===========================================================================
-- WALLPAPER (dispatch D1b: bind)
-- ===========================================================================
function Ctx:tex(mid)
  local t = self.env.atlas and self.env.atlas.texels
  if type(t) ~= "function" or mid == nil then return nil end
  return t(mid, "under")
end
function Ctx:voidColour()
  if self._voidC == nil then
    local vm = self.voidMidB or self.env.voidMid
    local t = vm and self:tex(vm)
    self._voidC = t and t[1] or false
  end
  return self._voidC or nil
end
-- a wall tile that can be wallpaper: texels, no over art, at most
-- maxVoid of it the void colour (a wall TOP / rim is mostly void; the lower
-- tile must be real wallpaper: < 25%, the upper may carry the dark top half
-- the back wall itself shows -- the Underground Path tunnels)
function Ctx:paperTile(mid, maxVoid)
  self._pt = self._pt or {}
  local e = self._pt[mid]
  if e == nil then
    e = false
    local t = self:tex(mid)
    if t then
      local hasOver = self.env.midHasOver and self.env.midHasOver(mid)
      local vc = self:voidColour() or -2
      local vs = voidShareC[t]
      if not vs then vs = {}; voidShareC[t] = vs end
      local share = vs[vc]
      if share == nil then
        local nv = 0
        for i = 1, 256 do if t[i] == vc then nv = nv + 1 end end
        share = nv / 256
        vs[vc] = share
      end
      e = (not hasOver) and share or false
    end
    self._pt[mid] = e
  end
  if e == false then return false end
  if maxVoid then return e <= maxVoid + 1e-9 end
  return e < 0.25
end
-- behaviours that mark a tile as NOT wallpaper: doors / warps, signs,
-- wall-mounted art, furniture and interactables (0x60-0xAF); other
-- behaviour bytes (0x08 cave ...) are battle / terrain flags
function Ctx:artBeh(beh)
  if beh == nil or beh == 0 then return false end
  local MB = self.env.MB or {}
  if (MB.WALL_MOUNTED and MB.WALL_MOUNTED[beh]) or (MB.SIGN and MB.SIGN[beh]) or (MB.DOOR and MB.DOOR[beh]) then return true end
  return beh >= 0x60 and beh <= 0xAF
end

function Ctx:bind(plainU, plainL, t)
  if self.dead then
    -- (repair2, skeptic-r2 N1) dead since classify: still keep the mesher's
    -- strips and dark texel -- fallbackGaps draws a B2 pad's open sides with
    -- them (Silph 9F (22,18) stayed open, 2 rays past module off)
    self.plainU0, self.plainL0 = self.plainU0 or plainU, self.plainL0 or plainL
    self.darkUv = self.darkUv or (t and t.darkUv)
    return plainU, plainL
  end
  local ok, U, L = pcall(Ctx.bindImpl, self, plainU, plainL, t or {})
  if ok then return U, L end
  self:fail("bind", U)
  -- (repair1) the mesher's own strips for the fallbacks (fallbackSouth / Gaps)
  self.plainU0, self.plainL0 = self.plainU0 or plainU, self.plainL0 or plainL
  self.darkUv = self.darkUv or (t and t.darkUv)
  return plainU, plainL
end

function Ctx:bindImpl(plainU, plainL, t)
  local t0 = now()
  local env = self.env
  self.darkUv = t.darkUv
  self.floorMid = self.floorMid or t.floorMid
  self.voidMidB = t.voidMid
  self.plainU0, self.plainL0 = plainU, plainL
  self.opaqueMark = #env.opaque -- the wall pass starts here (parity post-pass)
  local P = self:pickWallpaper()
  self.wp = P
  local U, L = plainU, plainL
  if P.tier == "A" or P.tier == "O" then
    U, L = env.underRect(P.up), env.underRect(P.lo)
    -- the in-wall door side faces read IN.wallUpper / Lower directly
    if env.IN then env.IN.wallUpper, env.IN.wallLower = P.up, P.lo end
  elseif P.tier == "B" then
    local ru, rl = env.underRect(P.up), env.underRect(P.lo)
    local cu = (P.col + 0.5) / 16
    U = ru and env.subRect(ru, cu, 0, cu, 1) or plainU
    L = rl and env.subRect(rl, cu, 0, cu, 1) or plainL
  end
  self.U, self.L = U, L
  self:analyseSouth()
  self.stats.ms = self.stats.ms + (now() - t0) * 1000
  return U, L
end

-- the wallpaper candidates (interiors team w0r1: one method, so PropTypes can
-- snapshot them before the per-type step)
function Ctx:wallpaperCands()
  local W, H = self.W, self.H
  -- candidates: wall-run bottoms with a floor-level cell south, clean tiles;
  -- back-wall columns (the run's top on void / off-map) first -- only when
  -- a room has none (the Power Plant's maze), every such run bottom
  local all = {}
  local grid = self.grid
  for y = 0, H - 1 do
    local row, below = grid[y], grid[y + 1]
    for x = 0, W - 1 do
      local c = row[x]
      if c and c.role == "wall" and c.runB == y and not c.inWall and not c.pocket then
        local s = below and below[x] or nil
        -- (floor or furniture south: a back wall behind a shelf is still wallpaper)
        if s and s.role ~= "wall" and not s.exitFrame then
          local up = (y - 1 >= c.runA) and grid[y - 1][x] or c
          if not self:artBeh(up.beh) and not self:artBeh(c.beh) and self:paperTile(up.mid, 0.5)
              and self:paperTile(c.mid) then
            all[#all + 1] = { x = x, y = y, up = up.mid, lo = c.mid, rows = c.runB - c.runA + 1,
              back = not self:at(x, c.runA - 1) }
          end
        end
      end
    end
  end
  return all
end
-- tiers O / A / B / C (DESIGN 1.3)
function Ctx:pickWallpaper()
  local all = self:wallpaperCands()
  -- (w0r1) wall runs a furniture type changed keep their pre-type candidates
  local PTw = self:opt("INTERIORS_PROPTYPES") and loadMod(self.env, "PropTypes") or nil
  if PTw and type(PTw.wallpaperCands) == "function" then all = PTw.wallpaperCands(self, all) end
  local function collect(backOnly, minRows)
    local out = {}
    for _, cd in ipairs(all) do
      if cd.rows >= minRows and (cd.back or not backOnly) then out[#out + 1] = cd end
    end
    return out
  end
  -- (2-row runs first: a 1-row run's single tile is the top of a wall
  -- whose lower row is furniture -- the same tile twice is no wallpaper)
  local cands, P
  for _, pass in ipairs({ { true, 2 }, { false, 2 }, { true, 1 }, { false, 1 } }) do
    cands = collect(pass[1], pass[2])
    P = { tier = "C", cands = #cands, back = pass[1], rows = pass[2] }
    if #cands > 0 then break end
  end
  -- the same candidates, override and thresholds -> the same pick
  local sec = self.sec
  local ov = sec and type(sec.wallpaper) == "table" and self.pair and sec.wallpaper[self.pair] or nil
  local sig = {}
  for _, cd in ipairs(cands) do sig[#sig + 1] = cd.up * 65536 + cd.lo end
  table.sort(sig)
  local key = table.concat(sig, ",") .. "|" .. tostring(self.pair) .. "|" .. (type(ov) == "table" and (tostring(ov.up) .. "/" .. tostring(ov.lo)) or "-")
    .. "|" .. tostring(self:opt("INTERIORS_A_MIN")) .. "/" .. tostring(self:opt("INTERIORS_O_MIN")) .. "/" .. tostring(self:opt("INTERIORS_B_MIN"))
    .. "/" .. tostring(self:opt("INTERIORS_BAND_SHARE")) .. "|" .. tostring(self:voidColour())
  local atlas = self.env.atlas
  local byAtlas = atlas and wallpaperC[atlas]
  local hit = byAtlas and byAtlas[key]
  if hit then
    local out = {}
    for k, v in pairs(hit) do out[k] = v end
    out.cached = true
    return out
  end
  local Pfinal = self:scoreWallpaper(cands, P, ov)
  if atlas then
    if not byAtlas then byAtlas = {}; wallpaperC[atlas] = byAtlas end
    local keep = {}
    for k, v in pairs(Pfinal) do keep[k] = v end
    byAtlas[key] = keep
  end
  return Pfinal
end

-- the tiers over the chosen candidates (pickWallpaper's scoring half)
function Ctx:scoreWallpaper(cands, P, ov)
  -- One-call row histograms: the same tile participates in the aggregate
  -- and several scores. No state survives a build or a cold-cache reset.
  local hist = {}
  local function rowsOf(t, allowMissing)
    local rows = hist[t]
    if rows then return rows end
    rows = {}
    for r = 0, 15 do
      local counts, base = {}, r * 16
      for col = 1, 16 do
        local v = t[base + col]
        -- Sparse override tiles score missing texels as nonmatches. Candidate
        -- tiles still fail aggregation on nil, as the original row model did.
        if v ~= nil or not allowMissing then counts[v] = (counts[v] or 0) + 1 end
      end
      rows[r] = counts
    end
    hist[t] = rows
    return rows
  end
  -- band model over the candidate columns (aggregated per distinct pair:
  -- the texel loops run once per pair, weighted by its column count)
  local freq, order = {}, {}
  for _, cd in ipairs(cands) do
    local k = cd.up * 65536 + cd.lo
    if not freq[k] then freq[k] = 0; order[#order + 1] = k end
    freq[k] = freq[k] + 1
  end
  local cnt, tot, modal, okC = {}, {}, {}, {}
  for r = 0, 31 do cnt[r] = {}; tot[r] = 0 end
  for _, k in ipairs(order) do
    local n = freq[k]
    local a, b = self:tex(mfloor(k / 65536)), self:tex(k % 65536)
    local ha, hb = rowsOf(a), rowsOf(b)
    for r = 0, 31 do
      local counts = (r < 16 and ha or hb)[r % 16]
      local row = cnt[r]
      for v, count in pairs(counts) do
        row[v] = (row[v] or 0) + n * count
      end
      tot[r] = tot[r] + 16 * n
    end
  end
  local SH = self:opt("INTERIORS_BAND_SHARE")
  for r = 0, 31 do
    local bst, bn = nil, -1
    local ok, lim = {}, SH * tot[r]
    for v, n in pairs(cnt[r]) do
      if n > bn or (n == bn and v < bst) then bst, bn = v, n end
      if n >= lim then ok[v] = true end
    end
    modal[r], okC[r] = bst, ok
  end
  local function score(up, lo)
    local a, b = self:tex(up), self:tex(lo)
    if not (a and b) then return 0 end
    if #cands == 0 then return nil end
    local ha, hb = rowsOf(a, true), rowsOf(b, true)
    local s = 0
    for r = 0, 31 do
      local counts = (r < 16 and ha or hb)[r % 16]
      local ok = okC[r]
      for v, count in pairs(counts) do
        if ok[v] then s = s + count end
      end
    end
    return s / 512
  end
  -- tier O: the section's override for this tileset pair
  if type(ov) == "table" and ov.up and ov.lo and self:paperTile(ov.up, 0.5) and self:paperTile(ov.lo) then
    local s = score(ov.up, ov.lo)
    if s == nil or s >= self:opt("INTERIORS_O_MIN") then
      P.tier, P.up, P.lo, P.score = "O", ov.up, ov.lo, s or 1
      return P
    end
    P.overrideRejected = s
  end
  -- tier A: the most frequent candidate pair with a band score >= A_MIN
  local AM = self:opt("INTERIORS_A_MIN")
  local bestK, bestF, bestS = nil, -1, -1
  for _, k in ipairs(order) do
    local s = score(mfloor(k / 65536), k % 65536) or 0
    if s >= AM and (freq[k] > bestF or (freq[k] == bestF and (s > bestS or (s == bestS and k < bestK)))) then
      bestK, bestF, bestS = k, freq[k], s
    end
  end
  if bestK then
    P.tier, P.up, P.lo, P.score = "A", mfloor(bestK / 65536), bestK % 65536, bestS
    return P
  end
  -- tier B: the best single texel column (stretched, u constant)
  local bs, bk, bc = -1, nil, nil
  for _, k in ipairs(order) do
    local up, lo = mfloor(k / 65536), k % 65536
    local a, b = self:tex(up), self:tex(lo)
    for col = 1, 16 do
      local s = 0
      for r = 0, 31 do
        local tt = r < 16 and a or b
        if tt[(r % 16) * 16 + col] == modal[r] then s = s + 1 end
      end
      if s > bs or (s == bs and k < bk) then bs, bk, bc = s, k, col - 1 end
    end
  end
  if bk and bs / 32 >= self:opt("INTERIORS_B_MIN") then
    P.tier, P.up, P.lo, P.col, P.score = "B", mfloor(bk / 65536), bk % 65536, bc, bs / 32
  end
  return P
end

-- the UV span of the wallpaper for band tile rect R between tile fractions
-- f0..f1 (tier A / O: 1:1 texels; B / C: the stretched strip, u as given)
function Ctx:bandUv(band, f0, f1)
  local P = self.wp
  local R = band == 0 and self.L or self.U
  if not R then return nil end
  if P and (P.tier == "A" or P.tier == "O") then
    return R[1] + (R[3] - R[1]) * f0, R[1] + (R[3] - R[1]) * f1, R[2], R[4]
  end
  return R[1], R[3], R[2], R[4]
end

-- ===========================================================================
-- geometry helpers
-- ===========================================================================
-- shading normal of a room-enclosing wall whose inward geometric normal is
-- (nx, nz) (C5 parity)
function Ctx:shadeN(nx, nz)
  local m = self.oShade
  if m == "back" or m == "core" then return 0, 0, 1 end
  return nx, 0, nz
end

-- the vertex constructor (the mesher's newV: it tracks geom.bounds); with
-- the DEBUG option INTERIORS_DEBUG_TAG each vertex also carries .ic = the
-- emitting module (tests find the core's triangles; never set in the game)
function Ctx:newVfn()
  local newV = self.env.newV
  if not self.oTag then return newV end
  local tag = self.owner or "core"
  return function(x, y, z, u, v, nx, ny, nz)
    local t = newV(x, y, z, u, v, nx, ny, nz)
    t.ic = tag
    return t
  end
end
-- quad a,b,c,d (corners: a bottom-left, b bottom-right, c top-right, d top-left)
function Ctx:quadV(list, ax, ay, az, au, av, bx, by, bz, bu, bv, cx, cy, cz, cu, cv, dx, dy, dz, du, dv, nx, ny, nz)
  local newV = self:newVfn()
  local A = newV(ax, ay, az, au, av, nx, ny, nz)
  local B = newV(bx, by, bz, bu, bv, nx, ny, nz)
  local Cc = newV(cx, cy, cz, cu, cv, nx, ny, nz)
  local D = newV(dx, dy, dz, du, dv, nx, ny, nz)
  local n = #list
  list[n + 1], list[n + 2], list[n + 3] = A, B, Cc
  list[n + 4], list[n + 5], list[n + 6] = A, Cc, D
end
-- vertical quad from a (left) to b (right), y0..y1, u0 at a, u1 at b, the
-- tile's vTop at y1
function Ctx:vquad(list, ax, az, bx, bz, y0, y1, u0, u1, vTop, vBot, nx, ny, nz)
  self:quadV(list, ax, y0, az, u0, vBot, bx, y0, bz, u1, vBot, bx, y1, bz, u1, vTop, ax, y1, az, u0, vTop, nx, ny, nz)
end
-- horizontal rectangle, one UV rect (r[1], r[2] at the north-west corner)
function Ctx:hquad(list, x0, z0, x1, z1, y, r, nx, ny, nz)
  self:quadV(list, x0, y, z0, r[1], r[2], x1, y, z0, r[3], r[2], x1, y, z1, r[3], r[4], x0, y, z1, r[1], r[4],
    nx or 0, ny or 1, nz or 0)
end
function Ctx:tri(list, a, b, c)
  local n = #list
  list[n + 1], list[n + 2], list[n + 3] = a, b, c
end

-- WALLPAPER on a vertical rectangle: a (left) -> b (right) as seen from the
-- room side, y0..y1, bands anchored at the floor g (lower tile g..g+1, upper
-- tile g+1..g+2, the upper tile again above). s0 = the tile coordinate at a
-- (world-anchored: see Ctx:sOf); split at integer s (1 tile = 1 cell).
-- n = shading normal {nx, ny, nz}.
function Ctx:paper(list, ax, az, bx, bz, g, y0, y1, s0, nx, ny, nz)
  local dx, dz = bx - ax, bz - az
  local len = msqrt(dx * dx + dz * dz)
  if len < 1e-9 or y1 <= y0 + 1e-9 then return end
  local ux, uz = dx / len, dz / len
  local s1 = s0 + len
  local k = mfloor(s0 + 1e-9)
  -- (repair1) tier B maps ONE texel column (u constant): no tile splits,
  -- one piece over the whole length (the same image, fewer triangles)
  local whole = self.wp and self.wp.tier == "B"
  while k < s1 - 1e-9 do
    local sa, sb = mmax(s0, k), mmin(s1, k + 1)
    if whole then sa, sb, k = s0, s1, mfloor(s1 + 1) end
    if sb > sa + 1e-9 then
      local pax, paz = ax + ux * (sa - s0), az + uz * (sa - s0)
      local pbx, pbz = ax + ux * (sb - s0), az + uz * (sb - s0)
      local f0, f1 = sa - k, sb - k
      local band = mfloor((y0 - g) + 1e-9)
      if band < 0 then band = 0 end
      while g + band < y1 - 1e-9 do
        local ya, yb = mmax(y0, g + band), mmin(y1, g + band + 1)
        if yb > ya + 1e-9 then
          local u0, u1, vT, vB = self:bandUv(band == 0 and 0 or 1, f0, f1)
          if u0 then
            -- (a band cut short: its v follows the tile, top row at g+band+1)
            local top = g + band + 1
            local va = vT + (vB - vT) * (top - yb)
            local vb = vT + (vB - vT) * (top - ya)
            self:vquad(list, pax, paz, pbx, pbz, ya, yb, u0, u1, va, vb, nx, ny, nz)
          end
        end
        band = band + 1
      end
    end
    k = k + 1
  end
end
-- world-anchored tile coordinate of point (x, z) on a face whose inward
-- normal is (nx, nz) (axis-aligned faces): the art reads left -> right
function M.sOf(nx, nz, x, z)
  if nz < -0.5 then return -x end   -- faces north (4th wall): left = east
  if nz > 0.5 then return x end     -- faces south (north wall): left = west
  if nx > 0.5 then return -z end    -- faces east (west wall): left = south
  return z                          -- faces west (east wall): left = north
end

-- the room's rim colour for caps (the mesher's IN.rimUv; an over-atlas rim
-- cannot be drawn in these lists -> darkUv, like the mesher's southWalls)
function Ctx:capUv()
  local IN = self.env.IN
  local r = IN and IN.rimUv
  if r and not r.over then return r end
  return self.darkUv
end

-- one synthetic wall slab on side d of cell c (the mesher's synthWall
-- geometry: SYNTH_WALL_INSET deep, N / S strips trimmed at a void / exit-
-- frame W / E neighbour), texel-exact wallpaper, parity normal, cap
-- a CONCAVE corner at the end of a strip: the next cell along the strip
-- (nx, ny) is floor-level and the cell diagonally beyond the strip (dx, dy)
-- is present -- there the perpendicular strip of the diagonal cell meets
-- this one; both faces run SYNTH_WALL_INSET on into the corner, or a
-- 0.06 x 0.06 hole stays open there (T1 found them)
function Ctx:concave(nx, ny, dx, dy)
  local n, d = self:at(nx, ny), self:at(dx, dy)
  return n and floorLevel(n) and d and not d.exitFrame and true or false
end
function Ctx:slab(list, capList, c, dname, g, overList)
  local ins, WH = self.ins, self.WH
  local x, y = c.x, c.y
  local x0, z0, x1, z1 = x + 0.0, y + 0.0, x + 1.0, y + 1.0
  local bx0, bx1, bz0, bz1 = x0, x1, z0, z1
  local ax, az, bx, bz, nx, nz
  if dname == "left" or dname == "right" then
    local fx = dname == "left" and x - 1 or x + 1
    local cN = self:concave(x, y - 1, fx, y - 1)
    local cS = self:concave(x, y + 1, fx, y + 1)
    local fz0 = cN and z0 - ins or z0
    local fz1 = cS and z1 + ins or z1
    if dname == "left" then
      bx1 = x0 + ins
      ax, az, bx, bz, nx, nz = bx1, fz1, bx1, fz0, 1, 0
    else
      bx0 = x1 - ins
      ax, az, bx, bz, nx, nz = bx0, fz0, bx0, fz1, -1, 0
    end
    -- (repair2) the strip's two ends: inset plane -> cell edge
    local xi, xe = ax, dname == "left" and x0 or x1
    if not self:open(x, y - 1) then self:endReturn(list, cN, x, y - 1, fx, y - 1, xi, fz0, xe, fz0, 0, -1, g) end
    if not self:open(x, y + 1) then self:endReturn(list, cS, x, y + 1, fx, y + 1, xi, fz1, xe, fz1, 0, 1, g) end
    -- (repair2) a concave run-on against a wall run: its SYNTH_WALL_INSET
    -- square beyond the cap has no perpendicular strip's cap over it -- the
    -- slot behind the return stood open from above (Indigo PC 1F, 3/4 view)
    if self.oReturns then
      local dN = cN and self:at(fx, y - 1)
      local dS = cS and self:at(fx, y + 1)
      self.retCaps = nil
      if dN and not floorLevel(dN) then self.retCaps = { fz0, z0 } end
      if dS and not floorLevel(dS) then
        local rc = self.retCaps or {}
        rc[#rc + 1], rc[#rc + 2] = z1, fz1
        self.retCaps = rc
      end
    end
  else
    local fy = dname == "up" and y - 1 or y + 1
    if dname == "up" then bz1 = z0 + ins else bz0 = z1 - ins end
    local oW, oE = self:open(x - 1, y), self:open(x + 1, y)
    local cW = not oW and self:concave(x - 1, y, x - 1, fy)
    local cE = not oE and self:concave(x + 1, y, x + 1, fy)
    if oW then bx0 = x0 + ins elseif cW then bx0 = x0 - ins end
    if oE then bx1 = x1 - ins elseif cE then bx1 = x1 + ins end
    if dname == "up" then ax, az, bx, bz, nx, nz = bx0, bz1, bx1, bz1, 0, 1
    else ax, az, bx, bz, nx, nz = bx1, bz0, bx0, bz0, 0, -1 end
    -- (repair2) the strip's two ends: inset plane -> cell edge
    local zi, ze = az, dname == "up" and z0 or z1
    if not oW then self:endReturn(list, cW, x - 1, y, x - 1, fy, bx0, zi, bx0, ze, -1, 0, g) end
    if not oE then self:endReturn(list, cE, x + 1, y, x + 1, fy, bx1, zi, bx1, ze, 1, 0, g) end
  end
  local sx, sy, sz = self:shadeN(nx, nz)
  self:paper(list, ax, az, bx, bz, g, g, g + WH, M.sOf(nx, nz, ax, az), sx, sy, sz)
  local IN = self.env.IN
  local rim = IN and IN.rimUv
  local rc = self.retCaps
  self.retCaps = nil
  local prev = self.owner
  if rim and rim.over and overList then
    self:hquad(overList, bx0, bz0, bx1, bz1, g + WH, rim)
    self.owner = rc and "retCap" or prev -- (the DEBUG vertex tag only)
    if rc then for i = 1, #rc, 2 do self:hquad(overList, bx0, rc[i], bx1, rc[i + 1], g + WH, rim) end end
  else
    local cap = self:capUv()
    if cap then
      self:hquad(capList, bx0, bz0, bx1, bz1, g + WH, cap)
      self.owner = rc and "retCap" or prev
      if rc then for i = 1, #rc, 2 do self:hquad(capList, bx0, rc[i], bx1, rc[i + 1], g + WH, cap) end end
    end
  end
  self.owner = prev
  return bx0, bx1, bz0, bz1
end

-- ---------------------------------------------------------------------------
-- (repair2, skeptic-visual-r2 N1) RETURNS. A synthetic wall stands
-- SYNTH_WALL_INSET (0.06) in from the cell edge; where the room's boundary
-- goes on ON the cell edge instead -- a wall run's face beyond a concave
-- corner, or a slanted (staircase) back wall ending on the edge -- the 0.06
-- step between the two was never closed: a floor-to-ceiling slit onto the
-- background (every Mart's NW chamfer, the Pokemon Tower 6F diagonal, the
-- Indigo / Cinnabar lab / Champion / Tower 4F / 7F joints, the Hideout 4th
-- wall ends). A return face closes it: in the plane through the strip's end,
-- from the inset plane (px, pz) to the cell edge (qx, qz), g .. g + WH, the
-- room's wallpaper, looking away from the strip along it (fnx, fnz).
-- conc: the strip ran SYNTH_WALL_INSET on into a concave corner (the cell
-- (dx, dy) diagonally beyond it is present): a return only when that cell is
-- not floor-level (a wall run: no perpendicular inset strip meets this one
-- there). Otherwise the next cell along the strip (nx, ny) decides: a wall
-- cell with a slanted face (the mesher's diagOf) needs one; a plain wall run
-- closes the step with its own flush face; a floor cell continues the strip.
-- diagOf is known from finish on: before it (side() in the wall pass) the
-- candidates are kept and closed in finish (Ctx:closeReturns).
-- ---------------------------------------------------------------------------
function Ctx:endReturn(list, conc, nx, ny, dx, dy, px, pz, qx, qz, fnx, fnz, g)
  if not self.oReturns then return end
  if conc then
    local d = self:at(dx, dy)
    if d and not floorLevel(d) then self:returnFace(list, px, pz, qx, qz, fnx, fnz, g) end
    return
  end
  local n = self:at(nx, ny)
  if not (n and n.role == "wall") then return end
  local diagOf = self.diagOf
  if type(diagOf) == "table" then
    if diagOf[n] then self:returnFace(list, px, pz, qx, qz, fnx, fnz, g) end
    return
  end
  local R = self.retDiag
  if not R then R = {}; self.retDiag = R end
  R[#R + 1] = { n = n, px = px, pz = pz, qx = qx, qz = qz, nx = fnx, nz = fnz, g = g }
end
-- the return face itself (wallpaper, world-anchored, C5 shading)
function Ctx:returnFace(list, px, pz, qx, qz, fnx, fnz, g)
  if mabs(px - qx) + mabs(pz - qz) < 1e-9 then return end
  -- a (left, seen from where the face looks) -> b: (-(b - a).z, (b - a).x) along the normal
  local ax, az, bx, bz = px, pz, qx, qz
  if -(bz - az) * fnx + (bx - ax) * fnz < 0 then ax, az, bx, bz = qx, qz, px, pz end
  local sx, sy, sz = self:shadeN(fnx, fnz)
  local prev = self.owner
  self.owner = "return" -- (the DEBUG vertex tag only)
  self:paper(list, ax, az, bx, bz, g, g, g + self.WH, M.sOf(fnx, fnz, ax, az), sx, sy, sz)
  self.owner = prev
  self.stats.returns = (self.stats.returns or 0) + 1
end
-- finish: the candidates side() kept, now that diagOf is known (opaque)
function Ctx:closeReturns()
  local R = self.retDiag
  if not R or #R == 0 then return end
  local diagOf = self.diagOf
  if type(diagOf) ~= "table" then return end
  local b = self:buffer("opaque")
  for _, r in ipairs(R) do
    if diagOf[r.n] then self:returnFace(b, r.px, r.pz, r.qx, r.qz, r.nx, r.nz, r.g) end
  end
  -- (kept: a later failure rolls this buffer back with the rest of finish,
  -- and the degraded mode draws them again -- Ctx:fallbackReturns)
end
-- degraded mode: the same returns straight into opaque (side()'s strips
-- stay in the lists whatever fails later, so their slits must stay closed)
function Ctx:fallbackReturns()
  local R, diagOf = self.retDiag, self.diagOf
  if not R or #R == 0 or type(diagOf) ~= "table" then return end
  local L = self.env.opaque
  for _, r in ipairs(R) do
    if diagOf[r.n] then self:returnFace(L, r.px, r.pz, r.qx, r.qz, r.nx, r.nz, r.g) end
  end
  self.retDiag = {}
end

-- ===========================================================================
-- SIDE (dispatch D2b): W / E / N synthetic walls, emitted at once
-- ===========================================================================
function Ctx:sideImpl(c, x, y, g, dname)
  if not self.analysed then error("side before bind") end
  local fk = (dname == "left" and 1) or (dname == "right" and 2) or nil
  if fk and self.fin[key(x, y) * 4 + fk] then
    self.stats.finSides = self.stats.finSides + 1
    -- (repair1) remembered: if the core fails later the slanted wall is
    -- dropped and fallbackFins draws the fin after all
    local F = self.finSkips
    if not F then F = {}; self.finSkips = F end
    F[#F + 1] = { c = c, g = g, d = dname }
    return true -- a stair-step fin of the south curve: the slanted 4th wall replaces it
  end
  local env = self.env
  self:slab(env.opaque, env.opaque, c, dname, g, env.over)
  self.stats.sides = self.stats.sides + 1
  return true
end
function Ctx:side(c, x, y, g, dname)
  if self.dead then return false end
  local env = self.env
  local nO, nOv = #env.opaque, #env.over
  local nR = self.retDiag and #self.retDiag or 0
  local ok, r = pcall(Ctx.sideImpl, self, c, x, y, g, dname)
  if ok then return r end
  for i = #env.opaque, nO + 1, -1 do env.opaque[i] = nil end
  for i = #env.over, nOv + 1, -1 do env.over[i] = nil end
  if self.retDiag then for i = #self.retDiag, nR + 1, -1 do self.retDiag[i] = nil end end -- (repair2) its kept returns go too
  self.owner, self.retCaps = nil, nil
  self:fail("side", r)
  return false
end

-- ===========================================================================
-- SOUTH (dispatch D2) and GAP (D2g): record only
-- ===========================================================================
function Ctx:southImpl(c, x, y, g)
  if not self.analysed then error("south before bind") end
  local L = self.southCells
  L[#L + 1] = { c = c, x = x, y = y, g = g }
  return true
end
function Ctx:south(c, x, y, g)
  if self.dead or self.openAir then return false end
  local ok, r = pcall(Ctx.southImpl, self, c, x, y, g)
  if ok then return r end
  self:fail("south", r)
  return false
end

function Ctx:gapImpl(c, x, y, g, dname)
  local L = self.gaps
  L[#L + 1] = { c = c, x = x, y = y, g = g, d = dname }
end
function Ctx:gap(c, x, y, g, dname)
  -- (repair1) recorded even after a failure: fallbackGaps needs the open
  -- sides of the pads classify made floor (bind can fail after classify)
  local ok, err = pcall(Ctx.gapImpl, self, c, x, y, g, dname)
  if not ok and not self.dead then self:fail("gap", err) end
end

-- the south boundary before the wall pass: stair-stepped south edges ->
-- slanted segments (their S edges and W / E fins are absorbed)
function Ctx:analyseSouth()
  self.absSouth = {}     -- absorbed south cells: key -> chain
  self.fin = {}          -- absorbed fins: key*4 + (1 left | 2 right) -> chain
  self.chains = {}
  self.analysed = true
  local W, H = self.W, self.H
  local maxStep, maxFin, minFins = self:opt("INTERIORS_DIAG_MAX_STEP"), self:opt("INTERIORS_DIAG_MAX_FIN"), self:opt("INTERIORS_DIAG_MIN_FINS")
  if self.openAir then return end
  local grid = self.grid
  local function sEdge(x, y)
    if x < 0 or x >= W then return nil end
    local c = grid[y][x]
    if not c or c.role == "wall" or c.exitFrame or c.isDoor then return nil end
    local s = y + 1 < H and grid[y + 1][x] or nil
    if s and not s.exitFrame then return nil end
    return c
  end
  -- runs of plain S-edge cells per row (same ground)
  local runs, byA, byB = {}, {}, {}
  for y = 0, H - 1 do
    local x = 0
    while x < W do
      local c = sEdge(x, y)
      if c then
        local a, b = x, x
        while sEdge(b + 1, y) and sEdge(b + 1, y).hgt == c.hgt do b = b + 1 end
        local R = { y = y, a = a, b = b, g = c.hgt }
        runs[#runs + 1] = R
        byA[key(a, y)] = R
        byB[key(b, y)] = R
        x = b + 1
      else
        x = x + 1
      end
    end
  end
  local function finOk(fx, ya, yb, openDx, g)
    for yy = ya, yb do
      local c = self:at(fx, yy)
      if not (c and floorLevel(c) and not c.isDoor and c.hgt == g and self:open(fx + openDx, yy)) then return false end
    end
    return true
  end
  -- descending eastward (room NE): R -> R' with R'.a = R.b + 1, R'.y > R.y
  local function nextDesc(R)
    for dy = 1, maxFin do
      local R2 = byA[key(R.b + 1, R.y + dy)]
      if R2 and R2.g == R.g and finOk(R.b + 1, R.y + 1, R.y + dy, -1, R.g) then return R2 end
    end
    return nil
  end
  -- ascending eastward, walked east -> west (room NW): R -> R' with
  -- R'.b = R.a - 1, R'.y > R.y
  local function nextAsc(R)
    for dy = 1, maxFin do
      local R2 = byB[key(R.a - 1, R.y + dy)]
      if R2 and R2.g == R.g and finOk(R.a - 1, R.y + 1, R.y + dy, 1, R.g) then return R2 end
    end
    return nil
  end
  local used, ends = {}, {}
  for _, dir in ipairs({ "desc", "asc" }) do
    local nextOf = dir == "desc" and nextDesc or nextAsc
    local hasPrev = {}
    for _, R in ipairs(runs) do local n = nextOf(R); if n then hasPrev[n] = true end end
    for _, R0 in ipairs(runs) do
      if not hasPrev[R0] and nextOf(R0) then
        local seq = { R0 }
        while true do
          local last = seq[#seq]
          local n = nextOf(last)
          -- an absorbed run (all but the last) is at most maxStep wide
          if not n or (last.b - last.a + 1) > maxStep or used[n] or ends[last] then break end
          seq[#seq + 1] = n
        end
        -- the first corner must be convex (no floor beside the first run)
        local first = seq[1]
        local ox = dir == "desc" and first.a - 1 or first.b + 1
        local beside = self:at(ox, first.y)
        if beside and floorLevel(beside) then table.remove(seq, 1) end
        local ok = #seq - 1 >= minFins
        for i = 1, #seq - 1 do if used[seq[i]] or ends[seq[i]] then ok = false end end
        if ok then
          ends[seq[#seq]] = true
          local ch = { dir = dir, runs = seq, g = seq[1].g }
          self.chains[#self.chains + 1] = ch
          for i = 1, #seq - 1 do
            local R = seq[i]
            used[R] = true
            for x = R.a, R.b do self.absSouth[key(x, R.y)] = ch end
            local R2 = seq[i + 1]
            if dir == "desc" then
              for yy = R.y + 1, R2.y do self.fin[key(R2.a, yy) * 4 + 1] = ch end
            else
              for yy = R.y + 1, R2.y do self.fin[key(R2.b, yy) * 4 + 2] = ch end
            end
          end
        end
      end
    end
  end
end

-- ===========================================================================
-- FINISH (dispatch D3): build everything
-- ===========================================================================
function Ctx:finish(diagOf)
  if self.dead then
    -- (repair1, skeptic-render D1) the core died after classify: its claimed
    -- cells keep role "ext" (the mesher drew only their ground), so they get
    -- the fallback boxes claimCell promises -- never emptier than module-off
    self.diagOf = diagOf
    pcall(Ctx.degrade, self)
    self.out = nil
    return
  end
  local t0 = now()
  local env = self.env
  local mark = { opaque = #env.opaque, over = #env.over, under = #env.under, keyed = #env.keyed }
  local ok, err = pcall(Ctx.finishImpl, self, diagOf)
  if not ok then
    self:fail("finish", err)
    -- drop what finish emitted into the base lists, then restore the
    -- mesher's own south walls for the recorded cells and box every claimed
    -- cell (repair1, D1: its props went with the rollback)
    for nm, n in pairs(mark) do
      local L = env[nm]
      for i = #L, n + 1, -1 do L[i] = nil end
    end
    self.diagOf = self.diagOf or diagOf
    pcall(Ctx.degrade, self)
    self.out = nil
  end
  self.stats.ms = self.stats.ms + (now() - t0) * 1000
end
-- (repair2, skeptic-r2 N3) the degraded mode, ONE entry point for both of
-- finish's failure branches, each fallback under its own pcall (and the
-- whole under the caller's): a fallback helper that throws loses only its
-- own part, never the map build. Every helper restores its own list lengths.
local DEGRADE = { "fallbackSouth", "fallbackFins", "fallbackGaps", "fallbackReturns", "claimFallback", "safeHiddenFaces" }
function Ctx:degrade()
  self.buffers = {}
  self.owner, self.retCaps = nil, nil
  local env = self.env
  for _, name in ipairs(DEGRADE) do
    local nO, nOv = #env.opaque, #env.over
    local ok, err = pcall(Ctx[name], self)
    if not ok then
      for i = #env.opaque, nO + 1, -1 do env.opaque[i] = nil end
      for i = #env.over, nOv + 1, -1 do env.over[i] = nil end
      self:note("degrade " .. name, err)
    end
  end
end
-- (repair1) the hidden-face patch again after a failure: classify's lowered
-- heights stay, so the faces they expose are closed in degraded mode too
function Ctx:safeHiddenFaces()
  if not (self:opt("INTERIORS_HIDDEN_FACES") or self:opt("INTERIORS_SKIRTS")) then return end
  local b0 = #self.buffers
  local ok = pcall(Ctx.patchHiddenFaces, self)
  for i = b0 + 1, #self.buffers do
    local b = self.buffers[i]
    if ok and not b.committed then pcall(Ctx.commit, self, b) end
  end
end

-- private buffers for the base lists (appended only when a step succeeds)
function Ctx:buffer(name)
  local b = { name = name }
  self.buffers[#self.buffers + 1] = b
  return b
end
function Ctx:commit(b)
  local L = self.env[b.name]
  for i = 1, #b do L[#L + 1] = b[i] end
  b.committed = true
end

-- a shell group (kind: wall | filler | door | sill | ceiling | riser | shaft | lamp)
-- spec: { nx, nz, d } (wall-type: the plane, normal INTO the room) or { y0 }
function Ctx:group(kind, spec, owner)
  assert(WALL_KINDS[kind] or CEIL_KINDS[kind], "interiors: unknown group kind " .. tostring(kind))
  self.nextGid = self.nextGid + 1
  local g = { id = self.nextGid, kind = kind, list = {}, owner = owner or self.owner or "core" }
  for k, v in pairs(spec or {}) do g[k] = v end
  if WALL_KINDS[kind] then
    assert(g.nx and g.nz and g.d, "interiors: a wall-type group needs a plane {nx, nz, d}")
  else
    assert(g.y0, "interiors: a ceiling-type group needs y0")
  end
  self.groups[#self.groups + 1] = g
  return g
end
-- the plane through (px, pz) with inward normal (nx, nz)
function M.plane(nx, nz, px, pz) return { nx = nx, nz = nz, d = -(nx * px + nz * pz) } end

-- run one feature module / section step; its groups and buffers are dropped
-- if it errors
function Ctx:runModule(name, fn)
  local g0, b0 = #self.groups, #self.buffers
  local prevOwner = self.owner
  self.owner = name
  local ok, err = pcall(fn, self)
  self.owner = prevOwner
  if ok then
    for i = b0 + 1, #self.buffers do
      local b = self.buffers[i]
      if not b.committed and not b.private then self:commit(b) end
    end
  else
    for i = #self.groups, g0 + 1, -1 do self.groups[i] = nil end
    for i = #self.buffers, b0 + 1, -1 do self.buffers[i] = nil end
    self:note(name, err)
  end
  return ok
end

function Ctx:finishImpl(diagOf)
  self.diagOf = diagOf
  local env = self.env
  self.opaqueFinish = #env.opaque -- (the mesher's own faces end here: parityMesherSides)
  -- 1. door cells' open sides
  self:classifyGaps()
  self:yield()
  -- 2. the 4th wall (straight + slanted segments)
  if not self.openAir then self:buildSouth() end
  self:yield()
  -- 2b. (repair1) faces the mesher skipped that this build exposes (opaque)
  if self:opt("INTERIORS_HIDDEN_FACES") or self:opt("INTERIORS_SKIRTS") then
    self:runModule("hiddenFaces", Ctx.patchHiddenFaces)
  end
  -- 3. fillers / drops / walls on W / E / N door-cell sides (opaque)
  self:runModule("fillers", Ctx.buildSideFillers)
  -- 3b. (repair2, N1) the returns side() left for diagOf (opaque)
  self:runModule("returns", Ctx.closeReturns)
  self:emitCaps() -- (repair1, resumed) the 4th wall's caps, split at the fillers' corners
  -- 4. exits (door slots) incl. face doors; the Doors module fills them
  self:findExits()
  local Doors = loadMod(env, "Doors")
  if Doors and type(Doors.build) == "function" then
    self:runModule("Doors", function(s) Doors.build(s) end)
  end
  self:yield()
  self:doorFallback()
  -- 5. the ceiling (never on open-air maps)
  local Ceiling = loadMod(env, "Ceiling")
  if Ceiling and type(Ceiling.build) == "function" and not self.openAir then
    self:runModule("Ceiling", function(s) Ceiling.build(s) end)
  end
  self:yield()
  -- 5b. PropFix props (build/props/CORE_HOOK.md): the cells it claimed
  local PF = self:opt("INTERIORS_PROPFIX") and loadMod(env, "PropFix") or nil
  if PF and type(PF.props) == "function" then
    if not self:runModule("PropFix", function(s) PF.props(s) end) then self:claimFallback("PropFix") end
  elseif #self.claims > 0 then
    self:claimFallback("PropFix")
  end
  -- 5c. per-type furniture props (PropTypes.lua): each type in its own runModule
  local PT = self:opt("INTERIORS_PROPTYPES") and loadMod(env, "PropTypes") or nil
  if PT and type(PT.props) == "function" then PT.props(self) end
  -- 6. section props
  local sec = self.sec
  if sec and type(sec.props) == "function" then
    local ts = now()
    local okP = self:runModule("section " .. tostring(self.section), function(s) sec.props(s) end)
    self.stats.sectionMs = self.stats.sectionMs + (now() - ts) * 1000
    if not okP then self:claimFallback("section") end
  elseif #self.claims > 0 and not (sec and sec.props) then
    self:claimFallback("section")
  end
  self:yield()
  -- 7. shade parity of the mesher's own side-wall faces (C5)
  if self:opt("INTERIORS_WALL_SHADE") == "back" then self:parityMesherSides() end
  -- 8. the shell
  self.out = self:assemble()
  -- Expose docking centers only after the owning prop's geometry committed
  -- and the whole shell assembled. A failed prop retains native fallback.
  local state = PT and PT.state and PT.state(self)
  local healer
  for _, ts in ipairs(state and state.types or {}) do
    if ts.name == "Healer" and ts.ok and ts.propsOk and ts.healerFR then
      if healer then healer = nil; break end -- ambiguous machines: flat fallback
      healer = ts.healerFR
    end
  end
  if self.out and healer then self.out.healerFR = healer end
end

-- ---------------------------------------------------------------------------
-- door-cell sides
-- ---------------------------------------------------------------------------
-- the exit side of a door cell, or nil
function Ctx:exitSide(c)
  if not (c.walkable and c.beh) then return nil end
  local a = ARROW[c.beh]
  if a then return a end
  if NOARROW_EXIT[c.beh] then
    local only, n = nil, 0
    for _, d in ipairs(DIRS) do
      if self:open(c.x + d.dx, c.y + d.dy) then only, n = d.name, n + 1 end
    end
    if n == 1 then return only end
  end
  return nil
end

function Ctx:classifyGaps()
  self.southGap = {} -- key -> { kind = exit | filler | hole | wall, gap }
  self.sideGaps = {}
  for _, gp in ipairs(self.gaps) do
    local c = gp.c
    local kind
    if not c.walkable then kind = "wall"
    elseif self:exitSide(c) == gp.d then kind = "exit"
    elseif c.beh and FALL[c.beh] then kind = "hole"
    else kind = "filler" end
    gp.kind = kind
    if gp.d == "down" then
      self.southGap[key(gp.x, gp.y)] = gp
    else
      self.sideGaps[#self.sideGaps + 1] = gp
    end
    if kind == "filler" or kind == "wall" then self.stats.fillers = self.stats.fillers + 1
    elseif kind == "hole" then self.stats.holes = self.stats.holes + 1 end
  end
end

-- W / E / N door-cell sides that are not exits: a wall slab (fillers and
-- unwalkable warp tiles) or a drop (fall warps); in opaque
function Ctx:buildSideFillers()
  local b = self:buffer("opaque")
  local holeWalls = self:opt("INTERIORS_HOLE_WALLS") -- (repair2, N2: a hole keeps the room's wall)
  for _, gp in ipairs(self.sideGaps) do
    if gp.kind == "filler" or gp.kind == "wall" or (holeWalls and gp.kind == "hole") then
      self:slab(b, b, gp.c, gp.d, gp.g)
    elseif gp.kind == "hole" then
      self:drop(b, gp.c, gp.d, gp.g)
    end
  end
end

-- a fall-warp hole's edge: a dark drop below the floor edge
function Ctx:drop(list, c, dname, g)
  local r = self.darkUv
  if not r then return end
  local x0, z0, x1, z1 = c.x + 0.0, c.y + 0.0, c.x + 1.0, c.y + 1.0
  local ax, az, bx, bz, nx, nz
  if dname == "down" then ax, az, bx, bz, nx, nz = x1, z1, x0, z1, 0, -1
  elseif dname == "up" then ax, az, bx, bz, nx, nz = x0, z0, x1, z0, 0, 1
  elseif dname == "left" then ax, az, bx, bz, nx, nz = x0, z1, x0, z0, 1, 0
  else ax, az, bx, bz, nx, nz = x1, z0, x1, z1, -1, 0 end
  self:vquad(list, ax, az, bx, bz, g - self:opt("INTERIORS_DROP_H"), g, r[1], r[3], r[2], r[4], 0, 0, 0)
end

-- ---------------------------------------------------------------------------
-- the 4th wall
-- ---------------------------------------------------------------------------
function Ctx:buildSouth()
  local ins, WH = self.ins, self.WH
  -- every south-edge cell of this build: plain cells (south()) + door cells
  -- (gap "down"); absorbed staircase cells are drawn by their chain
  local cells = {}
  for _, s in ipairs(self.southCells) do
    if not self.absSouth[key(s.x, s.y)] then cells[key(s.x, s.y)] = { x = s.x, y = s.y, g = s.g, c = s.c } end
  end
  for k, gp in pairs(self.southGap) do
    cells[k] = { x = gp.x, y = gp.y, g = gp.g, c = gp.c, gap = gp }
  end
  -- straight runs: consecutive cells of a row with the same ground
  local rows = {}
  for _, e in pairs(cells) do rows[#rows + 1] = e end
  table.sort(rows, function(p, q) if p.y ~= q.y then return p.y < q.y end return p.x < q.x end)
  local i = 1
  while i <= #rows do
    local j = i
    while j + 1 <= #rows and rows[j + 1].y == rows[i].y and rows[j + 1].x == rows[j].x + 1
        and rows[j + 1].g == rows[i].g do j = j + 1 end
    self:straightRun(rows, i, j)
    i = j + 1
  end
  for _, ch in ipairs(self.chains) do self:slantedChain(ch) end
end

local function cellsNeighbour(rows, k, sd)
  local e = rows[k]
  local n = rows[k + sd]
  if n and n.y == e.y and n.x == e.x + sd then return n end
  return nil
end
-- one straight run of the 4th wall: rows[i..j] (same row y, same ground g)
function Ctx:straightRun(rows, i, j)
  local ins, WH = self.ins, self.WH
  local y, g = rows[i].y, rows[i].g
  local zp = y + 1 - ins
  local grp = self:group("wall", M.plane(0, -1, 0, zp))
  grp.x0, grp.x1, grp.z0, grp.z1 = rows[i].x, rows[j].x + 1, zp, y + 1
  grp.run = { y = y, a = rows[i].x, b = rows[j].x, g = g }
  local sx, sy, sz = self:shadeN(0, -1)
  local cap = self:capUv()
  local L = grp.list
  local capA, capB -- the cap spans each stretch of wall cells (split at gaps:
  -- a door slot's head wall is the Doors module's, with its own cap)
  -- (repair1) the wallpaper too: ONE paper call per stretch (the same tile
  -- pieces for tiers A / C; one quad per band for tier B's single texel
  -- column, see Ctx:paper -- the shell budget)
  local function flushCap()
    if capA then self:paper(L, capB, zp, capA, zp, g, g, g + WH, M.sOf(0, -1, capB, zp), sx, sy, sz) end
    if cap and capA then
      -- (repair1, resumed: seam backstop, third person) emitted after the
      -- fillers (Ctx:emitCaps), split where another top has a corner on
      -- its back edge
      local P = self.pendingCaps
      if not P then P = {}; self.pendingCaps = P end
      P[#P + 1] = { L = L, xa = capA, xb = capB, z0 = zp, z1 = y + 1, y = g + WH, r = cap }
    end
    capA, capB = nil, nil
  end
  -- (repair2, skeptic-visual-r2 N2) a fall hole on the south edge keeps the
  -- 4th wall (Mansion 3F: 26% of the view south was background): the hole
  -- is floor art, the room's wall still stands beyond it
  local holeWalls = self:opt("INTERIORS_HOLE_WALLS")
  local function walled(kd) return kd == "plain" or kd == "filler" or kd == "wall" or (holeWalls and kd == "hole") end
  for k = i, j do
    local e = rows[k]
    local kind = e.gap and e.gap.kind or "plain"
    local x0, x1 = e.x + 0.0, e.x + 1.0
    local oW, oE = self:open(e.x - 1, e.y), self:open(e.x + 1, e.y)
    local cW = not oW and self:concave(e.x - 1, e.y, e.x - 1, e.y + 1)
    local cE = not oE and self:concave(e.x + 1, e.y, e.x + 1, e.y + 1)
    if oW then x0 = x0 + ins elseif cW then x0 = x0 - ins end
    if oE then x1 = x1 - ins elseif cE then x1 = x1 + ins end
    if walled(kind) then
      capA = capA and mmin(capA, x0) or x0
      capB = capB and mmax(capB, x1) or x1
      -- (repair2) the wall's ends against a cell-edge face (see endReturn)
      if not oW then self:endReturn(L, cW, e.x - 1, e.y, e.x - 1, e.y + 1, x0, zp, x0, y + 1, -1, 0, g) end
      if not oE then self:endReturn(L, cE, e.x + 1, e.y, e.x + 1, e.y + 1, x1, zp, x1, y + 1, 1, 0, g) end
    else
      flushCap()
      if kind == "hole" then self:drop(L, e.c, "down", g) end
    end
    -- close the slab's open end beside a gap (exit / hole) with a dark jamb
    if walled(kind) then
      for _, sd in ipairs({ -1, 1 }) do
        local nb = cellsNeighbour(rows, k, sd)
        local nk = nb and nb.gap and nb.gap.kind
        if nk == "hole" and not walled(nk) then self:jamb(L, sd < 0 and x0 or x1, zp, y + 1, g, g + WH, sd) end
      end
    end
  end
  flushCap()
  -- (repair1, resumed: seam backstop) the next cell of this row is the start
  -- of a run on ANOTHER ground (Silph 9F row 18 alternates 1.0 / 0.75): the
  -- two slabs share the edge x = xe with different band vertices (coplanar
  -- T-junctions: 1-pixel cracks with nothing behind the 4th wall) and the
  -- higher slab's end stands open above the lower slab's cap. A strip of
  -- wallpaper behind the seam (inside the slab depth) and a cap-coloured
  -- step face on the end close both; only a crack ever shows them.
  local e, n = rows[j], rows[j + 1]
  local function plainKind(q) return walled(q.gap and q.gap.kind or "plain") end
  if n and n.y == e.y and n.x == e.x + 1 and n.g ~= e.g and plainKind(e) and plainKind(n) then
    local xe = e.x + 1.0
    local gLo, gHi = mmin(e.g, n.g), mmax(e.g, n.g)
    local zb = zp + 0.02 -- (the nearest parallel spacing the shell already uses)
    self:paper(L, xe + 0.5, zb, xe - 0.5, zb, gLo, gLo, gHi + WH, M.sOf(0, -1, xe + 0.5, zb), sx, sy, sz)
    if cap then
      -- the higher slab's end: faces the lower side (+x when this run is higher)
      local r = cap
      if g > n.g then
        local qx, qy, qz = self:shadeN(1, 0) -- (C5 wall-shade parity)
        self:vquad(L, xe, zp, xe, y + 1, gLo + WH, gHi + WH, r[1], r[3], r[2], r[4], qx, qy, qz)
      else
        local qx, qy, qz = self:shadeN(-1, 0)
        self:vquad(L, xe, y + 1, xe, zp, gLo + WH, gHi + WH, r[1], r[3], r[2], r[4], qx, qy, qz)
      end
    end
    self.stats.runSeams = (self.stats.runSeams or 0) + 1
  end
  self.stats.segments = self.stats.segments + 1
end
-- (repair1, resumed: seam backstop, third person) the 4th wall's caps, after
-- the fillers: where a top of the same height beyond the wall (an alcove's
-- side slab, a filler, a wall row) has a corner ON a cap's back edge, the cap
-- is split there -- that corner was a coplanar T-junction whose crack showed
-- the background from above (third person draws no ceiling). Elsewhere one
-- quad per stretch, as before.
function Ctx:emitCaps()
  local P = self.pendingCaps or {}
  self.pendingCaps = {}
  -- only a cap with a map cell beyond it can meet another top: collect
  -- those lines (height, z), then ONE pass over the base list and the wall
  -- groups for the corners on them (JIT-off build time)
  local need, needY, any = {}, {}, false
  for _, c in ipairs(P) do
    for x = mfloor(c.xa), math.ceil(c.xb) - 1 do
      if self:at(x, c.z1) then
        c.check = true
        local hy = mfloor(c.y * 1e4 + 0.5)
        need[hy * 1e6 + mfloor(c.z1 * 1e2 + 0.5)] = {}
        needY[hy] = true
        any = true
        break
      end
    end
  end
  if any then
    -- (the tops of the mesher's walls and the side slabs come from the wall
    -- pass on: the base list from the mark bind set)
    -- (repair2, JIT-off time) a plain range test first: almost every
    -- triangle is nowhere near a cap height (no floor call for those)
    local yLo, yHi = math.huge, -math.huge
    for hy in pairs(needY) do
      local yy = hy / 1e4
      if yy < yLo then yLo = yy end
      if yy > yHi then yHi = yy end
    end
    yLo, yHi = yLo - 1e-4, yHi + 1e-4
    local function scan(L, i0)
      for i = i0, #L - 2, 3 do
        local va = L[i]
        local vy = va[2]
        local hy = (vy >= yLo and vy <= yHi) and mfloor(vy * 1e4 + 0.5) or nil
        if hy and needY[hy] then
          local vb, vc = L[i + 1], L[i + 2]
          if mabs(vb[2] - va[2]) < 1e-6 and mabs(vc[2] - va[2]) < 1e-6 then
            local hk = hy * 1e6
            for q = 0, 2 do
              local v = L[i + q]
              local t = need[hk + mfloor(v[3] * 1e2 + 0.5)]
              if t and mabs(v[3] * 1e2 - mfloor(v[3] * 1e2 + 0.5)) < 1e-4 then t[#t + 1] = v[1] end
            end
          end
        end
      end
    end
    local m0 = self.opaqueMark or 0
    scan(self.env.opaque, m0 - m0 % 3 + 1)
    for _, gr in ipairs(self.groups) do if WALL_KINDS[gr.kind] then scan(gr.list, 1) end end
  end
  for _, c in ipairs(P) do
    local xa = c.xa
    if c.check then
      local xs = {}
      for _, x in ipairs(need[mfloor(c.y * 1e4 + 0.5) * 1e6 + mfloor(c.z1 * 1e2 + 0.5)]) do
        if x > c.xa + 1e-6 and x < c.xb - 1e-6 then xs[#xs + 1] = x end
      end
      table.sort(xs)
      local last = nil
      for _, x in ipairs(xs) do
        if not last or x > last + 1e-5 then
          self:hquad(c.L, xa, c.z0, x, c.z1, c.y, c.r)
          xa, last = x, x
          self.stats.capSplits = (self.stats.capSplits or 0) + 1
        end
      end
    end
    self:hquad(c.L, xa, c.z0, c.xb, c.z1, c.y, c.r)
  end
end
-- a dark jamb closing the slab end at x = xe (sd = -1: the slab's west end)
function Ctx:jamb(list, xe, za, zb, y0, y1, sd)
  local r = self.darkUv
  if not r then return end
  -- the face looks toward the gap: west end -> normal -x
  if sd < 0 then self:vquad(list, xe, za, xe, zb, y0, y1, r[1], r[3], r[2], r[4], -1, 0, 0)
  else self:vquad(list, xe, zb, xe, za, y0, y1, r[1], r[3], r[2], r[4], 1, 0, 0) end
end

-- slanted 4th-wall segments along one staircase chain
function Ctx:slantedChain(ch)
  local ins, WH, g = self.ins, self.WH, ch.g
  local R, K = ch.runs, #ch.runs
  local P, Pr, Cc = {}, {}, {}
  for k = 1, K do
    local r = R[k]
    if ch.dir == "desc" then
      Pr[k] = { r.a, r.y + 1 }
      local ox = self:open(r.a - 1, r.y) and ins or 0
      P[k] = { r.a + ox, r.y + 1 - ins }
      if k < K then Cc[k] = { R[k + 1].a, r.y + 1 } end
    else
      Pr[k] = { r.b + 1, r.y + 1 }
      local ox = self:open(r.b + 1, r.y) and ins or 0
      P[k] = { r.b + 1 - ox, r.y + 1 - ins }
      if k < K then Cc[k] = { R[k + 1].b + 1, r.y + 1 } end
    end
  end
  -- u continues from the straight run at the chain's last corner P[K]
  -- (s = -x there); segments walked from the last one back
  local sx, sy, sz = self:shadeN(0, -1)
  local cap = self:capUv()
  local fr = self.floorMid and self.env.underRect(self.floorMid)
  local sAcc = -P[K][1]
  for k = K - 1, 1, -1 do
    local A, B
    if ch.dir == "desc" then A, B = P[k + 1], P[k] else A, B = P[k], P[k + 1] end
    local dx, dz = B[1] - A[1], B[2] - A[2]
    local len = msqrt(dx * dx + dz * dz)
    local nx, nz = -dz / len, dx / len
    local grp = self:group("wall", M.plane(nx, nz, A[1], A[2]))
    grp.slanted = true
    grp.x0, grp.x1 = mmin(A[1], B[1]), mmax(A[1], B[1])
    grp.z0, grp.z1 = mmin(A[2], B[2]), mmax(A[2], B[2])
    local s0
    if ch.dir == "desc" then s0 = sAcc; sAcc = sAcc + len else sAcc = sAcc - len; s0 = sAcc end
    local tx, ty, tz = sx, sy, sz
    if self:opt("INTERIORS_WALL_SHADE") == "true" then tx, ty, tz = nx, 0, nz end
    self:paper(grp.list, A[1], A[2], B[1], B[2], g, g, g + WH, s0, tx, ty, tz)
    -- (no cap: a slanted segment is one plane, nothing to close on top;
    -- a cap to the raw corners would overlap the W / E slabs' caps)
    -- the floor between the stair-step edge and the wall
    if fr then self:floorFill(grp.list, { Pr[k], Cc[k], Pr[k + 1] }, g, fr) end
    self.fills[#self.fills + 1] = { poly = { Pr[k], Cc[k], Pr[k + 1] }, g = g, group = grp }
    self.stats.segments = self.stats.segments + 1
    self.stats.slanted = self.stats.slanted + 1
  end
end
-- a flat polygon (fan) at height y with one UV rect sampled at its centre (a
-- solid colour: caps)
function Ctx:fan(list, poly, y, r)
  local newV = self:newVfn()
  local u, v = (r[1] + r[3]) * 0.5, (r[2] + r[4]) * 0.5
  local vs = {}
  for i, p in ipairs(poly) do vs[i] = newV(p[1], y, p[2], u, v, 0, 1, 0) end
  for i = 2, #vs - 1 do self:tri(list, vs[1], vs[i], vs[i + 1]) end
end
-- clip a convex polygon {{x, z}, ...} to the half-plane f(p) >= 0
local function clipHalf(poly, f)
  local out = {}
  for i = 1, #poly do
    local p, q = poly[i], poly[i % #poly + 1]
    local fp, fq = f(p), f(q)
    if fp >= 0 then out[#out + 1] = p end
    if (fp >= 0) ~= (fq >= 0) then
      local t = fp / (fp - fq)
      out[#out + 1] = { p[1] + (q[1] - p[1]) * t, p[2] + (q[2] - p[2]) * t }
    end
  end
  return out
end
M.clipHalf = clipHalf
-- a floor polygon at height g, the floor tile planar per cell (clipped to
-- the cells it crosses: the atlas cannot wrap)
function Ctx:floorFill(list, poly, g, r)
  local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
  for _, p in ipairs(poly) do
    minX, maxX = mmin(minX, p[1]), mmax(maxX, p[1])
    minZ, maxZ = mmin(minZ, p[2]), mmax(maxZ, p[2])
  end
  local newV = self:newVfn()
  for cx = mfloor(minX + 1e-9), math.ceil(maxX - 1e-9) - 1 do
    for cz = mfloor(minZ + 1e-9), math.ceil(maxZ - 1e-9) - 1 do
      local q = poly
      q = clipHalf(q, function(p) return p[1] - cx end)
      if #q >= 3 then q = clipHalf(q, function(p) return cx + 1 - p[1] end) end
      if #q >= 3 then q = clipHalf(q, function(p) return p[2] - cz end) end
      if #q >= 3 then q = clipHalf(q, function(p) return cz + 1 - p[2] end) end
      if #q >= 3 then
        local vs = {}
        for i, p in ipairs(q) do
          vs[i] = newV(p[1], g, p[2], r[1] + (r[3] - r[1]) * (p[1] - cx), r[2] + (r[4] - r[2]) * (p[2] - cz), 0, 1, 0)
        end
        for i = 2, #vs - 1 do self:tri(list, vs[1], vs[i], vs[i + 1]) end
        self.stats.fillTris = self.stats.fillTris + #vs - 2
      end
    end
  end
end

-- ---------------------------------------------------------------------------
-- exits: door slots (gap doors on void / exit-frame edges; face doors on a
-- wall run in the warp direction)
-- ---------------------------------------------------------------------------
function Ctx:findExits()
  local slots = {}
  -- gap exits (recorded by the mesher's wall pass)
  local ex = {}
  for _, gp in ipairs(self.gaps) do if gp.kind == "exit" then ex[#ex + 1] = gp end end
  -- face exits: a walkable arrow warp whose neighbour in the arrow direction is a wall cell
  for _, c in ipairs(self:doorCells()) do
    local d = c.role == nil and ARROW[c.beh or -1] and self:exitSide(c)
    if d then
      local x, y = c.x, c.y
      local nb = self:at(x + DXY[d][1], y + DXY[d][2])
      if nb and nb.role == "wall" then ex[#ex + 1] = { c = c, x = x, y = y, g = c.hgt, d = d, kind = "exit", face = true } end
    end
  end
  -- runs of exit cells along the same face (same side, adjacent, same ground and kind)
  table.sort(ex, function(p, q)
    if p.d ~= q.d then return p.d < q.d end
    if (p.face and 1 or 0) ~= (q.face and 1 or 0) then return (p.face and 1 or 0) < (q.face and 1 or 0) end
    if p.d == "left" or p.d == "right" then if p.x ~= q.x then return p.x < q.x end return p.y < q.y end
    if p.y ~= q.y then return p.y < q.y end
    return p.x < q.x
  end)
  local i = 1
  while i <= #ex do
    local j = i
    local horiz = ex[i].d == "up" or ex[i].d == "down"
    while j + 1 <= #ex do
      local p, q = ex[j], ex[j + 1]
      local adj = q.d == p.d and (q.face and true or false) == (p.face and true or false) and q.g == p.g and q.c.beh == p.c.beh
        and ((horiz and q.y == p.y and q.x == p.x + 1) or (not horiz and q.x == p.x and q.y == p.y + 1))
      if not adj then break end
      j = j + 1
    end
    slots[#slots + 1] = self:makeSlot(ex, i, j)
    i = j + 1
  end
  self.doors = slots
  self.stats.exits = #slots
  for _, s in ipairs(slots) do if s.kind == "face" then self.stats.faceExits = self.stats.faceExits + 1 end end
end

-- a door slot: the opening on the wall plane (see API.md)
function Ctx:makeSlot(ex, i, j)
  local a, b = ex[i], ex[j]
  local d, ins = a.d, self.ins
  local cells = {}
  for k = i, j do cells[#cells + 1] = { x = ex[k].x, y = ex[k].y } end
  local s = { face = FACE[d], side = d, kind = a.face and "face" or "gap", cells = cells, g = a.g, h = self.WH,
    warp = { x = a.x, y = a.y, beh = a.c.beh, x1 = b.x, y1 = b.y }, list = "opaque" }
  -- the plane: gap doors on the synthetic-wall inset plane; face doors on
  -- the wall run's face (the cell edge)
  local off = a.face and 0 or ins
  if d == "down" then
    s.z = a.y + 1 - off; s.x0, s.x1 = a.x, b.x + 1; s.plane = M.plane(0, -1, 0, s.z)
    if not a.face and not self.openAir then s.list = "roomShell" end
  elseif d == "up" then
    s.z = a.y + off; s.x0, s.x1 = a.x, b.x + 1; s.plane = M.plane(0, 1, 0, s.z)
  elseif d == "left" then
    s.x = a.x + off; s.z0, s.z1 = a.y, b.y + 1; s.plane = M.plane(1, 0, s.x, 0)
  else
    s.x = a.x + 1 - off; s.z0, s.z1 = a.y, b.y + 1; s.plane = M.plane(-1, 0, s.x, 0)
  end
  s.width = #cells
  return s
end

-- the section's door style for a slot ("wallpaper" by default; DESIGN 1.4)
function Ctx:doorStyle(slot)
  local sec = self.sec
  if sec and type(sec.doorStyle) == "function" then
    local ok, v = pcall(sec.doorStyle, self, slot)
    if ok and type(v) == "string" then return v end
  end
  return "wallpaper"
end

-- slots the Doors module did not build: the opening stays (phase-1
-- behaviour), with dark jambs closing the neighbouring wall slabs' open ends
-- beside it (else a grazing ray slips past the slab end into the exit
-- frame: T1 found them at the gatehouse and corridor side exits)
function Ctx:doorFallback()
  local ins, WH = self.ins, self.WH
  local b = self:buffer("opaque")
  for _, s in ipairs(self.doors) do
    if not s.built and s.kind == "gap" and not (s.side == "down" and self.openAir) then
      local y0, y1 = s.g, s.g + WH
      if s.side == "down" or s.side == "up" then
        local row = s.cells[1].y
        local fy = s.side == "down" and row + 1 or row - 1
        local L = b
        if s.side == "down" and s.list == "roomShell" then L = self:group("wall", s.plane, "core").list end
        local za, zb
        if s.side == "down" then za, zb = row + 1 - ins, row + 1 else za, zb = row, row + ins end
        for _, sd in ipairs({ -1, 1 }) do
          local nx = sd < 0 and s.x0 - 1 or s.x1
          local nb = self:at(nx, row)
          if nb and floorLevel(nb) and not nb.isDoor and self:open(nx, fy) then
            self:jamb(L, sd < 0 and s.x0 or s.x1, za, zb, y0, y1, -sd)
          end
        end
      else
        local col = s.cells[1].x
        local fx = s.side == "left" and col - 1 or col + 1
        local xa, xb
        if s.side == "left" then xa, xb = col, col + ins else xa, xb = col + 1 - ins, col + 1 end
        for _, sd in ipairs({ -1, 1 }) do
          local nz = sd < 0 and s.z0 - 1 or s.z1
          local nb = self:at(col, nz)
          if nb and floorLevel(nb) and not nb.isDoor and self:open(fx, nz) then
            self:jambZ(b, sd < 0 and s.z0 or s.z1, xa, xb, y0, y1, -sd)
          end
        end
      end
      s.fallback = true
    end
  end
  self:commit(b)
end
-- a dark jamb at z = ze across x = xa..xb, facing +z (nz = 1) or -z
function Ctx:jambZ(list, ze, xa, xb, y0, y1, nz)
  local r = self.darkUv
  if not r then return end
  if nz > 0 then self:vquad(list, xa, ze, xb, ze, y0, y1, r[1], r[3], r[2], r[4], 0, 0, 1)
  else self:vquad(list, xb, ze, xa, ze, y0, y1, r[1], r[3], r[2], r[4], 0, 0, -1) end
end

-- ---------------------------------------------------------------------------
-- (repair1) HIDDEN FACES: faces the mesher never draws because it assumes
-- the neighbour hides them, but the interiors build exposes (opaque):
--   (a) beside a slanted wall cell (the mesher's diagOf: its front part is
--       floor): a furniture box's side face and a wall run's face toward it
--       were skipped ("neighbour is a wall"); the lowered real-life counters
--       of every PC 1F / Mart now show the pit behind (skeptic-visual FAIL 1)
--   (b) on an edge the slanted 4th wall absorbed (void beyond, the chain's
--       floor fill in front): a furniture box's side face was skipped
--       ("neighbour is void") -- the Pokemon Tower 1F counter ends
--   (c) SKIRTS (GY-7): a cell lower than a neighbouring wall run (the
--       Cerulean Gym porthole notches, 0.25 below the 0.75 wall) -- the wall
--       face starts at the wall's own ground; it continues down to the cell's
-- Only the exposed part of an edge (clipped to the slanted wall's front) is
-- drawn; box faces use exactly the mesher's side strips / heights; wall
-- faces the room's wallpaper (world-anchored, parity shading).
-- ---------------------------------------------------------------------------
-- the edge of cell (x, y) on side d as the mesher's faceQuad draws it: a -> b
-- (the tile's left edge at a, seen from outside the cell), outward normal
local function cellEdge(x, y, d)
  local x0, z0, x1, z1 = x + 0.0, y + 0.0, x + 1.0, y + 1.0
  if d == "down" then return x0, z1, x1, z1, 0, 1 end
  if d == "up" then return x1, z0, x0, z0, 0, -1 end
  if d == "left" then return x0, z0, x0, z1, -1, 0 end
  return x1, z1, x1, z0, 1, 0
end
M.cellEdge = cellEdge
-- the part t0..t1 of a -> b in front of slanted wall dg (its floor side), or nil
local function frontPart(dg, ax, az, bx, bz)
  local nn, px, pz = dg[5], dg[6], dg[7]
  if not (nn and px and pz) then return nil end
  local fa = (ax - px) * nn[1] + (az - pz) * nn[3]
  local fb = (bx - px) * nn[1] + (bz - pz) * nn[3]
  local E = 1e-9
  if fa >= -E and fb >= -E then return 0, 1 end
  if fa < E and fb < E then return nil end
  local t = fa / (fa - fb)
  if fa > 0 then return 0, t end
  return t, 1
end
M.frontPart = frontPart

function Ctx:patchHiddenFaces()
  local env, C = self.env, self.C
  local diagOf = self.diagOf
  local b = self:buffer("opaque")
  local ST = (C.WALL_STRIP_TEXELS or 3) / 16
  local WH = self.WH
  local st = { box = 0, wall = 0, abs = 0, skirt = 0 }
  self.stats.hiddenFaces = st
  local hidden = self:opt("INTERIORS_HIDDEN_FACES")
  -- 1-cell groups may be the mesher's cylinder bins (drawn round, no box):
  -- their lid centre vertex (x + .5, g + h, y + .5, normal up) marks them
  local bins
  local function isBin(p)
    if not bins then
      bins = {}
      local L = env.opaque
      for i = 1, #L do
        local v = L[i]
        if v[7] == 1 and v[1] % 1 == 0.5 and v[3] % 1 == 0.5 then bins[key(v[1] - 0.5, v[3] - 0.5) * 8 + 1] = v[2] end
      end
    end
    local y = bins[key(p.x, p.y) * 8 + 1]
    return y ~= nil and p.group and mabs(y - ((p.hgt or 0) + (p.group.h or 0))) < 1e-6
  end
  local function boxCell(p)
    local grp = p and p.role == "furniture" and p.group
    if not grp or grp.pillar or grp.slot then return nil end
    if #grp.cells == 1 and isBin(p) then return nil end
    return grp
  end
  -- a furniture box face of cell p on side d over t0..t1 of the edge
  local function boxFace(p, grp, d, t0, t1, low)
    local r = env.underRect(p.mid)
    if not r then return end
    local uv
    if d == "down" then uv = (p.frontMid and env.underRect(p.frontMid)) or r
    elseif d == "up" then uv = env.subRect(r, 0, 0, 1, ST)
    elseif d == "left" then uv = env.subRect(r, 0, 0, ST, 1)
    else uv = env.subRect(r, 1 - ST, 0, 1, 1) end
    local g = p.hgt or 0
    local top = g + (grp.h or 0)
    if top <= low + 1e-9 then return end
    local ax, az, bx, bz, nx, nz = cellEdge(p.x, p.y, d)
    local du = uv[3] - uv[1]
    local q = { uv[1] + du * t0, uv[2], uv[1] + du * t1, uv[4] } -- (wallQuad: u[1] at a, v[2] at the top)
    local Ax, Az = ax + (bx - ax) * t0, az + (bz - az) * t0
    local Bx, Bz = ax + (bx - ax) * t1, az + (bz - az) * t1
    env.wallQuad(b, Ax, Az, Bx, Bz, low, top, q, { nx, 0, nz })
    st.box = st.box + 1
  end
  -- a wall run's face (cell w, side d) over t0..t1: the room's wallpaper
  local function wallFace(w, d, t0, t1, y0, y1)
    local ax, az, bx, bz, nx, nz = cellEdge(w.x, w.y, d)
    local Ax, Az = ax + (bx - ax) * t0, az + (bz - az) * t0
    local Bx, Bz = ax + (bx - ax) * t1, az + (bz - az) * t1
    local sx, sy, sz = self:shadeN(nx, nz)
    self:paper(b, Ax, Az, Bx, Bz, w.hgt or 0, y0, y1, M.sOf(nx, nz, Ax, Az), sx, sy, sz)
  end
  -- (a) beside slanted wall cells (grid order: deterministic)
  if hidden and type(diagOf) == "table" then
    local dl = {}
    for n, dg in pairs(diagOf) do
      if type(n) == "table" and n.x and type(dg) == "table" then dl[#dl + 1] = n end
    end
    table.sort(dl, function(p, q) if p.y ~= q.y then return p.y < q.y end return p.x < q.x end)
    for _, n in ipairs(dl) do
      local dg = diagOf[n]
      for _, dd in ipairs(DIRS) do
        -- p's side dd faces n
        local p = self:at(n.x - dd.dx, n.y - dd.dy)
        if p and not diagOf[p] then
          local ax, az, bx, bz = cellEdge(p.x, p.y, dd.name)
          local t0, t1 = frontPart(dg, ax, az, bx, bz)
          if t0 and t1 - t0 > 1e-6 then
            local grp = boxCell(p)
            if grp then
              boxFace(p, grp, dd.name, t0, t1, mmin(n.hgt or 0, p.hgt or 0))
            elseif p.role == "wall" then
              local g = p.hgt or 0
              wallFace(p, dd.name, t0, t1, g, g + WH)
              st.wall = st.wall + 1
            end
          end
        end
      end
    end
  end
  -- (b) absorbed stair-step edges of furniture cells (void beyond): only
  -- the absorbed cells (sorted: a deterministic order)
  if hidden and (next(self.absSouth or {}) or next(self.fin or {})) then
    local ks, seen = {}, {}
    for k in pairs(self.absSouth) do if not seen[k] then seen[k] = true; ks[#ks + 1] = k end end
    for k4 in pairs(self.fin) do local k = mfloor(k4 / 4); if not seen[k] then seen[k] = true; ks[#ks + 1] = k end end
    table.sort(ks)
    for _, k in ipairs(ks) do
      local x, y = k % 65536, mfloor(k / 65536)
      local p = self:at(x, y)
      local grp = p and boxCell(p)
      if grp then
        if self.absSouth[k] and not self:at(x, y + 1) then boxFace(p, grp, "down", 0, 1, p.hgt or 0); st.abs = st.abs + 1 end
        if self.fin[k * 4 + 1] and not self:at(x - 1, y) then boxFace(p, grp, "left", 0, 1, p.hgt or 0); st.abs = st.abs + 1 end
        if self.fin[k * 4 + 2] and not self:at(x + 1, y) then boxFace(p, grp, "right", 0, 1, p.hgt or 0); st.abs = st.abs + 1 end
      end
    end
  end
  -- (c) skirts: a floor-level, non-box cell lower than a straight wall run
  -- beside it (not on open-air maps: the S.S. Anne sea is the section's);
  -- one quick pass first: nothing to do unless some such cell is lower than
  -- the highest wall run
  -- (one pass for the quick tests of (c) and (d): the wall runs' lowest /
  -- highest ground, the lowest plain floor)
  local skirts = self:opt("INTERIORS_SKIRTS") and not self.openAir
  local steps = self:opt("INTERIORS_WALL_STEPS") ~= false
  local wallMin, wallMax, floorMin = math.huge, -math.huge, math.huge
  if skirts or steps then
    local grid, W, H = self.grid, self.W, self.H
    for y = 0, H - 1 do
      local row = grid[y]
      for x = 0, W - 1 do
        local p = row[x]
        if p then
          local g = p.hgt or 0
          if p.role == "wall" then
            if g > wallMax then wallMax = g end
            if g < wallMin then wallMin = g end
          elseif not p.exitFrame and p.role ~= "furniture" and p.role ~= "ext" and g < floorMin then floorMin = g end
        end
      end
    end
  end
  if skirts then
    local W, H = self.W, self.H
    if floorMin < wallMax - 1e-6 then
      for y = 0, H - 1 do
        for x = 0, W - 1 do
          local p = self:at(x, y)
          if p and floorLevel(p) and p.role ~= "furniture" and p.role ~= "ext" and (p.hgt or 0) < wallMax - 1e-6 then
            for _, dd in ipairs(DIRS) do
              local w = self:at(x + dd.dx, y + dd.dy)
              if w and w.role == "wall" and not (diagOf and diagOf[w]) and (w.hgt or 0) > (p.hgt or 0) + 1e-6 then
                -- the wall's face toward p: p's edge seen from p (normal into p)
                local ax, az, bx, bz, nx, nz = cellEdge(x, y, dd.name)
                local sx, sy, sz = self:shadeN(-nx, -nz)
                self:paper(b, bx, bz, ax, az, p.hgt or 0, p.hgt or 0, w.hgt or 0, M.sOf(-nx, -nz, bx, bz), sx, sy, sz)
                st.skirt = st.skirt + 1
              end
            end
          end
        end
      end
    end
  end
  -- (d) (repair2, skeptic-visual-r2 N3) WALL-TOP STEPS: two wall runs side by
  -- side on different grounds (Silph 8F's x = 18 partition: 1.0 beside 0.75)
  -- -- the mesher draws a wall's faces only toward non-wall cells, so the step
  -- between the two tops (0.25) stood open onto the background from above
  -- (3/4 view, third person: 1,373 px on Silph 8F, module off too). A face on
  -- the shared edge from the lower top to the higher, the room's cap colour.
  if steps then
    local W, H = self.W, self.H
    local cap = wallMax > wallMin + 1e-6 and self:capUv() or nil
    if cap then
      st.step = 0
      for y = 0, H - 1 do
        for x = 0, W - 1 do
          local w = self:at(x, y)
          if w and w.role == "wall" and not (diagOf and diagOf[w]) then
            local gw = w.hgt or 0
            for _, dd in ipairs(DIRS) do
              local n = self:at(x + dd.dx, y + dd.dy)
              if n and n.role == "wall" and (n.hgt or 0) < gw - 1e-6 and not (diagOf and diagOf[n]) then
                -- w's edge toward n, seen from n (normal into n)
                local ax, az, bx, bz, nx, nz = cellEdge(x, y, dd.name)
                local sx, sy, sz = self:shadeN(nx, nz)
                local prev = self.owner
                self.owner = "wallStep" -- (the DEBUG vertex tag only)
                self:vquad(b, ax, az, bx, bz, (n.hgt or 0) + WH, gw + WH, cap[1], cap[3], cap[2], cap[4], sx, sy, sz)
                self.owner = prev
                st.step = st.step + 1
              end
            end
          end
        end
      end
    end
  end
end

-- claimed cells whose props failed: a plain box of the cell's own art
function Ctx:claimFallback(owner) -- props (build/props/CORE_HOOK.md): owner filter
  local b = self:buffer("opaque")
  local env = self.env
  for _, p in ipairs(self.claims) do
    local r = env.underRect(p.mid)
    if r and (owner == nil or (p.claimOwner or "section") == owner) then
      local g, h = p.hgt or 0, p.claimH or 0.7
      local x0, z0, x1, z1 = p.x + 0.0, p.y + 0.0, p.x + 1.0, p.y + 1.0
      self:hquad(b, x0, z0, x1, z1, g + h, r)
      self:vquad(b, x0, z1, x1, z1, g, g + h, r[1], r[3], r[2], r[4], 0, 0, 1)
      self:vquad(b, x1, z0, x0, z0, g, g + h, r[1], r[3], r[2], r[4], 0, 0, -1)
      self:vquad(b, x0, z0, x0, z1, g, g + h, r[1], r[3], r[2], r[4], -1, 0, 0)
      self:vquad(b, x1, z1, x1, z0, g, g + h, r[1], r[3], r[2], r[4], 1, 0, 0)
    end
  end
  self:commit(b)
end

-- ---------------------------------------------------------------------------
-- C5 parity for the mesher's own room-enclosing faces: the inward faces of
-- side-wall cells (wall runs with void W / E) get the back wall's shading
-- normal. Only faces the wall pass emitted (from bind's mark), exactly on
-- that cell edge, with the side-wall normal.
-- ---------------------------------------------------------------------------
function Ctx:parityMesherSides()
  local L = self.env.opaque
  local planes = {}
  local grid = self.grid
  for y = 0, self.H - 1 do
    local row = grid[y]
    for x = 0, self.W - 1 do
      local c = row[x]
      if c and c.role == "wall" and c.side then
        local wn, en = self:at(x - 1, y), self:at(x + 1, y)
        if wn and wn.role ~= "wall" then planes[#planes + 1] = { x = x + 0.0, n = -1, z0 = y, z1 = y + 1, g = c.hgt } end
        if en and en.role ~= "wall" then planes[#planes + 1] = { x = x + 1.0, n = 1, z0 = y, z1 = y + 1, g = c.hgt } end
      end
    end
  end
  if #planes == 0 then return end
  local byX = {}
  for _, p in ipairs(planes) do
    local k = p.x * 4 + (p.n > 0 and 1 or 0)
    byX[k] = byX[k] or {}
    byX[k][#byX[k] + 1] = p
  end
  local WH, n = self.WH, 0
  local done = {}
  -- (repair2: only the mesher's own faces, bind's mark .. finish's start)
  local iEnd = mmin(#L, self.opaqueFinish or #L)
  for i = (self.opaqueMark or 0) + 1, iEnd - 2, 3 do
    local a = L[i]
    local nx = a[6]
    local b, c
    if nx == 1 or nx == -1 then b, c = L[i + 1], L[i + 2] end -- (repair2: the others read one vertex only)
    if b and b[6] == nx and c[6] == nx and a[8] == 0 and a[1] == b[1] and a[1] == c[1] then
      local cand = byX[a[1] * 4 + (nx > 0 and 1 or 0)]
      if cand then
        local zc = (a[3] + b[3] + c[3]) / 3
        local yc = (a[2] + b[2] + c[2]) / 3
        for _, p in ipairs(cand) do
          if zc > p.z0 and zc < p.z1 and yc >= p.g - 1e-6 and yc <= p.g + WH + 1e-6 then
            for _, v in ipairs({ a, b, c }) do
              if not done[v] then done[v] = true; v[6], v[7], v[8] = 0, 0, 1 end
            end
            n = n + 1
            break
          end
        end
      end
    end
  end
  self.stats.parityFaces = n
end

-- ---------------------------------------------------------------------------
-- the mesher's own south walls for recorded cells (the core failed after
-- south() took them): the old geom.southWalls geometry, plain strips
-- ---------------------------------------------------------------------------
function Ctx:fallbackSouth()
  local ok = pcall(function()
    local env = self.env
    local L = env.IN and env.IN.southWalls
    if not L then return end
    local U, Lw = self.plainU0, self.plainL0
    local ins, WH = self.ins, self.WH
    for _, s in ipairs(self.southCells) do
      local x0, x1, z1 = s.x + 0.0, s.x + 1.0, s.y + 1.0
      if self:open(s.x - 1, s.y) then x0 = x0 + ins end
      if self:open(s.x + 1, s.y) then x1 = x1 - ins end
      local z = z1 - ins
      if Lw then env.wallQuad(L, x1, z, x0, z, s.g, s.g + 1.0, Lw, { 0, 0, -1 }) end
      if U then env.wallQuad(L, x1, z, x0, z, s.g + 1.0, s.g + WH, U, { 0, 0, -1 }) end
      local cap = self.darkUv
      if cap then env.hQuad(L, x0, z, x1, z1, s.g + WH, cap) end
    end
    self.southCells = {}
  end)
  return ok
end

-- (repair1, resumed: containment) the W / E fins of the south curve that
-- side() absorbed (the mesher drew nothing for them) get their wall after
-- all when the core fails later: without the slanted 4th wall they were
-- open to the background, more open than module off (Pokemon Tower 1F:
-- 463 escaping rays after a late failure). Same slab as a plain side().
function Ctx:fallbackFins()
  local F = self.finSkips
  if not F or #F == 0 then return true end
  local env = self.env
  local nO, nOv = #env.opaque, #env.over
  local ok = pcall(function()
    for _, s in ipairs(F) do self:slab(env.opaque, env.opaque, s.c, s.d, s.g, env.over) end
  end)
  if not ok then
    for i = #env.opaque, nO + 1, -1 do env.opaque[i] = nil end
    for i = #env.over, nOv + 1, -1 do env.over[i] = nil end
  end
  self.finSkips = {}
  return ok
end

-- (repair1, resumed: containment) a warp pad B2 made floor (it stood as an
-- in-wall door in module off) has door-cell open sides nobody draws once
-- the core fails (Doors / fillers went with it): a wall slab on each, as
-- if the pad were still in the wall (Silph 9F (22,18): 2 escaping rays).
function Ctx:fallbackGaps()
  local G = self.gaps
  if not G or #G == 0 then return true end
  local env = self.env
  local nO, nOv = #env.opaque, #env.over
  local ok = true
  for _, gp in ipairs(G) do
    local p = self:at(gp.x, gp.y)
    if p and p.padFixed then
      -- the core's slab (needs bind); else the mesher's own strips, as
      -- fallbackSouth does
      local okS = self.wp ~= nil and pcall(Ctx.slab, self, env.opaque, env.opaque, gp.c, gp.d, gp.g, env.over)
      if not okS then
        for i = #env.opaque, nO + 1, -1 do env.opaque[i] = nil end
        for i = #env.over, nOv + 1, -1 do env.over[i] = nil end
        okS = pcall(Ctx.plainWall, self, env.opaque, gp.x, gp.y, gp.g, gp.d)
        if not okS then
          for i = #env.opaque, nO + 1, -1 do env.opaque[i] = nil end
          ok = false
        end
      end
      nO, nOv = #env.opaque, #env.over
    end
  end
  return ok
end
-- a plain inset wall on one side of cell (x, y) in the mesher's own strips
-- (lower 1.0 / upper) and the dark cap: the degraded-mode wall
function Ctx:plainWall(L, x, y, g, dname)
  local env, ins, WH = self.env, self.ins, self.WH
  local U, Lw = self.plainU0, self.plainL0
  local x0, z0, x1, z1 = x + 0.0, y + 0.0, x + 1.0, y + 1.0
  local ax, az, bx, bz, nx, nz, cx0, cz0, cx1, cz1
  if dname == "left" then ax, az, bx, bz, nx, nz = x0 + ins, z1, x0 + ins, z0, 1, 0; cx0, cz0, cx1, cz1 = x0, z0, x0 + ins, z1
  elseif dname == "right" then ax, az, bx, bz, nx, nz = x1 - ins, z0, x1 - ins, z1, -1, 0; cx0, cz0, cx1, cz1 = x1 - ins, z0, x1, z1
  elseif dname == "up" then ax, az, bx, bz, nx, nz = x0, z0 + ins, x1, z0 + ins, 0, 1; cx0, cz0, cx1, cz1 = x0, z0, x1, z0 + ins
  else ax, az, bx, bz, nx, nz = x1, z1 - ins, x0, z1 - ins, 0, -1; cx0, cz0, cx1, cz1 = x0, z1 - ins, x1, z1 end
  if Lw then env.wallQuad(L, ax, az, bx, bz, g, g + 1.0, Lw, { nx, 0, nz }) end
  if U then env.wallQuad(L, ax, az, bx, bz, g + 1.0, g + WH, U, { nx, 0, nz }) end
  local cap = self.darkUv
  if cap then env.hQuad(L, cx0, cz0, cx1, cz1, g + WH, cap) end
end

-- ---------------------------------------------------------------------------
-- the shell (contract V2.14)
-- ---------------------------------------------------------------------------
function Ctx:assemble()
  local verts, groups, groupOf = {}, {}, {}
  local order = {}
  for _, g in ipairs(self.groups) do if WALL_KINDS[g.kind] and #g.list > 0 then order[#order + 1] = g end end
  for _, g in ipairs(self.groups) do if CEIL_KINDS[g.kind] and #g.list > 0 then order[#order + 1] = g end end
  local st = self.stats
  local nv = 0
  for _, g in ipairs(order) do
    local first = nv / 3 + 1
    local minX, maxX, minY, maxY, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge, math.huge, -math.huge
    -- (repair2, JIT-off time: numeric loop, locals, no ipairs / # per vertex)
    local L = g.list
    for i = 1, #L do
      local v = L[i]
      nv = nv + 1
      verts[nv] = v
      local x, y, z = v[1], v[2], v[3]
      if x < minX then minX = x end
      if x > maxX then maxX = x end
      if y < minY then minY = y end
      if y > maxY then maxY = y end
      if z < minZ then minZ = z end
      if z > maxZ then maxZ = z end
    end
    local count = #L / 3
    local out = { id = g.id, kind = g.kind, owner = g.owner, nx = g.nx, nz = g.nz, d = g.d, y0 = g.y0,
      x0 = minX, x1 = maxX, y1 = maxY, ymin = minY, z0 = minZ, z1 = maxZ, first = first, count = count,
      slanted = g.slanted or nil }
    groups[#groups + 1] = out
    for t = first, first + count - 1 do groupOf[t] = g.id end
    if g.kind == "wall" or g.kind == "filler" or g.kind == "sill" then st.wallTris = st.wallTris + count
    elseif g.kind == "door" then st.doorTris = st.doorTris + count
    elseif g.kind == "lamp" then st.lampTris = st.lampTris + count
    else st.ceilTris = st.ceilTris + count end
  end
  st.tris = #verts / 3
  for _, s in ipairs(self.doors) do if s.built then st.doors = st.doors + 1 end end
  local P = self.wp or {}
  local shell = {
    verts = verts, groups = groups, groupOf = groupOf, doors = self.doors,
    wallpaper = { tier = P.tier or "C", up = P.up, lo = P.lo, col = P.col, score = P.score, cands = P.cands },
    openAir = self.openAir, section = self.section, W = self.W, H = self.H,
    ceilY = self.ceilY, stats = st, version = M.VERSION,
  }
  if self:opt("INTERIORS_SHELL_TO_OPAQUE") then
    -- DEBUG preview: the shell drawn as ordinary opaque geometry (always
    -- visible) -- only for captures without the renderer patch
    local L = self.env.opaque
    for _, v in ipairs(verts) do L[#L + 1] = v end
    shell.debugInlined = true
  end
  return shell
end

-- ===========================================================================
-- VISIBILITY (reference for the renderer, DESIGN 1.6 + VERIFY_arch 3c)
-- ===========================================================================
-- mode "dollhouse" (3/4 view, table view): nothing of the shell;
-- "halfspace" (first / third person, battle seat): a wall-type group draws
-- while the eye is on the room side of its plane; a ceiling-type group while
-- the eye is below the ceiling over the eye's OWN cell (shell.ceilY), else
-- below the group's own y0 -- so a head rising a few cm on a 1.0-high floor
-- never toggles the lower neighbouring ceiling.
M.MARGIN = DEF.INTERIORS_MARGIN
function M.roomVisible(group, ex, ey, ez, mode, shell)
  if mode == "dollhouse" then return false end
  local k = group.kind
  local m = M.MARGIN
  if WALL_KINDS[k] then
    return group.nx * ex + group.nz * ez + group.d > m
  end
  local y0 = group.y0
  if shell and shell.ceilY and shell.W then
    local cx, cz = mfloor(ex), mfloor(ez)
    if cx >= 0 and cz >= 0 and cx < shell.W and (not shell.H or cz < shell.H) then
      local cy = shell.ceilY[cz * shell.W + cx + 1]
      if cy then y0 = cy end
    end
  end
  return ey < y0 - m
end
-- merged triangle ranges { {first, count}, ... } of the visible groups
-- (groups are contiguous and in shell order)
function M.visibleRanges(shell, vis)
  local out = {}
  for _, g in ipairs(shell.groups) do
    if vis[g.id] then
      local last = out[#out]
      if last and last[1] + last[2] == g.first then last[2] = last[2] + g.count
      else out[#out + 1] = { g.first, g.count } end
    end
  end
  return out
end

return M
