-- FRLG_VOXEL / interiors-team: Kit.lua -- geometry primitives and the room
-- palette for the feature modules (Doors, Ceiling) and the section props.
-- Owner: the core worker (build/core/API.md section "Kit"). Additions by
-- request; existing signatures are frozen.
--
-- Every emitter takes the interiors context `ctx` (FrlgInteriors) and a
-- target `list`: a shell group's list (ctx:group(kind, spec).list) or a
-- base-list buffer (ctx:buffer("opaque" | "keyed" | "over" | "under")).
-- Vertices are the mesher's 8-field { x, y, z, u, v, nx, ny, nz } made by
-- ctx:newVfn() (they update geom.bounds). UV rects are { u0, v0, u1, v1 }
-- in the UNDER atlas (v0 = the tile's top row) unless the target is the
-- over / keyed list. No state; no debug / package / io.
local V = ...
local _ = V
local Kit = { VERSION = "kit 1.0 (2026-09-29)" }

local mfloor, mabs, msqrt, mcos, msin, mpi = math.floor, math.abs, math.sqrt, math.cos, math.sin, math.pi

-- ---------------------------------------------------------------- palette
local function luma(c)
  local r, g, b = mfloor(c / 65536) % 256, mfloor(c / 256) % 256, c % 256
  return 0.299 * r + 0.587 * g + 0.114 * b
end
Kit.luma = luma

-- a mip-safe single-texel UV rect of colour `rgb`: the centre of a 3x3
-- block of that colour in one of `mids` (default: the room's wallpaper,
-- floor and rim tiles) -> rect | nil
function Kit.colourUv(ctx, rgb, mids)
  ctx._kitC = ctx._kitC or {}
  local e = ctx._kitC[rgb]
  if e ~= nil and mids == nil then return e or nil end
  e = false
  local env = ctx.env
  local list = mids
  if not list then
    local P = ctx.wp or {}
    list = { P.lo, P.up, ctx.floorMid, env.IN and env.IN.wallLower, env.IN and env.IN.wallUpper }
  end
  for _, m in ipairs(list) do
    local u = m and ctx:tex(m)
    local r = u and env.underRect(m)
    if u and r then
      for row = 1, 14 do
        for col = 1, 14 do
          -- Most pixels fail the first row. Preserve row-major selection
          -- while avoiding eight further reads and two loops per mismatch.
          local p = (row - 1) * 16 + col
          local ok = u[p] == rgb and u[p+1] == rgb and u[p+2] == rgb
            and u[p+16] == rgb and u[p+17] == rgb and u[p+18] == rgb
            and u[p+32] == rgb and u[p+33] == rgb and u[p+34] == rgb
          if ok then
            local f0, f1 = (col + 0.5) / 16, (row + 0.5) / 16
            e = env.subRect(r, f0, f1, f0, f1)
            e.rgb = rgb
            break
          end
        end
        if e then break end
      end
    end
    if e then break end
  end
  if mids == nil then ctx._kitC[rgb] = e end
  return e or nil
end

-- the room palette from its own under art (DESIGN 1.4): each entry is a
-- single-texel UV rect (with .rgb) or nil
--   main  : the lower wallpaper tile's most common colour
--   trim  : the lower tile's bottom two rows' most common colour (skirting)
--   rim   : the mesher's rim colour (IN.rimUv) when it is under art
--   light : the lightest colour holding >= 3% of the wallpaper texels
--   dark  : the darkest such colour, else the void colour patch (darkUv)
function Kit.palette(ctx)
  if ctx._kitPal then return ctx._kitPal end
  local P = ctx.wp or {}
  local pal = {}
  local lo, up = P.lo and ctx:tex(P.lo), P.up and ctx:tex(P.up)
  if lo then
    local cnt, trimC = {}, {}
    local n = 0
    for _, t in ipairs({ lo, up or lo }) do
      for i = 1, 256 do cnt[t[i]] = (cnt[t[i]] or 0) + 1; n = n + 1 end
    end
    for i = 225, 256 do trimC[lo[i]] = (trimC[lo[i]] or 0) + 1 end
    local function modal(c, exclude)
      local best, bn = nil, -1
      for k, v in pairs(c) do if k ~= exclude and (v > bn or (v == bn and k < best)) then best, bn = k, v end end
      return best
    end
    local mainC = modal((function() local c = {}; for i = 1, 256 do c[lo[i]] = (c[lo[i]] or 0) + 1 end; return c end)())
    pal.main = mainC and Kit.colourUv(ctx, mainC)
    local tc = modal(trimC)
    pal.trim = tc and Kit.colourUv(ctx, tc)
    local lightC, darkC, lL, dL = nil, nil, -1, 1e9
    for k, v in pairs(cnt) do
      if v >= 0.03 * n then
        local l = luma(k)
        if l > lL then lightC, lL = k, l end
        if l < dL then darkC, dL = k, l end
      end
    end
    pal.light = lightC and Kit.colourUv(ctx, lightC)
    pal.dark = darkC and Kit.colourUv(ctx, darkC)
  end
  local IN = ctx.env.IN
  if IN and IN.rimUv and not IN.rimUv.over then pal.rim = IN.rimUv end
  pal.main = pal.main or ctx.L
  pal.trim = pal.trim or pal.main
  pal.rim = pal.rim or pal.light or pal.main
  pal.light = pal.light or pal.main
  pal.dark = pal.dark or ctx.darkUv
  ctx._kitPal = pal
  return pal
end

-- ---------------------------------------------------------------- emitters
-- a quad with corner UVs from rect r: a..d counter-clockwise seen from the
-- normal side, a = the rect's bottom-left (u0, v1)
function Kit.quad(ctx, list, a, b, c, d, r, n)
  ctx:quadV(list, a[1], a[2], a[3], r[1], r[4], b[1], b[2], b[3], r[3], r[4], c[1], c[2], c[3], r[3], r[2],
    d[1], d[2], d[3], r[1], r[2], n[1], n[2], n[3])
end

-- an axis-aligned box x0..x1 / z0..z1 / y0..y1 (no bottom face). uv.top
-- (rect over the top, north-west = u0 v0), uv.side (each side face: its
-- full rect, the tile's top at y1) or uv.n / uv.s / uv.w / uv.e per face.
-- opts.noTop, opts.skip = { n=true, ... }
function Kit.box(ctx, list, x0, z0, x1, z1, y0, y1, uv, opts)
  opts = opts or {}
  local skip = opts.skip or {}
  if uv.top and not opts.noTop then ctx:hquad(list, x0, z0, x1, z1, y1, uv.top) end
  local function side(k) return uv[k] or uv.side end
  local r
  r = side("s"); if r and not skip.s then ctx:vquad(list, x0, z1, x1, z1, y0, y1, r[1], r[3], r[2], r[4], 0, 0, 1) end
  r = side("n"); if r and not skip.n then ctx:vquad(list, x1, z0, x0, z0, y0, y1, r[1], r[3], r[2], r[4], 0, 0, -1) end
  r = side("w"); if r and not skip.w then ctx:vquad(list, x0, z0, x0, z1, y0, y1, r[1], r[3], r[2], r[4], -1, 0, 0) end
  r = side("e"); if r and not skip.e then ctx:vquad(list, x1, z1, x1, z0, y0, y1, r[1], r[3], r[2], r[4], 1, 0, 0) end
end

-- a vertical cylinder (segs sides, top cap), UV: side rect wrapped once
-- round, top rect planar
function Kit.cylinder(ctx, list, cx, cz, rad, y0, y1, segs, uvSide, uvTop)
  segs = segs or 12
  local newV = ctx:newVfn()
  for i = 0, segs - 1 do
    local a0, a1 = 2 * mpi * i / segs, 2 * mpi * (i + 1) / segs
    local c0, s0, c1, s1 = mcos(a0), msin(a0), mcos(a1), msin(a1)
    local am = (a0 + a1) * 0.5
    local nx, nz = mcos(am), msin(am)
    if uvSide then
      local u0 = uvSide[1] + (uvSide[3] - uvSide[1]) * i / segs
      local u1 = uvSide[1] + (uvSide[3] - uvSide[1]) * (i + 1) / segs
      -- outward face: from angle a1 to a0 reads left -> right from outside
      ctx:vquad(list, cx + c1 * rad, cz + s1 * rad, cx + c0 * rad, cz + s0 * rad, y0, y1, u0, u1, uvSide[2], uvSide[4], nx, 0, nz)
    end
    if uvTop then
      local function tv(c, s) return uvTop[1] + (uvTop[3] - uvTop[1]) * (0.5 + 0.5 * c), uvTop[2] + (uvTop[4] - uvTop[2]) * (0.5 + 0.5 * s) end
      local mu, mv = tv(0, 0)
      local au, av = tv(c0, s0)
      local bu, bv = tv(c1, s1)
      ctx:tri(list, newV(cx, y1, cz, mu, mv, 0, 1, 0), newV(cx + c1 * rad, y1, cz + s1 * rad, bu, bv, 0, 1, 0),
        newV(cx + c0 * rad, y1, cz + s0 * rad, au, av, 0, 1, 0))
    end
  end
end

-- two crossed upright cards (keyed / over art: pass that buffer), centred
-- on (cx, cz), w wide, y0..y1, normal UP like the mesher's plant cards
function Kit.card(ctx, list, cx, cz, w, y0, y1, uv, crossed)
  local hw = w * 0.5
  ctx:vquad(list, cx - hw, cz, cx + hw, cz, y0, y1, uv[1], uv[3], uv[2], uv[4], 0, 1, 0)
  if crossed ~= false then ctx:vquad(list, cx, cz - hw, cx, cz + hw, y0, y1, uv[1], uv[3], uv[2], uv[4], 0, 1, 0) end
end

-- a stair flight in the rectangle x0..x1 / z0..z1 rising from y0 to y1
-- toward `dir` ("up" = north, "down" = south, "left", "right"), `steps`
-- steps; tread / riser rects (stretched per step)
function Kit.stairs(ctx, list, x0, z0, x1, z1, y0, y1, steps, dir, uvTread, uvRiser)
  steps = math.max(1, steps or 4)
  local dh = (y1 - y0) / steps
  for i = 0, steps - 1 do
    local f0, f1 = i / steps, (i + 1) / steps
    local ya, yb = y0 + dh * i, y0 + dh * (i + 1)
    local a0, a1, b0, b1 -- the step's footprint
    if dir == "up" then a0, a1, b0, b1 = x0, x1, z1 - (z1 - z0) * f1, z1 - (z1 - z0) * f0
    elseif dir == "down" then a0, a1, b0, b1 = x0, x1, z0 + (z1 - z0) * f0, z0 + (z1 - z0) * f1
    elseif dir == "left" then a0, a1, b0, b1 = x1 - (x1 - x0) * f1, x1 - (x1 - x0) * f0, z0, z1
    else a0, a1, b0, b1 = x0 + (x1 - x0) * f0, x0 + (x1 - x0) * f1, z0, z1 end
    -- tread: the remaining run to the top at this step's height
    if uvTread then ctx:hquad(list, a0, b0, a1, b1, yb, uvTread) end
    if uvRiser then
      local r = uvRiser
      if dir == "up" then ctx:vquad(list, a0, b1, a1, b1, ya, yb, r[1], r[3], r[2], r[4], 0, 0, 1)
      elseif dir == "down" then ctx:vquad(list, a1, b0, a0, b0, ya, yb, r[1], r[3], r[2], r[4], 0, 0, -1)
      elseif dir == "left" then ctx:vquad(list, a1, b1, a1, b0, ya, yb, r[1], r[3], r[2], r[4], 1, 0, 0)
      else ctx:vquad(list, a0, b0, a0, b1, ya, yb, r[1], r[3], r[2], r[4], -1, 0, 0) end
    end
  end
end

-- a railing from a to b: a top rail (box t thick) at y0 + h and posts every
-- `postEvery` cells (boxes pw square)
function Kit.railing(ctx, list, ax, az, bx, bz, y0, h, uvRail, uvPost, opts)
  opts = opts or {}
  local t, pw, every = opts.t or 0.06, opts.pw or 0.08, opts.postEvery or 1
  local dx, dz = bx - ax, bz - az
  local len = msqrt(dx * dx + dz * dz)
  if len < 1e-6 then return end
  if mabs(dx) >= mabs(dz) then
    local xa, xb = math.min(ax, bx), math.max(ax, bx)
    Kit.box(ctx, list, xa, az - t * 0.5, xb, az + t * 0.5, y0 + h - t, y0 + h, { top = uvRail, side = uvRail })
  else
    local za, zb = math.min(az, bz), math.max(az, bz)
    Kit.box(ctx, list, ax - t * 0.5, za, ax + t * 0.5, zb, y0 + h - t, y0 + h, { top = uvRail, side = uvRail })
  end
  local n = math.max(1, mfloor(len / every + 0.5))
  for i = 0, n do
    local f = i / n
    local px, pz = ax + dx * f, az + dz * f
    Kit.box(ctx, list, px - pw * 0.5, pz - pw * 0.5, px + pw * 0.5, pz + pw * 0.5, y0, y0 + h - t,
      { top = uvPost, side = uvPost })
  end
end

return Kit
