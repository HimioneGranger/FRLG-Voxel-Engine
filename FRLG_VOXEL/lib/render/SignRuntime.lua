-- FireRed sign lettering: map-build-only GPU textures, per-record sign faces and a
-- zero-allocation draw. No GPU object is created and no text is looked up in draw.
--
-- v2 (signs57 follow-up): native art is upscaled with an edge-directed pixel-art filter (EPX, three passes: 16 -> 128
-- pixels, then x2 nearest into the 256 canvas) so diagonals and corners read smooth without any blur; baked shadow
-- pixels are transparent; gyms get a bold GYM and a crest texture; mailboxes are drawn procedurally for a 3D body.
--
-- Lifecycle
--   prepare(input, yield, owner)   map build, BEFORE the mesher: one 256x256 canvas per
--                                  readable sign (shared through a content cache), sets
--                                  input.signLabelsReady[key] only for a canvas that exists
--   upload(state, faces, format)   after the mesher: one static quad per face the mesher
--                                  actually emitted; a prepared texture without a face is
--                                  released at once
--   draw(scene, ...)               per eye, per visible record
--   release(state)                 record eviction, build error or cancellation (idempotent)
--   shutdown()                     Scene:release(): drops unreferenced textures and the fonts
-- Textures are shared by content (style, palette, wording), reference counted and kept in a
-- small idle list so a map that is rebuilt after eviction does not paint its signs again.
local V = ...
local Font = V.require('render/SignPixelFont')
local Profiles = V.require('data/SignProfiles')
local Mip = V.require('render/Mip')
local M = { VERSION = 'firered-sign-runtime-6-rear-directions' }
M.IDLE_CAP = 12 -- unreferenced textures kept (256 x 256 rgba8 = 256 KiB each)

local styles = {
  ['fr-metal'] = { panel = { 1, 15, 4, 9 }, band = { 1, 15, 9, 12 }, bg = { 7, 4 }, ink = { 2, 5 } },
  ['fr-wood'] = { panel = { 3, 13, 5, 11 }, bg = { 3, 5 }, ink = { 1, 2 } },
  ['fr-gym'] = { panel = { 1, 14, 0, 3 }, band = { 1, 14, 8, 10 }, bg = { 1, 0 }, ink = { 3, 0 } },
  ['fr-mailbox'] = { inkColor = { 206 / 255, 82 / 255, 74 / 255, 1 } },
  ['fr-gym-crest'] = {},
}
M.styles = styles
M.style = Profiles.style
M.profiles = Profiles -- test seam

local unpack = unpack or table.unpack
local function release(o) if o and o.release then pcall(o.release, o) end end

-- ------------------------------------------------------------------ shared resources
local fonts = {}   -- integer scale -> image font, built on first use, dropped by shutdown()
local cache = {}   -- content key -> { texture, refs, used, key }
local clock = 0    -- LRU tick, advanced when a texture goes idle
local stats = { created = 0, hits = 0, released = 0, fonts = 0, failed = 0 }
M.stats = stats

local function fontAt(scale)
  local f = fonts[scale]
  if not f then f = Font.new(scale * 7); fonts[scale] = f; stats.fonts = stats.fonts + 1 end
  return f
end

local function trim()
  local idle, n = {}, 0
  for k, e in pairs(cache) do if e.refs <= 0 then n = n + 1; idle[n] = e end end
  if n <= M.IDLE_CAP then return end
  table.sort(idle, function(a, b) return a.used < b.used end)
  for i = 1, n - M.IDLE_CAP do
    local e = idle[i]
    e.dropped = true; release(e.texture); cache[e.key] = nil; stats.released = stats.released + 1
  end
end

local function unref(e)
  if not e or e.dropped then return end
  e.refs = e.refs - 1
  if e.refs <= 0 then clock = clock + 1; e.used = clock; trim() end
end

