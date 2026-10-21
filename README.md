# FRLG Voxel Engine — beta

A FireRed/LeafGreen voxel renderer for a compatible Gen1Recomp Gen 3 host.
This repository distributes the renderer mod, its internal compatibility
adapters and development sources. It does not distribute the host application
or a collection of gameplay mods.

This is an evaluation beta. Your original game data is required separately.
No ROM, extracted game atlas, save, signing key or account credential is supplied.

## Installation

Download the renderer mod ZIP from the beta release. Extract its `FRLG_VOXEL`
directory and the included `VRITK_FRLG_HOST` shim directory into the compatible
host's mods directory. Replace the prior version
of this mod rather than enabling two copies. Keep your saves backed up.

The host must provide mod API 2, Gen 3 runtime/map/tileset/collision interfaces
and LÖVE graphics. Quest stereo additionally requires the host's OpenXR device
interface. This mod does not add Gen 3 support to a host which lacks it.
The integration baseline is the existing Gen 3 Lab 62 host
(`0.3.33-gen3.lab.62-runtime-fixes-wilds171`). Compatibility with an arbitrary
upstream release is not assumed. Use a separately supplied compatible host.
Desktop rendering and Quest rendering share the engine; headset acceptance is
tracked separately from source, geometry and desktop checks.

Wilds, VRITK, TWS/weather, Catch, Backpack and Portal are optional integrations.
The mod-local mesher/profile loader is verified with those mods absent.
Their integrations activate only when the relevant provider is present.
It owns its rendering/compatibility code inside this mod; those other mods are
not included in this download. The ZIP also includes a tiny `VRITK_FRLG_HOST`
discovery shim because existing VRITK versions look up that fixed identifier.
The shim forwards to compatibility implementation inside `FRLG_VOXEL`; it is
not a second renderer. Replace an older copy of that bridge when installing
this bundle. Do not keep two mods with the same identifier.

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
[private-use beta license](LICENSE.txt): private noncommercial evaluation and
local development, with changes submitted back for review. This is a
source-available beta, not an unrestricted open-source release. Public GitHub
viewing/forking remains subject to GitHub's terms. A future full release may
have separately stated terms.

Third-party material retains its original terms; see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). No rights to Pokémon game
content are granted by this project.
