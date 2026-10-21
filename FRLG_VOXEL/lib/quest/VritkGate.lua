-- FRLG_VOXEL Lab 57: is VRITK (mod VRITK_FRLG_HOST) installed and active? The Lab 57 features (WORLD CACHE,
-- LOADING SCREEN with its full collect and warm-up pass, the eye-pass probe) turn on only when it is. With VRITK
-- absent they stay off and the game behaves as before. The lookup goes through the mod registry (mod.find), never
-- package.loaded, and fails soft: a missing or throwing registry means "not active".
-- Pure: find and clock are injected. The answer is re-read at most every `interval` seconds (VRITK can load after
-- this mod, so a "no" is not final).
local G = {}
G.__index = G

G.MOD_ID = "VRITK_FRLG_HOST"

function G.new(find, clock, interval)
  return setmetatable({ find = find, clock = clock or os.clock, interval = interval or 1.0, at = nil, on = false }, G)
end

function G:active()
  local t = self.clock()
  if self.at == nil or t - self.at >= self.interval or t < self.at then
    self.at = t
    local ok, handle = false, nil
    if type(self.find) == "function" then ok, handle = pcall(self.find, G.MOD_ID) end
    self.on = ok and handle ~= nil and handle ~= false
  end
  return self.on
end

-- forget the cached answer (tests, session restart)
function G:reset() self.at, self.on = nil, false end

return G
