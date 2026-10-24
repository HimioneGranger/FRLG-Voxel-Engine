-- Record producer identity. Unknown additions remain included. These exact
-- presentation modules are not read by Scene's capture producer.
local M={}
local excluded={
 -- Live encounter placement and reach scheduling; not a Scene record producer.
 ['lib/compat/legacyBridge/lib/compat/WildsReachCompat.lua']=true,
 ['manifest.json']=true,
 ['lib/quest/SaveViewCapture.lua']=true, -- clean save-view presentation only
 ['lib/render/AtmosTime.lua']=true,['lib/render/AtmosSky.lua']=true,
 ['lib/render/AtmosState.lua']=true,['lib/render/PrepareScreen.lua']=true,
 ['lib/render/VoxelLoading.lua']=true,['lib/render/LoadingGate.lua']=true,
 ['lib/perf/FrPrecacheDependencies.lua']=true,
 ['lib/perf/FrPrecacheReuse.lua']=true,['lib/perf/FrPrecacheLegacy.lua']=true,
 ['lib/battle/ImportedSprites.lua']=true,['lib/battle/ImportedSpriteProvider.lua']=true,
 ['lib/battle/gen5-notices/ANIMAENGINE_LICENSE']=true,
 ['lib/battle/gen5-notices/LICENSE']=true,['lib/battle/gen5-notices/PROVENANCE.md']=true,
 -- Live follower inventory/input only; neither module enters Scene capture.
 ['lib/compat/legacyBridge/lib/compat/Gen3PhysicalMedicine.lua']=true,
 ['lib/compat/legacyBridge/lib/compat/Gen3FollowerMedicine.lua']=true,
 ['lib/compat/legacyBridge/lib/compat/NativeBallFX.lua']=true,
 ['lib/compat/legacyBridge/lib/compat/Gen3BallHeadingCompat.lua']=true,
 ['lib/compat/legacyBridge/lib/compat/Gen3PartyActionFX.lua']=true,
 ['lib/compat/legacyBridge/lib/compat/Gen3CapturePresentation.lua']=true,
 ['lib/compat/legacyBridge/lib/compat/Gen3FollowerPlacement.lua']=true,
 ['lib/compat/legacyBridge/lib/compat/Gen3PartySubjectCompat.lua']=true,
 ['lib/compat/legacyBridge/lib/compat/Gen3RecallAim.lua']=true,
 ['lib/compat/legacyBridge/lib/compat/OpeningBeamFX.lua']=true,
}
function M.include(path)
 if excluded[path] then return false end
 -- Audio is never read as static world geometry/classification. No broad
 -- extension exemption for images, model data, Lua or unknown assets.
 if path:match('^assets/') or path:match('^lib/compat/legacyBridge/assets/') then
  local ext=path:match('%.([^./]+)$');ext=ext and ext:lower()
  if ext=='mp3' or ext=='ogg' or ext=='wav' or ext=='flac' then return false end
 end
 return true
end
function M.content(path,source)
 if path~='lib/perf/FrPrecacheKey.lua' then return source end
 -- Only code-policy orchestration is omitted. Preserve every key-producing
 -- engine/input/atlas/edge function and their shared prefix helpers.
 local tail=source:match('(\n%-%- %-%-+ engine.*)')
 local prefix=source:match('(local K = {}.-)\n%-%- %-%-+ code')
 if not tail or not prefix then return source end -- unfamiliar source fails conservative
 return 'FrPrecacheKey-producers-v1\n'..prefix..tail
end
return M
