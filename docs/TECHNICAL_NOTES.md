# FRLG Voxel Engine — beta

A FireRed/LeafGreen voxel renderer for a compatible Gen1Recomp Gen 3 host.
This repository distributes the renderer mod, its internal compatibility
adapters and development sources. It does not distribute the host application
or a collection of gameplay mods.

This is an evaluation beta. Your original game data is required separately.
No ROM, extracted game atlas, save, signing key or account credential is supplied.

## Installation

Extract `FRLG_VOXEL` into the compatible host's mods directory. All adapters
initialize under this engine's hooks, events and options. No separately enabled
compatibility shim is needed for the renderer or Wilds Pokémon drawing.
Beta 4's tested host is FireRed lab 3232 (engine 0.3.33, mod API 2/LÖVE,
plus OpenXR for Quest). Earlier beta verification used Gen 3 Lab 62.
Original game inputs and optional gameplay mods remain separate.

Compatibility exports are isolated at `FRLG_VOXEL.exports.compatibility`.
External consumers now use the protected `getCompatibilityHost()` export,
which returns a standard host handle only when the engine compatibility API is
ready for FireRed/LeafGreen. The engine's layout/readiness checks stay inside
FRLG_VOXEL. It does not invent a host mod entry or modify the loader registry.

The included offline updater changes seven source/manifest files across the
pinned VRITK, Catch and Gear versions. It removes Catch's hard dependency on
the absent bridge and adds ordering edges where needed. Actual host-loader
tests cover reverse player ordering and legacy fallback. All adapter behavior
remains inside FRLG_VOXEL; external changes are lookup/dependency plumbing.
It never runs automatically in-game. See [consumer updates](CONSUMER_UPDATES.md)
for validation, backups and scope. HD sprites' old host guard is still a
separate unresolved compatibility area, not claimed covered by these changes.

Game simulation, ROM import and platform device services remain the host's
responsibility.

The updated host must call the `game.boot_prepare`, `render.boot`,
`input.mouse` and `input.focus` hooks for the new preparation and PC mouse
features. Older hosts are not claimed to provide them. Mouse/keyboard mode is
a PC option and is not enabled as a Quest control scheme.

This engine package does not include the separate custom Oak/title mod,
Wilds, VRITK, Catch, Gear, weather/clock mods or the host application. Their
independent updates in a full lab APK are not part of this engine ZIP.

## Foliage development

Work from a branch and submit focused changes. Begin with
`FRLG_VOXEL/lib/grass/`, `FRLG_VOXEL/lib/mesh/FrlgNativeFoliage.lua` and
`FRLG_VOXEL/lib/render/FrlgTreeView.lua`. Preserve native plant placement,
terrain support, source artwork and collision. Check both nearby views and
the normal camera distances, including animated grass and tree transparency.

Building shapes and accepted cave layouts are protected regression baselines.
Keep foliage changes scoped; include before/after captures and the test command
and environment used. A passing geometry test does not establish visual or
headset acceptance. Do not include game files or private saves in submissions.

## Included work and verification

The beta integrates the latest reviewed native building profile set and all
20 accepted FireRed cave outputs, including the source-specific Mt. Moon 1F
and B2F results. Mt. Moon B2F retains its deferred visual-polish note.
The cave runtime validates observable native map state and original artwork,
builds its texture from local native donors, and shares geometry with its
height queries. Water animation uses admitted native frames.

Verification covers exact cave geometry/UV/shading/query preservation, native
runtime map guards, desktop GPU uploads/draws, source loading without the
external gameplay mods, compatibility discovery/lifecycle, and cancellation
resource cleanup. These checks do not constitute a full gameplay or Quest
headset acceptance run. Please report beta issues with the host version and
reproduction steps, without attaching ROMs or private saves.

Cold cave construction is cooperative, but can still produce frame hitches
while decoding large meshes or allocating resources. Desktop measurements are
development diagnostics, not a guaranteed VR frame budget. Quest performance
and full gameplay acceptance remain unverified for this beta.

World-cache invalidation still hashes all engine compatibility files and
assets. An audio or control-only update can therefore trigger an unnecessary
terrain rebuild. Beta 4 does not fix that rule. See [change notes](CHANGELOG.md)
for the current runtime checks and other limitations.

## License

Original project material is offered under the interim
[private-use beta license](../LICENSE.txt): private noncommercial evaluation and
local development, with changes submitted back for review. This is a
source-available beta, not an unrestricted open-source release. Public GitHub
viewing/forking remains subject to GitHub's terms. The engine's original code will become open source at its full release, under
a license announced then. Beta forks remain for private use; publicly releasing
beta-derived work requires HimioneGranger's prior explicit written permission,
subject to GitHub-required viewing/forking and third-party license rights.

Third-party material retains its original terms; see
[THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md). No rights to Pokémon game
content are granted by this project.
