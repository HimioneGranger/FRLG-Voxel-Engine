-- FRLG_VOXEL: the flat game frame in VR.
--  * flat canvas (240x160): world plane + UI plane composited exactly like
--    Display.mirrorFlatFrame (src/core/game3/display.lua:329-356), captured
--    in render.compose so it also covers boot/title frames.
--  * quad canvas (960x640): the flat canvas upscaled 4x with nearest
--    filtering, blitted into the OpenXR quad layer in PANEL mode (battles,
--    full-screen menus, voxel view off or failed).
--  * in-scene UI card: while the 3D field is shown, the transparent UI plane
--    (text boxes, start menu, map-name popup) is drawn inside each eye as an
--    alpha-blended card in LOCAL space, in front of where the head looked
--    when the latest menu/text opened.
local V = ...
local Mat4 = V.require("render/Mat4")
local Shaders = V.require("render/Shaders")
-- Lab 58 #12 (flag "requirememo"): engine module tables are remembered after the first success (the sandboxed
-- require is not free and these run every frame). A failed require is retried; Panel.resetEngineMemo() forgets.
local okS58, Speed58 = pcall(V.require, "perf/Speed58")
if not (okS58 and type(Speed58) == "table") then Speed58 = nil end
local engineMemo = {}

local Panel = {}
Panel.__index = Panel

Panel.W, Panel.H = 240, 160
Panel.CARD_WIDTH = 0.95    -- metres
Panel.CARD_DIST = 1.05
Panel.CARD_DROP = 0.28

function Panel.new()
  return setmetatable({ flat = nil, quad = nil, composedFrame = -1, cardYaw = nil,
                        cardBase = nil, card = nil, menuWas = false }, Panel)
end

local function newCanvas(w, h)
  local ok, c = pcall(love.graphics.newCanvas, w, h, { dpiscale = 1 })
  if not ok or not c then return nil end
  c:setFilter("nearest", "nearest")
  return c
end

-- Every push("all") below is paired with a pop() that runs even when the
-- body throws: a Canvas left bound makes love.graphics.present() throw and
-- takes the app down (review item 1).
local function guarded(body, ...)
  local g = love.graphics
  g.push("all")
  local ok, a, b = pcall(body, ...)
  g.pop()
  if not ok then return false, tostring(a) end
  return a, b
end

local function composeBody(flat, ctx)
  local g = love.graphics
  g.setCanvas(flat)
  g.origin()
  g.setShader()
  g.setBlendMode("alpha")
  g.clear(0, 0, 0, 1)
  g.setColor(1, 1, 1, 1)
  local world = ctx.worldCanvas
  if ctx.worldActive and world then
    local vw, vh = world:getWidth(), world:getHeight()
    g.draw(world, math.floor((Panel.W - vw) / 2), math.floor((Panel.H - vh) / 2))
  end
  if ctx.uiCanvas then g.draw(ctx.uiCanvas, 0, 0) end
  return true
end

function Panel:composeFlat(ctx, frame)
  if not self.flat then self.flat = newCanvas(Panel.W, Panel.H) end
  local flat = self.flat
  if not flat then return false end
  local ok, err = guarded(composeBody, flat, ctx)
  if not ok then return false, err end
  self.composedFrame = frame
  return true
end

-- Source for the panel quad this frame.
function Panel:flatCanvas(frame)
  if self.flat and self.composedFrame == frame then return self.flat end
  local memo = Speed58 and Speed58.on("requirememo")
  local Display = memo and engineMemo["src.core.game3.display"] or nil
  if not Display then
    local ok, d = pcall(require, "src.core.game3.display")
    Display = ok and d or nil
    if memo and type(Display) == "table" then engineMemo["src.core.game3.display"] = Display end
  end
  if Display and Display._canvas then return Display._canvas end
  return self.flat
end

function Panel:quadCanvas(frame, qw, qh)
  local src = self:flatCanvas(frame)
  if not src then return nil end
  qw, qh = qw or Panel.W * 4, qh or Panel.H * 4
  if not self.quad or self.quad:getWidth() ~= qw or self.quad:getHeight() ~= qh then
    if self.quad then pcall(self.quad.release, self.quad) end
    self.quad = newCanvas(qw, qh)
  end
  if not self.quad then return nil end
  local ok, err = guarded(function(quad)
    local g = love.graphics
    g.setCanvas(quad)
    g.origin()
    g.setShader()
    g.clear(0, 0, 0, 1)
    g.setColor(1, 1, 1, 1)
    pcall(src.setFilter, src, "nearest", "nearest")
    local sw, sh = src:getWidth(), src:getHeight()
    local s = math.min(qw / sw, qh / sh)
    g.draw(src, math.floor((qw - sw * s) / 2), math.floor((qh - sh * s) / 2), 0, s, s)
    return true
  end, self.quad)
  if not ok then return nil, err end
  return self.quad
end

-- Re-anchor the in-scene card in front of the head whenever a menu or text
-- box opens (rising edge), so it never ends up behind a player who turned.
function Panel:updateCardPose(pose, menuOpen)
  if (menuOpen and not self.menuWas) or not self.cardYaw then
    self.cardYaw = pose and pose.quat and Mat4.quatYaw(pose.quat) or 0
    local p = pose and pose.pos or { 0, 0, 0 }
    self.cardBase = { p[1], p[2], p[3] }
  end
  self.menuWas = menuOpen and true or false
end

