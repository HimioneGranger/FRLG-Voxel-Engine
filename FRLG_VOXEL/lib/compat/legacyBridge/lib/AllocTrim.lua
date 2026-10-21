-- Lab 51 ALLOC TRIM flag shared by the VRITK_FRLG_HOST libs (and read by
-- SkinnedGloveHands through VRHandAssets.trimFlag). Plain field read =
-- allocation-free. Default ON. OFF runs the exact Lab 50 code paths.
local T = { on = true }
function T.set(on) T.on = on and true or false end
return T
