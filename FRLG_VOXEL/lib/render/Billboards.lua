-- FRLG_VOXEL: overworld sprites as upright, camera-facing cards. Uses the
-- game's own OW sprite sheets and pose logic (OwSprites.getDraw / .pose,
-- src/core/game3/ow_sprites.lua), so palettes, walk frames, bows and custom
-- frames match the flat view. The facing frame is chosen RELATIVE to the
-- viewer: an NPC facing south shows its front to a viewer standing south of
-- it, its back to a viewer standing north, and a side frame from east/west.
--
-- Tour review (2026-09-28): R1 -- each sheet's art rows are measured once
-- (spr.imageData) so the feet stand on the ground instead of floating on the
-- frame's empty bottom rows; the first-person scale comes from that art
-- (Camera.CARD_SCALE.first). R5 -- in the 3/4 view (desktop and the Quest
-- diorama) every card faces one shared direction (env.cardDir: minus the
-- camera's forward, flattened) and facing frames come from it, so cards off
-- to the side no longer turn toward the eye point and twist.
local V = ...
local Mat4 = V.require("render/Mat4")
local Shaders = V.require("render/Shaders")
local Light = V.require("render/Light")
-- Lab 58 SPEED PATCHES (render/../perf/Speed58.lua): every item below is off unless the gate says VRITK is active,
-- which is exactly the Lab 57 path. `speedOn(name)` allocates nothing.
local okSpeed, Speed58 = pcall(V.require, "perf/Speed58")
local function speedOn(name)
  if not okSpeed or type(Speed58) ~= "table" then return false end
  return Speed58.on(name) == true
end
local mathsqrt = math.sqrt

local Billboards = {}
Billboards.__index = Billboards

local CELL = 16
local FACING_VEC = { up = { 0, -1 }, down = { 0, 1 }, left = { -1, 0 }, right = { 1, 0 } }

Billboards.MAX_BLOBS = 48

-- Blob vertices carry a colour so each blob can fade with the light it
-- stands in (review R5): alpha = 0.35 + 0.65 * lit.
Billboards.BLOB_FORMAT = {
  { "VertexPosition", "float", 3 },
  { "VertexTexCoord", "float", 2 },
  { "VertexNormal", "float", 3 },
  { "VertexColor", "byte", 4 },
}

function Billboards.new()
  local self = setmetatable({ meshes = {}, prepared = {}, count = 0, blobVerts = {}, blobCount = 0,
    cardShadow = {}, blobAlpha = {},
    -- Track C (Lab 54): per-card colour and premultiplied alpha, parallel
    -- arrays indexed like meshes (no table per card). Engine sprites and
    -- records without a colour stay white / straight alpha.
    cardR = {}, cardG = {}, cardB = {}, cardA = {}, cardPremul = {},
    -- Lab 58 (#1): per-card bounding sphere (centre + radius, root cells) for the per-eye frustum test
    cardCX = {}, cardCY = {}, cardCZ = {}, cardRad = {}, vis = {},
    -- Lab 58 (#2): per-actor-slot sample memo (x, z, generation, ground, shadow sample)
    mGen = {}, mX = {}, mZ = {}, mH = {}, mRec = {}, mXf = {}, mS = {}, mLo = {}, memoGen = 1,
    -- Lab 58 (#7): reused vertex rows / blob quads / card shadow records
    blobQuads = {}, shadowRecs = {},
    -- Approach loading (A2): scale-in state by card key (first-seen clock, last-seen clock)
    fadeT = {}, fadeSeen = {} }, Billboards)
  Billboards.current = self -- W5 (owmons): the live renderer's cards, for vrHost.actors.targets
  return self
end

-- Soft blob under a character, stretched and nudged away from the sun
-- (down-right on the original screen), lying on the ground.
local function addBlob(self, x, z, ground, k, alpha, outdoor, reuse)
  if self.blobCount >= Billboards.MAX_BLOBS then return end
  alpha = alpha or 1
  k = math.max(0.6, k or 1)
  local sx, sz = -Light.TO_SUN_XZ[1], -Light.TO_SUN_XZ[2]   -- shadow direction
  local directional = Light.solarWeight or 0
  if outdoor == false then sx,sz,directional=.8,.6,1 end -- unchanged indoor contact shape
  local cx, cz = x + sx * 0.12 * k * directional, z + sz * 0.12 * k * directional
  if sx*sx+sz*sz < .0001 or directional <= 0 then sx,sz=1,0 end
  local ax, az = sx * 0.42 * k, sz * 0.42 * k             -- long axis
  ax,az=sx*(.30+.12*directional)*k,sz*(.30+.12*directional)*k
  local bx, bz = -sz * 0.30 * k, sx * 0.30 * k            -- short axis
  local y = ground + 0.03
  local v = self.blobVerts
  local n = self.blobCount * 6
  local p00, p10, p11, p01
  if reuse then
    -- Lab 58 (#7): one flat row per blob corner, created once per blob slot and filled in place. Only the position
    -- and the alpha change from frame to frame; uv, normal and the white vertex colour are constants of the corner.
    local quads = self.blobQuads
    local q = quads[self.blobCount + 1]
    if not q then
      q = { { 0, 0, 0, 0, 0, 0, 1, 0, 1, 1, 1, 1 }, { 0, 0, 0, 1, 0, 0, 1, 0, 1, 1, 1, 1 },
        { 0, 0, 0, 1, 1, 0, 1, 0, 1, 1, 1, 1 }, { 0, 0, 0, 0, 1, 0, 1, 0, 1, 1, 1, 1 } }
      quads[self.blobCount + 1] = q
    end
    p00, p10, p11, p01 = q[1], q[2], q[3], q[4]
    p00[1], p00[2], p00[3], p00[12] = cx - ax - bx, y, cz - az - bz, alpha
    p10[1], p10[2], p10[3], p10[12] = cx + ax - bx, y, cz + az - bz, alpha
    p11[1], p11[2], p11[3], p11[12] = cx + ax + bx, y, cz + az + bz, alpha
    p01[1], p01[2], p01[3], p01[12] = cx - ax + bx, y, cz - az + bz, alpha
  else
    p00 = { cx - ax - bx, y, cz - az - bz, 0, 0, 0, 1, 0, 1, 1, 1, alpha }
    p10 = { cx + ax - bx, y, cz + az - bz, 1, 0, 0, 1, 0, 1, 1, 1, alpha }
    p11 = { cx + ax + bx, y, cz + az + bz, 1, 1, 0, 1, 0, 1, 1, 1, alpha }
    p01 = { cx - ax + bx, y, cz - az + bz, 0, 1, 0, 1, 0, 1, 1, 1, alpha }
  end
  self.blobAlpha[self.blobCount + 1] = alpha
  v[n + 1], v[n + 2], v[n + 3] = p00, p10, p11
  v[n + 4], v[n + 5], v[n + 6] = p00, p11, p01
  self.blobCount = self.blobCount + 1
end

-- worker "atmos" (GW-P1, coordinated with W5): env.shadowFade mirrors the
-- shader's u_shadowFade (render/AtmosState.lua's sunShare); nil/absent
-- (indoors, or before GW-P1 wiring) behaves exactly as before this edit.
local function blobAlpha(lit, env)
  local fade = env and env.shadowFade
  if fade == nil then return 0.35 + 0.65 * lit end
  local litFaded = lit + (1 - fade) * (1 - lit)
  return math.max(0.4, 0.35 + 0.65 * litFaded)
end

-- Art rows of a sprite sheet, measured once per sheet from its ImageData:
-- top = first opaque row of frame 0 (the standing frame), bottom = the
-- lowest opaque row over every frame (so no walk frame sinks). Pixels in
-- frame rows; nil when the sheet has no CPU-side pixels.
local artCache = setmetatable({}, { __mode = "k" })
function Billboards.artRows(spr)
  if not spr then return nil end
  local key = spr.imageData or spr
  local hit = artCache[key]
  if hit ~= nil then return hit and hit.top, hit and hit.bottom end
  local data = spr.imageData
  local w, h, n = spr.width, spr.height, spr.frameCount or 1
  if not (data and data.getPixel and w and h) then artCache[key] = false; return nil end
  local okD, dw, dh = pcall(data.getDimensions, data)
  if not okD then artCache[key] = false; return nil end
  n = math.max(1, math.min(n, math.floor(dh / h)))
  w = math.min(w, dw)
  local top, bottom
  for f = 0, n - 1 do
    for y = 0, h - 1 do
      local row = f * h + y
      for x = 0, w - 1 do
        local _, _, _, a = data:getPixel(x, row)
        if a and a > 0.5 then
          if f == 0 and (top == nil or y < top) then top = y end
          if bottom == nil or y > bottom then bottom = y end
          break
        end
      end
    end
  end
  if top == nil or bottom == nil then artCache[key] = false; return nil end
  artCache[key] = { top = top, bottom = bottom }
  return top, bottom
end

-- Approach loading (Lab 58 A3): the same scan as artRows, but resumable and callable ahead of time, so a warm job
-- (VRITK_FRLG_HOST ApproachLoader) can measure a sheet's art rows a few rows per frame instead of the frame that first
-- draws its card. It writes the SAME artCache entry artRows would, so artRows stays a pure cache hit afterwards;
-- artRows itself is untouched. Never loads a sheet.
local artScan = setmetatable({}, { __mode = "k" })

-- true when the sheet's art rows are cached (artRows would not scan)
function Billboards.artRowsCached(spr)
  if not spr then return false end
  return artCache[spr.imageData or spr] ~= nil
end

-- Runs at most `budgetRows` pixel rows of the scan (nil = all). true when the rows are cached, false when more work
-- remains (call again). A sheet without CPU pixels is cached as "no art rows" exactly as artRows does.
function Billboards.warmArtRows(spr, budgetRows)
  if not spr then return true end
  local key = spr.imageData or spr
  if artCache[key] ~= nil then return true end
  local data = spr.imageData
  local st = artScan[key]
  if not st then
    local w, h, n = spr.width, spr.height, spr.frameCount or 1
    if not (data and data.getPixel and w and h) then artCache[key] = false; return true end
    local okD, dw, dh = pcall(data.getDimensions, data)
    if not okD then artCache[key] = false; return true end
    n = math.max(1, math.min(n, math.floor(dh / h)))
    st = { w = math.min(w, dw), h = h, n = n, f = 0, y = 0 }
    artScan[key] = st
  end
  local left = tonumber(budgetRows) or math.huge
  local sw, sh, sn = st.w, st.h, st.n
  while st.f < sn do
    local y = st.y
    local row = st.f * sh + y
    for x = 0, sw - 1 do
      local _, _, _, a = data:getPixel(x, row)
      if a and a > 0.5 then
        if st.f == 0 and (st.top == nil or y < st.top) then st.top = y end
        if st.bottom == nil or y > st.bottom then st.bottom = y end
        break
      end
    end
    y = y + 1
    if y >= sh then st.y = 0; st.f = st.f + 1 else st.y = y end
    left = left - 1
    if left <= 0 and st.f < sn then return false end
  end
  artScan[key] = nil
  if st.top == nil or st.bottom == nil then artCache[key] = false
  else artCache[key] = { top = st.top, bottom = st.bottom } end
  return true
end

-- The sheet getDraw(gid) would return, WITHOUT loading anything: the palette override's sprite, else the loaded one.
function Billboards.sheetFor(OwSprites, gid)
  gid = tonumber(gid)
  if gid == nil or not OwSprites then return nil end
  local ov = OwSprites._overrides
  ov = ov and ov[gid]
  if ov and ov.spr then return ov.spr end
  local loaded = OwSprites._loaded
  return loaded and loaded[gid] or nil
end

local OwSpritesSeam
local function owSpritesModule()
  if OwSpritesSeam then return OwSpritesSeam end
  local ok, m = pcall(require, "src.core.game3.ow_sprites")
  if ok and type(m) == "table" then OwSpritesSeam = m end
  return OwSpritesSeam
end

-- Seam for the host: is the card for graphics id `gid` free to draw (sheet resident AND art rows cached)?
function Billboards.cardWarm(gid)
  local spr = Billboards.sheetFor(owSpritesModule(), gid)
  return spr ~= nil and Billboards.artRowsCached(spr)
end

-- Seam for the host: advance the art-rows scan of a RESIDENT sheet. Returns done (true/false), or nil + reason when
-- the sheet is not loaded (nothing is loaded here).
function Billboards.warmGid(gid, budgetRows)
  local spr = Billboards.sheetFor(owSpritesModule(), gid)
  if not spr then return nil, "sheet not loaded" end
  return Billboards.warmArtRows(spr, budgetRows)
end

-- Which frame to show and from where the card is seen. (vx, vz) is the
-- viewer's position, or `dir` a fixed unit direction toward the viewer
-- (3/4 view).
local function relativeFacing(facing, ax, az, vx, vz, dir)
  local f = FACING_VEC[facing] or FACING_VEC.down
  local dx, dz
  if dir then dx, dz = dir[1], dir[2] else dx, dz = vx - ax, vz - az end
  local len = math.sqrt(dx * dx + dz * dz)
  if len < 1e-4 then return facing end
  dx, dz = dx / len, dz / len
  local dot = f[1] * dx + f[2] * dz
  if dot > 0.7071 then return "down" end   -- facing the viewer
  if dot < -0.7071 then return "up" end    -- facing away
  -- viewer's right-hand side (in the viewer's frame) decides left/right
  local side = f[1] * dz - f[2] * dx
  if side > 0 then return "right" end
  return "left"
end

-- Lab 58 (#7): the six vertices of a card, reused. One scratch array of six flat 8-number rows per Billboards,
-- filled in place for every card (setVertices copies the data, so the next card may overwrite it). The normal
-- columns (0, 1, 0) are constants of the row and written once.
local function cardRows(self)
  local rows = self.cardRowScratch
  if not rows then
    rows = {}
    for i = 1, 6 do rows[i] = { 0, 0, 0, 0, 0, 0, 1, 0 } end
    self.cardRowScratch = rows
  end
  return rows
end

-- The shared card builder: one upright quad (x0,z0)-(x1,z1) from `base` to `top` with the UV rect (u0,v0)-(u1,v1).
-- cardverts OFF builds the six nested tables and a fresh cardShadow record per card exactly as Lab 57 did; ON fills
-- reused rows and records in place. cull ON also stores the card's bounding sphere (centre and half diagonal).
-- Returns false when no mesh could be made (count is restored).
local function pushCard(self, image, x0, z0, x1, z1, base, top, u0, v0, u1, v1, srec, sxf, reuse, cull)
  local verts
  if reuse then
    verts = cardRows(self)
    local r = verts[1]
    r[1], r[2], r[3], r[4], r[5] = x0, base, z0, u0, v1
    r = verts[2]
    r[1], r[2], r[3], r[4], r[5] = x1, base, z1, u1, v1
    r = verts[3]
    r[1], r[2], r[3], r[4], r[5] = x1, top, z1, u1, v0
    r = verts[4]
    r[1], r[2], r[3], r[4], r[5] = x0, base, z0, u0, v1
    r = verts[5]
    r[1], r[2], r[3], r[4], r[5] = x1, top, z1, u1, v0
    r = verts[6]
    r[1], r[2], r[3], r[4], r[5] = x0, top, z0, u0, v0
  else
    verts = {
      { x0, base, z0, u0, v1, 0, 1, 0 }, { x1, base, z1, u1, v1, 0, 1, 0 },
      { x1, top, z1, u1, v0, 0, 1, 0 },
      { x0, base, z0, u0, v1, 0, 1, 0 }, { x1, top, z1, u1, v0, 0, 1, 0 },
      { x0, top, z0, u0, v0, 0, 1, 0 },
    }
  end
  local i = self.count + 1
  self.count = i
  if reuse then
    if srec then
      local rec = self.shadowRecs[i]
      if not rec then rec = {}; self.shadowRecs[i] = rec end
      rec.image, rec.xf = srec.shadow, sxf
      self.cardShadow[i] = rec
    else
      self.cardShadow[i] = false
    end
  else
    self.cardShadow[i] = srec and { image = srec.shadow, xf = sxf } or false
  end
  local mesh = self.meshes[i]
  if not mesh then
    local okM, m = pcall(love.graphics.newMesh, Shaders.FORMAT, verts, "triangles", "stream")
    if not okM then self.count = i - 1; return false end
    mesh = m
    self.meshes[i] = mesh
  else
    mesh:setVertices(verts)
  end
  mesh:setTexture(image)
  self.cardR[i], self.cardG[i], self.cardB[i], self.cardA[i], self.cardPremul[i] = 1, 1, 1, 1, false
  if cull then
    local hx, hy, hz = (x1 - x0) * 0.5, (top - base) * 0.5, (z1 - z0) * 0.5
    self.cardCX[i], self.cardCY[i], self.cardCZ[i] = (x0 + x1) * 0.5, (base + top) * 0.5, (z0 + z1) * 0.5
    self.cardRad[i] = mathsqrt(hx * hx + hy * hy + hz * hz) + 1e-4
  end
  return true
end

-- W5 (owmons): one upright card from an image + UV rect, the same quad the
-- engine-sprite path below builds. (dx, dz) is the unit direction the card
-- faces. Returns false when no mesh could be made.
local function emitCard(self, image, u0, v0, u1, v1, x, z, base, w, h, dx, dz, srec, sxf, reuse, cull)
  local rx, rz = dz * (w / 2), -dx * (w / 2)
  local x0, z0, x1, z1 = x - rx, z - rz, x + rx, z + rz
  return pushCard(self, image, x0, z0, x1, z1, base, base + h, u0, v0, u1, v1, srec, sxf, reuse, cull)
end

-- Track C (Lab 54): colour + premultiplied flag for the card just emitted.
local function tintLast(self, col, premul)
  local i = self.count
  if type(col) == "table" then
    self.cardR[i], self.cardG[i] = tonumber(col[1]) or 1, tonumber(col[2]) or 1
    self.cardB[i], self.cardA[i] = tonumber(col[3]) or 1, tonumber(col[4]) or 1
  end
  self.cardPremul[i] = premul == true
end

-- W5 (owmons): a provider record (data/Actors.lua registerProvider) carries
-- its own image through rec.pose(rec, relFacing) instead of an engine
-- graphics id. It goes through the same ground (heightAt), lift, art-row
-- trim, card scale, blob and sun-shadow steps as an engine sprite; its blob
-- follows rec.shadow (false = none, a number scales it). Each drawn card
-- with a key is also recorded as a hit target, from the very numbers used
-- to build it (self.hitTargets[1..self.targetCount], stamped with
-- self.prepareFrame).
-- Lab 58 (#2): ground height and shadow-mask sample under (x, z). Without the memo this is exactly the Lab 57 pair
-- of calls (env.heightAt, then pcall(env.shadowAt)). With the memo (env.memoEpoch present, see Billboards:prepare)
-- the last answer of this actor slot is reused while x, z, the memo generation and both env functions are unchanged:
-- the answer is a pure function of those plus the scene state the epoch stands for. A shadowAt that threw is never
-- memoised. Returns ground (with the default-ground fallback applied), srec, sxf, sh, slo.
local function sample(self, env, slot, x, z)
  local memo = slot and self.memoOn
  if memo and self.mGen[slot] == self.memoGen and self.mX[slot] == x and self.mZ[slot] == z then
    return self.mH[slot] or env.defaultGround or 0, self.mRec[slot] or nil, self.mXf[slot] or nil, self.mS[slot], self.mLo[slot]
  end
  local h = env.heightAt(x, z)
  local ground = h or env.defaultGround or 0
  local srec, sxf, sh, slo
  local okS = true
  if env.shadowAt then
    local r1, r2, r3, r4
    okS, r1, r2, r3, r4 = pcall(env.shadowAt, x, z)
    if okS then srec, sxf, sh, slo = r1, r2, r3, r4 end
  end
  if memo then
    if okS then
      self.mGen[slot], self.mX[slot], self.mZ[slot] = self.memoGen, x, z
      self.mH[slot], self.mRec[slot], self.mXf[slot] = h or false, srec or false, sxf or false
      self.mS[slot], self.mLo[slot] = sh, slo
    else
      self.mGen[slot] = nil
    end
  end
  return ground, srec, sxf, sh, slo
end

local function prepareExternal(self, a, env, slot, reuse, cull)
  -- no image yet (e.g. its texture renders next frame): no card, no blob
  local facing = relativeFacing(a.facing, a.x, a.z, env.viewX, env.viewZ, env.cardDir)
  local okP, image, u0, v0, u1, v1, fw, fh, artBottom, xs, col = pcall(a.pose, a, facing)
  if not (okP and image and u0 and v0 and u1 and v1 and fw and fh) then return end
  local ground, srec, sxf, sh, slo = sample(self, env, slot, a.x, a.z)
  local k = env.cardScale or 1
  if a.shadow ~= false then
    local lit = srec and Light.litFrom(sh or 0, ground, 0.03, slo) or 1
    addBlob(self, a.x, a.z, ground, k * (tonumber(a.shadow) or 1), blobAlpha(lit, env), env.outdoor, reuse) -- worker "atmos"
  end
  local w, h = fw / CELL * k * (tonumber(xs) or 1), fh / CELL * k
  local drop = artBottom and math.max(0, fh - 1 - artBottom) / CELL * k or 0
  local lift = (a.liftPx or 0) / CELL * (a.liftScaled and k or 1)
  local base = ground + lift + 0.01 - drop
  local dx, dz
  if env.cardDir then
    dx, dz = env.cardDir[1], env.cardDir[2]
  else
    dx, dz = env.viewX - a.x, env.viewZ - a.z
  end
  local len = math.sqrt(dx * dx + dz * dz)
  if len < 1e-4 then dx, dz, len = 0, 1, 1 end
  dx, dz = dx / len, dz / len
  if not emitCard(self, image, u0, v0, u1, v1, a.x, a.z, base, w, h, dx, dz, srec, sxf, reuse, cull) then return end
  if col ~= nil or a.color ~= nil or a.premultiplied then tintLast(self, col or a.color, a.premultiplied) end -- Track C
  self.externalCount = self.externalCount + 1
  if a.key ~= nil then
    local n = self.targetCount + 1
    local t = self.hitTargets[n]
    if not t then t = { center = {} }; self.hitTargets[n] = t end
    t.key, t.kind, t.catchable = a.key, a.kind, a.catchable == true
    t.center.x, t.center.y, t.center.z = a.x, base + drop + (h - drop) / 2, a.z
    t.width, t.height, t.base, t.ground = w, h - drop, base + drop, ground
    t.facing, t.frame = facing, self.prepareFrame
    self.targetCount = n
  end
end

-- W5 (owmons): a copy of this frame's hit targets (external cards only):
-- { frame, list = { { key, kind, catchable, center = {x,y,z}, width, height,
-- base, ground, facing, frame }, ... } }, root cells, Y up.
function Billboards:targetsSnapshot()
  local list = {}
  for i = 1, self.targetCount or 0 do
    local t = self.hitTargets[i]
    list[i] = { key = t.key, kind = t.kind, catchable = t.catchable,
      center = { x = t.center.x, y = t.center.y, z = t.center.z },
      width = t.width, height = t.height, base = t.base, ground = t.ground,
      facing = t.facing, frame = t.frame }
  end
  return { frame = self.prepareFrame or 0, list = list }
end

-- Build this frame's cards once; both eyes draw the same cards (oriented to
-- the head centre, not per eye, so the stereo pair agrees).
-- env = { viewX, viewZ (cells), heightAt = fn(x,z), hidePlayer = bool,
--         shadowAt = fn(x,z) -> rec, xf, shadowHeight (optional, review R5),
--         cardDir = { dx, dz } unit, toward the viewer (optional: 3/4 view) }
-- Lab 58 optional env fields (all absent = the Lab 57 behaviour):
--   cullX, cullZ, cullFar (cells): ENGINE-sprite NPC cards farther than cullFar + CULL_MARGIN from (cullX, cullZ) are
--     not prepared (no card, no blob). Needs the cardcull switch. Never applied to the player or to provider records
--     (rec.pose) unless the record opts in with rec.cullable = true; hit targets are made by prepare, so they are
--     never lost to the per-eye frustum test.
--   memoEpoch (any comparable value, e.g. Scene:probeEpoch()): enables the per-actor-slot sample memo (actormemo).
local CULL_MARGIN = 4
Billboards.CULL_MARGIN = CULL_MARGIN

-- Approach loading (A2, flag cardscale): a card seen for the first time grows from SCALE_FROM to 1 about its feet over
-- SCALE_SECS (smoothstep). State is kept by the record's fadeKey (Actors sets it: the same NPC keeps one key as a
-- neighbour ghost and as a live object, so crossing a border does not replay the scale-in). A key not seen for
-- FADE_FORGET seconds is dropped, so an NPC that leaves range and returns grows in again. No allocation after the
-- first sight of a key.
Billboards.SCALE_FROM = 0.85
Billboards.SCALE_SECS = 0.30
Billboards.FADE_FORGET = 1.0
function Billboards.scaleAt(age)
  if age >= Billboards.SCALE_SECS then return 1 end
  if age < 0 then age = 0 end
  local k = age / Billboards.SCALE_SECS
  local e = k * k * (3 - 2 * k)
  return Billboards.SCALE_FROM + (1 - Billboards.SCALE_FROM) * e
end
local function fadeScale(self, key, now)
  local ft = self.fadeT
  local t0 = ft[key]
  if t0 == nil then t0 = now; ft[key] = now end
  self.fadeSeen[key] = now
  local age = now - t0
  return Billboards.scaleAt(age)
end
local function pruneFade(self, now)
  local ft, seen, forget = self.fadeT, self.fadeSeen, Billboards.FADE_FORGET
  for key, t in pairs(seen) do
    if now - t > forget or now < t then seen[key] = nil; ft[key] = nil end
  end
end

local OwSpritesMemo -- Lab 58 (#12): the engine module table, kept after the first success (never memoise failure)

local function build(self, actors, env, memoReq, reuse, cull, memo, scaleOn)
  local okO, OwSprites
  if memoReq and OwSpritesMemo then
    okO, OwSprites = true, OwSpritesMemo
  else
    okO, OwSprites = pcall(require, "src.core.game3.ow_sprites")
    if memoReq and okO and OwSprites then OwSpritesMemo = OwSprites end
  end
  if not (okO and OwSprites) then return end
  local lim2
  if cull and env.cullFar and env.cullX and env.cullZ then
    local lim = env.cullFar + CULL_MARGIN
    lim2 = lim * lim
  end
  local cullX, cullZ = env.cullX, env.cullZ
  for i = 1, #actors do
    local a = actors[i]
    if a.pose then
      if lim2 and a.cullable == true then
        local dx, dz = a.x - cullX, a.z - cullZ
        if dx * dx + dz * dz > lim2 then goto continue end
      end
      prepareExternal(self, a, env, memo and i or nil, reuse, cull); goto continue -- W5 (owmons)
    end
    if lim2 and not a.player then
      local dx, dz = a.x - cullX, a.z - cullZ
      if dx * dx + dz * dz > lim2 then goto continue end
    end
    local ground0, srec, sxf, sh, slo = sample(self, env, memo and i or nil, a.x, a.z)
    local lit = srec and Light.litFrom(sh or 0, ground0, 0.03, slo) or 1
    addBlob(self, a.x, a.z, ground0, env.cardScale or 1, blobAlpha(lit, env), env.outdoor, reuse) -- worker "atmos"
    if not (a.player and env.hidePlayer) then
      local spr = OwSprites.getDraw(a.gid)
      if spr and spr.image and spr.quads then
        local facing = relativeFacing(a.facing, a.x, a.z, env.viewX, env.viewZ, env.cardDir)
        local okP, frame, flip = pcall(OwSprites.pose, spr, facing, a.walkPhase, a.stepFlip, a.opts)
        local q = okP and spr.quads[frame]
        if q then
          local qx, qy, qw, qh = q:getViewport()
          local iw, ih = spr.image:getDimensions()
          local u0, v0, u1, v1 = qx / iw, qy / ih, (qx + qw) / iw, (qy + qh) / ih
          if flip then u0, u1 = u1, u0 end
          local k = env.cardScale or 1
          if scaleOn and a.fadeKey ~= nil then -- Approach loading (A2): scale-in of a newly seen card, about its feet
            local sc = fadeScale(self, a.fadeKey, env.clock)
            if sc ~= 1 then k = k * sc end
          end
          local fh = spr.height or qh
          local w, h = (spr.width or qw) / CELL * k, fh / CELL * k
          -- Lab 57 asked heightAt a second time for the same point; the first answer (ground0) is that value
          local ground = ground0
          if not memo then ground = env.heightAt(a.x, a.z) or env.defaultGround or 0 end
          -- R1: the lowest art row (not the frame's edge) meets the ground
          local _, artBottom = Billboards.artRows(spr)
          local drop = artBottom and math.max(0, fh - 1 - artBottom) / CELL * k or 0
          local base = ground + (a.liftPx or 0) / CELL + 0.01 - drop
          local dx, dz
          if env.cardDir then
            dx, dz = env.cardDir[1], env.cardDir[2]
          else
            dx, dz = env.viewX - a.x, env.viewZ - a.z
          end
          local len = math.sqrt(dx * dx + dz * dz)
          if len < 1e-4 then dx, dz, len = 0, 1, 1 end
          dx, dz = dx / len, dz / len
          if not emitCard(self, spr.image, u0, v0, u1, v1, a.x, a.z, base, w, h, dx, dz, srec, sxf, reuse, cull) then return end
        end
      end
    end
    ::continue:: -- W5 (owmons)
  end
end

-- Lab 58 (#7): the blob vertices are the same for both eyes, so the mesh is filled once per frame (in prepare)
-- instead of once per eye in drawBlobs.
local function ensureBlobMesh(self)
  if self.blobMesh then return self.blobMesh end
  local cap = {}
  for i = 1, Billboards.MAX_BLOBS * 6 do cap[i] = { 0, 0, 0, 0, 0, 0, 1, 0, 1, 1, 1, 1 } end
  local ok, m = pcall(love.graphics.newMesh, Billboards.BLOB_FORMAT, cap, "triangles", "stream")
  if not ok then return nil end
  self.blobMesh = m
  m:setTexture(Light.blob())
  return m
end

local function uploadBlobs(self)
  self.blobUploaded = self.prepareFrame
  local n = self.blobCount * 6
  if n == 0 then return end
  if not (Shaders.get("CUTOUT") and Light.blob()) then return end
  local m = ensureBlobMesh(self)
  if not m then return end
  local verts = self.blobVerts
  for i = n + 1, #verts do verts[i] = nil end
  m:setVertices(verts)
  m:setDrawRange(1, n)
end

function Billboards:prepare(actors, env)
  self.count = 0
  self.blobCount = 0
  -- W5 (owmons): per-frame external-card and hit-target bookkeeping
  self.prepareFrame = (self.prepareFrame or 0) + 1
  self.externalCount, self.targetCount = 0, 0
  self.hitTargets = self.hitTargets or {}
  local memoReq, reuse, cull = speedOn("requirememo"), speedOn("cardverts"), speedOn("cardcull")
  local memo = false
  if speedOn("actormemo") and env.memoEpoch ~= nil then
    memo = true
    -- anything the memo's answers depend on that this file cannot see changed: start a new generation
    if self.memoEpoch ~= env.memoEpoch or self.memoH ~= env.heightAt or self.memoS ~= env.shadowAt then
      self.memoEpoch, self.memoH, self.memoS = env.memoEpoch, env.heightAt, env.shadowAt
      self.memoGen = self.memoGen + 1
    end
  end
  self.memoOn = memo
  self.cullOn = cull
  self.reuseOn = reuse
  local scaleOn = env.clock ~= nil and speedOn("cardscale")
  build(self, actors, env, memoReq, reuse, cull, memo, scaleOn)
  if scaleOn and self.prepareFrame % 32 == 0 then pruneFade(self, env.clock) end
  if reuse then uploadBlobs(self) end
end

-- Lab 58 (#2): drop every memoised sample (a caller that knows the scene changed in a way the epoch cannot show).
function Billboards:invalidateMemo()
  self.memoGen = self.memoGen + 1
end

-- Blob shadows: one mesh for all characters, depth-tested, no depth write.
function Billboards:drawBlobs(env)
  if self.blobCount == 0 then return 0 end
  local cutout = Shaders.get("CUTOUT")
  local blob = Light.blob()
  if not (cutout and blob) then return 0 end
  local g = love.graphics
  local n = self.blobCount * 6
  if self.reuseOn then
    if self.blobUploaded ~= self.prepareFrame then uploadBlobs(self) end -- a caller that skipped prepare's upload
    if not self.blobMesh then return 0 end
  else
    if not self.blobMesh then
      local cap = {}
      for i = 1, Billboards.MAX_BLOBS * 6 do cap[i] = { 0, 0, 0, 0, 0, 0, 1, 0, 1, 1, 1, 1 } end
      local ok, m = pcall(love.graphics.newMesh, Billboards.BLOB_FORMAT, cap, "triangles", "stream")
      if not ok then return 0 end
      self.blobMesh = m
      m:setTexture(blob)
    end
    local verts = self.blobVerts
    for i = n + 1, #verts do verts[i] = nil end
    self.blobMesh:setVertices(verts)
    self.blobMesh:setDrawRange(1, n)
  end
  g.setDepthMode("lequal", false)
  g.setShader(cutout)
  Shaders.frame(cutout, env, 0.0)
  Shaders.shadow(cutout, nil)
  Shaders.texSize(cutout, nil)
  Shaders.send(cutout, "u_mvp", "row", env.vp)
  g.draw(self.blobMesh)
  g.setShader()
  g.setDepthMode("lequal", true)
  return 1
end

-- Lab 58 (#1): the six frustum planes of a row-major view-projection with the same arithmetic as
-- Scene._planesInto, written into this Billboards' own scratch (slot 5 = the plane normal's length, for sphere tests).
local function putPlane(p, m, s, a, b, c, d)
  local pa, pb, pc = m[13] + s * a, m[14] + s * b, m[15] + s * c
  p[1], p[2], p[3], p[4] = pa, pb, pc, m[16] + s * d
  p[5] = mathsqrt(pa * pa + pb * pb + pc * pc)
end
local function eyePlanes(self, m)
  local P = self.planes
  if not P then
    P = { {}, {}, {}, {}, {}, {} }
    self.planes = P
  end
  putPlane(P[1], m, 1, m[1], m[2], m[3], m[4]); putPlane(P[2], m, -1, m[1], m[2], m[3], m[4])
  putPlane(P[3], m, 1, m[5], m[6], m[7], m[8]); putPlane(P[4], m, -1, m[5], m[6], m[7], m[8])
  putPlane(P[5], m, 1, m[9], m[10], m[11], m[12]); putPlane(P[6], m, -1, m[9], m[10], m[11], m[12])
  return P
end
Billboards._eyePlanes = eyePlanes -- test seam

-- true when the sphere (cx, cy, cz, r) touches or lies inside all six planes
local function sphereVisible(P, cx, cy, cz, r)
  for i = 1, 6 do
    local p = P[i]
    if p[1] * cx + p[2] * cy + p[3] * cz + p[4] < -r * p[5] then return false end
  end
  return true
end
Billboards._sphereVisible = sphereVisible

function Billboards:draw(env)
  if self.count == 0 then return 0 end
  local cutout = Shaders.get("CUTOUT")
  if not cutout then return 0 end
  local g = love.graphics
  -- Lab 58 (#1): per-eye frustum test of each card's bounding sphere (render only: hit targets were made in prepare)
  local vis, P
  local drawn = self.count
  if self.cullOn and env.vp then
    P = eyePlanes(self, env.vp)
    vis = self.vis
    local CX, CY, CZ, CR = self.cardCX, self.cardCY, self.cardCZ, self.cardRad
    drawn = 0
    for i = 1, self.count do
      local v = sphereVisible(P, CX[i], CY[i], CZ[i], CR[i])
      vis[i] = v
      if v then drawn = drawn + 1 end
    end
    if drawn == 0 then return 0 end
  end
  g.setShader(cutout)
  Shaders.frame(cutout, env, 0.5)
  Shaders.texSize(cutout, nil)
  Shaders.send(cutout, "u_mvp", "row", env.vp)
  -- review R5: each card reads the shadow mask of the map it stands on
  local bound = 0
  -- Track C (Lab 54): colour / blend state changes only where a card differs
  -- from the one before; all-white straight-alpha frames make no extra calls.
  local cr, cg, cb, ca, pm = 1, 1, 1, 1, false
  local R, G, B, A, Pm = self.cardR, self.cardG, self.cardB, self.cardA, self.cardPremul
  for i = 1, self.count do
    if vis and not vis[i] then goto skip end
    do
      local sh = env.shadows and self.cardShadow[i] or false
      if sh ~= bound then
        if sh and sh.image then
          Shaders.shadow(cutout, sh.image, sh.xf[1], sh.xf[2], sh.xf[3], sh.xf[4])
        else
          Shaders.shadow(cutout, nil)
        end
        bound = sh
      end
      local r, gg, b, a, p = R[i] or 1, G[i] or 1, B[i] or 1, A[i] or 1, Pm[i] == true
      if r ~= cr or gg ~= cg or b ~= cb or a ~= ca then g.setColor(r, gg, b, a); cr, cg, cb, ca = r, gg, b, a end
      if p ~= pm then
        g.setBlendMode("alpha", p and "premultiplied" or "alphamultiply"); pm = p
        Shaders.send(cutout, "u_premul", p and 1 or 0) -- Lab 57: haze scaled by alpha on premultiplied cards
      end
      g.draw(self.meshes[i])
    end
    ::skip::
  end
  if cr ~= 1 or cg ~= 1 or cb ~= 1 or ca ~= 1 then g.setColor(1, 1, 1, 1) end
  if pm then g.setBlendMode("alpha", "alphamultiply"); Shaders.send(cutout, "u_premul", 0) end
  g.setShader()
  return drawn
end

function Billboards:release()
  if self.blobMesh then pcall(self.blobMesh.release, self.blobMesh); self.blobMesh = nil end
  for i, m in ipairs(self.meshes) do
    if m.release then pcall(m.release, m) end
    self.meshes[i] = nil
  end
  self.count = 0
  -- W5 (owmons): a torn-down renderer reports no targets
  self.targetCount = 0
  if Billboards.current == self then Billboards.current = nil end
end

local _ = Mat4
return Billboards
