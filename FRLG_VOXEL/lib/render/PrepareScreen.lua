-- FRLG_VOXEL Lab 59: the "Preparing 3D world" screen of PRECACHE ON FIRST LOAD (FireRed's own file).
--
-- An opaque black canvas with a title, "Map N of M", a progress bar, a rough time-remaining line and the skip
-- hint. On the headset it is the flat panel quad (XRSession's panel: a comfortable, world-locked rectangle about
-- 1.25 m in front of where the head looked; main.lua also asks XRSession to follow the head when it turns away),
-- supplied only through the panelCanvas hook, like the Loading screen.
--
-- No per-frame allocation: canvas() compares a few numbers with the last drawn ones and returns the same Canvas
-- object while nothing visible changed. The canvas is repainted when the bar moves by at least one step, the map
-- counter or the time bucket changes, or the phase / skip state changes, and then at most every REDRAW_S seconds
-- (the strings are built only then).
local S = {}
S.__index = S

S.REDRAW_S = 0.2
S.BAR_STEPS = 400         -- the bar moves in 1/400 steps

function S.new()
  return setmetatable({ image = nil, drawn = false, kStep = -1, kDone = -1, kEta = -2, kPhase = "", kSkip = false,
    kTotal = -1, lastDraw = -1e9, draws = 0, fonts = nil }, S)
end

local function etaBucket(eta)
  if eta == nil or eta < 0 then return -1 end
  if eta < 90 then return 5 * math.ceil(eta / 5) end
  return 1000 + math.ceil(eta / 60)
end
S.etaBucket = etaBucket

local function etaText(b)
  if b < 0 then return "Estimating time left..." end
  if b < 1000 then return ("About %d sec left"):format(math.max(5, b)) end
  return ("About %d min left"):format(b - 1000)
end
S.etaText = etaText

local function paint(self, w, h, prog)
  local g = love.graphics
  g.origin(); g.setShader(); g.setScissor(); g.setStencilTest(); g.setDepthMode(); g.setMeshCullMode("none")
  g.setBlendMode("alpha"); g.setColor(0, 0, 0, 1); g.rectangle("fill", 0, 0, w, h)
  local f = self.fonts
  g.setColor(1, 1, 1, 1)
  g.setFont(f.big)
  g.printf("Preparing 3D world", 0, math.floor(h * 0.14), w, "center")
  g.setColor(0.72, 0.72, 0.72, 1)
  g.setFont(f.small)
  g.printf("Building the maps from your game. This only happens once.", 0, math.floor(h * 0.14 + f.big:getHeight() + h * 0.02), w, "center")
  g.setColor(1, 1, 1, 1)
  g.setFont(f.mid)
  local phase = prog.phase
  local line
  if phase == "check" or phase == "plan" then line = "Checking saved data..."
  elseif prog.skipping then line = "Skipping..."
  elseif phase == "finish" then line = "Finishing up..."
  elseif phase == "tiles" then line = ("Loading tilesets %d of %d"):format(math.min(prog.total, prog.done + 1), prog.total)
  else line = ("Map %d of %d"):format(math.min(prog.total, prog.done + 1), prog.total) end
  g.printf(line, 0, math.floor(h * 0.42), w, "center")
  -- bar
  local bw, bh = math.floor(w * 0.7), math.max(14, math.floor(h * 0.045))
  local bx, by = math.floor((w - bw) / 2), math.floor(h * 0.54)
  g.setColor(0.2, 0.2, 0.2, 1); g.rectangle("fill", bx, by, bw, bh)
  g.setColor(0.38, 0.82, 0.5, 1); g.rectangle("fill", bx, by, math.floor(bw * math.min(1, math.max(0, prog.frac))), bh)
  g.setColor(0.8, 0.8, 0.8, 1); g.rectangle("line", bx + 0.5, by + 0.5, bw - 1, bh - 1)
  g.setColor(1, 1, 1, 1)
  g.setFont(f.mid)
  g.printf((phase == "run" and etaText(etaBucket(prog.etaSec))) or (phase == "tiles" and "Getting ready...") or "", 0, math.floor(h * 0.63), w, "center")
  g.setColor(0.72, 0.72, 0.72, 1)
  g.setFont(f.small)
  g.printf("Press B to skip for now. It carries on next time you start the game.", 0, math.floor(h * 0.84), w, "center")
end

-- prog = { phase, done, total, frac, etaSec, skipping }; now = seconds. -> Canvas. Raises on a graphics failure
-- (the caller falls back to the flat panel).
function S:canvas(w, h, prog, now)
  local g = love.graphics
  if self.image and (self.image:getWidth() ~= w or self.image:getHeight() ~= h) then
    self.image:release(); self.image = nil; self.drawn = false
  end
  if not self.image then
    self.fonts = self.fonts or {
      big = g.newFont(math.max(24, math.floor(h / 11))),
      mid = g.newFont(math.max(18, math.floor(h / 17))),
      small = g.newFont(math.max(14, math.floor(h / 26))),
    }
    local c = g.newCanvas(w, h, { dpiscale = 1 })
    c:setFilter("linear", "linear")
    self.image = c
    self.drawn = false
  end
  local step = math.floor(math.min(1, math.max(0, prog.frac)) * S.BAR_STEPS)
  local eta = etaBucket(prog.etaSec)
  local same = self.drawn and step == self.kStep and prog.done == self.kDone and eta == self.kEta
    and prog.phase == self.kPhase and (prog.skipping == true) == self.kSkip and prog.total == self.kTotal
  if not same and (not self.drawn or now - self.lastDraw >= S.REDRAW_S) then
    g.push("all")
    local ok, why = pcall(function() g.setCanvas(self.image); paint(self, w, h, prog) end)
    g.pop()
    if not ok then self.drawn = false; error(why, 0) end
    self.drawn = true
    self.kStep, self.kDone, self.kEta, self.kPhase = step, prog.done, eta, prog.phase
    self.kSkip, self.kTotal = prog.skipping == true, prog.total
    self.lastDraw = now
    self.draws = self.draws + 1
  end
  return self.image
end

function S:release()
  if self.image then self.image:release(); self.image = nil end
  if self.fonts then
    for _, f in pairs(self.fonts) do if f.release then f:release() end end
    self.fonts = nil
  end
  self.drawn = false
end

return S
