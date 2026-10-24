# Beta 7 technical notes

This repository distributes the FRLG renderer and internal adapters. The host,
ROM import, game simulation, platform services and optional gameplay mods remain
separate. FireRed lab3257 is the source baseline (engine 0.3.33, mod API 2,
LÖVE graphics, plus OpenXR on Quest). The manifest's broad host version range
does not establish compatibility with every host in that range.

## Installation and host services

Install only `FRLG_VOXEL`. Internal adapters initialize under its normal hooks,
events and options. The protected `getCompatibilityHost()` export supplies a
host handle only when the engine is ready for FireRed/LeafGreen; it does not
insert a fake mod or loader alias.

The optional consumer updater supports the pinned VRITK, Catch and Gear
versions. It changes discovery/dependency plumbing, preserves backups and
refuses unknown inputs. It does not run in-game or install those mods.
See [consumer updates](CONSUMER_UPDATES.md).

Host requirements extend beyond the version number:

- Preparation and PC controls use `game.boot_prepare`, `render.boot`,
  `input.mouse` and `input.focus`. Mouse/keyboard mode is a PC option.
- Android CPU preparation requires LÖVE threads and matching native Gen 3
  map/cache modules. GPU upload remains on the rendering thread.
- Android background-preparation ownership and wake handling require the
  matching Activity services (`watchWorldPrepare`, `disarmWorldPrepare` and
  `worldPrepareProcessToken`). A mod ZIP cannot add those Java/native services.
- Steam Frame requires a separately matched launcher and external-frame
  adapter. This engine ZIP is not the Steam Frame tester bundle and does not
  install that launcher or native bridge.

The separate custom title/Oak scene, its portal UI, VRITK, Catch, Gear, Wilds,
weather and clock updates in the full lab are not bundled here. Installing
the engine alone does not reproduce every feature of the lab APK.

The public package omits the lab's embedded Gen 5 sprite provider and its
provider-specific notices. `ImportedSprites.lua` retains beta 4's external
provider route; without a compatible separately installed provider and pack,
it falls back to native battle artwork. The host's importer is not bundled.
This is an explicit exception to the lab3257 source import, alongside the
public beta version metadata; the full lab's imported-sprite workflow is not
included. The existing project license and third-party notices are unchanged.

## Trees and preparation

`TREES` (`fr_trees`) has Cards (`sheet`), Voxel (`voxel`) and Voxel Low Res
(`voxel_low`), defaulting to Cards. Voxel keeps near/far detail. Low Res draws
the existing coarse stamp at every distance. Voxel-to-Low-Res changes only draw
policy, with no map generation change; switching to/from Cards rebuilds nearby
geometry. Retired separate low-detail settings migrate through the native
option writer. Low mode does not remove resident detailed templates or promise
faster precaching. No Quest2 FPS result has been measured.

The current General and Forest forms refine the existing native leaf groups
and lower surfaces. They are not a blanket replacement for every foliage family.
The runtime batches instances and preserves native placement and support.
Dense forests still need device performance testing; batching alone is not a
frame-rate guarantee.

World-cache format 6 persists plain tree templates and placements, then creates
the live GPU resources on a cache hit. Sheet and voxel modes have separate
record/preparation identities. Mode changes cancel incomplete work; malformed
or incompatible data is rejected rather than drawn as a partial cached world.

Cache invalidation now uses a conservative producer dependency policy. Exact
listed presentation-only modules and supported audio assets do not invalidate
static world geometry. Unknown/new files, models, geometry sources, source art
and relevant map/settings changes remain part of the identity. This is not a
promise that every control-only edit can avoid preparation.

An upgrade that changes tree geometry or the record format can legitimately
prepare new records once. Warm reuse is expected only for compatible completed
records. Existing cache corruption checks remain in place; users should not
need to wipe caches as a normal update step.

## Preserved work and verification

Reviewed buildings, all 20 compiled cave outputs and original artwork remain
protected baselines. Mt. Moon B2F retains its deferred visual-polish note.
Large cold cave decoding or graphics allocation can still hitch.

The integration evidence includes bounded tree-cache codec and mode tests,
actual native-map cold/reuse rendering checks, and comparisons of near/far
canopy geometry against the selected profiles. Release verification checks
the standalone package, its exact source provenance, Lua syntax and loading.
These are different from a full gameplay run with every optional mod/host
combination. State the host version, tree mode, location and reproduction steps
when reporting a problem; do not attach ROMs or private saves.

The lab/tester integration and this standalone ZIP have distinct acceptance
status. Quest installation and automated desktop checks do not establish
Steam Frame performance, LeafGreen-wide visual acceptance or compatibility
with older third-party hosts.

## Source work and licensing

Tree work begins in `lib/mesh/FrlgGeneralFoliage.lua`, `FrlgFoliageCompiler.lua`,
`FrlgTreeModels.lua`, `FrlgVoxelTree.lua` and `lib/render/FrlgVoxelTrees.lua`.
Use native-art anatomy evidence, front/side/oblique/underside views and both
near/far geometry. Passing connectivity tests does not establish visual quality.
Preserve the contribution history and credit for flixtkc's voxel-tree PR #1.

The existing [interim private-use license](../LICENSE.txt) applies to original
project material; third-party rights retain their own terms. This remains a
source-available beta, not the full open-source release. Preserve the
[third-party notices](../THIRD_PARTY_NOTICES.md) and source attributions.

## Beta 7 interaction validation

Preparation guidance uses existing loading time; it adds no extra stage. The
Help guide, belt lock, throw assistance, own send-out cue, juggle spin, physical
medicine/TM/HM/berries and native battle text are engine-owned optional adapters.
Their supported consumer mods remain separate. Controlled production-module
tests and isolated GPU captures pass; physical controller feel, full native
TM/HM UI transitions, end-to-end feeding and combined headset performance remain
pending. No fix is claimed for the Steam Frame3255 missing belt report.

The first-pass mainland horizon integration comes from the installed3257 source
baseline and existing map-by-bearing/transition review. It does not establish
complete regional geography or headset acceptance. The native source-map
coordinates, eight original project horizon images and coverage exclusions
remain as reviewed; no new horizon authoring is performed in this release.
