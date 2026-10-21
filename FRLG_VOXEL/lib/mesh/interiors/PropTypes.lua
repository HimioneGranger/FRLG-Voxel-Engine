-- FRLG_VOXEL / interiors team: PropTypes.lua -- the per-type furniture
-- dispatcher (wave 0, 2026-10-01; scout PLAN.md section 2; repair round w0r1,
-- 2026-10-02).
--
-- One module per furniture type, lib/mesh/interiors/props/<Type>.lua, in
-- the order of props/Registry.lua (= cell precedence). The core calls:
--   classify(ctx, loadMod)  inside Ctx:classify, after the core's B1 / B2 /
--                           real-life heights and BEFORE PropFix (hook H6):
--                           each type's match() names the cells it wants,
--                           this file refuses the illegal ones (section 2.4)
--                           and the ones an earlier type took, then runs the
--                           type's classify() as ONE journaled core step with
--                           ctx.owner = "type:<Name>" (its claims carry that
--                           owner; an error rolls the step back and frees the
--                           cells).
--   props(ctx)              inside Ctx:finishImpl, after PropFix props and
--                           before the section props (hook H7): each type's
--                           props() in its own runModule; an error drops its
--                           buffers and boxes ITS claimed cells only
--                           (claimFallback by owner).
--   wallpaperCands(ctx, all) inside Ctx:pickWallpaper (hook H8, w0r1): the
--                           wall runs a type changed keep the candidates they
--                           had before the per-type step (the room's wallpaper
--                           is never re-picked because a type pulled a machine
--                           out of the wall).
-- A missing type file is skipped (loadMod caches it as absent). With no type
-- file present the dispatcher does nothing at all (no index pass): the room
-- is bit-identical to the unhooked core (gate G0).
--
-- w0r1 (review defects D1 / D2, coordinator requests):
--   * one bad type never blocks the others: match() must return a list
--     ("bad match result" otherwise), each entry a cell or { x = int, y = int }
--     ("bad cell" otherwise), and every type is dispatched under its own pcall;
--   * one owner per cell, enforced in the game (not only by the gates): after
--     a type's classify() the step checks the journal -- a cell outside the
--     type's grant may only receive the core helpers' side writes (run / column
--     extents, the leaves' suppressDecal), a furniture group may be changed
--     (height, pillar ...) only if every cell of it is granted, and cells may
--     only LEAVE a group that holds other cells; anything else is an error and
--     the whole type rolls back ("claim / furnish outside its grant");
--     setGround needs T.heightAt = true;
--   * every granted cell, and every group holding one, gets typeOwner =
--     "type:<Name>" (journaled): PropFix (1.1) never targets them;
--   * a host group a type took cells out of (claim / leaveGroup) gets the
--     core's real-life height of its remaining cells (Ctx:realHeightOf) when
--     its height is not fixed -- PropFix's own re-heights then apply as usual.
--
-- w0r4 (review-w1 grant bypass, review-w2 cost; 1.2 / w0r3 was not promoted):
--   * always: the grant is checked against PRIVATE copies taken before
--     classify() (editing ts.cells / ts.cellSet grants nothing); journaled
--     list writes are checked too (a push only onto env.groups / the claims
--     list; env.groups may lose only groups left empty; the claims list is
--     never rewritten); the room's structure -- ctx.grid / env.grid, every
--     row and the cell at every position, the env.groups and claims lists --
--     must not change outside the journal (a cheap identity check), and a
--     failed step puts it back;
--   * strict (INTERIORS_PROPTYPES_STRICT = true; when that is unset, the
--     test / gate builds that set INTERIORS_KEEP_LAST): a plain field write
--     (not through ctx:set) on a cell outside the grant, or on a group that
--     holds one, is an error -- nested plain tables (a group's member list,
--     pillar, boulder ...) are compared too, edits in place included, and NaN
--     equals NaN. ONE snapshot per map, taken before the first type step and
--     refreshed from each successful step's journal and grant; a failed step
--     restores it after the journal's rollback (unjournaled writes undone).
--     Game builds skip this field scan (it cost 1 to 3 ms per map); the types
--     the game ships pass it on every map in the strict gate runs.
--
-- w0r5 (wave-4 repair: Grave G2 / G4, Crate R1, OneOff R1):
--   * PropFix takeovers: a granted wall cell that PropFix's own plan unwalls
--     (PropFix.plan on the room as the type step finds it; the plan is pure
--     and, for a cell still a wall, the same as before the types) is, for
--     the two pre-type snapshots, what PropFix makes of it in a tree without
--     the type -- H8 records no wall run for it (the run's candidates are
--     today's, as after PropFix's unwall), and Ceiling 1.1 does not count it
--     as type-made (Ceiling.propfixMade): wallpaper and lamps equal the
--     PropFix tree. A run that also holds a type cell PropFix does not plan
--     keeps the pre-type candidates as before (st.wpMixed lists such runs).
--     The plan runs only on maps where a type is granted a wall cell;
--   * deferred regroup: the type's classify runs with Ctx:deferRegroup, so a
--     furniture group the type takes many cells out of is regrouped once
--     (flushRegroup, before the grant check), not once per cell; same cells,
--     groups and geometry (Silph 1F fountain: 92 claims from one group).
--
-- State lives in a weak-keyed table per ctx (nothing is written on ctx
-- itself except the core's own owner field around each step, as PropFix does).
-- Type module contract: see TYPE_AGENT_TEMPLATE.md (w0r1) / PLAN.md 2.5.
-- The ts table a type receives: { name, owner = "type:<Name>", cells (granted,
-- row-major as matched), cellSet[cell] = true, lib = { Relief, Kit }, ok,
-- propsOk } -- per-build state of the type goes on ts, never on ctx.
-- No debug / package / io (mod sandbox).
local V = ...
local _ = V

local P = { VERSION = "proptypes 1.4 (2026-10-02)" }

local fmt, mfloor, mabs = string.format, math.floor, math.abs
local ST = setmetatable({}, { __mode = "k" })
-- names that are helpers in props/, never types
P.NOT_TYPES = { Registry = true, Relief = true }

-- ---------------------------------------------------------------------------
-- the shared index: ONE pass over the grid (after B1 / B2 / heights)
--   byBeh[beh]   cells with that behaviour byte (beh > 0)
--   byMid[mid]   cells showing that metatile
--   byRole[role] cells by mesher / core role ("floor" for none)
--   solid        every non-walkable cell
--   all          every present cell (row-major)
-- every list is row-major (y, then x): deterministic
-- ---------------------------------------------------------------------------
local function push(t, k, v)
  local l = t[k]
  if not l then l = {}; t[k] = l end
  l[#l + 1] = v
end
function P.index(ctx)
  local byBeh, byMid, byRole, solid, all = {}, {}, {}, {}, {}
  local grid = ctx.grid
  for y = 0, ctx.H - 1 do
    local row = grid[y]
    for x = 0, ctx.W - 1 do
      local c = row and row[x]
      if c then
        all[#all + 1] = c
        if c.beh and c.beh ~= 0 then push(byBeh, c.beh, c) end
        if c.mid then push(byMid, c.mid, c) end
        push(byRole, c.role or "floor", c)
        if not c.walkable then solid[#solid + 1] = c end
      end
    end
  end
  return { byBeh = byBeh, byMid = byMid, byRole = byRole, solid = solid, all = all,
    mapId = ctx.mapId, pair = ctx.pair, W = ctx.W, H = ctx.H }
end

-- ---------------------------------------------------------------------------
-- legality (PLAN 2.4; never a type's choice): nil = granted, else the reason
-- ---------------------------------------------------------------------------
function P.illegal(ctx, c, T)
  if not c then return "off-map" end
  local env = ctx.env
  local atlas = env.atlas
  if c.mid == nil or (atlas and atlas.isVoid and atlas.isVoid(c.mid)) then return "void" end
  if c.exitFrame then return "exit frame" end
  local MB = env.MB or {}
  if c.isDoor or (c.beh and MB.DOOR and MB.DOOR[c.beh]) then return "door" end
  if c.inWall or c.pocket then return "in-wall" end
  if c.stair or (c.beh and MB.STAIR_WARP and MB.STAIR_WARP[c.beh]) then return "stair" end
  if c.role == "ext" or c.claimOwner then return "claimed" end
  if c.walkable and not T.walkable then return "walkable" end
  if c.role == "wall" and not T.walls then return "wall" end
  return nil
end

-- a match entry -> the grid cell (types may return cells or {x=, y=});
-- nil, why for anything else (w0r1 D1: a fractional / non-number coordinate
-- used to raise inside ctx:at and stop the dispatch of every later type)
local function isInt(v) return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge and mfloor(v) == v end
local function cellOf(ctx, p)
  if type(p) ~= "table" then return nil, "bad cell" end
  if not (isInt(p.x) and isInt(p.y)) then return nil, "bad cell" end
  local c = ctx:at(p.x, p.y)
  if c == nil then return nil, "off-map" end
  return c
end

-- ---------------------------------------------------------------------------
-- the grant check, host re-heights and ownership (inside the type's step)
-- ---------------------------------------------------------------------------
-- writes a type may cause on cells OUTSIDE its grant (the core helpers' side
-- effects: unwall splits the run, leaveGroup / furnish re-extend the column
-- extents, plant hides the leaves' decal)
P.SIDE_KEYS = { runA = true, runB = true, fy0 = true, fy1 = true, suppressDecal = true }
-- writes on a group that holds cells outside the grant (cells may only leave it)
P.GROUP_SIDE_KEYS = { cells = true, minY = true, maxY = true }

local function isCellOf(ctx, t)
  if not (isInt(rawget(t, "x")) and isInt(rawget(t, "y"))) then return false end
  return ctx:at(t.x, t.y) == t
end
local function isGroup(t) return type(rawget(t, "cells")) == "table" end

-- ---------------------------------------------------------------------------
-- (w0r4) the room snapshot, ONE per map (taken before the first type step,
-- refreshed after each successful step): the structure always, every cell's
-- and group's fields in strict builds
-- ---------------------------------------------------------------------------
local function same(a, b) return a == b or (a ~= a and b ~= b) end -- NaN equals NaN
local function listCopy(l)
  if type(l) ~= "table" then return false end
  local o = {}
  for i = 1, #l do o[i] = l[i] end
  return o
end
-- l (a live list) holds exactly the entries of ref (a copy; false = no list)
local function listIs(l, ref)
  if not ref then return type(l) ~= "table" end
  local n = #ref
  for i = 1, n do if l[i] ~= ref[i] then return false end end
  return l[n + 1] == nil
end
-- a table's fields, and nested plain tables (not a cell, not a group: a
-- group's member list, pillar, boulder ...) copied the same way
local function copyOf(ctx, t, seen)
  local o, nest = {}, nil
  for k, v in pairs(t) do
    o[k] = v
    if type(v) == "table" and not seen[v] and not isGroup(v) and not isCellOf(ctx, v) then
      seen[v] = true
      nest = nest or {}
      nest[k] = { v, copyOf(ctx, v, seen) }
    end
  end
  return { o, nest }
end
-- the first field of t (or of a nested table, in place) that differs from
-- its copy E without a journal entry (keys[k]); nil when there is none
local function changed(t, E, keys)
  local old, nest = E[1], E[2]
  for k, v in pairs(t) do
    if not same(old[k], v) and not (keys and keys[k]) then return tostring(k) end
  end
  for k in pairs(old) do
    if rawget(t, k) == nil and not (keys and keys[k]) then return tostring(k) end
  end
  if nest then
    for k, ne in pairs(nest) do
      if rawget(t, k) == ne[1] then
        local sub = changed(ne[1], ne[2], nil)
        if sub then return tostring(k) .. "." .. sub end
      end
    end
  end
  return nil
end
local function putBack(t, E)
  local old, nest = E[1], E[2]
  for k in pairs(t) do if old[k] == nil then t[k] = nil end end
  for k, v in pairs(old) do if not same(t[k], v) then t[k] = v end end
  if nest then for _, ne in pairs(nest) do putBack(ne[1], ne[2]) end end
end
local function putList(l, ref)
  if type(l) ~= "table" or not ref then return end
  for i = #l, #ref + 1, -1 do l[i] = nil end
  for i = 1, #ref do if l[i] ~= ref[i] then l[i] = ref[i] end end
end
local function snapGroups(ctx, s)
  for _, g in ipairs(s.gl or {}) do
    if type(g) == "table" and isGroup(g) and not s.byT[g] then
      s.groups[#s.groups + 1] = g
      s.byT[g] = copyOf(ctx, g, {})
      s.members[g] = listCopy(g.cells)
    end
  end
end
-- fields: also every cell's and group's fields (strict)
function P.snapshot(ctx, fields)
  local env, W, H, grid = ctx.env, ctx.W, ctx.H, ctx.grid
  local s = { grid = grid, envGrid = env.grid, W = W, H = H, rows = {}, at = {},
    groupsList = env.groups, claims = ctx.claims, gl = listCopy(env.groups), cl = listCopy(ctx.claims) }
  local rows, at = s.rows, s.at
  for y = 0, H - 1 do
    local row = grid[y]
    rows[y + 1] = row or false
    for x = 0, W - 1 do at[y * W + x + 1] = (row and row[x]) or false end
  end
  if fields then
    s.byT, s.cells, s.groups, s.members = {}, {}, {}, {}
    for i = 1, W * H do
      local c = at[i]
      if c then s.cells[#s.cells + 1] = c; s.byT[c] = copyOf(ctx, c, {}) end
    end
    snapGroups(ctx, s)
  end
  return s
end
-- after a successful step: what the journal touched, the grant (a type may
-- write its own cells directly), every group, the lists
function P.refresh(ctx, s, J, grantList)
  s.gl, s.cl = listCopy(ctx.env.groups), listCopy(ctx.claims)
  if not s.byT then return end
  local byT, done = s.byT, {}
  for i = 1, (J and J.n or 0) do
    local t = J.e[i][1]
    if byT[t] and not done[t] then done[t] = true; byT[t] = copyOf(ctx, t, {}) end
  end
  for _, c in ipairs(grantList) do
    if byT[c] and not done[c] then done[c] = true; byT[c] = copyOf(ctx, c, {}) end
  end
  for _, g in ipairs(s.groups) do
    if not done[g] then byT[g] = copyOf(ctx, g, {}) end
    s.members[g] = listCopy(rawget(g, "cells"))
  end
  snapGroups(ctx, s)
end
-- after a failed step (the journal already rolled back): the snapshot again
function P.restore(ctx, s)
  local env = ctx.env
  if ctx.grid ~= s.grid then ctx.grid = s.grid end
  if env.grid ~= s.envGrid then env.grid = s.envGrid end
  local grid, W = s.grid, s.W
  for y = 0, s.H - 1 do
    local row = s.rows[y + 1] or nil
    if grid[y] ~= row then grid[y] = row end
    if row then
      for x = 0, W - 1 do
        local c = s.at[y * W + x + 1] or nil
        if row[x] ~= c then row[x] = c end
      end
    end
  end
  if env.groups ~= s.groupsList then env.groups = s.groupsList end
  if ctx.claims ~= s.claims then ctx.claims = s.claims end
  putList(s.groupsList, s.gl)
  putList(s.claims, s.cl)
  if s.byT then
    for _, c in ipairs(s.cells) do putBack(c, s.byT[c]) end
    for _, g in ipairs(s.groups) do putBack(g, s.byT[g]) end
  end
end
-- list (the live list) as it was when the step began: the journal undone on
-- a copy; nil when the list does not fit the journal (each push must undo
-- exactly the one entry it added: an extra entry appended directly shows)
local function listBefore(list, J)
  local o = listCopy(list)
  for i = J.n, 1, -1 do
    local e = J.e[i]
    if e[1] == list then
      if e[2] == false then
        if #o ~= e[3] + 1 then return nil end
        o[#o] = nil
      else o[e[2]] = e[3] end
    end
  end
  return o
end
-- (always) the room's structure: grid, rows, the cell at every position, the
-- env.groups / claims lists -- only the journal may change the lists.
-- Returns env.groups as it was when the step began.
local function checkStructure(ctx, ts, s, J, listW)
  local env = ctx.env
  if ctx.grid ~= s.grid or env.grid ~= s.envGrid then
    error(fmt("%s: replaces the room's grid directly (not through ctx:set)", ts.owner))
  end
  local grid, W, rows, at = s.grid, s.W, s.rows, s.at
  for y = 0, s.H - 1 do
    local row = grid[y]
    if (row or false) ~= rows[y + 1] then
      error(fmt("%s: replaces grid row %d directly (not through ctx:set)", ts.owner, y))
    end
    if row then
      local b = y * W + 1
      for x = 0, W - 1 do
        if (row[x] or false) ~= at[b + x] then
          error(fmt("%s: replaces the grid cell (%d,%d) directly (not through ctx:set)", ts.owner, x, y))
        end
      end
    end
  end
  if env.groups ~= s.groupsList then error(fmt("%s: replaces env.groups directly (not through ctx:set)", ts.owner)) end
  if ctx.claims ~= s.claims then error(fmt("%s: replaces the claims list directly (not through ctx:set)", ts.owner)) end
  -- each list undone through the journal (when it wrote one) must be the
  -- snapshot's list
  local before = s.gl
  if type(s.groupsList) == "table" then
    local ok
    if listW then before = listBefore(s.groupsList, J); ok = before ~= nil and listIs(before, s.gl)
    else ok = listIs(s.groupsList, s.gl) end
    if not ok then error(fmt("%s: changes env.groups directly (not through ctx:set)", ts.owner)) end
  end
  if type(s.claims) == "table" then
    local ok
    if listW then local cl = listBefore(s.claims, J); ok = cl ~= nil and listIs(cl, s.cl)
    else ok = listIs(s.claims, s.cl) end
    if not ok then error(fmt("%s: changes the claims list directly (not through ctx:set)", ts.owner)) end
  end
  return before
end
-- (strict) plain field writes on a cell outside the grant, or on a group that
-- holds one (jk[t][k]: the journaled writes, already checked)
local function checkFields(ctx, ts, cellSet, s, jk)
  for _, c in ipairs(s.cells) do
    if not cellSet[c] then
      local k = changed(c, s.byT[c], jk[c])
      if k then
        error(fmt("%s: writes %s of (%d,%d), a cell outside its grant, directly (not through ctx:set)",
          ts.owner, k, c.x, c.y))
      end
    end
  end
  for _, g in ipairs(s.groups) do
    local list, foreign = s.members[g], false
    for _, q in ipairs(list or {}) do if not cellSet[q] then foreign = true; break end end
    local cur = rawget(g, "cells")
    if not foreign and type(cur) == "table" then
      for _, q in ipairs(cur) do if not cellSet[q] then foreign = true; break end end
    end
    if foreign then
      local k = changed(g, s.byT[g], jk[g])
      if k then
        local c1 = list and list[1]
        error(fmt("%s: writes %s of a furniture group (%s,%s) that holds cells outside its grant, directly (not through ctx:set)",
          ts.owner, k, tostring(c1 and c1.x), tostring(c1 and c1.y)))
      end
    end
  end
end

-- grant: the dispatcher's private set of the granted cells (w0r4: never
-- ts.cellSet); snap: the map's snapshot; strict: check the fields too
function P.settle(ctx, ts, grant, grantList, snap, strict)
  local J = ctx.J
  local T, cellSet = ts.T, grant or ts.cellSet
  local groupsList, claims = ctx.env.groups, ctx.claims
  local oldCells, gOrder, gChanged = {}, {}, {}
  local jk, listW = (strict and snap) and {} or nil, false
  for i = 1, J.n do
    local e = J.e[i]
    local t, k = e[1], e[2]
    if t == groupsList or t == claims then
      -- (w0r4) the lists: pushes (the core's furnish / claim); env.groups
      -- rewritten in place (leaveGroup); the claims list never rewritten
      listW = true
      if k ~= false and t == claims then error(fmt("%s: rewrites the claims list", ts.owner)) end
    elseif k == false then
      error(fmt("%s: a list push outside env.groups / the claims list", ts.owner))
    else
      if jk then
        local s = jk[t]
        if not s then s = {}; jk[t] = s end
        s[k] = true
      end
      if type(t) ~= "table" then
        error(fmt("%s: a state write outside the cells and groups", ts.owner))
      elseif isCellOf(ctx, t) then
        if not cellSet[t] then
          if not P.SIDE_KEYS[k] then
            error(fmt("%s: writes %s of (%d,%d), a cell outside its grant (claim / furnish outside the grant)",
              ts.owner, tostring(k), t.x, t.y))
          end
        elseif k == "hgt" and not T.heightAt then
          error(fmt("%s: setGround (%d,%d) without T.heightAt = true", ts.owner, t.x, t.y))
        end
      elseif isGroup(t) then
        if oldCells[t] == nil then oldCells[t] = (k == "cells") and e[3] or false; gOrder[#gOrder + 1] = t end
        if k == "cells" and oldCells[t] == false then oldCells[t] = e[3] end
        if not P.GROUP_SIDE_KEYS[k] then gChanged[t] = true end
      else
        error(fmt("%s: a state write (%s) outside the cells and groups", ts.owner, tostring(k)))
      end
    end
  end
  if snap then
    -- (w0r4) the structure (always); env.groups may lose only groups that
    -- hold no cell outside the grant (leaveGroup drops the emptied ones)
    local before = checkStructure(ctx, ts, snap, J, listW)
    if listW and type(groupsList) == "table" and type(before) == "table" then
      local now = {}
      for _, g in ipairs(groupsList) do now[g] = true end
      for _, g in ipairs(before) do
        if not now[g] and type(g) == "table" and isGroup(g) then
          for _, q in ipairs(g.cells) do
            if not cellSet[q] then
              error(fmt("%s: drops a furniture group holding (%s,%s), a cell outside its grant, from env.groups",
                ts.owner, tostring(q.x), tostring(q.y)))
            end
          end
        end
      end
    end
    if jk then checkFields(ctx, ts, cellSet, snap, jk) end
  end
  -- groups: cells outside the grant may only leave; any other change needs
  -- every cell of the group granted
  local hosts = {}
  for _, g in ipairs(gOrder) do
    local had = {}
    local old = oldCells[g]
    if type(old) == "table" then for _, q in ipairs(old) do had[q] = true end end
    local foreign = false
    for _, q in ipairs(g.cells) do
      if not cellSet[q] then
        foreign = true
        if type(old) == "table" and not had[q] then
          error(fmt("%s: puts (%d,%d), a cell outside its grant, into a furniture group", ts.owner, q.x, q.y))
        end
      end
    end
    if foreign and gChanged[g] then
      local c1 = g.cells[1]
      error(fmt("%s: changes a furniture group (%d,%d) that holds cells outside its grant", ts.owner, c1.x, c1.y))
    end
    if foreign and type(old) == "table" and #g.cells < #old then hosts[#hosts + 1] = g end
  end
  -- a host group that lost cells: the core's real-life height of what is left
  -- (unless its height is fixed; PropFix's own re-heights follow as usual)
  if ctx:opt("INTERIORS_REAL_HEIGHTS") and type(ctx.realHeightOf) == "function" then
    for _, g in ipairs(hosts) do
      if not g.fixedH and not g.pillar and not g.slot and #g.cells > 0 then
        local h = ctx:realHeightOf(g)
        if h and mabs(h - (g.h or 0)) > 1e-9 then
          ts.rehost = (ts.rehost or 0) + 1
          ctx:set(g, "h", h)
        end
      end
    end
  end
  -- ownership: every granted cell, every group holding one
  for _, c in ipairs(grantList or ts.cells) do
    ctx:set(c, "typeOwner", ts.owner)
    local g = c.group
    if g and not g.typeOwner then ctx:set(g, "typeOwner", ts.owner) end
  end
end

-- ---------------------------------------------------------------------------
-- classify (hook H6)
-- ---------------------------------------------------------------------------
local classifyImpl
-- (the hook calls this outside a core step: a dispatcher error must never
-- reach Ctx:classify's latch; every type step already rolled itself back)
function P.classify(ctx, loadMod)
  local st = { types = {}, log = {}, idx = nil, granted = {} }
  ST[ctx] = st
  local ok, err = pcall(classifyImpl, ctx, loadMod, st)
  if not ok then
    ctx:note("PropTypes classify", err)
    st.log[#st.log + 1] = "dispatcher error: " .. tostring(err)
  end
end

-- (w0r5) PropFix's own wall targets: the cells its plan unwalls (every kind
-- PropFix handles unwalls a wall target: claim, box, plant). Computed once per
-- map, on the first type granted a wall cell; false = none (PropFix off,
-- missing, or its plan failed)
local function propfixWalls(ctx, st)
  if st.pfWalls ~= nil then return st.pfWalls end
  st.pfWalls = false
  if not ctx:opt("INTERIORS_PROPFIX") then return false end
  local PF = st.loadMod and st.loadMod(ctx.env, "PropFix")
  if not (type(PF) == "table" and type(PF.plan) == "function") then return false end
  local ok, plan = pcall(PF.plan, ctx)
  if not (ok and type(plan) == "table" and type(plan.targets) == "table") then
    ctx:note("PropTypes PropFix plan", ok and "bad plan" or plan)
    return false
  end
  local KIND = type(PF.KIND) == "table" and PF.KIND or {}
  local set = {}
  for _, t in pairs(plan.targets) do
    local c = type(t) == "table" and t.cell or nil
    if type(c) == "table" and c.role == "wall" and KIND[t.kind] then set[c] = true end
  end
  st.pfWalls = set
  return set
end

-- one type: match, grant, its step (w0r1 D1: under its own pcall)
local function dispatch(ctx, st, m, idx, lib, taken, mine, cells)
  local name, T = m.name, m.T
  local okA, applies = true, true
  if T.applies ~= nil then okA, applies = pcall(T.applies, ctx, idx) end
  if not okA then
    ctx:note("type " .. name .. " applies", applies)
    return
  end
  if not applies then return end
  local ok, want = pcall(T.match, ctx, idx) -- PURE: reads cells only
  if not ok then
    ctx:note("type " .. name .. " match", want)
    return
  end
  if type(want) ~= "table" then
    st.log[#st.log + 1] = name .. " bad match result (" .. type(want) .. ")"
    ctx:note("type " .. name .. " match", "bad match result (" .. type(want) .. ")")
    return
  end
  for _, p in ipairs(want) do
    local c, bad = cellOf(ctx, p)
    local why = bad or P.illegal(ctx, c, T)
    local px = (type(p) == "table" and tostring(p.x)) or "?"
    local py = (type(p) == "table" and tostring(p.y)) or "?"
    if why then
      st.log[#st.log + 1] = name .. " skip (" .. px .. "," .. py .. ") " .. why
    elseif mine[c] then
      st.log[#st.log + 1] = name .. " dup (" .. px .. "," .. py .. ")"
    elseif taken[c] then
      st.log[#st.log + 1] = name .. " overlap (" .. px .. "," .. py .. ") owned by " .. taken[c]
    else
      taken[c] = name
      mine[c] = true
      cells[#cells + 1] = c
    end
  end
  if #cells == 0 then return end
  local ts = { name = name, cells = cells, owner = "type:" .. name, T = T, cellSet = mine, lib = lib }
  -- (w0r4) the grant as granted: private copies the type never receives
  local grant, grantList = {}, {}
  for i, c in ipairs(cells) do grant[c] = true; grantList[i] = c end
  -- (w0r1, hook H8) the wallpaper candidates before the first type that
  -- changes wall cells, and the runs this type may change
  -- (w0r5) a wall cell PropFix's plan unwalls is not a pre-type wall for
  -- either snapshot (pfMade); the others record their run as before
  local runs, pfMade, pf
  for _, c in ipairs(cells) do
    if c.role == "wall" then
      if pf == nil then pf = propfixWalls(ctx, st) end
      if pf and pf[c] then
        pfMade = pfMade or {}
        pfMade[#pfMade + 1] = c
      elseif c.runA and c.runB then
        runs = runs or {}
        runs[#runs + 1] = { x = c.x, a = c.runA, b = c.runB }
      end
    end
  end
  -- (w0r5, diagnostics only) a recorded run that also holds a PropFix wall
  -- target keeps its pre-type (pre-PropFix) candidates
  if runs and pf then
    for _, r in ipairs(runs) do
      for y = r.a, r.b do
        local q = ctx:at(r.x, y)
        if q and pf[q] then
          st.wpMixed = st.wpMixed or {}
          st.wpMixed[#st.wpMixed + 1] = fmt("%s (%d,%d..%d)", name, r.x, r.a, r.b)
          break
        end
      end
    end
  end
  if runs and st.wpSnap == nil and type(ctx.wallpaperCands) == "function" then
    local okW, snap = pcall(ctx.wallpaperCands, ctx)
    st.wpSnap = okW and snap or false
    if not okW then ctx:note("PropTypes wallpaper snapshot", snap) end
  end
  -- (w0r4) the map's snapshot, once: before the first type step
  local snap = st.snap
  if not snap then
    snap = P.snapshot(ctx, st.strict)
    st.snap = snap
  end
  local prev = ctx.owner
  ctx.owner = ts.owner -- claimOwner of every claim it makes
  local jr
  -- (w0r5) one regroup per host group for the whole step (core helper; an
  -- older core without it regroups per leave)
  local defer = type(ctx.deferRegroup) == "function" and type(ctx.flushRegroup) == "function"
  ts.ok = ctx:step("type " .. name, function(s)
    if defer then s:deferRegroup() end
    T.classify(s, cells, ts)
    if defer then s:flushRegroup() end
    P.settle(s, ts, grant, grantList, snap, st.strict)
    jr = s.J
  end)
  if defer and type(ctx.cancelRegroup) == "function" then ctx:cancelRegroup() end -- (an error left it set)
  ctx.owner = prev
  if ts.ok then
    P.refresh(ctx, snap, jr, grantList)
    if runs then
      st.wpRuns = st.wpRuns or {}
      for _, r in ipairs(runs) do st.wpRuns[#st.wpRuns + 1] = r end
    end
    if pfMade then
      -- (w0r5) the lamps: these cells are PropFix's unwalls, not type-made
      st.pfMade = st.pfMade or {}
      for _, c in ipairs(pfMade) do st.pfMade[#st.pfMade + 1] = c end
      local CeilM = st.loadMod and st.loadMod(ctx.env, "Ceiling")
      if type(CeilM) == "table" and type(CeilM.propfixMade) == "function" then
        local okC, errC = pcall(CeilM.propfixMade, ctx, pfMade)
        if not okC then ctx:note("PropTypes Ceiling propfixMade", errC) end
      end
    end
  else
    P.restore(ctx, snap) -- (w0r4) the structure; in strict builds unjournaled field writes too
    for _, c in ipairs(grantList) do taken[c] = nil end -- rolled back: the cells are free again
    st.log[#st.log + 1] = name .. " classify rolled back"
  end
  st.types[#st.types + 1] = ts
  st.granted[name] = ts.ok and grantList or {}
end

classifyImpl = function(ctx, loadMod, st)
  local reg = loadMod(ctx.env, "props/Registry")
  if type(reg) ~= "table" then return end
  -- the type modules present (missing files: loadMod returns nil, cached)
  local mods = {}
  for _, name in ipairs(reg) do
    if type(name) == "string" and not P.NOT_TYPES[name] then
      local T = loadMod(ctx.env, "props/" .. name)
      if type(T) == "table" then
        if type(T.match) == "function" and type(T.classify) == "function" then
          mods[#mods + 1] = { name = name, T = T }
        else
          st.log[#st.log + 1] = name .. " bad module (match / classify missing)"
        end
      end
    end
  end
  if #mods == 0 then return end -- G0: no type file -> no index, no state
  local idx = P.index(ctx)
  st.idx = idx
  st.loadMod = loadMod -- (w0r5) PropFix's plan / Ceiling, on first need
  -- the shared builders, through the core's loader (types never require)
  local lib = { Relief = loadMod(ctx.env, "props/Relief"), Kit = loadMod(ctx.env, "Kit") }
  st.lib = lib
  -- (w0r4) strict: the field scan (gate / test builds; see the header)
  local strict = ctx:opt("INTERIORS_PROPTYPES_STRICT")
  if strict == nil then strict = ctx:opt("INTERIORS_KEEP_LAST") end
  st.strict = strict and true or false
  local taken = {}
  for _, m in ipairs(mods) do
    local mine, cells = {}, {}
    local ok, err = pcall(dispatch, ctx, st, m, idx, lib, taken, mine, cells)
    if not ok then
      -- (D1) this type only: its cells go free, the next type runs
      for c in pairs(mine) do if taken[c] == m.name then taken[c] = nil end end
      ctx:note("PropTypes dispatch " .. m.name, err)
      st.log[#st.log + 1] = m.name .. " dispatcher error: " .. tostring(err)
      st.granted[m.name] = {}
      st.snap = nil -- (w0r4) taken again before the next type step
    end
  end
  st.snap = nil -- (w0r4) the snapshot lives for the per-type step only
end

-- ---------------------------------------------------------------------------
-- wallpaper (hook H8, w0r1): the candidates of the runs a type changed are
-- the ones those runs had before the per-type step; every other run's are
-- today's (PropFix / sections still count). Row-major like the core's list.
-- ---------------------------------------------------------------------------
local function wallpaperImpl(st, all)
  local runs = st.wpRuns
  local function inRun(x, y)
    for _, r in ipairs(runs) do if r.x == x and y >= r.a and y <= r.b then return true end end
    return false
  end
  local out = {}
  for _, cd in ipairs(all) do if not inRun(cd.x, cd.y) then out[#out + 1] = cd end end
  for _, cd in ipairs(st.wpSnap) do if inRun(cd.x, cd.y) then out[#out + 1] = cd end end
  table.sort(out, function(a, b) if a.y ~= b.y then return a.y < b.y end return a.x < b.x end)
  return out
end
function P.wallpaperCands(ctx, all)
  local st = ST[ctx]
  if not (st and st.wpSnap and st.wpRuns and #st.wpRuns > 0) then return all end
  local ok, out = pcall(wallpaperImpl, st, all)
  if not ok then
    st.log[#st.log + 1] = "wallpaper snapshot error: " .. tostring(out)
    return all
  end
  return out
end

-- ---------------------------------------------------------------------------
-- props (hook H7)
-- ---------------------------------------------------------------------------
local function fallback(ctx, st, ts)
  local ok, err = pcall(ctx.claimFallback, ctx, ts.owner)
  if not ok then ctx:note("PropTypes fallback " .. ts.name, err) end
end
function P.props(ctx)
  local st = ST[ctx]
  if not st then return end
  for _, ts in ipairs(st.types) do
    if ts.ok then
      local T = ts.T
      if type(T.props) == "function" then
        ts.propsOk = ctx:runModule(ts.owner, function(s) T.props(s, ts) end)
        if not ts.propsOk then
          st.log[#st.log + 1] = ts.name .. " props failed: fallback boxes"
          fallback(ctx, st, ts)
        end
      else
        fallback(ctx, st, ts) -- claimed but nothing draws it: plain boxes
      end
    end
  end
end

-- tests / harness
function P.state(ctx) return ST[ctx] end

return P