local function cardMesh(self)
  if self.card then return self.card end
  -- zero normals = unlit (full brightness) in the world shaders
  local verts = {
    { -0.5, -0.5, 0, 0, 1, 0, 0, 0 }, { 0.5, -0.5, 0, 1, 1, 0, 0, 0 },
    { 0.5, 0.5, 0, 1, 0, 0, 0, 0 },
    { -0.5, -0.5, 0, 0, 1, 0, 0, 0 }, { 0.5, 0.5, 0, 1, 0, 0, 0, 0 },
    { -0.5, 0.5, 0, 0, 0, 0, 0, 0 },
  }
  local ok, m = pcall(love.graphics.newMesh, Shaders.FORMAT, verts, "triangles", "static")
  if ok then self.card = m end
  return self.card
end

-- P = (flipped) projection; eyeLocal = the eye's LOCAL-space view (metres).
function Panel:drawCard(P, eyeLocal, uiCanvas)
  if not uiCanvas then return end
  local mesh = cardMesh(self)
  local shader = Shaders.get("CUTOUT")
  if not (mesh and shader) then return end
  local yaw = self.cardYaw or 0
  local b = self.cardBase or { 0, 0, 0 }
  local w = Panel.CARD_WIDTH
  local h = w * (uiCanvas:getHeight() / math.max(1, uiCanvas:getWidth()))
  local model = Mat4.chain(
    Mat4.translate(b[1] - math.sin(yaw) * Panel.CARD_DIST, b[2] - Panel.CARD_DROP,
      b[3] - math.cos(yaw) * Panel.CARD_DIST),
    Mat4.rotY(yaw),
    Mat4.scale(w, h, 1))
  local g = love.graphics
  mesh:setTexture(uiCanvas)
  g.setShader(shader)
  Shaders.frame(shader, { light = { sun = { 0, 1, 0 }, fill = { 0, 1, 0 }, terms = { 1, 0, 0 } },
    fog = { 1000, 2000, 0 }, fogColor = { 0, 0, 0, 1 } }, 0.0)
  Shaders.shadow(shader, nil)
  Shaders.texSize(shader, nil)
  Shaders.send(shader, "u_mvp", "row", Mat4.chain(P, eyeLocal, model))
  g.draw(mesh)
  g.setShader()
end

-- ------------------------------------------------ location preview (3D only)
-- FireRed's location preview (map_preview_screen.c; Viridian Forest on
-- first entry, caves) paints FULL-SCREEN artwork of the area into the UI
-- plane plus a 13x2-tile name window at (0,0) (sMapNameWindow). The flat
-- game shows the artwork opaque over the field and fades it out; over the
-- 3D view it read as the whole flat frame laid across the scene. While the
-- 3D view renders, the UI plane is cut down to the name window, so both the
-- desktop overlay and the Quest card show just the banner. Text boxes and
-- menus dismiss the preview (hud.lua) and are never cut.
Panel.PREVIEW_BANNER = { 0, 0, 104, 16 }   -- x, y, w, h in UI pixels

local function engineModule(name)
  if Speed58 and Speed58.on("requirememo") then
    local m = engineMemo[name]
    if m then return m end
    local ok, mod = pcall(require, name)
    if ok and type(mod) == "table" then engineMemo[name] = mod; return mod end
    return nil
  end
  local ok, m = pcall(require, name)
  if ok and type(m) == "table" then return m end
  return nil
end
function Panel.resetEngineMemo() for k in pairs(engineMemo) do engineMemo[k] = nil end end

local function callFlag(m, fn)
  local f = m and m[fn]
  if type(f) ~= "function" then return false end
  local ok, v = pcall(f)
  return ok and v and true or false
end

-- True while the preview artwork is on the UI plane (forest preview, or a
-- cave preview; not the plain cave flash) and no text box / menu is up.
function Panel.previewShowing()
  local M = engineModule("src.ui.game3.map_preview_screen")
  if not M then return false end
  if not (callFlag(M, "isForestActive") or rawget(M, "_cave") ~= nil) then return false end
  if callFlag(engineModule("src.ui.game3.message"), "isOpen") then return false end
  if callFlag(engineModule("src.ui.game3.stack"), "busy") then return false end
  return true
end

-- The engine's UI plane (the render.compose ctx.uiCanvas).
function Panel.uiCanvas()
  local R = engineModule("src.render.Renderer")
  return R and R.canvas or nil
end

-- 3D path only (View:prepare): clear the UI plane outside the preview's
-- name window. The flat PANEL copy is composed before this runs and the
-- engine redraws the plane every frame. Returns true when it cut.
function Panel.maskPreview(ui)
  ui = ui or Panel.uiCanvas()
  if not (ui and ui.getDimensions and Panel.previewShowing()) then return false end
  local w, h = ui:getDimensions()
  local b = Panel.PREVIEW_BANNER
  local ok = guarded(function()
    local g = love.graphics
    g.setCanvas(ui)
    g.origin()
    g.setScissor()
    g.setShader()
    g.setBlendMode("replace", "premultiplied")
    g.setColor(0, 0, 0, 0)
    local bx1, by1 = b[1] + b[3], b[2] + b[4]
    if bx1 < w then g.rectangle("fill", bx1, 0, w - bx1, by1) end     -- right of it
    if by1 < h then g.rectangle("fill", 0, by1, w, h - by1) end       -- below it
    return true
  end)
  return ok == true
end

function Panel:release()
  for _, k in ipairs({ "flat", "quad", "card" }) do
    local c = self[k]
    if c and c.release then pcall(c.release, c) end
    self[k] = nil
  end
end

return Panel
