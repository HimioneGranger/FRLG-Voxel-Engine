-- FRLG_VOXEL / interiors team: props/PC.lua -- the PC terminal (behaviour 0x83,
-- MB_PC) as a relief piece (wave 1, 2026-10-01; scout INVENTORY "PC terminal").
--
-- Where: 45 cells on 45 maps, all metatile 98, all floor-standing towers:
--   * 24 lone one-cell boxes between walls (every PC Center 1F incl. Indigo and
--     One Island, the two Cinnabar lab rooms, both Day Cares, the Two Island
--     Game Corner) -- TAKEN by this version;
--   * 20 inline in a counter (the Cable Club link counter of every PC Center
--     2F, the Trainer Tower lobby counter) and 1 in Silph Co. 11F's desk block
--     -- NOT taken yet (see lone() below). The art's tower reaches the floor
--     below the counter's foot: these are PCs standing in the counter line,
--     not PCs on a counter (none of the 45 stands on a host).
-- A taken PC cell is claimed and drawn by the shared Relief builder: the art's
-- front rows on the front face, its top rows on the lid, the hidden depth laid
-- with the lid rows course by course (never stretched). The monitor head above
-- stays where the game paints it, on the wall cell behind; the tower's foot
-- below the cell stays the floor art in front (that cell is walkable).
--
-- Method after pokeemerald-3Ds-dualscreen (ZallaxDev, MIT) through
-- props/Relief.lua (the MIT text is in Relief.lua's header); no code of his is
-- copied here. Every texel is our own ROM-extracted art read through the atlas.
-- Mod sandbox: no globals; the debug, package and io libraries are never used;
-- `...` is V in the game, nil in tests.
local V = ...
local _ = V

local T = {
  id = "PC", version = "pc 0.1 (2026-10-01)",
  walkable = false,
  maxWalkH = 0.56,
  walls = false,
  heightAt = false,
  supersedes = {},
  budget = 400,       -- a lone PC adds 12 triangles (one per map)
  sourceMids = nil,
  stretchedAllowed = 0,
  windingExempt = 0,
}

-- user default (scout PLAN Q1): real-life heights, 1 cell = 1.6 m.
-- PC terminal 1.2 m = 0.75 cells (the core's FURNITURE_H[0x83]).
T.PC_H = 0.75

local BEH_PC = 0x83

function T.applies(ctx, idx) return idx.byBeh[BEH_PC] ~= nil end

-- A PC inside a host group (the 2F link counters, the Trainer Tower lobby
-- counter, Silph Co. 11F's desk block) is left to its host for now: ctx:claim
-- takes it out of the group, and the host group then keeps the PC's 0.75
-- height (the core's realHeights ran with the PC still in it, and PropFix's
-- "counter holding a PC" re-height no longer fires), so the whole counter /
-- desk would grow 0.1 cell. Only the host's owner may re-height it
-- (RESULTS.md, Requests).
local function lone(c)
  local g = c.group
  if c.role ~= "furniture" or not g then return false end
  for _, q in ipairs(g.cells) do if q.beh ~= BEH_PC then return false end end
  return true
end

-- PURE: the lone PC cells, row-major (the index order)
function T.match(ctx, idx)
  local out = {}
  for _, c in ipairs(idx.byBeh[BEH_PC] or {}) do
    if lone(c) then out[#out + 1] = c end
  end
  return out
end

function T.classify(ctx, cells, ts)
  for _, p in ipairs(cells) do ctx:claim(p.x, p.y, nil, T.PC_H) end
end

function T.props(ctx, ts)
  local R = ts.lib.Relief
  local under, over = ctx:buffer("opaque"), ctx:buffer("over")
  local H = T.PC_H
  for _, p in ipairs(ts.cells) do
    -- footprint = the cell; back and flanks auto-skip against the wall runs
    R.piece(ctx, { x0 = p.x + 0.0, x1 = p.x + 1.0, z0 = p.y + 0.0, z1 = p.y + 1.0, h = H, g = p.hgt or 0,
      under = under, over = over, tag = "pc" })
  end
end

return T
