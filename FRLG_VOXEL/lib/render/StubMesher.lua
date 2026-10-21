-- FRLG_VOXEL: W2's trivial stand-in mesher (identical copy kept at
-- w2/stub_mesher.lua). Same signature as W1's lib/mesh/FrlgMesher.lua:
--   M.build(input, deps) -> geom
-- It is also the runtime fallback when W1's mesher is absent or throws.
-- Output: every cell's under art as a flat top quad at elevation *
-- ELEV_UNIT, a vertical skirt wherever a neighbour is lower (so terraces
-- read as steps), non-walkable cells raised by BLOCK_H as simple boxes, and
-- the over art as a cutout decal floated above the top. Deliberately crude.
local V = ...
local _ = V

local M = {}

local ELEV_UNIT = 0.25
local BLOCK_H = 1.0
local OVER_LIFT = 0.02

local function quad(list, a, b, c, d, n, uv)
  -- a,b,c,d corners {x,y,z}, counter-clockwise seen from the normal side;
  -- uv = {u0, v0, u1, v1} mapped a=(u0,v1) b=(u1,v1) c=(u1,v0) d=(u0,v0)
  local u0, v0, u1, v1 = uv[1], uv[2], uv[3], uv[4]
  local nx, ny, nz = n[1], n[2], n[3]
  local va = { a[1], a[2], a[3], u0, v1, nx, ny, nz }
  local vb = { b[1], b[2], b[3], u1, v1, nx, ny, nz }
  local vc = { c[1], c[2], c[3], u1, v0, nx, ny, nz }
  local vd = { d[1], d[2], d[3], u0, v0, nx, ny, nz }
  local n0 = #list
  list[n0 + 1] = va; list[n0 + 2] = vb; list[n0 + 3] = vc
  list[n0 + 4] = va; list[n0 + 5] = vc; list[n0 + 6] = vd
end

local function topOf(cell)
  if not cell then return nil end
  local h = (tonumber(cell.elevation) or 0) * ELEV_UNIT
  if cell.walkable == false then h = h + BLOCK_H end
  return h
end

function M.build(input, deps)
  local _ = deps
  local w, h = input.width or 0, input.height or 0
  local atlas = input.atlas
  local opaque, under, over = {}, {}, {}
  local heights = {}
  for y = 0, h - 1 do
    for x = 0, w - 1 do
      local c = input.cellAt(x, y)
      if c then
        local top = topOf(c)
        heights[y * w + x + 1] = top
        local u0, v0, u1, v1 = atlas.underRect(c.mid)
        local uv = { u0, v0, u1, v1 }
        -- top face: north edge at z=y, south edge at z=y+1; texture v0 = north
        quad(opaque,
          { x, top, y + 1 }, { x + 1, top, y + 1 }, { x + 1, top, y }, { x, top, y },
          { 0, 1, 0 }, uv)
        -- skirts toward lower neighbours (or map edge down to 0)
        local sides = {
          { 0, 1, { x, y + 1 }, { x + 1, y + 1 }, { 0, 0, 1 } },   -- south
          { 0, -1, { x + 1, y }, { x, y }, { 0, 0, -1 } },         -- north
          { 1, 0, { x + 1, y + 1 }, { x + 1, y }, { 1, 0, 0 } },   -- east
          { -1, 0, { x, y }, { x, y + 1 }, { -1, 0, 0 } },         -- west
        }
        for _, s in ipairs(sides) do
          local n = input.cellAt(x + s[1], y + s[2])
          local nt = topOf(n) or 0
          if nt < top - 1e-4 then
            local p, q = s[3], s[4]
            quad(opaque,
              { p[1], nt, p[2] }, { q[1], nt, q[2] }, { q[1], top, q[2] }, { p[1], top, p[2] },
              s[5], uv)
          end
        end
        if c.layerType == 0 and atlas.overRect then
          local o0, p0, o1, p1 = atlas.overRect(c.mid)
          if o0 then
            local lift = top + OVER_LIFT
            quad(over,
              { x, lift, y + 1 }, { x + 1, lift, y + 1 }, { x + 1, lift, y }, { x, lift, y },
              { 0, 1, 0 }, { o0, p0, o1, p1 })
          end
        end
      end
    end
  end
  return {
    opaque = opaque,
    cutoutUnder = under,
    cutoutOver = over,
    bounds = { 0, 0, 0, w, 8, h },
    stats = { tris = (#opaque + #under + #over) / 3, mesher = "w2-stub" },
    heightAt = function(cx, cy)
      if cx < 0 or cy < 0 or cx >= w or cy >= h then return nil end
      local c = input.cellAt(cx, cy)
      return c and (tonumber(c.elevation) or 0) * ELEV_UNIT or nil
    end,
  }
end

return M
