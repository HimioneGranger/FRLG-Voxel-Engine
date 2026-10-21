-- FRLG_VOXEL: warm ground light pools in front of lit doors (worker "atmos",
-- GW-P4, daynight-weather-hook/DESIGN.md 4.7, reading-voxel-renderer-sky-
-- light.md 3.6 "P2, the mask B channel"). One soft ellipse per door cell,
-- on the walkable (south) side, baked at map-build time into the shadow
-- mask's free B channel (Light.lua writes 0 there today) or, on outdoor
-- town maps built with shadows off, into a standalone pools-only mask read
-- through the shader's pools-only branch (DESIGN.md 3.4).
--
-- Pure CPU geometry (this file never touches love.graphics; the caller
-- turns the returned grid into pixels with love.image, same as
-- render/Light.lua's own mask builders). Static per map: pool positions
-- never move, only the shader's u_poolGain (from AtmosState.pools.gain,
-- the night weight) fades them in and out.
--
-- Door cells (urgent fix, 2026-09-28): geom.stats.buildingInfo[i].doors
-- (W3's r12 per-building door list), falling back to an MB.DOOR behaviour
-- scan only when a map has no r12 door data at all -- see doorCells below.
-- Building width: the footprint (maxX - minX + 1) of the buildingInfo entry
-- the door belongs to, else DEFAULT_WIDTH_CELLS in the legacy fallback.
-- FRLG buildings face south (the player always approaches/leaves a door
-- from the south, per
-- the mesher's own wall/eave convention), so the pool sits centred one
-- DEPTH_CELLS band south of the door cell -- matching the user's reference
-- sheets (v17/v18: warm ellipses on the ground south of building fronts).
local V = ...
local _ = V

local LightPools = {}

LightPools.RES = 4              -- texels per cell (matches Light.RES; kept
                                 -- independent so this file has zero
                                 -- render/Light.lua dependency)
LightPools.DEPTH_CELLS = 1.6    -- how far south of the door the pool reaches
LightPools.DEFAULT_WIDTH_CELLS = 3
LightPools.MAX_POOLS = 64       -- guard: a pathological map cannot blow the build budget

-- One entry per door found: { x, z (door cell, map-local), width (cells) }.
-- geom: the mesher's output (geom.stats.buildingInfo, optional). input:
-- { width, height, cellAt(x,z) -> cell|nil }. MB: lib/mesh/MB.lua (MB.DOOR).
--
-- urgent fix (W3->W8 report, 2026-09-28): built directly from W3's
-- per-building door list first (geom.stats.buildingInfo[i].doors --
-- world-space, { x, z = the door cell, wx = its centre x, wz = the front
-- wall's plane, y = the ground, w = 1, h = WALL_ROW_UNIT, face = "south",
-- legacy }; see FrlgMesher.lua's comment above its nightDoors local),
-- replacing the previous MB.DOOR behaviour cell-scan + "which nearby
-- building is this door probably against" guess -- each door already lives
-- INSIDE its own building's buildingInfo entry, so there is nothing left to
-- guess. The old scan is kept as a fallback only for a map/cache with
-- buildingInfo but no r12 door data at all (never runs once every cached
-- mesh has been rebuilt past this point; harmless to keep as a safety net).
function LightPools.doorCells(geom, input, MB)
  local list = {}
  local buildings = geom and geom.stats and geom.stats.buildingInfo or nil
  if type(buildings) == "table" then
    for i = 1, #buildings do
      local b = buildings[i]
      local bdoors = type(b) == "table" and b.doors
      if type(bdoors) == "table" and #bdoors > 0 then
        local width = math.max(1, (b.maxX or 0) - (b.minX or 0) + 1)
        for _, d in ipairs(bdoors) do
          if #list >= LightPools.MAX_POOLS then return list end
          if type(d) == "table" and d.x ~= nil and d.z ~= nil then
            list[#list + 1] = { x = d.x, z = d.z, width = width }
          end
        end
      end
    end
    if #list > 0 then return list end
  end
  -- legacy fallback: no r12 door data anywhere on this map.
  local cellAt = input and input.cellAt
  local w, h = input and input.width, input and input.height
  if not (cellAt and w and h and MB and MB.DOOR) then return list end
  for z = 0, h - 1 do
    for x = 0, w - 1 do
      if #list >= LightPools.MAX_POOLS then return list end
      local okC, c = pcall(cellAt, x, z)
      if okC and c and c.behavior ~= nil and MB.DOOR[c.behavior] then
        local width = LightPools.DEFAULT_WIDTH_CELLS
        if buildings then
          for i = 1, #buildings do
            local b = buildings[i]
            if b.minX and x >= b.minX - 1 and x <= b.maxX + 1
                and b.minY and z >= b.minY - 2 and z <= b.maxY + 1 then
              width = math.max(1, (b.maxX - b.minX + 1))
              break
            end
          end
        end
        list[#list + 1] = { x = x, z = z, width = width }
      end
    end
  end
  return list
end

-- Sparse grid (k = j*W+i+1 -> strength 0..1) at LightPools.RES texels per
-- cell, W = width*RES, H = height*RES. Returns nil, "no doors" when the map
-- has none (most maps: pools only matter near town building fronts).
function LightPools.bake(geom, input, MB, opts)
  opts = opts or {}
  local doors = LightPools.doorCells(geom, input, MB)
  if #doors == 0 then return nil, "no doors" end
  local R = opts.res or LightPools.RES
  local w, h = input.width, input.height
  local W, H = w * R, h * R
  local want = opts.want   -- border rings: only ring texels are ever sampled
  local grid = {}
  local depth = LightPools.DEPTH_CELLS
  for _, d in ipairs(doors) do
    local rx, rz = d.width / 2, depth / 2
    local cx, cz = d.x + 0.5, d.z + 1.0 + rz   -- centred `depth` south of the door
    local i0 = math.max(0, math.floor((cx - rx - 0.5) * R))
    local i1 = math.min(W - 1, math.floor((cx + rx + 0.5) * R))
    local j0 = math.max(0, math.floor((cz - rz - 0.5) * R))
    local j1 = math.min(H - 1, math.floor((cz + rz + 0.5) * R))
    for j = j0, j1 do
      local pz = (j + 0.5) / R
      local dz = (pz - cz) / rz
      local dz2 = dz * dz
      if dz2 < 1 then
        for i = i0, i1 do
          if not want or want(math.floor(i / R), math.floor(j / R)) then
            local px = (i + 0.5) / R
            local dx = (px - cx) / rx
            local q = 1 - (dx * dx + dz2)
            if q > 0 then
              local s = math.sqrt(q)
              local k = j * W + i + 1
              if (grid[k] or 0) < s then grid[k] = s end
            end
          end
        end
      end
    end
  end
  if next(grid) == nil then return nil, "no doors in range" end
  return grid, W, H
end

-- Writes a baked grid into the B channel of an existing shadow/contact mask
-- ImageData (Light.shadowMask / Light.contactMask's return), leaving R, G
-- and A untouched. Call before love.graphics.newImage(mask) wraps it
-- (Scene.lua's coordinated edit, right after Light.shadowMask/contactMask).
function LightPools.writeIntoMask(data, grid, W, H)
  if not (data and grid) then return false end
  local okDim, dw, dh = pcall(data.getDimensions, data)
  if not okDim or dw ~= W or dh ~= H then return false end
  for k, s in pairs(grid) do
    local i = (k - 1) % W
    local j = math.floor((k - 1) / W)
    local r, g, _, a = data:getPixel(i, j)
    data:setPixel(i, j, r or 0, g or 0, math.min(1, s), a or 1)
  end
  return true
end

-- Standalone pools-only mask (rgba8; only B is meaningful) for an outdoor
-- town map built with shadows off (DESIGN.md 3.4 "Pools without shadows").
-- Returns an ImageData, or nil when the map has no doors in range.
function LightPools.buildStandaloneMask(geom, input, MB, opts)
  if not (love and love.image and love.image.newImageData) then return nil end
  local grid, W, H = LightPools.bake(geom, input, MB, opts)
  if not grid then return nil end
  local data = love.image.newImageData(W, H, "rgba8")
  -- rgba8 ImageData reads back as 0 for anything not explicitly set; only
  -- touch texels the grid actually covers, which is the common case (a map
  -- with a handful of doors), instead of a full W*H clear loop.
  for k, s in pairs(grid) do
    local i = (k - 1) % W
    local j = math.floor((k - 1) / W)
    data:setPixel(i, j, 0, 0, math.min(1, s), 1)
  end
  return data, W, H
end

return LightPools
