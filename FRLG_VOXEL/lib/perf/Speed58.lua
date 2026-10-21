-- FRLG_VOXEL Lab 58 SPEED PATCHES: one master switch plus one flag per item, shared by the renderer files.
-- Every item is an equivalent-output speed-up of an existing path (same draws, same uniforms, same state); the flags
-- exist so a headset A/B can put any one of them back to the Lab 57 code path. Active only while VRITK
-- (VRITK_FRLG_HOST) is installed and active: the gate function is injected by main.lua (see VritkGate). With no gate
-- injected (a test harness, a build without VRITK) every item reports OFF, which is the Lab 57 behaviour.
-- Pure: no engine access. `on(name)` is called from hot paths and allocates nothing.
local S = {}

S.master = true -- the SPEED PATCHES row (OutdoorPerf.speed58)
S.items = {
  cardcull = true,     -- #1 card/blob distance and frustum culling (Billboards)
  actormemo = true,    -- #2 per-actor shadow/height memo, one heightAt, hoisted closures
  seaview = true,      -- #3 Scene:seaView cache by (visible set, eye cell)
  cardverts = true,    -- #7 card/blob vertex reuse, one blob upload per frame
  mipgate = true,      -- #8 Mip mirror refresh only on a real change
  requirememo = true,  -- #12 sandboxed-require memo
  layoutpoll = true,   -- #13 layoutVersion polling
  -- Approach loading (A1/A2): these two CHANGE what is drawn (more cards, a short scale-in), unlike the items above
  ghostcards = true,   -- neighbour-map NPC ghosts as cards (Actors.collect), warm sheets only, culled by distance
  cardscale = true,    -- a newly seen NPC card grows 0.85 -> 1 about its feet over 0.30 s (Billboards)
}

local gate = nil -- function() -> boolean (VRITK installed and active); nil = off
function S.setGate(fn) gate = fn end
function S.hasGate() return gate ~= nil end

function S.active()
  if not S.master or gate == nil then return false end
  return gate() == true
end

function S.on(name)
  if not S.master or S.items[name] ~= true or gate == nil then return false end
  return gate() == true
end

return S
