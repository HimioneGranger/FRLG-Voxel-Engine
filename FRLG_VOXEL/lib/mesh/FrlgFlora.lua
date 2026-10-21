-- FRLG_VOXEL flora (W7, 2026-09-28): tree crowns, tall grass and flowers
-- built from the tileset art's OWN sections instead of one stretched leaf
-- swatch per ring.
--
-- Pure Lua 5.1 / LuaJIT (JIT off on Quest): no love.*, no require, no
-- package / debug / io. FrlgMesher.lua creates one context per build
-- (F.new(env)) and dispatches to it from its tree-unit, tall-grass, flower
-- and understory emitters (w7/INTEGRATION_FLORA.md). Every UV is a
-- sub-rect of an UNDER-atlas rect returned by env.underRect(mid); geometry
-- goes into env.opaque (OPAQUE shader, under atlas) or env.keyed
-- (cutoutKeyed: the ground-keyed under atlas, alpha test). Nothing is
-- emitted into the over list (contract V2; mesher test M13).
--
-- USER REPORTS answered here (2026-09-28):
--  * "our trees and grass HAS to look better. The leaf patterns are already
--    pretty sectioned out ... instead of just doing each row as one long
--    leaf texture; also too much trunk exposed"
--  * "Grass ... only rendering a shell. The bottom part of trees aren't
--    rendering, they are staying as a block"; "Some tree trunks are off
--    centre".
--
-- TREES. One crown per tree unit, centred on the unit's footprint (a 2x2
-- tree on the shared corner of its four cells; the trunk exactly there, no
-- shift toward open sides; crown jitter <= FLORA_JITTER). Unit detection /
-- pairing stays the mesher's (by art identity, MB.TREE_*; seams via
-- input.outsideMidAt).
--   conifer (general tileset 2x2; tree rounds 2-4, USER: "a TEARDROP":
--     a pointed apex, three scalloped tiers with a dark outline row at each
--     hem, widest near the bottom tier): an OPAQUE lathe (CONIFER_PROFILE:
--     the bottom tier, two NOTCHES -- a ring pair where the tier above
--     overhangs the one below, the pair's downward band one texel of the
--     darkest leaf colour = the outline row -- and a pointed apex), smooth
--     normals from the profile with their up part capped at
--     FLORA_CROWN_NY (darker tops), each face one tile section of the art
--     (the bottom tiles' dark clump rows low, the top tiles' deeper-green
--     lower rows above, their side clumps on the apex), alternating the
--     tree's left and right tiles (boxes clear of the ground-coloured
--     corners). Crowns stay inside their own footprint (walls: neighbours
--     touch; no crown over a neighbouring roof).
--   broadleaf (MB.FOREST3_PAIRS: Viridian Forest, Pattern Bush): an opaque
--     dome whose faces are whole tiles of the tree's own left / right
--     columns (lower row below, upper row above; the centre column's art is
--     over-layer only) + a ring of keyed scalloped hem cards to the ground.
--   The crown bottom is FLORA_HEM (0.11) of the height (broadleaf + 0.02):
--   the dark trunk stub under it hides behind it from eye height beyond ~2
--   cells; the round ground shadow comes from the shadow mask
--   (geom.treeOccluders dome, y0 = that hem).
--   ROWS (round 5, USER: "we only need like two rows of trees just to hide
--   the sky in 1st & 3rd person"): only the two rows facing open ground get
--   trees (first row: the near LOD + trunk on edge units; second row: the
--   inner LOD); deeper units get a 4-triangle canopy pillow at crown height
--   (+ skirts toward shallower forest), rising toward the world's edge over
--   the third-person eye (Ctx:treeRow / Ctx:canopy; needs dispatch F12,
--   without it the round-4 LODs).
-- Clump bounds come from the art when atlas.texels is present: every card
-- is cropped to the columns / rows that hold non-ground texels (cropBox),
-- so no card is wider than its visible leaves; the CONIFER / BROAD boxes
-- below are the starting cut (and the whole cut without texels). The core /
-- understory colour is the art's most common dark leaf texel (darkTexel).
--
-- TALL GRASS (rounds 2-5). Keyed through the ground key, the tile keeps only
-- its leaf OUTLINES -- the leaf fills are ground colours (0xa5e6c5 /
-- 0x73cea5 / 0x42b58c: 62 of the plant's 184 texels) -- which was the
-- hollow "shell"; opaque whole-tile cards showed those fills as pale mint
-- slabs at eye level. Round 5: each cell is five small CLUMPS (a ring of
-- four round the centre + one on it, the ring turned per cell), each two
-- opaque blade triangles side by side -- an "M" with two points on top --
-- whose UVs run from a leaf tip down to the dark stem rows (GRASS_BLADES:
-- no background texel, mostly the art's dark greens), shaded ambient-only
-- (normals turned from sun and fill). Hiding: ~40 % of a 0.9-cell Pokemon
-- from 3-5 cells, ~30 % from 2 (Ctx:grass). 10 triangles a cell (+ the
-- mesher's 2-triangle base); border rings 4.
--
-- FLOWERS (round 2). Two keyed cards of the whole flower tile (blooms and
-- leaves; the ground keys away), each leaning FLOWER_LEAN -- one east-west
-- toward the north, one north-south toward the west -- so the clump reads
-- from above and from the side. 4 triangles.
--
-- UNDERSTORY. The forest-edge closure keeps the mesher's corner logic, but
-- with flora it is a flat DARK fill (one texel of the art's darkest leaf
-- colour, downward normal = ambient-only shade, never a lit leaf-textured
-- wall), FLORA_UNDER_INSET deep (near the edge trees' trunk line), as tall
-- as the r11 closure so the understory rays still stop; the hems hide all
-- but a sliver of it from eye height.
--
-- Costs (triangles; each at or under the r11 crown it replaces): conifer
-- near edge 69 (5-sided lathe 4 bands 40 + pointed apex 5 + stub 4 + two
-- scalloped hems 20; r11 72), inner / second row 50 (r11 56), single cell
-- 54 (r11 56),
-- far (border ring, depth 3-4) 6; canopy 4 (+ 2 per skirt, at most 12);
-- broadleaf near 52 (dome 30 + hem 18 + trunk 4), inner 30, far 18. Grass
-- cell 10 (+ the mesher's 2-triangle base; border ring 4), flower cell 4.
-- FLORA_CROWN = "c88" (round 11, the default since w7.18; "lathe" = the
-- crowns above): edge and single 80 (6 half-sprite faces x 10 + the row-32
-- dark band 12 + trunk 4 + the baked-shadow ground decal 4, keyed; 86 with
-- FLORA_C88_U = 1; 88 without the shadow cut), inner 36 -- above the r11
-- edge 72 / single 56, so edge-heavy maps (Route 23, Route 1 ...) exceed
-- their r11 totals by up to ~6 % (accepted by the coordinator, round 11:
-- the gates are <= 60k a map and <= 45k an eye).

local F = {}
F.VERSION = "w7.18"

-- Tunables. deps.Constants may override any key of the same name.
F.DEFAULTS = {
  FLORA_CONIFER_H = 2.8,       -- conifer top above ground (x hashed scale)
  FLORA_CONIFER_R = 1.0,       -- widest crown radius of a 2x2 conifer (walls touch; hem bands overlap)
  FLORA_SINGLE = 0.6,          -- a tree cell without a 2x2 partner: scale
  FLORA_SCALE_JITTER = 0.06,   -- +- hashed size
  FLORA_JITTER = 0.03,         -- +- hashed crown offset (the trunk stays centred)
  FLORA_HEM = 0.11,            -- crown bottom, fraction of the tree height
  FLORA_OVERLAP = 1.25,        -- card width over the ring's chord
  FLORA_HEM_K = 0.8,           -- pentagon side corners at this fraction of the card
  FLORA_NORMAL_UP = 0.45,      -- card normals bent up (softer side shading)
  FLORA_TRUNK_W = 0.11,        -- trunk half width (2x2); singles 0.6x
  FLORA_BROAD_H = 2.9,         -- broadleaf (FOREST3) top
  FLORA_BROAD_R = 1.5,         -- broadleaf widest radius
  FLORA_UNDER_INSET = 0.95,    -- understory fill inside the forest edge (2x2 units)
  FLORA_UNDER_INSET_1 = 0.6,   -- single-cell units
  FLORA_UNDER_INSET_BLOB = 0.85,
  FLORA_UNDER_H = 0.6,         -- fill height (the hems hide it from eye height)
  FLORA_UNDER_H_BROAD = 0.9,
  FLORA_GRASS_BLADE_W = 0.54,  -- a clump's base width (+- 0.04)
  FLORA_GRASS_H_TALL = 0.57,   -- clump heights: the tallest of a cell (in GRASS_CARD_H_MIN .. MAX) ...
  FLORA_GRASS_H_RING = 0.56,   -- ... two ring clumps (with TALL / LOW: the hiding) ...
  FLORA_GRASS_H_MID = 0.52,    -- ... the centre ...
  FLORA_GRASS_H_LOW = 0.5,
  FLORA_GRASS_H_VAR = 0.02,    -- +- per clump
  FLORA_GRASS_SHADE_VAR = 20,  -- +- degrees on the blades' shading direction
  FLORA_GRASS_TIP = 0.28,      -- a clump's two tips: this far (x its width) left / right of centre
  FLORA_GRASS_RING_TURN = 45,  -- +- degrees the ring of clumps turns per cell (45: any turn)
  FLORA_GRASS_YAW_VAR = 45,    -- +- degrees a ring clump turns off the tangent
  FLORA_GRASS_UP = 0.33,       -- blade normals: face + this much up (ny 0.31 > the w1 tuft test's 0.3)
  FLORA_GRASS_STYLE = "grid", -- "blades" (round 6: clumps scattered per cell) or "grid" (GRASS_GRID)
  FLORA_GRASS_H_GRID_C = 0.48,  -- grid style: the fan's face (sets the hiding from the south) ...
  FLORA_GRASS_H_GRID_ARM = 0.5, -- ... its arms ...
  FLORA_GRASS_H_GRID_SPINE = 0.46, -- ... the north / south spines
  FLORA_GRASS_GRID_ARM = 55,    -- grid style: the arms' turn off east-west (degrees)
  FLOWER_CARD_W = 0.66,        -- whole-tile flower card
  FLOWER_CARD_H = 0.6,         -- its length along the lean
  FLOWER_LEAN = 0.72,          -- radians each flower card leans back
  -- tree rows (round 5: "we only need like two rows of trees just to hide
  -- the sky"): depth = cells to the nearest non-forest cell (border rings:
  -- to the ring's inner hole)
  FLORA_ROW1_CELLS = 2,        -- depth <= this: the first row (near LOD on edge units)
  FLORA_ROW2_CELLS = 4,        -- depth <= this: the second row (inner LOD)
  FLORA_BORDER_TREE_CELLS = 2, -- border ring: inner LOD up to this depth ...
  FLORA_BORDER_FAR_CELLS = 4,  -- ... the far pyramid up to this one
  FLORA_CANOPY_Y = 0.62,       -- deeper: a canopy pillow at this fraction of the tree height ...
  FLORA_CANOPY_SLOPE = 0.3,    -- ... rising this much a cell deeper (toward the world edge) ...
  FLORA_CANOPY_MAX = 3.8,      -- ... up to this above its ground (over the 3.0 third-person eye)
  FLORA_CANOPY_RISE = 0.3,     -- its centre this much higher
  FLORA_CANOPY_EXT = 0.3,      -- past the unit's footprint on every side
  FLORA_CROWN_NY = 0.35,       -- conifer crown normals: at most this much up (darker tops)
  FLORA_CONIFER_SIDES = 5,     -- near edge conifers: lathe sides (inner / single units 5)
  FLORA_HEM_LOBE = "w",        -- conifer tier hems on edge units: "art" (the art's own hem, cut texel-stepped;
                               -- round 9), "v" / "u" / "w" lobes (Ctx:lathe opts.lobes; round 8 = "w") or "none"
  FLORA_HEM_LOBE_INNER = "v",  -- ... on inner (second-row) and single units (the middle tier only)
  FLORA_HEM_LOBE_D = 0.055,    -- ... hanging this fraction of the tree height below the rim
  FLORA_HEM_LOBE_LIFT = 0.04,  -- ... their tops this far up the tier's face (overlap: no crack)
  FLORA_HEM_ART_ZONE = 0.5,    -- "art" hems: search the rect's lower half for the outline ...
  FLORA_HEM_ART_DARK = 100,    -- ... texels whose every channel is <= this (the sprite's 0x3a5a10)
  FLORA_HEM_ART_MERGE = 1,     -- ... columns join a run when their cuts differ by <= this many rows (0 = exact)
  FLORA_HEM_ART_LIP = 0.08,    -- ... the dark lip under a cut run: this far in (half as far down); 0 = none
  FLORA_CROWN = "c88",         -- conifer crowns: "c88" (round 11: the sprite at one scale, ALIGNMENT_SPEC.md)
                               -- or "lathe" (the tiered teardrop, FLORA_HEM_LOBE hems; the default to w7.17)
  FLORA_C88_U = 0,             -- c88: 1 = the H3 U's bottom as a flap too (edge 94 tris; 0: 88)
  FLORA_C88_TIP_OVER = 0,      -- c88: 1 = the tip from the tile above's OVER layer when the dispatch
                               -- passes env.over (F13; OFF until w1 M13 exempts it); else / 0: the
                               -- under-layer 22/23 tip where validated, else one light texel
  FLORA_C88_TRUNK_TEXELS = 4,  -- c88: trunk half width in sprite columns (the art's trunk, x12-19, fills the arch)
  FLORA_C88_SHADOW_CUT = 1,    -- c88: 1 = the skirt ends at the last LEAF row; the sprite's baked ground shadow
                               -- (its dark rows around the trunk, found in the art) is not foliage (user, image 22)
  FLORA_C88_SHADOW = "decal",  -- c88 + cut: the baked shadow as "decal" (its own texels flat on the ground,
                               -- keyed) or "none" (the renderer's sun shadow only)
  FLORA_C88_DECAL_Z = 1.6,     -- ... decal: ground depth of one sprite row, in columns (the trunk's 5 rows over its 8)
  FLORA_C88_DECAL_LIFT = 0.012, -- ... decal: height above the ground (no z-fighting)
  FLORA_ART2_UVTRUE = 1,       -- "art2": 1 = the UV-true two-tier crown (round 10b), 0 = the round-10 three tiers
  FLORA_ART2_SIDES = 6,        -- ... its faces (even: the sprite's halves pair up)
  FLORA_HEM_ART2_MERGE = 1,    -- "art2": the U hem's runs join within this many rows ...
  FLORA_HEM_ART2_MERGE_BOTTOM = 2, -- ... the bottom tier's (UV-true crown: edge tree 70 tris)
  FLORA_HEM_ART_TOP = 0,       -- ... the top tier too (1: edge 84 tris, over the r11 72; 0 = the middle tier only, 69)
  FLORA_HEM_LOBE_DARK = 0.7,   -- ... their tips' normals this far from the face's toward straight down
}

-- ---------------------------------------------------------------------
-- small helpers
-- ---------------------------------------------------------------------
local sqrt, cos, sin, pi, floor, max, min, abs = math.sqrt, math.cos, math.sin, math.pi, math.floor, math.max, math.min, math.abs

-- same integer hash as FrlgMesher.hash01 (exact integer math)
local function hash01(a, b, salt)
  local Mo = 16777213
  local h = (a * 7919 + b * 104729 + salt * 1299709 + 4099) % Mo
  h = (h * 48271) % Mo
  h = (h * 48271 + 12345) % Mo
  return h / Mo
end
F.hash01 = hash01

-- the renderer's ground key (render/Mip.lua KEYS), 0xRRGGBB
local KEY = { [0x73cea5] = true, [0x42b58c] = true, [0xa5e6c5] = true, [0xbdefd6] = true }
F.KEY = KEY

-- texel-space sub-rect of a tile rect r = {u0, v0, u1, v1}: x0..x1, y0..y1
-- in texels (0..16, exclusive ends) -> u0, v0, u1, v1
local function texRect(r, x0, y0, x1, y1)
  local du, dv = (r[3] - r[1]) / 16, (r[4] - r[2]) / 16
  return r[1] + du * x0, r[2] + dv * y0, r[1] + du * x1, r[2] + dv * y1
end

-- ---------------------------------------------------------------------
-- art analysis (optional atlas.texels): crop a texel box to the columns /
-- rows that hold at least `need` non-ground texels
-- ---------------------------------------------------------------------
local function cropBox(tex, x0, y0, x1, y1, need)
  if not tex then return x0, y0, x1, y1 end
  need = need or 2
  local function colCount(x)
    local n = 0
    for y = y0, y1 - 1 do
      local v = tex[y * 16 + x + 1]
      if v and v >= 0 and not KEY[v] then n = n + 1 end
    end
    return n
  end
  local function rowCount(y, a, b)
    local n = 0
    for x = a, b - 1 do
      local v = tex[y * 16 + x + 1]
      if v and v >= 0 and not KEY[v] then n = n + 1 end
    end
    return n
  end
  local a, b = x0, x1
  while a < b - 1 and colCount(a) < need do a = a + 1 end
  while b > a + 1 and colCount(b - 1) < need do b = b - 1 end
  local c, d = y0, y1
  while c < d - 1 and rowCount(c, a, b) < need do c = c + 1 end
  while d > c + 1 and rowCount(d - 1, a, b) < need do d = d - 1 end
  return a, c, b, d
end
F.cropBox = cropBox

-- the most common colour among texels whose max channel is 40..maxLum and
-- that are not ground colours; returns its texel index (1..256) or nil
local function darkTexel(tex, maxLum)
  if not tex then return nil end
  local cnt, first, best, bn = {}, {}, nil, 0
  for i = 1, 256 do
    local v = tex[i]
    if v and v >= 0 and not KEY[v] then
      local r, g, b = floor(v / 65536), floor(v / 256) % 256, v % 256
      if max(r, g, b) <= maxLum and max(r, g, b) >= 40 then
        cnt[v] = (cnt[v] or 0) + 1
        first[v] = first[v] or i
        if cnt[v] > bn then best, bn = first[v], cnt[v] end
      end
    end
  end
  return best
end
F.darkTexel = darkTexel

-- ---------------------------------------------------------------------
-- context
-- ---------------------------------------------------------------------
local Ctx = {}
Ctx.__index = Ctx
F.Ctx = Ctx

-- env = { C, MB, atlas, underRect(mid) -> {u0,v0,u1,v1}|nil (shared,
--   read-only), newV(x,y,z,u,v,nx,ny,nz) -> vertex, opaque, keyed,
--   isBorder, pair, forest3 (MB.FOREST3_PAIRS[pair] or nil); optional
--   (dispatch F12, the tree rows): at(x, y) -> cell, W, H, isForestCell(c),
--   borderDist (border rings: per cell y * W + x + 1, BFS steps to the
--   ring's inner hole); (dispatch F13, "c88" over-layer tip) over: the
--   mesher's cutoutOver list }
function F.new(env)
  if type(env) ~= "table" or type(env.underRect) ~= "function" or type(env.newV) ~= "function"
      or type(env.opaque) ~= "table" or type(env.keyed) ~= "table" then
    return nil, "flora: bad env"
  end
  local C = {}
  for k, v in pairs(F.DEFAULTS) do C[k] = v end
  for k, v in pairs(env.C or {}) do C[k] = v end
  return setmetatable({
    C = C, MB = env.MB or {}, atlas = env.atlas or {}, underRect = env.underRect, newV = env.newV,
    opaque = env.opaque, keyed = env.keyed, isBorder = env.isBorder == true, forest3 = env.forest3,
    at = env.at, W = env.W, H = env.H, isForestCell = env.isForestCell, borderDist = env.borderDist,
    over = env.over,
    texCache = {}, artCache = {},
    stats = { version = F.VERSION, units = 0, conifers = 0, broadleaf = 0, grassCells = 0, flowerCells = 0,
      treeTris = 0, grassTris = 0, canopy = 0 },
  }, Ctx)
end

function Ctx:texels(mid)
  local t = self.texCache[mid]
  if t ~= nil then return t or nil end
  t = false
  local fn = self.atlas.texels
  if type(fn) == "function" then
    local ok, r = pcall(fn, mid, "under")
    if ok and type(r) == "table" and #r >= 256 then t = r end
  end
  self.texCache[mid] = t
  return t or nil
end

-- first mid of `list` that has an under rect
-- a mid the pair's atlas really holds: the atlases answer a missing mid
-- with the slot of mid 0 (WorldSource rect(): "midToSlot[mid] or
-- midToSlot[0]"), so a rect equal to an absent mid's is no tile (a pair
-- without the general tileset's tree tiles drew black crowns)
function Ctx:hasMid(m)
  if m == nil then return false end
  local r = self.underRect(m)
  if not r then return false end
  if m == 0 then return true end
  local fb = self.absentRect
  if fb == nil then
    fb = self.underRect(-1) or false
    self.absentRect = fb
  end
  return not (fb and r[1] == fb[1] and r[2] == fb[2] and r[3] == fb[3] and r[4] == fb[4])
end

function Ctx:pick(list)
  for _, m in ipairs(list) do
    if m and self:hasMid(m) then return m end
  end
  return nil
end

-- a crop box of tile `mid` as a UV rect { u0, v0, u1, v1, inner = side };
-- box = { x0, y0, x1, y1 } texels; `inner` ("l" / "r" / nil) = the side
-- facing the tree's centre line (a triangle card puts its apex there)
function Ctx:boxUv(mid, box, need, inner)
  local r = self.underRect(mid)
  if not r then return nil end
  local x0, y0, x1, y1 = cropBox(self:texels(mid), box[1], box[2], box[3], box[4], need)
  local u0, v0, u1, v1 = texRect(r, x0, y0, x1, y1)
  return { u0, v0, u1, v1, inner = inner, mid = mid, box = { x0, y0, x1, y1 } }
end

-- (tree round 9, USER: "the lobes should just follow the original
-- texture, it's already drawn for you, just adjust it for voxel") The hem a
-- band rect's own art draws: per texel column, scanning up from the rect's
-- bottom row through its lower FLORA_HEM_ART_ZONE, the first OUTLINE texel
-- (the sprite's dark outline colour: every channel <= FLORA_HEM_ART_DARK)
-- -- the rows below it are cut away, the outline texel itself stays as the
-- tier's dark rim. Columns join into runs (neighbours whose cut differs by
-- <= FLORA_HEM_ART_MERGE rows; a run keeps its smallest cut). Returns runs
-- in face order (f = 0 at the rect's u1 side, the lathe's vertex A; 1 at
-- u0): { fa, fb, cut } with cut a fraction of the rect's height; nil
-- without texels or when nothing is cut. Cached per rect.
function Ctx:hemRuns(rect)
  local cache = self.hemCache
  if not cache then cache = {}; self.hemCache = cache end
  local hit = cache[rect]
  if hit ~= nil then return hit or nil end
  local runs = false
  local tex = rect.mid and rect.box and self:texels(rect.mid)
  if tex then
    local C = self.C
    local x0, y0, x1, y1 = rect.box[1], rect.box[2], rect.box[3], rect.box[4]
    local rows = y1 - y0
    local ystart = y0 + floor(rows * (1 - C.FLORA_HEM_ART_ZONE))
    local dark = C.FLORA_HEM_ART_DARK
    local list, any = {}, false
    for x = x1 - 1, x0, -1 do          -- face order: from the u1 side
      local cut = 0
      for y = y1 - 1, ystart, -1 do
        local v = tex[y * 16 + x + 1]
        if v and v >= 0 and not KEY[v] then
          local r, g, b = floor(v / 65536), floor(v / 256) % 256, v % 256
          if max(r, g, b) <= dark then cut = y1 - 1 - y; break end
        end
      end
      if cut > 0 then any = true end
      local f0, f1 = (x1 - 1 - x) / (x1 - x0), (x1 - x) / (x1 - x0)
      local last = list[#list]
      if last and abs(cut - last.c0) <= C.FLORA_HEM_ART_MERGE then
        last[2] = f1
        if cut < last[3] then last[3] = cut end
      else
        list[#list + 1] = { f0, f1, cut, c0 = cut }
      end
    end
    if any then
      runs = {}
      for _, r in ipairs(list) do runs[#runs + 1] = { r[1], r[2], r[3] / rows } end
      if #runs == 1 and runs[1][3] == 0 then runs = false end
    end
  end
  cache[rect] = runs
  return runs or nil
end

-- one texel (its centre) of tile `mid` as a degenerate UV rect
function Ctx:texelUv(mid, idx)
  local r = self.underRect(mid)
  if not r then return nil end
  local tx, ty = (idx - 1) % 16 + 0.5, floor((idx - 1) / 16) + 0.5
  local u, v = texRect(r, tx, ty, tx, ty)
  return { u, v, u, v }
end

-- a swatch spec { mid, u0, v0, u1, v1 } (MB.*_SWATCH form) as a UV rect
function Ctx:swatch(ls)
  local r = ls and self:hasMid(ls.mid) and self.underRect(ls.mid)
  if not r then return nil end
  return { r[1] + (r[3] - r[1]) * ls.u0, r[2] + (r[4] - r[2]) * ls.v0,
           r[1] + (r[3] - r[1]) * ls.u1, r[2] + (r[4] - r[2]) * ls.v1 }
end

-- the darkest common leaf colour of a tile as one texel (core, understory)
function Ctx:coreUv(mid)
  local t = self:texels(mid)
  local idx = t and darkTexel(t, 110)
  if idx then return self:texelUv(mid, idx) end
  return nil
end

-- ---------------------------------------------------------------------
-- art sets
-- ---------------------------------------------------------------------
-- General-tileset 2x2 conifer (w7/art: tree_full.png). Roles: TL / TR =
-- the top tiles (clean variants first; 28 / 29 carry a neighbour's shadow
-- in their outer top corners), BL / BR = the bottom tiles. Boxes in texels
-- (x0, y0, x1, y1, exclusive ends); the tree's centre line is TL's / BL's
-- right edge and TR's / BR's left edge.
local CONIFER = {
  TL = { 30, 28 }, TR = { 31, 29 }, BL = { 36, 38, 20, 22 }, BR = { 37, 39, 21, 23 },
  -- (tree round 2: the crown is an OPAQUE lathe, so every box stays clear
  -- of the tiles' ground-coloured corners and of the trunk texels)
  apex = { { 5, 0, 16, 8 }, { 0, 0, 11, 8 } },     -- the upper rows, light clumps
  mid = { { 2, 6, 16, 16 }, { 0, 6, 14, 16 } },    -- side clumps + lower scallops
  deep = { { 2, 9, 16, 16 }, { 0, 9, 14, 16 } },   -- their deeper-green lower rows
  low = { { 4, 0, 12, 10 }, { 4, 0, 12, 10 } },    -- dark clump rows + their outline (x 3 BL / x 12 BR hold the
                                                   -- sprite's 0x19a56b edge texels: a teal square, round 8 review)
  -- 28 / 29 variants: the shadowed outer corners cut away
  apex2 = { { 5, 0, 16, 8 }, { 0, 0, 11, 8 } },
  mid2 = { { 3, 6, 16, 16 }, { 0, 6, 13, 16 } },
  deep2 = { { 3, 9, 16, 16 }, { 0, 9, 13, 16 } },
}
F.CONIFER = CONIFER

function Ctx:coniferArt()
  local a = self.artCache.conifer
  if a == nil then
    a = false
    local tl, tr = self:pick(CONIFER.TL), self:pick(CONIFER.TR)
    local bl, br = self:pick(CONIFER.BL), self:pick(CONIFER.BR)
    if tl and tr then
      local apL, apR = CONIFER.apex[1], CONIFER.apex[2]
      local miL, miR = CONIFER.mid[1], CONIFER.mid[2]
      local dpL, dpR = CONIFER.deep[1], CONIFER.deep[2]
      if tl ~= 30 then apL, miL, dpL = CONIFER.apex2[1], CONIFER.mid2[1], CONIFER.deep2[1] end
      if tr ~= 31 then apR, miR, dpR = CONIFER.apex2[2], CONIFER.mid2[2], CONIFER.deep2[2] end
      local loL, loR = CONIFER.low[1], CONIFER.low[2]
      if not bl then bl, loL = tl, { 0, 8, 16, 16 } end
      if not br then br, loR = tr, { 0, 8, 16, 16 } end
      a = {
        apex = { self:boxUv(tl, apL, 1, "r"), self:boxUv(tr, apR, 1, "l") },
        mid = { self:boxUv(tl, miL, 2, "r"), self:boxUv(tr, miR, 2, "l") },
        deep = { self:boxUv(tl, dpL, 2, "r"), self:boxUv(tr, dpR, 2, "l") },
        low = { self:boxUv(bl, loL, 2, "r"), self:boxUv(br, loR, 2, "l") },
        core = self:coreUv(bl) or self:swatch(self.MB.DARK_SWATCH),
        bark = self:swatch(self.MB.BARK_SWATCH),
        mids = { tl, tr, bl, br },
      }
      a.core = a.core or a.low[1]
      a.bark = a.bark or a.core
    end
    self.artCache.conifer = a
  end
  return a or nil
end

-- Fallback when the pair's atlas has none of the CONIFER tiles: the
-- unit's own cell tiles (its first cell = top, its last = bottom), so every
-- tree unit still gets a crown
function Ctx:unitArt(u)
  local cells = u.cells or {}
  local top = cells[1] and cells[1].mid
  local bot = cells[#cells] and cells[#cells].mid
  if not (top and self.underRect(top)) then return nil end
  if not (bot and self.underRect(bot)) then bot = top end
  local full = { 0, 0, 16, 16 }
  local t = self:boxUv(top, full, 2)
  local b = self:boxUv(bot, { 0, 0, 16, 12 }, 2)
  local core = self:coreUv(bot) or self:swatch(self.MB.DARK_SWATCH) or b
  return { apex = { t }, mid = { t }, deep = { t }, low = { b }, core = core, bark = self:swatch(self.MB.BARK_SWATCH) or core }
end

-- Broadleaf (FOREST3, Viridian Forest / Pattern Bush; w7/art/forest3_*.png):
-- a tree is 3 columns x 2 rows; the CENTRE column's art is in the OVER layer
-- (its under tiles are plain grass), so the canopy uses the left and right
-- columns' under art, alternating: dome faces cropped inside the canopy's
-- teal / ground outline, hem cards whole tiles (keyed: the outline stays).
local BROAD = {
  upL = { 3, 0, 16, 16 }, upR = { 0, 0, 13, 16 },    -- upper row, inside the outline
  loL = { 2, 0, 16, 11 }, loR = { 0, 0, 14, 11 },    -- lower row above its scallops
  hem = { 0, 0, 16, 16 },                          -- lower row, whole (keyed)
}
F.BROAD = BROAD

function Ctx:broadArt()
  local a = self.artCache.broad
  if a == nil then
    a = false
    local f3 = self.forest3
    if f3 then
      local up, lo = {}, {}
      for m, col in pairs(f3.upper or {}) do
        -- the plain upper row (664 / 666) over the column-top variants
        if self:hasMid(m) and (up[col] == nil or m > up[col]) then up[col] = m end
      end
      for m, col in pairs(f3.lower or {}) do
        -- the plain lower row (656 / 658) over the trunk / edge variants
        if self:hasMid(m) and (lo[col] == nil or m < lo[col]) then lo[col] = m end
      end
      if up[1] and up[3] and lo[1] and lo[3] then
        local boxes = type(f3.broad) == "table" and f3.broad or BROAD
        local function box(mid, name, fallback, need, inner)
          local r = self:boxUv(mid, boxes[name] or fallback, need, inner)
          local inset = boxes.uvInset
          if r and type(inset) == "number" and inset > 0 and r.box[3] - r.box[1] > inset * 2
              and r.box[4] - r.box[2] > inset * 2 then
            local tile = self.underRect(mid)
            local du, dv = (tile[3] - tile[1]) / 16 * inset, (tile[4] - tile[2]) / 16 * inset
            r[1], r[2], r[3], r[4] = r[1] + du, r[2] + dv, r[3] - du, r[4] - dv
          end
          return r
        end
        a = {
          upper = { box(up[1], "upL", BROAD.upL, 1, "r"), box(up[3], "upR", BROAD.upR, 1, "l") },
          lower = { box(lo[1], "loL", BROAD.loL, 1, "r"), box(lo[3], "loR", BROAD.loR, 1, "l") },
          hem = { box(lo[1], "hemL", BROAD.hem, 2, "r"), box(lo[3], "hemR", BROAD.hem, 2, "l") },
          core = self:coreUv(lo[1]) or self:swatch(f3.dark) or self:swatch(self.MB.DARK_SWATCH),
          bark = self:swatch(f3.bark) or self:swatch(self.MB.BARK_SWATCH),
        }
        a.cap = a.upper[1]
        a.core = a.core or a.lower[1]
        a.bark = a.bark or a.core
      end
    end
    self.artCache.broad = a
  end
  return a or nil
end

-- ---------------------------------------------------------------------
-- card emitters
-- ---------------------------------------------------------------------
-- One card vertex: top centre (tx, ty, tz) + ss * S + tt * D (S the card's
-- horizontal axis, D its down-slope axis); normal: the cone normal of the
-- vertex's own azimuth round the tree axis (cx, cz) when cnr is given
-- (smooth: neighbouring cards shade continuously), else (fnx, cny, fnz).
-- A plain function (no per-card closure: the build runs with the JIT off).
local function cardV(newV, tx, ty, tz, sx, sz, dx, dy, dz, ss, tt, u, v, cx, cz, cnr, cny, fnx, fnz)
  local px, pz = tx + sx * ss + dx * tt, tz + sz * ss + dz * tt
  local nx, nz = fnx, fnz
  if cnr then
    local rx, rz = px - cx, pz - cz
    local rl = sqrt(rx * rx + rz * rz)
    if rl > 1e-4 then nx, nz = rx / rl * cnr, rz / rl * cnr end
  end
  return newV(px, ty + dy * tt, pz, u, v, nx, cny, nz)
end

-- A tier card on a cone: top centre at radius rt / height yt, hem centre at
-- radius rb / height yb, azimuth th (x = cos, z = sin), width w, one UV
-- rect (its u runs left -> right as seen from outside, v top -> hem;
-- `mirror` swaps u). shape: "pent" (shallow pointed hem, side corners at
-- hemK; 3 triangles), "rect" (2) or "tri" (apex at the top centre, which
-- samples the rect's top centre; 1). Normals: the cone surface's, bent up
-- by nUp; `flat` = one normal per card (far trees). Returns the triangle
-- count.
function Ctx:card(list, cx, cy, cz, th, rt, yt, rb, yb, w, uv, shape, nUp, hemK, mirror, flat)
  local newV = self.newV
  local c, s = cos(th), sin(th)
  local dr, dy = rb - rt, yb - yt
  local L = sqrt(dr * dr + dy * dy)
  if L < 1e-6 or not uv then return 0 end
  local dx, dyy, dz = c * dr / L, dy / L, s * dr / L
  local nr, ny = -dy / L, dr / L + (nUp or 0)
  local nl = sqrt(nr * nr + ny * ny)
  local cnr, cny = nr / nl, ny / nl
  local fnx, fnz = c * cnr, s * cnr
  local sm = cnr
  if flat then sm = nil end
  local sx, sz = s, -c                 -- S: the viewer's right from outside
  local tx, ty, tz = cx + c * rt, cy + yt, cz + s * rt
  local hw = w * 0.5
  local u0, v0, u1, v1 = uv[1], uv[2], uv[3], uv[4]
  local inner = uv.inner
  if mirror then
    u0, u1 = u1, u0
    inner = inner == "r" and "l" or (inner == "l" and "r" or nil)
  end
  local n = #list
  if shape == "tri" then
    -- apex on the box's top centre: an unsheared triangle of the art (the
    -- inner-edge apex smeared the pixels diagonally)
    local au = (u0 + u1) * 0.5
    list[n + 1] = newV(tx, ty, tz, au, v0, fnx, cny, fnz)
    list[n + 2] = cardV(newV, tx, ty, tz, sx, sz, dx, dyy, dz, -hw, L, u0, v1, cx, cz, sm, cny, fnx, fnz)
    list[n + 3] = cardV(newV, tx, ty, tz, sx, sz, dx, dyy, dz, hw, L, u1, v1, cx, cz, sm, cny, fnx, fnz)
    return 1
  end
  local TL = cardV(newV, tx, ty, tz, sx, sz, dx, dyy, dz, -hw, 0, u0, v0, cx, cz, sm, cny, fnx, fnz)
  local TR = cardV(newV, tx, ty, tz, sx, sz, dx, dyy, dz, hw, 0, u1, v0, cx, cz, sm, cny, fnx, fnz)
  if shape == "rect" then
    local BR = cardV(newV, tx, ty, tz, sx, sz, dx, dyy, dz, hw, L, u1, v1, cx, cz, sm, cny, fnx, fnz)
    local BL = cardV(newV, tx, ty, tz, sx, sz, dx, dyy, dz, -hw, L, u0, v1, cx, cz, sm, cny, fnx, fnz)
    list[n + 1], list[n + 2], list[n + 3] = TL, TR, BR
    list[n + 4], list[n + 5], list[n + 6] = TL, BR, BL
    return 2
  end
  local k = hemK or self.C.FLORA_HEM_K
  local vk = v0 + (v1 - v0) * k
  local BRk = cardV(newV, tx, ty, tz, sx, sz, dx, dyy, dz, hw, L * k, u1, vk, cx, cz, sm, cny, fnx, fnz)
  local BM = cardV(newV, tx, ty, tz, sx, sz, dx, dyy, dz, 0, L, (u0 + u1) * 0.5, v1, cx, cz, sm, cny, fnx, fnz)
  local BLk = cardV(newV, tx, ty, tz, sx, sz, dx, dyy, dz, -hw, L * k, u0, vk, cx, cz, sm, cny, fnx, fnz)
  list[n + 1], list[n + 2], list[n + 3] = TL, TR, BRk
  list[n + 4], list[n + 5], list[n + 6] = TL, BRk, BM
  list[n + 7], list[n + 8], list[n + 9] = TL, BM, BLk
  return 3
end

-- a ring of n cards (a tier) round (cx, gy, cz); uvs cycle per card
function Ctx:tier(list, cx, gy, cz, n, rot, rt, yt, rb, yb, uvs, shape, hemK, overlap, flat)
  local C = self.C
  local w = 2 * rb * sin(pi / n) * (overlap or C.FLORA_OVERLAP)
  local tris, m = 0, #uvs
  for i = 0, n - 1 do
    local th = rot + i / n * 2 * pi
    local uv = uvs[i % m + 1]
    tris = tris + self:card(list, cx, gy, cz, th, rt, yt, rb, yb, w, uv, shape, C.FLORA_NORMAL_UP, hemK, false, flat)
  end
  return tris
end

-- dark core cone: `sides` faces from radius r0 at y0 to the apex at y1;
-- flat face normals (never an up-normal apex: no "pole fan"); each face
-- maps the core UV rect (one texel)
function Ctx:core(cx, cy, cz, r0, y0, y1, sides, rot, uv)
  local list, newV = self.opaque, self.newV
  local n = #list
  local um, vm = (uv[1] + uv[3]) * 0.5, uv[2]
  local h = y1 - y0
  local rm = r0 * cos(pi / sides)
  local nl = sqrt(h * h + rm * rm)
  for i = 0, sides - 1 do
    local a0 = rot + i / sides * 2 * pi
    local a1 = rot + (i + 1) / sides * 2 * pi
    local am = (a0 + a1) * 0.5
    local nx, ny, nz = cos(am) * h / nl, rm / nl, sin(am) * h / nl
    local A = newV(cx, cy + y1, cz, um, vm, nx, ny, nz)
    local B = newV(cx + cos(a0) * r0, cy + y0, cz + sin(a0) * r0, uv[1], uv[4], nx, ny, nz)
    local Cc = newV(cx + cos(a1) * r0, cy + y0, cz + sin(a1) * r0, uv[3], uv[4], nx, ny, nz)
    list[n + 1], list[n + 2], list[n + 3] = A, B, Cc
    n = n + 3
  end
  return sides
end

-- trunk stub: two crossed quads (bark), from the ground into the crown
function Ctx:trunk(cx, gy, cz, hw, top, rot, uv)
  local list, newV = self.opaque, self.newV
  local n = #list
  for k = 0, 1 do
    local a = rot + k * pi * 0.5
    local c, s = cos(a), sin(a)
    local nx, nz = -s, c
    local ax, az = cx - c * hw, cz - s * hw
    local bx, bz = cx + c * hw, cz + s * hw
    local p1 = newV(ax, gy, az, uv[1], uv[4], nx, 0, nz)
    local p2 = newV(bx, gy, bz, uv[3], uv[4], nx, 0, nz)
    local p3 = newV(bx, top, bz, uv[3], uv[2], nx, 0, nz)
    local p4 = newV(ax, top, az, uv[1], uv[2], nx, 0, nz)
    list[n + 1], list[n + 2], list[n + 3] = p1, p2, p3
    list[n + 4], list[n + 5], list[n + 6] = p1, p3, p4
    n = n + 6
  end
  return 4
end

-- ---------------------------------------------------------------------
-- tree units
-- ---------------------------------------------------------------------
-- u = the mesher's unit { x, y, w, h?, cells, single, far, edge, dense,
-- open, forest3, noCrown, seam }; gy = its ground height. Emits the crown
-- and (near edge units) the trunk; returns the occluder { x, z, y0, y1, r }
-- (nil for a crownless seam half), trunk (bool) and the triangle count.
function Ctx:unit(u, gy)
  if u.noCrown then return nil, false, 0 end
  local C = self.C
  local w, h = u.w, u.h or u.w
  local ux, uy = u.x, u.y
  local cx0, cz0 = ux + w * 0.5, uy + h * 0.5            -- footprint centre
  local sc = 1 + (hash01(ux, uy, 75) - 0.5) * 2 * C.FLORA_SCALE_JITTER
  local jx = (hash01(ux, uy, 71) - 0.5) * 2 * C.FLORA_JITTER
  local jz = (hash01(ux, uy, 73) - 0.5) * 2 * C.FLORA_JITTER
  local rot = hash01(ux, uy, 77) * 2 * pi
  local cx, cz = cx0 + jx, cz0 + jz
  local occ, trunk, tris
  -- an edge unit is always the first row (full crown + trunk)
  local row, deep, depth = 1, 0, nil
  if not u.edge then row, deep, depth = self:treeRow(u) end
  local far = row == 3
  if u.forest3 and self:broadArt() then
    local art = self:broadArt()
    if row == 4 then
      occ, trunk, tris = self:canopy(u, gy, cx0, cz0, sc, art.lower[1], deep, depth)
    else
      occ, trunk, tris = self:broadleaf(u, gy, cx, cz, cx0, cz0, sc, rot, art, far)
    end
  else
    local art = self:coniferArt() or self:unitArt(u)
    if not art then return nil, false, 0 end
    if row == 4 then
      occ, trunk, tris = self:canopy(u, gy, cx0, cz0, sc, art.deep[1], deep, depth)
    else
      occ, trunk, tris = self:conifer(u, gy, cx, cz, cx0, cz0, sc, rot, art, far)
    end
  end
  self.stats.units = self.stats.units + 1
  self.stats.treeTris = self.stats.treeTris + tris
  return occ, trunk, tris
end

-- Tree rows (round 5). The first two rows of a forest facing open ground
-- hide the sky from first person, third person and the 3/4 camera; the
-- trees behind them are never seen whole, so they are not drawn: a canopy
-- pillow per unit closes the view down into the forest instead.
--   depth = BFS steps from the nearest in-grid non-forest cell (dispatch
--   F12 passes the grid); a unit's depth = its cells' minimum
--   row 1: depth <= FLORA_ROW1_CELLS (edge units: near LOD + trunk; units
--          open only diagonally: the inner LOD)
--   row 2: depth <= FLORA_ROW2_CELLS: the inner LOD
--   row 4: deeper: the canopy (4 triangles)
-- Border rings (the player stands in the hole): depth = the mesher's
-- borderDist; <= FLORA_BORDER_TREE_CELLS the inner LOD, <=
-- FLORA_BORDER_FAR_CELLS the far pyramid (row 3), deeper the canopy.
-- Without the grid (dispatch before F12) every non-edge unit is row 2
-- (row 3 when the mesher marked it far): the round-4 behaviour.
function Ctx:cellDepth()
  local d = self.depthMap
  if d == nil then
    d = false
    local W, H = tonumber(self.W), tonumber(self.H)
    if self.isBorder then
      if type(self.borderDist) == "table" and W then d = self.borderDist end
    elseif type(self.at) == "function" and type(self.isForestCell) == "function" and W and H and W > 0 then
      local at, isForest = self.at, self.isForestCell
      local q, head = {}, 1
      d = {}
      for y = 0, H - 1 do
        for x = 0, W - 1 do
          local c = at(x, y)
          if c and not isForest(c) then
            local k = y * W + x + 1
            d[k] = 0
            q[#q + 1] = k
          end
        end
      end
      while head <= #q do
        local k = q[head]
        head = head + 1
        local x = (k - 1) % W
        local dv = d[k] + 1
        if x > 0 and d[k - 1] == nil then d[k - 1] = dv; q[#q + 1] = k - 1 end
        if x < W - 1 and d[k + 1] == nil then d[k + 1] = dv; q[#q + 1] = k + 1 end
        if k > W and d[k - W] == nil then d[k - W] = dv; q[#q + 1] = k - W end
        if k <= (H - 1) * W and d[k + W] == nil then d[k + W] = dv; q[#q + 1] = k + W end
      end
      if head == 1 then d = false end
    end
    self.depthMap = d
  end
  return d or nil
end

function Ctx:treeRow(u)
  local d = self:cellDepth()
  if not d then return u.far and 3 or 2 end
  local C, W = self.C, self.W
  local m = math.huge
  for _, c in ipairs(u.cells or {}) do
    local v = c.x and c.y and d[c.y * W + c.x + 1]
    if v and v < m then m = v end
  end
  if self.isBorder then
    if m <= C.FLORA_BORDER_TREE_CELLS then return 2 end
    if m <= C.FLORA_BORDER_FAR_CELLS then return 3 end
    return 4, m - C.FLORA_BORDER_FAR_CELLS - 1, m
  end
  if m <= C.FLORA_ROW2_CELLS then return m <= C.FLORA_ROW1_CELLS and 1 or 2 end
  if m == math.huge then return 2 end
  return 4, m - C.FLORA_ROW2_CELLS - 1, m
end

-- the canopy pillow over a hidden unit: its footprint (+ EXT) at
-- CANOPY_Y x the tree height + CANOPY_SLOPE per cell deeper (deep = cells
-- past the last tree row; up to CANOPY_MAX: toward the world's edge the
-- canopy rises over the third-person eye, so a look just under the
-- horizon meets leaves, not the sky past the edge), the centre CANOPY_RISE higher, 4 triangles
-- of one leaf rect (uv) with one normal turned away from the sun (a dark
-- mass, not a lit lawn); heights hashed so overlapping neighbours never
-- lie in one plane
-- (0.58, 0.72, 0.43: no sun term at 42 degrees NW, ambient + a little
-- fill ~0.69; ny >= 0.7 so the ground-contact AO bake treats it as a top,
-- which it is, not a wall with a foot)
local CANOPY_N = (function()
  local x, y, z = 0.8, 1.0, 0.6
  local l = sqrt(x * x + y * y + z * z)
  return { x / l, y / l, z / l }
end)()
F.CANOPY_N = CANOPY_N

function Ctx:canopy(u, gy, cx0, cz0, sc, uv, deep, depth)
  local C = self.C
  local w, h = u.w, u.h or u.w
  local Ht = (u.forest3 and C.FLORA_BROAD_H or C.FLORA_CONIFER_H) * sc
  local yBase = gy + C.FLORA_CANOPY_Y * Ht
  local y = C.FLORA_CANOPY_Y * Ht + C.FLORA_CANOPY_SLOPE * (deep or 0)
  -- a border ring's outermost cells are the world's edge: full height there
  local edge = false
  if self.isBorder and self.W and self.H then
    for _, c in ipairs(u.cells or {}) do
      if c.x == 0 or c.y == 0 or c.x == self.W - 1 or c.y == self.H - 1 then edge = true end
    end
  end
  if edge or y > C.FLORA_CANOPY_MAX - C.FLORA_CANOPY_RISE then y = C.FLORA_CANOPY_MAX - C.FLORA_CANOPY_RISE end
  y = gy + y + (hash01(u.x, u.y, 91) - 0.5) * 0.12
  local yc = y + C.FLORA_CANOPY_RISE
  local e = C.FLORA_CANOPY_EXT
  local x0, x1, z0, z1 = u.x - e, u.x + w + e, u.y - e, u.y + h + e
  local u0, v0, u1, v1 = uv[1], uv[2], uv[3], uv[4]
  local nx, ny, nz = CANOPY_N[1], CANOPY_N[2], CANOPY_N[3]
  local newV, list = self.newV, self.opaque
  local P = { { x0, z0, u0, v0 }, { x1, z0, u1, v0 }, { x1, z1, u1, v1 }, { x0, z1, u0, v1 } }
  local T = newV(cx0, yc, cz0, (u0 + u1) * 0.5, (v0 + v1) * 0.5, nx, ny, nz)
  local n = #list
  for i = 1, 4 do
    local a, b = P[i], P[i % 4 + 1]
    list[n + 1] = newV(a[1], y, a[2], a[3], a[4], nx, ny, nz)
    list[n + 2] = newV(b[1], y, b[2], b[3], b[4], nx, ny, nz)
    list[n + 3] = T
    n = n + 3
  end
  local tris = 4
  -- skirts: a side facing shallower forest (toward the player) hangs down
  -- to the lowest canopy level, so a look along the rising terraces never
  -- slips between two of them and on under the canopy to the world's edge
  local d, W = self.depthMap, self.W
  if d and depth and y > yBase then
    local x0c, x1c, y0c, y1c = u.x, u.x + w - 1, u.y, u.y + h - 1
    local function shallower(ax, ay, bx, by)
      for yy = ay, by do
        for xx = ax, bx do
          if xx >= 0 and yy >= 0 and xx < W then
            local v = d[yy * W + xx + 1]
            if v and v < depth then return true end
          end
        end
      end
      return false
    end
    local yb = yBase - 0.2
    -- (on the extended edge, but only the footprint's own span: the skirts
    -- of two neighbours in one plane meet end to end, never overlap)
    local fx0, fx1, fz0, fz1 = u.x, u.x + w, u.y, u.y + h
    local S = {
      { shallower(x0c, y0c - 1, x1c, y0c - 1), fx0, z0, fx1, z0 },   -- north
      { shallower(x1c + 1, y0c, x1c + 1, y1c), x1, fz0, x1, fz1 },   -- east
      { shallower(x0c, y1c + 1, x1c, y1c + 1), fx1, z1, fx0, z1 },   -- south
      { shallower(x0c - 1, y0c, x0c - 1, y1c), x0, fz1, x0, fz0 },   -- west
    }
    for _, sd in ipairs(S) do
      if sd[1] then
        local A = newV(sd[2], y, sd[3], u0, v0, nx, ny, nz)
        local B = newV(sd[4], y, sd[5], u1, v0, nx, ny, nz)
        local Cc = newV(sd[4], yb, sd[5], u1, v1, nx, ny, nz)
        local D = newV(sd[2], yb, sd[3], u0, v1, nx, ny, nz)
        list[n + 1], list[n + 2], list[n + 3] = A, B, Cc
        list[n + 4], list[n + 5], list[n + 6] = A, Cc, D
        n, tris = n + 6, tris + 2
      end
    end
  end
  self.stats.canopy = self.stats.canopy + 1
  return { x = cx0, z = cz0, y0 = y - 0.4, y1 = yc, r = 0.5 * min(w, h) + e }, false, tris
end

-- Conifer (tree rounds 2-4). The sprite (general-tileset tree; w7/art
-- tree_full.png) is a TEARDROP: a pointed apex (2 px at row 3, 4 at 5, 10
-- at 7), then three scalloped tiers -- each tier's clump row widens past
-- the one above it (the notches: 14 -> 20 px at row 11, 22 -> 26 at 18,
-- 28 -> 30 at 25) with a dark outline row at its hem -- widest near the
-- bottom tier. Profile (t = height fraction of the crown above its bottom,
-- r = radius fraction of R); each NOTCH is a ring pair: the tier above's
-- hem (outer) just over the tier below's top (inner), the pair's band
-- facing down = the dark outline row:
local CONIFER_PROFILE = {
  { 0.00, 0.94 },                    -- bottom tier hem (dark clump rows)
  { 0.30, 0.74 }, { 0.31, 0.90 },    -- notch 1: the middle tier's hem
  { 0.53, 0.60 }, { 0.54, 0.72 },    -- notch 2: the top tier's hem
}                                    -- (the top tier: a straight cone to the apex)
local CONIFER_DARK = { [2] = true, [4] = true }   -- the two notch undersides
-- inner (forest) units: from notch 1 up (their bottom tier is hidden)
local CONIFER_INNER = { { 0.18, 0.86 }, { 0.30, 0.74 }, { 0.31, 0.90 }, { 0.53, 0.60 }, { 0.54, 0.72 } }
F.CONIFER_PROFILE = CONIFER_PROFILE

-- The dark lip under a cut hem run (art hems): the run's bottom edge Q1-Q2
-- and the same edge pulled in toward the axis by lip[1] and down by lip[2]
-- -- a short solid underside in one texel of the outline colour
-- (self.hemLipUv, set by the conifer), shaded down-and-out like the notch
-- undersides. 2 triangles.
function Ctx:hemLip(list, n, tris, cx, cz, Q1, Q2, lip)
  local uv = self.hemLipUv
  local newV = self.newV
  local function inner(Q)
    local dx, dz = Q[1] - cx, Q[3] - cz
    local l = sqrt(dx * dx + dz * dz)
    if l < 1e-6 then l = 1 end
    return newV(Q[1] - dx / l * lip[1], Q[2] - lip[2], Q[3] - dz / l * lip[1], uv[1], uv[2], dx / l * 0.4472136, -0.8944272, dz / l * 0.4472136)
  end
  local function outer(Q)
    local dx, dz = Q[1] - cx, Q[3] - cz
    local l = sqrt(dx * dx + dz * dz)
    if l < 1e-6 then l = 1 end
    return newV(Q[1], Q[2], Q[3], uv[1], uv[2], dx / l * 0.4472136, -0.8944272, dz / l * 0.4472136)
  end
  local O1, O2, I1, I2 = outer(Q1), outer(Q2), inner(Q1), inner(Q2)
  list[n + 1], list[n + 2], list[n + 3] = O1, O2, I2
  list[n + 4], list[n + 5], list[n + 6] = O1, I2, I1
  return n + 6, tris + 2
end

-- A lathe round (cx, cz): rings[k] = { y, r } ascending; band k (rings k ..
-- k+1) maps, on side i, the whole rect bandArt[k][i % #bandArt[k] + 1] (the
-- tree's left / right tiles in turn; the tile's top at the upper ring);
-- smooth normals from the profile (the light wraps round, no flat bands);
-- a cap fans the top ring to (cx, yTop, cz): opts.pointed = a point, each
-- face its own apex vertex with that face's normal, capUv mapped per face
-- (conifers); else a blunt cap in planar x/z UVs of capUv whose slope
-- stays under 35 degrees. opts.dark = { [k] = true }: band k keeps its own
-- flat normal (a notch underside). opts.lobes = { [k] = { shape, depth } }:
-- band k's bottom rim becomes a scalloped HEM (tree round 7): under each
-- side a lobe in the face's own plane, hanging `depth` below the rim --
-- "v" one triangle (tip at the side's middle), "u" two (a flat-bottomed
-- lobe over the side's middle half), "w" two (tips at a quarter and three
-- quarters: twice the lobes); cusps at the corners; the band's
-- rect is re-mapped so the lobe tips sit on its bottom texel row (UVs
-- stay inside the rect). sides <= 8. Returns the triangle count.
function Ctx:lathe(list, cx, cz, rings, yTop, sides, rot, bandArt, capUv, opts)
  local newV = self.newV
  local K = #rings
  opts = opts or {}
  local dark = opts.dark or {}
  local lobes = opts.lobes or {}
  local artHem = opts.artHem or {}
  if not opts.pointed then
    -- a blunt top: the cap rises at most tan(30) of its radius
    local capRise = 0.57 * rings[K][2]
    if yTop - rings[K][1] > capRise then
      rings[K] = { yTop - capRise, rings[K][2] }
    end
  end
  local ca, sa = {}, {}
  for i = 0, sides do
    local a = rot + i / sides * 2 * pi
    ca[i], sa[i] = cos(a), sin(a)
  end
  -- profile normal per ring: perpendicular to the profile tangent
  local nr, ny = {}, {}
  for k = 1, K do
    local a = rings[k > 1 and k - 1 or 1]
    local b = k < K and rings[k + 1] or { yTop, 0 }
    local ty, tr = b[1] - a[1], b[2] - a[2]
    local l = sqrt(ty * ty + tr * tr)
    nr[k], ny[k] = ty / l, -tr / l
    -- (round 4c: tops no brighter than the sides' upper bend)
    local cap = self.C.FLORA_CROWN_NY
    if ny[k] > cap then nr[k], ny[k] = sqrt(1 - cap * cap), cap end
  end
  local n, tris = #list, 0
  for k = 1, K - 1 do
    local art = bandArt[k]
    local y0, r0, y1, r1 = rings[k][1], rings[k][2], rings[k + 1][1], rings[k + 1][2]
    local nr0, ny0, nr1, ny1 = nr[k], ny[k], nr[k + 1], ny[k + 1]
    if dark[k] then
      -- a tier's underside (the dark outline row): the band's own normal
      local ty, tr = y1 - y0, r1 - r0
      local l = sqrt(ty * ty + tr * tr)
      nr0, ny0 = ty / l, -tr / l
      nr1, ny1 = nr0, ny0
    end
    local lb = lobes[k]
    local drop = lb and lb[2] / (y1 - y0) or 0     -- lobe offset per unit of face slope
    for i = 0, sides - 1 do
      local uv = art[i % #art + 1]
      local u0, v0, u1, v1 = uv[1], uv[2], uv[3], uv[4]
      local vr = v1
      if lb then vr = v1 - (v1 - v0) * lb[2] / (y1 - y0 + lb[2]) end
      -- seen from outside, side i + 1 is to the viewer's left
      local runs = artHem[k] and self:hemRuns(uv)
      if runs then
        -- the art's own hem: one quad a run, from its cut up to the top
        -- ring (bilinear on the face: f across, t up), and a dark lip
        -- under every cut run
        local function P(f, t)
          local c0, s0 = ca[i] + (ca[i + 1] - ca[i]) * f, sa[i] + (sa[i + 1] - sa[i]) * f
          local rr, yy = r0 + (r1 - r0) * t, y0 + (y1 - y0) * t
          local am = rot + (i + f) / sides * 2 * pi
          local nrr, nyy = nr0 + (nr1 - nr0) * t, ny0 + (ny1 - ny0) * t
          local nl = sqrt(nrr * nrr + nyy * nyy)
          return newV(cx + c0 * rr, yy, cz + s0 * rr, u1 + (u0 - u1) * f, v1 + (v0 - v1) * t,
            cos(am) * nrr / nl, nyy / nl, sin(am) * nrr / nl)
        end
        for _, run in ipairs(runs) do
          local fa, fb, c = run[1], run[2], run[3]
          local Q1, Q2, Q3, Q4 = P(fa, c), P(fb, c), P(fb, 1), P(fa, 1)
          list[n + 1], list[n + 2], list[n + 3] = Q1, Q2, Q3
          list[n + 4], list[n + 5], list[n + 6] = Q1, Q3, Q4
          n, tris = n + 6, tris + 2
          if c > 0 and artHem[k].lip then
            n, tris = self:hemLip(list, n, tris, cx, cz, Q1, Q2, artHem[k].lip)
          end
        end
      else
      local A = newV(cx + ca[i] * r0, y0, cz + sa[i] * r0, u1, vr, ca[i] * nr0, ny0, sa[i] * nr0)
      local B = newV(cx + ca[i + 1] * r0, y0, cz + sa[i + 1] * r0, u0, vr, ca[i + 1] * nr0, ny0, sa[i + 1] * nr0)
      local Cc = newV(cx + ca[i + 1] * r1, y1, cz + sa[i + 1] * r1, u0, v0, ca[i + 1] * nr1, ny1, sa[i + 1] * nr1)
      local D = newV(cx + ca[i] * r1, y1, cz + sa[i] * r1, u1, v0, ca[i] * nr1, ny1, sa[i] * nr1)
      list[n + 1], list[n + 2], list[n + 3] = A, B, Cc
      list[n + 4], list[n + 5], list[n + 6] = A, Cc, D
      n, tris = n + 6, tris + 2
      if lb then
        -- the hem lobe: points along the rim, pushed down the face's slope
        local function lobePt(f, rim)
          local c0, s0 = ca[i] + (ca[i + 1] - ca[i]) * f, sa[i] + (sa[i + 1] - sa[i]) * f
          local am = rot + (i + f) / sides * 2 * pi
          if rim then
            -- a lobe's TOP: on the face a little above the rim (LOBE_LIFT
            -- up the slope) and a hair proud of it (0.008 along the
            -- normal), so each lobe overlaps its band -- no crack along
            -- the rim, no shared plane (no z-fight, no T-junction)
            local lf = self.C.FLORA_HEM_LOBE_LIFT / (y1 - y0)
            local px = cx + c0 * r0 + c0 * (r1 - r0) * lf + c0 * nr0 * 0.008
            local pz = cz + s0 * r0 + s0 * (r1 - r0) * lf + s0 * nr0 * 0.008
            local py = y0 + (y1 - y0) * lf + ny0 * 0.008
            return newV(px, py, pz, u1 + (u0 - u1) * f, vr - (vr - v0) * lf, cos(am) * nr0, ny0, sin(am) * nr0)
          end
          local x = cx + c0 * r0 + c0 * (r0 - r1) * drop
          local z = cz + s0 * r0 + s0 * (r0 - r1) * drop
          -- the tip's normal turned down-and-out (ambient + a little fill):
          -- each lobe shades from the tier's green to a dark rim, the
          -- sprite's outlined clump
          local dn = self.C.FLORA_HEM_LOBE_DARK
          local tnr, tny = nr0 * (1 - dn), ny0 * (1 - dn) - dn
          local tl = sqrt(tnr * tnr + tny * tny)
          return newV(x, y0 - lb[2], z, u1 + (u0 - u1) * f, v1, cos(am) * tnr / tl, tny / tl, sin(am) * tnr / tl)
        end
        local LA, LB = lobePt(0, true), lobePt(1, true)
        if lb[1] == "w" then
          -- two lobes a side: tips at a quarter and three quarters
          local M, T1, T2 = lobePt(0.5, true), lobePt(0.25), lobePt(0.75)
          list[n + 1], list[n + 2], list[n + 3] = LA, M, T1
          list[n + 4], list[n + 5], list[n + 6] = M, LB, T2
          n, tris = n + 6, tris + 2
        elseif lb[1] == "u" then
          local P1, P2 = lobePt(0.25), lobePt(0.75)
          list[n + 1], list[n + 2], list[n + 3] = LA, LB, P2
          list[n + 4], list[n + 5], list[n + 6] = LA, P2, P1
          n, tris = n + 6, tris + 2
        else
          local M = lobePt(0.5)
          list[n + 1], list[n + 2], list[n + 3] = LA, LB, M
          n, tris = n + 3, tris + 1
        end
      end
      end -- (art hem / plain band)
    end
  end
  local yK, rK = rings[K][1], rings[K][2]
  local cu0, cv0, cdu, cdv = capUv[1], capUv[2], capUv[3] - capUv[1], capUv[4] - capUv[2]
  if opts.pointed then
    -- a pointed apex (the sprite narrows to a point): each face's own apex
    -- vertex carries that face's side normal (a cone, not a flat pole)
    local apexRuns = opts.artHemApex and self:hemRuns(capUv)
    for i = 0, sides - 1 do
      local am = (i + 0.5) / sides * 2 * pi + rot
      if apexRuns then
        -- the top tier's own hem: per run the triangle from its cut edge
        -- to the point (lines to the apex keep f: exactly the region above
        -- the run), and the lip under cut runs
        local T = newV(cx, yTop, cz, cu0 + cdu * 0.5, cv0, cos(am) * nr[K], ny[K], sin(am) * nr[K])
        local function P(f, t)
          local c0, s0 = ca[i] + (ca[i + 1] - ca[i]) * f, sa[i] + (sa[i + 1] - sa[i]) * f
          local fam = rot + (i + f) / sides * 2 * pi
          local rr, yy = rK * (1 - t), yK + (yTop - yK) * t
          return newV(cx + c0 * rr, yy, cz + s0 * rr, cu0 + cdu * (1 - f) + (cdu * 0.5 - cdu * (1 - f)) * t,
            cv0 + cdv * (1 - t), cos(fam) * nr[K], ny[K], sin(fam) * nr[K])
        end
        for _, run in ipairs(apexRuns) do
          local Q1, Q2 = P(run[1], run[3]), P(run[2], run[3])
          list[n + 1], list[n + 2], list[n + 3] = Q1, Q2, T
          n, tris = n + 3, tris + 1
          if run[3] > 0 and opts.artHemApex.lip then
            n, tris = self:hemLip(list, n, tris, cx, cz, Q1, Q2, opts.artHemApex.lip)
          end
        end
      else
      local A = newV(cx + ca[i] * rK, yK, cz + sa[i] * rK, cu0 + cdu, cv0 + cdv, ca[i] * nr[K], ny[K], sa[i] * nr[K])
      local B = newV(cx + ca[i + 1] * rK, yK, cz + sa[i + 1] * rK, cu0, cv0 + cdv, ca[i + 1] * nr[K], ny[K], sa[i + 1] * nr[K])
      local T = newV(cx, yTop, cz, cu0 + cdu * 0.5, cv0, cos(am) * nr[K], ny[K], sin(am) * nr[K])
      list[n + 1], list[n + 2], list[n + 3] = A, B, T
      n, tris = n + 3, tris + 1
      end -- (art hem / plain apex face)
    end
    return tris
  end
  local top = newV(cx, yTop, cz, cu0 + cdu * 0.5, cv0 + cdv * 0.5, 0, 1, 0)
  for i = 0, sides - 1 do
    local a0, a1 = ca[i], ca[i + 1]
    local b0, b1 = sa[i], sa[i + 1]
    list[n + 1] = newV(cx + a0 * rK, yK, cz + b0 * rK, cu0 + cdu * (0.5 + 0.5 * a0), cv0 + cdv * (0.5 + 0.5 * b0),
      a0 * nr[K], ny[K], b0 * nr[K])
    list[n + 2] = newV(cx + a1 * rK, yK, cz + b1 * rK, cu0 + cdu * (0.5 + 0.5 * a1), cv0 + cdv * (0.5 + 0.5 * b1),
      a1 * nr[K], ny[K], b1 * nr[K])
    list[n + 3] = top
    n, tris = n + 3, tris + 1
  end
  return tris
end

-- LOD (tree rounds 4-7: every level at or below the r11 crown it replaces
-- -- edge 72, inner 56, single 56, far 6 -- so flora never adds triangles
-- to a map):
--   near EDGE units: 5-sided lathe, bottom tier + both notches, the top
--     tier a straight cone to the point, stub, and (round 7, USER: "the
--     tier hems should be scalloped") two hem lobes a side under the
--     bottom tier's rim and the middle tier's rim ("w": 10 lobes a ring):
--     4 bands x 10 + apex 5 + stub 4 + 2 rims x 10 = 69
--   inner / second-row units: 5 sides, from above the bottom tier, one
--     lobe a side under the middle tier's rim ("v"): 4 x 10 + 5 + 5 = 50
--   single cells: 5 sides, the full profile, "v" under the middle rim:
--     40 + 5 + stub 4 + 5 = 54
--   far (border ring, depth 3-4): a 6-face pyramid of the art, 6
--   deeper: no tree (Ctx:canopy)
-- Band art: the bottom tier the bottom tiles' dark clump rows, the notch
-- undersides one texel of the darkest leaf colour (the outline row), the
-- middle tier the top tiles' deeper-green lower rows, the top tier their
-- side clumps. Lobe tips shade toward straight down (FLORA_HEM_LOBE_DARK):
-- each lobe darkens to its rim like the sprite's outlined leaf clumps.
-- ---------------------------------------------------------------------
-- "art2" conifers (tree round 10, USER: "the lobes should just follow the
-- original texture, it's already drawn for you, just adjust it for voxel")
-- ---------------------------------------------------------------------
-- The tree sprite read as ONE 32 x 32 image (the top tiles over the bottom
-- tiles). Its own tier hems, found from the texels at build time:
--   * the upper crown's hem: the chain of dark outline texels (every
--     channel <= FLORA_HEM_ART_DARK) with light leaf texels just above them
--     that spans the sprite's width -- the big U-shaped scallop that runs
--     ACROSS the top / bottom tile boundary (general tileset: row 11 at the
--     sides, 18 at the middle) -- traced column by column as the best path
--     (steps <= 2 rows a column) through those texels;
--   * the bottom tier's hem: the sprite's outer silhouette at the bottom
--     (ground key colours and the outline colour -- the leaf colour most
--     often next to the key, 0x19a56b: no teal rim) with the trunk texels
--     (brown: red > green) cut away too, so the 3D trunk shows where the
--     art draws it.
-- The lathe keeps its three tiers (CONIFER_PROFILE) and the faces keep
-- the sprite's left / right tiles in turn; the middle tier shows the top
-- tiles' rows 8-15 and ends on the U (cut texel-stepped: its lobes hang
-- from the notch, which attaches at the U's highest cut), the bottom tier
-- shows the whole bottom tiles and ends on the silhouette. Columns merge
-- into runs within FLORA_HEM_ART2_MERGE (middle) / _BOTTOM rows. nil (no
-- art2) without the four tiles' texels or without a U.
local SPRITE_X0, SPRITE_X1 = 2, 30          -- the sprite columns the faces show (left tile
                                            -- 2 .. 15 on even faces, right tile 16 .. 29 on odd)
local SPRITE_MIDTOP = 8                     -- the middle tier shows the top tiles' rows 8 .. 15

function Ctx:spriteHems(art)
  local a = self.artCache.sprite
  if a ~= nil then return a or nil end
  a = false
  local C = self.C
  local mids = art.mids
  local tex = {}
  for i = 1, 4 do tex[i] = mids and mids[i] and self:texels(mids[i]) end
  local rects = {}
  for i = 1, 4 do rects[i] = mids and mids[i] and self.underRect(mids[i]) end
  local function beside(l, r)
    -- r directly right of l in the atlas (the insets apart), same rows
    if not (l and r) then return false end
    local w = (l[3] - l[1]) / 16
    return abs(r[1] - l[3]) < w * 0.25 and abs(r[2] - l[2]) < 1e-9 and abs(r[4] - l[4]) < 1e-9
  end
  local _ = beside
  if tex[1] and tex[2] and tex[3] and tex[4] and rects[1] and rects[2] and rects[3] and rects[4] then
    local dark = C.FLORA_HEM_ART_DARK
    -- classes: 0 outside (ground key), 1 trunk, 2 dark outline, 3 light, 4 other leaf
    local cls = {}
    for y = 0, 31 do
      for x = 0, 31 do
        local t = tex[(y >= 16 and 3 or 1) + (x >= 16 and 1 or 0)]
        local v = t[(y % 16) * 16 + (x % 16) + 1]
        local k = 0
        if v and v >= 0 and not KEY[v] then
          local r, g, b = floor(v / 65536), floor(v / 256) % 256, v % 256
          if r > g then k = 1
          elseif max(r, g, b) <= dark then k = 2
          elseif g >= 0xd0 then k = 3
          else k = 4 end
        end
        cls[y * 32 + x] = k
      end
    end
    local function at(x, y) return cls[y * 32 + x] end
    -- the sprite's outline colour: the leaf colour most often next to the
    -- ground key (0x19a56b on the general tileset) -- the bottom tier's
    -- silhouette cut takes it too (no teal rim)
    local edgeCnt, edgeCol, edgeN = {}, nil, 0
    local function colAt(x, y)
      local t = tex[(y >= 16 and 3 or 1) + (x >= 16 and 1 or 0)]
      return t[(y % 16) * 16 + (x % 16) + 1]
    end
    for y = 0, 31 do
      for x = 0, 31 do
        if cls[y * 32 + x] >= 2 then
          local nearKey = false
          for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
            local xx, yy = x + d[1], y + d[2]
            if xx >= 0 and yy >= 0 and xx < 32 and yy < 32 and cls[yy * 32 + xx] == 0 then nearKey = true end
          end
          if nearKey then
            local v = colAt(x, y)
            edgeCnt[v] = (edgeCnt[v] or 0) + 1
            if edgeCnt[v] > edgeN then edgeCol, edgeN = v, edgeCnt[v] end
          end
        end
      end
    end
    -- the U: a path y(x) over x in [X0, X1), rows 6 .. 20, steps <= 2 a
    -- column, scoring dark texels with a light texel 1-2 rows above
    local Y0, Y1 = 6, 20
    local function score(x, y)
      if at(x, y) ~= 2 then return 0 end
      if (y >= 1 and at(x, y - 1) == 3) or (y >= 2 and at(x, y - 2) == 3) then return 1 end
      return 0
    end
    local best, from = {}, {}
    for y = Y0, Y1 do best[y] = score(SPRITE_X0, y) end
    for x = SPRITE_X0 + 1, SPRITE_X1 - 1 do
      local nb, nf = {}, {}
      for y = Y0, Y1 do
        local bs, bf
        for d = -2, 2 do
          local py = y - d
          if py >= Y0 and py <= Y1 then
            local sv = best[py] - 0.15 * abs(d)
            if bs == nil or sv > bs then bs, bf = sv, py end
          end
        end
        nb[y], nf[y] = bs + score(x, y), bf
      end
      best = nb
      from[x] = nf
    end
    local by, bv = Y0, -1
    for y = Y0, Y1 do if best[y] > bv then by, bv = y, best[y] end end
    local path = {}
    path[SPRITE_X1 - 1] = by
    for x = SPRITE_X1 - 1, SPRITE_X0 + 1, -1 do path[x - 1] = from[x][path[x]] end
    if bv >= 0.5 * (SPRITE_X1 - SPRITE_X0) then
      -- per column cuts in rows of each 16-row window
      local cutU, cutB, hemB = {}, {}, {}
      for x = SPRITE_X0, SPRITE_X1 - 1 do
        local u = path[x] < 15 and path[x] or 15
        if u < SPRITE_MIDTOP then u = SPRITE_MIDTOP end
        cutU[x] = 15 - u
        local last = path[x]
        local y = path[x] + 1
        while y <= 31 and at(x, y) >= 2 and colAt(x, y) ~= edgeCol do last = y; y = y + 1 end
        cutB[x] = last >= 16 and (31 - last) or 16
        hemB[x] = last
      end
      -- runs over one tile's columns [xa, xb), in face order (f = 0 at xb,
      -- the lathe's vertex A); a run holds columns whose cuts span <= merge
      -- rows and keeps the smallest (keepMore: more of the art) or the
      -- largest cut (never a trunk / outline / ground texel)
      local function runsOf(cut, xa, xb, keepMore, rows, merge)
        local list = {}
        for x = xb - 1, xa, -1 do
          local f0, f1 = (xb - 1 - x) / (xb - xa), (xb - x) / (xb - xa)
          local last = list[#list]
          if last and max(last.hi, cut[x]) - min(last.lo, cut[x]) <= merge then
            last[2] = f1
            if cut[x] < last.lo then last.lo = cut[x] end
            if cut[x] > last.hi then last.hi = cut[x] end
          else
            list[#list + 1] = { f0, f1, 0, hi = cut[x], lo = cut[x] }
          end
        end
        local out, cmax = {}, 0
        for _, r in ipairs(list) do
          local c = (keepMore and r.lo or r.hi) / rows
          out[#out + 1] = { r[1], r[2], c }
          if c > cmax then cmax = c end
        end
        return out, cmax
      end
      local mrows = 16 - SPRITE_MIDTOP
      local mU, mB = C.FLORA_HEM_ART2_MERGE, C.FLORA_HEM_ART2_MERGE_BOTTOM
      local upL, cL = runsOf(cutU, SPRITE_X0, 16, true, mrows, mU)
      local upR, cR = runsOf(cutU, 16, SPRITE_X1, true, mrows, mU)
      local botL = runsOf(cutB, SPRITE_X0, 16, false, 16, mB)
      local botR = runsOf(cutB, 16, SPRITE_X1, false, 16, mB)
      local tl, tr, bl, br = rects[1], rects[2], rects[3], rects[4]
      local function sub(r, x0, y0, x1, y1)
        local a0, b0, a1, b1 = texRect(r, x0, y0, x1, y1)
        return { a0, b0, a1, b1 }
      end
      -- (round 10b, the UV-true crown) per half, per column step k (c in
      -- [k, k + 1) from the centre line outward): the cone's kept bottom
      -- row (the U outline texel's bottom edge, clipped at 16; runs keep
      -- the largest) and the bottom tier's (the last kept texel's bottom
      -- edge; runs keep the smallest)
      local function colOf(h, k) return h == 1 and (15 - k) or (16 + k) end
      local function runsHalf(h, fn, mg, keepMore)
        local list2 = {}
        for k = 0, 13 do
          local v = fn(colOf(h, k))
          local last = list2[#list2]
          if last and max(last.hi, v) - min(last.lo, v) <= mg then
            last[2] = k + 1
            if v < last.lo then last.lo = v end
            if v > last.hi then last.hi = v end
          else
            list2[#list2 + 1] = { k, k + 1, hi = v, lo = v }
          end
        end
        for _, r in ipairs(list2) do r[3] = keepMore and r.hi or r.lo end
        return list2
      end
      -- the trunk the sprite draws between the bottom foliage (its
      -- centre columns, rows 16-31) is inside the 3D crown: those columns
      -- show the foliage columns just outside them, mirrored (their hem
      -- too), so no face carries a trunk or a trunk-shaped gap
      local cone3, bot3, ycMin, trunkC = {}, {}, 16, {}
      for h = 1, 2 do
        local tc = 0
        for k = 0, 6 do
          local x = colOf(h, k)
          local has = false
          for y = 16, 31 do if at(x, y) == 1 then has = true end end
          if has and tc == k then tc = k + 1 end
        end
        trunkC[h] = tc
      end
      for h = 1, 2 do
        local tc = trunkC[h]
        cone3[h] = runsHalf(h, function(x) local y = path[x] + 1; return y < 16 and y or 16 end, mU, true)
        bot3[h] = runsHalf(h, function(x)
          local k = (h == 1) and (15 - x) or (x - 16)
          if k < tc then x = colOf(h, 2 * tc - 1 - k) end
          local y = hemB[x] + 1
          return y > 16 and y or 16
        end, mB, false)
        for _, r in ipairs(cone3[h]) do if r[3] < ycMin then ycMin = r[3] end end
      end
      a = { up = { upL, upR }, bot = { botL, botR }, cmaxU = max(cL, cR), path = path, cutU = cutU, cutB = cutB, hemB = hemB,
        rects = rects,
        cone3 = cone3, bot3 = bot3, ycMin = ycMin, trunkC = trunkC,
        mid = { sub(tl, SPRITE_X0, SPRITE_MIDTOP, 16, 16), sub(tr, 0, SPRITE_MIDTOP, SPRITE_X1 - 16, 16) },
        low = { sub(bl, SPRITE_X0, 0, 16, 16), sub(br, 0, 0, SPRITE_X1 - 16, 16) } }
    end
  end
  self.artCache.sprite = a
  return a or nil
end

-- the art2 crown: the lathe's three tiers (CONIFER_PROFILE), faces the
-- sprite's left / right tiles in turn; the middle tier is the upper crown's
-- lower rows with its U hem cut, the bottom tier the bottom tiles with
-- their silhouette cut; the notch under the middle tier attaches at the U's
-- highest cut (its lobes hang free); the top tier and the notches as the
-- lathe. Returns occluder, trunk, triangle count.
function Ctx:conifer2(u, gy, cx, cz, cx0, cz0, sc, rot, art, sp, H, R, hem, crownH)
  local C = self.C
  local list, newV = self.opaque, self.newV
  local sides = C.FLORA_CONIFER_SIDES
  local P = CONIFER_PROFILE
  local function ring(k) return gy + hem + P[k][1] * crownH, P[k][2] * R end
  local y1, r1 = ring(1)
  local y2, r2 = ring(2)
  local y3, r3 = ring(3)
  local y4, r4 = ring(4)
  local y5, r5 = ring(5)
  local yT = gy + H
  local ca, sa = {}, {}
  for i = 0, sides do
    local a = rot + i / sides * 2 * pi
    ca[i], sa[i] = cos(a), sin(a)
  end
  local capNy = C.FLORA_CROWN_NY
  local function prof(ya, ra, yb, rb, flat)
    local ty, tr = yb - ya, rb - ra
    local l = sqrt(ty * ty + tr * tr)
    local nr, ny = ty / l, -tr / l
    if not flat and ny > capNy then nr, ny = sqrt(1 - capNy * capNy), capNy end
    return nr, ny
  end
  local nrB, nyB = prof(y1, r1, y2, r2)
  local nrM, nyM = prof(y3, r3, y4, r4)
  local nrT, nyT = prof(y5, r5, yT, 0)
  local cm = sp.cmaxU
  local y3c, r3c = y3 + cm * (y4 - y3), r3 + cm * (r4 - r3)
  local n, tris = #list, 0
  local core = art.core
  local function band(i, ya, ra, yb, rb, nr, ny, rc, runs)
    -- runs from each cut up to the band's top ring (bilinear on the face)
    local c0i, s0i, dci, dsi = ca[i], sa[i], ca[i + 1] - ca[i], sa[i + 1] - sa[i]
    local u1, du, v1, dv = rc[3], rc[1] - rc[3], rc[4], rc[2] - rc[4]
    local a0, da = rot + i / sides * 2 * pi, 2 * pi / sides
    for k = 1, #runs do
      local run = runs[k]
      local fa, fb, c = run[1], run[2], run[3]
      if c < 1 - 1e-9 then
        local rc_, yc_ = ra + (rb - ra) * c, ya + (yb - ya) * c
        local xa_, za_ = c0i + dci * fa, s0i + dsi * fa
        local xb_, zb_ = c0i + dci * fb, s0i + dsi * fb
        local ma, mb = a0 + da * fa, a0 + da * fb
        local nxa, nza, nxb, nzb = cos(ma) * nr, sin(ma) * nr, cos(mb) * nr, sin(mb) * nr
        local ua, ub, vc = u1 + du * fa, u1 + du * fb, v1 + dv * c
        local Q1 = newV(cx + xa_ * rc_, yc_, cz + za_ * rc_, ua, vc, nxa, ny, nza)
        local Q2 = newV(cx + xb_ * rc_, yc_, cz + zb_ * rc_, ub, vc, nxb, ny, nzb)
        local Q3 = newV(cx + xb_ * rb, yb, cz + zb_ * rb, ub, v1 + dv, nxb, ny, nzb)
        local Q4 = newV(cx + xa_ * rb, yb, cz + za_ * rb, ua, v1 + dv, nxa, ny, nza)
        list[n + 1], list[n + 2], list[n + 3] = Q1, Q2, Q3
        list[n + 4], list[n + 5], list[n + 6] = Q1, Q3, Q4
        n, tris = n + 6, tris + 2
      end
    end
  end
  local function darkBand(i, ya, ra, yb, rb)
    local nr, ny = prof(ya, ra, yb, rb, true)
    local cu, cv = core[1], core[2]
    local A = newV(cx + ca[i] * ra, ya, cz + sa[i] * ra, cu, cv, ca[i] * nr, ny, sa[i] * nr)
    local B = newV(cx + ca[i + 1] * ra, ya, cz + sa[i + 1] * ra, cu, cv, ca[i + 1] * nr, ny, sa[i + 1] * nr)
    local Cc = newV(cx + ca[i + 1] * rb, yb, cz + sa[i + 1] * rb, cu, cv, ca[i + 1] * nr, ny, sa[i + 1] * nr)
    local D = newV(cx + ca[i] * rb, yb, cz + sa[i] * rb, cu, cv, ca[i] * nr, ny, sa[i] * nr)
    list[n + 1], list[n + 2], list[n + 3] = A, B, Cc
    list[n + 4], list[n + 5], list[n + 6] = A, Cc, D
    n, tris = n + 6, tris + 2
  end
  local cap = art.mid[1]
  local cu0, cv0, cdu, cdv = cap[1], cap[2], cap[3] - cap[1], cap[4] - cap[2]
  for i = 0, sides - 1 do
    local h = i % 2 + 1
    band(i, y1, r1, y2, r2, nrB, nyB, sp.low[h], sp.bot[h])
    darkBand(i, y2, r2, y3c, r3c)
    band(i, y3, r3, y4, r4, nrM, nyM, sp.mid[h], sp.up[h])
    darkBand(i, y4, r4, y5, r5)
    -- the top tier: the lathe's pointed apex face
    local am = (i + 0.5) / sides * 2 * pi + rot
    local A = newV(cx + ca[i] * r5, y5, cz + sa[i] * r5, cu0 + cdu, cv0 + cdv, ca[i] * nrT, nyT, sa[i] * nrT)
    local B = newV(cx + ca[i + 1] * r5, y5, cz + sa[i + 1] * r5, cu0, cv0 + cdv, ca[i + 1] * nrT, nyT, sa[i + 1] * nrT)
    local T = newV(cx, yT, cz, cu0 + cdu * 0.5, cv0, cos(am) * nrT, nyT, sin(am) * nrT)
    list[n + 1], list[n + 2], list[n + 3] = A, B, T
    n, tris = n + 3, tris + 1
  end
  local tw = C.FLORA_TRUNK_W * sc
  tris = tris + self:trunk(cx0, gy, cz0, tw, gy + hem + 0.12 * H, rot, art.bark)
  self.stats.conifers = self.stats.conifers + 1
  return { x = cx, z = cz, y0 = gy + hem, y1 = yT, r = R }, true, tris
end

-- The UV-true art2 crown (tree round 10b, USER: "the top of the tree
-- isn't lined up with the texture; it's warping the lobes"). The sprite's
-- rows and columns land on the crown at ONE scale: row 0 (its top) at the
-- apex, row 32 (its bottom) at the hem, every row crownH / 32 tall; each
-- face shows one half of the sprite (left tile on even faces, right tile
-- on odd ones) measured from the tree's centre line outward, every column
-- the same width (the widest face, at the hem, shows 14): a face narrower
-- up the crown simply shows fewer columns -- straight-edged windows, no
-- fanning toward the point. The art's two tiers become the crown's two:
--   the upper cone (rows 0-16, the top tiles) to the pointed apex, its
--     rim cut on the art's U scallop (rows 11-16), fanned from the apex;
--   the bottom tier (rows 16-32, the bottom tiles) cut on the sprite's
--     silhouette and trunk, one quad (or a clipped polygon) a run;
--   a dark notch from the bottom tier's top ring up to the U's highest cut,
--     closing the scallops' gaps.
-- Faces: FLORA_ART2_SIDES (even: the halves pair up; 6). Runs: columns of
-- one hem row within FLORA_HEM_ART2_MERGE rows (cone) / _BOTTOM (bottom).
function Ctx:conifer3(u, gy, cx, cz, cx0, cz0, sc, rot, art, sp, H, R, hem, crownH)
  local C = self.C
  local list, newV = self.opaque, self.newV
  local sides = C.FLORA_ART2_SIDES
  local sv = crownH / 32
  local yA = gy + H
  local rRim, rTop, rHem = 0.90 * R, 0.80 * R, 0.94 * R
  local half = sin(pi / sides)
  local sh = 2 * rHem * half / 14             -- one texel column
  local capNy = C.FLORA_CROWN_NY
  local function prof(ya, ra, yb, rb, flat)
    local ty, tr = yb - ya, rb - ra
    local l = sqrt(ty * ty + tr * tr)
    local nr, ny = ty / l, -tr / l
    if not flat and ny > capNy then nr, ny = sqrt(1 - capNy * capNy), capNy end
    return nr, ny
  end
  local nrC, nyC = prof(yA - 16 * sv, rRim, yA, 0)
  local nrB, nyB = prof(yA - 32 * sv, rHem, yA - 16 * sv, rTop)
  local rects = sp.rects
  local path, hemB = sp.path, sp.hemB
  local coneRuns, botRuns, ycMin = sp.cone3, sp.bot3, sp.ycMin
  local ca, sa = {}, {}
  for i = 0, sides do
    local a = rot + i / sides * 2 * pi
    ca[i], sa[i] = cos(a), sin(a)
  end
  local n, tris = #list, 0
  for i = 0, sides - 1 do
    local h = i % 2 + 1
    local ce, ou = (h == 1) and i or (i + 1), (h == 1) and (i + 1) or i
    local ex, ez = ca[ou] - ca[ce], sa[ou] - sa[ce]
    local el = sqrt(ex * ex + ez * ez)
    ex, ez = ex / el, ez / el
    local topR, botR = rects[h], rects[2 + h]
    -- texture (c, y) -> vertex; y < 16 on the cone / top tile, else the bottom tier / tile
    local tcH = sp.trunkC[h]
    local function V(c, y, cone, mir)
      local rr = cone and (rRim * y / 16) or (rTop + (rHem - rTop) * (y - 16) / 16)
      local px, pz = cx + ca[ce] * rr + ex * c * sh, cz + sa[ce] * rr + ez * c * sh
      local py = yA - y * sv
      local rc = cone and topR or botR
      local cu = mir and (2 * tcH - c) or c
      local col = (h == 1) and (16 - cu) or cu
      local row = cone and y or (y - 16)
      local am
      if rr == 0 and c == 0 then am = rot + (i + 0.5) / sides * 2 * pi   -- the apex: the face's middle
      else am = math.atan2(pz - cz, px - cx) end
      local nr, ny = nrB, nyB
      if cone then nr, ny = nrC, nyC end
      return newV(px, py, pz, rc[1] + (rc[3] - rc[1]) * col / 16, rc[2] + (rc[4] - rc[2]) * row / 16,
        cos(am) * nr, ny, sin(am) * nr)
    end
    -- the cone: fan from the apex over the stepped hem, clipped by the
    -- face's outer edge c = kC * y
    local kC = 2 * rRim * half / sh / 16
    local apex = V(0, 0, true)
    local pts = {}
    local runs = coneRuns[h]
    local yPrev
    for ri, r in ipairs(runs) do
      local c0, c1, y = r[1], r[2], r[3]
      if ri == 1 then pts[#pts + 1] = { 0, y } end
      if yPrev and y ~= yPrev then
        -- the vertical step at c0 from yPrev to y (clipped at the edge)
        if c0 > kC * y then
          pts[#pts + 1] = { c0, c0 / kC }
          break
        end
        pts[#pts + 1] = { c0, y }
      end
      if c1 >= kC * y then
        pts[#pts + 1] = { kC * y, y }
        yPrev = nil
        break
      end
      pts[#pts + 1] = { c1, y }
      yPrev = y
      if ri == #runs then
        -- reached the last column still inside: up the outer edge
        pts[#pts + 1] = { c1, c1 / kC }
      end
    end
    for k = 1, #pts - 1 do
      local a, b = pts[k], pts[k + 1]
      if abs(a[1] - b[1]) + abs(a[2] - b[2]) > 1e-9 then
        list[n + 1], list[n + 2], list[n + 3] = apex, V(b[1], b[2], true), V(a[1], a[2], true)
        n, tris = n + 3, tris + 1
      end
    end
    -- the notch: the bottom tier's top ring up to the cone at the U's highest cut
    do
      local rq = rRim * ycMin / 16
      local yq = yA - ycMin * sv
      local y16 = yA - 16 * sv
      local nr, ny = prof(y16, rTop, yq, rq, true)
      local cu, cv = art.core[1], art.core[2]
      local function D(k, rr, yy) return newV(cx + ca[k] * rr, yy, cz + sa[k] * rr, cu, cv, ca[k] * nr, ny, sa[k] * nr) end
      local A1, B1, C1, D1 = D(i, rTop, y16), D(i + 1, rTop, y16), D(i + 1, rq, yq), D(i, rq, yq)
      list[n + 1], list[n + 2], list[n + 3] = A1, B1, C1
      list[n + 4], list[n + 5], list[n + 6] = A1, C1, D1
      n, tris = n + 6, tris + 2
    end
    -- the bottom tier: per run the part of [c0, c1] x [16, y] inside the
    -- face (c <= kB(y), kB growing linearly from the top ring to the hem)
    local function kB(y) return 2 * (rTop + (rHem - rTop) * (y - 16) / 16) * half / sh end
    local pieces = {}
    for _, r in ipairs(botRuns[h]) do
      if r[1] < tcH and r[2] > tcH then
        pieces[#pieces + 1] = { r[1], tcH, r[3], true }
        pieces[#pieces + 1] = { tcH, r[2], r[3], false }
      else
        pieces[#pieces + 1] = { r[1], r[2], r[3], r[2] <= tcH }
      end
    end
    for _, r in ipairs(pieces) do
      local c0, c1, y, mir = r[1], r[2], r[3], r[4]
      if y > 16 + 1e-9 then
        local poly = {}
        local cTop = kB(16)
        if c0 < cTop then
          poly[#poly + 1] = { c0, 16 }
          poly[#poly + 1] = { min(c1, cTop), 16 }
          if c1 > cTop then
            -- along the slanted edge to where it reaches c1 (or the run's bottom)
            local yEdge = 16 + (c1 - cTop) / (kB(32) - cTop) * 16
            if yEdge < y then
              poly[#poly + 1] = { c1, yEdge }
              poly[#poly + 1] = { c1, y }
            else
              poly[#poly + 1] = { kB(y), y }
            end
          else
            poly[#poly + 1] = { c1, y }
          end
          poly[#poly + 1] = { c0, y }
        else
          -- the run starts outside the top edge: from where the edge reaches c0
          local yEdge0 = 16 + (c0 - cTop) / (kB(32) - cTop) * 16
          if yEdge0 < y then
            local yEdge1 = 16 + (c1 - cTop) / (kB(32) - cTop) * 16
            poly[#poly + 1] = { c0, yEdge0 }
            if yEdge1 < y then
              poly[#poly + 1] = { c1, yEdge1 }
              poly[#poly + 1] = { c1, y }
            else
              poly[#poly + 1] = { kB(y), y }
            end
            poly[#poly + 1] = { c0, y }
          end
        end
        if #poly >= 3 then
          local P0 = V(poly[1][1], poly[1][2], false, mir)
          for k = 2, #poly - 1 do
            local Pa, Pb = V(poly[k][1], poly[k][2], false, mir), V(poly[k + 1][1], poly[k + 1][2], false, mir)
            list[n + 1], list[n + 2], list[n + 3] = P0, Pa, Pb
            n, tris = n + 3, tris + 1
          end
        end
      end
    end
  end
  local tw = C.FLORA_TRUNK_W * sc
  tris = tris + self:trunk(cx0, gy, cz0, tw, gy + hem + 0.12 * H, rot, art.bark)
  self.stats.conifers = self.stats.conifers + 1
  return { x = cx, z = cz, y0 = gy + hem, y1 = yA, r = R }, true, tris
end

-- ---------------------------------------------------------------------
-- "c88" conifers (tree round 11; w7/uv-analysis/ALIGNMENT_SPEC.md +
-- CHECK.md; USER: "the top of the tree isn't lined up with the texture")
-- ---------------------------------------------------------------------
-- The FRLG tree is THREE tiles tall: sprite rows 3-47 (45 visible rows);
-- its tip (rows 3-15) is in the tile above the 2x2 block. The crown takes
-- the sprite at ONE square scale: row 3 at the apex, row 48 on the ground,
-- every row sv = H / 45 tall; each of 6 faces shows one half of the sprite
-- from the centre line outward (c = texel columns along the face's chord,
-- constant width sh -- no fanning). Four tiers, their hems at the drawn
-- curves (straight cuts through texel corners, dark lips behind the V
-- flaps), the skirt on the silhouette with the trunk's arch:
--   A  the tip cone (rows 3-16) + its V flap down to row 21 (H1)
--   B  rows 16-29 with its V (H2), C rows 20-32, a dark band closing C|D
--   D  the skirt (rows 32-47): the silhouette and the trunk opening
-- Coordinates below: (c, Y); planes as corner radius rho(Y) in texel
-- columns; pieces from w7/uv-analysis/alignment/C88_pieces.lua (winding
-- as Ctx:lathe: left half signed area < 0, right half > 0).
local C88 = {
  planes = {
    A = { { 3, 0 }, { 16, 10 }, { 21, 13.1 } },
    B = { { 16, 10 }, { 29, 15.46 } },
    C = { { 20, 11.68 }, { 32, 14.464 }, { 35, 15.16 } },
    D = { { 32, 12 }, { 47, 12 } },   -- (spec 13; 12 keeps the teal edge column x3 / x28, rows 36-44, off the skirt)
  },
  left = {
    { "A", "tip", { { 0, 3 }, { 10, 16 }, { 0, 16 } }, { { 1, 3, 2 } } },
    { "A", "top", { { 10, 16 }, { 0, 21 }, { 0, 16 } }, { { 1, 3, 2 } } },
    { "B", "dark", { { 0, 16 }, { 10, 16 }, { 0, 21 } }, { { 1, 3, 2 } } },
    { "B", "top", { { 0, 21 }, { 10, 16 }, { 11.68, 20 }, { 0, 29 } }, { { 4, 2, 1 }, { 2, 4, 3 } } },
    { "C", "dark", { { 0, 20 }, { 11.68, 20 }, { 0, 29 } }, { { 1, 3, 2 } } },
    { "C", "top", { { 0, 29 }, { 11.68, 20 }, { 14.464, 32 }, { 0, 32 } }, { { 4, 2, 1 }, { 2, 4, 3 } } },
    { "D", "bot", { { 0, 32 }, { 12, 32 }, { 12, 43 }, { 4, 47 }, { 4, 39 }, { 0, 39 } },
      { { 6, 2, 1 }, { 2, 4, 3 }, { 2, 5, 4 }, { 2, 6, 5 } } },
  },
  right = {
    { "A", "tip", { { 0, 3 }, { 10, 16 }, { 0, 16 } }, { { 1, 2, 3 } } },
    { "A", "top", { { 10, 16 }, { 0, 21 }, { 0, 16 } }, { { 1, 2, 3 } } },
    { "B", "dark", { { 0, 16 }, { 10, 16 }, { 0, 21 } }, { { 1, 2, 3 } } },
    { "B", "top", { { 0, 21 }, { 10, 16 }, { 11.68, 20 }, { 0, 29 } }, { { 4, 1, 2 }, { 2, 3, 4 } } },
    { "C", "dark", { { 0, 20 }, { 11.68, 20 }, { 0, 29 } }, { { 1, 2, 3 } } },
    { "C", "top", { { 0, 29 }, { 11.68, 20 }, { 14.464, 32 }, { 0, 32 } }, { { 4, 1, 2 }, { 2, 3, 4 } } },
    { "D", "bot", { { 0, 32 }, { 12, 32 }, { 12, 43 }, { 4, 47 }, { 4, 39 }, { 0, 39 } },
      { { 6, 1, 2 }, { 2, 3, 4 }, { 2, 4, 5 }, { 2, 5, 6 } } },
  },
  -- C94u: the H3 U's bottom as a flap on plane C below the tile boundary
  uLeft = { "C", "bot", { { 0, 32 }, { 8, 32 }, { 0, 35 } }, { { 1, 3, 2 } } },
  uRight = { "C", "bot", { { 0, 32 }, { 8, 32 }, { 0, 35 } }, { { 1, 2, 3 } } },
  inner = { [1] = true, [2] = true, [4] = true, [6] = true },   -- I36: the sprite-UV pieces only
}
F.C88 = C88

-- the tile sources, in order of preference (ALIGNMENT_SPEC section 3)
local C88_TILES = {
  top = { { 30, 31 }, { 28, 29 } },
  bot = { { 36, 37 }, { 38, 39 }, { 20, 21 }, { 22, 23 } },
  tipUnder = { { 22, 23 } },
  tipOver = { { 14, 15 } },
}
-- validation texels (sprite X, Y, colour): a pair that fails is not the
-- tree (player_house owns mids 22-39 with other art)
local C88_VALID = {
  tip = { { 15, 3, 0x3a5a10 }, { 16, 3, 0x3a5a10 }, { 14, 4, 0x3a5a10 }, { 5, 13, 0x3a5a10 }, { 26, 13, 0x3a5a10 } },
  top = { { 15, 20, 0x3a9431 }, { 14, 20, 0x3a9431 }, { 2, 19, 0x3a5a10 }, { 29, 19, 0x3a5a10 },
    { 12, 26, 0x3a5a10 }, { 19, 26, 0x3a5a10 }, { 15, 28, 0x3a9431 } },
  bot = { { 15, 34, 0x3a5a10 }, { 16, 34, 0x3a5a10 }, { 13, 36, 0x3a5a10 }, { 12, 39, 0x423a31 },
    { 19, 39, 0x423a31 }, { 15, 41, 0x736363 } },
}
F.C88_VALID = C88_VALID

function Ctx:texelsLayer(mid, layer)
  if layer ~= "over" then return self:texels(mid) end
  local key = "over" .. mid
  local t = self.texCache[key]
  if t ~= nil then return t or nil end
  t = false
  local fn = self.atlas.texels
  if type(fn) == "function" then
    local ok, r = pcall(fn, mid, "over")
    if ok and type(r) == "table" and #r >= 256 then t = r end
  end
  self.texCache[key] = t
  return t or nil
end

-- the resolved sources: { top = {rL, rR}, bot = {rL, rR}, tip = {rL, rR} |
-- nil, tipLayer = "under" / "over", tipFallback = uv | nil, core }; nil
-- when the top or bottom tiles are not the tree
-- The bottom tile pair's baked ground shadow. The trunk's first row = the
-- first row (32-47) with a bark texel (green not above red) in columns
-- 8-23; the shadow colour = the commonest leaf colour of that row; the
-- shadow starts at the highest row above the trunk from which every row
-- down to the trunk is at least half that colour (pallet: rows 38-47 --
-- 38 is 16 of 30, 37 only 10 of 28). nil (no cut) outside rows 34-44.
function Ctx:c88Shadow(pr)
  local tl, tr = self:texels(pr[1]), self:texels(pr[2])
  if not (tl and tr) then return nil end
  local function px(x, y) local t = x < 16 and tl or tr; return t[(y - 32) * 16 + (x % 16) + 1] end
  local function bark(v)
    if not v or v < 0 or KEY[v] then return false end
    return floor(v / 256) % 256 <= floor(v / 65536)
  end
  local t0, t1
  for y = 32, 47 do
    for x = 8, 23 do
      if bark(px(x, y)) then t0 = t0 or y; t1 = y end
    end
  end
  if not t0 then return nil end
  local cnt, dark, dn = {}, nil, 0
  for x = 0, 31 do
    local v = px(x, t0)
    if v and v >= 0 and not KEY[v] and not bark(v) then
      cnt[v] = (cnt[v] or 0) + 1
      if cnt[v] > dn then dark, dn = v, cnt[v] end
    end
  end
  if not dark then return nil end
  local function frac(y)
    local n, d = 0, 0
    for x = 0, 31 do
      local v = px(x, y)
      if v and v >= 0 and not KEY[v] and not bark(v) then
        n = n + 1
        if v == dark then d = d + 1 end
      end
    end
    return n > 0 and d / n or 0
  end
  local ys = t0
  while ys - 1 >= 33 and frac(ys - 1) >= 0.5 do ys = ys - 1 end
  if ys < 34 or ys > 44 then return nil end
  return ys, { t0, t1 }
end

-- the skirt cut at the shadow row ys (plane D, rows 32..ys: no arch -- the
-- trunk stands free below), left / right as C88.left[7] / right[7]
local c88DCache = {}
local function c88D(ys, h)
  local key = ys * 2 + h
  local d = c88DCache[key]
  if d then return d end
  local verts = { { 0, 32 }, { 12, 32 }, { 12, ys }, { 0, ys } }
  if h == 0 then d = { "D", "bot", verts, { { 4, 2, 1 }, { 2, 4, 3 } } }
  else d = { "D", "bot", verts, { { 4, 1, 2 }, { 2, 3, 4 } } } end
  c88DCache[key] = d
  return d
end

function Ctx:c88Art()
  local a = self.artCache.c88
  if a ~= nil then return a or nil end
  a = false
  local function valid(pair, band, base, layer)
    local tl, tr = self:texelsLayer(pair[1], layer), self:texelsLayer(pair[2], layer)
    if not (tl and tr) then return false end
    for _, t in ipairs(C88_VALID[band]) do
      local x, y, col = t[1], t[2] - base, t[3]
      local tex = x < 16 and tl or tr
      if tex[y * 16 + (x % 16) + 1] ~= col then return false end
    end
    return true
  end
  local function pickPair(list, band, base)
    for _, pr in ipairs(list) do
      if self:hasMid(pr[1]) and self:hasMid(pr[2]) and valid(pr, band, base, "under") then return pr end
    end
    return nil
  end
  local conif = self:coniferArt()
  local top = pickPair(C88_TILES.top, "top", 16)
  local bot = pickPair(C88_TILES.bot, "bot", 32)
  if conif and top and bot then
    a = { top = { self.underRect(top[1]), self.underRect(top[2]) },
      bot = { self.underRect(bot[1]), self.underRect(bot[2]) }, core = conif.core, bark = conif.bark,
      mids = { top = top, bot = bot } }
    local C = self.C
    -- T1: the exact tip in the tile above, OVER layer (needs dispatch F13)
    local ov = self.atlas.overRect
    if C.FLORA_C88_TIP_OVER ~= 0 and self.over and type(ov) == "function" then
      local pr = C88_TILES.tipOver[1]
      if valid(pr, "tip", 0, "over") then
        local l, r = { ov(pr[1]) }, { ov(pr[2]) }
        if l[4] and r[4] then a.tip, a.tipLayer = { l, r }, "over" end
      end
    end
    -- T2: the under-layer tip the tileset also carries (22/23)
    if not a.tip then
      local pr = pickPair(C88_TILES.tipUnder, "tip", 0)
      if pr then a.tip, a.tipLayer = { self.underRect(pr[1]), self.underRect(pr[2]) }, "under"; a.mids.tip = pr end
    end
    -- T3: one light texel of the top tiles (their most common green >= 0xf0)
    if not a.tip then
      local tex = self:texels(top[1])
      local cnt, best, bn = {}, nil, 0
      for i = 1, 256 do
        local v = tex[i]
        if v and v >= 0 and floor(v / 256) % 256 >= 0xf0 and not KEY[v] then
          cnt[v] = (cnt[v] or 0) + 1
          if cnt[v] > bn then best, bn = i, cnt[v] end
        end
      end
      a.tipFallback = best and self:texelUv(top[1], best) or conif.core
      self.stats.tipFallback = true
    end
    -- the baked ground shadow (USER, round 11, image 22: "the darker part ...
    -- on the bottom is actually a prebaked shadow"): a.shadowRow = the first
    -- sprite row of the dark band under the lowest leaves, around the trunk
    a.shadowRow, a.trunkRows = self:c88Shadow(bot)
  end
  self.artCache.c88 = a
  return a or nil
end

local function c88Rho(pl, Y)
  local n = #pl
  local k = 1
  while k < n - 1 and Y > pl[k + 1][1] do k = k + 1 end
  local a, b = pl[k], pl[k + 1]
  local s = (b[2] - a[2]) / (b[1] - a[1])
  return a[2] + s * (Y - a[1]), s
end

-- one c88 crown: inner = the I36 pieces only (no lips, band, skirt, trunk)
-- The baked shadow as what it is: its own texels (bottom pair, rows ys-47)
-- on two flat keyed quads at the trunk's foot (the ground key drops the
-- grass texels around the oval), axis-aligned like the sprite (rows run
-- south), one column sh wide, one row FLORA_C88_DECAL_Z columns deep, the
-- trunk rows centred on the trunk. 4 triangles.
function Ctx:c88Decal(ca88, ys, gy, cx0, cz0, sh)
  local C, newV, list = self.C, self.newV, self.keyed
  local tr = ca88.trunkRows
  local zc = (tr and (tr[1] + tr[2] + 1) * 0.5) or 41.5
  local kz = C.FLORA_C88_DECAL_Z * sh
  local y = gy + C.FLORA_C88_DECAL_LIFT
  local z0, z1 = cz0 + (ys - zc) * kz, cz0 + (48 - zc) * kz
  local n = #list
  for h = 0, 1 do
    local r = ca88.bot[h + 1]
    local x0, x1 = cx0 + (h * 16 - 16) * sh, cx0 + h * 16 * sh
    local v0 = r[2] + (r[4] - r[2]) * (ys - 32) / 16
    local a = newV(x0, y, z0, r[1], v0, 0, 1, 0)
    local b = newV(x1, y, z0, r[3], v0, 0, 1, 0)
    local c = newV(x1, y, z1, r[3], r[4], 0, 1, 0)
    local d = newV(x0, y, z1, r[1], r[4], 0, 1, 0)
    list[n + 1], list[n + 2], list[n + 3] = a, b, c
    list[n + 4], list[n + 5], list[n + 6] = a, c, d
    n = n + 6
  end
  return 4
end

function Ctx:coniferC88(u, gy, cx, cz, cx0, cz0, sc, rot, H, R, ca88, inner, uFlap)
  local C = self.C
  local newV = self.newV
  local sv = H / 45
  local sh = R / 15.46
  if sh > sv then sh = sv end
  local yA = gy + H
  local capNy = C.FLORA_CROWN_NY
  local core = ca88.core
  local tris = 0
  local da = pi / 3
  local list = self.opaque
  -- the skirt ends above the baked shadow (FLORA_C88_SHADOW_CUT)
  local ys = C.FLORA_C88_SHADOW_CUT ~= 0 and ca88.shadowRow or nil
  local yBot = ys and (yA - (ys - 3) * sv) or (gy + C.FLORA_HEM * H)
  for i = 0, 5 do
    local h = i % 2
    local ce, ou = (h == 0) and i or (i + 1), (h == 0) and (i + 1) or i
    local dcx, dcz = cos(rot + ce * da), sin(rot + ce * da)
    local ex, ez = cos(rot + ou * da) - dcx, sin(rot + ou * da) - dcz
    local pieces = (h == 0) and C88.left or C88.right
    local amid = rot + (i + 0.5) * da
    local function emit(pc, pi_)
      if inner and not C88.inner[pi_] then return end
      local plane, uvk, verts, ts = pc[1], pc[2], pc[3], pc[4]
      local pl = C88.planes[plane]
      -- the piece's slope: its plane segment at the piece's mean row
      local my = 0
      for _, v in ipairs(verts) do my = my + v[2] end
      my = my / #verts
      local _, slope = c88Rho(pl, my)
      local L = sqrt(sv * sv + (slope * sh) * (slope * sh))
      local nr, ny = sv / L, slope * sh / L
      if ny > capNy then ny = capNy; nr = sqrt(1 - ny * ny) end
      local dark = uvk == "dark"
      local rect, band, tipOne
      if uvk == "tip" then
        band = 0
        if ca88.tip then rect = ca88.tip[h + 1] else tipOne = ca88.tipFallback end
      elseif uvk == "top" then band, rect = 1, ca88.top[h + 1]
      elseif uvk == "bot" then band, rect = 2, ca88.bot[h + 1] end
      local out = self.opaque
      if uvk == "tip" and ca88.tipLayer == "over" then out = self.over end
      local vs = {}
      for k, v in ipairs(verts) do
        local c, Y = v[1], v[2]
        local rho = c88Rho(pl, Y)
        local px = cx + dcx * rho * sh + ex * c * sh
        local pz = cz + dcz * rho * sh + ez * c * sh
        local py = yA - (Y - 3) * sv
        local am
        if c == 0 and Y == 3 then am = amid else am = math.atan2(pz - cz, px - cx) end
        local uu, vv
        if dark then uu, vv = core[1], core[2]
        elseif tipOne then uu, vv = tipOne[1], tipOne[2]
        else
          local xt = (h == 0) and (16 - c) or c
          local yt = Y - 16 * band
          uu = rect[1] + (rect[3] - rect[1]) * xt / 16
          vv = rect[2] + (rect[4] - rect[2]) * yt / 16
        end
        if dark then
          vs[k] = newV(px, py, pz, uu, vv, cos(am) * 0.4472136, -0.8944272, sin(am) * 0.4472136)
        else
          vs[k] = newV(px, py, pz, uu, vv, cos(am) * nr, ny, sin(am) * nr)
        end
      end
      local m = #out
      for _, t in ipairs(ts) do
        out[m + 1], out[m + 2], out[m + 3] = vs[t[1]], vs[t[2]], vs[t[3]]
        m = m + 3
        tris = tris + 1
      end
    end
    for pi_, pc in ipairs(pieces) do
      if pi_ == 7 and ys then pc = c88D(ys, h) end
      emit(pc, pi_)
    end
    if uFlap and not inner then emit((h == 0) and C88.uLeft or C88.uRight, 0) end
    -- the band closing C | D (a dark ring at row 32: C's rho outside, D's inside)
    if not inner then
      local yb = yA - 29 * sv
      local rOut, rIn = 14.464 * sh, 12 * sh
      local function B(k, rr)
        local a = rot + k * da
        return newV(cx + cos(a) * rr, yb, cz + sin(a) * rr, core[1], core[2],
          cos(a) * 0.4472136, -0.8944272, sin(a) * 0.4472136)
      end
      local in0, in1, out0, out1 = B(i, rIn), B(i + 1, rIn), B(i, rOut), B(i + 1, rOut)
      local m = #list
      list[m + 1], list[m + 2], list[m + 3] = in0, in1, out1
      list[m + 4], list[m + 5], list[m + 6] = in0, out1, out0
      tris = tris + 2
    end
  end
  local trunk = false
  if not inner and u.edge then
    -- (the stub on edge units only, as the lathe: the mesher counts trunks against edge units)
    local tw = max(C.FLORA_TRUNK_W * sc, C.FLORA_C88_TRUNK_TEXELS * sh)
    local tTop = gy + C.FLORA_HEM * H + 0.12 * H
    if ys then tTop = yBot + 2 * sv end            -- up into the crown: no gap under the cut skirt
    tris = tris + self:trunk(cx0, gy, cz0, tw, tTop, rot, ca88.bark)
    trunk = true
    if ys and C.FLORA_C88_SHADOW == "decal" then
      tris = tris + self:c88Decal(ca88, ys, gy, cx0, cz0, sh)
    end
  end
  self.stats.conifers = self.stats.conifers + 1
  return { x = cx, z = cz, y0 = yBot, y1 = yA, r = R }, trunk, tris
end

function Ctx:conifer(u, gy, cx, cz, cx0, cz0, sc, rot, art, far)
  local C = self.C
  local H, R = C.FLORA_CONIFER_H * sc, C.FLORA_CONIFER_R * sc
  local single = u.single == true
  if single then H, R = H * (0.5 + 0.5 * C.FLORA_SINGLE), R * C.FLORA_SINGLE end
  local hem = C.FLORA_HEM * H
  local crownH = H - hem
  -- crowns stay inside their own footprint (a tree next to a house never
  -- reaches over its roof)
  local half = math.min(u.w, u.h or u.w) * 0.5
  local lim = 0.98 * half - math.max(abs(cx - cx0), abs(cz - cz0))
  if R > lim then R = lim end
  self.stats.conifers = self.stats.conifers + 1
  if far then
    local tris = self:lathe(self.opaque, cx, cz, { { gy + hem, 0.9 * R } }, gy + H, 6, rot, {}, art.deep[1], { pointed = true })
    return { x = cx, z = cz, y0 = gy + hem, y1 = gy + H, r = R }, false, tris
  end
  if C.FLORA_CROWN == "c88" then
    local ca88 = self:c88Art()
    if ca88 then
      self.stats.conifers = self.stats.conifers - 1      -- (coniferC88 counts it)
      local innerU = not (u.edge or single)
      local H88 = H
      if single then
        -- square texels on a 1-cell footprint: the tree as tall as 45 of
        -- its (narrow) columns
        local sh1 = R / 15.46
        if 45 * sh1 < H88 then H88 = 45 * sh1 end
      end
      return self:coniferC88(u, gy, cx, cz, cx0, cz0, sc, rot, H88, R, ca88, innerU, C.FLORA_C88_U ~= 0)
    end
  end
  if u.edge and not single and C.FLORA_HEM_LOBE == "art2" then
    local sp = self:spriteHems(art)
    if sp then
      self.stats.conifers = self.stats.conifers - 1      -- (conifer2 counts it)
      if C.FLORA_ART2_UVTRUE ~= 0 then
        return self:conifer3(u, gy, cx, cz, cx0, cz0, sc, rot, art, sp, H, R, hem, crownH)
      end
      return self:conifer2(u, gy, cx, cz, cx0, cz0, sc, rot, art, sp, H, R, hem, crownH)
    end
  end
  local near = u.edge or single
  local prof = near and CONIFER_PROFILE or CONIFER_INNER
  local rings = {}
  for k, pr in ipairs(prof) do rings[k] = { gy + hem + pr[1] * crownH, pr[2] * R } end
  local core = { art.core }
  local bands, darkB
  bands = { art.low, core, art.deep, core }
  darkB = CONIFER_DARK
  local sides = (near and not single) and C.FLORA_CONIFER_SIDES or 5
  -- (tree round 7, USER: scalloped tier hems) lobes under the bottom
  -- tier's rim (edge units) and the middle tier's rim (every near / inner
  -- unit): FLORA_HEM_LOBE shape, FLORA_HEM_LOBE_D x the tree height deep
  local lobes = {}
  local shape = (u.edge and not single) and C.FLORA_HEM_LOBE or C.FLORA_HEM_LOBE_INNER
  local depth = C.FLORA_HEM_LOBE_D * H
  if shape == "v" or shape == "u" or shape == "w" then
    lobes[3] = { shape, depth }
    if u.edge and not single then lobes[1] = { shape, depth } end
  end
  -- (tree round 9) FLORA_HEM_LOBE = "art": no invented lobes -- the middle
  -- and top tiers end where their own art draws the hem outline, cut
  -- texel-stepped (Ctx:hemRuns), with a dark lip under each cut run
  local artHem, artApex
  if (u.edge and not single and C.FLORA_HEM_LOBE == "art") or (not (u.edge and not single) and C.FLORA_HEM_LOBE_INNER == "art") then
    lobes = {}
    local lip = C.FLORA_HEM_ART_LIP > 0 and { C.FLORA_HEM_ART_LIP, C.FLORA_HEM_ART_LIP * 0.5 } or nil
    artHem = { [3] = { lip = lip } }
    if (C.FLORA_HEM_ART_TOP or 0) ~= 0 then artApex = { lip = lip } end
    self.hemLipUv = art.core
  end
  local tris = self:lathe(self.opaque, cx, cz, rings, gy + H, sides, rot, bands, art.mid[1],
    { pointed = true, dark = darkB, lobes = lobes, artHem = artHem, artHemApex = artApex })
  local trunk = false
  if u.edge then
    -- a short dark stub under the crown, on the footprint centre: from eye
    -- height it hides behind the bottom tier beyond ~2 cells
    local tw = C.FLORA_TRUNK_W * (single and 0.6 or 1) * sc
    tris = tris + self:trunk(cx0, gy, cz0, tw, gy + hem + 0.12 * H, rot, art.bark)
    trunk = true
  end
  return { x = cx, z = cz, y0 = gy + hem, y1 = gy + H, r = R }, trunk, tris
end

-- Ellipsoid dome (broadleaf canopy): centre (cx, yc, cz), horizontal radius
-- a, vertical semi-axis b, rings at latitudes lats[1..n] (radians); band k
-- (rings k .. k+1) maps, on side i, the whole tile bandArt[k][i % 3 + 1]
-- (left / centre / right columns of the tree art in turn round the canopy,
-- the tile's top at the upper ring); the top closes with a fan in planar
-- x/z UVs of capUv. Smooth ellipsoid normals. Returns the triangle count.
function Ctx:dome(cx, yc, cz, a, b, sides, lats, bandArt, capUv, rot, list)
  local newV = self.newV
  list = list or self.opaque
  local ca, sa = {}, {}
  for i = 0, sides do
    local ang = rot + i / sides * 2 * pi
    ca[i], sa[i] = cos(ang), sin(ang)
  end
  local ia2, ib2 = 1 / (a * a), 1 / (b * b)
  local function ringPt(k, i)
    local cl, sl = cos(lats[k]), sin(lats[k])
    local px, py, pz = cx + a * cl * ca[i], yc + b * sl, cz + a * cl * sa[i]
    local gx, gy2, gz = (px - cx) * ia2, (py - yc) * ib2, (pz - cz) * ia2
    local l = sqrt(gx * gx + gy2 * gy2 + gz * gz)
    return px, py, pz, gx / l, gy2 / l, gz / l
  end
  local n, tris = #list, 0
  for k = 1, #lats - 1 do
    local art = bandArt[k]
    for i = 0, sides - 1 do
      local uv = art[i % #art + 1]
      local u0, v0, u1, v1 = uv[1], uv[2], uv[3], uv[4]
      local x1, y1, z1, n1x, n1y, n1z = ringPt(k, i)
      local x2, y2, z2, n2x, n2y, n2z = ringPt(k, i + 1)
      local x3, y3, z3, n3x, n3y, n3z = ringPt(k + 1, i + 1)
      local x4, y4, z4, n4x, n4y, n4z = ringPt(k + 1, i)
      -- seen from outside, side i + 1 is to the viewer's left (angles grow
      -- toward the viewer's left), so it takes the tile's left edge
      local A = newV(x1, y1, z1, u1, v1, n1x, n1y, n1z)
      local B = newV(x2, y2, z2, u0, v1, n2x, n2y, n2z)
      local Cc = newV(x3, y3, z3, u0, v0, n3x, n3y, n3z)
      local D = newV(x4, y4, z4, u1, v0, n4x, n4y, n4z)
      list[n + 1], list[n + 2], list[n + 3] = A, B, Cc
      list[n + 4], list[n + 5], list[n + 6] = A, Cc, D
      n, tris = n + 6, tris + 2
    end
  end
  -- top fan (planar UVs over the top ring's radius): a low dome's pole
  local K = #lats
  local rr = a * cos(lats[K])
  local pu, pv = (capUv[1] + capUv[3]) * 0.5, (capUv[2] + capUv[4]) * 0.5
  local ptop = newV(cx, yc + b, cz, pu, pv, 0, 1, 0)
  local cu0, cv0, cdu, cdv = capUv[1], capUv[2], capUv[3] - capUv[1], capUv[4] - capUv[2]
  for i = 0, sides - 1 do
    local x1, y1, z1, n1x, n1y, n1z = ringPt(K, i)
    local x2, y2, z2, n2x, n2y, n2z = ringPt(K, i + 1)
    local ua = cu0 + cdu * max(0, min(1, (x1 - cx) / (2 * rr) + 0.5))
    local va = cv0 + cdv * max(0, min(1, (z1 - cz) / (2 * rr) + 0.5))
    local ub = cu0 + cdu * max(0, min(1, (x2 - cx) / (2 * rr) + 0.5))
    local vb = cv0 + cdv * max(0, min(1, (z2 - cz) / (2 * rr) + 0.5))
    list[n + 1] = newV(x1, y1, z1, ua, va, n1x, n1y, n1z)
    list[n + 2] = newV(x2, y2, z2, ub, vb, n2x, n2y, n2z)
    list[n + 3] = ptop
    n, tris = n + 3, tris + 1
  end
  return tris
end

-- broadleaf (FOREST3): a round canopy -- an opaque dome (the tree's lower
-- row art on its lower band, the upper row art on its upper band, the upper
-- centre tile on top, each face one tile) -- with a ring of keyed clump
-- cards (the lower row's scalloped tiles) hanging from its widest line to
-- the hem, near the ground.
--   dome : centre 0.56 H, a = 0.94 R, b = 0.44 H, latitudes -8 / 28 / 62 deg
--   hem  : 6 cards, top (0.8 R, 0.5 H) -> hem (1.0 R, HEM + 0.02)
function Ctx:broadleaf(u, gy, cx, cz, cx0, cz0, sc, rot, art, far)
  local C = self.C
  local keyed = self.keyed
  local H, R = C.FLORA_BROAD_H * sc, C.FLORA_BROAD_R * sc
  if u.single then H, R = H * 0.7, R * 0.6 end
  local hem = (C.FLORA_HEM + 0.02) * H
  local tris = 0
  local RAD = pi / 180
  self.stats.broadleaf = self.stats.broadleaf + 1
  if far then
    tris = tris + self:dome(cx, gy + 0.56 * H, cz, 0.94 * R, 0.44 * H, 6, { -20 * RAD, 45 * RAD },
      { art.upper }, art.cap, rot)
    return { x = cx, z = cz, y0 = gy + 0.3 * H, y1 = gy + H, r = R }, false, tris
  end
  tris = tris + self:dome(cx, gy + 0.56 * H, cz, 0.94 * R, 0.44 * H, 6, { -8 * RAD, 28 * RAD, 62 * RAD },
    { art.lower, art.upper }, art.cap, rot)
  -- (round 4: the scalloped hem ring only where it can be seen -- edge
  -- units; an inner unit's dome stays at the r11 inner cost, 30 <= 32)
  if u.edge then
    tris = tris + self:tier(keyed, cx, gy, cz, 6, rot + pi / 6, 0.8 * R, 0.5 * H, R, hem, art.hem, "pent", 0.85)
  end
  local trunk = false
  if u.edge then
    tris = tris + self:trunk(cx0, gy, cz0, C.FLORA_TRUNK_W * 1.3 * sc, gy + hem + 0.2 * H, rot, art.bark)
    trunk = true
  end
  return { x = cx, z = cz, y0 = gy + hem, y1 = gy + H, r = R }, trunk, tris
end

-- ---------------------------------------------------------------------
-- understory (the mesher keeps its corner logic; these are its numbers)
-- ---------------------------------------------------------------------
function Ctx:underInset(c)
  local C = self.C
  if not c.unit then return C.FLORA_UNDER_INSET_BLOB end
  return (c.unit.w >= 2) and C.FLORA_UNDER_INSET or C.FLORA_UNDER_INSET_1
end

function Ctx:underHeight(c)
  local C = self.C
  if c.unit and c.unit.forest3 then return C.FLORA_UNDER_H_BROAD end
  return C.FLORA_UNDER_H
end

-- one texel of the darkest leaf colour (flat shade, never a textured wall)
function Ctx:underUv(broad)
  if broad then
    local a = self:broadArt()
    if a then return a.core end
  end
  local a = self:coniferArt()
  return a and a.core or nil
end
Ctx.UNDER_NORMAL = { 0, -1, 0 }

-- ---------------------------------------------------------------------
-- tall grass
-- ---------------------------------------------------------------------
-- Grass round 5 (coordinator: "at eye level still reads as hedge slabs:
-- big flat panels with straight vertical edges and pale mint faces ...
-- MORE, SMALLER plants ... the top edge jagged blades ... bias toward the
-- art's darker greens"). Why panels looked mint: the plant is 184 of the
-- tile's 256 texels and 62 of those (34 %) are the ground key colours --
-- every leaf fill (0xa5e6c5 x18, 0x73cea5 x19, 0x42b58c x25) -- and a
-- convex-hull card also takes in background. So no keyed card can show
-- the blades (the fills would cut away: the old "shell"), and an opaque
-- card shows every fill at full size. Instead each blade is ONE opaque
-- triangle whose UVs are a triangle of the art that runs from a leaf tip
-- down to the dark stem rows: no background texel, 52-86 % dark greens
-- (0x3a9431 / 0x3a5a10 / 0x19a56b), the pale fills only as a few texels
-- (GRASS_BLADES; w7/art/blade_picks.png). The triangle's own edges are the
-- blade silhouette, so a tuft's top is two points, never a flat edge.
-- Texel coordinates (x right, y down, 0..16) of the tall-grass tile:
-- apex (the leaf tip), base left, base right. (Measured on the general
-- tileset's tile 13 with w7 scratch blades.py: background 0-5 %, dark greens
-- 52-86 %, the pale 0xa5e6c5 <= 5 %.)
local GRASS_BLADES = {
  { { 8, 0 }, { 5, 15 }, { 11, 15 } },        -- the centre blade over the stem
  { { 8, 0.5 }, { 4, 16 }, { 12, 16 } },
  { { 8, 5 }, { 4, 16 }, { 12, 16 } },        -- the stem (darkest)
  { { 1.5, 3 }, { 4, 15 }, { 10, 15 } },      -- the upper-left leaf
  { { 14.5, 3 }, { 6, 15 }, { 12, 15 } },     -- the upper-right leaf
  { { 0.5, 7.5 }, { 5, 16 }, { 11, 16 } },    -- the middle-left leaf
  { { 15.5, 7.5 }, { 5, 16 }, { 11, 16 } },   -- the middle-right leaf
  { { 14, 3 }, { 5, 13 }, { 10, 13 } },
}
F.GRASS_BLADES = GRASS_BLADES
-- Five clumps a cell: { x, z, height } (height: FLORA_GRASS_H_<name>): a
-- ring of four round the centre and one on it. A wild Pokemon stands on
-- the centre, so from any side two ring clumps stand in front of it, one
-- each side of its middle: they set how much of it hides. The ring turns
-- by a hashed angle per cell and mirrors x (no repeating rosette in the
-- 3/4 view).
local GRASS_TUFTS = {
  { 0.25, 0.26, "TALL" }, { 0.75, 0.27, "RING" }, { 0.5, 0.5, "MID" }, { 0.26, 0.75, "RING" }, { 0.74, 0.74, "LOW" },
}
F.GRASS_TUFTS = GRASS_TUFTS
-- The "grid" style (FLORA_GRASS_STYLE = "grid"; the alternative to the
-- default "blades"): the same blade clumps in ONE fixed pattern per cell,
-- no turn, no mirror, no hashed yaw -- a tidy grid of fan plants like the
-- reference's rows at 3/4. { x, z, yaw (deg, 0 = the clump runs east-west;
-- +-55 = the arms, scaled to FLORA_GRASS_GRID_ARM), width x
-- FLORA_GRASS_BLADE_W, height FLORA_GRASS_H_<name>, tip shift (x width,
-- along the clump), blade 1, blade 2 (GRASS_BLADES indices) }:
--   1  the fan's face: wide, east-west, just south of the centre (in front
--      of a wild Pokemon from the south)
--   2  the north spine: north-south, a little east of the centre line
--   3, 4  the fan's arms, turned +- ARM degrees, tips leaning outward (in
--      front of the Pokemon from the west / east)
--   5  the south spine: north-south, a little west of it
-- The spines carry the w1 knee-height rays at z 0.2 / 0.8, the arms z 0.5.
local GRASS_GRID = {
  { 0.5, 0.67, 0, 1.15, "GRID_C", 0, 1, 2 },
  { 0.56, 0.26, 90, 1.0, "GRID_SPINE", 0, 3, 8 },
  { 0.25, 0.54, 55, 1.0, "GRID_ARM", -0.12, 4, 6 },
  { 0.75, 0.54, -55, 1.0, "GRID_ARM", 0.12, 5, 7 },
  { 0.44, 0.84, 90, 0.9, "GRID_SPINE", 0, 3, 8 },
}
F.GRASS_GRID = GRASS_GRID
-- the shading direction: horizontal part turned from the sun (NW, 42 deg)
-- and from the fill (from the south), so a blade gets ambient only (~0.58
-- where the round-4 south faces got ~0.74), +- FLORA_GRASS_SHADE_VAR
local GRASS_DARK_YAW = math.atan2(-0.44, 0.9)

-- a tall-grass cell (x, y) at ground gy; uv = the cell's under rect; mid
-- (optional, dispatch F11) is not needed any more: the blades sample the
-- cell's own tile through GRASS_BLADES.
-- Each tuft is a CLUMP of two blades side by side: full-width bases, the
-- tips over its left and right thirds (FLORA_GRASS_TIP), one tip lower --
-- an "M": solid low down, two points and a notch on top. The two blades
-- are turned +- 10 degrees about the clump's axis (never coplanar). Ring
-- clumps stand tangent to the ring (+- 15 degrees), so from any side two
-- of them face the viewer at >= 0.7 of their width; the centre clump's
-- yaw is hashed. Width FLORA_GRASS_BLADE_W +- 0.04, drawn either way round,
-- each blade's UVs a hashed GRASS_BLADES triangle. 5 clumps x 2 = 10
-- triangles a cell (+ the mesher's 2-triangle base); border rings: the
-- first and third clumps (4).
function Ctx:grass(x, y, gy, uv, mid)
  local _ = mid
  local C = self.C
  local list, newV = self.opaque, self.newV
  local rad = pi / 180
  local up = C.FLORA_GRASS_UP
  local nl = sqrt(1 + up * up)
  local flip = hash01(x, y, 29) < 0.5
  local du, dv = (uv[3] - uv[1]) / 16, (uv[4] - uv[2]) / 16
  local tip = C.FLORA_GRASS_TIP
  local ra = (hash01(x, y, 30) - 0.5) * 2 * C.FLORA_GRASS_RING_TURN * rad
  local ringC, ringS = cos(ra), sin(ra)
  local tris, n = 0, #list
  local last = self.isBorder and 3 or #GRASS_TUFTS
  local step = self.isBorder and 2 or 1
  if C.FLORA_GRASS_STYLE == "grid" then
    for t = 1, last, step do
      local gd = GRASS_GRID[t]
      local salt = 100 + 16 * t
      local cxp, czp = x + gd[1], y + gd[2]
      local h = C["FLORA_GRASS_H_" .. gd[5]] + (hash01(x, y, salt + 2) - 0.5) * 2 * C.FLORA_GRASS_H_VAR
      if h > C.GRASS_CARD_H_MAX then h = C.GRASS_CARD_H_MAX end
      local sy = GRASS_DARK_YAW + (hash01(x, y, salt + 3) - 0.5) * 2 * C.FLORA_GRASS_SHADE_VAR * rad
      local nx, ny, nz = cos(sy) / nl, up / nl, sin(sy) / nl
      local yaw = gd[3] * rad
      if gd[3] ~= 0 and gd[3] ~= 90 then yaw = gd[3] / 55 * C.FLORA_GRASS_GRID_ARM * rad end
      local w = C.FLORA_GRASS_BLADE_W * gd[4]
      local hw = w * 0.5
      for b = 1, 2 do
        local by = yaw + (b == 1 and -10 or 10) * rad
        local sx, sz = cos(by), sin(by)
        local lean = ((b == 1 and -tip or tip) + gd[6]) * w
        local hb = b == 2 and h * 0.86 or h
        local bl = GRASS_BLADES[gd[6 + b]]
        local A = newV(cxp + sx * lean, gy + hb, czp + sz * lean,
          uv[1] + du * bl[1][1], uv[2] + dv * bl[1][2], nx, ny, nz)
        local L = newV(cxp - sx * hw, gy, czp - sz * hw, uv[1] + du * bl[2][1], uv[2] + dv * bl[2][2], nx, ny, nz)
        local R = newV(cxp + sx * hw, gy, czp + sz * hw, uv[1] + du * bl[3][1], uv[2] + dv * bl[3][2], nx, ny, nz)
        list[n + 1], list[n + 2], list[n + 3] = L, R, A
        n, tris = n + 3, tris + 1
      end
    end
    last = 0 -- (the blades loop below then does nothing)
  end
  for t = 1, last, step do
    local tf = GRASS_TUFTS[t]
    local salt = 100 + 16 * t
    -- the ring turned by a hashed angle per cell (no repeating rosette)
    local tx0, tz0 = (flip and (1 - tf[1]) or tf[1]) - 0.5, tf[2] - 0.5
    local tx = 0.5 + tx0 * ringC - tz0 * ringS
    local tz = 0.5 + tx0 * ringS + tz0 * ringC
    local cxp = x + tx + (hash01(x, y, salt) - 0.5) * 0.06
    local czp = y + tz + (hash01(x, y, salt + 1) - 0.5) * 0.04
    local h = C["FLORA_GRASS_H_" .. tf[3]] + (hash01(x, y, salt + 2) - 0.5) * 2 * C.FLORA_GRASS_H_VAR
    if h > C.GRASS_CARD_H_MAX then h = C.GRASS_CARD_H_MAX end
    local sy = GRASS_DARK_YAW + (hash01(x, y, salt + 3) - 0.5) * 2 * C.FLORA_GRASS_SHADE_VAR * rad
    local nx, ny, nz = cos(sy) / nl, up / nl, sin(sy) / nl
    local yaw
    local rx, rz = tx - 0.5, tz - 0.5
    if rx * rx + rz * rz > 0.01 then
      yaw = math.atan2(rx, -rz) + (hash01(x, y, salt + 4) - 0.5) * 2 * C.FLORA_GRASS_YAW_VAR * rad   -- tangent to the ring
    else
      yaw = hash01(x, y, salt + 4) * pi
    end
    local w = C.FLORA_GRASS_BLADE_W + (hash01(x, y, salt + 5) - 0.5) * 0.08
    local hw = w * 0.5
    local low = hash01(x, y, salt + 6) < 0.5 and 1 or 2   -- which tip is the lower one
    for b = 1, 2 do
      local by = yaw + (b == 1 and -10 or 10) * rad
      local sx, sz = cos(by), sin(by)
      local lean = (b == 1 and -tip or tip) * w
      local hb = b == low and h * (0.78 + 0.14 * hash01(x, y, salt + 7 + b)) or h
      local bl = GRASS_BLADES[floor(hash01(x, y, salt + 9 + b) * #GRASS_BLADES) + 1]
      local mir = hash01(x, y, salt + 11 + b) < 0.5
      local l, r = bl[2], bl[3]
      if mir then l, r = r, l end
      local A = newV(cxp + sx * lean, gy + hb, czp + sz * lean,
        uv[1] + du * bl[1][1], uv[2] + dv * bl[1][2], nx, ny, nz)
      local L = newV(cxp - sx * hw, gy, czp - sz * hw, uv[1] + du * l[1], uv[2] + dv * l[2], nx, ny, nz)
      local R = newV(cxp + sx * hw, gy, czp + sz * hw, uv[1] + du * r[1], uv[2] + dv * r[2], nx, ny, nz)
      list[n + 1], list[n + 2], list[n + 3] = L, R, A
      n, tris = n + 3, tris + 1
    end
  end
  self.stats.grassCells = self.stats.grassCells + 1
  self.stats.grassTris = self.stats.grassTris + tris
  return true, tris
end

-- ---------------------------------------------------------------------
-- flowers
-- ---------------------------------------------------------------------
-- (coordinator: "flowers read as thin red scribbles [at 3/4] ... the art's
-- own flower heads and leaves as upright clumps ... read clearly from above
-- AND from the side; keep it cheap")
-- Two KEYED cards of the whole flower tile (its ground keys away; blooms
-- and leaves stay), cropped to the columns / rows holding the plant's own
-- texels (cropBox): one east-west leaning back FLOWER_LEAN (seen from the south and from above), one
-- north-south leaning west FLOWER_LEAN (seen from the east / west and from
-- above). 4 triangles.
function Ctx:flower(x, y, gy, uv, mid)
  local C = self.C
  local list, newV = self.keyed, self.newV
  local x0, y0, x1, y1 = cropBox(mid and self:texels(mid), 0, 0, 16, 16, 1)
  local u0, v0, u1, v1 = texRect(uv, x0, y0, x1, y1)
  local n = #list
  local wt = C.FLOWER_CARD_W * (x1 - x0) / 16
  local lt = C.FLOWER_CARD_H * (y1 - y0) / 16
  for k = 0, 1 do
    local lean = C.FLOWER_LEAN + (hash01(x, y, 95 + k) - 0.5) * 0.2
    local cl, sl = cos(lean), sin(lean)
    -- side axis and lean direction: k = 0 east-west, top north; k = 1
    -- north-south, top west
    local sx, sz, dx, dz = 1, 0, 0, -1
    if k == 1 then sx, sz, dx, dz = 0, 1, -1, 0 end
    local px = x + 0.5 + (hash01(x, y, 97 + k) - 0.5) * 0.1 - dx * lt * sl * 0.5
    local pz = y + 0.5 + (hash01(x, y, 99 + k) - 0.5) * 0.1 - dz * lt * sl * 0.5
    local hx, hz = sx * wt * 0.5, sz * wt * 0.5
    local ox, oy, oz = dx * lt * sl, lt * cl, dz * lt * sl
    -- normal: the card's face (up and away from the lean), bent up
    local nx, ny, nz = -dx * cl, sl + 0.3, -dz * cl
    local nl = sqrt(nx * nx + ny * ny + nz * nz)
    nx, ny, nz = nx / nl, ny / nl, nz / nl
    local a0, a1 = u0, u1
    if hash01(x, y, 90 + k) < 0.5 then a0, a1 = u1, u0 end
    local p1 = newV(px - hx, gy, pz - hz, a0, v1, nx, ny, nz)
    local p2 = newV(px + hx, gy, pz + hz, a1, v1, nx, ny, nz)
    local p3 = newV(px + hx + ox, gy + oy, pz + hz + oz, a1, v0, nx, ny, nz)
    local p4 = newV(px - hx + ox, gy + oy, pz - hz + oz, a0, v0, nx, ny, nz)
    list[n + 1], list[n + 2], list[n + 3] = p1, p2, p3
    list[n + 4], list[n + 5], list[n + 6] = p1, p3, p4
    n = n + 6
  end
  self.stats.flowerCells = self.stats.flowerCells + 1
  return true, 4
end

return F
