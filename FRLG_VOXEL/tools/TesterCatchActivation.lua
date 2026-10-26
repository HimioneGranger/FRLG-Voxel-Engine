-- One-time opt-in for the private tester stack requested for build 3259.
-- Kept with FireRed compatibility; the generic host calls it only when its
-- separately packaged tester-stack marker is present. This is not a loader
-- default and never overrides a later user choice.
local M = {}
M.STACK = 'FRLG_BETA_TESTER_STACK_V1\n'
M.MARKER = 'tester_catch_enabled_3259_'

function M.apply(ctx)
  if type(ctx) ~= 'table' or ctx.testerStack ~= M.STACK then
    return false, 'not-tester-stack'
  end
  local version = ctx.version
  if version ~= 'firered' and version ~= 'leafgreen' then return false, 'other-game' end
  if ctx.cartId or ctx.arena then return false, 'isolated-session' end
  local SD, fs = ctx.SaveData, ctx.fs
  if type(SD) ~= 'table' or type(fs) ~= 'table' or type(fs.read) ~= 'function'
      or type(fs.write) ~= 'function' or type(ctx.decode) ~= 'function' then
    return false, 'persistence-unavailable'
  end
  -- Only the audited installed tester providers; missing/other mods are not
  -- installed, aliased, force-enabled, or granted any additional capability.
  for id, pinned in pairs({FRLG_VOXEL='0.1.0-beta.7', FRLG_CATCH='0.4.0-lab8.2'}) do
    local bytes = fs.read('mods/' .. id .. '/manifest.json')
    local ok, manifest = pcall(ctx.decode, bytes or '')
    if not ok or type(manifest) ~= 'table' or manifest.id ~= id
        or manifest.version ~= pinned then return false, 'unmatched-provider' end
  end
  local options = SD.loadOptions(fs)
  if SD.isSafeMode(options) then return false, 'safe-mode' end
  if SD.modEnabled(options, 'FRLG_VOXEL', version) == false then
    return false, 'engine-disabled'
  end
  -- Preserve the prototype manager's legacy choices before the native loader
  -- migrates them. Otherwise its later migration (which tests only shared
  -- flags) could overwrite the new per-game Catch choice in this first boot.
  -- Use the native restricted data parser, never execute a settings chunk.
  if type(options.mods) == 'table' and next(options.mods) == nil then
    local legacy = fs.read('mod_state.lua')
    if legacy then
      local ok, state = pcall(SD.decode, legacy)
      if not ok or type(state) ~= 'table' then return false, 'legacy-state-unreadable' end
      for id, disabled in pairs(state) do
        if disabled then options.mods[id] = false end
      end
    end
  end
  if SD.modEnabled(options, 'FRLG_VOXEL', version) == false then
    return false, 'engine-disabled'
  end
  local marker = M.MARKER .. version
  options.modOptions = type(options.modOptions)=='table' and options.modOptions or {}
  local bucket = type(options.modOptions.FRLG_VOXEL)=='table' and options.modOptions.FRLG_VOXEL or {}
  if bucket[marker] == true then return false, 'already-migrated' end
  options.modOptions.FRLG_VOXEL = bucket
  SD.setModEnabled(options, 'FRLG_CATCH', true, version)
  bucket[marker] = true
  -- Native SaveData stages, verifies and backs up its whole-file write.
  -- A failed write leaves this migration pending; no live option table is
  -- modified and the next launch can retry.
  if not SD.saveOptions(options, fs) then return false, 'save-failed' end
  local stored = SD.loadOptions(fs)
  local saved = stored.modOptions and stored.modOptions.FRLG_VOXEL
  if SD.modEnabled(stored, 'FRLG_CATCH', version) ~= true
      or not (saved and saved[marker] == true) then
    return false, 'verification-failed'
  end
  return true, 'enabled-once'
end

return M
