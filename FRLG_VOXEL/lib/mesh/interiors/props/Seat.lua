-- FRLG_VOXEL / interiors team: props/Seat.lua -- chairs, stools, sofas,
-- benches and armchairs (wave 1, 2026-10-01; scout INVENTORY "Seats").
--
-- Today every seat is flat floor art. This type turns the walkable seat
-- cells into LOW pieces the player still walks through (user default,
-- scout Q2): a seat block SEAT_H high and, where the art shows one, a thin
-- back BACK_H high on the side the art draws it. Built with the shared
-- Relief builder (method after pokeemerald-3Ds-dualscreen, ZallaxDev, MIT;
-- licence text in Relief.lua): every texel is the room's own ROM art read
-- through the atlas, front rows on the front, top rows on the lid.
--
-- Cells are found by METATILE (pair + mid), not by behaviour: FRLG's
-- 0x30-0x33 "impassable east / west / north / south" bytes sit on the seat
-- AND on the floor cell beyond its back (Fan Clubs, Condos), and many chairs
-- carry no behaviour at all. The catalogue below was built offline from the
-- 263-map census (seat mids reviewed by eye on contact sheets; x extents
-- measured against the neighbouring floor tile). Each entry is the side of
-- the back ("w", "e", "n") or "-" (stool / no back) and the art's x extent
-- in pixels {l, r}; a 4th field true marks a sofa / armchair part that
-- joins its neighbours (single chairs side by side stay separate).
-- Sofas: cells of one sofa (same back side, adjacent along the back) are
-- built as ONE piece when every cell of the run was granted to this type.
-- The cell's ground becomes the plain floor of a walkable neighbour (the
-- rug / floor round the seat), so no seat picture stays flat underneath.
-- No debug / package / io (mod sandbox); state lives on ts only.
local V = ...
local _ = V

local T = {
  id = "Seat", version = "seat 0.1 (2026-10-01)",
  walkable = true,       -- seats are decoration on walkable cells (scout Q2)
  maxWalkH = 0.56,       -- G4: the highest piece over the floor (cells)
  walls = false,
  heightAt = false,
  supersedes = {},
  budget = 800,          -- hero rooms: Fan Clubs / Silph 1F / Game Corner (see RESULTS.md)
  sourceMids = nil,
  stretchedAllowed = 0,
  windingExempt = 0,
}

