-- FireRed native sign families. Pure gate shared by metadata discovery, GPU
-- preparation and (by the same constants) the mesher. Never touches the engine.
-- Every family is a (map id, tileset pair, metatile id) triple taken from the
-- audited native rasters; anything else keeps its native appearance.
local M = { VERSION = 'firered-sign-profiles-2' }
-- Every metatile id any family above can match (WorldSource reads their palettes once per tileset).
M.MIDS = { 2, 3, 360, 361, 685, 717, 780, 807, 815, 828, 853 }
-- Gym crest tiles (OVER layer art above the gym board); their palette comes from the over bytes.
M.CREST_MIDS = { 352, 703, 772 }
-- Mailbox 3D body (world units; mesher and runtime must agree). Canvas rows used by the front face = CANVAS_H of 256.
M.MAILBOX = { W = 0.56, D = 0.34, RH = 0.32, RISE = 0.14, POSTH = 0.26, CANVAS_H = 210 }
function M.style(input, mid)
  local mt = tonumber(input.mapType)
  if mt == 8 or mt == 9 or input.kind == 'indoor' then return nil end
  local id, pair = tostring(input.mapId or ''), tostring(input.pair or '')
  if not id:match('^FR_') then return nil end
  if mid == 2 then return 'fr-metal' end
  if mid == 3 then return 'fr-wood' end
  if mid == 717 and (pair == 'general__rom_082d4bfc' or pair == 'general__rom_082d4df4' or pair == 'general__rom_082d4e24') then return 'fr-wood' end
  if (mid == 807 or mid == 853) and pair == 'general__rom_082d4b3c' or mid == 828 and pair == 'general__rom_082d4b9c' then return 'fr-wood' end
  if mid == 360 or mid == 780 and pair == 'general__rom_082d4b9c' then return 'fr-gym' end
  -- Mailboxes: the standalone MID 361, Pallet's MID 685 and Saffron's MID 815 only (the mesher's own gate).
  if mid == 361 or mid == 685 and pair == 'pallet_outdoor' or mid == 815 and pair == 'general__rom_082d4b9c' then return 'fr-mailbox' end
end
-- Baked drop shadow / ground of the native art: tile-local pixel (x, y), 0..15. Such pixels are never meshed and never
-- painted into a sign texture (they are transparent there); the engine's own lighting and contact shadow replace them.
-- The kept post / leg / foot regions are the ones the mesher textures from the tile.
function M.shadow(style, x, y)
  if style == 'fr-mailbox' then
    if y >= 12 then return not (x >= 6 and x <= 9 and y <= 13) end -- the dark stub (cols 6-9, rows 12-13) is the post; row 14 holds the shadow corners
    return x < 2 or x > 13                                      -- outside the body outline: ground
  elseif style == 'fr-metal' then
    if y <= 12 then return false end                            -- board rows 0-12 (row 12 = bottom rail)
    return not (y <= 14 and ((x >= 2 and x <= 4) or (x >= 11 and x <= 13))) -- two feet, rows 13-14
  elseif style == 'fr-wood' then
    if y <= 11 then return false end
    return not (y <= 13 and x >= 6 and x <= 9)                  -- single post, rows 12-13
  elseif style == 'fr-gym' then
    if y <= 10 then return x >= 15 end
    if y <= 12 then return not ((x >= 1 and x <= 4) or (x >= 10 and x <= 13)) end -- legs, rows 11-12
    if y == 13 then return not (x == 2 or x == 3 or x == 11 or x == 12) end         -- leg feet, row 13
    return true
  end
  return false
end
return M
