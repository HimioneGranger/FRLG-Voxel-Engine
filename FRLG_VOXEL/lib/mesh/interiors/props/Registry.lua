-- FRLG_VOXEL / interiors team: props/Registry.lua -- the furniture types in
-- precedence order (an earlier type takes a contested cell first). Every type
-- of every wave is listed from the start; a type whose file
-- lib/mesh/interiors/props/<Type>.lua does not exist yet is skipped, so adding
-- a type never edits this file. Owner: the coordinator (scout PLAN.md 5).
-- Specific pieces before broad ones; Plant last. Overlaps are fixed by
-- narrowing a type's match, not by leaning on this order.
-- Wave 1: Healer CableClub(w3) PC Counter MartShelf Seat Table
-- Wave 2: Kitchen Cabinet Bookshelf TV Bed Plant
-- Wave 3: CableClub Desk Telephone Machine Statue Bin
-- Wave 4: GameCorner Grave Crate Rail Pillar OneOff
local V = ...
local _ = V
return {
  "Healer", "CableClub", "PC", "Counter", "MartShelf", "Kitchen", "Cabinet", "Bookshelf", "TV", "Bed",
  "Seat", "Table", "Desk", "Telephone", "Machine", "Statue", "Bin", "GameCorner", "Grave", "Crate",
  "Rail", "Pillar", "OneOff", "Plant",
}
