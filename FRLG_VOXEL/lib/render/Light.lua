-- SolarShadows now commits the actual WeatherLab native sun together with
-- bounded shadow-only rebakes. The constants below remain indoor defaults;
-- outdoors unknown/stale native lighting fails closed, never NW fallback.
-- FRLG_VOXEL historical default: one sun from the upper left (north-west),
-- 42 degrees high so trees and houses throw readable shadows toward the lower
-- right like the reference look, a soft ambient and a weak fill from the
-- viewer's side, plus the per-map SHADOW HEIGHT MASK the shaders read.
--
-- Shadow mask (no shadow maps, no extra render passes): per map, a small
-- texture with RES texels per cell. Each texel stores the height below which
-- a point at that xz is shadowed from the sun:
--   S(p) = max over 0<t<=MAX_SHADOW_CELLS of ( H(p + t*toSunXZ) - t*tan(e) )
-- where H is the height of the geometry over each texel. The shaders compare
-- the fragment's height (plus a slope bias) with S, so roofs and canopy tops
-- stay lit while the ground, trunks and the lee walls underneath darken;
-- linear filtering of the mask gives the soft edge.
--
-- Review R4 (2026-09-28): H is rasterised -- each texel centre inside a
-- triangle takes the triangle's interpolated plane height (a hip roof is a
-- slope, not a box at its ridge height); only near-vertical triangles still
-- mark their xz bounding box at their top. Tree units (geom.treeOccluders,
-- optional) are stamped as domes, so forest shadows scallop per tree. RES 4,
-- shadow length capped in cells. Built on the CPU once per map mesh, inside
-- the Scene build coroutine (opts.yield is deadline-checked by the caller).
--
-- Tour review R4 (2026-09-28): cutout triangles cast by what they SHOW, not
-- by their bounding box -- the caller passes opts.alpha(listName, a, b, c,
-- vertical), which returns false for a triangle whose texels are all
-- transparent (a sign's keyed edge and top quads), or the world heights of
-- its top and bottom visible rows (a board on a post). The mask also keeps
-- the BOTTOM of floating occluders (G channel): a ground point is shadowed
-- only when the ray toward the sun passes between an occluder's bottom and
-- top, so a sign board, an eave or a tree crown throws its shadow away from
-- its foot instead of a solid wedge from the ground up. Indoors and in caves there is no sun:
-- Light.contactMask stores a soft ~0.3-cell contact darkening at the foot of
-- walls and furniture instead (same texture format, same shader compare), so
-- the stair-stepped sun edges and the 2-cell band along back walls go away.
--
-- Worker "atmos" (GW-P1/GW-P4, daynight-weather-hook/DESIGN.md 3.3 step 6,
-- 4.7): two additions that live OUTSIDE this file on purpose, so night does
-- not get darkened twice and Scene.lua (owned this phase by W6/W3, not us)
-- only needs one small coordinated edit each:
--   * Per-frame u_terms (ambient, sun, fill) is no longer just Light.TERMS.
--     render/AtmosState.lua's shadowTerms(s) computes the night/overcast
--     version every frame (s = sunShare = dayWeight*(1-overcast)); at s=1 it
--     is IDENTICAL to Light.TERMS below (verified by this worker's
--     atmos_selftest.lua), so Light.TERMS stays the correct indoor/fallback
--     default and the single source of truth for "full sun, no fade".
--   * The mask's B channel (still written 0 by shadowMask/contactMask here)
--     is free for render/LightPools.lua to bake warm ground-pool strength
--     into, post-hoc, on the returned ImageData -- before it becomes a GPU
--     Image (Scene:_mask). This file's own R/G contract is unchanged.
local V = ...
local _ = V

local Light = {}

Light.ELEVATION = math.rad(42)
-- horizontal direction TOWARD the sun: north-west, a little more west than
-- north (x east, z south); shadows fall east-south-east
local SX, SZ = -0.8, -0.6
Light.TO_SUN_XZ = { SX, SZ }
local ce, se = math.cos(Light.ELEVATION), math.sin(Light.ELEVATION)
Light.SUN = { SX * ce, se, SZ * ce }                -- unit vector toward the sun
Light.DEFAULT_SUN = { Light.SUN[1], Light.SUN[2], Light.SUN[3] }
Light.solarWeight = 0 -- outdoor casts fail closed until a coherent native commit
function Light.commitSolar(d)
  SX, SZ = d.x, d.z
  Light.TO_SUN_XZ[1], Light.TO_SUN_XZ[2] = SX, SZ
  Light.SUN[1], Light.SUN[2], Light.SUN[3] = d.dx, d.dy, d.dz
  Light.TAN_E = d.tan
end
Light.FILL = (function()                            -- from the viewer's side (south)
  local x, y, z = 0.2, 0.35, 1.0
  local n = math.sqrt(x * x + y * y + z * z)
  return { x / n, y / n, z / n }
end)()
-- ambient, sun weight, fill weight (top face lit ~0.97, in shadow ~0.63)
Light.TERMS = { 0.58, 0.50, 0.16 }
Light.TAN_E = math.tan(Light.ELEVATION)

Light.RES = 4                -- mask texels per cell
Light.HSCALE = 8             -- mask value 1.0 = 8 world units
Light.NORMAL_PUSH = 0.3      -- sample the mask this far out along the face normal
Light.MAX_SHADOW_CELLS = 2   -- longest shadow, in cells along the ground
Light.SLOPE_BIAS = { 0.03, 0.15 } -- shader bias = a + b * (1 - n.y)
Light.TRIS_PER_YIELD = 8 -- teams/perf L1 (was 256: one slice could run 30-50 ms desktop JIT-off)

-- The geometry lists that cast shadows (all optional).
local CASTERS = { "shadowOpaque", "opaque", "cutoutUnder", "cutoutOver", "cutoutKeyed" }
Light.CASTERS = CASTERS

local function put(grid, k, y)
  local cur = grid[k]
  if cur == nil or y > cur then grid[k] = y end
end

-- Per texel: the lowest surface (floor) and the lowest distinct surface
-- more than GAP above it (a floating occluder's underside).
local GAP = 0.1
local function putSurf(lo1, lo2, k, y)
  local a = lo1[k]
  if a == nil then lo1[k] = y; return end
  if y < a - GAP then
    lo2[k] = math.min(lo2[k] or math.huge, a)
    lo1[k] = y
  elseif y <= a + GAP then
    if y < a then lo1[k] = y end
  elseif lo2[k] == nil or y < lo2[k] then
    lo2[k] = y
  end
end
local function putMin(t, k, y)
  local cur = t[k]
  if cur == nil or y < cur then t[k] = y end
end

-- Height per mask texel (W x H texels, texel (i, j) centred at
-- ((i + 0.5) / R, (j + 0.5) / R) in map cells). Returns top, W, H, bottom,
-- floor: top = highest occluder, floor = lowest surface, bottom = the
-- occluder's underside -- the floor when something stands on it from the
-- floor up (a wall, a post), else the lowest surface floating above the
-- floor (a sign board, an eave, a crown).
local function heightGrid(geom, w, h, yield, alpha)
  local R = Light.RES
  local W, H = w * R, h * R
  local grid = {}
  local lo1, lo2, vbot = {}, {}, {}
  local eps = 1e-3
  local count = 0
  local texels = 0 -- teams/perf L1
  local function texelYield(n) texels = texels + n; if yield and texels >= 2048 then texels = 0; yield() end end -- teams/perf L1
  for _, name in ipairs(CASTERS) do
    local list = geom[name]
    if type(list) == "table" then
      for i = 1, #list - 2, 3 do
        local a, b, c = list[i], list[i + 1], list[i + 2]
        local ax, ay, az = a[1], a[2], a[3]
        local bx, by, bz = b[1], b[2], b[3]
        local cx, cy, cz = c[1], c[2], c[3]
        local x0, x1 = math.min(ax, bx, cx), math.max(ax, bx, cx)
        local z0, z1 = math.min(az, bz, cz), math.max(az, bz, cz)
        -- signed doubled xz area: ~0 for (near-)vertical triangles
        local area = (bx - ax) * (cz - az) - (cx - ax) * (bz - az)
        local spanV = math.max(x1 - x0, z1 - z0)
        local vertical = math.abs(area) <= 0.02 * spanV * spanV + 1e-9
        -- R4: cutouts cast by their visible texels (opaque has no alpha)
        local capTop, capBot, hidden = nil, nil, false
        if alpha and name ~= "opaque" and name ~= "shadowOpaque" then
          local okA, r, rb = pcall(alpha, name, a, b, c, vertical)
          if okA then
            if r == false then hidden = true end
            if type(r) == "number" then capTop = r end
            if type(rb) == "number" then capBot = rb end
          end
        end
        if not hidden then
        local i0 = math.max(0, math.floor((x0 + eps) * R))
        local i1 = math.min(W - 1, math.floor((x1 - eps) * R))
        local j0 = math.max(0, math.floor((z0 + eps) * R))
        local j1 = math.min(H - 1, math.floor((z1 - eps) * R))
        if i1 < i0 and x1 - x0 < eps then i1 = i0 end
        if j1 < j0 and z1 - z0 < eps then j1 = j0 end
        if vertical then
          -- near-vertical: mark the footprint at the top (walls, cards)
          local top = math.max(ay, by, cy)
          if capTop and capTop < top then top = capTop end
          local bot = math.min(ay, by, cy)
          if capBot and capBot > bot then bot = math.min(capBot, top) end
          for j = j0, j1 do
            local row = j * W + 1
            for ii = i0, i1 do
              put(grid, row + ii, top)
              putMin(vbot, row + ii, bot)
            end
            texelYield(i1 - i0 + 1) -- teams/perf L1
          end
        else
          local inv = 1 / area
          local e = -0.02   -- conservative: include centres just outside edges
          for j = j0, j1 do
            local pz = (j + 0.5) / R
            local row = j * W + 1
            for ii = i0, i1 do
              local px = (ii + 0.5) / R
              local wa = ((bx - px) * (cz - pz) - (cx - px) * (bz - pz)) * inv
              local wb = ((cx - px) * (az - pz) - (ax - px) * (cz - pz)) * inv
              local wc = 1 - wa - wb
              if wa >= e and wb >= e and wc >= e then
                local y = wa * ay + wb * by + wc * cy
                put(grid, row + ii, y)
                putSurf(lo1, lo2, row + ii, y)
              end
            end
            texelYield(i1 - i0 + 1) -- teams/perf L1
          end
        end
        end -- not hidden
        count = count + 1
        if yield and count % Light.TRIS_PER_YIELD == 0 then yield() end
      end
    end
  end
  -- tree units as domes (optional contract: { x, z, y0, y1, r } in cells)
  local trees = geom.treeOccluders
  if type(trees) == "table" then
    for _, t in ipairs(trees) do
      local tx, tz = tonumber(t.x or t[1]), tonumber(t.z or t[2])
      local y0, y1 = tonumber(t.y0 or t[3]), tonumber(t.y1 or t[4])
      local r = tonumber(t.r or t[5])
      if tx and tz and y0 and y1 and r and r > 0 then
        local i0 = math.max(0, math.floor((tx - r) * R))
        local i1 = math.min(W - 1, math.floor((tx + r) * R))
        local j0 = math.max(0, math.floor((tz - r) * R))
        local j1 = math.min(H - 1, math.floor((tz + r) * R))
        for j = j0, j1 do
          local dz = (j + 0.5) / R - tz
          local row = j * W + 1
          for ii = i0, i1 do
            local dx = (ii + 0.5) / R - tx
            local q = 1 - (dx * dx + dz * dz) / (r * r)
            if q > 0 then
              put(grid, row + ii, y0 + (y1 - y0) * math.sqrt(q))
              putSurf(lo1, lo2, row + ii, y0)
            end
          end
          texelYield(i1 - i0 + 1) -- teams/perf L1
        end
      end
    end
  end
  -- bottom of the occluding material per texel
  local bottom = {}
  local nBottom = 0 -- teams/perf L1
  for k, top in pairs(grid) do
    local f, f2, vb = lo1[k], lo2[k], vbot[k]
    local b
    if vb and (f == nil or vb <= f + GAP) then
      b = f and math.min(f, vb) or vb          -- stands on the floor: solid
    else
      b = f2                                   -- floating above the floor
      if vb and (b == nil or vb < b) then b = vb end
      if b == nil then b = f or top end        -- only a floor here
    end
    bottom[k] = b
    nBottom = nBottom + 1; if yield and nBottom % 4096 == 0 then yield() end -- teams/perf L1
  end
  return grid, W, H, bottom, lo1
end
Light.heightGrid = heightGrid

-- Returns an ImageData (rgba8, value in R) sized (w*RES) x (h*RES), and the
-- highest occluder found (for stats), or nil when love.image is missing.
-- opts (optional): want(cx, cz) -> bool limits the texels computed (border
-- rings: only ring cells are ever sampled); yield() is called every
-- rowsPerYield texel rows and every TRIS_PER_YIELD raster triangles; the
-- caller decides whether it actually yields (Scene: frame deadline).
function Light.shadowMask(geom, w, h, opts)
  opts = opts or {}
  local want, yield, rowsPerYield = opts.want, opts.yield, opts.rowsPerYield or 4
  if not (love and love.image and love.image.newImageData) then return nil end
  local field = opts.field
  local grid, W, H, bottom, floor
  if field then W, H = field:getDimensions()
  else grid, W, H, bottom, floor = heightGrid(geom, w, h, yield, opts.alpha) end
  local function heights(k)
    if field then
      local t, b, f, valid = field:getPixel((k - 1) % W, math.floor((k - 1) / W))
      if valid > 0 then return t, b, f end
    else return grid[k], bottom[k], floor[k] end
  end
  local R = Light.RES
  local maxH = 0
  -- Lab 55 (opts.fieldOnly, Scene: buildSlice + moving sun): the R/G march
  -- below is never displayed for a sun record (Solar.pump re-marches it
  -- from the retained field before any draw binds it), so skip the march
  -- and return an all-zero mask (its B channel still takes the pools) plus
  -- the field. Only meaningful with opts.retain; never with opts.field.
  local fieldOnly = opts.fieldOnly and not field
  if not fieldOnly then
  for k = 1, W * H do
    local v = heights(k)
    if v and v > maxH then maxH = v end
    if yield and k % 16384 == 0 then yield() end -- teams/perf L1
  end
  end
  local stepT = 1 / R                          -- cells per step
  local direction = opts.direction
  local sx, sz = direction and direction.x or SX, direction and direction.z or SZ
  local drop = stepT * (direction and direction.tan or Light.TAN_E)
  local steps = math.min(math.ceil(Light.MAX_SHADOW_CELLS * R),
    math.ceil((maxH + 0.5) / math.max(drop, 0.00001)))
  if direction and not direction.cast then steps = 0 end
  local data = love.image.newImageData(W, H, "rgba8")
  if opts.ownData then opts.ownData(data) end
  local HS = Light.HSCALE
  local work = 0 -- Lab 59: march steps since the last checkpoint (a row of a big map can take 10 ms)
  for j = 0, fieldOnly and -1 or H - 1 do
    if yield and j > 0 and j % rowsPerYield == 0 then yield() end
    for i = 0, W - 1 do
     if not want or want(math.floor(i / R), math.floor(j / R)) then
      local px, pz = (i + 0.5) / R, (j + 0.5) / R
      local s = -1
      local k0 = j * W + i + 1
      local top0, _, floor0 = heights(k0)
      local recv = floor0 or top0 or -1
      local lo = math.huge
      for n = 1, steps do
        local t = n * stepT
        local qi = math.floor((px + sx * t) * R)
        local qj = math.floor((pz + sz * t) * R)
        if qi < 0 or qj < 0 or qi >= W or qj >= H then break end
        local kq = qj * W + qi + 1
        local hq, bq = heights(kq)
        if hq then
          local v = hq - n * drop
          if v > s then s = v end
          if v > recv + 0.02 then
            local bl = (bq or hq) - n * drop
            if bl < lo then lo = bl end
          end
        end
      end
      local e = s <= 0 and 0 or math.min(1, s / HS)
      -- G: occluder bottom + 1 (0 = no lower bound)
      local gch = lo == math.huge and 0 or math.max(0, math.min(1, (lo + 1) / HS))
      data:setPixel(i, j, e, gch, 0, 1)
      work = work + steps + 8
      if yield and work >= 8192 then work = 0; yield() end
     end
    end
  end
  if opts.retain and not field and W * H * 16 <= opts.retain then
    field = love.image.newImageData(W, H, "rgba32f")
    if opts.ownField then opts.ownField(field) end
    for j = 0, H - 1 do
      if yield and j % 2 == 0 then yield() end -- Lab 59: was every rowsPerYield rows
      for i = 0, W - 1 do
        local k = j * W + i + 1
        field:setPixel(i, j, grid[k] or -1, bottom[k] or grid[k] or -1,
          floor[k] or grid[k] or -1, grid[k] and 1 or 0)
      end
    end
  end
  return data, maxH, field
end

-- Indoor / cave contact darkening (tour review R4). Per mask texel p with a
-- surface height g = H(p): if a neighbour within CONTACT_RADIUS cells stands
-- more than CONTACT_STEP above g, store
--   s = g + 0.06 + 0.19 * (1 - d / CONTACT_RADIUS)   (nearest such neighbour)
-- which the shaders' ramp turns into up to ~30% darkening at the foot of the
-- wall, fading out ~0.3-0.5 cells away; every other surface texel stores
-- its own height g (lit), empty texels 0.
-- No sun direction is involved, so there are no cast edges to stair-step.
Light.CONTACT_RADIUS = 0.5
Light.CONTACT_STEP = 0.25
function Light.contactMask(geom, w, h, opts)
  opts = opts or {}
  local yield, rowsPerYield = opts.yield, opts.rowsPerYield or 4
  if not (love and love.image and love.image.newImageData) then return nil end
  local grid, W, H = heightGrid(geom, w, h, yield, opts.alpha)
  local R = Light.RES
  local rad = Light.CONTACT_RADIUS
  local reach = math.floor(rad * R)
  local offs = {}
  for dj = -reach, reach do
    for di = -reach, reach do
      local d = math.sqrt(di * di + dj * dj) / R
      if (di ~= 0 or dj ~= 0) and d < rad then offs[#offs + 1] = { di, dj, 1 - d / rad } end
    end
  end
  local data = love.image.newImageData(W, H, "rgba8")
  local HS, step = Light.HSCALE, Light.CONTACT_STEP
  local maxH = 0
  for j = 0, H - 1 do
    if yield and j > 0 and j % 2 == 0 then yield() end -- Lab 59: was every rowsPerYield rows
    local row = j * W
    for i = 0, W - 1 do
      local g = grid[row + i + 1]
      if g then
        if g > maxH then maxH = g end
        local k = 0
        for n = 1, #offs do
          local o = offs[n]
          local qi, qj = i + o[1], j + o[2]
          if qi >= 0 and qj >= 0 and qi < W and qj < H then
            local hq = grid[qj * W + qi + 1]
            if hq and hq - g > step and o[3] > k then k = o[3] end
          end
        end
        -- a texel without contact stores its own surface height (lit): the
        -- linear filter then fades the darkening out smoothly instead of
        -- collapsing it into a hairline between g + x and 0
        local sv = k > 0 and (g + 0.06 + 0.19 * k) or g
        local e = math.max(0, math.min(1, sv / HS))
        data:setPixel(i, j, e, 0, 0, 1)
      end
    end
  end
  return data, maxH
end

-- Shadow height at a map-local point from a mask ImageData (bilinear, like
-- the GPU's linear filter). For CPU uses: blob alpha, tests. The texel
-- density comes from the mask itself (W / w).
-- Lab 58 (#2, switch actormemo): the same arithmetic without the two closures `at` and `bl` (and their upvalue
-- tables) that the Lab 57 body builds on every call. The state the helpers need rides in module locals; sampleMask
-- is not re-entrant (nothing it calls calls it back).
local okSpeed, Speed58 = pcall(V.require, "perf/Speed58")
local mData, mW, mH, mAx, mAz = nil, 0, 0, 0, 0
local function maskAt(i, j)
  local W, H = mW, mH
  i = math.max(0, math.min(W - 1, i))
  j = math.max(0, math.min(H - 1, j))
  local r, g = mData:getPixel(i, j)
  return (r or 0) * Light.HSCALE, (g or 0) * Light.HSCALE
end
local function maskBl(a, b, c, d)
  return (a * (1 - mAx) + b * mAx) * (1 - mAz) + (c * (1 - mAx) + d * mAx) * mAz
end
local function sampleMaskHoisted(data, w, h, x, z)
  local W, H = w * Light.RES, h * Light.RES
  if data.getDimensions then
    local ok, dw, dh = pcall(data.getDimensions, data)
    if ok and dw and dh then W, H = dw, dh end
  end
  local R = W / w
  local fx, fz = x * R - 0.5, z * R - 0.5
  local i0, j0 = math.floor(fx), math.floor(fz)
  mData, mW, mH, mAx, mAz = data, W, H, fx - i0, fz - j0
  local r00, g00 = maskAt(i0, j0)
  local r10, g10 = maskAt(i0 + 1, j0)
  local r01, g01 = maskAt(i0, j0 + 1)
  local r11, g11 = maskAt(i0 + 1, j0 + 1)
  mData = nil
  return maskBl(r00, r10, r01, r11), maskBl(g00, g10, g01, g11) - 1
end

function Light.sampleMask(data, w, h, x, z)
  if not data then return 0 end
  if okSpeed and Speed58.on("actormemo") then return sampleMaskHoisted(data, w, h, x, z) end
  local W, H = w * Light.RES, h * Light.RES
  if data.getDimensions then
    local ok, dw, dh = pcall(data.getDimensions, data)
    if ok and dw and dh then W, H = dw, dh end
  end
  local R = W / w
  local fx, fz = x * R - 0.5, z * R - 0.5
  local i0, j0 = math.floor(fx), math.floor(fz)
  local ax, az = fx - i0, fz - j0
  local function at(i, j)
    i = math.max(0, math.min(W - 1, i))
    j = math.max(0, math.min(H - 1, j))
    local r, g = data:getPixel(i, j)
    return (r or 0) * Light.HSCALE, (g or 0) * Light.HSCALE
  end
  local r00, g00 = at(i0, j0)
  local r10, g10 = at(i0 + 1, j0)
  local r01, g01 = at(i0, j0 + 1)
  local r11, g11 = at(i0 + 1, j0 + 1)
  local function bl(a, b, c, d)
    return (a * (1 - ax) + b * ax) * (1 - az) + (c * (1 - ax) + d * ax) * az
  end
  -- top (R), and the occluder bottom (G - 1; -1 = no lower bound)
  return bl(r00, r10, r01, r11), bl(g00, g10, g01, g11) - 1
end

local function smooth(a, b, x)
  local t = math.max(0, math.min(1, (x - a) / (b - a)))
  return t * t * (3 - 2 * t)
end

-- Same ramp as the shaders: 1 = sunlit, 0 = fully shadowed. `lo` (optional)
-- is the occluder bottom: a point below it is lit (the light passes under).
function Light.litFrom(s, y, bias, lo)
  local above = smooth(0.03, 0.22, s - y - (bias or Light.SLOPE_BIAS[1]))
  local below = lo and (1 - smooth(-0.02, 0.10, lo - y)) or 1
  return 1 - above * below
end

-- Soft round blob (white, alpha falloff) for character drop shadows.
local blobImage
function Light.blob()
  if blobImage then return blobImage end
  if not (love and love.image and love.graphics) then return nil end
  local n = 32
  local data = love.image.newImageData(n, n, "rgba8")
  for y = 0, n - 1 do
    for x = 0, n - 1 do
      local dx, dy = (x + 0.5) / n * 2 - 1, (y + 0.5) / n * 2 - 1
      local r = math.sqrt(dx * dx + dy * dy)
      local a = math.max(0, 1 - r)
      a = a * a * (3 - 2 * a)
      data:setPixel(x, y, 0, 0, 0, a * 0.55)
    end
  end
  local ok, img = pcall(love.graphics.newImage, data)
  if ok and img then
    img:setFilter("linear", "linear")
    blobImage = img
  end
  return blobImage
end

return Light