-- ------------------------------------------------------------------ pixel-art upscale
-- Native 16x16 tile (0xRRGGBB, -1 = transparent) -> shadow / key pixels transparent -> EPX x3 -> n = 128.
local function epx(src, n, yield)
  local m, out = 2 * n, {}
  for y = 0, n - 1 do
    for x = 0, n - 1 do
      local P = src[y * n + x + 1]
      local A = y > 0 and src[(y - 1) * n + x + 1] or P
      local D = y < n - 1 and src[(y + 1) * n + x + 1] or P
      local C = x > 0 and src[y * n + x] or P
      local B = x < n - 1 and src[y * n + x + 2] or P
      local p1, p2, p3, p4 = P, P, P, P
      if C == A and C ~= D and A ~= B then p1 = A end
      if A == B and A ~= C and B ~= D then p2 = B end
      if D == C and D ~= B and C ~= A then p3 = C end
      if B == D and B ~= A and D ~= C then p4 = D end
      local i = (2 * y) * m + 2 * x + 1
      out[i], out[i + 1], out[i + m], out[i + m + 1] = p1, p2, p3, p4
    end
    if yield and y % 32 == 31 then yield() end
  end
  return out
end

-- tile (array of 256 ints, -1 transparent) -> love Image at 128x128 (nearest); caller releases it
local function smoothImage(tile, yield)
  local cur, n = tile, 16
  for _ = 1, 3 do cur = epx(cur, n, yield); n = n * 2 end
  local strs, c4 = {}, {}
  for i = 1, n * n do
    local v = cur[i]
    local s = c4[v]
    if not s then
      if v < 0 then s = string.char(0, 0, 0, 0)
      else s = string.char(math.floor(v / 65536) % 256, math.floor(v / 256) % 256, v % 256, 255) end
      c4[v] = s
    end
    strs[i] = s
  end
  local data = love.image.newImageData(n, n, 'rgba8', table.concat(strs))
  local img = love.graphics.newImage(data)
  img:setFilter('nearest', 'nearest')
  release(data)
  return img
end

local function isKeyInt(v)
  return Mip.isKey and Mip.isKey(math.floor(v / 65536) % 256 / 255, math.floor(v / 256) % 256 / 255, v % 256 / 255)
end

-- the art of a tile with baked shadow (family rule) and, optionally, the colour-key ground removed
local function artTile(p, style, transparentKey, flat)
  local t = {}
  for y = 0, 15 do
    for x = 0, 15 do
      local v = p[y * 16 + x + 1]
      if type(v) ~= 'number' then error('missing native sign palette') end
      if v >= 0 and (Profiles.shadow(style, x, y) or (transparentKey and isKeyInt(v))) then v = -1 end
      if flat and v >= 0 then v = flat end -- silhouette only (the plain back of the crest)
      t[y * 16 + x + 1] = v
    end
  end
  return t
end
M.artTile = artTile -- test seam

-- ------------------------------------------------------------------ rendering
local function color(p, x, y)
  local n = p[y * 16 + x + 1]
  if type(n) ~= 'number' or n < 0 then error('missing native sign palette') end
  return { math.floor(n / 65536) % 256 / 255, math.floor(n / 256) % 256 / 255, n % 256 / 255, 1 }
end

