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
The host baseline remains Gen 3 Lab 62 (mod API 2/LÖVE, plus OpenXR for Quest).
Original game inputs and optional gameplay mods remain separate.

Compatibility exports are isolated at `FRLG_VOXEL.exports.compatibility`.
The engine resolves its historical bridge lookup internally; it does not
invent a loaded mod or modify the host's private loader registry. An already
installed beta-1 discovery shim can attach to the same adapter exports without
duplicating hooks, but the beta-2 archive contains no shim folder. Remove the
old separate folder during upgrade. Unchanged external VRITK/Catch/Gear builds
that look up or hard-depend on that old ID need their consumer contract updated;
they are not verified as supported by this single-folder release. The old host's
HD guard also hardcodes the legacy folder. These limitations are not hidden by
a fabricated alias. Wilds 1.5.0 and 1.7.1 use the engine-owned provider directly.

Game simulation, ROM import and platform device services remain the host's
responsibility.

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
