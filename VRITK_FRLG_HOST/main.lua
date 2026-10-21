-- Discovery only; substantive compatibility code lives inside FRLG_VOXEL.
local mod = ...
local engine = mod.find("FRLG_VOXEL")
assert(engine and engine.exports and type(engine.exports.installLegacyBridge)=="function",
 "FRLG Voxel Engine compatibility bootstrap is unavailable")
engine.exports.installLegacyBridge(mod)
