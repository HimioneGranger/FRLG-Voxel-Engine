local WORLD_IDENTITY={1,1,1}
local WORLD_ZERO={0,0,0}
-- VRITK_FRLG_HOST compat (Gen3 only: FireRed/LeafGreen and Emerald): the game's own Poke Ball open, absorb
-- and capture-star presentation, placed in the 3D world for the field send-out, recall and overworld catch.
--
-- Art and colours come from the engine's ROM extraction (src/import/gba/ball_open_extract.lua):
--   particles.rgba   gBallParticleSpritesheets (8x8 frames, gBallParticlePalettes)
--   balls.rgba       gBallSpriteSheets (16x16 closed / opening / open frames)
--   fadeColors       sBallOpenFadeColors (the per-ball colour a Pokemon is blended toward)
--   sine             gSineTable
-- Motion is the engine's own port of pokefirered (src/core/game3/battle/ball_open.lua and catch_seq.lua,
-- pokefirered/src/battle_anim_special.c and pokeball.c): the per-ball particle spawners and callbacks, the
-- sprite animation, the palette-fade state machine and the capture-star arcs are repeated here per instance
-- (the engine keeps one global set for the battle screen, which must not be disturbed from the field).
-- Nothing here draws art that the ROM does not contain, and nothing touches game state.
--
-- Placement: native battle-screen pixels map onto the Pokemon's own card. A 64 px battle frame becomes the
-- card's frame width (k = card width / 64 world px per GBA px), so the burst, the ball offsets and the
-- emerge/shrink distances keep the game's proportions to the Pokemon. Particles are upright quads facing
-- the viewer (the card's own yaw), at world depth, drawn identically in both eyes.
-- Not reproduced (VR-only gaps, see the task report): the battle background's white palette flash
-- (BeginNormalPaletteFade to white on the BG layer) has no field counterpart and is not applied to the
-- whole VR world.
local N = {}
N.VERSION = 1
N.TICK = 1 / 60

local function engine(name)
  local ok, m = pcall(require, name)
  if ok and type(m) == "table" then return m end
  return nil
end
local function BO() return engine("src.core.game3.battle.ball_open") end

-- pokefirered include/constants/items.h -> src/battle_anim_special.c:702 (ItemIdToBallId)
N.BALL_IDS = { POKE_BALL = 0, GREAT_BALL = 1, SAFARI_BALL = 2, ULTRA_BALL = 3, MASTER_BALL = 4, NET_BALL = 5,
  DIVE_BALL = 6, NEST_BALL = 7, REPEAT_BALL = 8, TIMER_BALL = 9, LUXURY_BALL = 10, PREMIER_BALL = 11 }
function N.ballIdForKey(key) return N.BALL_IDS[key] or 0 end
function N.ballIdForItem(item)
  local b = BO()
  return b and b.ballIdForItem and b.ballIdForItem(item) or 0
end

local dataCache
function N.data()
  if dataCache then return dataCache end
  local b = BO()
  if not (b and b.data) then return nil end
  local ok, d = pcall(b.data)
  if ok and type(d) == "table" then dataCache = d end
  return dataCache
end

-- The colour (0..31 per channel) a Pokemon is blended toward for this ball.
function N.fadeColor(ballId)
  local d = N.data()
  local c = d and d.fadeColors and d.fadeColors[(ballId or 0) + 1]
  if c then return c[1], c[2], c[3] end
  return 31, 31, 31
end

-- gSineTable (from the ROM when the cache has it; the same truncated Q8.8 values otherwise).
local function sineAt(index)
  local d = N.data()
  local v = d and d.sine and d.sine[(index % 320) + 1]
  if v then return v end
  local s = math.sin((index % 256) * 2 * math.pi / 256) * 256
  return s >= 0 and math.floor(s) or -math.floor(-s)
end
-- pokefirered/src/trig.c:514
local function Sin(index, amp) return math.floor(amp * sineAt(index) / 256) end
-- pokefirered/src/trig.c:520
local function Cos(index, amp) return Sin(index + 64, amp) end
N.Sin, N.Cos = Sin, Cos

-- ------------------------------------------------------------ extracted sheets
local function readCache(rel)
  local Dataset = engine("src.core.game3.dataset")
  if Dataset and Dataset.cache then
    local ok, c = pcall(Dataset.cache)
    local d = ok and c and c.read and c:read(rel)
    if type(d) == "string" and #d > 0 then return d end
  end
  local CacheFs = engine("src.import.CacheFs")
  if CacheFs and CacheFs.readActive then
    local ok, d = pcall(CacheFs.readActive, rel)
    if ok and type(d) == "string" and #d > 0 then return d end
  end
  return nil
end
local function cacheRoot()
  local Extract = engine("src.import.gba.extract_island1")
  local b = BO()
  return (Extract and Extract.CACHE_ROOT or "data/generated/gba") .. "/" .. (b and b.CACHE_SUB or "pokemon/battle/ball_open")
end

local sheets = {}
local function sheet(which)
  local hit = sheets[which]
  if hit ~= nil then return hit or nil end
  local d = N.data()
  if not (d and love and love.image and love.graphics) then return nil end
  sheets[which] = false
  local name, w, h
  if which == "particles" then
    name, w, h = d.sheet or "particles.rgba", d.sheetW or 64, d.sheetH or 8
  else
    name, w, h = d.ballSheet or "balls.rgba", d.ballSheetW or 192, d.ballSheetH or 48
  end
  local rgba = readCache(cacheRoot() .. "/" .. name)
  if rgba and #rgba >= w * h * 4 then
    local okD, id = pcall(love.image.newImageData, w, h, "rgba8", rgba)
    if okD and id then
      local okI, img = pcall(love.graphics.newImage, id)
      if okI and img then
        img:setFilter("nearest", "nearest")
        sheets[which] = { image = img, data = id, w = w, h = h }
      end
    end
  end
  return sheets[which] or nil
end
N.sheet = sheet

-- Opaque extent (GBA px) of a ball's closed frame in gBallSpriteSheets: the size the game draws the ball.
local artSize = {}
function N.ballArtSize(ballId)
  ballId = ballId or 0
  if artSize[ballId] then return artSize[ballId] end
  local s = sheet("balls")
  if not s then return 12 end
  local x0, x1, y0, y1 = 99, -1, 99, -1
  for y = 0, 15 do
    for x = 0, 15 do
      local _, _, _, a = s.data:getPixel(ballId * 16 + x, y)
      if a > 0 then x0, x1, y0, y1 = math.min(x0, x), math.max(x1, x), math.min(y0, y), math.max(y1, y) end
    end
  end
  local size = (x1 >= x0) and math.max(x1 - x0 + 1, y1 - y0 + 1) or 12
  artSize[ballId] = size
  return size
end

-- ------------------------------------------------------------ palette fade (pokefirered/src/palette.c:151, :393)
local Fade = {}
Fade.__index = Fade
function Fade.new()
  return setmetatable({ active = false, y = 0, target = 0, yDec = false, toggle = 0, finishing = false,
    counter = 0, objSel = nil, color = nil, delay = 0, delayCounter = 0 }, Fade)
end
function Fade:update()
  if not self.active then return end
  if self.finishing then
    if self.counter == 4 then self.active, self.finishing, self.counter = false, false, 0
    else self.counter = self.counter + 1 end
    return
  end
  if self.toggle == 0 then
    if self.delayCounter < self.delay then self.delayCounter = self.delayCounter + 1; return end
    self.delayCounter = 0
  elseif self.objSel then
    self.objSel.coeff = self.y
  end
  self.toggle = 1 - self.toggle
  if self.toggle == 0 then
    if self.y == self.target then
      self.objSel = nil
      self.finishing = true
    elseif not self.yDec then
      self.y = math.min(self.target, self.y + 2)
    else
      self.y = math.max(self.target, self.y - 2)
    end
  end
end
function Fade:begin(startY, targetY, opts)
  if self.active then return false end
  opts = opts or {}
  self.y, self.target, self.active = startY, targetY, true
  self.objSel, self.delay = opts.obj, opts.delay or 0
  self.delayCounter = self.delay
  self.yDec = not (startY < targetY)
  self:update()
  return true
end
N.Fade = Fade

-- ------------------------------------------------------------ particles (ball_open.lua: pokefirered/src/battle_anim_special.c)
local CB = {}
-- pokefirered/src/battle_anim_special.c:1492
function CB.poke1(p) if p.data[1] == 0 then p.cb = CB.poke2 else p.data[1] = p.data[1] - 1 end end
-- pokefirered/src/battle_anim_special.c:1500
function CB.poke2(p)
  local d = p.data
  p.x2, p.y2 = Sin(d[0], d[1]), Cos(d[0], d[1])
  d[1] = d[1] + 2
  if d[1] == 50 then p.dead = true end
end
-- pokefirered/src/battle_anim_special.c:1693
function CB.fan(p)
  local d = p.data
  p.x2, p.y2 = Sin(d[0], d[1]), Cos(d[0], d[2])
  d[0] = (d[0] + d[4]) % 256; d[1] = d[1] + d[5]; d[2] = d[2] + d[6]; d[3] = d[3] + 1
  if d[3] == 51 then p.dead = true end
end
-- pokefirered/src/battle_anim_special.c:1735
function CB.repeat_(p)
  local d = p.data
  p.x2, p.y2 = Sin(d[0], d[1]), Cos(d[0], Sin(d[0], d[2]))
  d[0] = (d[0] + 6) % 256; d[1] = d[1] + 1; d[2] = d[2] + 1; d[3] = d[3] + 1
  if d[3] == 51 then p.dead = true end
end
-- pokefirered/src/battle_anim_special.c:1823
function CB.premier(p)
  local d = p.data
  p.x2, p.y2 = Sin(d[0], d[1]), Cos(d[0], Sin(d[0] % 64, d[2]))
  d[0] = (d[0] + 10) % 256; d[1] = d[1] + 1; d[2] = d[2] + 1; d[3] = d[3] + 1
  if d[3] == 51 then p.dead = true end
end

-- pokefirered/src/battle_anim_special.c:201
local ANIM_NUMS = { [0] = 0, 0, 0, 5, 1, 2, 2, 3, 5, 5, 4, 4 }

local function spawn(sim, task, cb, d, animNum)
  local p = { x = task.x, y = task.y, x2 = 0, y2 = 0, animNum = animNum or ANIM_NUMS[task.ballId] or 0,
    animBeginning = true, frame = 0, hFlip = false, delay = 0, cmd = 1, cb = cb,
    data = { [0] = 0, 0, 0, 0, 0, 0, 0, 0 } }
  for key, v in pairs(d or {}) do p.data[key] = v end
  sim.particles[#sim.particles + 1] = p
  return p
end
local function fanBurst(sim, task, count, step, d4, d5, d6)
  for i = 0, count - 1 do spawn(sim, task, CB.fan, { [0] = i * step, [4] = d4, [5] = d5, [6] = d6 }) end
end
local SPAWN = {}
-- pokefirered/src/battle_anim_special.c:1448
function SPAWN.poke(sim, t)
  if t.data0 < 16 then
    local v = t.data0
    if v >= 8 then v = v - 8 end
    spawn(sim, t, CB.poke1, { [0] = v * 32 })
    if t.data0 == 15 then return true end
  end
  t.data0 = t.data0 + 1
  return false
end
-- pokefirered/src/battle_anim_special.c:1648
function SPAWN.great(sim, t)
  if t.data7 ~= 0 then t.data7 = t.data7 - 1; return false end
  fanBurst(sim, t, 8, 32, 8, 2, 2)
  t.data7 = 8
  t.data0 = t.data0 + 1
  return t.data0 == 2
end
-- pokefirered/src/battle_anim_special.c:1578
function SPAWN.safari(sim, t) fanBurst(sim, t, 8, 32, 4, 1, 1); return true end
-- pokefirered/src/battle_anim_special.c:1613
function SPAWN.ultra(sim, t) fanBurst(sim, t, 10, 25, 5, 1, 1); return true end
-- pokefirered/src/battle_anim_special.c:1746
function SPAWN.master(sim, t) fanBurst(sim, t, 8, 32, 8, 2, 1); fanBurst(sim, t, 8, 32, 8, 1, 2); return true end
-- pokefirered/src/battle_anim_special.c:1543
function SPAWN.dive(sim, t) fanBurst(sim, t, 8, 32, 10, 1, 2); return true end
-- pokefirered/src/battle_anim_special.c:1704
function SPAWN.repeat_(sim, t) for i = 0, 11 do spawn(sim, t, CB.repeat_, { [0] = i * 21 }) end; return true end
-- pokefirered/src/battle_anim_special.c:1509
function SPAWN.timer(sim, t) fanBurst(sim, t, 8, 32, 10, 2, 1); return true end
-- pokefirered/src/battle_anim_special.c:1792
function SPAWN.premier(sim, t) for i = 0, 7 do spawn(sim, t, CB.premier, { [0] = i * 32 }) end; return true end
-- pokefirered/src/battle_anim_special.c:217
local SPAWNERS = { [0] = SPAWN.poke, SPAWN.great, SPAWN.safari, SPAWN.ultra, SPAWN.master, SPAWN.safari,
  SPAWN.dive, SPAWN.ultra, SPAWN.repeat_, SPAWN.timer, SPAWN.great, SPAWN.premier }

-- pokefirered/src/battle_anim_mons.c:988 / :1034 / :766 (capture-star arcs, as catch_seq.lua)
local function arcInit(s, speed, destX, destY, ampl)
  local d = s.data
  local dx, dy = destX - s.x, destY - s.y
  local xd = math.floor((math.abs(dx) * 256) % 65536 / speed)
  local yd = math.floor((math.abs(dy) * 256) % 65536 / speed)
  xd = xd - xd % 2 + ((dx < 0) and 1 or 0)
  yd = yd - yd % 2 + ((dy < 0) and 1 or 0)
  d[0], d[1], d[2], d[3], d[4], d[5] = speed, xd, yd, 0, 0, ampl
  d[6] = math.floor(0x8000 / speed)
  d[7] = 0
end
local function translateLinear(s)
  local d = s.data
  if d[0] == 0 then return true end
  local x = (d[3] + d[1]) % 65536
  local y = (d[4] + d[2]) % 65536
  s.x2 = (d[1] % 2 == 1) and -math.floor(x / 256) or math.floor(x / 256)
  s.y2 = (d[2] % 2 == 1) and -math.floor(y / 256) or math.floor(y / 256)
  d[3], d[4] = x, y
  d[0] = d[0] - 1
  return false
end
local function translateArc(s)
  if translateLinear(s) then return true end
  local d = s.data
  d[7] = d[7] + d[6]
  s.y2 = s.y2 + Sin(math.floor(d[7] / 256) % 256, d[5])
  return false
end
-- pokefirered/src/battle_anim_special.c:1298
local function starCb(p)
  p.invisible = not p.invisible
  if translateArc(p) then p.dead = true end
end
-- pokefirered/src/battle_anim_special.c:98
local CAPTURE_STARS = { { 10, 2, -3 }, { 15, 0, -4 }, { -10, 2, -4 } }

-- One instance of the ball-open state for one ball: particles, the mon colour fade and the BG fade clock.
local Sim = {}
Sim.__index = Sim
function N.newSim(ballId)
  return setmetatable({ ballId = ballId or 0, particles = {}, tasks = {}, fade = Fade.new(), mon = nil, frame = 0 }, Sim)
end
-- pokefirered/src/pokeball.c:763 (BallOpen.start): unfadeLater == false fades the Pokemon TO the ball
-- colour (capture, recall); otherwise it starts at the ball colour and fades back (send-out, break-out).
function Sim:open(unfadeLater, yOffset)
  -- pokefirered/src/battle_anim_special.c:1427 (the ball-open callers start the burst 5 px above the ball;
  -- the recall passes the battler's foot point unchanged)
  self.tasks[#self.tasks + 1] = { kind = "particles", ballId = self.ballId, x = 0, y = yOffset or -5, data0 = 0, data7 = 0 }
  local m
  if unfadeLater == false then
    m = { kind = "mon", coeff = 0, d0 = 0, d1 = 1, d2 = 0, state = "to" }
  else
    m = { kind = "mon", coeff = 16, d0 = 16, d1 = -1, d2 = 0, state = "wait" }
  end
  self.mon = m
  self.tasks[#self.tasks + 1] = m
  self.fade:begin(0, 16)
end
-- pokefirered/src/battle_anim_special.c:1266 (capture stars from the ball at the click)
function Sim:stars()
  for _, c in ipairs(CAPTURE_STARS) do
    local p = spawn(self, { x = 0, y = 0, ballId = 0 }, starCb, nil, 1)
    p.invisible = false
    arcInit(p, 24, c[1], c[2], c[3])
  end
end
-- pokefirered/src/battle_anim_special.c:1910
local function runMonFade(sim, m)
  if m.state == "wait" then
    if not sim.fade.active then sim.fade:begin(16, 0); m.state = "step" end
    return false
  end
  if m.d2 <= 16 then
    m.coeff = m.d0
    m.d0 = m.d0 + m.d1
    m.d2 = m.d2 + 1
    return false
  end
  if m.state == "to" then
    if sim.fade.active then return false end
    sim.fade:begin(16, 0)
    m.hold = true
  end
  return true
end
-- One 60 Hz frame (battle_main.c:1447 order: particles, palette fade, tasks).
function Sim:tick()
  local b = BO()
  local animate = b and b.animate
  local keep = {}
  for _, p in ipairs(self.particles) do
    p.cb(p)
    if not p.dead then
      if animate then animate(p) else p.animBeginning = false end
      keep[#keep + 1] = p
    end
  end
  self.particles = keep
  self.fade:update()
  local tasks, kept = self.tasks, {}
  for _, t in ipairs(tasks) do
    local done
    if t.kind == "particles" then done = SPAWNERS[t.ballId](self, t) else done = runMonFade(self, t) end
    if not done then kept[#kept + 1] = t end
  end
  self.tasks = kept
  self.frame = self.frame + 1
end
function Sim:advanceTo(frame)
  local n = 0
  while self.frame < frame and n < 600 do self:tick(); n = n + 1 end
end
-- The Pokemon's blend coefficient (0..16) toward the ball's fade colour.
function Sim:coeff() return self.mon and self.mon.coeff or 0 end
function Sim:busy() return #self.particles > 0 or #self.tasks > 0 or self.fade.active end

-- ------------------------------------------------------------ material
-- GBA BlendPalette (pokefirered/src/blend_palette.c:16) on 5-bit channels, alpha-masked like the host's
-- card shader. GLES rule: no blanket precision statement; qualify per variable.
local SOURCE = [[
varying highp vec2 nativeFlashXZ;
#ifdef PIXEL
uniform mediump vec3 nativeWorldMul;
uniform mediump vec3 nativeWorldAdd;
uniform bool nativeFlashEnabled;
uniform highp vec2 nativeFlashCenter;
uniform highp float nativeFlashRadius;
vec4 maskNativeFlash(vec4 c) {
 float occupied=min(1.0,max(max(c.r,c.g),c.b)*4.0);
 c.rgb=clamp(c.rgb*nativeWorldMul+nativeWorldAdd*occupied,0.0,1.0);
 if (!nativeFlashEnabled) return c;
 float a=nativeFlashRadius<=0.0?1.0:smoothstep(.82*nativeFlashRadius,1.18*nativeFlashRadius,length(nativeFlashXZ-nativeFlashCenter));
 return vec4(c.rgb*(1.0-a),c.a);
}
#endif

varying LOVE_HIGHP_OR_MEDIUMP vec2 v_uv;
#ifdef VERTEX
uniform highp mat4 u_vp;
uniform highp mat4 u_model;
uniform highp vec3 u_eye;
uniform highp float u_pull;
vec4 position(mat4 transform_projection, vec4 vertex_position) {
  v_uv = VertexTexCoord.xy;
  highp vec4 w = u_model * vertex_position;
  nativeFlashXZ=w.xz/16.0;
  // optional: the capture material's view-ray pull (keeps a deformed card in front of nearby terrain)
  if (u_pull > 0.0) w.xyz += normalize(u_eye - w.xyz) * u_pull;
  return u_vp * w;
}
#endif
#ifdef PIXEL
uniform mediump float u_coeff;
uniform mediump vec3 u_target;
vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc) {
  mediump vec4 c = Texel(tex, v_uv);
  if (c.a < 0.5) discard;
  mediump vec3 c5 = floor(c.rgb * 31.0 + 0.5);
  mediump vec3 o = c5 + floor((u_target - c5) * u_coeff / 16.0);
  return maskNativeFlash(vec4(o / 31.0, 1.0));
}
#endif
]]
local shader, attempted, lastError = nil, false, nil
local IDENTITY = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }
local function program()
  if attempted then return shader end
  attempted = true
  local g = love and love.graphics
  if not (g and g.newShader) then return nil end
  local ok, sh = pcall(g.newShader, SOURCE)
  if ok and sh then shader = sh else lastError = tostring(sh) end
  return shader
end
function N.status() return { shader = shader ~= nil, attempted = attempted, error = lastError } end

-- Draw a mesh with a texture through the blend material (coeff 0..16 toward r,g,b 0..31). Restores the
-- previous shader and colour; returns true only when the draw completed.
function N.drawMesh(voxel, mesh, texture, model, coeff, r, g, b, pull)
  local gr = love and love.graphics
  if not (gr and voxel and voxel.vp and mesh) then return false end
  local sh = program()
  if not sh then return false end
  local okS, prev = pcall(gr.getShader)
  local okC, cr, cg, cb, ca = pcall(gr.getColor)
  if not (okS and okC) then return false end
  local ok, err = pcall(function()
    if texture then mesh:setTexture(texture) end
    local wl=voxel.worldLighting
    sh:send('nativeWorldMul',wl and wl.mul or WORLD_IDENTITY)
    sh:send('nativeWorldAdd',wl and wl.add or WORLD_ZERO)
    local nf=voxel.nativeFlash
    sh:send('nativeFlashEnabled',nf~=nil and nf.enabled==true)
    if nf and nf.enabled then sh:send('nativeFlashCenter',nf.center);sh:send('nativeFlashRadius',nf.radiusTiles)end
    sh:send("u_vp", "row", voxel.vp)
    sh:send("u_model", "row", model or IDENTITY)
    sh:send("u_coeff", math.max(0, math.min(16, tonumber(coeff) or 0)))
    sh:send("u_target", { tonumber(r) or 31, tonumber(g) or 31, tonumber(b) or 31 })
    local eye = voxel.eye
    sh:send("u_eye", { eye and tonumber(eye[1]) or 0, eye and tonumber(eye[2]) or 0, eye and tonumber(eye[3]) or 0 })
    sh:send("u_pull", (eye and tonumber(pull)) or 0)
    gr.setShader(sh)
    gr.setColor(1, 1, 1, 1)
    gr.draw(mesh)
  end)
  pcall(gr.setShader, prev)
  pcall(gr.setColor, cr, cg, cb, ca)
  if not ok then lastError = tostring(err) end
  return ok
end

-- ------------------------------------------------------------ world placement
local MAX_PARTICLES = 32
local PARTICLE_LIFT = 0.25 -- world px toward the viewer
local ZERO_VERTEX = { 0, 0, 0, 0, 0, 0 }
local function format(voxel)
  return voxel and voxel.FORMAT or { { "VertexPosition", "float", 3 }, { "VertexTexCoord", "float", 2 },
    { "VertexShade", "float", 1 } }
end
-- holder keeps one dynamic quad mesh. origin = world px of the GBA burst origin (the ball), yaw = facing of
-- the cards (the viewer's), k = world px per GBA px. Returns the mesh (or nil when nothing is visible).
function N.particleMesh(holder, voxel, list, origin, yaw, k)
  local s = sheet("particles")
  if not (s and love and love.graphics and origin) then return nil end
  local rx, rz = math.cos(yaw or 0), -math.sin(yaw or 0)
  -- the game draws these sprites over the Pokemon: lift them off the card's
  -- plane toward the viewer so the two never fight for depth
  local fx, fz = math.sin(yaw or 0) * PARTICLE_LIFT, math.cos(yaw or 0) * PARTICLE_LIFT
  local verts, n = {}, 0
  local half = 4 * k
  local fw, fh = 8 / s.w, 8 / s.h
  for _, p in ipairs(list) do
    if n >= MAX_PARTICLES then break end
    if not p.animBeginning and not p.invisible and not p.dead then
      n = n + 1
      local gx, gy = p.x + p.x2, p.y + p.y2
      local cx, cy, cz = origin[1] + rx * gx * k + fx, origin[2] - gy * k, origin[3] + rz * gx * k + fz
      local u0, u1 = p.frame * fw, (p.frame + 1) * fw
      if p.hFlip then u0, u1 = u1, u0 end
      local b = (n - 1) * 4
      verts[b + 1] = { cx - rx * half, cy - half, cz - rz * half, u0, fh, 1 }
      verts[b + 2] = { cx + rx * half, cy - half, cz + rz * half, u1, fh, 1 }
      verts[b + 3] = { cx + rx * half, cy + half, cz + rz * half, u1, 0, 1 }
      verts[b + 4] = { cx - rx * half, cy + half, cz - rz * half, u0, 0, 1 }
    end
  end
  if n == 0 then return nil end
  for i = n * 4 + 1, MAX_PARTICLES * 4 do verts[i] = ZERO_VERTEX end
  local mesh = holder.particleMesh
  if not mesh then
    local map = {}
    for q = 0, MAX_PARTICLES - 1 do
      local b = q * 4
      map[#map + 1], map[#map + 2], map[#map + 3] = b + 1, b + 2, b + 3
      map[#map + 1], map[#map + 2], map[#map + 3] = b + 1, b + 3, b + 4
    end
    local ok, m = pcall(love.graphics.newMesh, format(voxel), verts, "triangles", "dynamic")
    if not ok then return nil end
    m:setVertexMap(map)
    m:setTexture(s.image)
    holder.particleMesh = m
    mesh = m
  else
    mesh:setVertices(verts)
  end
  mesh:setDrawRange(1, n * 6)
  return mesh
end
function N.drawParticles(holder, voxel, list, origin, yaw, k)
  local mesh = N.particleMesh(holder, voxel, list, origin, yaw, k)
  if not mesh then return true end
  local s = sheet("particles")
  return N.drawMesh(voxel, mesh, s and s.image, IDENTITY, 0)
end

-- A centred card quad of w x h world px (bottom-left, bottom-right, top-right, top-left).
function N.cardMesh(voxel, w, h)
  local hw, hh = w / 2, h / 2
  local verts = { { -hw, -hh, 0, 0, 1, 1 }, { hw, -hh, 0, 1, 1, 1 }, { hw, hh, 0, 1, 0, 1 }, { -hw, hh, 0, 0, 0, 1 } }
  local ok, m = pcall(love.graphics.newMesh, format(voxel), verts, "triangles", "static")
  if not ok then return nil end
  m:setVertexMap({ 1, 2, 3, 1, 3, 4 })
  return m
end

-- The card's model: centre (world px) shifted down by dy, facing yaw, scaled s about its centre.
function N.cardModel(Mat4, center, yaw, s, dy)
  local m = Mat4.translate(center[1], center[2] - (dy or 0), center[3])
  m = Mat4.mul(m, Mat4.rotateY(yaw or 0))
  return Mat4.mul(m, Mat4.scale(s, s, 1))
end

-- ------------------------------------------------------------ native timelines (frames from the open)
-- Send-out emergence: pokefirered/src/pokeball.c:349 as the engine's Anim.sendOutMon (12 frames, scale
-- 0.16 -> 1, 16 px below -> in place).
function N.sendOutPose(frame)
  local u = math.max(0, math.min(1, frame / 12))
  return 0.16 + 0.84 * u, 16 * (1 - u)
end
-- Recall: AnimTask_SwitchOutBallEffect + (delay 10) AnimTask_SwitchOutShrinkMon (pokeemerald/pokefirered
-- battle_anim_special.c; gBattleAnimSpecial_SwitchOutPlayerMon): matrix 0x100 + 0x30 per frame until
-- 0x2D0, bottom-anchored (SetBattlerSpriteYOffsetFromYScale), then invisible. Returns scale or nil.
function N.recallPose(frame)
  if frame <= 10 then return 1 end
  local m = 0x100 + 0x30 * (frame - 10)
  if frame > 11 and 0x100 + 0x30 * (frame - 11) >= 0x2D0 then return nil end
  return 256 / m
end
-- Capture intake: catch_seq.lua CB.tenFrameDelay + CB.shrinkMon (pokefirered battle_anim_special.c:865,
-- :875): 10 frames held, then 0x100 + 0x20 per frame to 0x480 while moving onto the ball, then hidden.
-- Returns scale, fraction of the way to the ball (or nil when hidden).
function N.capturePose(frame)
  if frame <= 11 then return 1, 0 end
  local j = frame - 11
  if j > 28 then return nil end
  return 256 / (256 + 32 * j), j / 28
end
N.CAPTURE_SE_TRADE_FRAME = 21 -- shrinkMon count 11: SE_BALL_TRADE
N.CAPTURE_CLOSE_FRAME = 41    -- shrinkMon state 3: the ball's close animation starts
-- Break-out emergence: catch_seq.lua CB.beginBreakOut / runBreakOut (pokefirered battle_anim_special.c:1305,
-- :1327; data.c:112 affine 0x28 + 0x12 x 12): scale, px below.
function N.breakOutPose(frame)
  local scale = math.min(0x100, 0x28 + 0x12 * math.max(0, frame)) / 256
  -- the lift runs until the affine has ended (frame 13), one frame after full size
  if frame >= 13 then return 1, 0 end
  local d1 = 0x1000 - 288 * math.max(1, frame)
  return scale, math.max(0, math.floor(d1 / 256))
end

-- ------------------------------------------------------------ field party effect (Gen3PartyActionFX)
-- deploy: the ball opens at the Pokemon's feet (the game places the ball 24 px below the battler centre and
-- the burst 5 px above the ball), particles + emergence + fade from the ball colour.
-- recall: particles at the feet (x, y + 32), fade to the ball colour, shrink into the ground point.
-- opts (all optional): below = burst point below the card centre in GBA px, burstY = the burst task's own
-- offset (GBA px; default the game's -5 above the ball, 0 for the recall), preCard = draw the plain card at
-- negative ages (the combined recall, before its native part starts).
N.DEPLOY_DURATION = 70 / 60
N.RECALL_DURATION = 62 / 60 -- the longest bursts (Great/Luxury Ball) end on frame 60
local Party = {}
Party.__index = Party
function N.newParty(voxel, mat4, kind, ballId, opts)
  return setmetatable({ voxel = voxel, M = mat4, kind = kind, ballId = ballId or 0, sim = nil, holder = {},
    opts = opts or {} }, Party)
end
function Party:clear()
  if self.holder.particleMesh then pcall(self.holder.particleMesh.release, self.holder.particleMesh) end
  self.holder, self.sim = {}, nil
end
function Party:frameFor(age)
  return math.max(0, math.floor((tonumber(age) or 0) * 60 + 1e-6))
end
local function drawCard(self, subject, model, coeff, r, g, b)
  -- without the blend material the plain card still shows (no ball colour)
  return N.drawMesh(self.voxel, subject.mesh, subject.texture, model, coeff, r, g, b)
    or pcall(self.voxel.draw, subject.mesh, subject.texture, model)
end
function Party:draw(age, subject, origin, purpose)
  if not (subject and subject.mesh and subject.texture and subject.center) then return false, "unavailable" end
  local recall = self.kind == "recall" or purpose == "recall"
  local o = self.opts
  local c = subject.center
  local yaw = subject.yaw or 0
  if (tonumber(age) or 0) < 0 then
    if o.preCard then return drawCard(self, subject, N.cardModel(self.M, c, yaw, 1, 0), 0), "waiting" end
    return true, "waiting"
  end
  local frame = self:frameFor(age)
  if not self.sim then
    self.sim = N.newSim(self.ballId)
    if recall then self.sim:open(false, o.burstY or 0) else self.sim:open(true, o.burstY) end
  end
  self.sim:advanceTo(frame)
  local w = tonumber(subject.width) or 32
  local h = tonumber(subject.height) or w
  local k = w / 64
  local r, g, b = N.fadeColor(self.ballId)
  local coeff = self.sim:coeff()
  local okCard = true
  if recall then
    local s = N.recallPose(frame)
    if s then okCard = drawCard(self, subject, N.cardModel(self.M, c, yaw, s, (h / 2) * (1 - s)), coeff, r, g, b) end
  else
    local s, oy = N.sendOutPose(frame)
    okCard = drawCard(self, subject, N.cardModel(self.M, c, yaw, s, oy * k), coeff, r, g, b)
  end
  -- ball / foot point below the card centre, in GBA px (64 px battle frame)
  local below = o.below or (recall and 32 or 24)
  N.drawParticles(self.holder, self.voxel, self.sim.particles, { c[1], c[2] - below * k, c[3] }, yaw, k)
  local duration = recall and N.RECALL_DURATION or N.DEPLOY_DURATION
  -- a missing particle draw is cosmetic; only a failed card ends the effect early
  return okCard, (tonumber(age) or 0) >= duration and "complete" or "active"
end

-- ------------------------------------------------------------ combined field effect (user decision 2026-10-01)
-- "use my own send out animations combined with the game's effects": the user's VRITK energy beam
-- (catching/release_energy pose + catching/capture_plasma volume + catching/capture_material, exactly as the
-- pre-fix field effect drew it: same pose clock, colours -- blue send-out, red recall -- shape and timing) is
-- drawn together with the game's own ball-open presentation above. The beam VOLUME is built here with the
-- shared modules, unchanged; the Pokemon's card is the native one (palette fade + grow/shrink), so there is
-- one Pokemon on screen and no double pop.
--   send-out: the beam reaches from the hand/ball to the Pokemon's spot on its own clock. When its tip
--             arrives (the release pose's connector starts to fade at GROW_SEC - 0.15 s) the native burst
--             fires at the beam's endpoint and the Pokemon grows in from the ball colour while the beam fades.
--   recall:   the beam reaches the Pokemon (pre-fix timing). The native fade to the ball colour starts so that
--             the native shrink (10 frames later) begins exactly when the beam starts carrying the energy
--             back (the plasma pull: CAPTURE_ABSORB_SEC + CAPTURE_HOLD_SEC on the capture clock); the beam
--             carries it to the hand/ball while the shrink finishes.
-- deps = { pose = release_energy.pose, Plasma = catching/capture_plasma, Material = catching/capture_material,
--          growSec = release_energy.GROW_SEC, duration = release_energy.DURATION,
--          recallDuration = release_energy.RECALL_DURATION }
N.COMBINED_DEPLOY_ARRIVE_LEAD = 0.15 -- release pose: the connector fade starts at GROW_SEC - 0.15
-- capture_plasma.pose defaults: ABSORB 1.32 + HOLD 0.15; release_energy's recall clock = capture clock - 0.77
N.COMBINED_RECALL_PULL_START = 1.32 + 0.15 - 0.77
local Combined = {}
Combined.__index = Combined
local IDENT = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }
function N.combinedTiming(kind, deps)
  deps = deps or {}
  if kind == "recall" then
    local delay = N.COMBINED_RECALL_PULL_START - 10 / 60
    return delay, math.max(deps.recallDuration or 1.555, delay + N.RECALL_DURATION)
  end
  local delay = (deps.growSec or 1.0) - N.COMBINED_DEPLOY_ARRIVE_LEAD
  return delay, math.max(deps.duration or 1.35, delay + N.DEPLOY_DURATION)
end
function N.newCombined(voxel, mat4, kind, ballId, deps)
  local self = setmetatable({ voxel = voxel, M = mat4, kind = kind, deps = deps }, Combined)
  self.delay, self.duration = N.combinedTiming(kind, deps)
  if kind == "recall" then
    self.native = N.newParty(voxel, mat4, kind, ballId, { preCard = true })
  else
    -- the burst fires at the beam's endpoint: the card centre the release pose aims at
    self.native = N.newParty(voxel, mat4, kind, ballId, { below = 0, burstY = 0 })
  end
  return self
end
function Combined:clear()
  if self.volumeMesh then pcall(self.volumeMesh.release, self.volumeMesh) end
  self.volumeMesh, self.volumeVertices, self.volumeIndices, self.volumeKey = nil, nil, nil, nil
  self.native:clear()
end
-- The beam volume exactly as release_energy's Instance:draw builds and draws it.
function Combined:drawBeam(age, subject, mouth, purpose)
  local d = self.deps
  local p = d.pose(age, subject.center, mouth, subject.width, subject.height, subject.yaw, purpose)
  if not p or p.pull >= .995 or p.fade <= .001 then return true end
  if not self.volumeVertices then self.volumeVertices, self.volumeIndices = d.Plasma.newGeometry() end
  local key = table.concat({ p.timer, p.source[1], p.source[2], p.source[3], mouth[1], mouth[2], mouth[3],
    p.width, p.height, p.yaw }, ":")
  if self.volumeKey ~= key then
    d.Plasma.update(self.volumeVertices, p)
    if not self.volumeMesh then
      self.volumeMesh = self.voxel.newMesh(self.volumeVertices, self.volumeIndices)
    elseif type(self.volumeMesh.setVertices) == "function" then
      self.volumeMesh:setVertices(self.volumeVertices)
    end
    self.volumeKey = key
  end
  if not self.volumeMesh then return false end
  return d.Material.draw(self.voxel, self.volumeMesh, subject.texture, IDENT, 0, p, false)
end
function Combined:draw(age, subject, mouth, purpose)
  if not (subject and subject.mesh and subject.texture and subject.center) then return false, "unavailable" end
  age = tonumber(age) or 0
  local recall = self.kind == "recall"
  local beamEnd = recall and (self.deps.recallDuration or 1.555) or (self.deps.duration or 1.35)
  self.beamOk = true
  if mouth and age < beamEnd then
    local ok, drawn = pcall(self.drawBeam, self, age, subject, mouth, recall and "recall" or (purpose or "follow"))
    self.beamOk = ok and drawn ~= false
    self.beamError = (not ok) and tostring(drawn) or nil
  end
  local okCard = self.native:draw(age - self.delay, subject, mouth, recall and "recall" or purpose)
  -- the beam is drawn with the native presentation; only a failed card ends the effect early
  return okCard, age >= self.duration and "complete" or "active"
end

return N