local function wrap(font, s, w)
  local out, line = {}, ''
  for word in s:gmatch('%S+') do
    if font:getWidth(word) > w then return nil end
    local test = line == '' and word or line .. ' ' .. word
    if font:getWidth(test) > w then out[#out + 1] = line; line = word else line = test end
  end
  if line ~= '' then out[#out + 1] = line end
  return #out > 0 and out or nil
end

local function fit(text, w, h, maxScale)
  for scale = maxScale or 3, 1, -1 do
    local font = fontAt(scale)
    local lines = wrap(font, text, w)
    if lines and #lines * (font:getHeight() + 4) - 4 <= h then return font, lines end
  end
end

local arrowPixels = {
  north = { '00100', '01110', '11111', '00100', '00100', '00100', '00100' },
  south = { '00100', '00100', '00100', '00100', '11111', '01110', '00100' },
  west = { '00100', '01100', '11111', '11111', '11111', '01100', '00100' },
  east = { '00100', '00110', '11111', '11111', '11111', '00110', '00100' },
}
local function arrow(g, dir, x, y, scale)
  for row, s in ipairs(assert(arrowPixels[dir])) do
    for col = 1, 5 do
      if s:sub(col, col) == '1' then g.rectangle('fill', x + (col - 1) * scale, y + (row - 1) * scale, scale, scale) end
    end
  end
end

-- Runs fn(g) inside a pushed graphics state on a fresh canvas. -> canvas | nil, reason
local function withCanvas(fn)
  local g = love.graphics
  local canvas = g.newCanvas(256, 256, { format = 'rgba8', dpiscale = 1, msaa = 0 })
  canvas:setFilter('nearest', 'nearest'); canvas:setWrap('clamp', 'clamp')
  local pushed = false
  local ok, err = pcall(function()
    g.push('all'); pushed = true
    g.setCanvas(canvas); g.origin(); g.setShader(); g.setScissor(); g.setStencilTest()
    g.setColorMask(true, true, true, true); g.setDepthMode('always', false); g.setMeshCullMode('none')
    g.setBlendMode('alpha', 'alphamultiply'); g.clear(0, 0, 0, 0)
    fn(g)
  end)
  if pushed then
    local restored = pcall(g.pop)
    if not restored then ok = false; err = 'graphics state restore failed' end
  end
  if not ok then release(canvas); return nil, tostring(err) end
  return canvas
end

-- The CPU upscale yields (build slices); it runs BEFORE any canvas exists or any graphics state is pushed, so a build
-- cancelled during it leaves nothing on the GPU and no state pushed.
local function smoothTile(p, style, transparentKey, yield, flat)
  return smoothImage(artTile(p, style, transparentKey, flat), yield)
end
local function drawTile(g, img, rear)
  g.setColor(1, 1, 1, 1)
  g.draw(img, rear and 256 or 0, 0, 0, rear and -2 or 2, 2)
end

-- Rear navigation directions turn 180 degrees with the reader. Reverse
-- every cardinal arrow while keeping lettering in reading order.
function M.rearArrow(dir) return ({north='south',south='north',east='west',west='east'})[dir] or dir end
local function mirrorRect(r) return {16-r[2],16-r[1],r[3],r[4]} end

-- Board families (metal, wood, gym). -> canvas | nil, reason
local function renderBoard(p, style, label, yield, rear)
  local spec = styles[style]
  local gymOnly = style == 'fr-gym' and not label.title
  local bg = color(p, unpack(spec.bg))
  local ink = spec.inkColor or color(p, unpack(spec.ink))
  local panel, band = spec.panel, spec.band
  if rear then panel=mirrorRect(panel);if band then band=mirrorRect(band) end end
  local dirs = label.directions or {}
  local dirLines = {}
  for _, d in ipairs(dirs) do
    if not Font.supports(d.label) or not arrowPixels[d.arrow] then return nil, 'unsupported-direction' end
    dirLines[#dirLines + 1] = { text = d.label, arrow = rear and M.rearArrow(d.arrow) or d.arrow }
    if #dirs == 1 and d.nextTown then
      if not Font.supports(d.nextTown) then return nil, 'unsupported-direction' end
      dirLines[#dirLines + 1] = { text = d.nextTown }
    end
  end
  -- Wooden boards have one native writing area. Partition only that area.
  if not band and #dirLines > 0 then
    local middle = (panel[3] + panel[4]) / 2
    band = { panel[1], panel[2], middle, panel[4] }
    panel = { panel[1], panel[2], panel[3], middle }
  end
  local titleFont, titleLines
  if not gymOnly then
    local maxTitleScale = (style == 'fr-metal' or style == 'fr-wood') and 3 or 2
    titleFont, titleLines = fit(label.title, (panel[2] - panel[1]) * 16 - 8, (panel[4] - panel[3]) * 16 - 6, maxTitleScale)
    if not titleFont then return nil, 'title-does-not-fit' end
  end
  local dirFont
  if #dirLines > 0 then
    if not band then return nil, 'no-direction-area' end
    for scale = 2, 1, -1 do
      local f = fontAt(scale)
      local fits = #dirLines * (f:getHeight() + 4) - 4 <= (band[4] - band[3]) * 16 - 6
      for _, d in ipairs(dirLines) do
        if f:getWidth(d.text) + (d.arrow and scale * 7 or 0) > (band[2] - band[1]) * 16 - 8 then fits = false end
      end
      if fits then dirFont = f; break end
    end
    if not dirFont then return nil, 'directions-do-not-fit' end
  end
  local art = smoothTile(p, style, style ~= 'fr-metal', yield)
  local canvas, why = withCanvas(function(g)
    -- native art at eight times the native resolution, shadow and ground transparent
    -- The rear replaces a solid native reading rectangle. Retain that native
    -- body under the filtered edge pixels so the closed board stays closed.
    if rear then g.setColor(unpack(bg));g.rectangle('fill',0,0,256,256) end
    drawTile(g, art, rear)
    local function fill(r, c) g.setColor(unpack(c)); g.rectangle('fill', r[1] * 16, r[3] * 16, (r[2] - r[1]) * 16, (r[4] - r[3]) * 16) end
    if titleFont then
      fill(panel, bg); g.setColor(unpack(ink)); g.setFont(titleFont)
      local y = math.floor((panel[3] + panel[4]) * 8 - (#titleLines * (titleFont:getHeight() + 4) - 4) / 2)
      for _, s in ipairs(titleLines) do
        g.print(s, math.floor((panel[1] + panel[2]) * 8 - titleFont:getWidth(s) / 2), y)
        y = y + titleFont:getHeight() + 4
      end
    end
    if band and #dirLines > 0 then
      fill(band, bg); g.setColor(unpack(ink)); g.setFont(dirFont)
      local y = math.floor((band[3] + band[4]) * 8 - (#dirLines * (dirFont:getHeight() + 4) - 4) / 2)
      for _, d in ipairs(dirLines) do
        local arrowScale = math.min(2, math.max(1, math.floor(dirFont:getHeight() / 7)))
        local prefix = d.arrow and arrowScale * 7 or 0
        local x = math.floor((band[1] + band[2]) * 8 - (dirFont:getWidth(d.text) + prefix) / 2)
        if d.arrow then arrow(g, d.arrow, x, y, arrowScale) end
        g.print(d.text, x + prefix, y); y = y + dirFont:getHeight() + 4
      end
    end
    if style == 'fr-gym' then
      -- The native GYM glyphs are 3 pixels tall and read as "OYH"; draw GYM bold in the same slate on the same face.
      local face, slate = color(p, 1, 3), color(p, 2, 4)
      g.setColor(unpack(face)); g.rectangle('fill', (rear and 3 or 2) * 16, 4 * 16, 11 * 16, 3 * 16)
      local f = fontAt(6)
      g.setColor(unpack(slate)); g.setFont(f)
      g.print('GYM', math.floor((rear and 136 or 120) - f:getWidth('GYM') / 2), math.floor(88 - f:getHeight() / 2))
    end
    if style == 'fr-metal' then
      -- Solid dark top rail (rows 0-1) over the native top return, then the native frame colour.
      local dark = color(p, 0, 6)
      fill({ 0, 16, 0, 2 }, dark)
      fill({ 1, 15, 2, 4 }, color(p, 3, 1)); fill({ 1, 15, 2, 2.25 }, dark); fill({ 6.5, 9.5, 2.75, 3.25 }, ink)
    end
  end)
  release(art)
  return canvas, why
end

-- Gym crest (OVER layer, the dome): alpha kept.
local function renderCrest(p, yield, flat)
  local art = smoothTile(p, 'fr-gym-crest', false, yield, flat)
  local canvas, why = withCanvas(function(g) drawTile(g, art) end)
  release(art)
  return canvas, why
end

-- Mailbox front face: arched silhouette (the mesher emits the same profile), body colour, outline, mail slot, name panel.
local function renderMailbox(p, label)
  local spec = styles['fr-mailbox']
  local MB = Profiles.MAILBOX
  local W = 256
  local sc = W / MB.W
  local rise = MB.RISE * sc
  local H = MB.CANVAS_H
  local R = (W * W / 4 + rise * rise) / (2 * rise)
  local bodyc, outline, hi, shade = color(p, 5, 7), color(p, 2, 3), color(p, 6, 0), color(p, 4, 2)
  local panelBg = color(p, 6, 6)
  local ink = spec.inkColor
  local ax, ay, aw, ah = 28, 112, 200, 82 -- lettering area: below the slot, inside the body
  local font, lines = fit(label.title, aw - 8, ah - 6, 3)
  if not font then return nil, 'title-does-not-fit' end
  return withCanvas(function(g)
    local function profile(inset)
      local pts = { inset, H - inset, W - inset, H - inset }
      local r, half = R - inset, W / 2 - inset
      local th0 = math.asin(half / r)
      local N = 16
      for i = 0, N do
        local th = th0 - 2 * th0 * i / N
        pts[#pts + 1] = W / 2 + r * math.sin(th); pts[#pts + 1] = R - r * math.cos(th)
      end
      return pts
    end
    g.setColor(unpack(outline)); g.polygon('fill', profile(0))
    g.setColor(unpack(bodyc)); g.polygon('fill', profile(10))
    g.setColor(unpack(hi)); g.polygon('fill', profile(22))
    g.setColor(unpack(bodyc)); g.polygon('fill', profile(30))
    -- mail slot: dark bar with a light lip, on the front face near the top of the straight part
    g.setColor(unpack(outline)); g.rectangle('fill', 52, 84, 152, 14)
    g.setColor(unpack(shade)); g.rectangle('fill', 52, 98, 152, 4)
    g.setColor(unpack(shade)); g.rectangle('fill', ax - 4, ay - 4, aw + 8, ah + 8)
    g.setColor(unpack(panelBg)); g.rectangle('fill', ax, ay, aw, ah)
    g.setColor(unpack(ink)); g.setFont(font)
    local y = math.floor(ay + ah / 2 - (#lines * (font:getHeight() + 4) - 4) / 2)
    for _, s in ipairs(lines) do
      g.print(s, math.floor(ax + aw / 2 - font:getWidth(s) / 2), y)
      y = y + font:getHeight() + 4
    end
  end)
end

-- Cache key: everything the picture depends on, so a stale texture can never be reused.
local function contentKey(style, p, label)
  local pal = {}
  for i = 1, 256 do pal[i] = p[i] or -1 end
  local dirs = {}
  for _, d in ipairs(label.directions or {}) do dirs[#dirs + 1] = d.arrow .. ':' .. d.label .. ':' .. tostring(d.nextTown) end
  return table.concat({ style, table.concat(pal, ','), tostring(label.title), table.concat(dirs, ';'), label.rear and 'rear' or 'front' }, '|')
end

local function acquire(state, key, style, p, label, renderFn)
  local okK, ckey = pcall(contentKey, style, p, label)
  if not okK then return nil, 'palette-key-failed' end
  local e = cache[ckey]
  if e then
    e.refs = e.refs + 1; stats.hits = stats.hits + 1
  else
    local okR, texture, why = pcall(renderFn)
    if okR and texture then
      e = { texture = texture, refs = 1, used = clock, key = ckey }
      cache[ckey] = e; stats.created = stats.created + 1
    else
      stats.failed = stats.failed + 1
      return nil, okR and why or tostring(texture)
    end
  end
  state.entries[key] = { e = e, style = style }
  return true
end

-- ------------------------------------------------------------------ build
function M.prepare(input, yieldPoint, owner)
  input.signLabelsReady = {}
  if not input.signLabels or not (love and love.graphics) then return nil end
  local state = { entries = {}, meshes = {}, tris = 0, report = {} }
  if owner then owner.signRuntime = state end
  local keys = {}
  for key in pairs(input.signLabels) do keys[#keys + 1] = key end
  table.sort(keys)
  for _, key in ipairs(keys) do
    local label = input.signLabels[key]
    local xs, ys = key:match('^(%d+),(%d+)$')
    local x, y = tonumber(xs), tonumber(ys)
    local cell = x and input.cellAt(x, y)
    local style = cell and M.style(input, cell.mid)
    local reason = label.reason or 'unsupported-native-type'
    -- a gym with no usable wording still gets the bold GYM (the wording is not needed for it)
    local usable = label.title and Font.supports(label.title)
    if style == 'fr-gym' and not usable then label = { gymOnly = true, reason = label.reason }; usable = true end
    if style and usable then
      local ok, p = pcall(input.atlas.signTexels or input.atlas.texels, cell.mid, 'under')
      if ok and p then
        local rf
        if style == 'fr-mailbox' then rf = function() return renderMailbox(p, label) end
        else rf = function() return renderBoard(p, style, label, yieldPoint) end end
        local okA, why = acquire(state, key, style, p, label, rf)
        if okA and style~='fr-mailbox' then
          local rear={};for k,v in pairs(label)do rear[k]=v end;rear.rear=true
          local okB, whyB=acquire(state,key..'#back',style,p,rear,
            function() return renderBoard(p,style,rear,yieldPoint,true) end)
          if okB then input.signLabelsReady[key..'#back']=true
          else
            -- Either both readable faces exist or the native board is kept.
            unref(state.entries[key].e);state.entries[key]=nil;okA=false;why=whyB
          end
        end
        if okA then
          input.signLabelsReady[key] = true; reason = 'ready'
          if style == 'fr-gym' then
            local north = input.cellAt(x, y - 1)
            local po = north and input.atlas.signOverTexels and input.atlas.signOverTexels(north.mid)
            if po then
              local okC = acquire(state, key .. '#crest', 'fr-gym-crest', po, { title = 'crest' }, function() return renderCrest(po, yieldPoint) end)
              if okC then
                input.signLabelsReady[key .. '#crest'] = true
                -- the plain back of the dome: same silhouette, one flat native colour (tile pixel 1,0), no art
                local flat = p[2]
                local okB = type(flat) == 'number' and flat >= 0 and acquire(state, key .. '#crestback', 'fr-gym-crest', po, { title = 'crestback' .. flat },
                  function() return renderCrest(po, yieldPoint, flat) end)
                if okB then input.signLabelsReady[key .. '#crestback'] = true end
              end
            end
          end
        else
          reason = why
        end
      else
        reason = 'missing-native-texels'
      end
    elseif label.title and not Font.supports(label.title) then
      reason = 'unsupported-glyph'
    end
    state.report[key] = reason
    if yieldPoint then yieldPoint() end
  end
  return state
end

-- faces: the mesher's signFaces. Rect faces carry x0..x1,y0..y1,z,u0..v1; triangle faces carry verts =
-- { {x,y,z,u,v,nx,ny,nz}, ... } (a triangle list); a part ("crest") selects the entry key..'#'..part.
-- -> true | nil, reason. A prepared sign without a face is released.
function M.upload(state, faces, format)
  if not state then return not faces or #faces == 0, 'unprepared sign faces' end
  local used = {}
  for _, d in ipairs(faces or {}) do
    local key = d.x .. ',' .. d.y .. (d.part and ('#' .. d.part) or '')
    local en = state.entries[key]
    if not en then return nil, 'sign face missing prepared texture' end
    used[key] = true
    local verts, x0, x1, y0, y1, z0, z1
    if d.verts then
      verts = d.verts
      x0, x1, y0, y1, z0, z1 = math.huge, -math.huge, math.huge, -math.huge, math.huge, -math.huge
      for _, v in ipairs(verts) do
        if v[1] < x0 then x0 = v[1] end
        if v[1] > x1 then x1 = v[1] end
        if v[2] < y0 then y0 = v[2] end
        if v[2] > y1 then y1 = v[2] end
        if v[3] < z0 then z0 = v[3] end
        if v[3] > z1 then z1 = v[3] end
      end
    else
      local l, r, b, t, z = d.x0, d.x1, d.y0, d.y1, d.z
      local u0, v0, u1, v1 = d.u0 or 0, d.v0 or 0, d.u1 or 1, d.v1 or 1
      local rear=d.normal and d.normal[3]<0
      local left,right,nz=rear and r or l,rear and l or r,rear and -1 or 1
      verts = {
        { left, t, z, u0, v0, 0, 0, nz }, { left, b, z, u0, v1, 0, 0, nz }, { right, b, z, u1, v1, 0, 0, nz },
        { left, t, z, u0, v0, 0, 0, nz }, { right, b, z, u1, v1, 0, 0, nz }, { right, t, z, u1, v0, 0, 0, nz },
      }
      x0, x1, y0, y1, z0, z1 = l, r, b, t, z, z
    end
    local ok, mesh = pcall(love.graphics.newMesh, format, verts, 'triangles', 'static')
    if not ok or not mesh then return nil, 'sign mesh upload failed: ' .. tostring(mesh) end
    local n = #verts / 3
    state.meshes[#state.meshes + 1] = { mesh = mesh, e = en.e, x0 = x0, x1 = x1, y0 = y0, y1 = y1, z0 = z0, z1 = z1 , tris = n }
    local bound, err = pcall(mesh.setTexture, mesh, en.e.texture)
    if not bound then return nil, tostring(err) end
    state.tris = state.tris + n
  end
  for key, en in pairs(state.entries) do
    if not used[key] then unref(en.e); state.entries[key] = nil; state.report[key] = 'no-native-face' end
  end
  return true
end

-- ------------------------------------------------------------------ draw
-- bind(scene, shader, rec, env) sends u_mvp and the map's shadow state (Scene owns both).
-- No table, closure or string is created here.
function M.draw(scene, shader, S, env, planes, boxVisible, counters, bind)
  local visible = scene.visible
  if not visible then return end
  local far2 = env.far * env.far
  local stateSet = false -- emissive/ao/texSize are per-call constants here (every sign canvas is 256 x 256, no AO, no glow)
  for i = 1, #visible do
    local rec = visible[i]
    local state = rec.signRuntime
    local meshes = state and state.meshes
    if meshes and #meshes > 0 then
      local sent = false
      local ox, oz = rec.ox or 0, rec.oz or 0
      for j = 1, #meshes do
        local ch = meshes[j]
        local x0, x1, z0, z1 = ch.x0 + ox, ch.x1 + ox, ch.z0 + oz, ch.z1 + oz
        local dx = math.max(x0 - env.camX, 0, env.camX - x1)
        local dz = math.max(z0 - env.camZ, 0, env.camZ - z1)
        if dx * dx + dz * dz <= far2 and boxVisible(planes, x0, ch.y0, z0, x1, ch.y1, z1) then
          if not sent then
            bind(scene, shader, rec, env)
            if not stateSet then
              S.emissive(shader, nil); S.ao(shader, false); S.texSize(shader, ch.e.texture)
              stateSet = true
            end
            sent = true
          end
          love.graphics.draw(ch.mesh)
          counters.calls = counters.calls + 1
          counters.tris = counters.tris + ch.tris
        end
      end
    end
  end
end

function M.release(state)
  if not state or state.released then return end
  state.released = true
  for _, ch in ipairs(state.meshes) do release(ch.mesh) end
  state.meshes = {}
  for _, en in pairs(state.entries) do unref(en.e) end
  state.entries = {}
end

-- Scene:release(): nothing may be left on the GPU once the renderer is gone.
function M.shutdown()
  for k, e in pairs(cache) do
    if e.refs <= 0 then e.dropped = true; release(e.texture); cache[k] = nil; stats.released = stats.released + 1 end
  end
  for scale, f in pairs(fonts) do release(f); fonts[scale] = nil end
end

function M.status()
  local n, refs = 0, 0
  for _, e in pairs(cache) do n = n + 1; refs = refs + e.refs end
  return { textures = n, refs = refs, created = stats.created, hits = stats.hits, released = stats.released,
    failed = stats.failed, fonts = stats.fonts }
end

return M
