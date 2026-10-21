-- FRLG_VOXEL / W1: pure DATA table of pret metatile-behavior (MB_*) byte
-- values used by FrlgMesher.lua's cell classification. Every number here is
-- copied from a constant already defined and pret-source-cited elsewhere in
-- this engine (src/core/game3/collision.lua, field.lua, battle/bg.lua,
-- trainer_sight.lua, scripting/interaction_scripts.lua) -- see the citation
-- on each line below. None of these are guesses.
--
-- Plain data table, no logic, no requires: safe for the mod sandbox and
-- safe for FrlgMesher.lua to receive via deps.MB (see w1/LOADING.md for how
-- W2's mod loader is expected to load and pass this file in).

return {
  -- src/core/game3/battle/bg.lua:146 (MB_TALL_GRASS) and
  -- src/core/game3/collision.lua:317-318 (MB_CYCLING_ROAD_PULL_DOWN_GRASS,
  -- the grass variant of the Route 1 cycling-road-pull tile pair).
  GRASS = { [0x02] = true, [0xD1] = true },

  -- src/core/game3/collision.lua:274-278 SURFABLE_BEH (pret
  -- metatile_behavior.c:204 sBehaviorSurfable) -- deep/surfable water.
  WATER_DEEP = {
    [0x10] = true, [0x11] = true, [0x12] = true, [0x13] = true, [0x15] = true,
    [0x1A] = true, [0x1B] = true,
    [0x50] = true, [0x51] = true, [0x52] = true, [0x53] = true,
  },
  -- src/core/game3/collision.lua:288-290 (MB_PUDDLE, MB_SHALLOW_WATER --
  -- only water-like at elevation==1, per Collision.isWaterOn).
  WATER_SHALLOW = { [0x16] = true, [0x17] = true },

  -- src/core/game3/collision.lua:292-294 (MB_ICE, MB_THIN_ICE, MB_CRACKED_ICE).
  ICE = { [0x23] = true, [0x26] = true, [0x27] = true },

  -- Ledge jump bytes -> one-way hop direction (= the edge the lip sits on).
  -- r7m M6: 0x38-0x3B follow the engine's importer table,
  -- src/core/game3/scripting/collision.lua:13-14 (JUMP_DIR: 0x38 E, 0x39 W,
  -- 0x3A N, 0x3B S; pret MB_JUMP_EAST/WEST/NORTH/SOUTH). The pre-r7m table
  -- had them rotated (0x3B -> "right"), which put a fin on the east edge of
  -- every south-hop cell. Route 1 / Viridian ledges are all 0x3B and their
  -- art draws the lip on the tile's south half (rows 8-15 of mid 135).
  -- r12: 0xA0-0xA3 are NOT ledge behaviours -- in FRLG's behaviour table
  -- they are furniture (0xA0 impressive machine ... SMALL_PROP below; one
  -- sits in Trainer Tower 3F); 0xA0-0xA7 are the Gen2 COLLISION codes the
  -- engine's extract uses for ledge hops (engine collision.lua), another
  -- field. Removed: they drew ledge curbs on furniture.
  LEDGE_DIR = {
    [0x38] = "right", -- MB_JUMP_EAST
    [0x39] = "left",  -- MB_JUMP_WEST
    [0x3A] = "up",    -- MB_JUMP_NORTH
    [0x3B] = "down",  -- MB_JUMP_SOUTH
  },

  -- src/core/game3/collision.lua:411-429, Collision.isWarpMetatileBehavior /
  -- isStepWarpBehavior (pret field_control_avatar.c / metatile_behavior.c,
  -- cited inline there). Doors/ladders/warps -- rendered as a recessed
  -- opening rather than a solid wall block.
  DOOR = {
    [0x60] = true, -- MB_CAVE_DOOR
    [0x61] = true, -- MB_LADDER
    [0x62] = true, [0x63] = true, [0x64] = true, [0x65] = true, -- arrow warps
    [0x66] = true, -- MB_FALL_WARP
    [0x67] = true, -- MB_REGULAR_WARP
    [0x68] = true, -- MB_LAVARIDGE_1F_WARP
    [0x69] = true, -- MB_WARP_DOOR
    [0x6A] = true, [0x6B] = true, -- escalators
    [0x6C] = true, [0x6D] = true, [0x6E] = true, [0x6F] = true, -- stair warps
    [0x71] = true, -- MB_UNION_ROOM_WARP / also the repaired COLL_DOOR value
  },

  -- src/core/game3/field.lua:691-693 (MB_SIGNPOST, MB_POKEMON_CENTER_SIGN,
  -- MB_POKEMART_SIGN, pret field_control_avatar.c:787).
  SIGN = { [0x84] = true, [0x87] = true, [0x88] = true },

  -- src/core/game3/scripting/interaction_scripts.lua I.FLAVOR: small indoor
  -- interactables. Listed for completeness (our 3 outdoor maps rarely hit
  -- these) -- rendered as a generic thin prop rather than a wall block if
  -- ever seen on a solid cell outdoors.
  SMALL_PROP = {
    [0x81] = true, [0x82] = true, [0x86] = true, [0x89] = true, [0x8A] = true,
    [0x8B] = true, [0x8C] = true, [0x90] = true, [0x93] = true, [0x94] = true,
    [0x95] = true, [0x96] = true, [0x97] = true, [0x98] = true, [0x99] = true,
    [0x9A] = true, [0x9B] = true, [0x9C] = true, [0x9D] = true, [0x9E] = true,
    [0x9F] = true, [0xA1] = true, [0xA2] = true,
  },

  -- src/core/game3/collision.lua:544-548 Collision.cell() fallback and
  -- Collision.isWalkable(): 0x07 / 0xff / 0x29 are the three special raw
  -- COLL-grid bytes; 0x29 is water on the FRLG grid specifically
  -- (Collision.isWaterOn / isWater).
  COLL_SOLID_FALLBACK = 0x07,
  COLL_BORDER = 0xFF,
  COLL_WATER = 0x29,

  -- W3: outdoor General-tileset TREE metatile ids, copied verbatim from the
  -- engine importer's own list, src/core/game3/scripting/collision.lua:38-43
  -- (TREE_MIDS; Collision.classify -> "TREE" when kind ~= "indoor" and the
  -- cell is solid). Not an MB_* byte: FRLG trees carry MB_NORMAL (0x00), so
  -- the metatile id is the real signal. Primary-tileset ids (< 640), so the
  -- same on every FRLG outdoor map. FALLBACK ONLY -- the live WorldSource
  -- passes the engine's per-cell category ("TREE") itself; the mesher uses
  -- this table when a cell has no category and input.kind ~= "indoor".
  -- r11 (USER REPORT: flowers flat): the general (primary) tileset's flower
  -- metatile -- the animated red flower, walkable, behaviour 0 -- shared by
  -- every Kanto and Sevii outdoor pair (their primary is the general
  -- tileset). The engine animates its tiles in the under atlas, which the
  -- flower cards sample.
  FLOWER_MIDS = { [0x004] = true },
  GENERAL_TREE_MIDS = {
    [0x00A] = true, [0x00B] = true, [0x00C] = true, [0x00E] = true, [0x00F] = true,
    [0x013] = true, [0x014] = true, [0x015] = true, [0x016] = true, [0x017] = true,
    [0x018] = true, [0x019] = true, [0x01A] = true, [0x01B] = true, [0x01C] = true,
    [0x01D] = true, [0x01E] = true, [0x01F] = true,
    [0x024] = true, [0x025] = true, [0x026] = true, [0x027] = true,
  },

  -- r7m M11: how the General-tileset tree metatiles tile one FRLG 2x2 tree
  -- (read off the atlas, w3 analysis tree_tiles.png / pallet_west_border
  -- .png): even mid = left half, odd = right half; 28-31 are crown tops,
  -- 20-23 crown bottoms overlapped by the next tree's tip (forest
  -- interior), 36-39 crown bottoms with the trunk on open ground.
  TREE_TOP_L = { [28] = true, [30] = true },
  TREE_TOP_R = { [29] = true, [31] = true },
  TREE_BOTTOM_L = { [20] = true, [22] = true, [36] = true, [38] = true },
  TREE_BOTTOM_R = { [21] = true, [23] = true, [37] = true, [39] = true },
  -- r7m M4: one leaf-only swatch for every crown: mid 28, texel columns
  -- 5-15, rows 0-15 (pure leaves, no trunk / ground / outline).
  LEAF_SWATCH = { mid = 28, u0 = 5 / 16, u1 = 16 / 16, v0 = 0, v1 = 1 },
  -- r9 Part B: the crown's DARK leaves (undersides, lobe bottoms, the
  -- understory under the forest edge): mid 20 (tree bottom-left) texel
  -- columns 4-10, rows 1-6 -- only the two dark greens (58,148,49) /
  -- (58,90,16), no ground, trunk or light leaf. BARK: mid 20 columns
  -- 12-15, rows 8-11 -- the trunk's (66,58,49) / (115,99,99) with dark
  -- leaf. Both General-tileset primary metatiles (same art in every
  -- outdoor pair, like LEAF_SWATCH); w3/analysis/r9/tree_tiles.png.
  DARK_SWATCH = { mid = 20, u0 = 4 / 16, u1 = 11 / 16, v0 = 1 / 16, v1 = 7 / 16 },
  BARK_SWATCH = { mid = 20, u0 = 12 / 16, u1 = 16 / 16, v0 = 8 / 16, v1 = 12 / 16 },
  -- SHADE: the understory closure under the forest edge -- mid 20 columns
  -- 5-10, rows 7-9: only the darkest leaf green (58,90,16) (deep shade).
  SHADE_SWATCH = { mid = 20, u0 = 5 / 16, u1 = 11 / 16, v0 = 7 / 16, v1 = 10 / 16 },
  -- r10: forest-tileset trees drawn 3 metatiles wide, 2 rows per tree,
  -- stacked every 2 rows (Viridian Forest, Six Island Pattern Bush: pair
  -- general__rom_082d4dc4 -- its SECONDARY mids, so keyed by pair).
  -- upper[mid] / lower[mid] = column 1..3 of a tree's upper / lower row
  -- (648 / 649 / 650: the forest's top edge; 654 / 655 / 672 / 673 / 674:
  -- lower-row variants); base[mid] = column of the trunk + shadow row under
  -- a column's last tree (675-677: that unit is 3x3). 662 / 670 draw two
  -- trees overlapping and stay single trees. Plus that tileset's own leaf /
  -- dark / bark / shade swatches (under atlas; texels read off
  -- w3/analysis/r9/vf_patch.png): leaf = 664 columns 4-15 (light + mid
  -- greens, no ground), dark = 656 columns 4-15 rows 0-11, bark = 676
  -- columns 5-10 rows 0-3, shade = 676 rows 5-6 (58,82,0).
  FOREST3_PAIRS = {
    -- Berry Forest has its own yellow foliage and three-column tile layout.
    -- Keep this record separate: its art differs from the Viridian forest pair.
    ["general__rom_082d5004"] = {
      tips = { [641] = true, [644] = true }, -- OVER crown tips on grass, above a formed tree
      broad = {
        upL = { 6, 5, 16, 16 }, upR = { 0, 5, 10, 16 },
        loL = { 2, 0, 16, 9 }, loR = { 0, 0, 14, 9 },
        hemL = { 2, 0, 16, 9 }, hemR = { 0, 0, 14, 9 },
        uvInset = 0.5, -- stay inside the clean foliage pixels under bilinear filtering
      },
      ground = { [219] = true, [220] = true, [221] = true }, -- drawn exit path beyond the warp
      upper = { [648] = 1, [664] = 1, [665] = 2, [650] = 3, [666] = 3 },
      lower = { [656] = 1, [672] = 1, [657] = 2, [673] = 2, [658] = 3, [674] = 3 },
      base = { [675] = 1, [676] = 2, [677] = 3 },
      leaf = { mid = 664, u0 = 4 / 16, u1 = 16 / 16, v0 = 0, v1 = 1 },
      dark = { mid = 656, u0 = 4 / 16, u1 = 16 / 16, v0 = 0, v1 = 12 / 16 },
      bark = { mid = 676, u0 = 5 / 16, u1 = 11 / 16, v0 = 0, v1 = 4 / 16 },
      shade = { mid = 676, u0 = 0, u1 = 16 / 16, v0 = 5 / 16, v1 = 7 / 16 },
    },
    ["general__rom_082d4dc4"] = {
      upper = { [648] = 1, [664] = 1, [649] = 2, [665] = 2, [650] = 3, [666] = 3 },
      lower = { [656] = 1, [672] = 1, [654] = 1, [657] = 2, [673] = 2, [658] = 3, [674] = 3, [655] = 3 },
      base = { [675] = 1, [676] = 2, [677] = 3 },
      leaf = { mid = 664, u0 = 4 / 16, u1 = 16 / 16, v0 = 0, v1 = 1 },
      dark = { mid = 656, u0 = 4 / 16, u1 = 16 / 16, v0 = 0, v1 = 12 / 16 },
      bark = { mid = 676, u0 = 5 / 16, u1 = 11 / 16, v0 = 0, v1 = 4 / 16 },
      shade = { mid = 676, u0 = 0, u1 = 16 / 16, v0 = 5 / 16, v1 = 7 / 16 },
    },
  },

  -- r8 interiors: FLOOR-STANDING furniture behaviours -> box height (world
  -- units; heights are PROPOSED, the byte meanings are verified):
  -- src/core/game3/scripting/interaction_scripts.lua:4-15 (I.FLAVOR, pret
  -- field_control_avatar.c GetInteractedMetatileScript) + 0x83 PC (:27) +
  -- 0x80 MB_COUNTER (src/core/game3/scripting/collision.lua:35).
  FURNITURE_H = {
    [0x80] = 0.9,  -- counter
    [0x81] = 1.2,  -- bookshelf
    [0x82] = 1.2,  -- PokeMart shelf
    [0x83] = 1.0,  -- PC
    [0x86] = 0.9,  -- TV
    [0x89] = 1.0,  -- cabinet
    [0x8A] = 0.9,  -- kitchen
    [0x8B] = 1.0,  -- dresser
    [0x8C] = 0.9,  -- snacks
    [0x90] = 0.9,  -- food
    [0x95] = 1.2,  -- power plant machine
    [0x96] = 0.8,  -- telephone
    [0x97] = 1.0,  -- computer
    [0x99] = 0.9,  -- tasty food
    [0x9A] = 0.6,  -- trash bin
    [0x9B] = 0.8,  -- cup
    [0x9F] = 1.0,  -- neatly lined-up tools
    [0xA0] = 1.2,  -- impressive machine
    [0xA1] = 0.9,  -- video game
    [0xA2] = 1.0,  -- burglary (ransacked shelf)
  },
  -- Wall-MOUNTED art (same sources): stays part of the back wall.
  WALL_MOUNTED = {
    [0x85] = true, -- wall town map (interaction_scripts.lua:28)
    [0x93] = true, -- blueprints
    [0x94] = true, -- painting
    [0x98] = true, -- advertising poster
    [0x9C] = true, -- polished window
    [0x9D] = true, -- beautiful sky window
    [0x9E] = true, -- blinking lights
  },
  -- Stair / ladder / escalator warps (subset of DOOR above): furniture
  -- touching one is the staircase drawing -> a flat decal, not a box.
  STAIR_WARP = {
    [0x61] = true, [0x6A] = true, [0x6B] = true,
    [0x6C] = true, [0x6D] = true, [0x6E] = true, [0x6F] = true,
  },

  -- r7m M1: walkability per runtime COLL byte, used only when a cell gives
  -- no `walkable` field (w1 fixtures). Copied mechanically from the
  -- engine's src/core/CollPermissions.lua TABLE via CollPermissions.of():
  -- L = land (walkable), W = water, X = wall. 256 chars, byte = index-1.
  COLL_PERM =
    "LLLLLLLXLLLLLLLX" .. -- 0x00-0x0F
    "LLXLLXLLLLXLLXLL" .. -- 0x10-0x1F
    "WWWLWWWXWWWLWWWX" .. -- 0x20-0x2F
    "WWWWWWWWWWWWWWWW" .. -- 0x30-0x3F
    "LLLLLLLLLLLLLLLL" .. -- 0x40-0x4F
    "LLLLLLLLLLLLLLLL" .. -- 0x50-0x5F
    "LLXLLLLLLLXLLLLL" .. -- 0x60-0x6F
    "LLLLLLLLLLLLLLLL" .. -- 0x70-0x7F
    "XXXXXLLLXXXXXLLL" .. -- 0x80-0x8F
    "XXXXXXXXXXXXXXXX" .. -- 0x90-0x9F
    "LLLLLLLLLLLLLLLL" .. -- 0xA0-0xAF
    "LLLLLLLLLLLLLLLL" .. -- 0xB0-0xBF
    "WWWWWWWWWWWWWWWW" .. -- 0xC0-0xCF
    "LLLLLLLLLLLLLLLL" .. -- 0xD0-0xDF
    "LLLLLLLLLLLLLLLL" .. -- 0xE0-0xEF
    "LLLLLLLLLLLLLLLX",   -- 0xF0-0xFF
}
