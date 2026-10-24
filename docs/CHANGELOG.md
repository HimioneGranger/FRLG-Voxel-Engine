# Beta 5

Engine foliage and preparation work from FireRed lab3253:

- Native-art voxel trees from flixtkc's PR #1, with the current General and
  Forest canopy refinements. Existing leaf rows and groups continue around
  their lower surfaces. Near/far geometry and instance batching are retained.
- Upright flowers preserve the original single-artwork treatment.
- Voxel-tree templates and placements now persist in world-cache format6.
  Sheet and voxel modes have separate cache/preparation identities; mode
  changes cannot consume the other mode's unfinished work.
- Bounded CPU preparation, safe cache writes and cooperative GPU completion
  replace the skipped voxel-tree preparation path. Android background/wake
  services require the matching host; those native services are not in this ZIP.
- Cache dependency filtering excludes supported audio and explicit
  presentation-only modules. New or unknown producers remain included;
  geometry and format changes still require fresh records.
- Current engine-side follower placement, physical healing and capture
  presentation adapters, warmer sunrise/golden-hour colors, and saved 3D-view
  capture hooks are also included. Their optional gameplay mods, host services
  and title/portal UI remain separate.

**Try it:** select **VOXEL TREES → VOXEL** in the engine settings. The default
remains **SHEETS**. Do not clear valid caches routinely.

Reviewed building/cave outputs and original artwork remain protected. The host,
optional gameplay mods, separate custom title/Oak scene and Steam Frame launcher
are not part of this engine package. Other lab changes are not implied by the
lab3253 reference. The lab's embedded Gen 5 sprite provider is omitted; the
beta 4 external-provider adapter and native-art fallback are retained.
See [technical notes](TECHNICAL_NOTES.md) for host services
and verification limits. The standalone engine still needs testing with the
chosen host and mod versions; dense forests have no guaranteed VR frame budget.

Thanks to [flixtkc](https://github.com/flixtkc) for the original voxel-tree
contribution in [PR #1](https://github.com/HimioneGranger/FRLG-Voxel-Engine/pull/1).
The interim private-use license and third-party rights remain unchanged.

---

# Beta 4

Engine-only changes from the FireRed lab 3232 runtime:

- A world-preparation screen distinguishes checking, precaching and rebuilding;
  preparation begins after New Game or Continue on a host with the matching hooks.
- Optional PC mouse/keyboard controls and free look. Quest keeps its VR controls.
- Battle terrain visibility no longer depends on the original fixed battle view.
- Single native flower artwork replaces the crossed flower treatment.
- Wilds of Hoenn 1.10.1 integration, native sharp ambient bird artwork and
  high entrances that descend into a 6–10 metre cruise. Clearance considers
  the flight corridor rather than the tallest object anywhere loaded.
- Ordinary distant ground Pokémon retire gradually beyond 16 cells and refill
  within the existing nearby 3–12 cell band. Native departure/arrival effects
  and the live cap remain in charge. Captures, shinies, roamers and active
  interactions are protected; no refresh occurs without a free local spawn cell.
- Party send-out/recall, custom audio, complete sprite cropping and ground
  anchoring fixes; thrown balls keep their incoming heading when they settle.
- VR stairs/escalators fade black while the simulated rig is held, then snap
  to the destination under cover. Headset tracking stays live.
- Pokédex speech can play before a catch while the uncaught tablet entry stays
  hidden. The low-health cue waits for the active battle Pokémon.

All compatibility remains inside `FRLG_VOXEL`. Accepted building/cave outputs,
original artwork, the consumer lookup updater and the interim license remain
unchanged. Optional mods and the host are not bundled.

## Verification and remaining work

Package integrity, Lua syntax and portable loading are checked. Lab tests also
exercise native spawn/FX and warp sequences, a continuous-walk fixture, a full
mod-stack population refresh and original Route 1 bird captures. These tests
do not establish physical headset acceptance. The corresponding lab APK was
installed on Quest 3; this standalone engine ZIP still needs user testing with
the chosen host and optional mod versions.

- The overly broad cache invalidation rule is **not fixed**. Compatibility or
  sound changes can still cause a world-cache rebuild.
- Native ambient frequency is unchanged. Pallet/Viridian had empty native
  bird pools in the tested setup; this update does not add birds to those pools.
- Flight clearance uses loaded, sometimes coarse chunk bounds, not exact
  collision against unloaded scenery.
- Moving population refresh targets ordinary land encounters, not water
  populations or special scripted encounters.
- Nonwarping terrain stairs are outside the stair-transition guard.
- Mt. Moon B2F retains its polish note; large cold cave loads can still hitch.

See [technical notes](TECHNICAL_NOTES.md) and the existing screenshots in the
[README](../README.md). The separate custom title/Oak mod is not in this ZIP.
