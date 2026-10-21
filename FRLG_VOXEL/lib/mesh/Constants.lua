-- FRLG_VOXEL: tunable numeric constants for FrlgMesher.lua. Every value
-- here is PROPOSED (a visual choice), not derived from ROM data -- unlike
-- lib/mesh/MB.lua, which holds verified engine/pret constants. Tune these
-- without touching mesher logic. Plain data table: no logic, no requires.
-- FrlgMesher.lua carries a fallback copy (DEFAULT_CONST); keep them in sync.
--
-- r7m (visual review REVIEW_VISUAL.md M1-M14): elevation is a tag, not a
-- height (M1); facade rows by art (M5); ledge curbs (M6); sealed eaves
-- (M7); keyed grass/fence/sign cards (M3/M9/M10); one tree per FRLG 2x2
-- tree with a leaf swatch (M4/M11); planar roof tiling (M12).
-- History: w1/REPORT.md (Rev 1-5), W3 hand-back (roof layering).

return {
  -- World units: 1 map cell = 1.0 unit on X/Z (interface contract).
  ELEV_UNIT = 0.25,        -- world units per pret elevation step. r7m M1:
                           -- only walkable cells with elevation 1..14 are
                           -- height sources; 0/15 cells take the height of
                           -- the nearest source (FrlgMesher pass 1b).
  WATER_DEPTH = 0.15,      -- water surface below the lowest bank (M1).
  SHALLOW_WATER_DEPTH = 0.06,
  WATER_BANK_V0 = 0.8,     -- bank skirt samples the bottom 20% of the tile.

  -- Building detector (unchanged since Rev 2): real buildings measured
  -- 0.70-1.00 distinct-mids-per-cell, tree/border rings 0.03-0.17.
  BUILDING_MIN_AREA = 6,
  BUILDING_MIN_DIM = 2,
  BUILDING_DIVERSITY_MIN = 0.5,

  -- Walls. r7m M5: a footprint row is ROOF when every interior building
  -- cell has over art with mean over coverage >= FACADE_ROOF_COVERAGE;
  -- otherwise FACADE (door/sign rows are always facade). Facade rows are
  -- counted from the front, up to MAX_WALL_ROWS; each is WALL_ROW_UNIT tall.
  WALL_ROW_UNIT = 1.0,
  MAX_WALL_ROWS = 2,
  WALL_HEIGHT_MIN = 1.25,
  WALL_HEIGHT_MAX = 2.0,
  FACADE_ROOF_COVERAGE = 0.9,
  FACADE_OVER_LIFT = 0.004, -- M14: facade over art this far in front of its base
  DOOR_INSET = 0.12,        -- M5: door art recessed this far into the footprint

  -- Roofs.
  EAVE_OVERHANG = 0.2,
  ROOF_PITCH = 0.23,        -- ridge rise = clamp(min(footprint ext) * PITCH,
  ROOF_RISE_MIN = 0.9,      --   ROOF_RISE_MIN, ROOF_RISE_MAX).
  ROOF_RISE_MAX = 1.2,
  ROOF_SOLID_MIN = 0.99,    -- over tile counts as solid (W3)
  ROOF_OVER_LIFT = 0.02,    -- composite roof: over layer above its base (W3)
  ROOF_COURSE_LEN = 1.3,    -- M12: one roof tile per ~1.3 units up the slope
                            -- (tiles are ~1 unit along the ridge; 2 courses
                            -- per house slope keeps a hip roof <= ~80 tris)
  ROOF_OVERHANG_PUSH = 0.6, -- M13: north eave reach when the roof art's top
                            -- row lies on the walkable row behind the house
  FASCIA_H = 0.12,          -- M7: dark board under every eave edge
  FLAT_ROOF_ASPECT_MIN = 1.35, -- r11 (review M13): aspect counts the overhang row (5x3+1 house: hip; 7x4+1 lab: flat)
  FLAT_ROOF_PARAPET = 0.25, -- M5: was 0.15

  -- M2 forest base: an opaque skirt inside every forest edge.
  FOREST_BASE_H = 1.35,
  FOREST_BASE_INSET = 0.25,
  FOREST_BASE_V0 = 0.55,

  -- M11 trees: one tree per FRLG 2x2 tree unit (MB.TREE_* pairing).
  TREE_UNIT_R = 1.02,       -- base radius: crown 2.0-2.1 wide
  TREE_UNIT_TOP = 2.55,     -- crown top above ground
  TREE_SIDES = 10,          -- r8 open-edge units (r9: unused, domes are 8 / 6 sided)
  TREE_SIDES_DENSE = 8,     -- r8 dense units (r9: unused)
  TREE_JITTER = 0.1,        -- hashed centre offset
  TREE_SCALE_JITTER = 0.08, -- hashed scale +-
  TREE_WOBBLE = 0.07,       -- hashed per-column rim wobble
  TREE_TRUNK_W = 0.15,      -- half width (0.3 wide)
  TREE_SINGLE_SCALE = 0.55, -- cells without a unit partner
  -- r9 Part B (first-person trees): round lobed crowns; an EDGE unit (any
  -- side facing in-grid non-tree cells) gets a low dome, 2-3 lobes and a
  -- trunk pushed TREE_TRUNK_SHIFT toward its open sides; the understory
  -- closure (dark leaves) stands FOREST_UNDER_INSET inside the edge,
  -- behind that trunk and under the crown, FOREST_UNDER_H tall.
  TREE_TRUNK_SHIFT = 0.4,   -- 2x2 units (singles: half)
  FOREST_UNDER_INSET = 0.85, -- 2x2 units (singles: FOREST_UNDER_INSET_1)
  FOREST_UNDER_INSET_1 = 0.85, -- r11 (review M3): deeper and lower, dark leaf, lit
  FOREST_UNDER_H = 0.6,     -- 2x2 units (singles: FOREST_UNDER_H_1): under the crown underside
  FOREST_UNDER_H_1 = 0.6,
  FOREST_UNDER_INSET_BLOB = 0.85, -- blob trees (per-cell domes)
  FOREST_UNDER_H_BLOB = 0.6,
  -- r10: 3-wide forest-tileset trees (MB.FOREST3_PAIRS, Viridian Forest):
  -- crown radius / top, understory height, trunk half width
  FOREST3_R = 1.45,
  FOREST3_TOP = 2.9,
  FOREST3_UNDER_H = 0.9,
  FOREST3_TRUNK_W = 0.18,
  -- r11 blocks (building complexes the building rule rejects, extruded
  -- per column): minimum cells, wall rows cap, facade share of a run
  BLOCK_MIN_CELLS = 6,
  BLOCK_MAX_ROWS = 5,
  BLOCK_FACADE_FRAC = 0.5,
  BLOCK_DIVERSITY_MIN = 0.2, -- distinct mids / cells: forests and rock fields are 0.01-0.09
  BLOCK_MAX_DEPTH = 16,      -- rows: Silph Co is 15, Safari / Mt Ember masses 36-54
  CLIFF_REJOIN = true,       -- r11: doorless non-cliff solids rejoin the cliffs they touch (rock mounds)
  BUILDING_FILL_MIN = 0.7,   -- r11: a building filling less of its bbox goes to blocks when it has a block part
  -- r11 (review M2): outdoor rock terrain (pass 3r): a lone rock, a 1-wide
  -- cliff run, and a rock mass stepped from its edge inward
  ROCK_LUMP_H = 0.7,
  ROCK_BEVEL = 1.0,          -- r12 (v18): rock rounds down to a lower neighbour over this far
  ROCK_BEVEL_K = 1.0,        -- (at most this x the drop)
  ROCK_CUTS = { 0.15, 0.4, 0.7, 1.0 }, -- heightfield cuts, as fractions of the bevel (snapped to 1 / ROCK_LATTICE)
  BOULDER_SEGS = 8,          -- r12: a lone boulder's lathe: segments around
  BIN_SEGS = 12,             -- r12: an interior round bin's cylinder: segments around
  POOL_DEPTH = 0.5,          -- r12: an interior's water sits this far below its deck (a recessed pool)
  PLANK_T = 0.1,             -- ... a plank walkway over it is a board this thick
  STILT_W = 0.08,            -- ... on stilts this wide
  STILT_INSET = 0.2,         -- ... this far in from its water-side edges
  GATE_BAR_H0 = 0.45,        -- r12: a gate's lowest glowing bar stands this high
  GATE_BAR_STEP = 0.45,      -- ... the next ones this much higher each
  GATE_BAR_T = 0.1,          -- ... this deep
  PILLAR_ROW_H = 0.55,       -- r12: an interior pillar is this tall per art row (capital included; <= INDOOR_WALL_H)
  PILLAR_INSET = 0.12,       -- ... and this far in from its cell's edges
  SIDE_TRIM_H = 0.125,       -- r12: a building's plain side / back walls: the base trim's height
  PILASTER_D = 0.1,          -- r12: a wall face's pilasters (edge post columns in its art) stand this far proud
  BOULDER_R_MAX = 0.48,      -- ... and its widest ring's radius (cells)
  ROCK_LATTICE = 4,          -- (budget: a run shares at most 3 interior cuts per axis; smooth normals round it)
  ROCK_KERB_H = 0.35,
  ROCK_H0 = 1.0,
  ROCK_STEP = 0.5,
  ROCK_MAX_H = 1.5,
  BLOCK_SMALL_H = 0.7,       -- r11 (review M11): a doorless block <= 2 columns wide (stall crates, pots)
  BLOCK_TOP_BIAS = 0.012,    -- r11 (review R3): block tops off the building eave / roof planes
  SIDE_GROUND_MAX = 0.12,    -- r11 (review M6): side / back wall art: at most 12% of its texels in the
                             -- ground palette round the building (edge-column corner tiles never)
  STATUE_INSET = 0.1,        -- r11 (review M8): a statue / bollard box is inset this far
  CONIFER_R = 0.85,          -- r11 (review M16): general-tileset tree units are tiered cones,
  CONIFER_TOP = 1.1,         -- narrower and taller than the broadleaf dome
  VENT_W = 0.45,             -- r11 (review M13): a roof vent / chimney box on a flat roof
  VENT_H = 0.3,
  GABLE_PITCH = 36,          -- r11 (USER REPORT, roofs): gable roofs where the art shows a side profile,
  GABLE_RISE_MIN = 0.5,      -- pitch in degrees, ridge rise clamped
  GABLE_RISE_MAX = 1.5,
  CHIMNEY_H = 0.85,          -- a flat roof's chimney / vent group (Oak's lab) is a box this tall
  CHAMFER_MIN = 0.2,         -- (USER REPORT 2) PC / Mart front corners: 45-degree facets as wide as the
  CHAMFER_MAX = 0.5,         -- roof art's side strips, clamped
  BULLNOSE_R = 0.35,         -- their roof (ref 07): a flat top with a rounded edge of this radius,
  BULLNOSE_LIP = 0.1,        -- a lip this deep under it,
  BULLNOSE_SEGS = 3,         -- segments on the quarter round
  BULLNOSE_CORNER_SEGS = 3,  -- and round each plan corner
  BULLNOSE_TOUCH_INSET = 0.03, -- inside a wall shared with another building
  GABLE_RISE_WALL = 0.5,     -- a gable rises at most this x the wall height (v16: low roof, the wall shows)
  MAX_WALL_ROWS_TALL = 5,    -- r11 (refs 07 / 12): a tall city building's facade rows (flat roof)
  TALL_ROW_MATCH = 0.8,      -- a row joins the facade with this share of the front rows' colours
  HIP_END_MIN = 0.35,        -- r11 (refs 14, v15-v17): a hip's sloped end reaches at least this far in
  CHIMNEY_D_MAX = 0.9,       -- a pitched roof's chimney box: at most this deep,
  CHIMNEY_ABOVE = 0.6,      -- standing this far over the highest roof point under it
  EMBLEM_D = 0.12,           -- the emblem box above the door stands this far proud of the eave
  EMBLEM_RISE = 0.15,        -- and rises this far over the wall top (refs 05 / 06, v15)
  WATER_ROCK_H = 0.5,        -- r11 (review M10): a blocked water cell is a rock this far above the water
  WATER_ROCK_INSET = 0.3,    -- (the lump's open sides; the water round the rock stays water)
  FENCE_POST_BOX = 0.25,     -- r11 (review M9): fence posts are boxes this thick with a cap
  FOUNTAIN_MAX_CELLS = 12,   -- r11 (review M11): a small doorless solid of mostly water art
  FOUNTAIN_WATER_MIN = 0.4,  -- (mean atlas.waterFrac) is a fountain: rim, water, spray cards
  FOUNTAIN_RIM_H = 0.35,
  FOUNTAIN_SPRAY_H = 0.9,
  POST_H = 0.55,             -- r11 (USER REPORT): a log stump / bollard / post in the fence art is a
  POST_SIDES = 10,           -- r12 (v15): log posts are round cylinders with this many sides
  POST_R_MIN = 0.175,        -- hexagonal post this tall, 0.35..0.45 wide
  POST_R_MAX = 0.225,
  POST_W_MAX = 6,            -- (USER REPORT, side walls) a facade corner post at most 6 texels wide
  FLOWER_H_MIN = 0.28,       -- r11 (USER REPORT): flower cards, the tile's top FLOWER_V1,
  FLOWER_H_MAX = 0.34,       -- width : height about the art's 16 : 12
  FLOWER_V1 = 0.75,
  FLOWER_W_MIN = 0.40,
  FLOWER_W_MAX = 0.46,
  -- Non-tree solid blobs (rocks, cliffs, bushes) keep a small per-cell
  -- crown (legacy shape, review "not planned": terraced rock).
  BLOB_SIDES = 6,
  BLOB_R = 0.7, BLOB_TOP = 2.0,
  BUSH_R = 0.45, BUSH_TOP = 0.95, -- isolated blob cell (no blob neighbour)

  -- M3 tall grass: 2 crossed keyed cards per cell, hashed layout.
  -- r11 (USER REPORT 13: grass "only rendering a shell"): a dense knee-high
  -- patch -- GRASS_CARDS blade cards (GRASS_CARDS_FAR on border rings) in a
  -- hashed star over a raised dark base; cards reach GRASS_SPILL into
  -- the neighbours
  GRASS_CARD_W_MIN = 0.75, GRASS_CARD_W_MAX = 0.95,
  GRASS_CARD_H_MIN = 0.45, GRASS_CARD_H_MAX = 0.6,
  GRASS_CARDS = 5, GRASS_CARDS_FAR = 2, GRASS_SPILL = 0.12, GRASS_BASE_LIFT = 0.03,
  GRASS_OFFSET = 0.15,
  GRASS_YAW_JITTER = 20,    -- degrees around the two diagonals
  GRASS_V1 = 0.6,           -- cards sample the top 60% of the grass tile

  -- M6 ledges: a curb on the exit edge.
  -- r12 (census): each ledge's lip / round come from its art (grid.censusOf);
  -- LEDGE_LIP / LEDGE_ROUND are the standard FRLG ledge's values (cap 8, face 8)
  LEDGE_LIP = 0.5,
  LEDGE_DEPTH = 0.4,         -- the curb's depth = the round's width in plan
  LEDGE_RAMP = 1.5,         -- r12 (USER: ledge hills): the ground behind a ledge rises to its lip over this many cells
  LEDGE_ROUND = 0.375,       -- r12: the standard lip's round height (LEDGE_ROUND_K x 0.5)
  LEDGE_ROUND_SEGS = 4,      -- its segments (and a run end's plan quarter turn: this + 1)
  LEDGE_ROUND_K = 0.75,      -- round height = this x the census lip (no shadow line)
  -- r13 / r13c (USER, image 20: "smooth this out"): smooth ledge-run ends and hill edges
  LEDGE_END_BANK = true,     -- smooth ends, hill bands, gap bridges (false: the r12b geometry, byte for byte)
  LEDGE_BANK_ROWS = 4,       -- rows across the run of a ledge cell's side band / banked shoulder
  LEDGE_GAP_BRIDGE = 4,      -- r13c: a gap of 3..this many cells between two runs of one direction carries the hill
  -- r12: ground-contact AO baked per vertex (geom.ao.<list>[i], a light multiplier)
  AO_BAKE = false,           -- bake it (off until a renderer attribute reads geom.ao: ~15 ms JIT-off on big maps)
  AO_WALL = 0.35,            -- steep faces: darkest at their foot
  AO_WALL_H = 0.6,           -- ... fading out this high above the ground
  AO_FLOOR = 0.3,            -- ground beside a solid / a step up: darkest at the edge, gone a cell away
  AO_FLOOR_STEP = 0.3,       -- a neighbour this much higher counts as a step
  LEDGE_CAP_DL = 18,         -- census: the cap line is this much darker than the top's lines (luma 0..255)
  LEDGE_SHADOW_DL = 40,      -- census: a shadow line is this much darker than both neighbours
  LEDGE_LIP_MIN = 0.25, LEDGE_LIP_MAX = 0.6, -- census lip clamp (cells)
  LEDGE_LIP_V0 = 0.5,       -- lip art = rows 8-15 of mid 135 (w3 tile_profile)

  -- M9 fences: one keyed card on the run centre line + posts.
  FENCE_H = 0.6,
  FENCE_V0 = 0.06,          -- fence art rows 1-15 of 231/644
  FENCE_POST_W = 0.14,

  -- M10 signs and mailboxes.
  SIGN_BOARD_W = 0.8, SIGN_BOARD_H = 0.45, SIGN_BOARD_D = 0.1,
  SIGN_BOARD_TOP = 0.8, SIGN_POST_W = 0.08,
  SIGN_BOARD_V1 = 0.72,     -- board art = top ~11 rows (mid 3 rows 1-11)
  MAILBOX_W = 0.35, MAILBOX_H = 0.4, MAILBOX_D = 0.3,

  -- r8 interiors (input.kind == "indoor"): back wall, sills, furniture.
  INDOOR_WALL_H = 2.0,      -- back wall height (2 facade rows of art)
  INDOOR_SILL_H = 0.2,      -- low sill where a floor meets void / map edge
  FURNITURE_H_DEFAULT = 0.7, -- furniture without a known behaviour (tables)
  PLANT_POT_H = 0.55, PLANT_TOP_H = 1.35, PLANT_CARD_W = 0.7,

  -- r8 caves (input.kind == "cave"): terraced rock walls.
  CAVE_WALL_H = 1.25,       -- rock top above its cell's ground

  -- r8 border rings: far tree units (>= BORDER_FAR_CELLS from the map)
  -- use the cheapest crown.
  BORDER_FAR_CELLS = 4,

  OVER_LIFT = 0.02,         -- flat over decal above its cell's ground
  MAX_TRIS_WARN = 60000,    -- work-order Quest budget (report only).
}
