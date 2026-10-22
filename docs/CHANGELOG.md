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