-- user defaults (scout PLAN Q2), one constant each
T.SEAT_H = 0.28          -- seat top over the floor (cells; 0.45 m)
T.BACK_H = 0.55          -- back top over the floor (cells; 0.88 m; G4 limit 0.56 incl. over-art lift)
T.FLAT = false           -- true: keep every seat flat (no claim, today's look)
local PXC = 1 / 16
local BACK_T = 3         -- back thickness (px)
local TOP, FOOT = 1, 15  -- art rows (px) of a seat's back edge and foot inside its cell
local MIN_IN = 1         -- px: the least inset from a cell edge
local WALL_IN = 2        -- px: the least inset from a wall / off-map side
local OVERLAP = 1        -- px: the seat block reaches into its back
local RECESS = 1 / 64    -- cells: the seat's other faces stay inside the back's planes (G6 > 0.004)

-- pair -> mid -> { back, l, r }
local W, E, N, S0 = "w", "e", "n", "-"
local CAT = {
  building__rom_082d4c2c = { [294] = { W, 0, 12 }, [295] = { E, 4, 16 }, [371] = { W, 2, 14 },
    [661] = { S0, 1, 15 }, [669] = { S0, 1, 15 } },
  building__rom_082d4cec = { [682] = { S0, 2, 14 }, [683] = { S0, 2, 14 }, [690] = { S0, 2, 14 },
    [691] = { S0, 2, 14 }, [698] = { S0, 2, 14 }, [699] = { S0, 2, 14 },
    [783] = { E, 1, 15, true }, [791] = { E, 1, 15, true } },
  building__rom_082d4e24 = { [359] = { E, 2, 14 }, [367] = { W, 2, 14 } },
  building__rom_082d4e6c = { [734] = { S0, 2, 14 }, [790] = { W, 1, 15 } },
  building__rom_082d4ecc = { [739] = { S0, 2, 14 }, [740] = { S0, 2, 14 }, [794] = { S0, 2, 14 },
    [902] = { S0, 2, 14 }, [837] = { S0, 1, 15 }, [842] = { S0, 1, 15 },
    [808] = { N, 1, 16, true }, [809] = { N, 0, 16, true }, [810] = { N, 0, 15, true },
    [866] = { E, 1, 15, true }, [874] = { E, 1, 15, true }, [867] = { W, 1, 15, true }, [875] = { W, 1, 15, true } },
  building__rom_082d4f14 = { [672] = { S0, 1, 15 }, [706] = { S0, 1, 15 }, [735] = { W, 2, 14 },
    [739] = { E, 2, 14 } },
  building__rom_082d4f2c = { [752] = { W, 1, 12 }, [753] = { E, 4, 15 }, [858] = { W, 1, 12 },
    [859] = { E, 4, 15 } },
  building__rom_082d4f44 = { [696] = { W, 1, 15, true }, [704] = { W, 1, 15, true }, [713] = { N, 2, 14 },
    [741] = { N, 2, 14 }, [717] = { E, 1, 12 }, [718] = { E, 4, 15 } },
  building__rom_082d4f5c = { [648] = { S0, 1, 15 } },
  building__rom_082d4f74 = { [704] = { W, 1, 15, true }, [712] = { W, 1, 15, true }, [705] = { E, 1, 15, true },
    [713] = { E, 1, 15, true }, [714] = { N, 1, 16, true }, [715] = { N, 0, 15, true } },
  building__rom_082d4f8c = { [692] = { S0, 2, 14 }, [715] = { E, 1, 15, true }, [772] = { E, 1, 15, true },
    [723] = { E, 1, 15, true }, [736] = { N, 1, 16, true }, [737] = { N, 0, 16, true }, [738] = { N, 0, 15, true } },
  building__rom_082d4fa4 = { [666] = { W, 1, 12 }, [675] = { W, 4, 15 } },
  general__rom_082d4d94 = { [771] = { E, 4, 15 }, [820] = { E, 4, 15 }, [780] = { N, 1, 15 } },
  house = { [75] = { W, 1, 12 }, [78] = { E, 4, 15 }, [359] = { E, 2, 14 }, [367] = { W, 2, 14 },
    [742] = { W, 1, 12 }, [743] = { E, 4, 15 } },
  network = { [679] = { E, 1, 15, true }, [687] = { E, 1, 15, true }, [757] = { S0, 1, 15 }, [765] = { S0, 1, 15 } },
  oak_lab = { [714] = { S0, 1, 15 }, [715] = { S0, 2, 14 }, [722] = { S0, 1, 15 }, [728] = { S0, 1, 15 },
    [760] = { S0, 2, 14 }, [780] = { S0, 2, 14 }, [784] = { S0, 2, 14 },
    [734] = { W, 1, 15, true }, [742] = { W, 1, 15, true }, [739] = { E, 1, 15, true }, [747] = { E, 1, 15, true } },
  player_house = { [75] = { W, 1, 12 }, [78] = { E, 4, 15 }, [198] = { W, 1, 12 }, [199] = { E, 4, 15 },
    [294] = { W, 1, 12 }, [295] = { E, 4, 15 }, [656] = { S0, 1, 15 }, [663] = { S0, 1, 15 } },
}
T.CATALOGUE = CAT -- (tests)

local function entry(pair, c)
  local P = CAT[pair]
  return P and c and P[c.mid] or nil
end
T.entry = entry

function T.applies(ctx, idx)
  local P = CAT[idx.pair]
  if not P or T.FLAT then return false end
  for mid in pairs(P) do if idx.byMid[mid] then return true end end
  return false
end

-- PURE: the walkable, role-free seat cells, row-major
function T.match(ctx, idx)
  local P = CAT[idx.pair]
  local out = {}
  if not P then return out end
  local mids = {}
  for mid in pairs(P) do mids[#mids + 1] = mid end
  table.sort(mids)
  for _, mid in ipairs(mids) do
    for _, c in ipairs(idx.byMid[mid] or {}) do
      -- (a seat on the room's south void edge is left flat: the core's south
      -- wall pass casts from that cell's centre and would meet the piece)
      local s = ctx:at(c.x, c.y + 1)
      if c.walkable and c.role == nil and s ~= nil then out[#out + 1] = c end
    end
  end
  table.sort(out, function(a, b) if a.y ~= b.y then return a.y < b.y end return a.x < b.x end)
  return out
end

-- the plain ground under a seat: a walkable, role-free, non-seat neighbour (S, W, E, N)
local function groundOf(ctx, c)
  for _, o in ipairs({ { 0, 1 }, { -1, 0 }, { 1, 0 }, { 0, -1 } }) do
    local q = ctx:at(c.x + o[1], c.y + o[2])
    if q and q.walkable and q.role == nil and q.mid and not entry(ctx.pair, q) and (q.hgt or 0) == (c.hgt or 0) then
      return q.mid
    end
  end
  return nil
end

function T.classify(ctx, cells, ts)
  for _, c in ipairs(cells) do
    ctx:claim(c.x, c.y, groundOf(ctx, c), T.SEAT_H)
  end
end

-- runs: a sofa = sofa-marked cells with the same back side, adjacent along the back
-- (w / e: down a column; n: along a row), every cell granted, same ground
local function runs(ctx, ts)
  local used, out = {}, {}
  for _, c in ipairs(ts.cells) do
    if not used[c] then
      local e = entry(ctx.pair, c)
      local run = { c }
      used[c] = true
      if e and e[1] ~= S0 and e[4] then
        local dx, dy = 0, 1
        if e[1] == N then dx, dy = 1, 0 end
        local q = ctx:at(c.x + dx, c.y + dy)
        while q and ts.cellSet[q] and not used[q] and (q.hgt or 0) == (c.hgt or 0) do
          local eq = entry(ctx.pair, q)
          if not eq or eq[1] ~= e[1] or not eq[4] then break end
          run[#run + 1] = q
          used[q] = true
          q = ctx:at(q.x + dx, q.y + dy)
        end
      end
      out[#out + 1] = run
    end
  end
  return out
end

local function clampIn(l, r)
  return math.max(l, MIN_IN), math.min(r, 16 - MIN_IN)
end

function T.props(ctx, ts)
  local R = ts.lib.Relief
  -- under art only: no catalogue seat has over art, and Relief's over lift
  -- (0.003) sits inside the G6 z-fight band (request in RESULTS.md)
  local under, over = ctx:buffer("opaque"), nil
  local sh, bh = T.SEAT_H, T.BACK_H
  local bt = BACK_T * PXC
  for _, run in ipairs(runs(ctx, ts)) do
    local c0, c1 = run[1], run[#run]
    local e = entry(ctx.pair, c0)
    local back = e[1]
    local g = c0.hgt or 0
    -- footprint (cells)
    local x0, x1, z0, z1
    if back == N then
      local l = clampIn(e[2], e[3])
      local _, r = clampIn(entry(ctx.pair, c1)[2], entry(ctx.pair, c1)[3])
      x0, x1 = c0.x + l * PXC, c1.x + r * PXC
    else
      local l, r = clampIn(e[2], e[3])
      for _, q in ipairs(run) do
        local eq = entry(ctx.pair, q)
        local ql, qr = clampIn(eq[2], eq[3])
        if ql < l then l = ql end
        if qr > r then r = qr end
      end
      x0, x1 = c0.x + l * PXC, c0.x + r * PXC
    end
    -- beside a wall (or off-map) keep WALL_IN off the cell edge: clear of the
    -- core's synthetic wall plane (inset 0.06) by more than the z-fight band
    local function walled(x, y)
      local q = ctx:at(x, y)
      return q == nil or q.role == "wall" or q.exitFrame
    end
    local xe = (back == N) and c1.x or c0.x
    if walled(c0.x - 1, c0.y) then x0 = math.max(x0, c0.x + WALL_IN * PXC) end
    if walled(xe + 1, c1.y) then x1 = math.min(x1, xe + 1 - WALL_IN * PXC) end
    z0, z1 = c0.y + TOP * PXC, c1.y + FOOT * PXC
    -- the seat reaches OVERLAP into the back, so no seat face lies in the
    -- back's inner face plane (no coincident opposite-facing pair)
    -- (and stays RECESS inside the back's other face planes, so no seat face
    -- shares a plane with a back face either way)
    local ov = OVERLAP * PXC
    local sx0, sx1, sz0, sz1 = x0, x1, z0, z1
    if back == W then sx0 = x0 + bt - ov; sz0 = z0 + RECESS; sz1 = z1 - RECESS
    elseif back == E then sx1 = x1 - bt + ov; sz0 = z0 + RECESS; sz1 = z1 - RECESS
    elseif back == N then sz0 = z0 + bt - ov; sx0 = x0 + RECESS; sx1 = x1 - RECESS end
    -- the seat block
    R.piece(ctx, { x0 = sx0, x1 = sx1, z0 = sz0, z1 = sz1, h = sh, g = g, first = sz0,
      under = under, over = over, tag = "seat" })
    -- the back
    if back == W then
      R.piece(ctx, { x0 = x0, x1 = x0 + bt, z0 = z0, z1 = z1, h = bh, g = g, first = z0,
        under = under, over = over, tag = "back" })
    elseif back == E then
      R.piece(ctx, { x0 = x1 - bt, x1 = x1, z0 = z0, z1 = z1, h = bh, g = g, first = z0,
        under = under, over = over, tag = "back" })
    elseif back == N then
      -- a thin slab along the north edge. A long couch whose back the game
      -- paints in the (solid) row above shows those rows on its front (ring
      -- art); a chair whose back is drawn inside its own cell repeats its own
      -- top rows instead (never the floor of a walkable row above)
      local above = true
      for _, q in ipairs(run) do
        local a = ctx:at(q.x, q.y - 1)
        if not a or a.walkable then above = false end
      end
      R.piece(ctx, { x0 = x0, x1 = x1, z0 = z0, z1 = z0 + bt, h = bh, g = g,
        first = above and (z0 + bt - bh) or z0, under = under, over = over, tag = "back" })
    end
  end
end

return T
