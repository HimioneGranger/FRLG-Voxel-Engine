-- FRLG_VOXEL / interiors team: props/CableClub.lua -- the two link machines
-- on every Pokemon Center 2F (wave 3, 2026-10-02; scout INVENTORY "Cable
-- Club machines", PLAN Q3).
--
-- Today each machine is a picture on a 4-row wall pillar (columns 8 and 12,
-- rows 0..3 of every Center 2F): the back wall's rows 0..1, then the cabinet
-- tile 869 in the aisle behind the counter and the console tile in the
-- counter row (870, behaviour 0x8D, the wireless monitor; 871, behaviour
-- 0x8E, the battle records). This type takes the two lower cells (cabinet
-- and console) out of the wall run and stands the machine on the floor,
-- built with the shared relief builder (props/Relief.lua: method after
-- pokeemerald-3Ds-dualscreen, ZallaxDev, MIT -- the licence text is in
-- Relief.lua's header). No code or data of that project is copied here; every
-- texel is the player's own ROM-extracted art read through the atlas. The
-- back wall's own rows (0..1) stay wall: the core gives the run left above
-- the machine a south face in the room's wallpaper, so the wall is closed
-- behind the machine.
--
-- Shape (picture row V = Z - Y, Relief's rule, held for every piece):
--   console  the front of the counter-row cell, H_CONSOLE high: its front
--            shows the monitor's lower rows and the stand, its top the white
--            lid and the monitor's upper rows; flanks the mauve casing
--   base     the same height from the console's back to the wall (under the
--            cabinet; closes the machine below it)
--   cabinet  lifted onto the base by H_CONSOLE, H_UPPER high, its front plane
--            where the console's drawn top starts: the red body's lower rows
--            (with the antenna) stand upright above the console, its upper
--            rows lie on its top
-- The antenna's tip and the wall rows above the red body (tile 766) are not
-- drawn as 3D: at real-life height they would stand above the cabinet.
--
-- User defaults (scout PLAN Q1 / Q3), one constant each:
--   H_CONSOLE  real-life console height (cells; 1 cell = 1.6 m)
--   H_UPPER    the cabinet above the console (total = H_CONSOLE + H_UPPER)
--   PULL_OUT   false = leave the machines painted on the wall (type off)
-- No globals, no debug / package / io (mod sandbox); state lives on ts only.
local V = ...
local _ = V

local T = {
  id = "CableClub", version = "cableclub 0.1 (2026-10-02)",
  walkable = false,
  maxWalkH = 0.56,
  walls = true,        -- both cells of a machine are wall-run cells today
  heightAt = false,
  supersedes = {},
  budget = 400,
  sourceMids = nil,
  stretchedAllowed = 0,
  windingExempt = 0,
}

-- ------------------------------------------------------------------ constants
T.H_CONSOLE = 0.75      -- 1.2 m: the monitor console (the PC's real-life height)
T.H_UPPER = 0.5         -- 0.8 m more: the red cabinet tops out at 1.25 = 2.0 m
                        -- (the Healer's height; the art's own rows would be ~1.9)
T.PULL_OUT = true       -- user default Q3: out of the wall, wall closed behind it
T.PAIR = "network"      -- the Pokemon Center tileset (metatile ids >= 640 are per tileset)
T.BEH = { [0x8D] = true, [0x8E] = true }   -- wireless monitor, battle records
T.CABINET_MID = 869     -- the cabinet tile in the aisle cell above the console
-- art rows (px of the cell above the console): the cabinet's bottom outline,
-- where the console's drawn top starts
local BODY_FOOT = 13 / 16
-- the cabinet's first red row (px of the wall cell two above the console)
local BODY_TOP = 13 / 16
-- cells: every face 1/64 off the cell borders it would share with a core
-- face (the counter boxes beside the console, review-w2)
local INSET_X = 1 / 64
-- flank source strips (cells): the cabinet's red columns (px 2..4) and the
-- console's mauve frame column (px 14: the casing over its dark base)
local CAB_SIDE_U, CAB_SIDE_W = 2 / 16, 3 / 16
local CON_SIDE_U, CON_SIDE_W = 14 / 16, 1 / 16
-- the console's base under the cabinet (hidden but for a sliver over the
-- counters): its lid rows (cells below the console cell's top; one 8 px band
-- in one source cell: few courses)
local BASE_LID = { 0, 8 / 16 }

local function isMachine(ctx, c)
  if not (c and c.role == "wall" and T.BEH[c.beh]) then return nil end
  local up = ctx:at(c.x, c.y - 1)
  if not (up and up.role == "wall" and up.mid == T.CABINET_MID) then return nil end
  -- the cabinet and the console must be the bottom of one wall run (the back
  -- wall's rows above stay wall)
  if not (c.runB == c.y and up.runA and up.runA < up.y) then return nil end
  -- one ground under both cells (a machine on mixed ground is left alone)
  if (up.hgt or 0) ~= (c.hgt or 0) then return nil end
  return up
end

function T.applies(ctx, idx)
  return T.PULL_OUT and idx.pair == T.PAIR and (idx.byBeh[0x8D] ~= nil or idx.byBeh[0x8E] ~= nil)
end

-- PURE: per machine, row-major by console: the cabinet cell, then the console
function T.match(ctx, idx)
  local list = {}
  for beh in pairs(T.BEH) do
    for _, c in ipairs(idx.byBeh[beh] or {}) do list[#list + 1] = c end
  end
  table.sort(list, function(a, b) if a.y ~= b.y then return a.y < b.y end return a.x < b.x end)
  local out = {}
  for _, c in ipairs(list) do
    local up = isMachine(ctx, c)
    if up then out[#out + 1] = up; out[#out + 1] = c end
  end
  return out
end

-- the machines whose two cells were both granted: { x, y } of the console
local function machines(ctx, ts)
  local out = {}
  for _, c in ipairs(ts.cells) do
    if T.BEH[c.beh] then
      local up = ctx:at(c.x, c.y - 1)
      if up and ts.cellSet[up] then out[#out + 1] = { x = c.x, y = c.y } end
    end
  end
  return out
end

function T.classify(ctx, cells, ts)
  local list = machines(ctx, ts)
  for _, k in ipairs(list) do
    -- each cell out of its wall run (role ext: the core draws the ground only)
    ctx:claim(k.x, k.y - 1, nil, T.H_CONSOLE + T.H_UPPER)
    ctx:claim(k.x, k.y, nil, T.H_CONSOLE)
  end
  ts.machines = list
end

function T.props(ctx, ts)
  local R = ts.lib.Relief
  local under, over = ctx:buffer("opaque"), ctx:buffer("over")
  local HC = T.H_CONSOLE
  for _, k in ipairs(ts.machines or {}) do
    local x, y = k.x, k.y
    local g = ctx:at(x, y).hgt or 0
    local X0, X1 = x + INSET_X, x + 1 - INSET_X
    -- the console's drawn top starts at the cabinet's bottom outline row and
    -- ends at the foot (zs .. y + 1, no hidden depth); its base runs on from
    -- zs back to the wall under the cabinet (closed below it), and the
    -- cabinet stands on that, lifted by HC (up AND south: its front plane is
    -- zs, its picture unchanged), so the three pieces share their edges
    local first = y - 1 + BODY_FOOT
    local zs = first + HC
    R.piece(ctx, { x0 = X0, x1 = X1, z0 = zs, z1 = y + 1, h = HC, g = g, first = first,
      back = false, flanks = { w = true, e = true }, sideW = CON_SIDE_W, sideU = x + CON_SIDE_U,
      under = under, over = over, tag = "cableclub:console" })
    R.piece(ctx, { x0 = X0, x1 = X1, z0 = y - 1, z1 = zs, h = HC, g = g, first = zs - HC,
      lid = { y + BASE_LID[1], y + BASE_LID[2] }, back = false, flanks = { w = true, e = true },
      under = under, over = over, tag = "cableclub:base" })
    R.piece(ctx, { x0 = X0, x1 = X1, z0 = y - 1 - HC, z1 = first, h = T.H_UPPER, g = g, lift = HC,
      first = y - 2 + BODY_TOP, back = false, flanks = { w = true, e = true },
      sideW = CAB_SIDE_W, sideU = x + CAB_SIDE_U,
      under = under, over = over, tag = "cableclub:cabinet" })
  end
end

return T
