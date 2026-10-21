-- VRITK_FRLG_HOST: exports.worldPx (vritk-hook/DESIGN.md 2b line 205):
--   exports.worldPx = {api=1, groundY(x,z), isWater(x,z), isWalkable(x,z),
--     raycast(o,d,max), cell(x,z)->cx,cy}
--
-- FRLG_VOXEL's vrHost.world.* queries are all in ROOT CELLS (1 unit = 1
-- cell); FRLG_CATCH (and anything else drawing through the bridge's
-- Voxel3D stand-in / QuestHandProps) works in WORLD PX (16 px per cell,
-- the same scale PxContext.lua documents and w4/tests/test_px_cell_
-- projection.lua already proves round-trips against FRLG_VOXEL's own
-- Camera/Mat4). This module is the px-in/px-out wrapper so a P3 consumer
-- never has to divide/multiply by 16 itself or import vrHost directly.
--
-- Pure adapter: takes a `getVrHost` closure (main.lua passes `function()
-- return S.vrHost end`) rather than reading module-level state itself, so
-- it is unit-testable with a fake vrHost with no bridge/HostApi involved.
local V = ...
local _ = V

local WorldPx = {}
WorldPx.PX_PER_CELL = 16

function WorldPx.new(getVrHost)
  local M = { api = 1 }
  local PX = WorldPx.PX_PER_CELL

  local function vh()
    local h = getVrHost and getVrHost()
    return (h and h.world) and h or nil
  end

  -- (px) -> cell, floor semantics matching vrHost.world's own cell math
  -- (locate() uses math.floor on world coords already).
  function M.cell(px, pz)
    if px == nil or pz == nil then return nil, nil end
    return math.floor(px / PX), math.floor(pz / PX)
  end

  -- groundY(px, pz) -> world px height, or nil off every loaded map.
  function M.groundY(px, pz)
    local h = vh()
    if not h then return nil end
    local y = h.world.heightAt(px / PX, pz / PX)
    if y == nil then return nil end
    return y * PX
  end

  function M.isWater(px, pz)
    local h = vh()
    if not h then return nil end
    return h.world.isWater(px / PX, pz / PX)
  end

  function M.isWalkable(px, pz)
    local h = vh()
    if not h then return nil end
    return h.world.isWalkable(px / PX, pz / PX)
  end

  -- raycast(originPx{x,y,z}, dir{x,y,z}, maxDistPx) -> the same
  -- {pos, normal, dist, cell={wx,wz}, kind} shape as vrHost.world.raycast,
  -- but every distance/position field converted back to world px. `dir` is
  -- a direction, not a distance, so it is NOT scaled (vrHost.raycast
  -- normalizes it internally regardless of magnitude).
  function M.raycast(originPx, dirPx, maxDistPx)
    local h = vh()
    if not h then return nil end
    if type(originPx) ~= "table" or type(dirPx) ~= "table" then return nil end
    local originCells = {
      x = (originPx.x or originPx[1] or 0) / PX,
      y = (originPx.y or originPx[2] or 0) / PX,
      z = (originPx.z or originPx[3] or 0) / PX,
    }
    local dirCells = { x = dirPx.x or dirPx[1] or 0, y = dirPx.y or dirPx[2] or 0, z = dirPx.z or dirPx[3] or 0 }
    local maxDistCells = (tonumber(maxDistPx) or (20 * PX)) / PX
    local hit = h.world.raycast(originCells, dirCells, maxDistCells)
    if not hit then return nil end
    return {
      pos = { x = hit.pos.x * PX, y = hit.pos.y * PX, z = hit.pos.z * PX },
      normal = hit.normal,
      dist = hit.dist * PX,
      cell = hit.cell,
      kind = hit.kind,
    }
  end

  return M
end

return WorldPx
