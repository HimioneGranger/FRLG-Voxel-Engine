local V = ...
local require = assert(V and V.require, "mod-local profile loader required")
-- Native, exact-source guarded profiles. No global building-family override.
local providers={
 require("mesh/VermilionHouseProfiles"),
 require("mesh/PewterHouseProfiles"),
 require("mesh/SeviiPurpleProfiles"),
 require("mesh/SafariNorthProfiles"),
 require("mesh/ThreeIslandProfiles"),
 require("mesh/LaboratoryProfiles"),
 require("mesh/CinnabarProfiles"),
 require("mesh/UnresolvedSpecialProfiles"),
 require("mesh/SilphProfiles"),
 require("mesh/CeladonBuildingProfiles"),
 require("mesh/MuseumProfiles"),
 require("mesh/SaffronYellowProfiles"),
 require("mesh/NetworkCenterProfiles"),
 require("mesh/SpecialBuildingProfiles"),
 require("mesh/Route12Profiles"),
 require("mesh/TanobyProfiles"),
}
local P={}
P.seviiRoofTemplate=require('mesh/SeviiPurpleProfiles').roofTemplate
P.terrain=require('mesh/FrlgElevationProfiles').terrain
for _,method in ipairs({"match","ownership","connected","water"})do
 P[method]=function(input,comp,atlas)
  for _,provider in ipairs(providers)do
   local fn=provider[method]
   if fn then local result=fn(input,comp,atlas);if result then return result end end
  end
 end
end
return P
